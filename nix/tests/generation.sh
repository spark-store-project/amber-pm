#!/usr/bin/env bash
# Exercise both installed CLIs with their real ace-run scripts. Only the
# mount/container boundary is stubbed; no FUSE, root or session is required.
set -euo pipefail
first=$1
second=$2
test "$first" != "$second"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export APM_ROOT="$work/root" HOME="$work/home" TMPDIR="$work/tmp"
export XDG_RUNTIME_DIR="$work/runtime" APM_TEST_RUNNER="$work/runner"
unset APM_STATE_DIR APM_CONF_DIR SUDO_UID PKEXEC_UID
state="$APM_ROOT/var/lib/apm"
mkdir -p "$state/test-base/files/ace-env" "$HOME" "$TMPDIR" "$XDG_RUNTIME_DIR" "$work/bin"

# Wrappers prepend their dependencies to PATH. At each actual Bash entry,
# restore only the mount/container stubs. Record the guest tool path emitted
# by the actual runner, which is derived from that runner's own source path.
# An external bwrap stub is necessary because ace-run uses exec, which cannot
# invoke an exported shell function.
export APM_TEST_BIN="$work/bin" BASH_ENV="$work/bash-env"
cat > "$BASH_ENV" <<'EOF'
export PATH="$APM_TEST_BIN:$PATH"
EOF
printf '#!%s\nexit 0\n' "$BASH" > "$work/bin/fuse-overlayfs"
cat > "$work/bin/bwrap" <<EOF
#!$BASH
printf '%s\\0' "\$@" > "\$APM_TEST_RUNNER"
EOF
chmod +x "$work/bin/"*

cat > "$work/override" <<EOF
#!$BASH
printf '%s\\0' "\$@" > "\$APM_TEST_RUNNER"
exit 27
EOF
chmod +x "$work/override"
for current in "$first" "$second"; do
    if [ "$current" = "$first" ]; then other=$second; else other=$first; fi
    # Switch only the fixture's compatibility entry, never the host's link.
    ln -sfn "$other/share/amber-pm/apm" "$state/apm"
    for cli in "$current/bin/apm" "$current/usr/libexec/apm/apm-main"; do
        # Both unset and empty values use this CLI generation's default.
        for mode in unset empty; do
            rm -f "$APM_TEST_RUNNER"
            if [ "$mode" = unset ]; then unset APM_RUN_EXEC; else export APM_RUN_EXEC=""; fi
            "$cli" run test-base true > "$work/stdout" 2> "$work/stderr" || {
                cat "$work/stderr" >&2
                exit 1
            }
            mapfile -d '' -t argv < "$APM_TEST_RUNNER"
            guest_path=""
            for ((i=0; i+2<${#argv[@]}; i++)); do
                if [ "${argv[i]}" = --setenv ] && [ "${argv[i+1]}" = PATH ]; then
                    guest_path=${argv[i+2]}
                fi
            done
            test "${guest_path%%:*}" = "/host$current/share/amber-pm/apm/files/amber-ce-tools/bin-override"
        done
        # Explicit overrides must still execute, preserve argv and return status.
        export APM_RUN_EXEC="$work/override"
        status=0
        "$cli" run test-base 'literal $HOME' '' $'line1\nline2' \
            > "$work/stdout" 2> "$work/stderr" || status=$?
        test "$status" = 27
        printf '%s\0' 'literal $HOME' '' $'line1\nline2' > "$work/expected"
        cmp "$work/expected" "$APM_TEST_RUNNER"
    done
done
echo 'PASS: two Store generations use their own runner through wrapped and direct CLIs, preserving explicit overrides'
