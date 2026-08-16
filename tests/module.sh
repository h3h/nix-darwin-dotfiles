#!/usr/bin/env bash
# Test suite for modules/home-manager.nix.
#
# tests/run.sh covers the three binaries against hand-written manifests. This
# covers the other half: the module that writes those manifests, places the
# files and wraps the binaries. The two meet in the "round trip" section, where
# the real nd-status is pointed at a manifest the real module produced.
#
# Everything it needs is built by tests/module.nix and passed in the
# environment; the flake check wires them up.
#
# Usage:
#   nix build .#checks.<system>.module

set -uo pipefail

for v in ND_ACTIVATION ND_ACTIVATION_SPARSE ND_ACTIVATION_AFTER \
  ND_EXPECTED_MANIFEST ND_EXPECTED_SPARSE_MANIFEST ND_ZSH_INIT \
  ND_PACKAGE_NAMES ND_ASSERTION_FAILURES ND_BAD_ASSERTION_FAILURES \
  ND_WRAP_SWITCH ND_WRAP_SAVE ND_WRAP_STATUS ND_WRAP_NOBRANCH_SAVE \
  ND_WRAP_NOHOST_SWITCH \
  ND_STATUS_BIN ND_HOME_DIRECTORY ND_FLAKE_PATH ND_EXPECTED_BRANCH_VALUE \
  ND_MANIFEST_PATH ND_HOST_VALUE; do
  if [ -z "${!v:-}" ]; then
    echo "tests/module.sh: $v is not set" >&2
    exit 1
  fi
done

# The wrapper cases assert on what --set-default does with an inherited value,
# so the four variables must start out genuinely unset. ND_HOST matters most
# here: a developer running this suite on their own machine may well have it
# exported for real.
unset ND_FLAKE ND_MANIFEST ND_EXPECTED_BRANCH ND_HOST

pass=0
fail=0
tab="$(printf '\t')"

ok() {
  printf '  ok   %s\n' "$1"
  pass=$((pass + 1))
}

no() {
  printf '  FAIL %s\n' "$1"
  printf '       %s\n' "$2"
  fail=$((fail + 1))
}

# `--` because an expected string can begin with a dash: field 1 of a glob
# record is exactly that, and without it grep reads the pattern as options and
# reports the case as failed for the wrong reason (the same trap as E11).
check() { # check <name> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else no "$1" "wanted '$2' in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

check_not() {
  if printf '%s' "$3" | grep -qF -- "$2"; then no "$1" "did not want '$2'"; else ok "$1"; fi
}

check_eq() { # check_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    no "$1" "wanted: $(printf '%s' "$2" | tr '\n\t' '|>')
       got:    $(printf '%s' "$3" | tr '\n\t' '|>')"
  fi
}

check_status() { # check_status <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "wanted exit $2, got $3"; fi
}

check_empty() { # check_empty <name> <actual>
  if [ -z "$2" ]; then ok "$1"; else no "$1" "wanted empty, got: $2"; fi
}

check_file_eq() { # check_file_eq <name> <expected-file> <actual-file>
  if [ ! -e "$3" ]; then
    no "$1" "$3 does not exist"
  elif cmp -s "$2" "$3"; then
    ok "$1"
  else
    no "$1" "differs from $2:
$(diff "$2" "$3" | cat -A | head -20)"
  fi
}

check_absent() { # check_absent <name> <path>
  if [ -e "$2" ]; then no "$1" "$2 exists"; else ok "$1"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# home-manager's own activation helper, reduced to the branch that matters:
# `run` executes, or echoes when DRY_RUN is set. Verified against
# home-manager.sh, which tests `[[ -v DRY_RUN ]]` and not the deprecated
# DRY_RUN_CMD.
activate() { # activate <script> <home> [dry]
  local script="$1" home="$2" dry="${3:-}"
  (
    set -eu
    export HOME="$home"
    # Invoked by the sourced activation script, not from here.
    # shellcheck disable=SC2329
    run() {
      if [[ -v DRY_RUN ]]; then
        echo "would run: $*"
      else
        "$@"
      fi
    }
    if [ -n "$dry" ]; then DRY_RUN=1; fi
    # shellcheck disable=SC1090
    source "$script"
  ) 2>&1
}

# makeWrapper emits a shell script that exports its variables and then execs the
# real binary. Shadowing `exec` with a function — bash resolves functions before
# builtins — lets the exports be observed directly, so a case can assert on the
# value rather than on whatever the wrapped program happens to print. The
# behavioural case further down proves the value really reaches the program.
# shellcheck disable=SC2016  # $1 and $2 are the sourced-in-bash -c arguments.
probe_src='
  exec() { :; }
  # shellcheck disable=SC1090
  source "$1" >/dev/null 2>&1
  if [ -z "${!2+x}" ]; then printf NOTSET; else printf "%s" "${!2}"; fi
'

probe() { # probe <wrapper> <var>
  bash -c "$probe_src" bash "$1" "$2"
}

probe_with() { # probe_with <VAR=VALUE> <wrapper> <var>
  env "$1" bash -c "$probe_src" bash "$2" "$3"
}

echo "module evaluation"

check_file_eq "the config raises no assertions" /dev/null "$ND_ASSERTION_FAILURES"

bad="$(cat "$ND_BAD_ASSERTION_FAILURES")"
check "a missing glob source names the option" \
  'programs.nd.globs.".config/gone".source = "nope" must be a directory' "$bad"
check "a missing glob source says it is missing" \
  '"nope" must be a directory under programs.nd.sourceDir; it is missing.' "$bad"
# A source that exists but is not a directory gets past pathExists and then
# throws the same unattributed `cannot read directory …: Not a directory` the
# assertion exists to replace.
check "a glob source that is a file names the option" \
  'programs.nd.globs.".config/notadir".source = "nv/init.lua" must be a directory' "$bad"
check "a glob source that is a file says what it is" \
  '"nv/init.lua" must be a directory under programs.nd.sourceDir; it is a regular.' "$bad"
check "an empty pattern list names the option" \
  'programs.nd.globs.".config/empty".patterns is empty' "$bad"

names="$(cat "$ND_PACKAGE_NAMES")"
check "nd-switch is installed" "nd-switch-nd" "$names"
check "nd-save is installed" "nd-save-nd" "$names"
check "nd-status is installed" "nd-status-nd" "$names"

check_eq "activation runs after the write boundary" "writeBoundary" "$(cat "$ND_ACTIVATION_AFTER")"

zshinit="$(cat "$ND_ZSH_INIT")"
check "the zsh hook sources the notice" "nd-notice.zsh" "$zshinit"
check "the zsh hook calls it" "nd_notice" "$zshinit"

echo
echo "manifest"

# The format contract. nd-status has ~190 cases against manifests written by
# hand in tests/run.sh; until this case existed, nothing compared those with
# what the module writes. Byte-for-byte, so a lost tab, a lost trailing newline,
# a reordered field or a store path in field 1 of a glob record all show up.
h="$tmp/manifest"
mkdir -p "$h"
activate "$ND_ACTIVATION" "$h" > /dev/null
check_file_eq "the manifest is exactly the documented format" \
  "$ND_EXPECTED_MANIFEST" "$h/$ND_MANIFEST_PATH"

manifest="$(cat "$h/$ND_MANIFEST_PATH")"
check "a glob record carries the - placeholder" "-${tab}.config/nv${tab}files/nv${tab}glob${tab}" "$manifest"
check_not "notes.txt matches no pattern and is not recorded" "notes.txt" "$manifest"
check_eq "every glob record has five fields" "5 5" \
  "$(awk -F'\t' '$4 == "glob" { printf "%s ", NF }' "$h/$ND_MANIFEST_PATH" | sed 's/ $//')"
check_eq "every file record has three" "3 3 3" \
  "$(awk -F'\t' '$4 == "" { printf "%s ", NF }' "$h/$ND_MANIFEST_PATH" | sed 's/ $//')"
check_eq "the last line is terminated" "" "$(tail -c 1 "$h/$ND_MANIFEST_PATH")"

# A pattern matching nothing today is the fresh-machine lazy-lock.json state. It
# must yield a glob record and no file records, and it must not be an evaluation
# failure.
h="$tmp/sparse"
mkdir -p "$h"
activate "$ND_ACTIVATION_SPARSE" "$h" > /dev/null
check_file_eq "a pattern matching nothing still records the glob" \
  "$ND_EXPECTED_SPARSE_MANIFEST" "$h/$ND_MANIFEST_PATH"
check_eq "and records no files" "0" \
  "$(awk -F'\t' '$4 == ""' "$h/$ND_MANIFEST_PATH" | grep -c . )"
check_absent "and places nothing" "$h/.config/nv"

echo
echo "dry run (defect 9)"

# The manifest used to be truncated and appended to directly, with only the
# final `mv` going through `run`, so a dry run left an orphaned manifest.new
# behind. The whole point of the fix is that a dry run writes nothing at all.
h="$tmp/dry"
mkdir -p "$h"
out=$(activate "$ND_ACTIVATION" "$h" dry); st=$?
# The unguarded write did not merely leave a file behind: with the state
# directory not yet created, because `run mkdir` is a no-op under DRY_RUN, the
# redirect itself fails and takes the rest of activation with it.
check_status "a dry run completes" 0 "$st"
check "a dry run says what it would do" "would write manifest to" "$out"
check_eq "a dry run writes nothing at all" "" "$(find "$h" -mindepth 1)"
check_eq "a dry run leaves no manifest.new" "" "$(find "$h" -name 'manifest.new')"

# The same, with a manifest already in place: the scratch file must not appear
# beside it and the existing one must not be touched.
h="$tmp/dry-existing"
mkdir -p "$h/$(dirname "$ND_MANIFEST_PATH")"
printf 'stale\n' > "$h/$ND_MANIFEST_PATH"
out=$(activate "$ND_ACTIVATION" "$h" dry)
check_eq "a dry run leaves the existing manifest alone" "stale" "$(cat "$h/$ND_MANIFEST_PATH")"
check_absent "and drops no scratch file beside it" "$h/$ND_MANIFEST_PATH.new"

h="$tmp/wet"
mkdir -p "$h"
out=$(activate "$ND_ACTIVATION" "$h"); st=$?
check_status "a real run completes" 0 "$st"
check "a real run writes the manifest" "$ND_MANIFEST_PATH" "$(find "$h" -type f)"
check_eq "a real run leaves no manifest.new" "" "$(find "$h" -name 'manifest.new')"
check_eq "a real run places the declared file" "setting = 1" "$(cat "$h/.config/app/config.toml")"
check_eq "a real run places the glob matches" "return 1 return 2" \
  "$(cat "$h/.config/nv/init.lua" "$h/.config/nv/lua/plug.lua" | tr '\n' ' ' | sed 's/ $//')"
check_absent "and places nothing a pattern did not match" "$h/.config/nv/notes.txt"

echo
echo "wrappers"

# flakePath and manifestPath were declared, documented and never referenced, so
# every tool fell back to its own hardcoded default (escalation E2). Deleting a
# --set-default below must turn these red.
for w in "$ND_WRAP_SWITCH" "$ND_WRAP_SAVE" "$ND_WRAP_STATUS"; do
  n="$(basename "$w")"
  check_eq "$n gets ND_FLAKE from flakePath" "$ND_FLAKE_PATH" "$(probe "$w" ND_FLAKE)"
  check_eq "$n gets ND_MANIFEST from manifestPath" \
    "$ND_HOME_DIRECTORY/$ND_MANIFEST_PATH" "$(probe "$w" ND_MANIFEST)"
  check_eq "$n gets ND_EXPECTED_BRANCH from expectedBranch" \
    "$ND_EXPECTED_BRANCH_VALUE" "$(probe "$w" ND_EXPECTED_BRANCH)"
  check_eq "$n gets ND_HOST from host" "$ND_HOST_VALUE" "$(probe "$w" ND_HOST)"

  # --set-default, not --set: the documented ND_* overrides and the whole of
  # tests/run.sh depend on an explicit export still winning.
  check_eq "$n lets an explicit ND_FLAKE win" "/elsewhere/flake" \
    "$(probe_with ND_FLAKE=/elsewhere/flake "$w" ND_FLAKE)"
  check_eq "$n lets an explicit ND_MANIFEST win" "/elsewhere/manifest" \
    "$(probe_with ND_MANIFEST=/elsewhere/manifest "$w" ND_MANIFEST)"
  check_eq "$n lets an explicit ND_EXPECTED_BRANCH win" "release" \
    "$(probe_with ND_EXPECTED_BRANCH=release "$w" ND_EXPECTED_BRANCH)"
  check_eq "$n lets an explicit ND_HOST win" "elsewhere" \
    "$(probe_with ND_HOST=elsewhere "$w" ND_HOST)"
done

# An empty expectedBranch means no constraint, which nd-save spells as the
# variable being absent — not as an empty one, which would still be a value the
# wrapper had chosen for the user.
check_eq "an empty expectedBranch sets nothing" "NOTSET" \
  "$(probe "$ND_WRAP_NOBRANCH_SAVE" ND_EXPECTED_BRANCH)"
check_eq "and the other two are still set" "$ND_FLAKE_PATH" \
  "$(probe "$ND_WRAP_NOBRANCH_SAVE" ND_FLAKE)"

# An empty host means "use the short hostname", which the wrapper spells as the
# variable being absent rather than as an empty one. nd-switch's `${ND_HOST:-}`
# would fall back on an empty value anyway, so this pins the intent rather than
# repairing a live bug — but the day that `:-` becomes `-`, an empty export is a
# switch that builds `darwinConfigurations.`, and this is the case that says so.
check_eq "an empty host sets nothing" "NOTSET" \
  "$(probe "$ND_WRAP_NOHOST_SWITCH" ND_HOST)"

# The flag AFTER the omitted one is the direction that can actually break: an
# empty `host` drops a middle element of wrapFlags, which is exactly the
# truncation the list form exists to prevent. The noBranch mirror above checks
# ND_FLAKE, which precedes its conditional and so cannot regress.
check_eq "and the flag after it survives" "$ND_EXPECTED_BRANCH_VALUE" \
  "$(probe "$ND_WRAP_NOHOST_SWITCH" ND_EXPECTED_BRANCH)"

# Reading the exports back is not the same as the program receiving them, so one
# case goes the whole way: nd-status names the manifest it was told to read.
out=$(HOME="$tmp/nowhere" "$ND_WRAP_STATUS" 2>&1)
check "the value reaches the program" "no manifest at $ND_HOME_DIRECTORY/$ND_MANIFEST_PATH" "$out"

echo
echo "round trip"

# The only place the producer and the consumer meet: a $HOME the module's own
# activation script populated, a manifest the module's own manifestText wrote,
# and the real nd-status binary reading both.
h="$tmp/rt"
mkdir -p "$h"
activate "$ND_ACTIVATION" "$h" > /dev/null

out=$(HOME="$h" "$ND_STATUS_BIN" 2>&1)
check_empty "a freshly activated home is clean" "$out"

printf 'return 99\n' > "$h/.config/nv/init.lua"
printf '{"plugins":[]}\n' > "$h/.config/nv/lazy-lock.json"
printf 'scratch\n' > "$h/.config/nv/scratch.txt"
mkdir -p "$h/.config/nv/lua/sub"
printf 'return 3\n' > "$h/.config/nv/lua/sub/deep.lua"

out=$(HOME="$h" "$ND_STATUS_BIN" 2>&1)
want="drifted${tab}.config/nv/init.lua${tab}files/nv/init.lua
new${tab}.config/nv/lazy-lock.json${tab}files/nv/lazy-lock.json
new${tab}.config/nv/lua/sub/deep.lua${tab}files/nv/lua/sub/deep.lua"
check_eq "drift, capture and silence are classified as designed" "$want" "$out"
check_not "a file matching no pattern is reported by nothing" "scratch.txt" "$out"

# Placing the drifted file back makes it clean again, and nothing else changes:
# the classification tracks the file, not a one-off state of the fixture.
install -m 0644 "$(awk -F'\t' '$2 == ".config/nv/init.lua" { print $1 }' "$h/$ND_MANIFEST_PATH")" \
  "$h/.config/nv/init.lua"
out=$(HOME="$h" "$ND_STATUS_BIN" 2>&1)
check_not "restoring the file clears the drift" "drifted" "$out"

rm -f "$h/.config/app/config.toml"
out=$(HOME="$h" "$ND_STATUS_BIN" 2>&1)
check "a deleted declared file is missing" \
  "missing${tab}.config/app/config.toml${tab}files/app/config.toml" "$out"

echo
echo "captured (round trip)"

# The captured side of the round trip: a manifest the module actually wrote,
# read by the real nd-status, against a real git repository standing in for
# the flake. This is the only place the module's own manifestText and
# kind_for's git-tracked check meet — tests/run.sh pins kind_for against
# manifests it writes by hand, never against one the module produced.
#
# ND_FLAKE is set explicitly for this one case, unlike everywhere else in this
# file: line 31 unsets it (and ND_MANIFEST, ND_EXPECTED_BRANCH) so the wrapper
# cases can tell an inherited value from --set-default's, and every other case
# here relies on that unset staying in place. kind_for needs an actual
# repository at the path nd-status is told to read, and the module's own
# flakePath default ($ND_FLAKE_PATH, /opt/flakes/dotfiles) does not exist in
# this sandbox — so this case points ND_FLAKE at one of its own instead of
# touching the unset.
h="$tmp/rt-captured"
mkdir -p "$h"
activate "$ND_ACTIVATION" "$h" > /dev/null

flake="$tmp/rt-captured-flake"
mkdir -p "$flake/files/nv"
git -C "$flake" init -q -b main
git -C "$flake" config user.email t@example.com
git -C "$flake" config user.name Test

printf 'return 99\n' > "$h/.config/nv/init.lua"
install -m 0644 "$h/.config/nv/init.lua" "$flake/files/nv/init.lua"
git -C "$flake" add -A
git -C "$flake" commit -qm captured

out=$(HOME="$h" ND_FLAKE="$flake" "$ND_STATUS_BIN" 2>&1)
check_eq "a file the module placed, then rewritten to match a tracked repo copy, is captured" \
  "captured${tab}.config/nv/init.lua${tab}files/nv/init.lua" "$out"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
