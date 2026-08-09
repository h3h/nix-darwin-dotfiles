{ writeShellApplication, coreutils }:

# nd-save — copy application-written config back into the repo and commit it.
#
# Reads the manifest that the home-manager module writes at activation. Each
# line is: store-source <TAB> path-relative-to-$HOME <TAB> path-relative-to-flake.
#
# A file differs from its store source exactly when something rewrote it after
# it was placed. That is the definition of drift used everywhere here.
writeShellApplication {
  name = "nd-save";
  runtimeInputs = [ coreutils ];
  text = ''
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"
    msg=""
    assume_yes=""

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
        -h | --help)
          echo "usage: nd-save [-m MESSAGE] [-y]"
          echo "  Copies config that applications rewrote back into the flake repo,"
          echo "  then commits it. Never pushes."
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

    # Scan BEFORE copying. Applications write credentials into their own config
    # as a matter of course, and the flake repo may be shared. Copying first and
    # refusing afterwards would leave the secret in the working tree for someone
    # to commit later by accident.
    secrets=""
    while IFS="$(printf '\t')" read -r src dest _repo_rel; do
      [ -n "''${dest:-}" ] || continue
      [ -e "$HOME/$dest" ] || continue
      cmp -s "$src" "$HOME/$dest" && continue
      if grep -inE '(ghp_|gho_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|"?(api_?key|secret|password|token)"?[[:space:]]*[:=])' "$HOME/$dest" >/dev/null; then
        secrets="$secrets$dest
    "
      fi
    done < "$manifest"

    if [ -n "$secrets" ]; then
      echo "nd-save: credential-shaped content in these files, nothing copied:" >&2
      printf '%s' "$secrets" | while IFS= read -r line; do
        [ -n "$line" ] && printf '  %s\n' "$line" >&2
      done
      echo "nd-save: remove it, or copy and stage by hand with git add -p" >&2
      exit 1
    fi

    copied=""
    while IFS="$(printf '\t')" read -r src dest repo_rel; do
      [ -n "''${dest:-}" ] || continue
      [ -e "$HOME/$dest" ] || continue
      if ! cmp -s "$src" "$HOME/$dest"; then
        if [ ! -d "$(dirname "$flake/$repo_rel")" ]; then
          echo "nd-save: no such directory in the repo: $(dirname "$repo_rel")" >&2
          exit 1
        fi
        install -m 0644 "$HOME/$dest" "$flake/$repo_rel"
        copied="$copied$dest
    "
      fi
    done < "$manifest"

    if [ -z "$copied" ]; then
      echo "nd-save: nothing to save, every placed file still matches"
      exit 0
    fi

    echo "nd-save: copied back into the repo"
    printf '%s' "$copied" | while IFS= read -r line; do
      [ -n "$line" ] && printf '  %s\n' "$line"
    done
    echo

    if [ -z "$(git -C "$flake" status --porcelain)" ]; then
      echo "nd-save: copies are identical to the committed versions, nothing to commit"
      exit 0
    fi

    echo "nd-save: changes"
    git -C "$flake" --no-pager diff -- .
    echo

    branch="$(git -C "$flake" branch --show-current)"
    echo "nd-save: will commit to branch '$branch'"

    if [ -z "$assume_yes" ]; then
      printf "nd-save: proceed? [y/N] "
      read -r reply
      case "$reply" in
        y | Y) ;;
        *)
          echo "nd-save: aborted. Files were copied but nothing was staged."
          exit 1
          ;;
      esac
    fi

    if [ -z "$msg" ]; then
      msg="Update config written by applications"
    fi

    while IFS="$(printf '\t')" read -r _src _dest repo_rel; do
      [ -n "''${repo_rel:-}" ] || continue
      [ -e "$flake/$repo_rel" ] && git -C "$flake" add -- "$repo_rel"
    done < "$manifest"

    git -C "$flake" commit -m "$msg"
    echo "nd-save: committed. Not pushed."
  '';
}
