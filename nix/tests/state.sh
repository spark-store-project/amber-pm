#!/usr/bin/env bash
set -euo pipefail
# Usage: bash nix/tests/state.sh ./result
# Source the built Nix package so the test verifies its applied patches.
package="$(realpath -- "${1:-./result}")"
libdir="$package/usr/libexec/apm"
[ -r "$libdir/apm-install.sh" ] || {
    echo "Build the Nix package first, then pass its output path." >&2
    exit 1
}
export PATH="$package/bin:$PATH"
unset APM_STATE_DIR APM_CONF_DIR
export APM_ROOT
APM_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/apm-nix-state-root.XXXXXX")
trap 'rm -rf "$APM_ROOT"' EXIT
source "$libdir/apm-lib.sh"
source "$libdir/apm-deb.sh"
source "$libdir/apm-db.sh"
source "$libdir/apm-install.sh"
source "$libdir/apm-migrate.sh"
apm_state_init
for reserved in apm apm-conf apm-compat; do
    if apm_install_deb /not/a/file "$reserved" 0 install 1 2>/dev/null; then exit 1; fi
    if apm_remove_pkg "$reserved" 1 2>/dev/null; then exit 1; fi
    if _apm_path_allowed - "var/lib/apm/$reserved/info_layer_addons.d/test" fake; then exit 1; fi
done
_apm_path_allowed - var/lib/apm/fake-base/info_layer_addons.d/test fake-addon
mkdir -p "$APM_DB_DIR/apm"
printf 'Package: apm\nVersion: 1.0\nAuto: 1\n' > "$APM_DB_DIR/apm/status"
if apm_db_installed apm; then exit 1; fi
[ -z "$(apm_db_list)" ]
[ -z "$(apm_autoremove_plan)" ]
test -s "$APM_DB_DIR/apm/status"
mkdir -p "$APM_STATE_DIR/apm/files" "$APM_STATE_DIR/apm-compat/ace-env"
ln -s "$APM_STATE_DIR/apm-compat/ace-env" "$APM_STATE_DIR/apm/files/ace-env"
printf retained > "$APM_STATE_DIR/apm-compat/ace-env/marker"
if apm_cmd_migrate >/dev/null 2>&1; then exit 1; fi
test -L "$APM_STATE_DIR/apm/files/ace-env"
test -s "$APM_STATE_DIR/apm-compat/ace-env/marker"
# Old packages can retain outside-path records from before Nix deployment.
# Test both uninstall and obsolete-file cleanup on upgrade, while ensuring
# ordinary outside files still get removed.
mv "$APM_STATE_DIR/apm" "$APM_ROOT/body"
ln -s "$APM_ROOT/body" "$APM_STATE_DIR/apm"
printf retained > "$APM_STATE_DIR/apm/files/retained"
printf retained > "$APM_STATE_DIR/apm-conf/retained"
printf retained > "$APM_STATE_DIR/apm-compat/retained"
mkdir -p "$APM_DB_DIR/other-app" "$APM_ROOT/usr/local/share"
printf '/var/lib/apm/other-app/shared\n' > "$APM_DB_DIR/other-app/files.list"
for cleanup in remove upgrade; do
    old_package="old-$cleanup"
    mkdir -p "$APM_STATE_DIR/$old_package" "$APM_DB_DIR/$old_package"
    printf 'Package: %s\nVersion: 1\nAuto: 0\n' "$old_package" > "$APM_DB_DIR/$old_package/status"
    cat > "$APM_DB_DIR/$old_package/files.list" <<EOF
/var/lib/apm/apm
/var/lib/apm/apm/files/retained
/var/lib/apm/apm-conf/retained
/var/lib/apm/apm-compat/retained
/usr/local/share/apm-$cleanup-obsolete
EOF
    touch "$APM_ROOT/usr/local/share/apm-$cleanup-obsolete"
    if [ "$cleanup" = remove ]; then
        apm_remove_pkg "$old_package" 1 >/dev/null
    else
        : > "$APM_ROOT/new-files.list"
        _apm_remove_obsolete_files "$old_package" "$APM_ROOT/new-files.list"
    fi
    test -L "$APM_STATE_DIR/apm"
    for marker in apm/files/retained apm-conf/retained apm-compat/retained; do
        test "$(cat "$APM_STATE_DIR/$marker")" = retained
    done
    test ! -e "$APM_ROOT/usr/local/share/apm-$cleanup-obsolete"
done

# Build a real payload trying to cross into the program's immutable directory.
mkdir -p "$APM_ROOT/control" "$APM_ROOT/build/var/lib/apm/apm/files"
printf 'Package: fake-overwrite\nVersion: 1\nArchitecture: all\nMaintainer: Test <test@example.com>\nDescription: test\n' > "$APM_ROOT/control/control"
printf evil > "$APM_ROOT/build/var/lib/apm/apm/files/marker"
tar -cf "$APM_ROOT/control.tar" -C "$APM_ROOT/control" .
tar -cf "$APM_ROOT/data.tar" -C "$APM_ROOT/build" .
printf '2.0\n' > "$APM_ROOT/debian-binary"
# Use the same small ar writer as tests/native-pkg-test.sh; no dpkg is needed.
{
    printf '!<arch>\n'
    for member in debian-binary control.tar data.tar; do
        size="$(wc -c < "$APM_ROOT/$member" | tr -d ' ')"
        printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$member" 0 0 0 100644 "$size"
        cat "$APM_ROOT/$member"
        if [ $((size % 2)) -eq 1 ]; then printf '\n'; fi
    done
} > "$APM_ROOT/evil.deb"
if apm_install_deb "$APM_ROOT/evil.deb" fake-overwrite 0 install 1 >/dev/null 2>&1; then exit 1; fi
test ! -e "$APM_STATE_DIR/apm/files/marker"
test ! -e "$APM_DB_DIR/fake-overwrite/status"
echo 'state boundary checks passed'
