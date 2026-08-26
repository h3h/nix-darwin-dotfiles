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
# The kinds are captured, drifted, missing, new and unreadable. A caller that
# meets a kind it does not recognise should say so rather than drop the line.
#
# git is not in runtimeInputs on purpose: it is taken from the caller's PATH so
# the closure does not carry a second git, and the flake check supplies one.
writeShellApplication {
  name = "nd-status";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
  ];
  text = ''
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"

    case "''${1:-}" in
      -h | --help)
        echo "usage: nd-status"
        echo "  Classifies managed paths as captured, drifted, missing, new or unreadable."
        echo "  Prints: <kind> TAB <path under \$HOME> TAB <path under the repo root>"
        echo
        echo "  drifted     the live file differs from the store source that placed it"
        echo "  missing     the live file is gone"
        echo "  new         a file under a glob root that nothing placed"
        echo "  unreadable  the store source cannot be opened, so whether the live"
        echo "              file drifted cannot be decided either way — usually a"
        echo "              manifest that no longer matches the current generation"
        echo "  captured    the live file differs from the store source that placed it,"
        echo "              or nothing placed it — but the repo already holds that exact"
        echo "              content and git can see it, so the next switch re-places it"
        echo "              and discards nothing"
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

    # `install` only ever places 0644 or 0755, so the executable bit is the
    # only mode either side of a managed file can vary on; a full mode
    # comparison would treat a umask the user set on the live file by hand
    # (0644 vs 0640) as drift for no reason.
    modes_match() { # modes_match <a> <b>
      local a b
      if [ -x "$1" ]; then a=1; else a=0; fi
      if [ -x "$2" ]; then b=1; else b=0; fi
      [ "$a" = "$b" ]
    }

    # Answer, for a path whose content is not what the store placed — or that
    # nothing placed at all — whether that exact content is already in the repo
    # where the next switch would build it from. If it is, switching re-places
    # it byte for byte and discards nothing, so reporting it as something a
    # switch would destroy is false, and refusing the switch on it deadlocks:
    # only an activation rewrites the manifest, and the refusal is what declines
    # to activate.
    #
    # Two questions, both of which must answer yes:
    #
    #   - the repo copy exists and is byte-identical to the live file; and
    #   - git can see it. An untracked file is invisible to a flake build — nix
    #     refuses with "To make it visible to Nix, run: git add" — so a
    #     byte-identical untracked copy would not survive the switch at all, and
    #     calling it captured would cost the user the file. A tracked file with
    #     an uncommitted modification is fine: nix builds a dirty tree from the
    #     working tree, which is where the content is.
    #
    # Everything else falls through to the caller's fallback kind. A missing
    # repo, a cmp that exits 2 rather than 1, a git that is not on PATH: each
    # leaves the question undecided, and E14's rule is that "I cannot tell
    # whether this is safe to overwrite" is the reason not to, not a reason to.
    kind_for() { # kind_for <fallback> <dest> <repo_rel>
      local fallback="$1" dest="$2" repo_rel="$3" cmp_st=0

      if [ -z "$repo_rel" ] || [ ! -f "$flake/$repo_rel" ]; then
        printf '%s' "$fallback"
        return 0
      fi

      cmp -s "$flake/$repo_rel" "$HOME/$dest" || cmp_st=$?
      if [ "$cmp_st" -ne 0 ]; then
        printf '%s' "$fallback"
        return 0
      fi

      # Byte-identical is not enough: a repo copy committed before an
      # executable bit was saved still matches on content, but the next
      # switch would place it 0644 and silently discard the bit again.
      if ! modes_match "$flake/$repo_rel" "$HOME/$dest"; then
        printf '%s' "$fallback"
        return 0
      fi

      # --literal-pathspecs, not a bare "--". A pathspec is not a path: without
      # it, a repo_rel containing [, * or ? is read as a glob and can match a
      # different tracked file at a different location. An untracked repo copy
      # named files/c[1].toml was reported captured this way, because
      # files/c1.toml happened to be tracked and the pathspec matched that
      # instead of asking whether files/c[1].toml itself was known to git.
      if ! git --literal-pathspecs -C "$flake" ls-files --error-unmatch -- "$repo_rel" > /dev/null 2>&1; then
        printf '%s' "$fallback"
        return 0
      fi

      printf 'captured'
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
        printf '%s\t%s\t%s\n' \
          "$(kind_for new "$dest_prefix$rel" "$repo_prefix$rel")" \
          "$dest_prefix$rel" "$repo_prefix$rel"
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
              # Content can match while the executable bit does not — the fix
              # for placing and saving that bit is worthless if the one place
              # that decides "nothing to do here" cannot see it change.
              if [ "$cmp_st" -eq 0 ] && ! modes_match "$src" "$HOME/$dest"; then
                cmp_st=1
              fi
              case "$cmp_st" in
                0) ;;
                1) printf '%s\t%s\t%s\n' "$(kind_for drifted "$dest" "$repo_rel")" "$dest" "$repo_rel" ;;
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
