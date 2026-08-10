{
  lib,
  pkgs,
  self,
}:

# Evaluates modules/home-manager.nix for real and hands the results to
# tests/module.sh.
#
# Everything the module produces — the manifest, the activation script, the
# wrapped binaries — was previously covered by nothing. tests/run.sh writes its
# manifests by hand, so the format nd-status has ~190 cases against had never
# been compared with the code that writes it.
#
# There is no home-manager input in this flake and adding one is a large
# dependency for a small gain, so the slice of the option surface the module
# writes to is stubbed below. `lib` goes through specialArgs because evalModules
# otherwise supplies its own `_module.args.lib`, and the module's
# `lib.hm.dag.entryAfter` call then dies with `attribute 'hm' missing`.

let
  hmLib = lib.extend (
    _final: _prev: {
      hm.dag.entryAfter = after: data: {
        inherit after data;
        before = [ ];
      };
    }
  );

  inherit (lib) mkOption types;

  # Only the options the module actually sets. A typo in an option name here
  # would be caught by evalModules rather than passing silently, which is the
  # reason to declare them rather than use freeform types.
  stub =
    { ... }:
    {
      options = {
        home.homeDirectory = mkOption { type = types.str; };
        home.packages = mkOption {
          type = types.listOf types.package;
          default = [ ];
        };
        # A home-manager DAG entry is { after, before, data }.
        home.activation = mkOption {
          type = types.attrsOf types.attrs;
          default = { };
        };
        programs.zsh.initContent = mkOption {
          type = types.lines;
          default = "";
        };
        assertions = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                assertion = mkOption { type = types.bool; };
                message = mkOption { type = types.str; };
              };
            }
          );
          default = [ ];
        };
      };
    };

  homeDir = "/home/tester";

  evalND =
    nd:
    (lib.evalModules {
      specialArgs = {
        lib = hmLib;
        inherit pkgs;
      };
      modules = [
        stub
        (import ../modules/home-manager.nix self)
        {
          home.homeDirectory = homeDir;
          programs.nd = nd;
        }
      ];
    }).config;

  srcDir = ./fixtures/src;

  base = {
    enable = true;
    sourceDir = srcDir;
    repoSubdir = "files";
    flakePath = "/opt/flakes/dotfiles";
    manifestPath = ".local/state/nd/manifest";
    expectedBranch = "trunk";
    files.".config/app/config.toml" = "app/config.toml";
    globs.".config/nv" = {
      source = "nv";
      patterns = [
        "**/*.lua"
        "lazy-lock.json"
      ];
    };
  };

  main = evalND base;

  # expectedBranch defaults to "", which must leave ND_EXPECTED_BRANCH unset
  # rather than set it to the empty string — nd-save reads "" as no constraint,
  # but only because the variable is absent from the wrapper entirely.
  noBranch = evalND (base // { expectedBranch = ""; });

  # The fresh-machine state: the only pattern is one that matches nothing in the
  # repo yet. It must produce a glob record, no file records, and no error.
  sparse = evalND (
    base
    // {
      files = { };
      globs.".config/nv" = {
        source = "nv";
        patterns = [ "lazy-lock.json" ];
      };
    }
  );

  # The module's own diagnostics, which replace evaluation errors that do not
  # name the option responsible.
  bad = evalND (
    base
    // {
      globs = {
        ".config/gone" = {
          source = "nope";
          patterns = [ "*" ];
        };
        ".config/empty" = {
          source = "nv";
          patterns = [ ];
        };
      };
    }
  );

  # `srcDir + "/${rel}"` is the same expression the module builds field 1 from,
  # so this is the format that is being asserted, not the store hash. The bytes
  # behind the path are checked by the activation and round-trip cases, which
  # place from field 1 and then compare against it.
  src = rel: "${srcDir + "/${rel}"}";

  # The format contract, written out by hand. Real tabs, a trailing newline on
  # every line, three fields for a file record and five for a glob record, and a
  # literal "-" in field 1 of a glob record (see escalation E7). File records
  # come from `files` first, then from each glob's matches in listFilesRecursive
  # order; notes.txt matches no pattern and must not appear at all.
  expectedManifest =
    "${src "app/config.toml"}\t.config/app/config.toml\tfiles/app/config.toml\n"
    + "${src "nv/init.lua"}\t.config/nv/init.lua\tfiles/nv/init.lua\n"
    + "${src "nv/lua/plug.lua"}\t.config/nv/lua/plug.lua\tfiles/nv/lua/plug.lua\n"
    + "-\t.config/nv\tfiles/nv\tglob\t(.*/)?[^/]*\\.lua\n"
    + "-\t.config/nv\tfiles/nv\tglob\tlazy-lock\\.json\n";

  expectedSparseManifest = "-\t.config/nv\tfiles/nv\tglob\tlazy-lock\\.json\n";

  activationOf = c: pkgs.writeText "nd-activation" c.home.activation.ndPlaceManagedConfigs.data;

  # home.packages is a list, and depending on its order to tell the three
  # wrappers apart would make this pass for the wrong reason if the order
  # changed. Look them up by name, and fail loudly if one is absent.
  wrapperOf =
    c: name:
    let
      match = lib.filter (p: lib.hasPrefix "${name}-nd" (p.name or "")) c.home.packages;
    in
    if match == [ ] then
      throw "no ${name} wrapper in home.packages: ${toString (map (p: p.name or "?") c.home.packages)}"
    else
      "${lib.head match}/bin/${name}";

  failingMessages =
    c: lib.concatMapStrings (a: a.message + "\n") (lib.filter (a: !a.assertion) c.assertions);
in
{
  activation = activationOf main;
  activationSparse = activationOf sparse;

  activationAfter = pkgs.writeText "nd-activation-after" (
    lib.concatStringsSep " " main.home.activation.ndPlaceManagedConfigs.after
  );

  expectedManifest = pkgs.writeText "nd-expected-manifest" expectedManifest;
  expectedSparseManifest = pkgs.writeText "nd-expected-sparse-manifest" expectedSparseManifest;

  zshInit = pkgs.writeText "nd-zsh-init" main.programs.zsh.initContent;

  packageNames = pkgs.writeText "nd-package-names" (
    lib.concatMapStrings (p: p.name + "\n") main.home.packages
  );

  assertionFailures = pkgs.writeText "nd-assertion-failures" (failingMessages main);
  badAssertionFailures = pkgs.writeText "nd-bad-assertion-failures" (failingMessages bad);

  wrapSwitch = wrapperOf main "nd-switch";
  wrapSave = wrapperOf main "nd-save";
  wrapStatus = wrapperOf main "nd-status";
  wrapNoBranchSave = wrapperOf noBranch "nd-save";

  homeDirectory = homeDir;
  flakePath = base.flakePath;
  expectedBranch = base.expectedBranch;
  manifestPath = base.manifestPath;
}
