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
ND_STATUS="${ND_STATUS:-}"

if [ -z "$ND_SWITCH" ] || [ -z "$ND_SAVE" ] || [ -z "$ND_STATUS" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  ND_SWITCH="$(nix build --no-link --print-out-paths "$root#nd-switch")/bin/nd-switch"
  ND_SAVE="$(nix build --no-link --print-out-paths "$root#nd-save")/bin/nd-save"
  ND_STATUS="$(nix build --no-link --print-out-paths "$root#nd-status")/bin/nd-status"
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

check_empty() { # check_empty <name> <actual>
  if [ -z "$2" ]; then ok "$1"; else no "$1" "wanted empty, got: $2"; fi
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

# A $HOME with a glob-tracked root: two placed files, a manifest carrying both
# file records and a glob record, and a git repo acting as the flake.
#
# The ERE in the manifest is what globToERE produces for "**/*.lua" — the
# manifest carries regexes, not globs, so the shell never parses a glob.
new_glob_fixture() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home/.local/state/nd" "$d/home/.config/nv/lua" \
           "$d/repo/files/nv/lua" "$d/store/lua"

  printf 'return 1\n' > "$d/store/init.lua"
  printf 'return 2\n' > "$d/store/lua/plug.lua"
  chmod 0444 "$d/store/init.lua" "$d/store/lua/plug.lua"

  install -m 0644 "$d/store/init.lua"     "$d/home/.config/nv/init.lua"
  install -m 0644 "$d/store/lua/plug.lua" "$d/home/.config/nv/lua/plug.lua"
  install -m 0644 "$d/store/init.lua"     "$d/repo/files/nv/init.lua"
  install -m 0644 "$d/store/lua/plug.lua" "$d/repo/files/nv/lua/plug.lua"
  printf '{}\n' > "$d/repo/flake.nix"

  {
    printf '%s\t%s\t%s\n' "$d/store/init.lua"     ".config/nv/init.lua"     "files/nv/init.lua"
    printf '%s\t%s\t%s\n' "$d/store/lua/plug.lua" ".config/nv/lua/plug.lua" "files/nv/lua/plug.lua"
    printf '%s\t%s\t%s\t%s\t%s\n' "$d/store" ".config/nv" "files/nv" "glob" '(.*/)?[^/]*\.lua'
    printf '%s\t%s\t%s\t%s\t%s\n' "$d/store" ".config/nv" "files/nv" "glob" 'lazy-lock\.json'
  } > "$d/home/.local/state/nd/manifest"

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
run_status() { HOME="$1/home" "$ND_STATUS" "${@:2}" 2>&1; }

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

# Defect 6. A deletion is not drift and must not block, but it must be said.
# The fixture's flake.nix is a stub, so nd-switch --build reaches `nix build`
# and fails there; the assertion is on the absence of the block, not the exit
# status. Every existing --build case has the same shape.
d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_switch "$d" --build)
check "a missing file is named" "will be restored" "$out"
check "a missing file names the path" ".config/app/config.toml" "$out"
check_not "a missing file does not block" "changed since they were placed" "$out"
rm -rf "$d"

# A new file cannot be overwritten by a switch — there is nothing in the store
# to overwrite it with — so the gate has nothing to protect and must not fire.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_switch "$d" --build)
check "a new file is named" "not yet in the repo" "$out"
check "a new file names the path" "lazy-lock.json" "$out"
check_not "a new file does not block" "changed since they were placed" "$out"
rm -rf "$d"

# --allow-dirty suppresses the block, not the reports.
d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_switch "$d" --build --allow-dirty)
check "--allow-dirty still reports missing" "will be restored" "$out"
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
rm -rf "$d"

# Defect 1. `git commit` with no pathspec commits everything already in the
# index, so anything the user staged beforehand lands in a commit whose message
# says it is application-written config. The fixture must therefore contain
# something else, staged.
d=$(new_fixture)
printf 'unrelated\n' > "$d/repo/other.txt"
git -C "$d/repo" add other.txt
git -C "$d/repo" commit -qm "add other"
printf 'half-finished edit\n' > "$d/repo/other.txt"
git -C "$d/repo" add other.txt
drift "$d"
out=$(run_save "$d" -y)
check "the commit touches the managed file" "files/config.toml" "$(git -C "$d/repo" show --stat --format= HEAD)"
check_not "the commit does not touch the staged file" "other.txt" "$(git -C "$d/repo" show --stat --format= HEAD)"
check "the unrelated edit is still staged" "other.txt" "$(git -C "$d/repo" diff --cached --name-only)"
check "the unrelated edit is still uncommitted" "half-finished edit" "$(cat "$d/repo/other.txt")"
rm -rf "$d"

# The preview showed every unrelated unstaged edit and hid every staged one —
# precisely the content the unscoped commit was about to sweep in.
d=$(new_fixture)
printf 'noise\n' > "$d/repo/noise.txt"
git -C "$d/repo" add noise.txt
git -C "$d/repo" commit -qm "add noise"
printf 'unstaged noise\n' > "$d/repo/noise.txt"
drift "$d"
out=$(run_save "$d" -y)
check_not "the preview excludes unrelated edits" "unstaged noise" "$out"
check "the preview includes the managed change" "setting = 2" "$out"
rm -rf "$d"

# A repository-wide `git status` answered "is the repo clean" when the question
# was "did the copies change anything", so an unrelated edit made nd-save
# proceed past an exit it should have taken.
d=$(new_fixture)
printf 'noise\n' > "$d/repo/noise.txt"
git -C "$d/repo" add noise.txt
git -C "$d/repo" commit -qm "add noise"
printf 'unstaged noise\n' > "$d/repo/noise.txt"
# The live file differs from the store but matches what is already committed,
# so there is genuinely nothing to commit.
printf 'setting = 1\n' > "$d/home/.config/app/config.toml"
touch "$d/home/.config/app/config.toml"
out=$(run_save "$d" -y)
check "an unrelated edit does not make nd-save commit" "nothing to save" "$out"
check "no commit was made" "add noise" "$(git -C "$d/repo" log -1 --format=%s)"
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
  check_empty "repo working tree is untouched" "$(git -C "$d/repo" status --porcelain)"
  rm -rf "$d"
done

# Defect 2. Three versions of a managed file exist: the store source, the live
# file, and the repo working tree. nd-save compared only the first two before
# overwriting the third, so an edit made in the repo and not yet placed was
# destroyed with no warning, no backup, and no mention in the preview — the
# preview is computed after the copy, so it showed the app's content as though
# it were the only change.
d=$(new_fixture)
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y); st=$?
check "an unplaced repo edit is refused" "never placed" "$out"
check "the refusal names the file" "files/config.toml" "$out"
check_status "the refusal exits 1" 1 "$st"
check "the repo edit survives" "my unplaced edit" "$(cat "$d/repo/files/config.toml")"
check "nothing was committed" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# --force is the escape hatch. It must overwrite, because that is what it says.
d=$(new_fixture)
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y --force)
check "--force overwrites" "copied back into the repo" "$out"
check "--force really overwrote" "setting = 2" "$(cat "$d/repo/files/config.toml")"
rm -rf "$d"

# The related bug at the old :126-128: every manifest entry whose repo file
# existed was staged, so an uncommitted edit to a managed file that had NOT
# drifted was committed anyway.
d=$(new_fixture)
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/files/config.toml"
out=$(run_save "$d" -y)
check "an undrifted file with a repo edit is not committed" "nothing to save" "$out"
check "the repo edit survives" "my unplaced edit" "$(cat "$d/repo/files/config.toml")"
check "nothing was committed" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# The rule is conditional. "Repo differs from store" is meaningless for a file
# the app just invented, which has no store source at all — for those the
# question is whether the repo already has a file there.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_save "$d" -y)
check "a new capture with no repo counterpart proceeds" "copied back into the repo" "$out"
check "the new file lands in the repo" '"plug":"abc"' "$(cat "$d/repo/files/nv/lazy-lock.json")"
rm -rf "$d"

d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
printf '{"plug":"mine"}\n' > "$d/repo/files/nv/lazy-lock.json"
out=$(run_save "$d" -y); st=$?
check "a new capture whose repo file exists is refused" "never placed" "$out"
check_status "that refusal exits 1" 1 "$st"
check "the repo file survives" '"plug":"mine"' "$(cat "$d/repo/files/nv/lazy-lock.json")"
rm -rf "$d"

# Parent directories for a capture in a subdirectory the repo does not have.
d=$(new_glob_fixture)
mkdir -p "$d/home/.config/nv/lua/deep"
printf 'return 4\n' > "$d/home/.config/nv/lua/deep/new.lua"
out=$(run_save "$d" -y)
check "a nested capture creates its repo directory" "copied back into the repo" "$out"
check "the nested file lands in the repo" "return 4" "$(cat "$d/repo/files/nv/lua/deep/new.lua")"
rm -rf "$d"

echo "nd-status"

d=$(new_fixture)
out=$(run_status "$d")
check_empty "clean fixture reports nothing" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_status "$d")
check "drifted is classified" "drifted	.config/app/config.toml	files/config.toml" "$out"
rm -rf "$d"

d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_status "$d")
check "a deleted file is missing, not drifted" "missing	.config/app/config.toml	files/config.toml" "$out"
check_not "a deleted file is not drift" "drifted" "$out"
rm -rf "$d"

d=$(new_fixture)
out=$(HOME="$d/home" ND_MANIFEST="$d/nope" "$ND_STATUS" 2>&1); st=$?
check "missing manifest is reported" "no manifest" "$out"
check_status "missing manifest exits 1" 1 "$st"
rm -rf "$d"

# Findings are not an error condition. Callers decide what a finding means.
d=$(new_fixture)
drift "$d"
HOME="$d/home" "$ND_STATUS" > /dev/null 2>&1; st=$?
check_status "findings still exit 0" 0 "$st"
rm -rf "$d"

d=$(new_glob_fixture)
out=$(run_status "$d")
check_empty "glob fixture with no extra files reports nothing" "$out"
rm -rf "$d"

# The whole point of defect 7: a file the application invented.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_status "$d")
check "an app-created file is new" "new	.config/nv/lazy-lock.json	files/nv/lazy-lock.json" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf 'return 3\n' > "$d/home/.config/nv/lua/extra.lua"
out=$(run_status "$d")
check "a new file in a subdirectory is found" "new	.config/nv/lua/extra.lua	files/nv/lua/extra.lua" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf 'junk\n' > "$d/home/.config/nv/notes.txt"
out=$(run_status "$d")
check_not "a file matching no pattern is ignored" "notes.txt" "$out"
rm -rf "$d"

# A placed file is inside the glob root and matches the pattern. It is already
# tracked; reporting it as new would make every switch look like a capture.
d=$(new_glob_fixture)
out=$(run_status "$d")
check_not "a placed file inside the root is never new" "new	.config/nv/init.lua" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
drift_glob() { printf 'return 99\n' > "$1/home/.config/nv/init.lua"; }
drift_glob "$d"
out=$(run_status "$d")
check "a placed file inside the root still drifts" "drifted	.config/nv/init.lua	files/nv/init.lua" "$out"
rm -rf "$d"

# Two patterns could both match one file. It must be reported once.
d=$(new_glob_fixture)
printf '%s\t%s\t%s\t%s\t%s\n' "$d/store" ".config/nv" "files/nv" "glob" '(.*/)?extra\.lua' \
  >> "$d/home/.local/state/nd/manifest"
printf 'return 3\n' > "$d/home/.config/nv/lua/extra.lua"
out=$(run_status "$d" | grep -c 'extra.lua')
check "a file matching two patterns is emitted once" "1" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
ln -s /etc/hosts "$d/home/.config/nv/link.lua"
mkdir -p "$d/home/.config/nv/dir.lua"
out=$(run_status "$d")
check_not "a symlink under the root is skipped" "link.lua" "$out"
check_not "a directory under the root is skipped" "dir.lua" "$out"
rm -rf "$d"

# The output format is line-based and cannot represent this. Skipping loudly
# beats emitting a line every consumer parses as two.
d=$(new_glob_fixture)
touch "$d/home/.config/nv/$(printf 'we\nird').lua"
out=$(run_status "$d")
check "a path with a newline is skipped with a warning" "skipping path with a newline" "$out"
check_not "a path with a newline is not emitted" "new	.config/nv/we" "$out"
rm -rf "$d"

# A glob root the application has not created yet is not an error.
d=$(new_glob_fixture)
rm -rf "$d/home/.config/nv"
out=$(run_status "$d"); st=$?
check_status "an absent glob root exits 0" 0 "$st"
check "an absent glob root reports its files missing" "missing	.config/nv/init.lua" "$out"
rm -rf "$d"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
