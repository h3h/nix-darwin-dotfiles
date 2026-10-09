#!/usr/bin/env bash
# Integration test for nd-switch's --override-input, against the real nix.
#
# tests/run.sh proves nd-switch passes the right arguments, to a stub nix. That
# leaves the two facts the multi-source design actually rests on unproven:
# that nix builds the checkout's working tree — uncommitted edits included —
# rather than the locked revision, and that it does so without rewriting the
# consumer's flake.lock. Both need a real nix and a real store, which a build
# sandbox does not have, so this runs outside it: in CI, or by hand.
#
# The consumer flake's only output is a derivation whose builder fails unless
# the input's value is "working". The input's committed value is "locked" and
# its working tree says "working", so the build succeeding is the proof that
# the checkout was used, and the build failing without the override is the
# proof that the test can tell the difference.
#
# Usage:
#   ND_SWITCH=/path/to/nd-switch bash tests/integration.sh
#
# If ND_SWITCH is unset it is built from this flake.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ND_SWITCH="${ND_SWITCH:-$(nix build --no-link --print-out-paths "$root#nd-switch")/bin/nd-switch}"

pass=0
fail=0

ok() {
  printf '  ok   %s\n' "$1"
  pass=$((pass + 1))
}

no() {
  printf '  FAIL %s\n' "$1"
  printf '       %s\n' "$2"
  fail=$((fail + 1))
}

check() { # check <name> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -e "$2"; then ok "$1"; else no "$1" "wanted '$2' in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

check_status() { # check_status <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "wanted exit $2, got $3"; fi
}

git_init() { # git_init <dir>
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
  git -C "$1" config commit.gpgsign false
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

system="$(nix eval --impure --raw --expr builtins.currentSystem)"

mkdir -p "$tmp/dep" "$tmp/consumer" "$tmp/home"

printf 'locked' > "$tmp/dep/value"
cat > "$tmp/dep/flake.nix" << 'EOF'
{
  outputs = _: { value = builtins.readFile ./value; };
}
EOF
git_init "$tmp/dep"
git -C "$tmp/dep" add -A
git -C "$tmp/dep" commit -qm initial

# /bin/sh is in the default sandbox paths on both darwin and Linux, so the
# builder needs nothing from nixpkgs and the test downloads nothing.
cat > "$tmp/consumer/flake.nix" << EOF
{
  inputs.dep.url = "git+file://$tmp/dep";
  outputs =
    { dep, ... }:
    {
      darwinConfigurations.example.system = builtins.derivation {
        name = "nd-integration";
        system = "$system";
        builder = "/bin/sh";
        args = [
          "-c"
          "test \"\$value\" = working && echo ok > \$out"
        ];
        value = dep.value;
      };
    };
}
EOF
git_init "$tmp/consumer"
git -C "$tmp/consumer" add -A
nix flake lock "$tmp/consumer" 2> /dev/null
git -C "$tmp/consumer" add -A
git -C "$tmp/consumer" commit -qm initial
cp "$tmp/consumer/flake.lock" "$tmp/lock.before"

# The edit nd-save would have made: tracked, uncommitted.
printf 'working' > "$tmp/dep/value"

run() { # run <ND_OVERRIDES> [args...]
  HOME="$tmp/home" ND_FLAKE="$tmp/consumer" ND_HOST=example ND_OVERRIDES="$1" \
    "$ND_SWITCH" --build "${@:2}" 2>&1
}

echo "nd-switch against a real nix"

out=$(run ""); st=$?
check_status "without the override, the locked revision is built and fails" 1 "$([ "$st" -ne 0 ] && echo 1 || echo 0)"

lock_unchanged() { # lock_unchanged <name>
  if cmp -s "$tmp/lock.before" "$tmp/consumer/flake.lock"; then
    ok "$1"
  else
    no "$1" "$(diff "$tmp/lock.before" "$tmp/consumer/flake.lock" | head -20)"
  fi
  check_status "$1 (working tree clean)" 0 \
    "$([ -z "$(git -C "$tmp/consumer" status --porcelain)" ] && echo 0 || echo 1)"
}

# mktemp's directory is under /var/folders on macOS, and /var is a symlink, so
# this also covers nd-switch handing nix the checkout's physical path.
ovr="$(printf 'dep\t%s' "$tmp/dep")"

out=$(run "$ovr"); st=$?
check_status "with the override, the checkout's uncommitted edit is built" 0 "$st"
check "the checkout is named" "nd-switch: dep from $tmp/dep" "$out"
# The lock pins a commit, and HEAD is still that commit: an uncommitted edit is
# not a lagging lock, and nix's own "Git tree … is dirty" warning covers it.
if printf '%s' "$out" | grep -qF "lock is at"; then
  no "an uncommitted edit is not reported as a lagging lock" "$(printf '%s' "$out" | tr '\n' '|')"
else
  ok "an uncommitted edit is not reported as a lagging lock"
fi
lock_unchanged "the consumer's flake.lock is unchanged"

# Committing moves HEAD past the lock, which is the case the lag line is for.
git -C "$tmp/dep" commit -qam working
out=$(run "$ovr"); st=$?
check_status "with the override, the checkout's new commit is built" 0 "$st"
check "the lagging lock is named" "lock is at" "$out"
check "the update command names the input" "nix flake update dep" "$out"
lock_unchanged "the consumer's flake.lock is still unchanged"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
