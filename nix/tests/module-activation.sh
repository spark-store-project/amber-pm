#!/usr/bin/env bash
# Execute the module's generated activation snippet against isolated state.
set -Eeuo pipefail

activation_source=$1
package=$2
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
trap 'test ! -f "$sandbox/activation.log" || cat "$sandbox/activation.log" >&2' ERR
state="$sandbox/var/lib/apm"
mkdir -p "$state"
export APM_STATE_DIR="$state"
export XDG_DATA_DIRS="$state/apm-compat/share"
export XDG_CONFIG_DIRS="$state/apm-compat/xdg"
sed "s|/var/lib/apm|$state|g" "$activation_source" > "$sandbox/activate"

activate() {
    bash "$sandbox/activate" > "$sandbox/activation.log" 2>&1
}

# Existing payloads must survive failed activation, including their contents.
mkdir "$state/apm"
printf 'preserve\n' > "$state/apm/sentinel"
if activate; then
    echo "Activation replaced a real APM directory" >&2
    exit 1
fi
test "$(cat "$state/apm/sentinel")" = preserve
grep -q 'existing data directory' "$sandbox/activation.log"
rm "$state/apm/sentinel"
rmdir "$state/apm"

ln -s "$sandbox/unmanaged" "$state/apm"
if activate; then
    echo "Activation replaced an unmanaged APM link" >&2
    exit 1
fi
test "$(readlink "$state/apm")" = "$sandbox/unmanaged"
rm "$state/apm"

# Initial activation and repeated activation create no copied program tree.
activate
expected="$package/share/amber-pm/apm"
test "$(readlink "$state/apm")" = "$expected"
test "$(readlink "$state/apm-compat/ace-env/amber-ce-tools/data-dir")" = "$state/apm-compat/share"
printf 'application data\n' > "$state/apm-compat/sentinel"
activate
test "$(readlink "$state/apm")" = "$expected"

# A generation change only changes the body link. Retained state survives
# switching forward and back, even if the previous store target is absent.
next=/nix/store/apm-test-generation/share/amber-pm/apm
sed "s|$expected|$next|g" "$sandbox/activate" > "$sandbox/next"
bash "$sandbox/next" > "$sandbox/activation.log" 2>&1
test "$(readlink "$state/apm")" = "$next"
activate
test "$(readlink "$state/apm")" = "$expected"
test "$(cat "$state/apm-compat/sentinel")" = 'application data'
test -z "$(find "$state" -maxdepth 1 -name '.apm-link.*' -print -quit)"

# A conflicting compatibility directory is retained as well.
data_link="$state/apm-compat/ace-env/amber-ce-tools/data-dir"
rm "$data_link"
mkdir "$data_link"
printf 'preserve\n' > "$data_link/sentinel"
if activate; then
    echo "Activation replaced compatibility data" >&2
    exit 1
fi
test "$(cat "$data_link/sentinel")" = preserve

echo "PASS: module activation refuses conflicts and preserves state across switching and rollback"
