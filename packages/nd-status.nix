{
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
}:

# nd-status — classify every managed path the manifest knows about.
#
# One program rather than four. Before this existed, the same scan was written
# in nd-switch, twice in nd-save, and again in the zsh startup notice, and
# adding a category meant editing all four consistently.
#
# Output is <kind> TAB <dest relative to $HOME> TAB <path relative to the flake
# repo root>, passed through `sort -u`. Exit status is 0 whenever the manifest
# was read, findings or not: classifying is this program's job, and deciding
# what a finding means belongs to its callers.
writeShellApplication {
  name = "nd-status";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
  ];
  text = ''
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"

    case "''${1:-}" in
      -h | --help)
        echo "usage: nd-status"
        echo "  Classifies managed paths as drifted, missing or new."
        echo "  Prints: <kind> TAB <path under \$HOME> TAB <path under the repo root>"
        exit 0
        ;;
      "") ;;
      *)
        echo "nd-status: unknown argument: $1" >&2
        exit 1
        ;;
    esac

    if [ ! -f "$manifest" ]; then
      echo "nd-status: no manifest at $manifest — has a switch run yet?" >&2
      exit 1
    fi

    tab="$(printf '\t')"

    # Every destination the manifest places explicitly. A placed file is never
    # "new" however many glob patterns also happen to match it — otherwise every
    # managed file inside a glob root would be reported on every run.
    #
    # cut's default delimiter is tab, which is the manifest's.
    placed="$(cut -f2 "$manifest")"

    scan_glob() {
      local root="$1" repo_root="$2" ere="$3"
      local f rel
      if [ ! -d "$HOME/$root" ]; then
        return 0
      fi
      while IFS= read -r -d "" f; do
        rel="''${f#"$HOME/$root/"}"
        # The output is line-based, and so is the membership test below. A path
        # containing a newline cannot be represented in either, so it is skipped
        # rather than emitted as something both would misparse.
        if [ "''${rel%%$'\n'*}" != "$rel" ]; then
          echo "nd-status: skipping path with a newline under $root" >&2
          continue
        fi
        if ! printf '%s' "$rel" | grep -qxE "$ere"; then
          continue
        fi
        if printf '%s\n' "$placed" | grep -qxF "$root/$rel"; then
          continue
        fi
        printf 'new\t%s\t%s\n' "$root/$rel" "$repo_root/$rel"
      done < <(find "$HOME/$root" -type f -print0)
    }

    scan() {
      local src dest repo_rel kind pattern
      while IFS="$tab" read -r src dest repo_rel kind pattern; do
        if [ -z "''${dest:-}" ]; then
          continue
        fi
        case "''${kind:-}" in
          glob)
            scan_glob "$dest" "$repo_rel" "$pattern"
            ;;
          *)
            if [ ! -e "$HOME/$dest" ]; then
              printf 'missing\t%s\t%s\n' "$dest" "$repo_rel"
            elif ! cmp -s "$src" "$HOME/$dest"; then
              printf 'drifted\t%s\t%s\n' "$dest" "$repo_rel"
            fi
            ;;
        esac
      done < "$manifest"
    }

    scan | sort -u
  '';
}
