#!/bin/bash
# Older Spark clients query update metadata through the former management
# environment. Support only their read-only apt download --print-uris request.
# This is not a shell or an apt frontend: no command or config is evaluated.
set -euo pipefail

usage() {
    echo 'Usage: amber-pm-debug apt [-c ignored-config] download <package>... --print-uris' >&2
    echo 'Read-only Spark compatibility; use apm debug for diagnostics.' >&2
}
if [ "${1:-}" = --help ]; then usage; exit 0; fi
case "${1:-}" in
    apt | apt-get | /usr/bin/apt | /usr/bin/apt-get) shift ;;
    *) usage; exit 2 ;;
esac
command_seen=0
print_uris=0
packages=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c | --config-file)
            # The config belonged to the removed Debian management rootfs.
            # Repository selection now comes exclusively from APM's cache.
            [ "$#" -ge 2 ] || { usage; exit 2; }
            shift 2
            ;;
        --print-uris | --print-uri) print_uris=1; shift ;;
        -*) usage; exit 2 ;;
        *)
            if [ "$command_seen" = 0 ]; then
                [ "$1" = download ] || { usage; exit 2; }
                command_seen=1
            else
                [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]] || { usage; exit 2; }
                packages+=("$1")
            fi
            shift
            ;;
    esac
done
[ "$command_seen" = 1 ] && [ "$print_uris" = 1 ] && [ "${#packages[@]}" -gt 0 ] || {
    usage; exit 2
}

_apm_lib_dir='@APM_LIB_DIR@'
source "$_apm_lib_dir/apm-lib.sh"
source "$_apm_lib_dir/apm-repo.sh"
[ -s "$APM_PACKAGES_FILE" ] && [ -r "$APM_PACKAGES_FILE" ] || {
    echo 'amber-pm-debug: repository metadata missing; run sudo apm update first.' >&2
    exit 1
}
for package in "${packages[@]}"; do
    filename=$(apm_repo_filename "$package")
    size=$(apm_repo_size "$package")
    sha512=$(apm_repo_field "$package" SHA512)
    [[ -n "$filename" && "$size" =~ ^[0-9]+$ && "$sha512" =~ ^[[:xdigit:]]{128}$ ]] || {
        echo "amber-pm-debug: missing package or SHA512 metadata: $package" >&2
        exit 1
    }
    printf "'%s' %s %s SHA512:%s\n" "$(apm_repo_pkg_url "$package")" \
        "$(basename -- "$filename")" "$size" "$sha512"
done
