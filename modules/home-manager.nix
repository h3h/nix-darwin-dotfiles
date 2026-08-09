self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nd;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;

  globLib = import ../lib/glob.nix { inherit lib; };

  # A glob entry contributes ordinary file records for everything that matches
  # in the repo right now, plus one glob record per pattern so nd-status can
  # recognise files the application creates later. Placement and drift detection
  # are therefore byte-for-byte the same code path as a declared file; globs add
  # discovery of files that do not exist yet, and nothing else.
  globFileRecords =
    destRoot: g:
    let
      root = cfg.sourceDir + "/${g.source}";
      eres = map globLib.globToERE g.patterns;
      relOf = p: lib.removePrefix "${toString root}/" (toString p);
    in
    map (p: {
      dest = "${destRoot}/${relOf p}";
      src = p;
      repoRel = "${cfg.repoSubdir}/${g.source}/${relOf p}";
    }) (lib.filter (p: globLib.matchesAny eres (relOf p)) (lib.filesystem.listFilesRecursive root));

  globPatternRecords =
    destRoot: g:
    map (p: {
      srcRoot = cfg.sourceDir + "/${g.source}";
      inherit destRoot;
      repoRoot = "${cfg.repoSubdir}/${g.source}";
      ere = globLib.globToERE p;
    }) g.patterns;

  fileRecords =
    lib.mapAttrsToList (dest: rel: {
      inherit dest;
      src = cfg.sourceDir + "/${rel}";
      repoRel = "${cfg.repoSubdir}/${rel}";
    }) cfg.files
    ++ lib.concatLists (lib.mapAttrsToList globFileRecords cfg.globs);

  patternRecords = lib.concatLists (lib.mapAttrsToList globPatternRecords cfg.globs);

  # Field 4 is the record kind; absent means "file", so the three-field lines a
  # previous generation wrote keep parsing.
  manifestText = lib.concatStrings (
    map (f: "${f.src}\t${f.dest}\t${f.repoRel}\n") fileRecords
    ++ map (g: "${g.srcRoot}\t${g.destRoot}\t${g.repoRoot}\tglob\t${g.ere}\n") patternRecords
  );

  # The declared options have to reach the binaries. Without this, flakePath and
  # manifestPath are documented settings that silently do nothing, because each
  # tool falls back to its own hardcoded default.
  #
  # --set-default rather than --set: an explicitly exported variable still wins,
  # which is what the tests and the documented ND_* overrides rely on.
  ndPkgs = self.packages.${pkgs.stdenv.hostPlatform.system};

  wrap =
    name: drv:
    pkgs.runCommand "${name}-nd"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = drv.meta or { };
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper "${drv}/bin/${name}" "$out/bin/${name}" \
          --set-default ND_FLAKE ${lib.escapeShellArg cfg.flakePath} \
          --set-default ND_MANIFEST ${lib.escapeShellArg "${config.home.homeDirectory}/${cfg.manifestPath}"} \
          ${lib.optionalString (
            cfg.expectedBranch != ""
          ) "--set-default ND_EXPECTED_BRANCH ${lib.escapeShellArg cfg.expectedBranch}"}
      '';

  # ND_EXPECTED_BRANCH is set on all three for uniformity; only nd-save reads it.
  ndSwitch = wrap "nd-switch" ndPkgs.nd-switch;
  ndSave = wrap "nd-save" ndPkgs.nd-save;
  ndStatus = wrap "nd-status" ndPkgs.nd-status;
in
{
  options.programs.nd = {
    enable = mkEnableOption "nd — copy-managed dotfiles with drift capture";

    flakePath = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.config/nix-darwin";
      description = ''
        Absolute path to the nix-darwin flake repository working tree. nd-save
        copies drifted files back into it and commits there.
      '';
    };

    sourceDir = mkOption {
      type = types.path;
      example = lib.literalExpression "./files";
      description = ''
        Directory holding the managed files. Copied into the store, so a
        generation carries the exact bytes it will place.
      '';
    };

    repoSubdir = mkOption {
      type = types.str;
      example = "modules/users/alice/files";
      description = ''
        Path of {option}`sourceDir` relative to {option}`flakePath`. Recorded in
        the manifest so nd-save knows where to copy each file back to.
      '';
    };

    files = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = lib.literalExpression ''
        {
          ".config/zed/settings.json" = "zed/settings.json";
          ".wezterm.lua" = "wezterm.lua";
        }
      '';
      description = ''
        Managed files, keyed by path relative to `$HOME`, valued by path
        relative to {option}`sourceDir`.

        These are **copied**, not symlinked. An out-of-store symlink makes the
        home path and the repo file the same inode, so `git checkout` and
        `git stash` rewrite live config underneath a running application, and a
        generation rollback cannot revert them. Copying decouples the two.
      '';
    };

    globs = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            source = mkOption {
              type = types.str;
              example = "nvim";
              description = "Directory holding the matching files, relative to {option}`sourceDir`.";
            };
            patterns = mkOption {
              type = types.listOf types.str;
              example = [
                "init.lua"
                "lua/**/*.lua"
                "lazy-lock.json"
              ];
              description = ''
                Glob patterns, relative to both {option}`source` and the
                destination root. Required: there is deliberately no default,
                because a default of `[ "**" ]` would be whole-directory
                tracking wearing a glob's clothes.

                Supported syntax is `**/` (zero or more directories), a trailing
                `/**` (everything below), `*` (within one component) and `?`.
                Bracket expressions and brace expansion are not supported and
                match literally.
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          ".config/nvim" = {
            source = "nvim";
            patterns = [ "init.lua" "lua/**/*.lua" "lazy-lock.json" ];
          };
        }
      '';
      description = ''
        Managed file *sets*, keyed by destination root relative to `$HOME`.

        Everything matching is placed exactly as {option}`files` entries are. In
        addition, a file that appears under the destination root later and
        matches a pattern — the canonical case being lazy.nvim rewriting
        `lazy-lock.json` on every plugin update — is reported by `nd-status` as
        new and captured by `nd-save`, after which the next evaluation places it
        like any other managed file.

        Only what a pattern names is ever captured. This is an allowlist on
        purpose: a managed *directory* would need an ignore list maintained
        against an application you do not control.
      '';
    };

    manifestPath = mkOption {
      type = types.str;
      default = ".local/state/nd/manifest";
      description = ''
        Where to record what was placed, relative to `$HOME`. Each line is
        store-source, destination and repo path, tab separated.
      '';
    };

    expectedBranch = mkOption {
      type = types.str;
      default = "";
      example = "main";
      description = ''
        Branch `nd-save` is allowed to commit to. Empty means no constraint.

        When set and the checked-out branch differs, `nd-save` refuses —
        including under `-y`, because the unattended path is the one with nobody
        reading the branch name. `--branch NAME` overrides it for one run.

        A detached HEAD is refused whatever this is set to: the commit would be
        unreachable as soon as anything else is checked out.
      '';
    };

    installPackages = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to add nd-switch and nd-save to {option}`home.packages`.";
    };

    enableZshIntegration = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Print a one-line notice at interactive zsh startup when managed files
        have drifted. Costs one `cmp` per managed file and starts no processes.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.files == { } && cfg.globs == { }) || cfg.repoSubdir != "";
        message = "programs.nd.repoSubdir must be set when programs.nd.files or programs.nd.globs is non-empty.";
      }
    ]
    # lib.filesystem.listFilesRecursive on a missing path throws an evaluation
    # error whose message does not name the option that caused it.
    ++ lib.mapAttrsToList (destRoot: g: {
      assertion = builtins.pathExists (cfg.sourceDir + "/${g.source}");
      message = "programs.nd.globs.\"${destRoot}\".source = \"${g.source}\" does not exist under programs.nd.sourceDir.";
    }) cfg.globs
    # An empty match set is not an error — a pattern that matches nothing today
    # but will match lazy-lock.json tomorrow is the expected state on a fresh
    # machine. An empty pattern list is, because it can never match anything.
    ++ lib.mapAttrsToList (destRoot: g: {
      assertion = g.patterns != [ ];
      message = "programs.nd.globs.\"${destRoot}\".patterns is empty, so the entry places and captures nothing.";
    }) cfg.globs;

    home.packages = mkIf cfg.installPackages [
      ndSwitch
      ndSave
      ndStatus
    ];

    # Copy into place and record what was placed.
    #
    # A pre-existing symlink is removed first. Without that, `install` writes
    # *through* an old out-of-store symlink straight back into the repo, which
    # silently preserves the exact behaviour this module replaces.
    #
    # 0644 is deliberate. The position the credential scan in nd-save enforces is
    # that no credential belongs in a managed file; if that holds, 0644 is
    # correct. A per-file mode option would not survive the repo round-trip in
    # any case, because git records only the executable bit. Closed as wontfix,
    # not overlooked.
    home.activation.ndPlaceManagedConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      manifest="$HOME/${cfg.manifestPath}"
      run mkdir -p "$(dirname "$manifest")"

      ${lib.concatMapStringsSep "\n" (f: ''
        run mkdir -p "$(dirname "$HOME/${f.dest}")"
        if [ -L "$HOME/${f.dest}" ]; then
          run rm -f "$HOME/${f.dest}"
        fi
        run install -m 0644 ${f.src} "$HOME/${f.dest}"
      '') fileRecords}

      # Built in one variable and written once, so a dry run writes nothing at
      # all. Previously the scratch file was truncated and appended to directly
      # while only the final `mv` went through `run`, so a dry run left an
      # orphaned manifest.new behind. `run` keys off DRY_RUN, not the deprecated
      # DRY_RUN_CMD.
      ndManifest=${lib.escapeShellArg manifestText}

      if [[ -v DRY_RUN ]]; then
        echo "nd: would write manifest to $manifest"
      else
        printf '%s' "$ndManifest" > "$manifest.new"
        mv "$manifest.new" "$manifest"
      fi
    '';

    programs.zsh.initContent = mkIf cfg.enableZshIntegration (
      lib.mkAfter ''
        () {
          emulate -L zsh
          local manifest="$HOME/${cfg.manifestPath}"
          [[ -f $manifest ]] || return
          local src dest rest n=0
          while IFS=$'\t' read -r src dest rest; do
            [[ -n $dest && -e $HOME/$dest ]] || continue
            cmp -s "$src" "$HOME/$dest" || (( n++ ))
          done < $manifest
          (( n > 0 )) && print -P "%F{yellow}nd:%f $n config file(s) drifted — run %B nd-save %b to audit and commit"
        }
      ''
    );
  };
}
