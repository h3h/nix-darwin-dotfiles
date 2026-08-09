#!/usr/bin/env bash
#
# Cross-engine agreement check for `lib/glob.nix`.
#
# The design's claim is "one translator, two anchoring mechanisms that agree by
# construction": Nix anchors with `builtins.match` (whole string), the shell
# anchors with `grep -qxE` (whole line). Nothing tested that claim, and the
# escaped-metacharacter cases lived in a list that only compared strings, so an
# ERE that GNU grep accepts and `builtins.match` rejects shipped green.
#
# This script closes that. It reads the case table generated from
# `tests/glob.nix`, which already carries the verdict `builtins.match` gave for
# every (ERE, subject) pair, re-runs each pair through `grep -qxE`, and fails if
# the two engines disagree — or if they agree on an answer the case did not want.
#
# Field order, tab-separated: glob, ERE, subject, want, builtins.match verdict.
# Verdicts are 1 for match and 0 for no match.
set -o errexit -o nounset -o pipefail

cases="${1:?usage: glob-engines.sh <cases-file>}"

total=0
failed=0

report() {
  failed=$((failed + 1))
  printf '\nFAIL: %s\n  glob:    %s\n  ere:     %s\n  subject: %s\n' "$1" "$2" "$3" "$4"
}

while IFS=$'\t' read -r g ere s want nix_said; do
  total=$((total + 1))

  # grep exits 0 on match, 1 on no match, 2 on a regex it will not compile.
  # `--` because a translated ERE may begin with `-`.
  rc=0
  printf '%s\n' "$s" | grep -qxE -- "$ere" || rc=$?

  case "$rc" in
    0) grep_said=1 ;;
    1) grep_said=0 ;;
    *)
      report "grep -qxE rejected the ERE (exit $rc)" "$g" "$ere" "$s"
      continue
      ;;
  esac

  if [ "$grep_said" != "$nix_said" ]; then
    report "the two engines disagree" "$g" "$ere" "$s"
    printf '  builtins.match: %s\n  grep -qxE:      %s\n' "$nix_said" "$grep_said"
    continue
  fi

  if [ "$grep_said" != "$want" ]; then
    report "both engines agree on the wrong answer" "$g" "$ere" "$s"
    printf '  want: %s\n  got:  %s\n' "$want" "$grep_said"
  fi
done <"$cases"

# A silently empty table would make every assertion above vacuous.
if [ "$total" -eq 0 ]; then
  printf 'FAIL: no cases were read from %s\n' "$cases"
  exit 1
fi

printf '\nglob engines: %d cases, %d failed\n' "$total" "$failed"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
