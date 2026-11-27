{
  pkgs ? import <nixpkgs> { },
  package ? pkgs.callPackage ../package.nix { },
}:

let
  evaluate =
    enable:
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit pkgs;
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../module.nix
        {
          programs.amber-pm = {
            inherit enable;
            package = if enable then package else throw "Disabled APM must not evaluate its package";
          };
          system.stateVersion = "24.11";
        }
      ];
    };
  config = (evaluate true).config;
  disabled = (evaluate false).config;
  apm = config.programs.amber-pm.package;
  activation = pkgs.writeText "apm-module-activation" config.system.activationScripts.amber-pm-state.text;
  deactivation = pkgs.writeText "apm-module-deactivation" disabled.system.activationScripts.amber-pm-state.text;
in
assert toString apm == toString package;
assert config.programs.fuse.enable;
assert config.security.wrappers.fusermount3.setuid;
assert config.security.polkit.enable;
assert config.security.wrappers.pkexec.setuid;
assert pkgs.lib.elem "/var/lib/apm/apm-compat" config.services.dbus.packages;
assert pkgs.lib.hasInfix "/var/lib/apm/apm-compat/share"
  config.environment.sessionVariables.XDG_DATA_DIRS;
assert pkgs.lib.hasInfix "/var/lib/apm/apm-compat/xdg"
  config.environment.sessionVariables.XDG_CONFIG_DIRS;
assert
  !(pkgs.lib.hasInfix (builtins.unsafeDiscardStringContext (toString package)) disabled.system.activationScripts.amber-pm-state.text);
assert !(disabled.environment.etc ? "systemd/user-environment-generators/60-apm");
assert !(pkgs.lib.elem "/var/lib/apm/apm-compat" disabled.services.dbus.packages);
pkgs.runCommand "amber-pm-module-check"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
    ];
  }
  ''
    bash ${./module-activation.sh} ${activation} ${deactivation} ${apm}
    touch "$out"
  ''
