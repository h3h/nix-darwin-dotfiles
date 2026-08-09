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
        nd-status = pkgs.callPackage ./packages/nd-status.nix { };
        # nd-status is passed explicitly: callPackage's auto-args come from
        # `pkgs`, not from this `rec` set, so being in scope here is not enough.
        nd-switch = pkgs.callPackage ./packages/nd-switch.nix { inherit nd-status; };
        nd-save = pkgs.callPackage ./packages/nd-save.nix { inherit nd-status; };
        default = pkgs.symlinkJoin {
          name = "nd";
          paths = [
            nd-switch
            nd-save
            nd-status
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
            export ND_STATUS="${self.packages.${system}.nd-status}/bin/nd-status"
            mkdir -p "$HOME"
            bash ${./tests/run.sh}
            touch $out
          '';

          glob =
            let
              r = import ./tests/glob.nix { inherit (pkgs) lib; };
            in
            if r.ok then
              pkgs.runCommand "nd-glob-tests" { } "touch $out"
            else
              throw ''
                globToERE translation failures: ${builtins.toJSON r.translationFailures}
                globToERE match failures: ${builtins.toJSON r.matchFailures}
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
