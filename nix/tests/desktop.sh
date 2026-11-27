#!/usr/bin/env bash
set -euo pipefail
package=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export APM_STATE_DIR="$work/state"
export APM_ROOT="$work/unrelated-root"
unset APM_CONF_DIR
entries="$APM_STATE_DIR/test-app/entries"
mkdir -p "$entries"/{applications,icons/hicolor/48x48/apps,autostart,mime/packages}
cat > "$entries/applications/test.desktop" <<'EOF'
[Desktop Entry]
Name=Test application
Type=Application
Exec=apm run test-app test
Icon=/var/lib/apm/apm/files/ace-env/var/lib/apm/test-app/entries/icons/hicolor/48x48/apps/test.png
EOF
cp "$entries/applications/test.desktop" "$entries/autostart/test.desktop"
printf 'icon\n' > "$entries/icons/hicolor/48x48/apps/test.png"
cat > "$entries/mime/packages/test.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-apm-test"><glob pattern="*.apm-test"/></mime-type>
</mime-info>
EOF
mkdir -p "$APM_STATE_DIR/apm-conf/db/test-app"
printf 'Package: test-app\nVersion: 1\n' > "$APM_STATE_DIR/apm-conf/db/test-app/status"
legacy="$APM_STATE_DIR/apm-compat/ace-env/var/lib/apm"
mkdir -p "$legacy/preserve-app" "$APM_STATE_DIR/preserve-app/entries/applications" \
    "$APM_STATE_DIR/apm-conf/db/preserve-app"
printf 'real data\n' > "$legacy/preserve-app/sentinel"
printf 'Package: preserve-app\nVersion: 1\n' > "$APM_STATE_DIR/apm-conf/db/preserve-app/status"
sed 's/test-app/preserve-app/g' "$entries/applications/test.desktop" \
    > "$APM_STATE_DIR/preserve-app/entries/applications/preserve.desktop"
"$package/bin/amber-pm-dstore-patch"
share="$APM_STATE_DIR/apm-compat/share"
test -L "$share/applications/test.desktop"
test -L "$share/icons/hicolor/48x48/apps/test.png"
test -L "$APM_STATE_DIR/apm-compat/xdg/autostart/test.desktop"
grep -q 'X-APM-APPID=test-app' "$share/applications/test.desktop"
test -f "$share/mime/mime.cache"
test "$(readlink "$legacy/test-app")" = "$APM_STATE_DIR/test-app"
cmp "$legacy/test-app/entries/icons/hicolor/48x48/apps/test.png" \
    "$entries/icons/hicolor/48x48/apps/test.png"
test ! -L "$legacy/preserve-app"
test "$(cat "$legacy/preserve-app/sentinel")" = 'real data'
test ! -e "$APM_ROOT"
"$package/bin/amber-pm-desktop-fix"
test "$(grep -c '^X-APM-APPID=' "$entries/applications/test.desktop")" = 1
test "$(readlink "$legacy/test-app")" = "$APM_STATE_DIR/test-app"
rm -rf "$APM_STATE_DIR/test-app" "$APM_STATE_DIR/apm-conf/db/test-app"
"$package/bin/amber-pm-desktop-fix"
test ! -L "$share/applications/test.desktop"
test ! -L "$share/icons/hicolor/48x48/apps/test.png"
test ! -L "$APM_STATE_DIR/apm-compat/xdg/autostart/test.desktop"
test ! -L "$legacy/test-app"
test "$(cat "$legacy/preserve-app/sentinel")" = 'real data'
test ! -e "$APM_ROOT"
echo 'PASS: desktop refresh repairs legacy icons in isolated state, preserves real data and cleans removed links'
