# Ensure the standard XDG data directories are present even on minimal hosts.
if [ -z "${XDG_DATA_DIRS:-}" ]; then
    XDG_DATA_DIRS="/usr/local/share:/usr/share"
fi

# APM apps are integrated into the host desktop through this data directory.
# Keep it in XDG_DATA_DIRS so desktop environments can find APM applications
# and icons even when they are not installed under /usr/share.
apm_xdg_data_dir="/var/lib/apm/apm/files/ace-env/amber-ce-tools/data-dir"
case ":${XDG_DATA_DIRS}:" in
    *":${apm_xdg_data_dir}:"*) ;;
    *) XDG_DATA_DIRS="${XDG_DATA_DIRS}:${apm_xdg_data_dir}" ;;
esac
export XDG_DATA_DIRS
