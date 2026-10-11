# The nd module inside real home-manager, at both ends of what consumers run.
#
# tests/module.nix evaluates the module against a stubbed slice of
# home-manager's option surface, which proves the module's own logic and
# nothing about whether the options it writes still exist upstream. A rename in
# home-manager — the kind that turned initExtra into initContent — would pass
# there and fail for every consumer. This flake builds a real home-manager
# activation package with the module enabled, using an extra source as well,
# against the stable release a team flake pins and the master branch a
# personal flake follows.
#
# A separate flake rather than inputs of the main one: flake inputs are locked
# transitively, so every consumer's flake.lock would carry two home-manager
# trees and two nixpkgs it never uses. `path:../..` is locked relative and
# unhashed, so this always evaluates the working tree it sits in.
#
# Usage:
#   nix flake check ./tests/hm
{
  inputs = {
    nd.url = "path:../..";
    nd.inputs.nixpkgs.follows = "nixpkgs-unstable";

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager-master.url = "github:nix-community/home-manager";
    home-manager-master.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # The darwin branch of the stable release is the one Hydra builds darwin
    # binaries for, so a check on macOS downloads rather than builds; nixos-*
    # is its Linux counterpart.
    nixpkgs-stable-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nixpkgs-stable-linux.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager-stable.url = "github:nix-community/home-manager/release-26.05";
    home-manager-stable.inputs.nixpkgs.follows = "nixpkgs-stable-linux";
  };

  outputs =
    {
      nd,
      nixpkgs-unstable,
      home-manager-master,
      nixpkgs-stable-darwin,
      nixpkgs-stable-linux,
      home-manager-stable,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs-unstable.lib.genAttrs systems f;

      fixtures = nd + "/tests/fixtures";

      # The same shape tests/module.nix uses, so a failure here and a pass there
      # points at home-manager rather than at the configuration.
      ndConfig =
        { pkgs, ... }:
        {
          home.username = "tester";
          home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/tester" else "/home/tester";
          home.stateVersion = "26.05";

          programs.zsh.enable = true;

          programs.nd = {
            enable = true;
            flakePath = "/opt/flakes/dotfiles";
            sourceDir = fixtures + "/src";
            repoSubdir = "files";
            files.".config/app/config.toml" = "app/config.toml";
            globs.".config/nv" = {
              source = "nv";
              patterns = [
                "**/*.lua"
                "lazy-lock.json"
              ];
            };
            sources.shared = {
              input = "dotfiles";
              checkout = "/opt/checkouts/dotfiles";
              sourceDir = fixtures + "/shared";
              repoSubdir = "alice/files";
              files.".posh.toml" = "posh.toml";
              globs.".config/kit" = {
                source = "kit";
                patterns = [ "*.md" ];
              };
            };
          };
        };

      # Building the activation package proves evaluation (home-manager fails
      # the build on any failed assertion) and that every option the module
      # sets exists. The greps prove the module's activation entry made it into
      # the script home-manager actually runs, extra source included.
      check =
        name: home-manager: pkgs:
        let
          activation =
            (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [
                nd.homeManagerModules.default
                ndConfig
              ];
            }).activationPackage;
        in
        pkgs.runCommand "nd-hm-${name}" { } ''
          grep -q 'nd: would write manifest' ${activation}/activate
          grep -q '/opt/checkouts/dotfiles/alice/files/posh.toml' ${activation}/activate
          touch $out
        '';
    in
    {
      checks = forAllSystems (
        system:
        let
          stable =
            if nixpkgs-unstable.lib.hasSuffix "-darwin" system then
              nixpkgs-stable-darwin.legacyPackages.${system}
            else
              nixpkgs-stable-linux.legacyPackages.${system};
        in
        {
          home-manager-master = check "master" home-manager-master nixpkgs-unstable.legacyPackages.${system};
          home-manager-stable = check "stable" home-manager-stable stable;
        }
      );
    };
}
