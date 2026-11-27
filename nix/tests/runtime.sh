#!/usr/bin/env bash
# Inspect the real packaged runtime without requiring FUSE or a user session.
set -euo pipefail
package=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
body="$package/share/amber-pm/apm/files"
mkdir -p "$work/bin" "$work/guest"
export APM_TEST_ARGV="$work/bwrap.argv"
cat > "$work/bin/bwrap" <<EOF
#!$BASH
printf '%s\\0' "\$@" > "\$APM_TEST_ARGV"
EOF
chmod +x "$work/bin/bwrap"
host_path="$work/bin:$PATH"
(
    export PATH="$host_path"
    # shellcheck source=/dev/null
    source "$body/ace-run-lib.sh"
    guest_path=$(ace_container_path)
    case "$guest_path" in *"$work/bin"*) exit 1;; esac
    case "$guest_path" in *:/usr/sbin:/usr/bin:/sbin:/bin) ;; *) exit 1;; esac
    ACE_BWRAP_SETENV=(--setenv PATH "$guest_path")
    ACE_BWRAP_BINDS=(--dev-bind "$work/guest" / --dev-bind / /host)
    ace_run_container "$work/print args" 'literal $HOME' 'a"b' '' \
        '$(touch should-not-exist)' $'line1\nline2'
)
mapfile -d '' -t argv < "$APM_TEST_ARGV"
has_args() {
    local i j
    for ((i=0; i <= ${#argv[@]} - $#; i++)); do
        j=0
        for expected in "$@"; do
            [ "${argv[i+j]}" = "$expected" ] || break
            j=$((j+1))
        done
        [ "$j" != "$#" ] || return 0
    done
    printf 'Missing runtime arguments:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 1
}
has_args --ro-bind /nix/store /nix/store
has_args --dev-bind-try /var/lib/apm /var/lib/apm
has_args --setenv APM_HOST_PATH "$host_path"
has_args --setenv SHELL /bin/bash
for name in LD_LIBRARY_PATH LD_PRELOAD NIX_LD_LIBRARY_PATH GIO_EXTRA_MODULES GTK_MODULES QT_PLUGIN_PATH; do
    has_args --unsetenv "$name"
done

# Run the reconstructed command to verify the bytes reaching the guest shell,
# including empty/newline arguments and shell syntax that must stay literal.
cat > "$work/print args" <<EOF
#!$BASH
printf '%s\\0' "\$@" > "\$APM_TEST_CHILD_ARGV"
EOF
chmod +x "$work/print args"
export APM_TEST_CHILD_ARGV="$work/child.argv"
bash -c "${argv[-1]}"
printf '%s\0' 'literal $HOME' 'a"b' '' '$(touch should-not-exist)' $'line1\nline2' > "$work/expected.argv"
cmp "$work/expected.argv" "$APM_TEST_CHILD_ARGV"

# Replace only the bridge transport with a recorder. Its remaining code,
# executable paths, environment handling and command arguments are packaged.
bridge="$body/amber-ce-tools/bin-override/host-spawn"
transport=$(sed -n 's/^args=(\([^ ]*\) --user.*/\1/p' "$bridge")
case "$transport" in /nix/store/*/bin/systemd-run) ;; *) exit 1;; esac
grep -Eq '^exec .* -- /nix/store/[^ ]*/bin/env "\$@"$' "$bridge"
sed "s|$transport|$work/bin/systemd-run|g" "$bridge" > "$work/host-spawn"
cat > "$work/bin/systemd-run" <<EOF
#!$BASH
printf '%s\\0' "\$@" > "\$APM_TEST_ARGV"
exit 23
EOF
chmod +x "$work/bin/systemd-run"
export APM_TEST_ARGV="$work/host.argv"
export APM_HOST_PATH="$work/host profile:/run/current-system/sw/bin"
export DISPLAY=:9.2 WAYLAND_DISPLAY=wayland-test
rc=0
bash "$work/host-spawn" -- 'command with space' 'literal $HOME' '' $'line1\nline2' || rc=$?
test "$rc" = 23
mapfile -d '' -t argv < "$APM_TEST_ARGV"
has_args --user --quiet --wait --pipe --collect
has_args --expand-environment=no
has_args -E "PATH=/run/wrappers/bin:$APM_HOST_PATH"
has_args -E DISPLAY=:9.2
has_args -E WAYLAND_DISPLAY=wayland-test
test "${argv[-4]}" = 'command with space'
test "${argv[-3]}" = 'literal $HOME'
test "${argv[-2]}" = ''
test "${argv[-1]}" = $'line1\nline2'

# A downloaded base initializer must work without its /bin/bash interpreter.
# All writes stay inside the fixture; the id stub only enables this code path.
(
    source "$package/usr/libexec/apm/apm-install.sh"
    export APM_ROOT="$work/root" APM_BASE_INIT_FORCE=1
    export APM_TEST_INIT_MARKER="$work/base-initialized"
    id() { printf '0\n'; }
    log.info() { :; }
    log.warn() { :; }
    log.error() { :; }
    apm_t() { printf '%s\n' "$1"; }
    files="$APM_ROOT/var/lib/apm/fake-base/files"
    mkdir -p "$files/bin"
    cat > "$files/bin/ace-init" <<'EOF'
#!/nonexistent-apm-test-interpreter
printf '%s\n' "$PACKAGE_NAME" > "$APM_TEST_INIT_MARKER"
EOF
    chmod +x "$files/bin/ace-init"
    touch "$files/ace-env.tar.xz"
    apm_base_init fake-base
    test "$(cat "$APM_TEST_INIT_MARKER")" = fake-base
    test ! -e "$files/ace-env.tar.xz"
    printf '\nexit 27\n' >> "$files/bin/ace-init"
    touch "$files/ace-env.tar.xz"
    if apm_base_init fake-base; then exit 1; fi
    test -e "$files/ace-env.tar.xz"
    chmod -x "$files/bin/ace-init"
    if apm_base_init fake-base; then exit 1; fi
    test -e "$files/ace-env.tar.xz"
)
echo 'PASS: packaged guest paths, loader isolation, host bridge arguments and base initializer'
