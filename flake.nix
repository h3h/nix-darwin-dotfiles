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
          tests =
            pkgs.runCommand "nd-tests"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.zsh
                ];
              }
              ''
                export HOME="$TMPDIR/home"
                export ND_SWITCH="${self.packages.${system}.nd-switch}/bin/nd-switch"
                export ND_SAVE="${self.packages.${system}.nd-save}/bin/nd-save"
                export ND_STATUS="${self.packages.${system}.nd-status}/bin/nd-status"
                export ND_NOTICE="${./modules/nd-notice.zsh}"
                mkdir -p "$HOME"
                bash ${./tests/run.sh}
                touch $out
              '';

          # modules/home-manager.nix, evaluated for real through lib.evalModules
          # against a stubbed home-manager option surface. Covers the manifest
          # it writes, the files its activation script places, the dry-run
          # guard, the ND_* wrappers, and — feeding the first to the third — a
          # round trip through the real nd-status.
          module =
            let
              m = import ./tests/module.nix {
                inherit (pkgs) lib;
                inherit pkgs self;
              };
            in
            pkgs.runCommand "nd-module-tests" { } ''
              export ND_ACTIVATION="${m.activation}"
              export ND_ACTIVATION_SPARSE="${m.activationSparse}"
              export ND_ACTIVATION_AFTER="${m.activationAfter}"
              export ND_EXPECTED_MANIFEST="${m.expectedManifest}"
              export ND_EXPECTED_SPARSE_MANIFEST="${m.expectedSparseManifest}"
              export ND_ZSH_INIT="${m.zshInit}"
              export ND_PACKAGE_NAMES="${m.packageNames}"
              export ND_ASSERTION_FAILURES="${m.assertionFailures}"
              export ND_BAD_ASSERTION_FAILURES="${m.badAssertionFailures}"
              export ND_WRAP_SWITCH="${m.wrapSwitch}"
              export ND_WRAP_SAVE="${m.wrapSave}"
              export ND_WRAP_STATUS="${m.wrapStatus}"
              export ND_WRAP_NOBRANCH_SAVE="${m.wrapNoBranchSave}"
              export ND_STATUS_BIN="${self.packages.${system}.nd-status}/bin/nd-status"
              export ND_HOME_DIRECTORY="${m.homeDirectory}"
              export ND_FLAKE_PATH="${m.flakePath}"
              export ND_EXPECTED_BRANCH_VALUE="${m.expectedBranch}"
              export ND_MANIFEST_PATH="${m.manifestPath}"
              bash ${./tests/module.sh}
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

          # `glob` above only ever consults `builtins.match`. This one replays
          # the same cases through `grep -qxE`, the engine `nd-status` actually
          # uses, and fails if the two disagree. Same translator, both anchors.
          glob-engines =
            let
              r = import ./tests/glob.nix { inherit (pkgs) lib; };
              casesFile = pkgs.writeText "nd-glob-cases.tsv" r.engineCases;
            in
            pkgs.runCommand "nd-glob-engine-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
              bash ${./tests/glob-engines.sh} ${casesFile}
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
