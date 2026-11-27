#!/usr/bin/env bash
# Execute the module's generated activation snippet against isolated state.
set -Eeuo pipefail

activation_source=$1
deactivation_source=$2
package=$3
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
trap 'test ! -f "$sandbox/activation.log" || cat "$sandbox/activation.log" >&2' ERR
state="$sandbox/var/lib/apm"
mkdir -p "$state"
export APM_ROOT="$sandbox" APM_STATE_DIR="$state"
unset APM_CONF_DIR
export XDG_DATA_DIRS="$state/apm-compat/share"
export XDG_CONFIG_DIRS="$state/apm-compat/xdg"
sed "s|/var/lib/apm|$state|g" "$activation_source" > "$sandbox/activate"
sed "s|/var/lib/apm|$state|g" "$deactivation_source" > "$sandbox/deactivate"

activate() {
    bash "$sandbox/activate" > "$sandbox/activation.log" 2>&1
}
deactivate() {
    bash "$sandbox/deactivate" > "$sandbox/activation.log" 2>&1
}

# A disabled module must not initialize state, even on a fresh machine.
rmdir "$state"
deactivate
deactivate
test ! -e "$state"
mkdir "$state"

# Existing payloads must survive failed activation, including their contents.
mkdir "$state/apm"
printf 'preserve\n' > "$state/apm/sentinel"
if activate; then
    echo "Activation replaced a real APM directory" >&2
    exit 1
fi
test "$(cat "$state/apm/sentinel")" = preserve
grep -q 'existing data directory' "$sandbox/activation.log"
deactivate
test "$(cat "$state/apm/sentinel")" = preserve
rm "$state/apm/sentinel"
rmdir "$state/apm"

ln -s "$sandbox/unmanaged" "$state/apm"
if activate; then
    echo "Activation replaced an unmanaged APM link" >&2
    exit 1
fi
test "$(readlink "$state/apm")" = "$sandbox/unmanaged"
deactivate
test "$(readlink "$state/apm")" = "$sandbox/unmanaged"
rm "$state/apm"

# Preserve files, valid unmanaged links and deceptive nested Store paths.
printf 'not a link\n' > "$state/apm"
deactivate
test "$(cat "$state/apm")" = 'not a link'
rm "$state/apm"
ln -s "$sandbox" "$state/apm"
deactivate
test "$(readlink "$state/apm")" = "$sandbox"
rm "$state/apm"
for unmanaged in /nix/store/unmanaged/subdir/share/amber-pm/apm \
    /nix/store/../share/amber-pm/apm /nix/store/not-a-store-output/share/amber-pm/apm; do
    ln -s "$unmanaged" "$state/apm"
    deactivate
    test "$(readlink "$state/apm")" = "$unmanaged"
    if activate; then
        echo "Activation accepted an unmanaged Store link: $unmanaged" >&2
        exit 1
    fi
    rm "$state/apm"
done

# Existing migrated packages need their old Icon= paths on first activation.
mkdir -p "$state/legacy-app/entries/applications" "$state/legacy-app/files/core" \
    "$state/apm-conf/db/legacy-app" "$state/test-base/files/ace-env"
printf 'Package: legacy-app\nVersion: 1\n' > "$state/apm-conf/db/legacy-app/status"
printf 'icon data\n' > "$state/legacy-app/files/core/icon.png"
printf 'base data\n' > "$state/test-base/files/ace-env/sentinel"
cat > "$state/legacy-app/entries/applications/legacy.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Legacy application
Exec=apm run legacy-app test
Icon=/var/lib/apm/apm/files/ace-env/var/lib/apm/legacy-app/files/core/icon.png
EOF

# Initial activation and repeated activation create no copied program tree.
activate
expected="$package/share/amber-pm/apm"
test "$(readlink "$state/apm")" = "$expected"
test "$(readlink "$state/apm-compat/ace-env/amber-ce-tools/data-dir")" = "$state/apm-compat/share"
legacy="$state/apm-compat/ace-env/var/lib/apm"
test "$(cat "$legacy/legacy-app/files/core/icon.png")" = 'icon data'
printf 'application data\n' > "$state/apm-compat/sentinel"
activate
test "$(readlink "$state/apm")" = "$expected"

# A generation change only changes the body link. Retained state survives
# switching forward and back, even if the previous store target is absent.
next=/nix/store/00000000000000000000000000000000-apm-test-generation/share/amber-pm/apm
sed "s|$expected|$next|g" "$sandbox/activate" > "$sandbox/next"
bash "$sandbox/next" > "$sandbox/activation.log" 2>&1
test "$(readlink "$state/apm")" = "$next"
activate
test "$(readlink "$state/apm")" = "$expected"
test "$(cat "$state/apm-compat/sentinel")" = 'application data'
test -z "$(find "$state" -maxdepth 1 -name '.apm-link.*' -print -quit)"

# Disable and re-enable, also handling already dangling generation links.
deactivate
test ! -L "$state/apm"
test "$(cat "$state/legacy-app/files/core/icon.png")" = 'icon data'
test -f "$state/apm-conf/db/legacy-app/status"
test "$(cat "$state/test-base/files/ace-env/sentinel")" = 'base data'
test "$(cat "$state/apm-compat/sentinel")" = 'application data'
deactivate
activate
test "$(readlink "$state/apm")" = "$expected"
test "$(cat "$legacy/legacy-app/files/core/icon.png")" = 'icon data'
ln -sfn "$next" "$state/apm"
test ! -e "$state/apm"
deactivate
test ! -L "$state/apm"
activate
test "$(readlink "$state/apm")" = "$expected"

# The legacy helper must preserve pre-existing real compatibility data.
rm "$legacy/legacy-app"
mkdir "$legacy/legacy-app"
printf 'legacy data\n' > "$legacy/legacy-app/sentinel"
activate
test ! -L "$legacy/legacy-app"
test "$(cat "$legacy/legacy-app/sentinel")" = 'legacy data'

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

echo "PASS: activation, disable/re-enable and dangling-link cleanup preserve data and repair migrated icons"
