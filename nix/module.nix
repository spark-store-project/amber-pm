{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.amber-pm;
  compatDir = "/var/lib/apm/apm-compat";
  dataDir = "${compatDir}/share";
  configDir = "${compatDir}/xdg";
  stateDirectories = [
    "/var/lib/apm"
    compatDir
    "${compatDir}/ace-env/var/lib/apm"
    "${compatDir}/ace-env/amber-ce-tools"
    "${dataDir}/applications"
    "${dataDir}/icons"
    "${dataDir}/mime/packages"
    "${dataDir}/glib-2.0/schemas"
    "${dataDir}/dbus-1/services"
    "${configDir}/autostart"
  ];
in
{
  options.programs.amber-pm = {
    enable = lib.mkEnableOption "Amber Package Manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = ''
        APM package to expose at /var/lib/apm/apm. Only APM itself is managed
        by NixOS; application and base packages remain managed by APM.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (!cfg.enable) {
      # Keep this activation step when disabled, without retaining the APM
      # package in the closure. readlink also recognizes a GC'd store target;
      # remove only the link itself, never follow it or touch mutable state.
      system.activationScripts.amber-pm-state = {
        deps = [ "specialfs" ];
        text = ''
          (
            set -eu
            target=/var/lib/apm/apm
            if [ -L "$target" ] && [[ "$(${pkgs.coreutils}/bin/readlink "$target")" =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+/share/amber-pm/apm$ ]]; then
              ${pkgs.coreutils}/bin/rm -- "$target"
            fi
          )
        '';
      };
    })
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];

      # Keep mutable desktop integration outside both the Nix store and the
      # system profile. Entries are maintained by APM's install/remove triggers.
      environment.sessionVariables = {
        XDG_DATA_DIRS = lib.mkAfter [ dataDir ];
        XDG_CONFIG_DIRS = lib.mkAfter [ configDir ];
      };
      environment.etc."systemd/user-environment-generators/60-apm".source =
        pkgs.writeShellScript "60-apm" ''
          xdg_data_dirs="''${XDG_DATA_DIRS:-/run/current-system/sw/share:/usr/local/share:/usr/share}"
          xdg_config_dirs="''${XDG_CONFIG_DIRS:-/etc/xdg}"
          case ":$xdg_data_dirs:" in
            *":${dataDir}:"*) ;;
            *) xdg_data_dirs="$xdg_data_dirs:${dataDir}" ;;
          esac
          case ":$xdg_config_dirs:" in
            *":${configDir}:"*) ;;
            *) xdg_config_dirs="$xdg_config_dirs:${configDir}" ;;
          esac
          printf 'XDG_DATA_DIRS=%s\nXDG_CONFIG_DIRS=%s\n' "$xdg_data_dirs" "$xdg_config_dirs"
        '';

      # makeDBusConf emits these runtime search paths without copying service
      # files at build time, so newly installed applications need no rebuild.
      services.dbus.packages = [ compatDir ];
      security.polkit.enable = true;
      programs.fuse.enable = true;
      boot.kernelModules = [ "fuse" ];

      systemd.tmpfiles.rules = map (path: "d ${path} 0755 root root -") stateDirectories;

      # Do not use L+ tmpfiles rules here: an existing mutable APM installation
      # must be migrated explicitly, never hidden or overwritten on activation.
      system.activationScripts.amber-pm-state = {
        deps = [ "specialfs" ];
        text = ''
          (
            set -eu
            target=/var/lib/apm/apm
            if [ -e "$target" ] || [ -L "$target" ]; then
              if [ ! -L "$target" ]; then
                echo "APM: $target is an existing data directory; migrate it as described in docs/NIXOS.md before enabling this module." >&2
                exit 1
              fi
              if ! [[ "$(${pkgs.coreutils}/bin/readlink "$target")" =~ ^/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+/share/amber-pm/apm$ ]]; then
                echo "APM: refusing to replace an unmanaged link at $target; see docs/NIXOS.md." >&2
                exit 1
              fi
            fi

            ${pkgs.coreutils}/bin/install -d -m 0755 ${
              lib.concatMapStringsSep " " lib.escapeShellArg stateDirectories
            }
            data_link=${compatDir}/ace-env/amber-ce-tools/data-dir
            if [ ! -e "$data_link" ] && [ ! -L "$data_link" ]; then
              ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg dataDir} "$data_link"
            elif [ ! -L "$data_link" ] || [ "$(${pkgs.coreutils}/bin/readlink "$data_link")" != ${lib.escapeShellArg dataDir} ]; then
              echo "APM: refusing to replace existing compatibility data at $data_link; see docs/NIXOS.md." >&2
              exit 1
            fi

            link_dir="$(${pkgs.coreutils}/bin/mktemp -d /var/lib/apm/.apm-link.XXXXXX)"
            trap '${pkgs.coreutils}/bin/rm -f "$link_dir/apm"; ${pkgs.coreutils}/bin/rmdir "$link_dir"' EXIT
            ${pkgs.coreutils}/bin/ln -s ${cfg.package}/share/amber-pm/apm "$link_dir/apm"
            ${pkgs.coreutils}/bin/mv -Tf "$link_dir/apm" "$target"
            ${cfg.package}/bin/amber-pm-desktop-fix
          )
        '';
      };
    })
  ];
}
