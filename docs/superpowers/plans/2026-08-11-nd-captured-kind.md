# The `captured` kind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Break the `nd-save` / `nd-switch` deadlock by teaching `nd-status` a fifth kind, `captured`, for content that has already been copied into the flake repo and can therefore be re-placed losslessly.

**Architecture:** `nd-status` owns classification; its callers decide what a kind means. So the whole fix is one new kind emitted by `nd-status`, plus each caller learning to recognise and report it. No caller grows a comparison of its own, and no new state is written anywhere — the check reads the manifest field that was already there. Two unrelated `nd-switch` defects from the same issue ride along because they touch the same file.

**Tech Stack:** Nix flake (`writeShellApplication`, so bash with `set -euo pipefail` and a build-time `shellcheck`), zsh for the startup notice, `tests/run.sh` as the suite.

## Global Constraints

- Design spec: [docs/superpowers/specs/2026-08-11-nd-captured-kind-design.md](../specs/2026-08-11-nd-captured-kind-design.md). It is authoritative; this plan implements it and adds nothing.
- Escalation log for this work: `docs/superpowers/escalations-2026-08-11-nd-captured.md`. Every deviation from the spec, every ambiguity, every surprise found while implementing gets an entry. Do not silently improvise.
- The five kinds are `drifted`, `missing`, `new`, `unreadable`, `captured`. Exactly those spellings, lower-case, always matched anchored to the tab that ends the field (`"^captured$tab"`, `(captured$'\t'*)`), never as a bare prefix.
- Every program is a Nix indented string (`''...''`). A literal `${` in shell must be written `''${`. A literal `''` must be written `'''`. Getting this wrong is an evaluation error, not a runtime one.
- `writeShellApplication` runs `set -o errexit -o nounset -o pipefail` and `shellcheck` at build time. Every new `cmp` and `git` invocation must capture its status explicitly (`cmd || st=$?`) or sit in an `if` condition — never bare.
- `git` is taken from the caller's `PATH`, never added to `runtimeInputs`. `nd-save` already does this deliberately; `nd-status` now does too.
- `nd-status` already calls `cmp`, which lives in `diffutils` and is in none of its `runtimeInputs`; it resolves from the caller's `PATH` today. That is pre-existing and out of scope. If it surprises you, open an escalation entry and leave it alone — do not fix it in this plan.
- Undecidable is never `captured`. Missing repo, missing repo copy, `cmp` exit ≥ 2, `git` absent, `git` non-zero for any reason — all fall through to the fallback kind.
- Fixed strings that tests grep for, verbatim:
  - `nd-switch: switching re-places them from the repo; nothing is lost.`
  - `nd-switch: nothing is being placed, so they are left alone.`
  - `nd-save: run 'nd-switch' to place them.`
- Build the packages with `nix build --no-link --print-out-paths .#nd-switch .#nd-save .#nd-status` before running the suite, and run the suite with those paths in `ND_SWITCH` / `ND_SAVE` / `ND_STATUS`. `nix flake check` runs everything including the module and glob checks.
- Commit after every task. Never append co-sign trailers.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `packages/nd-status.nix` | classification, the only place that decides a kind | Task 1 |
| `packages/nd-switch.nix` | the gate, and the `--build` / stale-comment defects | Tasks 2, 3 |
| `packages/nd-save.nix` | capture, and the redirect out of the deadlock | Task 4 |
| `modules/nd-notice.zsh` | one-line shell startup notice | Task 5 |
| `README.md` | the kind list and the two-vs-three-state explanation | Task 6 |
| `tests/run.sh` | the suite; every task adds to it | Tasks 1–6 |
| `docs/superpowers/escalations-2026-08-11-nd-captured.md` | escalation log | Task 0, appended throughout |

---

## Task 0: The escalation log

**Files:**
- Create: `docs/superpowers/escalations-2026-08-11-nd-captured.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the file every later task appends to.

- [ ] **Step 1: Create the log with its header and no entries**

```markdown
# Escalations — the `captured` kind

Work log for [the captured-kind plan](plans/2026-08-11-nd-captured-kind.md),
implementing [its spec](specs/2026-08-11-nd-captured-kind-design.md).

One entry per deviation, ambiguity or surprise. An entry is opened the moment
the question arises and closed in the same document when it is answered, so the
reasoning survives the session that produced it. The existing
`escalations.md` is the model.

Statuses: **open**, **resolved**, **deferred to the maintainer**.

## Entries

_None yet._
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/escalations-2026-08-11-nd-captured.md
git commit -m "Open an escalation log for the captured kind"
```

---

## Task 1: `nd-status` emits `captured`

**Files:**
- Modify: `packages/nd-status.nix`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: the manifest's third field (repo-relative path), which every record already carries.
- Produces: a fifth kind on stdout, `captured\t<dest>\t<repo_rel>`, for both file records and glob-discovered files. Every later task recognises exactly this spelling.

- [ ] **Step 1: Give `run_status` the flake path**

`nd-status` has never needed `ND_FLAKE`, so the helper never passed it. Without this every new case falls through to the fallback kind and the tests pass for the wrong reason.

In `tests/run.sh`, change:

```bash
run_status() { HOME="$1/home" "$ND_STATUS" "${@:2}" 2>&1; }
```

to:

```bash
run_status() { HOME="$1/home" ND_FLAKE="$1/repo" "$ND_STATUS" "${@:2}" 2>&1; }
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/run.sh`, in the `nd-status` section (immediately before the `echo` that begins the `zsh notice` section):

```bash
# The third state. The live file differs from the store source that placed it,
# but the repo already holds that exact content, so the next switch rebuilds the
# file FROM that copy and discards nothing. Classifying it as drifted is what
# deadlocked nd-switch against nd-save: nd-switch refused to place it and
# nd-save refused to re-capture it, each naming the other.
d=$(new_fixture)
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
out=$(run_status "$d")
check "a captured file is captured" "captured	.config/app/config.toml	files/config.toml" "$out"
check_not "and is not drifted" "drifted" "$out"
rm -rf "$d"

# Uncommitted is still captured: nix builds a dirty tree from the working tree,
# so the content is what gets placed. This is the state nd-save leaves behind
# when its commit prompt is declined, and it is a legitimate way to get here.
d=$(new_fixture)
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
out=$(run_status "$d")
check "an uncommitted but tracked capture is captured" "captured	.config/app/config.toml" "$out"
rm -rf "$d"

# Untracked is NOT captured. Nix cannot see an untracked file at all — it fails
# evaluation with "To make it visible to Nix, run: git add" — so a repo copy
# that matches byte for byte but is untracked would not survive the switch.
# Calling it captured would cost the user the file.
d=$(new_fixture)
drift "$d"
git -C "$d/repo" rm -q --cached files/config.toml
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
out=$(run_status "$d")
check "an untracked repo copy is still drifted" "drifted	.config/app/config.toml" "$out"
check_not "and is not captured" "captured" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_status "$d")
check "a repo copy that differs is still drifted" "drifted	.config/app/config.toml" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
rm "$d/repo/files/config.toml"
out=$(run_status "$d")
check "an absent repo copy is still drifted" "drifted	.config/app/config.toml" "$out"
rm -rf "$d"

# Fails closed on a flake path that is not a repository at all: git cannot
# answer, so the question is undecided, and undecided is never captured.
d=$(new_fixture)
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
out=$(HOME="$d/home" ND_FLAKE="$d/nowhere" "$ND_STATUS" 2>&1)
check "an absent flake is still drifted" "drifted	.config/app/config.toml" "$out"
rm -rf "$d"

# A directory where the repo copy should be. cmp exits 2 rather than 1, which
# is "I could not read one of them", not "they match".
d=$(new_fixture)
drift "$d"
rm "$d/repo/files/config.toml"
mkdir "$d/repo/files/config.toml"
out=$(run_status "$d")
check "a directory in the repo's place is still drifted" "drifted	.config/app/config.toml" "$out"
rm -rf "$d"

# The glob side. A file the application invented has no store source, so "did it
# drift" is meaningless — but "is this exact content already in the repo, where
# the next switch places it from" is the same question with the same answer.
d=$(new_glob_fixture)
printf '{"pinned":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
install -m 0644 "$d/home/.config/nv/lazy-lock.json" "$d/repo/files/nv/lazy-lock.json"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
out=$(run_status "$d")
check "a captured glob file is captured" "captured	.config/nv/lazy-lock.json	files/nv/lazy-lock.json" "$out"
check_not "and is not new" "new	.config/nv/lazy-lock.json" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf '{"pinned":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_status "$d")
check "an uncaptured glob file is still new" "new	.config/nv/lazy-lock.json" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf '{"pinned":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
install -m 0644 "$d/home/.config/nv/lazy-lock.json" "$d/repo/files/nv/lazy-lock.json"
out=$(run_status "$d")
check "an untracked glob capture is still new" "new	.config/nv/lazy-lock.json" "$out"
rm -rf "$d"
```

The literal tabs inside the `check` expectations matter — they are what makes the assertion anchored to a field rather than a substring. Type real tab characters, not `\t`.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
nix build --no-link --print-out-paths .#nd-switch .#nd-save .#nd-status
```

Then, with the three paths from that output:

```bash
ND_SWITCH=<path>/bin/nd-switch ND_SAVE=<path>/bin/nd-save ND_STATUS=<path>/bin/nd-status bash tests/run.sh
```

Expected: the nine new `captured` / `not new` assertions fail. The `still drifted` and `still new` ones already pass, and must keep passing — they are the guard's existing behaviour, which this change must not loosen.

- [ ] **Step 4: Add the flake path and the check to `nd-status`**

In `packages/nd-status.nix`, after the `manifest=` line, add:

```
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"
```

Then, immediately before `scan_glob()`, add the classifier:

```
    # Answer, for a path whose content is not what the store placed — or that
    # nothing placed at all — whether that exact content is already in the repo
    # where the next switch would build it from. If it is, switching re-places
    # it byte for byte and discards nothing, so reporting it as something a
    # switch would destroy is false, and refusing the switch on it deadlocks:
    # only an activation rewrites the manifest, and the refusal is what declines
    # to activate.
    #
    # Two questions, both of which must answer yes:
    #
    #   - the repo copy exists and is byte-identical to the live file; and
    #   - git can see it. An untracked file is invisible to a flake build — nix
    #     refuses with "To make it visible to Nix, run: git add" — so a
    #     byte-identical untracked copy would not survive the switch at all, and
    #     calling it captured would cost the user the file. A tracked file with
    #     an uncommitted modification is fine: nix builds a dirty tree from the
    #     working tree, which is where the content is.
    #
    # Everything else falls through to the caller's fallback kind. A missing
    # repo, a cmp that exits 2 rather than 1, a git that is not on PATH: each
    # leaves the question undecided, and E14's rule is that "I cannot tell
    # whether this is safe to overwrite" is the reason not to, not a reason to.
    kind_for() { # kind_for <fallback> <dest> <repo_rel>
      local fallback="$1" dest="$2" repo_rel="$3" cmp_st=0

      if [ -z "$repo_rel" ] || [ ! -f "$flake/$repo_rel" ]; then
        printf '%s' "$fallback"
        return 0
      fi

      cmp -s "$flake/$repo_rel" "$HOME/$dest" || cmp_st=$?
      if [ "$cmp_st" -ne 0 ]; then
        printf '%s' "$fallback"
        return 0
      fi

      if ! git -C "$flake" ls-files --error-unmatch -- "$repo_rel" > /dev/null 2>&1; then
        printf '%s' "$fallback"
        return 0
      fi

      printf 'captured'
    }
```

- [ ] **Step 5: Route both emitters through it**

In `scan_glob()`, replace:

```
        printf 'new\t%s\t%s\n' "$dest_prefix$rel" "$repo_prefix$rel"
```

with:

```
        printf '%s\t%s\t%s\n' \
          "$(kind_for new "$dest_prefix$rel" "$repo_prefix$rel")" \
          "$dest_prefix$rel" "$repo_prefix$rel"
```

In `scan()`, replace:

```
                1) printf 'drifted\t%s\t%s\n' "$dest" "$repo_rel" ;;
```

with:

```
                1) printf '%s\t%s\t%s\n' "$(kind_for drifted "$dest" "$repo_rel")" "$dest" "$repo_rel" ;;
```

- [ ] **Step 6: Document the kind in `--help`**

In the `-h | --help` block, after the `unreadable` lines, add:

```
        echo "  captured    the live file differs from the store source that placed it,"
        echo "              or nothing placed it — but the repo already holds that exact"
        echo "              content and git can see it, so the next switch re-places it"
        echo "              and discards nothing"
```

- [ ] **Step 7: Rebuild and run the whole suite**

```bash
nix build --no-link --print-out-paths .#nd-switch .#nd-save .#nd-status
```

Then run `tests/run.sh` with the new paths.

Expected: the nine new assertions pass. **Existing assertions may now fail**, and that is information, not noise. `run_switch` and `run_save` already export `ND_FLAKE`, and `nd-status` is their child, so any existing case where a fixture's repo copy matches its live file now classifies differently. For each failure, decide and record in the escalation log which it is:

- the case is asserting the deadlock as correct behaviour → update the expectation, and say so in the log;
- the case is asserting something else and the reclassification is incidental → adjust the fixture so the case still tests what it was written to test;
- the reclassification is wrong → that is a defect in `kind_for`, not in the test.

Do not weaken an assertion to make it pass without an entry saying why.

- [ ] **Step 8: Run the full flake check**

```bash
nix flake check
```

`tests/module.sh` unsets `ND_FLAKE` and runs `nd-status` with only `HOME` set, so it falls through to the default flake path, which does not exist in that sandbox, so every kind is unchanged there. Confirm that rather than assuming it.

- [ ] **Step 9: Commit**

```bash
git add packages/nd-status.nix tests/run.sh docs/superpowers/escalations-2026-08-11-nd-captured.md
git commit -m "Classify content already in the repo as captured, not drifted"
```

---

## Task 2: `nd-switch` reports `captured` without gating on it

**Files:**
- Modify: `packages/nd-switch.nix`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `captured\t<dest>\t<repo_rel>` from Task 1.
- Produces: a non-blocking report. `report_status` still returns 1 only for uncaptured `drifted` with an empty label.

- [ ] **Step 1: Write the failing tests**

Append to the `nd-switch` section of `tests/run.sh`:

```bash
# Captured content does not block. The new generation builds this file from the
# repo copy, which is byte-identical to what is live, so the overwrite has
# nothing to discard. Refusing here is the deadlock the issue is about.
d=$(new_fixture)
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
out=$(run_switch "$d" --build)
check "captured content is named" "the repo already holds the change" "$out"
check "captured content names the file" ".config/app/config.toml" "$out"
check "captured content says nothing is lost" "nothing is lost" "$out"
check "captured content does not block" "building" "$out"
check_not "and is not called drift" "switching would overwrite them" "$out"
rm -rf "$d"

# The guard still fires on genuine, uncaptured drift. This is the property the
# fix must not cost, and it is worth more than any of the assertions above.
d=$(new_fixture)
drift "$d"
out=$(run_switch "$d"); st=$?
check_status "uncaptured drift still refuses" 1 "$st"
check "uncaptured drift still names the file" "changed since they were placed" "$out"
check "uncaptured drift still points at nd-save" "run 'nd-save'" "$out"
rm -rf "$d"

# A mixed run blocks on the drifted file and reports the captured one. The gate
# is per-file, so one captured file must not clear the way for another that is
# genuinely at risk.
d=$(new_fixture)
printf 'other = 1\n' > "$d/other-source"
chmod 0444 "$d/other-source"
install -m 0644 "$d/other-source" "$d/home/.config/app/other.toml"
install -m 0644 "$d/other-source" "$d/repo/files/other.toml"
printf '%s\t%s\t%s\n' "$d/other-source" ".config/app/other.toml" "files/other.toml" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm second
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
printf 'other = 2\n' > "$d/home/.config/app/other.toml"
out=$(run_switch "$d"); st=$?
check_status "a mixed run still refuses" 1 "$st"
check "the mixed run blocks on the drifted file" "other.toml" "$out"
check "the mixed run still reports the captured one" "the repo already holds the change" "$out"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify they fail**

Rebuild, then run the suite. Expected: the captured assertions fail with the file reported as drift and the switch refused. The three "still refuses" assertions already pass.

- [ ] **Step 3: Teach the catch-all the new kind**

In `packages/nd-switch.nix`, in `report_status`, change:

```
        | grep -vE "^(drifted|missing|new|unreadable)$tab" || true)"
```

to:

```
        | grep -vE "^(drifted|missing|new|unreadable|captured)$tab" || true)"
```

Without this the kind is reported as one `nd-switch` does not know, which reads as version skew between two programs that ship in the same generation.

- [ ] **Step 4: Collect and report it**

Add `captured` to the `local` declaration at the top of `report_status`:

```
      local status drifted missing created unreadable unknown captured
```

Add the collection alongside the others:

```
      captured="$(printf '%s\n' "$status" | grep "^captured$tab" | cut -f2 || true)"
```

Add the report immediately before the `if [ -n "$drifted" ]` block:

```
      # Not a finding the gate acts on, and deliberately reported anyway. The
      # live file differs from what this generation placed, so something did
      # rewrite it — but the repo already holds that content, so the switch
      # rebuilds the file from it and discards nothing. Saying so is what tells
      # the user why a file they know changed is not being refused.
      if [ -n "$captured" ]; then
        echo "nd-switch: these changed since they were placed, and the repo already holds the change:" >&2
        printf '%s\n' "$captured" | sed 's/^/  /' >&2
        echo "nd-switch: switching re-places them from the repo; nothing is lost." >&2
      fi
```

- [ ] **Step 5: Run to verify they pass**

Rebuild, run the suite. Expected: all Task 2 assertions pass, and nothing that passed before regresses.

- [ ] **Step 6: Commit**

```bash
git add packages/nd-switch.nix tests/run.sh
git commit -m "Report captured files in nd-switch without gating on them"
```

---

## Task 3: `--build` reports and never blocks, and the stale comment goes

**Files:**
- Modify: `packages/nd-switch.nix`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `report_status`, from Task 2, with a new `--build` label.
- Produces: no new interface. `--build` reaches the build step whatever `nd-status` found.

- [ ] **Step 1: Write the failing tests**

Append to the `nd-switch` section of `tests/run.sh`:

```bash
# --build is documented as "build only, no sudo, no switch". It places nothing,
# so the gate has nothing to protect — and blocking it removed the one
# non-destructive way to see the situation while stuck behind the gate.
d=$(new_fixture)
drift "$d"
out=$(run_switch "$d" --build); st=$?
check_status "--build is not blocked by drift" 0 "$st"
check "--build still names the drifted file" ".config/app/config.toml" "$out"
check "--build says nothing is being placed" "nothing is being placed" "$out"
check "--build reaches the build step" "building" "$out"
check_not "--build does not threaten an overwrite" "OVERWRITTEN" "$out"
check_not "--build does not say contents are discarded" "contents will be discarded" "$out"
rm -rf "$d"

# Both flag orders build and neither switches. A comment in nd-switch claimed
# --allow-dirty --build fell through to a real switch because --build was never
# consumed; it does not, and this pins that rather than the comment.
d=$(new_fixture)
drift "$d"
out=$(run_rollback "$d" --allow-dirty --build); st=$?
check_status "--allow-dirty --build exits 0" 0 "$st"
check "--allow-dirty --build builds" "build only, not switching" "$out"
check_not "--allow-dirty --build does not switch" "darwin-rebuild" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_rollback "$d" --build --allow-dirty); st=$?
check_status "--build --allow-dirty exits 0" 0 "$st"
check "--build --allow-dirty builds" "build only, not switching" "$out"
check_not "--build --allow-dirty does not switch" "darwin-rebuild" "$out"
rm -rf "$d"
```

`run_rollback` is used rather than `run_switch` because it puts the stubbed `sudo` on `PATH`. If either case ever does switch, the stub echoes and the `check_not` catches it; without the stub the real `sudo` would be reached.

- [ ] **Step 2: Run to verify they fail**

Rebuild, run the suite. Expected: the six `--build` assertions fail — the command exits 1 with the gate's refusal. The `--allow-dirty --build` assertions already pass; they are a regression pin, not a fix.

- [ ] **Step 3: Give the labelled path a `--build` branch**

In `report_status`, inside `if [ -n "$drifted" ]`, after the `if [ -z "$label" ]` block and before the existing `echo "nd-switch: $label: ..."` line, insert:

```
        # --build places nothing, so the OVERWRITTEN wording the other labels
        # use is simply false here, and a false warning is how a true one stops
        # being read.
        if [ "$label" = "--build" ]; then
          echo "nd-switch: --build: these files changed since they were placed:" >&2
          printf '%s\n' "$drifted" | sed 's/^/  /' >&2
          echo "nd-switch: nothing is being placed, so they are left alone." >&2
          return 0
        fi
```

- [ ] **Step 4: Route `--build` past the gate**

Replace:

```
    if [ -n "$allow_dirty" ]; then
      report_status "--allow-dirty"
    else
      if ! report_status ""; then
        exit 1
      fi
    fi
```

with:

```
    if [ -n "$build_only" ]; then
      # Reports everything and refuses nothing. --build cannot discard drift
      # because it places nothing, and the gate blocking it took away the only
      # non-destructive way to inspect the state while stuck behind the gate.
      # Checked before --allow-dirty so that the two together still describe
      # what is actually about to happen, which is a build.
      report_status "--build" || true
    elif [ -n "$allow_dirty" ]; then
      report_status "--allow-dirty"
    else
      if ! report_status ""; then
        exit 1
      fi
    fi
```

- [ ] **Step 5: Delete the stale comment**

Replace:

```
    # Parsed as a loop so flags work in any order. Positional checks let
    # `--allow-dirty --build` perform a switch, because --build was never
    # consumed and fell through to darwin-rebuild.
```

with:

```
    # Parsed as a loop so flags work in any order.
```

The deleted claim does not reproduce: both orders set `build_only` and exit before `sudo`. Task 3's last two cases pin that, which is worth more than a comment saying it.

- [ ] **Step 6: Run to verify they pass**

Rebuild, run the suite. Expected: all Task 3 assertions pass. Watch specifically that "the discard warning precedes the build" and the other existing `--allow-dirty` cases still pass — they use `run_switch "$d" --allow-dirty` without `--build`, so they must be untouched by the new branch.

- [ ] **Step 7: Commit**

```bash
git add packages/nd-switch.nix tests/run.sh
git commit -m "Let nd-switch --build report without refusing, and drop a stale comment"
```

---

## Task 4: `nd-save` recognises `captured` and points at `nd-switch`

**Files:**
- Modify: `packages/nd-save.nix`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `captured\t<dest>\t<repo_rel>` from Task 1.
- Produces: no new interface. `candidates` stays `drifted|new`, so a captured path is never copied and the E14 blocker never runs against it.

- [ ] **Step 1: Write the failing tests**

Append to the `nd-save` section of `tests/run.sh`:

```bash
# The other half of the deadlock. nd-save had already captured this content, so
# there is nothing left to copy — but its unplaced-edit guard compared the repo
# copy against the store source, found them different, and refused with "the
# repo carries edits that were never placed", pointing at the switch that
# nd-switch was simultaneously refusing to perform.
d=$(new_fixture)
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
out=$(run_save "$d" -y); st=$?
check_status "a captured file is not an error" 0 "$st"
check "a captured file is named" "already in the repo" "$out"
check "and the file is named" ".config/app/config.toml" "$out"
check "and the user is sent to nd-switch" "run 'nd-switch' to place them" "$out"
check_not "it is not refused as an unplaced edit" "never placed" "$out"
check_not "and it does not claim everything still matches" "every placed file still matches" "$out"
check "no commit was made" "captured" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# A repo copy that differs from what was placed and was never placed is still
# refused. That is what the E14 guard is for, and the reclassification must not
# reach it.
d=$(new_fixture)
drift "$d"
printf 'my unplaced edit\n' > "$d/repo/files/config.toml"
out=$(run_save "$d" -y); st=$?
check_status "an unplaced repo edit is still refused" 1 "$st"
check "the refusal still names it" "never placed" "$out"
check "the repo edit survives" "my unplaced edit" "$(cat "$d/repo/files/config.toml")"
rm -rf "$d"

# A captured glob file. Not a deadlock — nd-switch never gated on new — but
# nd-save refused with "already in the repo, never placed" about a file nd-save
# itself put there one run earlier.
d=$(new_glob_fixture)
printf '{"pinned":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
install -m 0644 "$d/home/.config/nv/lazy-lock.json" "$d/repo/files/nv/lazy-lock.json"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
out=$(run_save "$d" -y); st=$?
check_status "a captured glob file is not an error" 0 "$st"
check "a captured glob file is named" "already in the repo" "$out"
check_not "and is not refused as never placed" "never placed" "$out"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify they fail**

Rebuild, run the suite. Expected: the captured cases exit 1 with `never placed`. The middle case already passes and must keep passing.

- [ ] **Step 3: Teach the catch-all the new kind**

In `packages/nd-save.nix`, change:

```
      | grep -vE "^(drifted|missing|new|unreadable)$tab" || true)"
```

to:

```
      | grep -vE "^(drifted|missing|new|unreadable|captured)$tab" || true)"
```

- [ ] **Step 4: Collect it**

After the `unreadable=` line, add:

```
    captured="$(printf '%s\n' "$status" | grep "^captured$tab" | cut -f2 || true)"
```

- [ ] **Step 5: Report it and send the user to `nd-switch`**

After the `unknown` report block and before `if [ -z "$candidates" ]`, add:

```
    # Already in the repo, so there is nothing for nd-save to copy — and saying
    # only "nothing to save" here is what made the deadlock unreadable: it is
    # true that nd-save has no work, and false that nothing needs doing. The
    # action is a switch, and nd-switch will now perform it.
    if [ -n "$captured" ]; then
      echo "nd-save: these are already in the repo; there is nothing to copy:"
      printf '%s\n' "$captured" | sed 's/^/  /'
      echo "nd-save: run 'nd-switch' to place them."
      echo
    fi
```

- [ ] **Step 6: Keep the closing message honest**

Change:

```
      if [ -n "$unreadable" ] || [ -n "$unknown" ]; then
```

to:

```
      if [ -n "$unreadable" ] || [ -n "$unknown" ] || [ -n "$captured" ]; then
```

"every placed file still matches" is false when a captured file exists — it is precisely a placed file that does not match.

- [ ] **Step 7: Run to verify they pass**

Rebuild, run the suite. Expected: all Task 4 assertions pass, and the existing `nd-save` cases are unchanged.

- [ ] **Step 8: Commit**

```bash
git add packages/nd-save.nix tests/run.sh
git commit -m "Send nd-save's captured files to nd-switch instead of refusing them"
```

---

## Task 5: the zsh notice counts `captured` and advises accordingly

**Files:**
- Modify: `modules/nd-notice.zsh`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: `captured\t...` from Task 1.
- Produces: no new interface.

- [ ] **Step 1: Give `run_notice` the flake path**

The notice forks `nd-status`, which now reads `ND_FLAKE`. In `tests/run.sh`:

```bash
run_notice() {
  HOME="$1/home" PATH="$(dirname "$ND_STATUS"):$PATH" \
    zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1
}
```

becomes:

```bash
run_notice() {
  HOME="$1/home" ND_FLAKE="$1/repo" PATH="$(dirname "$ND_STATUS"):$PATH" \
    zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1
}
```

- [ ] **Step 2: Write the failing tests**

Append to the `zsh notice` section of `tests/run.sh`:

```bash
d=$(new_fixture)
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
out=$(run_notice "$d")
check "a captured file is announced" "1 captured" "$out"
check_not "and not as unrecognised" "unrecognised" "$out"
check "a captured-only state advises nd-switch" "nd-switch" "$out"
check_not "and does not advise nd-save" "nd-save" "$out"
rm -rf "$d"

# Captured and drifted together. nd-save still has work to do, so the advice
# must not be diverted by the captured file.
d=$(new_fixture)
printf 'other = 1\n' > "$d/other-source"
chmod 0444 "$d/other-source"
install -m 0644 "$d/other-source" "$d/home/.config/app/other.toml"
install -m 0644 "$d/other-source" "$d/repo/files/other.toml"
printf '%s\t%s\t%s\n' "$d/other-source" ".config/app/other.toml" "files/other.toml" \
  >> "$d/home/.local/state/nd/manifest"
drift "$d"
install -m 0644 "$d/home/.config/app/config.toml" "$d/repo/files/config.toml"
git -C "$d/repo" add -A
git -C "$d/repo" commit -qm captured
printf 'other = 2\n' > "$d/home/.config/app/other.toml"
out=$(run_notice "$d")
check "both are counted" "1 drifted" "$out"
check "captured is counted too" "1 captured" "$out"
check "the advice stays nd-save while drift remains" "nd-save" "$out"
rm -rf "$d"
```

- [ ] **Step 3: Run to verify they fail**

Rebuild is not needed — the notice is a plain file, not a package — but `nd-status` must already be the Task 1 build. Run the suite. Expected: `1 captured` fails, reported as `1 unrecognised`.

- [ ] **Step 4: Count the kind**

In `modules/nd-notice.zsh`, change:

```zsh
  local -i drifted=0 missing=0 created=0 unreadable=0 unrecognised=0
```

to:

```zsh
  local -i drifted=0 captured=0 missing=0 created=0 unreadable=0 unrecognised=0
```

Add an arm after the `drifted` one:

```zsh
      (captured$'\t'*)   (( captured++ )) ;;
```

Add a part after the `drifted` one:

```zsh
  (( captured )) && parts+=("$captured captured")
```

- [ ] **Step 5: Redirect the advice when only captured work remains**

Replace:

```zsh
  print -P "%F{yellow}nd:%f ${(j:, :)parts} config file(s) — run %Bnd-save%b to audit and commit"
```

with:

```zsh
  # nd-save is the right advice for everything it can act on, and the wrong
  # advice for a state made only of captured files: it will decline them and
  # send you here again. A switch is what places captured content — and what
  # restores a missing file — so when nothing is drifted or new, say so.
  # unreadable and unrecognised keep the nd-save advice, because nd-save is
  # where both are explained at length.
  local advice="run %Bnd-save%b to audit and commit"
  if (( captured && ! drifted && ! created && ! unreadable && ! unrecognised )); then
    advice="run %Bnd-switch%b to place them"
  fi

  print -P "%F{yellow}nd:%f ${(j:, :)parts} config file(s) — $advice"
```

- [ ] **Step 6: Run to verify they pass**

Run the suite. Expected: the Task 5 assertions pass, and the existing notice cases — clean, drifted, missing, new, unreadable, and the two catch-all stubs — are unchanged.

- [ ] **Step 7: Commit**

```bash
git add modules/nd-notice.zsh tests/run.sh
git commit -m "Count captured files in the shell notice and point them at nd-switch"
```

---

## Task 6: the README, and the deadlock end to end

**Files:**
- Modify: `README.md`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: the case that fails on `v0.2.0` and passes after this plan.

- [ ] **Step 1: Write the failing end-to-end test**

Append to the `end to end` section of `tests/run.sh`:

```bash
# The deadlock from issue #1, start to finish. On v0.2.0 the second nd-switch
# refuses and the second nd-save refuses, each naming the other, and no
# sequence of the two clears it.
d=$(new_fixture)
drift "$d"

out=$(run_switch "$d"); st=$?
check_status "uncaptured drift refuses the switch" 1 "$st"
check "and says to run nd-save" "run 'nd-save'" "$out"

out=$(run_save "$d" -y)
check "nd-save captures it" "copied back into the repo" "$out"
check "nd-save commits it" "committed" "$out"
check "the repo holds the live content" "setting = 2" "$(cat "$d/repo/files/config.toml")"

out=$(run_switch "$d"); st=$?
check_status "the switch is now allowed" 0 "$st"
check "and says why it is safe" "nothing is lost" "$out"
check "and reaches the build" "building" "$out"

# nd-save agrees there is nothing left for it, and sends the user to the switch
# rather than refusing.
out=$(run_save "$d" -y); st=$?
check_status "nd-save is not an error either" 0 "$st"
check "nd-save sends the user to nd-switch" "run 'nd-switch' to place them" "$out"

# And the loop closes: place it, and everything matches again.
install -m 0644 "$d/repo/files/config.toml" "$d/store-source-2"
chmod 0444 "$d/store-source-2"
printf '%s\t%s\t%s\n' "$d/store-source-2" ".config/app/config.toml" "files/config.toml" \
  > "$d/home/.local/state/nd/manifest"
out=$(run_status "$d")
check_empty "after the switch nothing is reported at all" "$out"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify it passes**

Rebuild, run the suite. Expected: it passes outright — Tasks 1 through 4 are what make it pass. Written last because it is the acceptance case for the whole plan, not a driver for any one part. If it fails, the failure names which earlier task is incomplete.

- [ ] **Step 3: Update the kind list in the README**

In section 2 of "How it works", replace:

```
2. **Detection.** `nd-status` reads the manifest and classifies every managed
   path as `drifted` (differs from the store source it was placed from),
   `missing` (deleted), `new` (a file under a glob root that matches a pattern
   and has no record yet) or `unreadable` (the store source cannot be opened, so
   drift cannot be decided either way). Drift is a content comparison against
   *what was actually installed*, which is what makes the next point work.
```

with:

```
2. **Detection.** `nd-status` reads the manifest and classifies every managed
   path as `drifted` (differs from the store source it was placed from),
   `captured` (differs from the store source, or was never placed, but the repo
   already holds that exact content where git can see it), `missing` (deleted),
   `new` (a file under a glob root that matches a pattern and has no record yet)
   or `unreadable` (the store source cannot be opened, so drift cannot be
   decided either way). Drift is a content comparison against *what was actually
   installed*, which is what makes the next point work.
```

- [ ] **Step 4: Update the gate description**

In section 3, replace:

```
3. **Gate.** `nd-switch` refuses to switch while any managed file has drifted,
   because switching would copy over it. `missing`, `new` and `unreadable` are
   reported but do not block: a missing file will be restored by the switch, a
   new file has no store source to be overwritten by, and an unreadable source
   is repaired by the switch, which rewrites the manifest.
```

with:

```
3. **Gate.** `nd-switch` refuses to switch while any managed file has drifted,
   because switching would copy over it. `captured`, `missing`, `new` and
   `unreadable` are reported but do not block: a captured file is rebuilt from
   the repo copy that already matches it, so the overwrite discards nothing; a
   missing file will be restored by the switch; a new file has no store source
   to be overwritten by; and an unreadable source is repaired by the switch,
   which rewrites the manifest.
```

- [ ] **Step 5: Add the third state to "Why compare against the store, not the repo"**

That section states the two-way reasoning as if it were complete. Append to it:

```markdown
There are three states, not two, and the third is why `captured` exists:

| live vs placed | live vs repo | meaning | what happens |
| --- | --- | --- | --- |
| same | same | nothing happened | switch |
| differs | differs | the app rewrote it, not yet captured | refuse — this is what the gate is for |
| differs | same | the app rewrote it, `nd-save` already captured it | switch; the new generation builds this file *from* the repo copy, so the overwrite discards nothing |

Before the third row was distinguished, it was classified as drift and refused,
and the refusal was self-perpetuating: only an activation rewrites the manifest,
and `nd-switch` was the thing declining to activate. `nd-save` could not break it
either, because the state it would have had to change is the manifest, which
activation owns. `nd-status` decides the third row by asking whether the repo
copy is byte-identical to the live file *and* visible to git — an untracked file
is invisible to a flake build, so a byte-identical untracked copy would not
survive the switch. Anything it cannot decide stays `drifted`.
```

- [ ] **Step 6: Update the `nd-status` usage line and worked example**

Change:

```
$ nd-status                 # what drifted, went missing, appeared or cannot be read
```

to:

```
$ nd-status                 # what drifted, was captured, went missing, appeared or cannot be read
```

- [ ] **Step 7: Run the full flake check**

```bash
nix flake check
```

Expected: every check passes.

- [ ] **Step 8: Commit**

```bash
git add README.md tests/run.sh
git commit -m "Describe the captured kind in the README and pin the deadlock end to end"
```

---

## Task 7: close the escalation log

**Files:**
- Modify: `docs/superpowers/escalations-2026-08-11-nd-captured.md`

- [ ] **Step 1: Resolve every open entry**

Read the log start to finish. Every entry is **resolved** or **deferred to the maintainer**; nothing stays **open**. A resolved entry says what was decided and why the alternative was rejected. A deferred entry says what the two positions are, what the current code does, and which tests encode that answer — so changing the answer means changing them.

- [ ] **Step 2: Write the closing state**

Append a `## Closing state` section, following the model at the end of `docs/superpowers/escalations.md`: the count resolved, and each deferred entry restated in full with both arguments, because the maintainer will read that section alone.

- [ ] **Step 3: Verify the whole thing once more**

```bash
nix flake check
```

And the suite directly, so the pass/fail counts are visible rather than swallowed by the check:

```bash
nix build --no-link --print-out-paths .#nd-switch .#nd-save .#nd-status
```

then `tests/run.sh` with those paths. Record the final `passed N, failed 0` line in the closing state.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/escalations-2026-08-11-nd-captured.md
git commit -m "Close out the captured-kind escalation log"
```

---

## Self-review notes

Checked against the spec:

- `captured` for file records — Task 1, Steps 4–5.
- `captured` for glob records — Task 1, Step 5, and tested in Step 2.
- Worktree-and-tracked as the reference — Task 1, Step 4, tested three ways in Step 2 (tracked and committed, tracked and uncommitted, untracked).
- Fail closed on everything undecidable — Task 1, Step 2, four negative cases.
- `nd-status` gains `ND_FLAKE` and `git` from `PATH` — Task 1, Step 4; `runtimeInputs` is deliberately untouched.
- `--help` documents the kind — Task 1, Step 6.
- `nd-switch` catch-all, report, gate unchanged — Task 2.
- `--build` reports without blocking, with its own wording — Task 3.
- Stale comment deleted, behaviour pinned by test — Task 3, Steps 1 and 5.
- `nd-save` catch-all, report, redirect, honest closing message — Task 4.
- Notice arm, part, and advice — Task 5.
- README kind list, gate description, three-state table, usage line — Task 6.
- End-to-end deadlock case — Task 6, Step 1.
- Escalation log opened, appended, closed — Tasks 0 and 7.

Deliberately not in this plan, because the spec puts them out of scope: prose output for `nd-status`, any change to `--allow-dirty`, E17, and any change to the manifest format.
