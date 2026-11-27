{
  pkgs ? import <nixpkgs> { },
  package ? pkgs.callPackage ../package.nix { },
}:
{
  module = import ./module.nix { inherit pkgs package; };
  regression =
    pkgs.runCommand "amber-pm-regression"
      {
        nativeBuildInputs = with pkgs; [
          bash
          bash-completion
          bzip2
          coreutils
          curl
          desktop-file-utils
          diffutils
          dpkg
          file
          findutils
          gawk
          glib
          gnugrep
          gnupg
          gnused
          gnutar
          gzip
          shared-mime-info
          util-linux
          xz
          zstd
        ];
      }
      ''
        bash ${./upstream.sh} ${package} ${../../tests} ${pkgs.bash}/bin/bash ${pkgs.bash-completion}/share/bash-completion/bash_completion
        bash ${./state.sh} ${package}
        bash ${./desktop.sh} ${package}
        bash ${./runtime.sh} ${package}
        bash ${./spark-compat.sh} ${package}
        touch "$out"
      '';
}
