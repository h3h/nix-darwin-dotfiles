{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  nd-status,
}:

# nd-save — copy application-written config back into the repo and commit it.
#
# Reads the manifest that the home-manager module writes at activation, by way
# of nd-status, which owns the classification. A file differs from its store
# source exactly when something rewrote it after it was placed; a file under a
# glob root with no store source at all is something the application created.
# Both are saved. A file that is simply gone is reported and skipped.
#
# git is not in runtimeInputs on purpose: it is taken from the caller's PATH so
# the closure does not carry a second git, and the flake check supplies one.
writeShellApplication {
  name = "nd-save";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    gawk
    nd-status
  ];
  text = ''
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"
    msg=""
    assume_yes=""
    force=""
    expected_branch="''${ND_EXPECTED_BRANCH:-}"

    # The application a destination belongs to, derived rather than looked up. A
    # lookup table of application names goes stale the first time a file is
    # added, and a wrong name in a commit subject is worse than a lower-case
    # one — so this stays unprettified: "zed", not "Zed"; "wezterm", not
    # "WezTerm".
    app_of() {
      local dest="$1" token
      case "$dest" in
        .config/*)
          token="''${dest#.config/}"
          token="''${token%%/*}"
          ;;
        *)
          token="$(basename "$dest")"
          ;;
      esac
      token="''${token#.}"
      printf '%s' "''${token%%.*}"
    }

    derive_subject() {
      local apps n list head tail
      apps="$(printf '%s' "$copied" | sed '/^[[:space:]]*$/d' | while IFS= read -r d; do
        app_of "$(printf '%s' "$d" | sed 's/^[[:space:]]*//')"
        printf '\n'
      done | sort -u)"

      n="$(printf '%s\n' "$apps" | sed '/^$/d' | wc -l | tr -d ' ')"

      if [ "$n" -le 1 ]; then
        printf 'Save %s config written by the app' "$apps"
        return 0
      fi

      list="$(printf '%s\n' "$apps" | sed '/^$/d' | paste -sd'|' - | sed 's/|/, /g')"
      head="''${list%, *}"
      tail="''${list##*, }"
      printf 'Save config written by %s and %s' "$head" "$tail"
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        -m)
          shift
          msg="''${1:-}"
          shift || true
          ;;
        -y | --yes)
          assume_yes=1
          shift
          ;;
        --force)
          force=1
          shift
          ;;
        --branch)
          shift
          expected_branch="''${1:-}"
          shift || true
          ;;
        -h | --help)
          echo "usage: nd-save [-m MESSAGE] [-y] [--force] [--branch NAME]"
          echo "  Copies config that applications rewrote back into the flake repo,"
          echo "  then commits it. Never pushes."
          echo "  --force        overwrite repo files that carry edits never placed"
          echo "  --branch NAME  require this branch; overrides ND_EXPECTED_BRANCH"
          exit 0
          ;;
        *)
          echo "nd-save: unknown argument: $1" >&2
          exit 1
          ;;
      esac
    done

    if [ ! -f "$manifest" ]; then
      echo "nd-save: no manifest at $manifest — has a switch run yet?" >&2
      exit 1
    fi

    if ! git -C "$flake" rev-parse --git-dir > /dev/null 2>&1; then
      echo "nd-save: $flake is not a git repository" >&2
      exit 1
    fi

    # The branch guard runs before the scan and before any copy. With -y the old
    # code printed the branch to a terminal nobody is reading and committed
    # regardless, so the unattended path — the one -y exists for — was the only
    # path with no check.
    branch="$(git -C "$flake" branch --show-current)"

    if [ -z "$branch" ]; then
      echo "nd-save: HEAD is detached in $flake — refusing." >&2
      echo "nd-save: a commit here becomes unreachable as soon as anything else is checked out." >&2
      echo "nd-save: run 'git switch <branch>' first." >&2
      exit 1
    fi

    if [ -n "$expected_branch" ] && [ "$branch" != "$expected_branch" ]; then
      echo "nd-save: on branch '$branch', expected '$expected_branch' — refusing." >&2
      echo "nd-save: nd-save is prompted by a shell notice rather than by you choosing a" >&2
      echo "nd-save: moment, so app config lands on whatever topic branch happens to be out." >&2
      echo "nd-save: switch branch, or pass --branch '$branch' to commit here anyway." >&2
      exit 1
    fi

    tab="$(printf '\t')"
    status="$(nd-status)"

    missing="$(printf '%s\n' "$status" | grep '^missing' | cut -f2 || true)"
    candidates="$(printf '%s\n' "$status" | grep -E '^(drifted|new)' || true)"

    if [ -n "$missing" ]; then
      echo "nd-save: these managed files are gone; there is nothing to save for them:"
      printf '%s\n' "$missing" | sed 's/^/  /'
      echo "nd-save: the next switch will restore them."
      echo
    fi

    if [ -z "$candidates" ]; then
      echo "nd-save: nothing to save, every placed file still matches"
      exit 0
    fi

    # Scan BEFORE copying. Applications write credentials into their own config
    # as a matter of course, and the flake repo may be shared. Copying first and
    # refusing afterwards would leave the secret in the working tree for someone
    # to commit later by accident.
    #
    # The pattern list is deliberately not an entropy check, and this is a
    # decision rather than an omission. Entropy scoring on application config
    # false-positives on exactly what these files are full of — hashes, UUIDs,
    # base64 icons, colour tables, minified snippets — and a scanner that cries
    # wolf gets switched off within a week, at which point it is worse than no
    # scanner because it is still trusted and now silent. This catches known key
    # prefixes and suspiciously named assignments and nothing else; it is a
    # backstop, not a guarantee. tests/run.sh pins three benign shapes that must
    # never trip it, so a future entropy check cannot land without proving it
    # does not break them.
    secrets=""
    while IFS="$tab" read -r _kind dest _repo_rel; do
      if [ -z "''${dest:-}" ]; then
        continue
      fi
      if grep -inE '(ghp_|gho_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|"?(api_?key|secret|password|token)"?[[:space:]]*[:=])' "$HOME/$dest" > /dev/null; then
        secrets="$secrets$dest
    "
      fi
    done < <(printf '%s\n' "$candidates")

    if [ -n "$secrets" ]; then
      echo "nd-save: credential-shaped content in these files, nothing copied:" >&2
      printf '%s' "$secrets" | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '  %s\n' "$line" >&2
        fi
      done
      echo "nd-save: remove it, or copy and stage by hand with git add -p" >&2
      exit 1
    fi

    # Three versions of any managed file exist: the store source, the live file
    # in $HOME, and the file in the repo working tree. Drift is a difference
    # between the first two. If the third also differs from the store, the repo
    # carries an edit that has not been placed yet, and copying over it destroys
    # work that nd-save never even showed you — the preview is computed after
    # the copy.
    #
    # nd-switch gets the analogous case right and documents why: it compares
    # against the store, not the repo, because comparing to the repo cannot
    # distinguish "the app changed this" from "I edited the repo and want to
    # place it". This is the same three-way awareness on the save side.
    #
    # The rule is conditional on purpose. "The repo differs from the store" is
    # the right question for a declared file and a meaningless one for a file
    # the application just invented, which has no store source at all — for
    # those the question is whether the repo already holds a file there.
    blockers=""
    while IFS="$tab" read -r kind dest repo_rel; do
      if [ -z "''${dest:-}" ]; then
        continue
      fi
      case "$kind" in
        new)
          if [ -e "$flake/$repo_rel" ]; then
            blockers="$blockers$repo_rel (already in the repo, never placed)
    "
          fi
          ;;
        *)
          # The destination reaches awk through the environment, not through
          # -v: awk runs an assigned value through escape processing, so a
          # destination containing a backslash arrived at the comparison as
          # something else, never matched, and left $src empty — which
          # short-circuited this entire check and reinstated defect 2 for any
          # path with a backslash in it.
          src="$(ND_DEST="$dest" awk -F'\t' \
            'ENVIRON["ND_DEST"] == $2 && $4 == "" { print $1; exit }' "$manifest")"
          if [ -z "$src" ]; then
            # Fail closed. nd-status only calls a path drifted on the strength
            # of a file record, so an empty $src means the manifest disagrees
            # with itself; and "I cannot tell what was placed here" is not a
            # reason to overwrite a file, it is the reason not to.
            if [ -e "$flake/$repo_rel" ]; then
              blockers="$blockers$repo_rel (cannot tell what was placed here)
    "
            fi
          elif [ -e "$flake/$repo_rel" ] && ! cmp -s "$src" "$flake/$repo_rel"; then
            blockers="$blockers$repo_rel (repo copy differs from what was placed)
    "
          fi
          ;;
      esac
    done < <(printf '%s\n' "$candidates")

    if [ -n "$blockers" ] && [ -z "$force" ]; then
      echo "nd-save: the repo carries edits that were never placed; nothing copied:" >&2
      printf '%s' "$blockers" | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '  %s\n' "$line" >&2
        fi
      done
      echo "nd-save: switch first to place them, or re-run with --force to overwrite." >&2
      exit 1
    fi

    copied=""
    paths=()
    while IFS="$tab" read -r kind dest repo_rel; do
      if [ -z "''${dest:-}" ]; then
        continue
      fi
      dir="$(dirname "$flake/$repo_rel")"
      case "$kind" in
        new)
          # A file the application invented has no repo counterpart yet, and its
          # parent may not exist either.
          mkdir -p "$dir"
          ;;
        *)
          # A declared file's directory always exists; if it does not, repoSubdir
          # disagrees with sourceDir and creating it would hide that.
          if [ ! -d "$dir" ]; then
            echo "nd-save: no such directory in the repo: $(dirname "$repo_rel")" >&2
            exit 1
          fi
          ;;
      esac
      # 0644 is deliberate, not an oversight. See the comment in
      # modules/home-manager.nix on why per-file modes are not offered.
      install -m 0644 "$HOME/$dest" "$flake/$repo_rel"
      copied="$copied$dest
    "
      paths+=("$repo_rel")
    done < <(printf '%s\n' "$candidates")

    echo "nd-save: copied back into the repo"
    printf '%s' "$copied" | while IFS= read -r line; do
      if [ -n "$line" ]; then
        printf '  %s\n' "$line"
      fi
    done
    echo

    # Every git operation below takes a pathspec. Unscoped, they each answered
    # the wrong question: `status` answered "is the repository clean" rather
    # than "did the copies change anything"; `diff -- .` showed every unrelated
    # unstaged edit and hid every staged one; and a bare `commit` swept the
    # whole index into a commit whose message says it is application-written
    # config. The repo may be shared, so that is a data leak, not a private
    # mistake.
    #
    # --intent-to-add makes a newly captured file visible to `diff HEAD`, which
    # otherwise shows nothing for an untracked path, and makes it a pathspec
    # `commit --only` will accept.
    #
    # It also mutates the index before the user has agreed to anything, and an
    # intent-to-add entry left behind is not harmless: a later `git commit -am`
    # of the user's own sweeps the file in, which is defect 1's failure coming
    # back through a different door. So record which paths git did not already
    # know, and undo exactly those on any exit that does not commit. Exactly
    # those: resetting a path that was already tracked would silently discard
    # staging the user did themselves.
    untracked=()
    for p in "''${paths[@]}"; do
      if ! git -C "$flake" ls-files --error-unmatch -- "$p" > /dev/null 2>&1; then
        untracked+=("$p")
      fi
    done

    unstage_captures() {
      if [ "''${#untracked[@]}" -gt 0 ]; then
        git -C "$flake" reset -q -- "''${untracked[@]}"
      fi
    }

    # A snapshot of the whole index file is strictly better than the
    # path-scoped reset wherever it is available, because it also puts back
    # staging the user did on a *tracked* managed path — which the `git add`
    # further down replaces, and which no reset can reconstruct. It is not
    # always available: a repository that has never staged anything has no
    # index file yet. So it degrades to the reset rather than depending on it.
    #
    # `--git-path` is resolved relative to the repository, which is where every
    # git invocation here already runs, and it honours a redirected index.
    index_file="$(git -C "$flake" rev-parse --git-path index)"
    case "$index_file" in
      /*) ;;
      *) index_file="$flake/$index_file" ;;
    esac

    index_backup=""
    if [ -f "$index_file" ]; then
      index_backup="$(mktemp)"
      if ! cp -p "$index_file" "$index_backup"; then
        rm -f "$index_backup"
        index_backup=""
      fi
    fi

    restore_index() {
      if [ -n "$index_backup" ]; then
        if cp -p "$index_backup" "$index_file"; then
          return 0
        fi
        echo "nd-save: could not restore the index from $index_backup" >&2
      fi
      unstage_captures
    }

    # Everything below mutates the index, so every exit that is not a
    # successful commit has to put it back — including the exits that are not
    # an `exit` statement at all. A `read` that returns non-zero under errexit,
    # and Ctrl-C, both left the intent-to-add entry behind, and a leftover
    # entry is swept into the user's next `git commit -am`: defect 1's failure
    # arriving through the door E8 did not close.
    #
    # SIGINT is trapped only so that the EXIT trap runs at all; bash does not
    # run an EXIT trap when it dies of an untrapped signal.
    committed=""
    on_exit() {
      if [ -z "$committed" ]; then
        restore_index
      fi
      if [ -n "$index_backup" ]; then
        rm -f "$index_backup"
      fi
    }
    trap on_exit EXIT
    trap 'exit 130' INT

    git -C "$flake" add --intent-to-add -- "''${paths[@]}"

    if [ -z "$(git -C "$flake" status --porcelain -- "''${paths[@]}")" ]; then
      echo "nd-save: copies are identical to the committed versions, nothing to commit"
      exit 0
    fi

    echo "nd-save: changes"
    git -C "$flake" --no-pager diff HEAD -- "''${paths[@]}"
    echo

    echo "nd-save: will commit to branch '$branch'"

    if [ -z "$assume_yes" ]; then
      printf "nd-save: proceed? [y/N] "
      # `read` returns non-zero when the input ends without a newline, and
      # under errexit that killed the script before this `case` could run. An
      # answer that never got terminated is not an answer either way, so it
      # takes the default, which is no: consenting to a commit is worth a
      # newline, and the unattended cases — closed stdin, a dead pipe — must
      # not read as consent.
      if ! read -r reply; then
        reply=""
        echo
      fi
      case "$reply" in
        y | Y) ;;
        *)
          # No line of this may begin "nd-save: committed": `grep nd-save:
          # committed` is the obvious way to ask whether a run succeeded, and
          # the earlier wording wrapped onto exactly that.
          echo "nd-save: aborted, nothing was committed."
          echo "nd-save: the files are copied into the repo working tree, and the"
          echo "nd-save: index is as you left it."
          exit 1
          ;;
      esac
    fi

    if [ -z "$msg" ]; then
      msg="$(derive_subject)"
    fi

    git -C "$flake" add -- "''${paths[@]}"

    # A commit can fail for reasons that have nothing to do with nd-save: a
    # pre-commit hook that rejects the content, commit.gpgsign with no key, a
    # full disk. Under errexit that was a silent exit with the capture left
    # fully staged — exactly the state a later `git commit -am` sweeps up. git
    # has already said why on stderr; this says what it means for the repo.
    if ! git -C "$flake" commit --only -m "$msg" -- "''${paths[@]}"; then
      echo "nd-save: the commit failed, so nothing was committed." >&2
      echo "nd-save: the files are still copied into the repo working tree." >&2
      if [ -n "$index_backup" ]; then
        echo "nd-save: the index is put back to what it was before this run." >&2
      else
        # No snapshot could be taken, so the tracked paths cannot be undone:
        # `git add` replaced whatever was staged on them and only the user
        # knows what that was. Name them rather than exit quietly.
        echo "nd-save: the index could not be snapshotted, so these paths may be" >&2
        echo "nd-save: left staged holding the captured content:" >&2
        printf '%s\n' "''${paths[@]}" | sed 's/^/  /' >&2
      fi
      exit 1
    fi
    committed=1
    echo "nd-save: committed. Not pushed."
  '';
}
