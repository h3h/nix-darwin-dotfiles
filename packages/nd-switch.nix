{
  writeShellApplication,
  coreutils,
  gnused,
  gnugrep,
  nd-status,
}:

# nd-switch — build, then switch, this host's nix-darwin configuration.
#
# Builds before switching so an evaluation error costs nothing and does not sit
# behind a sudo prompt. Refuses to switch while managed config has drifted,
# because a switch would copy over it.
writeShellApplication {
  name = "nd-switch";
  runtimeInputs = [
    coreutils
    gnused
    gnugrep
    nd-status
  ];
  text = ''
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"
    host="''${ND_HOST:-$(/bin/hostname -s)}"
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"
    build_only=""
    allow_dirty=""
    rollback=""
    steps=1

    gens() {
      find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' \
        | sed 's|.*/system-\([0-9]*\)-link|\1|' | sort -n
    }

    # Parsed as a loop so flags work in any order. Positional checks let
    # `--allow-dirty --build` perform a switch, because --build was never
    # consumed and fell through to darwin-rebuild.
    while [ $# -gt 0 ]; do
      case "$1" in
        --rollback | -r)
          rollback=1
          shift
          # An empty case pattern cannot be written inside the Nix indented
          # string this file becomes, so test for "present and not a flag".
          if [ -n "''${1:-}" ] && [ "''${1#-}" = "''${1:-}" ]; then
            case "$1" in
              *[!0-9]*)
                echo "nd-switch: --rollback expects a number, got '$1'" >&2
                exit 1
                ;;
              *)
                steps="$1"
                shift
                ;;
            esac
          fi
          ;;
        --build | -b)
          build_only=1
          shift
          ;;
        --allow-dirty)
          allow_dirty=1
          shift
          ;;
        -h | --help)
          echo "usage: nd-switch [--build] [--allow-dirty] [--rollback [N]] [-- ARGS...]"
          echo "  --build         build only, no sudo, no switch"
          echo "  --allow-dirty   switch even though managed config has drifted"
          echo "  --rollback [N]  go back N generations (default 1)"
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *) break ;;
      esac
    done

    if [ -n "$rollback" ] && [ -n "$build_only" ]; then
      echo "nd-switch: --rollback and --build are mutually exclusive" >&2
      exit 1
    fi

    if [ -n "$rollback" ]; then
      current="$(readlink /nix/var/nix/profiles/system | sed 's|system-\([0-9]*\)-link|\1|')"

      if [ "$steps" -eq 1 ]; then
        echo "nd-switch: rolling back one generation from $current"
        sudo darwin-rebuild switch --rollback "$@"
      else
        # Generations are not contiguous once old ones are collected, so step
        # back through the list that exists rather than subtracting.
        target="$(gens | awk -v cur="$current" -v n="$steps" '
          { g[NR] = $0; if ($0 == cur) idx = NR }
          END { if (idx == "" || idx - n < 1) exit 1; print g[idx - n] }
        ')" || {
          echo "nd-switch: cannot go back $steps from generation $current" >&2
          echo "nd-switch: available: $(gens | tr "\n" " ")" >&2
          exit 1
        }
        echo "nd-switch: switching from generation $current to $target"
        sudo darwin-rebuild switch --switch-generation "$target" "$@"
      fi

      echo "nd-switch: done. Relaunch your terminal fully if PATH or packages changed."
      exit 0
    fi

    # Refuse to place over config an application rewrote. The comparison is
    # against the store path the current generation installed, not against the
    # repo: comparing to the repo cannot tell "the app changed this file" from
    # "I edited the repo and want to place it", and would refuse exactly the
    # switch you meant to run. nd-status owns that comparison.
    #
    # Only `drifted` blocks. A `missing` file will be restored by the switch and
    # a `new` file has no store source to be overwritten by, so neither has
    # anything for the gate to protect — but both are reported, because
    # restoring a file somebody deleted on purpose without saying so is the
    # behaviour defect 6 is about.
    if [ -f "$manifest" ]; then
      status="$(nd-status)"

      drifted="$(printf '%s\n' "$status" | grep '^drifted' | cut -f2 || true)"
      missing="$(printf '%s\n' "$status" | grep '^missing' | cut -f2 || true)"
      created="$(printf '%s\n' "$status" | grep '^new' | cut -f2 || true)"

      if [ -n "$missing" ]; then
        echo "nd-switch: these managed files are gone and will be restored:" >&2
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
      fi

      if [ -n "$created" ]; then
        echo "nd-switch: these files are not yet in the repo:" >&2
        printf '%s\n' "$created" | sed 's/^/  /' >&2
        echo "nd-switch: run 'nd-save' to capture them." >&2
      fi

      if [ -z "$allow_dirty" ] && [ -n "$drifted" ]; then
        echo "nd-switch: these files changed since they were placed:" >&2
        printf '%s\n' "$drifted" | sed 's/^/  /' >&2
        echo "nd-switch: switching would overwrite them." >&2
        echo "nd-switch: run 'nd-save' to copy them back and commit, or --allow-dirty to discard" >&2
        exit 1
      fi
    fi

    if [ ! -e "$flake/flake.nix" ]; then
      echo "nd-switch: no flake.nix in $flake" >&2
      exit 1
    fi

    echo "nd-switch: building $host from $flake"
    nix build --no-link "$flake#darwinConfigurations.$host.system"

    if [ -n "$build_only" ]; then
      echo "nd-switch: build only, not switching"
      exit 0
    fi

    # The numbered generation, so the rollback command is exact. Printed before
    # switching because afterwards this number is the new one.
    gen="$(gens | tail -1)"
    if [ -n "$gen" ]; then
      echo "nd-switch: roll back with  sudo /nix/var/nix/profiles/system-$gen-link/activate"
    fi

    sudo darwin-rebuild switch --flake "$flake#$host" "$@"

    echo "nd-switch: done. Relaunch your terminal fully if PATH or packages changed."
  '';
}
