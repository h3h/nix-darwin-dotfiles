{
  description = "Copy-managed dotfiles for nix-darwin, with drift capture (nd-switch, nd-save)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        nd-switch = pkgs.callPackage ./packages/nd-switch.nix { };
        nd-save = pkgs.callPackage ./packages/nd-save.nix { };
        default = pkgs.symlinkJoin {
          name = "nd";
          paths = [
            nd-switch
            nd-save
          ];
        };
      });

      homeManagerModules = {
        nd = import ./modules/home-manager.nix self;
        default = self.homeManagerModules.nd;
      };

      checks = forAllSystems (
        pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) system;
        in
        {
          tests = pkgs.runCommand "nd-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
            export HOME="$TMPDIR/home"
            export ND_SWITCH="${self.packages.${system}.nd-switch}/bin/nd-switch"
            export ND_SAVE="${self.packages.${system}.nd-save}/bin/nd-save"
            mkdir -p "$HOME"
            bash ${./tests/run.sh}
            touch $out
          '';
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.git
            pkgs.shellcheck
            pkgs.nixfmt-rfc-style
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
