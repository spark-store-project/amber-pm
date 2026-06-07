{
  description = "Amber Package Manager packaged for NixOS testing";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "loongarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          amber-pm = pkgs.callPackage ./nix/package.nix { };
          default = self.packages.${system}.amber-pm;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          amber-pm = self.packages.${system}.amber-pm;
        in
        {
          cli-smoke = pkgs.runCommand "amber-pm-cli-smoke" { } ''
            ${amber-pm}/bin/apm --version
            ${amber-pm}/bin/apm --help >/dev/null
            ${amber-pm}/bin/amber-pm-init-state --help >/dev/null
            touch "$out"
          '';
        }
      );

      nixosModules.default = import ./nix/module.nix;

      overlays.default = final: prev: {
        amber-pm = final.callPackage ./nix/package.nix { };
      };
    };
}
