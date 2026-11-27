#!/usr/bin/env bash
set -euo pipefail
package=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export APM_STATE_DIR="$work/state"
entries="$APM_STATE_DIR/test-app/entries"
mkdir -p "$entries"/{applications,icons/hicolor/48x48/apps,autostart,mime/packages}
cat > "$entries/applications/test.desktop" <<'EOF'
[Desktop Entry]
Name=Test application
Type=Application
Exec=apm run test-app test
EOF
cp "$entries/applications/test.desktop" "$entries/autostart/test.desktop"
printf 'icon\n' > "$entries/icons/hicolor/48x48/apps/test.png"
cat > "$entries/mime/packages/test.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-apm-test"><glob pattern="*.apm-test"/></mime-type>
</mime-info>
EOF
"$package/bin/amber-pm-dstore-patch"
share="$APM_STATE_DIR/apm-compat/share"
test -L "$share/applications/test.desktop"
test -L "$share/icons/hicolor/48x48/apps/test.png"
test -L "$APM_STATE_DIR/apm-compat/xdg/autostart/test.desktop"
grep -q 'X-APM-APPID=test-app' "$share/applications/test.desktop"
test -f "$share/mime/mime.cache"
"$package/bin/amber-pm-desktop-fix"
test "$(grep -c '^X-APM-APPID=' "$entries/applications/test.desktop")" = 1
rm -rf "$APM_STATE_DIR/test-app"
"$package/bin/amber-pm-desktop-fix"
test ! -L "$share/applications/test.desktop"
test ! -L "$share/icons/hicolor/48x48/apps/test.png"
test ! -L "$APM_STATE_DIR/apm-compat/xdg/autostart/test.desktop"
echo 'PASS: desktop installation, caches, idempotence and removal in isolated state'
