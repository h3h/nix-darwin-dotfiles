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
        -h | --help)
          echo "usage: nd-save [-m MESSAGE] [-y] [--force]"
          echo "  Copies config that applications rewrote back into the flake repo,"
          echo "  then commits it. Never pushes."
          echo "  --force  overwrite repo files that carry edits never placed"
          exit 0
          ;;
        *)
          echo "nd-save: unknown argument: $1" >&2
          exit 1
          ;;
      esac
    done

    # Task 6 consumes this; referenced here so shellcheck does not call the
    # flag's variable unused before then.
    : "$force"

    if [ ! -f "$manifest" ]; then
      echo "nd-save: no manifest at $manifest — has a switch run yet?" >&2
      exit 1
    fi

    if ! git -C "$flake" rev-parse --git-dir > /dev/null 2>&1; then
      echo "nd-save: $flake is not a git repository" >&2
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
    git -C "$flake" add --intent-to-add -- "''${paths[@]}"

    if [ -z "$(git -C "$flake" status --porcelain -- "''${paths[@]}")" ]; then
      echo "nd-save: copies are identical to the committed versions, nothing to commit"
      exit 0
    fi

    echo "nd-save: changes"
    git -C "$flake" --no-pager diff HEAD -- "''${paths[@]}"
    echo

    branch="$(git -C "$flake" branch --show-current)"
    echo "nd-save: will commit to branch '$branch'"

    if [ -z "$assume_yes" ]; then
      printf "nd-save: proceed? [y/N] "
      read -r reply
      case "$reply" in
        y | Y) ;;
        *)
          echo "nd-save: aborted. Files were copied into the repo but nothing was committed."
          exit 1
          ;;
      esac
    fi

    if [ -z "$msg" ]; then
      msg="Update config written by applications"
    fi

    git -C "$flake" add -- "''${paths[@]}"
    git -C "$flake" commit --only -m "$msg" -- "''${paths[@]}"
    echo "nd-save: committed. Not pushed."
  '';
}
