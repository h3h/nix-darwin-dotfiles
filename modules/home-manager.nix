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

    manifestPath = mkOption {
      type = types.str;
      default = ".local/state/nd/manifest";
      description = ''
        Where to record what was placed, relative to `$HOME`. Each line is
        store-source, destination and repo path, tab separated.
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
        assertion = cfg.files == { } || cfg.repoSubdir != "";
        message = "programs.nd.repoSubdir must be set when programs.nd.files is non-empty.";
      }
    ];

    home.packages = mkIf cfg.installPackages [
      self.packages.${pkgs.stdenv.hostPlatform.system}.nd-switch
      self.packages.${pkgs.stdenv.hostPlatform.system}.nd-save
    ];

    # Copy into place and record what was placed.
    #
    # A pre-existing symlink is removed first. Without that, `install` writes
    # *through* an old out-of-store symlink straight back into the repo, which
    # silently preserves the exact behaviour this module replaces.
    home.activation.ndPlaceManagedConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      manifest="$HOME/${cfg.manifestPath}"
      run mkdir -p "$(dirname "$manifest")"
      tmp="$manifest.new"
      : > "$tmp"

      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (dest: rel: ''
          run mkdir -p "$(dirname "$HOME/${dest}")"
          [ -L "$HOME/${dest}" ] && run rm -f "$HOME/${dest}"
          run install -m 0644 ${cfg.sourceDir + "/${rel}"} "$HOME/${dest}"
          printf '%s\t%s\t%s\n' "${cfg.sourceDir + "/${rel}"}" "${dest}" "${cfg.repoSubdir}/${rel}" >> "$tmp"
        '') cfg.files
      )}

      run mv "$tmp" "$manifest"
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
