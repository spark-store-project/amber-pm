{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.amber-pm;
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

    programs.nix-ld.enable = lib.mkDefault true;

    boot.kernel.sysctl."kernel.apparmor_restrict_unprivileged_userns" = lib.mkDefault 0;

    system.activationScripts.amber-pm-state = lib.mkIf cfg.initializeState ''
      if [ ! -e /var/lib/apm/apm ]; then
        ${cfg.package}/bin/amber-pm-init-state
      fi
    '';
  };
}
