#!/usr/bin/env bash
# Optional live test after deployment. Requires FUSE and user namespaces.
# Usage: bash nix/tests/deployed.sh [installed-base] [package-output]
# All writable package state and initialization payloads are private fixtures.
set -Eeuo pipefail
base=${1:-amber-pm-trixie}
package=${2:-$(dirname "$(dirname "$(readlink -f "$(command -v apm)")")")}
base_root="/var/lib/apm/$base/files/ace-env"
base_init="/var/lib/apm/$base/files/bin/ace-init"
test -d "$base_root"
test -x "$base_init"
test -c /dev/fuse
source <(sed '/^exec /,$d' "$package/bin/apm")
export APM_RUN_EXEC="$package/share/amber-pm/apm/files/ace-run"
bash_bin=$(readlink -f "$BASH")
cmp_bin=$(readlink -f "$(command -v cmp)")
work=$(mktemp -d "${TMPDIR:-/tmp}/apm-deployed.XXXXXX")
child=""
cleanup() {
    local mount
    if [ -n "$child" ]; then
        touch "$work/release"
        wait "$child" 2>/dev/null || true
    fi
    for mount in "$work/runtime/apm-run/apm-live-app" "$work"/tmp/apm-mnt-*; do
        if mountpoint -q "$mount" && ! fusermount3 -u "$mount"; then
            printf 'Could not unmount fixture; retained %s\n' "$work" >&2
            return
        fi
    done
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'test ! -f "$work/first.log" || cat "$work/first.log" >&2' ERR
mkdir -p "$work"/{home,runtime,tmp,init-state/apm-live-init/files/bin}
export HOME="$work/home" XDG_RUNTIME_DIR="$work/runtime" TMPDIR="$work/tmp"

# Run the real installed initializer as UID 0 only inside a user namespace.
# Its fixed /var/lib/apm paths resolve to a writable fixture, never host data.
files="$work/init-state/apm-live-init/files"
cp "$base_init" "$files/bin/ace-init"
mkdir -p "$files/amber-ce-tools/bin-override" "$work/payload/ace-env/etc"
cp "$package/share/amber-pm/apm/files/amber-ce-tools/bin-override/host-spawn" \
    "$files/amber-ce-tools/bin-override/host-spawn"
cat > "$work/initialize.sh" <<'EOF'
set -euo pipefail
unset APM_STATE_DIR APM_CONF_DIR
export APM_ROOT="" APM_NO_TRIGGERS=1
source "$1/usr/libexec/apm/apm-lib.sh"
source "$1/usr/libexec/apm/apm-install.sh"
apm_base_init apm-live-init
test "$(cat /var/lib/apm/apm-live-init/files/ace-env/etc/apm-live-version)" = "$2"
test ! -e /var/lib/apm/apm-live-init/files/ace-env.tar.xz
"$3" /etc/passwd /var/lib/apm/apm-live-init/files/ace-env/etc/passwd
"$3" /etc/localtime /var/lib/apm/apm-live-init/files/ace-env/etc/localtime
test -d /var/lib/apm/apm-live-init/files/ace-env/amber-ce-tools
EOF
for version in 1 2; do
    printf '%s\n' "$version" > "$work/payload/ace-env/etc/apm-live-version"
    tar --owner=0 --group=0 -cJf "$files/ace-env.tar.xz" -C "$work/payload" ace-env
    bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / \
        --proc /proc --dev /dev --tmpfs /run --tmpfs /var --dir /var/lib \
        --bind "$work/init-state" /var/lib/apm --bind "$work" "$work" \
        "$bash_bin" "$work/initialize.sh" "$package" "$version" "$cmp_bin" > "$work/initialize-$version.log" 2>&1 || {
        cat "$work/initialize-$version.log" >&2
        exit 1
    }
done
echo 'PASS: installed base initializer extracts and upgrades inside isolated /var/lib/apm'

# Use the actual base as a read-only lower layer with a private application.
export APM_ROOT="$work/root" APM_NO_TRIGGERS=1 APM_HOME_DIRS="$work/home"
unset APM_STATE_DIR APM_CONF_DIR
state="$APM_ROOT/var/lib/apm"
mkdir -p "$state/apm-live-base/files" "$state/apm-live-app/files"/{core/opt/apm-live,work}
ln -s "$base_root" "$state/apm-live-base/files/ace-env"
printf 'apm-live-base\n' > "$state/apm-live-app/info"
apm_cmd() { "$package/bin/apm" "$@"; }
apm_cmd run apm-live-base bash -euc 'printf temporary > /apm-live-discard' > "$work/base.log" 2>&1
test ! -e "$base_root/apm-live-discard"
apm_cmd run apm-live-app bash -euc 'printf persistent > /opt/apm-live/marker' > "$work/persist.log" 2>&1
test "$(cat "$state/apm-live-app/files/core/opt/apm-live/marker")" = persistent

apm_cmd run apm-live-app bash -euc '
    test "$(cat /opt/apm-live/marker)" = persistent
    : > "$1/ready"
    while [ ! -e "$1/release" ]; do sleep 0.05; done
' -- "$work" > "$work/first.log" 2>&1 &
child=$!
for ((i=0; i<200; i++)); do
    [ ! -e "$work/ready" ] || break
    kill -0 "$child"
    sleep 0.05
done
test -e "$work/ready"
apm_cmd run apm-live-app bash -euc 'test "$(cat /opt/apm-live/marker)" = persistent' > "$work/second.log" 2>&1
mountpoint -q "$XDG_RUNTIME_DIR/apm-run/apm-live-app"
touch "$work/release"
wait "$child"
child=""
if mountpoint -q "$XDG_RUNTIME_DIR/apm-run/apm-live-app"; then
    echo 'Shared overlay remained mounted after the last instance exited' >&2
    exit 1
fi
test -z "$(find "$TMPDIR" -maxdepth 1 \( -name 'apm-overlay-*' -o -name 'apm-mnt-*' \) -print -quit)"
echo 'PASS: real FUSE writes persist for applications, discard for bases, and concurrent instances clean up'

# Only execute an argument recorder through the real user manager. Disable
# systemd's own variable expansion as well as shell interpretation.
status=0
apm_cmd run apm-live-base host-spawn bash -c 'printf "%s\0" "$@"; exit 23' -- \
    'a b' 'literal $HOME' '${HOME}' '$$' '$(printf unwanted)' '%i %u' '' \
    $'quote\" and newline\nnext' > "$work/host.actual" 2> "$work/host.log" || status=$?
test "$status" = 23
printf '%s\0' 'a b' 'literal $HOME' '${HOME}' '$$' '$(printf unwanted)' '%i %u' '' \
    $'quote\" and newline\nnext' > "$work/host.expected"
"$cmp_bin" "$work/host.expected" "$work/host.actual"
echo 'PASS: real host-spawn preserves literal arguments and exit status'
