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

# The zsh notice is a plain file in the repo rather than a built package, so the
# fallback is a path, not a build. The flake check exports it from the store.
ND_NOTICE="${ND_NOTICE:-}"
if [ -z "$ND_NOTICE" ]; then
  ND_NOTICE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/modules/nd-notice.zsh"
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
#
# Field 1 of a glob record is "-", matching what the module writes: no reader
# uses it, and putting a real store path there would copy the source subtree
# into the store a second time for nothing.
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
    printf '%s\t%s\t%s\t%s\t%s\n' "-" ".config/nv" "files/nv" "glob" '(.*/)?[^/]*\.lua'
    printf '%s\t%s\t%s\t%s\t%s\n' "-" ".config/nv" "files/nv" "glob" 'lazy-lock\.json'
  } > "$d/home/.local/state/nd/manifest"

  git -C "$d/repo" init -q -b main
  git -C "$d/repo" config user.email t@example.com
  git -C "$d/repo" config user.name Test
  git -C "$d/repo" add -A
  git -C "$d/repo" commit -qm initial
  printf '%s' "$d"
}

drift() { printf 'setting = 2\n' > "$1/home/.config/app/config.toml"; }

# nd-switch's rollback path ends in `sudo darwin-rebuild`, which the suite
# neither can nor should run. A stub `sudo` that only echoes stands in; the real
# one is never reached because nd-switch takes sudo from the caller's PATH.
stub_bin="$(mktemp -d)"
printf '#!/bin/sh\necho "stub sudo $*"\n' > "$stub_bin/sudo"
chmod +x "$stub_bin/sudo"
trap 'rm -rf "$stub_bin"' EXIT

run_switch() { HOME="$1/home" ND_FLAKE="$1/repo" "$ND_SWITCH" "${@:2}" 2>&1; }
run_rollback() { HOME="$1/home" ND_FLAKE="$1/repo" PATH="$stub_bin:$PATH" "$ND_SWITCH" "${@:2}" 2>&1; }
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

# Defect 10. --allow-dirty bypasses the gate and lets activation overwrite every
# drifted file. It used to print nothing at all: the refusal path named every
# file, the destructive path named none. The bypass still has to happen — hence
# the two assertions that the refusal is absent and the build was reached, both
# of which go red if a gate reappears — but it has to say what it is discarding,
# and say it before `nix build` and before the sudo prompt.
d=$(new_fixture)
drift "$d"
out=$(run_switch "$d" --build --allow-dirty)
check "--allow-dirty names what it will discard" "will be OVERWRITTEN" "$out"
check "--allow-dirty names the file" ".config/app/config.toml" "$out"
check "--allow-dirty says the contents go" "contents will be discarded" "$out"
check "--allow-dirty points at nd-save" "Run 'nd-save' first to keep them" "$out"
check_not "--allow-dirty skips the gate" "run 'nd-save' to copy them back and commit" "$out"
check "--allow-dirty still reaches the build step" "building" "$out"
rm -rf "$d"

# The warning has to come out before anything is built and before sudo is asked
# for anything, or there is nothing left to interrupt.
d=$(new_fixture)
drift "$d"
out=$(run_switch "$d" --build --allow-dirty)
check "the discard warning precedes the build" "OVERWRITTEN" \
  "$(printf '%s\n' "$out" | sed -n '1,/building/p')"
rm -rf "$d"

# --rollback returned before the drift check was ever reached, so a rollback
# overwrote every drifted file in silence — the same loss as defect 10 through a
# door the flag does not even guard. It warns and proceeds; it must not gate.
# See E17.
d=$(new_fixture)
drift "$d"
out=$(run_rollback "$d" --rollback)
check "--rollback names what it will discard" "will be OVERWRITTEN" "$out"
check "--rollback names the file" ".config/app/config.toml" "$out"
check "--rollback says the contents go" "contents will be discarded" "$out"
check_not "--rollback is not blocked" "run 'nd-save' to copy them back and commit" "$out"
check "--rollback still rolls back" "darwin-rebuild switch --rollback" "$out"
rm -rf "$d"

# A clean tree rolls back with nothing said about drift.
d=$(new_fixture)
out=$(run_rollback "$d" --rollback)
check_not "a clean rollback warns about nothing" "OVERWRITTEN" "$out"
check "a clean rollback still rolls back" "darwin-rebuild switch --rollback" "$out"
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
# "changed since they were placed" is only ever emitted on the drifted path, so
# asserting its absence here is vacuous — deleting the whole `missing`
# classification would leave it green. Reaching the build step is the thing that
# actually discriminates: a block exits before it.
check "a missing file does not block" "building" "$out"
rm -rf "$d"

# A new file cannot be overwritten by a switch — there is nothing in the store
# to overwrite it with — so the gate has nothing to protect and must not fire.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_switch "$d" --build)
check "a new file is named" "not yet in the repo" "$out"
check "a new file names the path" "lazy-lock.json" "$out"
check "a new file does not block" "building" "$out"
rm -rf "$d"

# --allow-dirty suppresses the block, not the reports.
d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_switch "$d" --build --allow-dirty)
check "--allow-dirty still reports missing" "will be restored" "$out"
rm -rf "$d"

# An unreadable store source means "I cannot tell whether this drifted". It is
# said out loud and it does not block: the switch is what rewrites the manifest,
# so refusing would leave the tool unable to repair its own state. See E19.
d=$(new_fixture)
rm -f "$d/store-source"
out=$(run_switch "$d" --build)
check "an unreadable source is named" "cannot be read" "$out"
check "an unreadable source names the path" ".config/app/config.toml" "$out"
check "an unreadable source does not block" "building" "$out"
check_not "an unreadable source is not reported as drift" "changed since they were placed" "$out"
check_not "an unreadable source is not an unknown kind" "does not know" "$out"
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

# Declining must leave the index exactly as it was. nd-save runs
# `git add --intent-to-add` before the prompt, so the preview can show a newly
# captured file; an intent-to-add entry left behind after a refusal is swept
# into the user's next `git commit -am`, which is defect 1's failure arriving
# through a different door.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(printf 'n\n' | HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" 2>&1)
check "declining a new capture aborts" "aborted" "$out"
# An intent-to-add entry does not show in `diff --cached`, so ask the index
# directly whether it knows the path at all.
check_empty "declining leaves the capture out of the index" \
  "$(git -C "$d/repo" ls-files -- files/nv/lazy-lock.json)"
# The user's own later commit must not pick the capture up.
printf 'return 9\n' > "$d/repo/files/nv/init.lua"
git -C "$d/repo" commit -qam "my own unrelated commit"
check_not "the declined capture stays out of the user's commit" "lazy-lock.json" \
  "$(git -C "$d/repo" show --stat --format= HEAD)"
rm -rf "$d"

# Declining must NOT unstage work the user staged themselves, including on a
# managed path: only paths git did not already know are reset.
d=$(new_fixture)
printf 'staged by me\n' > "$d/repo/files/config.toml"
git -C "$d/repo" add files/config.toml
drift "$d"
out=$(printf 'n\n' | HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" --force 2>&1)
check "declining with a tracked managed path aborts" "aborted" "$out"
check "the user's own staging of a tracked path survives" "files/config.toml" \
  "$(git -C "$d/repo" diff --cached --name-only)"
rm -rf "$d"

# `read` returns non-zero at end of input, and nd-save runs under errexit, so
# every way of ending the prompt without a newline killed the script before the
# abort path could run: the intent-to-add entry stayed in the index and nothing
# was printed. Three doors, one failure — E8's leak, reopened.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(printf 'n' | HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" 2>&1); st=$?
check "a reply with no trailing newline still aborts" "aborted" "$out"
check_status "that abort exits 1" 1 "$st"
check_empty "an unterminated reply leaves the capture out of the index" \
  "$(git -C "$d/repo" ls-files -- files/nv/lazy-lock.json)"
rm -rf "$d"

# Closed stdin is the unattended case: a cron entry, a pipe that ended.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" < /dev/null 2>&1); st=$?
check "closed stdin aborts with a message" "aborted" "$out"
check_status "closed stdin exits 1" 1 "$st"
check_empty "closed stdin leaves the capture out of the index" \
  "$(git -C "$d/repo" ls-files -- files/nv/lazy-lock.json)"
rm -rf "$d"

# An input that ended mid-answer is not an answer. The default is no.
d=$(new_fixture)
drift "$d"
out=$(printf 'y' | HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" 2>&1); st=$?
check "an unterminated 'y' is not consent" "aborted" "$out"
check_status "an unterminated 'y' exits 1" 1 "$st"
check "an unterminated 'y' commits nothing" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# Ctrl-C at the prompt. Job control is switched on for the spawn so the child
# gets its own process group and the default SIGINT disposition; a background
# job started with job control off inherits SIGINT ignored, which is not what a
# terminal does. Nothing polls: the reader blocks on nd-save's own output until
# the prompt appears.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
mkfifo "$d/in" "$d/out"
set -m
HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" < "$d/in" > "$d/out" 2>&1 &
save_pid=$!
set +m
exec 9> "$d/in"
exec 8< "$d/out"
buf=""
while IFS= read -r -n1 -u 8 c; do
  buf="$buf$c"
  case "$buf" in *"proceed?"*) break ;; esac
done
kill -INT "$save_pid" 2> /dev/null
wait "$save_pid"; st=$?
exec 9>&-
exec 8<&-
check_status "an interrupted run exits 130" 130 "$st"
check_empty "an interrupted run leaves the capture out of the index" \
  "$(git -C "$d/repo" ls-files -- files/nv/lazy-lock.json)"
rm -rf "$d"

# A commit can fail for reasons that have nothing to do with nd-save: a
# pre-commit hook, commit.gpgsign with no key, a full disk. errexit turned that
# into a silent exit 1 with the capture left staged — the state the user's next
# `git commit -am` sweeps up.
d=$(new_fixture)
printf '#!/bin/sh\nexit 1\n' > "$d/repo/.git/hooks/pre-commit"
chmod +x "$d/repo/.git/hooks/pre-commit"
drift "$d"
out=$(run_save "$d" -y); st=$?
check "a failed commit is reported" "the commit failed" "$out"
check_status "a failed commit exits 1" 1 "$st"
check_not "a failed commit does not read as a success" "nd-save: committed" "$out"
check_empty "a failed commit leaves nothing staged" "$(git -C "$d/repo" diff --cached --name-only)"
check "a failed commit commits nothing" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# The asymmetry a path-scoped reset cannot fix: `git add` has already replaced
# whatever the user staged on a *tracked* managed path, and resetting that path
# would discard it just as thoroughly. The index snapshot is what puts it back.
d=$(new_fixture)
printf '#!/bin/sh\nexit 1\n' > "$d/repo/.git/hooks/pre-commit"
chmod +x "$d/repo/.git/hooks/pre-commit"
printf 'staged by me\n' > "$d/repo/files/config.toml"
git -C "$d/repo" add files/config.toml
drift "$d"
out=$(run_save "$d" -y --force)
check "the user's own staging survives a failed commit" "staged by me" \
  "$(git -C "$d/repo" show :files/config.toml)"
rm -rf "$d"

# The restore has to know that a commit happened, and "the commit returned 0"
# is not the same instant as "nd-save recorded that it did": bash runs a
# pending signal trap between the two. A post-commit hook that signals nd-save
# reproduces that window exactly — the commit is made, and the run still ends
# through the trap. Restoring the index there would revert the capture that is
# already in HEAD.
d=$(new_fixture)
drift "$d"
mkfifo "$d/in" "$d/out"
set -m
HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" < "$d/in" > "$d/out" 2>&1 &
save_pid=$!
set +m
printf '#!/bin/sh\nkill -INT %s\n' "$save_pid" > "$d/repo/.git/hooks/post-commit"
chmod +x "$d/repo/.git/hooks/post-commit"
exec 9> "$d/in"
exec 8< "$d/out"
buf=""
while IFS= read -r -n1 -u 8 c; do
  buf="$buf$c"
  case "$buf" in *"proceed?"*) break ;; esac
done
printf 'y\n' >&9
wait "$save_pid"
exec 9>&-
exec 8<&-
check "the interrupted commit was still made" "files/config.toml" \
  "$(git -C "$d/repo" show --stat --format= HEAD)"
check_empty "an interrupt after the commit does not revert the index" \
  "$(git -C "$d/repo" status --porcelain -- files/config.toml)"
rm -rf "$d"

# An abort must not be greppable as a success. `check "drift is committed"
# "committed"` below is exactly the grep a user writes, and the abort message
# used to wrap onto a line beginning "nd-save: committed".
d=$(new_fixture)
drift "$d"
out=$(printf 'n\n' | HOME="$d/home" ND_FLAKE="$d/repo" "$ND_SAVE" 2>&1)
check_not "an abort never reads as a commit" "nd-save: committed" "$out"
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

# The defect-2 guard compares the working tree with the store and never looks
# at the index. A managed path whose staged content differs from HEAD, with a
# working tree that matches the store, passed the guard — and then `git add`
# replaced the staged blob with the captured content and the user's staged work
# became unreachable. Same class of loss the guard exists to prevent.
d=$(new_fixture)
printf 'staged only\n' > "$d/repo/files/config.toml"
git -C "$d/repo" add files/config.toml
install -m 0644 "$d/store-source" "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y); st=$?
check "a staged-only edit blocks the capture" "staged" "$out"
check_status "the staged-only refusal exits 1" 1 "$st"
check "the staged blob survives" "staged only" "$(git -C "$d/repo" show :files/config.toml)"
check "the staged-only refusal commits nothing" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# --force remains the one escape hatch, and it has to open this door too.
d=$(new_fixture)
printf 'staged only\n' > "$d/repo/files/config.toml"
git -C "$d/repo" add files/config.toml
install -m 0644 "$d/store-source" "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y --force)
check "--force overrides the staged-edit refusal" "copied back into the repo" "$out"
rm -rf "$d"

# `awk -v x=VAL` runs the value through escape processing, so a destination
# containing a backslash never equalled $2: the store source came back empty
# and `[ -n "$src" ]` short-circuited the whole blocker check. Defect 2's
# failure mode, reinstated for any path with a backslash in it.
d=$(new_fixture)
bs_dest='.config/app/co\nfig.toml'
bs_repo='files/co\nfig.toml'
printf 'setting = 1\n' > "$d/store-source-bs"
chmod 0444 "$d/store-source-bs"
install -m 0644 "$d/store-source-bs" "$d/home/$bs_dest"
install -m 0644 "$d/store-source-bs" "$d/repo/$bs_repo"
printf '%s\t%s\t%s\n' "$d/store-source-bs" "$bs_dest" "$bs_repo" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm "add the backslash file"
printf 'setting = 2\n' > "$d/home/$bs_dest"
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/$bs_repo"
out=$(run_save "$d" -y); st=$?
check "a backslash in a destination still blocks" "never placed" "$out"
check_status "the backslash refusal exits 1" 1 "$st"
check "the repo edit under a backslash path survives" "my unplaced edit" \
  "$(cat "$d/repo/$bs_repo")"
rm -rf "$d"

# Parent directories for a capture in a subdirectory the repo does not have.
d=$(new_glob_fixture)
mkdir -p "$d/home/.config/nv/lua/deep"
printf 'return 4\n' > "$d/home/.config/nv/lua/deep/new.lua"
out=$(run_save "$d" -y)
check "a nested capture creates its repo directory" "copied back into the repo" "$out"
check "the nested file lands in the repo" "return 4" "$(cat "$d/repo/files/nv/lua/deep/new.lua")"
rm -rf "$d"

# A flake repo whose first commit has not been made yet: `git diff HEAD` is
# fatal there, and nd-save reached it after the copies and the intent-to-add
# had already happened, so it died mid-way with a git error for a message.
d=$(new_fixture)
rm -rf "$d/repo/.git"
git -C "$d/repo" init -q -b main
git -C "$d/repo" config user.email t@example.com
git -C "$d/repo" config user.name Test
drift "$d"
out=$(run_save "$d" -y); st=$?
check_not "an unborn HEAD is not a fatal error" "bad revision" "$out"
check_status "an unborn HEAD exits 0" 0 "$st"
check "an unborn HEAD still previews the change" "setting = 2" "$out"
check "an unborn HEAD gets its first commit" "files/config.toml" \
  "$(git -C "$d/repo" show --stat --format= HEAD)"
rm -rf "$d"

# Defect 3. With -y the branch was printed to a terminal nobody is reading and
# the commit proceeded regardless, so the unattended path was the one with no
# check at all.
d=$(new_fixture)
drift "$d"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_EXPECTED_BRANCH=main "$ND_SAVE" -y 2>&1); st=$?
check "the expected branch matching proceeds" "committed" "$out"
check_status "matching exits 0" 0 "$st"
rm -rf "$d"

d=$(new_fixture)
git -C "$d/repo" switch -q -c topic
drift "$d"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_EXPECTED_BRANCH=main "$ND_SAVE" -y 2>&1); st=$?
check "a mismatched branch is refused under -y" "expected 'main'" "$out"
check_status "a mismatched branch exits 1" 1 "$st"
check "nothing was committed" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

d=$(new_fixture)
git -C "$d/repo" switch -q -c topic
drift "$d"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_EXPECTED_BRANCH=main "$ND_SAVE" -y --branch topic 2>&1)
check "--branch overrides the environment" "committed" "$out"
rm -rf "$d"

# git branch --show-current prints an empty string on a detached HEAD, which the
# old code reported as branch '' and then committed onto anyway. That commit is
# unreachable the moment anything else is checked out.
d=$(new_fixture)
git -C "$d/repo" checkout -q --detach HEAD
drift "$d"
out=$(run_save "$d" -y); st=$?
check "a detached HEAD is refused" "detached" "$out"
check_status "a detached HEAD exits 1" 1 "$st"
rm -rf "$d"

d=$(new_fixture)
git -C "$d/repo" checkout -q --detach HEAD
drift "$d"
out=$(run_save "$d" -y --branch main --force); st=$?
check "a detached HEAD is refused even with --branch and --force" "detached" "$out"
check_status "that still exits 1" 1 "$st"
rm -rf "$d"

# No constraint set is the existing behaviour: print and prompt, do not refuse.
d=$(new_fixture)
git -C "$d/repo" switch -q -c topic
drift "$d"
out=$(run_save "$d" -y)
check "no constraint means no refusal" "committed" "$out"
check "the branch is still printed" "branch 'topic'" "$out"
rm -rf "$d"

# Defect 4. Every commit said "Update config written by applications", so
# `git log --oneline` told you nothing about which application rewrote what.
d=$(new_fixture)
drift "$d"
run_save "$d" -y > /dev/null
check "a single file names its app" "Save app config written by the app" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
run_save "$d" -y -m "Explicit subject" > /dev/null
check "-m still wins" "Explicit subject" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# Two apps. The fixture gets a second managed file under a different .config
# component.
d=$(new_fixture)
mkdir -p "$d/home/.config/zed" "$d/repo/files/zed"
printf 'a\n' > "$d/store-source-2"
chmod 0444 "$d/store-source-2"
install -m 0644 "$d/store-source-2" "$d/home/.config/zed/settings.json"
install -m 0644 "$d/store-source-2" "$d/repo/files/zed/settings.json"
printf '%s\t%s\t%s\n' "$d/store-source-2" ".config/zed/settings.json" "files/zed/settings.json" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A; git -C "$d/repo" commit -qm "add zed"
drift "$d"
printf 'b\n' > "$d/home/.config/zed/settings.json"
run_save "$d" -y > /dev/null
check "two apps are both named" "Save config written by app and zed" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# The list of applications was joined with `paste -sd'|'` and then split again
# on the same character, so an application token containing a pipe came out as
# two applications. A path component can contain any character but `/`, so no
# delimiter is safe: the join must not need one.
d=$(new_fixture)
mkdir -p "$d/home/.config/we|ird" "$d/repo/files/we|ird"
printf 'a\n' > "$d/store-source-pipe"
chmod 0444 "$d/store-source-pipe"
install -m 0644 "$d/store-source-pipe" "$d/home/.config/we|ird/settings.json"
install -m 0644 "$d/store-source-pipe" "$d/repo/files/we|ird/settings.json"
printf '%s\t%s\t%s\n' "$d/store-source-pipe" ".config/we|ird/settings.json" "files/we|ird/settings.json" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm "add the pipe app"
drift "$d"
printf 'b\n' > "$d/home/.config/we|ird/settings.json"
run_save "$d" -y > /dev/null
check "a pipe in an app name is not split into two apps" "Save config written by app and we|ird" \
  "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# A destination outside .config/ derives from the basename.
d=$(new_fixture)
printf 'x\n' > "$d/store-source-3"
chmod 0444 "$d/store-source-3"
install -m 0644 "$d/store-source-3" "$d/home/.wezterm.lua"
install -m 0644 "$d/store-source-3" "$d/repo/files/wezterm.lua"
printf '%s\t%s\t%s\n' "$d/store-source-3" ".wezterm.lua" "files/wezterm.lua" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A; git -C "$d/repo" commit -qm "add wezterm"
printf 'y\n' > "$d/home/.wezterm.lua"
run_save "$d" -y > /dev/null
check "a dotfile outside .config derives its name" "Save wezterm config written by the app" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# Defect 5 negatives. These must NOT trip the scan. They exist so a future
# entropy check cannot land without proving it does not break them.
for benign in \
  '{"red": "#ff0044", "green": "#00ff88", "blue": "#0044ff"}' \
  '{"id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"}' \
  '{"icon": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}'; do
  d=$(new_fixture)
  printf '%s\n' "$benign" > "$d/home/.config/app/config.toml"
  out=$(run_save "$d" -y); st=$?
  check_not "benign content is not a credential: ${benign:0:22}" "credential-shaped content" "$out"
  check_status "benign content exits 0" 0 "$st"
  rm -rf "$d"
done

# E20. `unreadable` is neither drifted nor new, so it matched no work-list
# pattern and matched no report either: nd-save said "nothing to save" about a
# file the next switch is going to overwrite. It is reported the way `missing`
# is — named, explained, skipped — because there is genuinely nothing nd-save
# can do with a file it cannot classify.
d=$(new_fixture)
rm -f "$d/store-source"
out=$(run_save "$d" -y); st=$?
check "an unreadable source is reported" "cannot be read" "$out"
check "the unreadable file is named" ".config/app/config.toml" "$out"
check_status "an unreadable source alone exits 0" 0 "$st"
check "an unreadable source still means nothing to save" "nothing to save" "$out"
check_not "an unreadable source is not claimed to still match" "every placed file still matches" "$out"
rm -rf "$d"

# One entry nd-status could not classify must not stop the ones it could.
d=$(new_fixture)
printf 'other = 1\n' > "$d/store-other"
chmod 0444 "$d/store-other"
install -m 0644 "$d/store-other" "$d/home/.config/app/other.toml"
install -m 0644 "$d/store-other" "$d/repo/files/other.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm "add other"
printf '%s\t%s\t%s\n' "$d/store-other" ".config/app/other.toml" "files/other.toml" \
  >> "$d/home/.local/state/nd/manifest"
rm -f "$d/store-source"
printf 'other = 2\n' > "$d/home/.config/app/other.toml"
out=$(run_save "$d" -y)
check "an unreadable entry is reported alongside a save" "cannot be read" "$out"
check "the classifiable entry is still committed" "files/other.toml" "$(git -C "$d/repo" show --stat --format= HEAD)"
check_not "the unreadable entry is not committed" "files/config.toml" "$(git -C "$d/repo" show --stat --format= HEAD)"
rm -rf "$d"

# E20. cmp exits 2 when it cannot read one of its arguments, and the unplaced-
# edit guard read that as "the repo copy differs" — blaming the user's repo for
# a comparison that never happened, which is the misattribution E19 removed from
# nd-status. Refusing is right either way (E14: the guard fails closed when it
# cannot tell what was placed), so what was wrong is the reason it gave.
d=$(new_fixture)
rm -f "$d/repo/files/config.toml"
mkdir -p "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y); st=$?
check "an uncomparable repo copy is refused" "never placed" "$out"
check "the refusal says the comparison could not be made" "cannot be compared with what was placed" "$out"
check_not "the refusal does not blame the repo copy" "repo copy differs" "$out"
check_status "an uncomparable repo copy exits 1" 1 "$st"
check "an uncomparable repo copy stops the copy" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
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
printf '%s\t%s\t%s\t%s\t%s\n' "-" ".config/nv" "files/nv" "glob" '(.*/)?extra\.lua' \
  >> "$d/home/.local/state/nd/manifest"
printf 'return 3\n' > "$d/home/.config/nv/lua/extra.lua"
out=$(run_status "$d" | grep -c 'extra.lua')
check "a file matching two patterns is emitted once" "1" "$out"
rm -rf "$d"

# Only the symlink is asserted. A directory named dir.lua was asserted here too,
# and `find -type f` cannot return one under any plausible implementation, so
# that case could not fail; a symlink can, because -type f and -type l are one
# character apart.
d=$(new_glob_fixture)
ln -s /etc/hosts "$d/home/.config/nv/link.lua"
out=$(run_status "$d")
check_not "a symlink under the root is skipped" "link.lua" "$out"
rm -rf "$d"

# The output format is line-based and cannot represent this. Skipping loudly
# beats emitting a line every consumer parses as two.
d=$(new_glob_fixture)
touch "$d/home/.config/nv/$(printf 'we\nird').lua"
out=$(run_status "$d")
check "a path with a newline is skipped with a warning" "skipping path with a newline" "$out"
check_not "a path with a newline is not emitted" "new	.config/nv/we" "$out"
rm -rf "$d"

# The tab is worse than the newline and was not guarded. nd-status emitted a
# four-field line into a three-field tab-separated format; nd-save split it at
# the tab, ran its credential grep against a path that does not exist, read that
# grep's exit 2 as "clean" — a fail-open on the credential scan — and then died
# inside install.
d=$(new_glob_fixture)
touch "$d/home/.config/nv/$(printf 'we\tird').lua"
out=$(run_status "$d")
check "a path with a tab is skipped with a warning" "skipping path with a tab" "$out"
check_not "a path with a tab is not emitted" "new	.config/nv/we	ird.lua" "$out"
rm -rf "$d"

# E11. globToERE does not escape `-` and cannot, so a pattern like `-foo/**`
# arrives as the ERE `-foo/.*` and grep reads it as options. grep exits 2 inside
# an `if` condition, where errexit does not apply, so every path under that root
# was skipped for good while grep printed usage to stderr.
d=$(new_glob_fixture)
printf '%s\t%s\t%s\t%s\t%s\n' "-" ".config/nv" "files/nv" "glob" '-foo/.*' \
  >> "$d/home/.local/state/nd/manifest"
mkdir -p "$d/home/.config/nv/-foo"
printf 'q\n' > "$d/home/.config/nv/-foo/a.txt"
out=$(run_status "$d")
check "a pattern starting with a dash still matches" "new	.config/nv/-foo/a.txt	files/nv/-foo/a.txt" "$out"
check_not "a pattern starting with a dash is not read as options" "grep:" "$out"
rm -rf "$d"

# A trailing slash on a globs key made the prefix strip miss, so rel stayed
# absolute: every placed file was reported new forever, at a repo path outside
# the repo that nd-save would have created there.
d=$(new_glob_fixture)
{
  printf '%s\t%s\t%s\n' "$d/store/init.lua"     ".config/nv/init.lua"     "files/nv/init.lua"
  printf '%s\t%s\t%s\n' "$d/store/lua/plug.lua" ".config/nv/lua/plug.lua" "files/nv/lua/plug.lua"
  printf '%s\t%s\t%s\t%s\t%s\n' "-" ".config/nv/" "files/nv/" "glob" '(.*/)?[^/]*\.lua'
} > "$d/home/.local/state/nd/manifest"
printf 'return 3\n' > "$d/home/.config/nv/extra.lua"
out=$(run_status "$d")
check "a trailing slash in the root still yields relative paths" \
  "new	.config/nv/extra.lua	files/nv/extra.lua" "$out"
check_not "a trailing slash does not produce an absolute path" "$d/home" "$out"
check_not "a placed file is still not new under a trailing-slash root" "new	.config/nv/init.lua" "$out"
rm -rf "$d"

# cmp exits 2 when it cannot read a file, and treating that as "they differ"
# called the file drifted and sent nd-save off to blame the repo copy for
# differing from a source neither of them could open.
d=$(new_fixture)
rm -f "$d/store-source"
out=$(run_status "$d")
check "an unreadable store source is its own kind" "unreadable	.config/app/config.toml	files/config.toml" "$out"
check_not "an unreadable store source is not drift" "drifted" "$out"
rm -rf "$d"

# Only reachable by hand-editing or truncation, but it fails in the dangerous
# direction: `while read` drops an unterminated final record, so a drifted file
# in one is reported by nothing and overwritten by the next switch in silence.
d=$(new_fixture)
drift "$d"
printf '%s\t%s\t%s' "$d/store-source" ".config/app/config.toml" "files/config.toml" \
  > "$d/home/.local/state/nd/manifest"
out=$(run_status "$d")
check "an unterminated final record is still read" "drifted	.config/app/config.toml" "$out"
rm -rf "$d"

# A glob root the application has not created yet is not an error.
d=$(new_glob_fixture)
rm -rf "$d/home/.config/nv"
out=$(run_status "$d"); st=$?
check_status "an absent glob root exits 0" 0 "$st"
check "an absent glob root reports its files missing" "missing	.config/nv/init.lua" "$out"
rm -rf "$d"

echo
echo "zsh notice"

run_notice() {
  HOME="$1/home" PATH="$(dirname "$ND_STATUS"):$PATH" \
    zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1
}

d=$(new_fixture)
out=$(run_notice "$d")
check_empty "a clean tree prints nothing" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_notice "$d")
check "drift is announced" "1 drifted" "$out"
check "the notice points at nd-save" "nd-save" "$out"
rm -rf "$d"

d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_notice "$d")
check "a missing file is announced" "1 missing" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf '{}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_notice "$d")
check "a new file is announced" "1 new" "$out"
rm -rf "$d"

d=$(new_fixture)
out=$(HOME="$d/home" ND_MANIFEST="$d/nope" PATH="$(dirname "$ND_STATUS"):$PATH" \
  zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1)
check_empty "no manifest prints nothing" "$out"
rm -rf "$d"

# E20. The case had no default arm, so a kind it did not know incremented
# nothing and the notice stayed silent while nd-status was reporting a finding.
d=$(new_fixture)
rm -f "$d/store-source"
out=$(run_notice "$d")
check "an unreadable source is announced" "1 unreadable" "$out"
rm -rf "$d"

# A kind newer than this notice. nd-status is taken from PATH here rather than
# from runtimeInputs, so unlike nd-switch and nd-save the suite can substitute a
# stub and pin the catch-all directly.
d=$(new_fixture)
stub_status="$(mktemp -d)"
printf '#!/bin/sh\nprintf "invented\\t.config/app/config.toml\\tfiles/config.toml\\n"\n' \
  > "$stub_status/nd-status"
chmod +x "$stub_status/nd-status"
out=$(HOME="$d/home" PATH="$stub_status:$PATH" \
  zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1)
check "a kind the notice does not know is announced" "1 unrecognised" "$out"
rm -rf "$d" "$stub_status"

# A kind whose name merely begins with a known one is not that kind. The arms
# were prefix matches, so a future "newly-linked" would have been counted as
# "new" and reported under the wrong word.
d=$(new_fixture)
stub_status="$(mktemp -d)"
printf '#!/bin/sh\nprintf "newfangled\\t.config/app/config.toml\\tfiles/config.toml\\n"\n' \
  > "$stub_status/nd-status"
chmod +x "$stub_status/nd-status"
out=$(HOME="$d/home" PATH="$stub_status:$PATH" \
  zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1)
check "a kind that only starts like a known one is not counted as it" "1 unrecognised" "$out"
check_not "and it is not counted as new" "1 new" "$out"
rm -rf "$d" "$stub_status"

echo
echo "end to end"

# lazy.nvim rewrites lazy-lock.json on every plugin update. It is a file the
# user never declares, whose whole purpose is to be regenerated. Capturing it
# must land it at the right repo path and leave the repo in a state where the
# next evaluation enumerates it as an ordinary file record.
d=$(new_glob_fixture)
printf '{"nvim-treesitter":{"commit":"abc123"}}\n' > "$d/home/.config/nv/lazy-lock.json"

out=$(run_switch "$d" --build)
check "the switch reports it without blocking" "not yet in the repo" "$out"
check "the switch is not blocked" "building" "$out"

out=$(run_save "$d" -y)
check "nd-save captures it" "lazy-lock.json" "$out"
check "it lands at the right repo path" "abc123" "$(cat "$d/repo/files/nv/lazy-lock.json")"
check "it is committed" "files/nv/lazy-lock.json" "$(git -C "$d/repo" show --stat --format= HEAD)"
check "the subject names the app" "Save nv config written by the app" "$(git -C "$d/repo" log -1 --format=%s)"

# It is now in the repo, so the next evaluation places it. Simulate that by
# adding the file record a switch would write, and confirm it stops being new.
# Field 1 is the source the next generation would place from; in this fixture
# that is the repo copy, which is byte-identical to the live file.
printf '%s\t%s\t%s\n' "$d/repo/files/nv/lazy-lock.json" ".config/nv/lazy-lock.json" "files/nv/lazy-lock.json" \
  >> "$d/home/.local/state/nd/manifest"
out=$(run_status "$d")
check_not "once placed it is no longer new" "new	.config/nv/lazy-lock.json" "$out"
check_not "and it has not drifted" "drifted" "$out"

# The loop closed: a second save has nothing to do.
out=$(run_save "$d" -y)
check "the loop is closed" "nothing to save" "$out"
rm -rf "$d"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
