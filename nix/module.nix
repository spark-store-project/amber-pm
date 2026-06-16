{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.amber-pm;
  apmXdgDataDir = "/var/lib/apm/apm/files/ace-env/amber-ce-tools/data-dir";

  aceRuntimePath = lib.makeBinPath (with pkgs; [
    bash
    bubblewrap
    coreutils
    gawk
    gnugrep
    gnused
    gnutar
    sudo
  ]);
in
{
  options.programs.amber-pm = {
    enable = lib.mkEnableOption "Amber Package Manager";

    package = lib.mkPackageOption pkgs "amber-pm" { };

    initializeState = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create /var/lib/apm/apm during system activation when it does not already exist.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    environment.sessionVariables.XDG_DATA_DIRS = lib.mkAfter [ apmXdgDataDir ];
    environment.etc."systemd/user-environment-generators/60-apm".source =
      pkgs.writeShellScript "60-apm" ''
        apm_xdg_data_dir=${lib.escapeShellArg apmXdgDataDir}
        xdg_data_dirs="''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

        case ":$xdg_data_dirs:" in
          *":$apm_xdg_data_dir:"*) ;;
          *) xdg_data_dirs="$xdg_data_dirs:$apm_xdg_data_dir" ;;
        esac

        printf 'XDG_DATA_DIRS=%s\n' "$xdg_data_dirs"
      '';

    programs.nix-ld.enable = lib.mkDefault true;

    boot.kernel.sysctl."kernel.apparmor_restrict_unprivileged_userns" = lib.mkDefault 0;

    system.activationScripts.amber-pm-state = lib.mkIf cfg.initializeState ''
      export PATH="${aceRuntimePath}:$PATH"
      target="/var/lib/apm/apm"
      version_file="$target/.amber-pm-version"
      current_version="${cfg.package.version}"

      if [ ! -e "$target" ]; then
        echo "APM state directory not found, initializing..."
        ${cfg.package}/bin/amber-pm-init-state
        echo "Running ace-init for first-time setup..."
        /var/lib/apm/apm/files/bin/ace-init
      elif [ -f "$version_file" ]; then
        stored_version="$(cat "$version_file")"
        if [ "$stored_version" != "$current_version" ]; then
          echo "APM version changed ($stored_version -> $current_version), re-initializing..."
          ${cfg.package}/bin/amber-pm-init-state --force
          echo "Running ace-init..."
          /var/lib/apm/apm/files/bin/ace-init
        else
          echo "APM version unchanged ($current_version), skipping ace-init."
        fi
      else
        echo "No version file found, refreshing state and running ace-init..."
        ${cfg.package}/bin/amber-pm-init-state --force
        /var/lib/apm/apm/files/bin/ace-init
      fi
    '';
  };
}
