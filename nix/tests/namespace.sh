#!/usr/bin/env bash
# Optional host test: requires permission to create a real bubblewrap namespace.
# Usage: bash nix/tests/namespace.sh ./result
# It uses a synthetic rootfs and independent state, without FUSE or host tasks.
set -euo pipefail
package=$(cd -- "${1:?Pass the built APM package directory}" && pwd -P)
body="$package/share/amber-pm/apm/files"
test -r "$body/ace-run-lib.sh"

# Load only the trusted Nix-generated wrapper's dependency search path. The
# actual entry point is not run; the fixture calls its installed library below.
# Bash, coreutils and sed are sufficient to bootstrap this standalone check.
source <(sed '/^exec /,$d' "$body/ace-run")
work=$(mktemp -d "${TMPDIR:-/tmp}/apm-nix-namespace.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/rootfs"/{bin,usr,var/lib/apm,tmp,host,proc,dev,run,nix/store} \
    "$work/host"/{var/lib/apm,nix/store} \
    "$work/state/apm-compat/ace-env/amber-ce-tools" \
    "$work/state/apm-compat/share"
ln -s "$package/share/amber-pm/apm" "$work/state/apm"
ln -s /var/lib/apm/apm-compat/share \
    "$work/state/apm-compat/ace-env/amber-ce-tools/data-dir"
printf 'namespace fixture\n' > "$work/state/apm-compat/share/marker"
ln -s "$(readlink -f "$BASH")" "$work/rootfs/bin/bash"
ln -s "$(readlink -f "$(command -v readlink)")" "$work/rootfs/bin/readlink"
ln -s "$(readlink -f "$(command -v cat)")" "$work/rootfs/bin/cat"

(
    # shellcheck source=/dev/null
    source "$body/ace-run-lib.sh"
    ACE_BWRAP_SETENV=(--setenv PATH "$(ace_container_path)")
    ACE_BWRAP_BINDS=(--dev-bind "$work/rootfs" / \
        --ro-bind "$work/host" /host --dev-bind /tmp /tmp --proc /proc --dev /dev)
    ACE_BWRAP_EXTRA=(--ro-bind /nix/store /host/nix/store \
        --ro-bind "$work/state" /var/lib/apm \
        --ro-bind "$work/state" /host/var/lib/apm)
    ace_run_container bash -euc '
        test "$(cat /var/lib/apm/apm/files/ace-env/amber-ce-tools/data-dir/marker)" = "namespace fixture"
        test "$(cat /host/var/lib/apm/apm/files/ace-env/amber-ce-tools/data-dir/marker)" = "namespace fixture"
        test "$(readlink -f /host/var/lib/apm/apm/files/ace-env/amber-ce-tools/data-dir)" = /var/lib/apm/apm-compat/share
        host-spawn --version
        /host/var/lib/apm/apm/files/amber-ce-tools/bin-override/host-spawn --version
        test "$SHELL" = /bin/bash
        case "$PATH" in *:/usr/sbin:/usr/bin:/sbin:/bin) ;; *) exit 1;; esac
        printf "PASS: real namespace resolves the Store body, compatibility state and host bridge interpreters\n"
    '
)
