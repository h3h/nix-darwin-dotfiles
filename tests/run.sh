#!/usr/bin/env bash
# Test suite for nd-switch and nd-save.
#
# Runs without sudo, without switching, and without touching the real home
# directory: every case builds a synthetic $HOME, a synthetic manifest and a
# throwaway git repo.
#
# Usage:
#   ND_SWITCH=/path/to/nd-switch ND_SAVE=/path/to/nd-save bash tests/run.sh
#
# If ND_SWITCH/ND_SAVE are unset it falls back to `nix run`, which needs a
# network-capable environment; the nix flake check passes them in explicitly.

set -uo pipefail

ND_SWITCH="${ND_SWITCH:-}"
ND_SAVE="${ND_SAVE:-}"

if [ -z "$ND_SWITCH" ] || [ -z "$ND_SAVE" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  ND_SWITCH="$(nix build --no-link --print-out-paths "$root#nd-switch")/bin/nd-switch"
  ND_SAVE="$(nix build --no-link --print-out-paths "$root#nd-save")/bin/nd-save"
fi

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
  if printf '%s' "$3" | grep -qF "$2"; then ok "$1"; else no "$1" "wanted '$2' in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

check_not() {
  if printf '%s' "$3" | grep -qF "$2"; then no "$1" "did not want '$2'"; else ok "$1"; fi
}

check_status() { # check_status <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "wanted exit $2, got $3"; fi
}

# A fixture is a $HOME with one managed file, a manifest, and a git repo acting
# as the flake. Returns the directory on stdout.
new_fixture() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home/.local/state/nd" "$d/home/.config/app" "$d/repo/files"

  printf 'setting = 1\n' > "$d/store-source"
  chmod 0444 "$d/store-source"

  install -m 0644 "$d/store-source" "$d/home/.config/app/config.toml"
  install -m 0644 "$d/store-source" "$d/repo/files/config.toml"
  printf '{}\n' > "$d/repo/flake.nix"

  printf '%s\t%s\t%s\n' "$d/store-source" ".config/app/config.toml" "files/config.toml" \
    > "$d/home/.local/state/nd/manifest"

  git -C "$d/repo" init -q -b main
  git -C "$d/repo" config user.email t@example.com
  git -C "$d/repo" config user.name Test
  git -C "$d/repo" add -A
  git -C "$d/repo" commit -qm initial
  printf '%s' "$d"
}

drift() { printf 'setting = 2\n' > "$1/home/.config/app/config.toml"; }

run_switch() { HOME="$1/home" ND_FLAKE="$1/repo" "$ND_SWITCH" "${@:2}" 2>&1; }
run_save() { HOME="$1/home" ND_FLAKE="$1/repo" "$ND_SAVE" "${@:2}" 2>&1; }

echo "nd-switch"

d=$(new_fixture)
out=$(run_switch "$d" --help); check "--help prints usage" "usage: nd-switch" "$out"
out=$(run_switch "$d" --rollback abc); st=$?
check "--rollback rejects a non-number" "expects a number" "$out"
check_status "--rollback non-number exits 1" 1 "$st"
out=$(run_switch "$d" --rollback --build); st=$?
check "--rollback with --build is refused" "mutually exclusive" "$out"
check_status "mutually exclusive exits 1" 1 "$st"
rm -rf "$d"

# The gate. This is the behaviour the whole design rests on.
d=$(new_fixture)
out=$(run_switch "$d" --build)
check_not "clean tree does not report drift" "changed since they were placed" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_switch "$d" --build); st=$?
check "drift is detected" "changed since they were placed" "$out"
check "drift names the file" ".config/app/config.toml" "$out"
check "drift suggests nd-save" "nd-save" "$out"
check_status "drift exits 1" 1 "$st"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_switch "$d" --build --allow-dirty)
check_not "--allow-dirty skips the gate" "changed since they were placed" "$out"
rm -rf "$d"

# Flag order must not change behaviour: positional parsing once let
# `--allow-dirty --build` perform a switch instead of a build.
d=$(new_fixture)
for args in "--build" "-b" "--build --allow-dirty" "--allow-dirty --build"; do
  # shellcheck disable=SC2086
  out=$(run_switch "$d" $args)
  check "flag order '$args' still reaches the build step" "building" "$out"
done
rm -rf "$d"

d=$(new_fixture)
rm "$d/repo/flake.nix"
out=$(run_switch "$d" --build); st=$?
check "missing flake.nix is reported" "no flake.nix" "$out"
check_status "missing flake.nix exits 1" 1 "$st"
rm -rf "$d"

echo "nd-save"

d=$(new_fixture)
out=$(run_save "$d" -y)
check "no drift means nothing to save" "nothing to save" "$out"
rm -rf "$d"

d=$(new_fixture)
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_MANIFEST="$d/nope" "$ND_SAVE" -y 2>&1); st=$?
check "missing manifest is reported" "no manifest" "$out"
check_status "missing manifest exits 1" 1 "$st"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_save "$d" -y -m "Update app config")
check "drift is copied back" "copied back into the repo" "$out"
check "drift is committed" "committed" "$out"
check "repo now holds the new content" "setting = 2" "$(cat "$d/repo/files/config.toml")"
check "commit message is used" "Update app config" "$(git -C "$d/repo" log -1 --format=%s)"
check "only the managed file is committed" "files/config.toml" "$(git -C "$d/repo" show --stat --format= HEAD)"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(printf 'n\n' | HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" 2>&1); st=$?
check "declining aborts" "aborted" "$out"
check_status "declining exits 1" 1 "$st"
check "declining leaves the commit unmade" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# Credentials must stop the copy, not merely the commit: a secret copied into
# the working tree and then refused is a secret waiting to be committed later.
for secret in \
  '"api_key": "sk-abcdefghijklmnopqrstuvwxyz123456"' \
  'token = ghp_abcdefghijklmnopqrstuvwxyz0123456789' \
  'password: hunter2'; do
  d=$(new_fixture)
  printf '%s\n' "$secret" > "$d/home/.config/app/config.toml"
  out=$(run_save "$d" -y); st=$?
  check "credential refused: ${secret:0:18}" "credential-shaped content" "$out"
  check_status "credential exits 1" 1 "$st"
  check_not "credential never reaches the repo" "$secret" "$(cat "$d/repo/files/config.toml")"
  check "repo working tree is untouched" "" "$(git -C "$d/repo" status --porcelain)"
  rm -rf "$d"
done

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
