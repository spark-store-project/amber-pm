#!/bin/bash
# Nix-only implementation of the existing desktop/dstore triggers. All
# generated files live outside the immutable body and outside /usr and /etc.
set -euo pipefail

APM_STATE_DIR="${APM_STATE_DIR:-${APM_ROOT:-}/var/lib/apm}"
APM_STATE_DIR="${APM_STATE_DIR%/}"
compat="$APM_STATE_DIR/apm-compat"
share="$compat/share"
xdg="$compat/xdg"
mkdir -p "$share" "$xdg/autostart"
exec 9>"$compat/desktop.lock"
flock -x 9

# Only remove our own dangling links; never clean another package manager's
# integration directories. This also handles files removed during upgrades.
while IFS= read -r -d '' link; do
    target="$(readlink -- "$link")"
    case "$target" in
        "$APM_STATE_DIR"/*) [ -e "$link" ] || rm -f -- "$link" ;;
    esac
done < <(find "$share" "$xdg" -type l -print0)

link_tree() {
    local source="$1" destination="$2" file relative
    [ -d "$source" ] || return 0
    while IFS= read -r -d '' file; do
        relative="${file#"$source"/}"
        mkdir -p -- "$(dirname -- "$destination/$relative")"
        ln -sfn -- "$file" "$destination/$relative"
    done < <(find -L "$source" -type f -print0)
}

for package in "$APM_STATE_DIR"/*; do
    [ -d "$package/entries" ] || continue
    case "${package##*/}" in apm | apm-conf | apm-compat) continue ;; esac
    entries="$package/entries"
    # Keep Spark/Deepin's existing uninstall fields on the imperative package
    # files. No application executable is launched by these triggers.
    if [ -d "$entries/applications" ]; then
        while IFS= read -r -d '' desktop; do
            grep -q '^X-APM-APPID=' "$desktop" ||
                printf 'X-APM-APPID=%s\n' "${package##*/}" >> "$desktop"
            grep -q '^X-Deepin-PreUninstall=' "$desktop" ||
                printf 'X-Deepin-PreUninstall=amber-pm-app-uninstaller %s\n' "${package##*/}" >> "$desktop"
        done < <(find "$entries/applications" -type f -name '*.desktop' -print0)
    fi
    for directory in applications icons mime glib-2.0 services pixmaps GConf help locale fcitx fonts dbus-1 templates; do
        link_tree "$entries/$directory" "$share/$directory"
    done
    link_tree "$entries/autostart" "$xdg/autostart"
    # Some Spark packages use entries/services for D-Bus activation files.
    link_tree "$entries/services" "$share/dbus-1/services"
done

mkdir -p "$share/applications" "$share/mime/packages" "$share/glib-2.0/schemas"
update-desktop-database "$share/applications"
XDG_DATA_DIRS="$share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" \
    update-mime-database "$share/mime"
glib-compile-schemas "$share/glib-2.0/schemas" >/dev/null
