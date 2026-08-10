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
#
# The kinds are drifted, missing, new and unreadable. A caller that meets a kind
# it does not recognise should say so rather than drop the line.
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
        echo "  Classifies managed paths as drifted, missing, new or unreadable."
        echo "  Prints: <kind> TAB <path under \$HOME> TAB <path under the repo root>"
        echo
        echo "  drifted     the live file differs from the store source that placed it"
        echo "  missing     the live file is gone"
        echo "  new         a file under a glob root that nothing placed"
        echo "  unreadable  the store source cannot be opened, so whether the live"
        echo "              file drifted cannot be decided either way — usually a"
        echo "              manifest that no longer matches the current generation"
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

    # A glob root written with a trailing slash — a `globs` key of ".config/nv/"
    # — used to defeat the prefix strip in scan_glob, so `rel` stayed absolute:
    # every placed file was reported `new` forever, at a repo path that was not
    # inside the repo, and nd-save would have created it there. Normalising here
    # rather than trusting the writer also keeps a hand-edited manifest honest.
    strip_trailing_slashes() {
      local s="$1"
      while [ -n "$s" ] && [ "''${s%/}" != "$s" ]; do
        s="''${s%/}"
      done
      printf '%s' "$s"
    }

    scan_glob() {
      local root repo_root ere
      root="$(strip_trailing_slashes "$1")"
      repo_root="$(strip_trailing_slashes "$2")"
      ere="$3"

      local base dest_prefix repo_prefix f rel
      # A root that normalises away entirely means "$HOME itself", so the
      # separator has to go with the prefix rather than into the format string.
      if [ -n "$root" ]; then
        base="$HOME/$root"
        dest_prefix="$root/"
      else
        base="$HOME"
        dest_prefix=""
      fi
      if [ -n "$repo_root" ]; then
        repo_prefix="$repo_root/"
      else
        repo_prefix=""
      fi

      if [ ! -d "$base" ]; then
        return 0
      fi
      while IFS= read -r -d "" f; do
        # find was given exactly "$base", so every result starts with it and
        # this strip cannot fail the way the unnormalised one could.
        rel="''${f#"$base/"}"
        # The output is line-based and tab-separated, and so is the membership
        # test below. A path containing either character cannot be represented
        # in them, so it is skipped rather than emitted as something every
        # consumer misparses. A tab was the worse of the two because nothing
        # stopped it: nd-save read the tab-split path as a shorter one, ran its
        # credential grep against a file that does not exist, took that grep's
        # exit 2 for "clean", and then died inside install with the working tree
        # half written.
        if [ "''${rel%%$'\n'*}" != "$rel" ]; then
          echo "nd-status: skipping path with a newline under $root" >&2
          continue
        fi
        if [ "''${rel%%$'\t'*}" != "$rel" ]; then
          echo "nd-status: skipping path with a tab under $root" >&2
          continue
        fi
        # `--` on both greps. globToERE deliberately does not escape `-` and
        # cannot (see E9), so a pattern such as `-foo/**` arrives here as
        # `-foo/.*` and grep reads it as options. grep then exits 2, this `if`
        # swallows it because errexit does not apply to a condition, and every
        # path under the root is skipped for good while grep prints usage to
        # stderr. The same argument applies to a destination beginning with `-`
        # in the fixed-string test below.
        if ! printf '%s' "$rel" | grep -qxE -- "$ere"; then
          continue
        fi
        if printf '%s\n' "$placed" | grep -qxF -- "$dest_prefix$rel"; then
          continue
        fi
        printf 'new\t%s\t%s\n' "$dest_prefix$rel" "$repo_prefix$rel"
      done < <(find "$base" -type f -print0)
    }

    scan() {
      local src dest repo_rel kind pattern cmp_st
      # `|| [ -n "$dest" ]` keeps the last record of a manifest whose final line
      # has no trailing newline. `read` returns 1 there, having already assigned
      # every field, and without this the record is dropped in silence — a
      # drifted file in an unterminated final record was reported by nothing and
      # overwritten by the next switch without a word. At true end of input read
      # assigns empty strings, so the loop still terminates.
      while IFS="$tab" read -r src dest repo_rel kind pattern || [ -n "''${dest:-}" ]; do
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
            else
              # cmp exits 1 for "they differ" and 2 for "I could not read one of
              # them". Conflating the two blamed the user for a store source
              # that had simply gone away: nd-status called the file drifted,
              # and nd-save then blamed the repo copy for differing from a file
              # it could not open either.
              cmp_st=0
              cmp -s "$src" "$HOME/$dest" || cmp_st=$?
              case "$cmp_st" in
                0) ;;
                1) printf 'drifted\t%s\t%s\n' "$dest" "$repo_rel" ;;
                *) printf 'unreadable\t%s\t%s\n' "$dest" "$repo_rel" ;;
              esac
            fi
            ;;
        esac
      done < "$manifest"
    }

    scan | sort -u
  '';
}
