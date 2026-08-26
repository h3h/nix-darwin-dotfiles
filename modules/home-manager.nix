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

  # Every path-shaped string in this module is relative — a destination to
  # `$HOME`, a source to sourceDir — and every one of them is interpolated into
  # the manifest verbatim, so a leading or trailing slash reaches each reader as
  # part of the path.
  #
  # nd-status normalises a trailing slash on a *glob root* defensively, because
  # the manifest is a text file that can be hand-edited or truncated (E18). That
  # is not a reason to let the module write one, and it is not enough on its
  # own: the same `globs` key is also the prefix of every file record's
  # destination, which nd-status does not normalise, so a key of ".config/nv/"
  # still yields a manifest whose glob scan and file records disagree —
  #
  #   $ nd-status                       # key ".config/nv/", init.lua placed
  #   new  .config/nv/init.lua  files/nv/init.lua
  #
  # — reporting a placed file as new, on every run, forever.
  #
  # Rejected rather than silently normalised. An assertion names the option, in
  # the same way and for the same reason as the pathExists assertion below, and
  # normalising would repair one half of a typo the user cannot see while
  # leaving them to wonder why their key is not the one they wrote. An empty
  # string and a leading slash are the same class of error and get the same
  # treatment: they produce `$HOME//x` in the manifest and a git pathspec that
  # is not inside the repo.
  relPathProblem =
    s:
    if s == "" then
      "is empty"
    else if lib.hasPrefix "/" s then
      "begins with a '/'"
    else if lib.hasSuffix "/" s then
      "ends with a '/'"
    else
      null;

  relPathAssertion = option: value: {
    assertion = relPathProblem value == null;
    message =
      "programs.nd.${option}: \"${value}\" ${relPathProblem value}. Paths here are relative"
      + " — destinations to $HOME, sources to programs.nd.sourceDir — and are written into the"
      + " manifest as given, so each must be a non-empty path with no leading or trailing"
      + " slash.";
  };

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
  #
  # Field 1 of a glob record is a "-" placeholder. No reader uses it: nd-status
  # scans with the destination root, the repo root and the ERE only, and every
  # file a pattern matches already has its own file record carrying its store
  # source. Interpolating the source root here would copy the whole subtree into
  # the store a second time, on top of the per-file copies, for a field nothing
  # reads — and it would not even be accurate, because the subtree contains
  # files no pattern matched.
  manifestText = lib.concatStrings (
    map (f: "${f.src}\t${f.dest}\t${f.repoRel}\n") fileRecords
    ++ map (g: "-\t${g.destRoot}\t${g.repoRoot}\tglob\t${g.ere}\n") patternRecords
  );

  # The declared options have to reach the binaries. Without this, flakePath and
  # manifestPath are documented settings that silently do nothing, because each
  # tool falls back to its own hardcoded default.
  #
  # --set-default rather than --set: an explicitly exported variable still wins,
  # which is what the tests and the documented ND_* overrides rely on.
  ndPkgs = self.packages.${pkgs.stdenv.hostPlatform.system};

  # A list, rather than arguments written inline on the makeWrapper call below.
  # Inline, that call is a backslash-continued shell command, and a conditional
  # argument in the middle of one collapses to a blank line between a trailing
  # `\` and the next flag — which ends the command there and silently drops
  # every flag after it. A list has no such positional hazard, so a new
  # conditional flag can go anywhere in it.
  wrapFlags = lib.concatStringsSep " " (
    [
      "--set-default ND_FLAKE ${lib.escapeShellArg cfg.flakePath}"
      "--set-default ND_MANIFEST ${lib.escapeShellArg "${config.home.homeDirectory}/${cfg.manifestPath}"}"
    ]
    ++ lib.optional (cfg.host != "") "--set-default ND_HOST ${lib.escapeShellArg cfg.host}"
    ++ lib.optional (
      cfg.expectedBranch != ""
    ) "--set-default ND_EXPECTED_BRANCH ${lib.escapeShellArg cfg.expectedBranch}"
  );

  wrap =
    name: drv:
    pkgs.runCommand "${name}-nd"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = drv.meta or { };
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper "${drv}/bin/${name}" "$out/bin/${name}" ${wrapFlags}
      '';

  # ND_EXPECTED_BRANCH and ND_HOST are set on all three for uniformity; only
  # nd-save reads the first, only nd-switch the second.
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
        Where to record what was placed, relative to `$HOME`. Tab-separated,
        with two kinds of record distinguished by field 4:

        - a *file* record has three fields — store source, destination relative
          to `$HOME`, path relative to {option}`flakePath` — and no field 4, so
          the three-field lines a previous generation wrote keep parsing;
        - a *glob* record has five — a literal `-`, the destination root, the
          repo root, the word `glob`, and the ERE that {option}`globs`.patterns
          was translated to at evaluation time.

        Field 1 of a glob record is a placeholder because nothing reads it:
        every file a pattern matches already has its own file record carrying
        its store source, and interpolating the source root here would copy the
        whole subtree into the store a second time for a field no reader uses.
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

    host = mkOption {
      type = types.str;
      default = "";
      example = "default";
      description = ''
        `darwinConfigurations` attribute `nd-switch` builds and switches to.
        Empty means the short hostname.

        A single attribute name, not a dotted path: a value containing `.` is
        read as a nested attribute path, which is why the hostname fallback
        uses `hostname -s` rather than the FQDN.

        A multi-host repo names each configuration after its machine, and the
        hostname finds it with nothing declared here. A host-agnostic
        single-user flake exposes one `darwinConfigurations.default` instead,
        precisely so no hostname is written down anywhere; set this to
        `default` and `nd-switch` stops looking for a machine-named attribute.

        `ND_HOST` overrides this for one run.
      '';
    };

    installPackages = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to add nd-switch, nd-save and nd-status to
        {option}`home.packages`.
      '';
    };

    enableZshIntegration = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Print a one-line notice at interactive zsh startup when managed config
        needs attention: drifted, captured, missing, newly appeared and
        unreadable files are each counted, and any kind `nd-status` reports
        that this notice predates is counted as unrecognised rather than
        dropped. Forks `nd-status` once, whatever the number of managed files.
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
    ++ lib.mapAttrsToList (dest: _: relPathAssertion "files" dest) cfg.files
    ++ lib.mapAttrsToList (dest: rel: relPathAssertion "files.\"${dest}\"" rel) cfg.files
    ++ lib.mapAttrsToList (destRoot: _: relPathAssertion "globs" destRoot) cfg.globs
    ++ lib.mapAttrsToList (
      destRoot: g: relPathAssertion "globs.\"${destRoot}\".source" g.source
    ) cfg.globs
    # lib.filesystem.listFilesRecursive on a missing path throws an evaluation
    # error whose message does not name the option that caused it. A path that
    # exists but is not a directory gets past a bare pathExists and then throws
    # the same class of unattributed error — `cannot read directory …: Not a
    # directory` — so both cases are checked here rather than one.
    ++ lib.mapAttrsToList (
      destRoot: g:
      let
        src = cfg.sourceDir + "/${g.source}";
      in
      {
        assertion = builtins.pathExists src && builtins.readFileType src == "directory";
        message =
          "programs.nd.globs.\"${destRoot}\".source = \"${g.source}\" must be a directory under "
          + "programs.nd.sourceDir; it is "
          + (if builtins.pathExists src then "a ${builtins.readFileType src}" else "missing")
          + ".";
      }
    ) cfg.globs
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
    # World-readable (not 0600) is deliberate: the credential scan in nd-save
    # enforces that no credential belongs in a managed file, and if that holds,
    # 0644/0755 is correct. The executable bit is preserved from the source
    # blob rather than declared, because it is the one permission git already
    # round-trips — no per-file mode option is offered or needed.
    home.activation.ndPlaceManagedConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      manifest="$HOME/${cfg.manifestPath}"
      run mkdir -p "$(dirname "$manifest")"

      ${lib.concatMapStringsSep "\n" (f: ''
        run mkdir -p "$(dirname "$HOME/${f.dest}")"
        if [ -L "$HOME/${f.dest}" ]; then
          run rm -f "$HOME/${f.dest}"
        fi
        if [ -x ${f.src} ]; then
          run install -m 0755 ${f.src} "$HOME/${f.dest}"
        else
          run install -m 0644 ${f.src} "$HOME/${f.dest}"
        fi
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
        source ${./nd-notice.zsh}
        nd_notice
      ''
    );
  };
}
