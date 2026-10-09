{
  writeShellApplication,
  coreutils,
  gnused,
  gnugrep,
  jq,
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
    jq
    nd-status
  ];
  text = ''
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"
    # /bin/hostname is macOS's, and its -s is what the nd-host-option design
    # chose. A Linux build sandbox has no /bin/hostname at all, so the bare call
    # failed before argument parsing and took even --help down with it.
    # `uname -n` (coreutils, so always on PATH here) with the domain cut off is
    # the same short name.
    if [ -x /bin/hostname ]; then
      default_host="$(/bin/hostname -s)"
    else
      default_host="$(uname -n)"
      default_host="''${default_host%%.*}"
    fi
    host="''${ND_HOST:-$default_host}"
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"
    build_only=""
    allow_dirty=""
    rollback=""
    steps=1
    tab="$(printf '\t')"

    # Both of these read the system profile, which a build sandbox (and a
    # machine whose system profile lives elsewhere) does not have. Under
    # errexit and pipefail a missing directory killed the script in the middle
    # of a switch that had already built, so an absent profile now reads as "no
    # generations": the printed rollback hint is skipped and a numbered
    # rollback says there is nothing to go back to.
    gens() {
      if [ ! -d /nix/var/nix/profiles ]; then
        return 0
      fi
      find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' \
        | sed 's|.*/system-\([0-9]*\)-link|\1|' | sort -n
    }

    current_gen() {
      readlink /nix/var/nix/profiles/system 2> /dev/null \
        | sed 's|system-\([0-9]*\)-link|\1|' || true
    }

    # Parsed as a loop so flags work in any order.
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
          echo "  --build         build only, no sudo, no switch; reports drift instead of"
          echo "                  refusing it"
          echo "  --allow-dirty   switch anyway, discarding the contents of drifted"
          echo "                  files; they are named before anything is built"
          echo "  --rollback [N]  go back N generations (default 1)"
          echo "  ND_OVERRIDES  extra sources to build from local checkouts (set by the module)"
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

    # Refuse to place over config an application rewrote. The comparison is
    # against the store path the current generation installed, not against the
    # repo: comparing to the repo cannot tell "the app changed this file" from
    # "I edited the repo and want to place it", and would refuse exactly the
    # switch you meant to run. nd-status owns that comparison.
    #
    # Only `drifted` blocks, and only when called with an empty label. A
    # `missing` file will be restored by the switch and a `new` file has no
    # store source to be overwritten by, so neither has anything for the gate to
    # protect — but both are reported, because restoring a file somebody deleted
    # on purpose without saying so is the behaviour defect 6 is about.
    #
    # With a label — "--allow-dirty", "--rollback" — the drift list is printed
    # anyway and says the contents are about to be discarded. Defect 10: the
    # refusal path named every drifted file and the destructive path named none,
    # so the flag that reads as "proceed" silently meant "overwrite". Every
    # caller runs this before `nix build` and before the sudo prompt, so there
    # is still time to interrupt.
    #
    # Returns 1 only when the gate refuses.
    report_status() {
      local label="$1"
      local status drifted missing created unreadable unknown captured

      if [ ! -f "$manifest" ]; then
        return 0
      fi

      status="$(nd-status)"

      drifted="$(printf '%s\n' "$status" | grep "^drifted$tab" | cut -f2 || true)"
      missing="$(printf '%s\n' "$status" | grep "^missing$tab" | cut -f2 || true)"
      created="$(printf '%s\n' "$status" | grep "^new$tab" | cut -f2 || true)"
      unreadable="$(printf '%s\n' "$status" | grep "^unreadable$tab" | cut -f2 || true)"
      captured="$(printf '%s\n' "$status" | grep "^captured$tab" | cut -f2 || true)"
      # Anything else is a kind this nd-switch predates. Saying so beats
      # dropping it, which is how a newer nd-status paired with an older
      # nd-switch would quietly lose a whole category — the same silence
      # defect 10 is about, one version skew away.
      unknown="$(printf '%s\n' "$status" | grep -v '^$' \
        | grep -vE "^(drifted|missing|new|unreadable|captured)$tab" || true)"

      if [ -n "$missing" ]; then
        echo "nd-switch: these managed files are gone and will be restored:" >&2
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
      fi

      if [ -n "$created" ]; then
        echo "nd-switch: these files are not yet in the repo:" >&2
        printf '%s\n' "$created" | sed 's/^/  /' >&2
        echo "nd-switch: run 'nd-save' to capture them." >&2
      fi

      if [ -n "$unreadable" ]; then
        echo "nd-switch: the source these files were placed from cannot be read:" >&2
        printf '%s\n' "$unreadable" | sed 's/^/  /' >&2
        echo "nd-switch: whether they changed since cannot be told, and this switch will overwrite them." >&2
        echo "nd-switch: nd-save reports them too, and skips them — there is nothing it can compare." >&2
        echo "nd-switch: switching rewrites the manifest, which is what repairs this." >&2
      fi

      if [ -n "$unknown" ]; then
        echo "nd-switch: nd-status reported kinds this nd-switch does not know:" >&2
        printf '%s\n' "$unknown" | sed 's/^/  /' >&2
        echo "nd-switch: they are outside the drift gate; nd-switch and nd-status may be out of step." >&2
      fi

      # Not a finding the gate acts on, and deliberately reported anyway. The
      # live file differs from what this generation placed, so something did
      # rewrite it — but the repo already holds that content, so the switch
      # rebuilds the file from it and discards nothing. Saying so is what tells
      # the user why a file they know changed is not being refused.
      if [ -n "$captured" ]; then
        echo "nd-switch: these changed since they were placed, and the repo already holds the change:" >&2
        printf '%s\n' "$captured" | sed 's/^/  /' >&2

        # The first line and the file list are true for every label; only the
        # closing sentence has to vary, because this block used to print one
        # sentence written for a plain switch and hand it to every label
        # unexamined. A rollback places the PREVIOUS generation's store content,
        # not the repo working tree — it does not build from the repo at all —
        # so "switching re-places them from the repo" is false there, and it
        # will revert a file this block just called safe. --build places
        # nothing, so the same sentence is false for the opposite reason. Only
        # an ordinary switch, with or without --allow-dirty riding along, is
        # actually about to re-place anything from the repo.
        case "$label" in
          --build)
            echo "nd-switch: nothing is being placed, so they are left alone." >&2
            ;;
          --rollback)
            echo "nd-switch: the repo holds this content, but a rollback places the older generation's copy instead — these files will be reverted." >&2
            ;;
          *)
            echo "nd-switch: switching re-places them from the repo; nothing is lost." >&2
            ;;
        esac
      fi

      if [ -n "$drifted" ]; then
        if [ -z "$label" ]; then
          echo "nd-switch: these files changed since they were placed:" >&2
          printf '%s\n' "$drifted" | sed 's/^/  /' >&2
          echo "nd-switch: switching would overwrite them." >&2
          echo "nd-switch: run 'nd-save' to copy them back and commit, or --allow-dirty to discard" >&2
          return 1
        fi

        # --build places nothing, so the OVERWRITTEN wording the other labels
        # use is simply false here, and a false warning is how a true one stops
        # being read.
        if [ "$label" = "--build" ]; then
          echo "nd-switch: --build: these files changed since they were placed:" >&2
          printf '%s\n' "$drifted" | sed 's/^/  /' >&2
          echo "nd-switch: nothing is being placed, so they are left alone." >&2
          return 0
        fi

        echo "nd-switch: $label: these files changed since they were placed and will be OVERWRITTEN:" >&2
        printf '%s\n' "$drifted" | sed 's/^/  /' >&2
        echo "nd-switch: their contents will be discarded. Run 'nd-save' first to keep them." >&2
      fi

      return 0
    }

    if [ -n "$rollback" ]; then
      # A rollback warns and proceeds; it does not gate. Reaching for a rollback
      # usually means something is already broken, and refusing to run the
      # repair is the worse trade. Whether it should honour the gate, with
      # --allow-dirty as the override, is E17 and is the maintainer's call.
      report_status "--rollback"

      current="$(current_gen)"

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

    if [ -n "$build_only" ]; then
      # Checked before --allow-dirty: --build never switches, even when
      # --allow-dirty rides along, so the OVERWRITTEN/discarded wording would
      # be false for this invocation — and a false warning teaches the user to
      # skim the true one. A caller who wants the discard warning gets it on
      # the run that can actually discard: a switch without --build.
      #
      # Reports everything and refuses nothing. --build cannot discard drift
      # because it places nothing, and the gate blocking it took away the only
      # non-destructive way to inspect the state while stuck behind the gate.
      report_status "--build" || true
    elif [ -n "$allow_dirty" ]; then
      report_status "--allow-dirty"
    else
      if ! report_status ""; then
        exit 1
      fi
    fi

    if [ ! -e "$flake/flake.nix" ]; then
      echo "nd-switch: no flake.nix in $flake" >&2
      exit 1
    fi

    # Each programs.nd.sources entry is a flake input whose files nd-save
    # captures into a local checkout. Building the locked revision instead would
    # make `captured` a lie: the capture is in the checkout, the lock does not
    # have it, and the switch would overwrite the live file with older content.
    # So each usable checkout overrides its input, and the lock is allowed to
    # lag — which is said out loud, because a lagging lock is how a change ends
    # up working on this machine and nowhere else.
    #
    # git+file sees uncommitted edits to tracked files and not untracked ones:
    # the same visibility the default flake has, which `captured` relies on.
    #
    # A root input is recorded either as a node name or, when it follows another
    # flake's input, as a path of input names to walk from the root — and each
    # step of that walk can itself be a follows path. Treating every reference
    # as a node name found nothing for a followed input, and an empty answer
    # printed nothing at all, which reads exactly like "the lock is current".
    locked_rev() { # locked_rev <input>
      # shellcheck disable=SC2016  # $n, $i and $ref are jq variables.
      jq -r --arg i "$1" '
        .nodes as $n
        | def node($ref):
            if ($ref | type) == "array"
            then reduce $ref[] as $k ("root"; node($n[.].inputs[$k]))
            else $ref
            end;
          $n[node($n.root.inputs[$i])].locked.rev // empty
      ' "$flake/flake.lock" 2> /dev/null || true
    }

    override_args=()
    while IFS="$tab" read -r ovr_input ovr_checkout; do
      if [ -z "''${ovr_input:-}" ]; then
        continue
      fi
      if [ -f "$ovr_checkout/flake.nix" ] \
        && git -C "$ovr_checkout" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        # The physical path, because nix refuses a git+file URL that runs
        # through a symlink — and on macOS /var and /tmp are both symlinks.
        ovr_physical="$(cd "$ovr_checkout" && pwd -P)"
        override_args+=(--override-input "$ovr_input" "git+file://$ovr_physical")
        ovr_head="$(git -C "$ovr_checkout" rev-parse HEAD 2> /dev/null || true)"
        echo "nd-switch: $ovr_input from $ovr_checkout (HEAD ''${ovr_head:0:7})"
        ovr_locked="$(locked_rev "$ovr_input")"
        if [ -z "$ovr_locked" ]; then
          echo "nd-switch:   flake.lock has no locked revision for $ovr_input; cannot tell whether it is behind the checkout"
        elif [ -n "$ovr_head" ] && [ "$ovr_head" != "$ovr_locked" ]; then
          echo "nd-switch:   lock is at ''${ovr_locked:0:7} — push it, then: nix flake update $ovr_input"
        fi
      else
        echo "nd-switch: $ovr_input: no checkout at $ovr_checkout, building the locked revision"
      fi
    done <<< "''${ND_OVERRIDES:-}"

    echo "nd-switch: building $host from $flake"
    nix build --no-link "$flake#darwinConfigurations.$host.system" "''${override_args[@]}"

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

    sudo darwin-rebuild switch --flake "$flake#$host" "''${override_args[@]}" "$@"

    echo "nd-switch: done. Relaunch your terminal fully if PATH or packages changed."
  '';
}
