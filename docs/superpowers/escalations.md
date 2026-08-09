# Escalations — nd globs and defect fixes

Plan: `docs/superpowers/plans/2026-08-09-nd-globs-and-defects.md`
Spec: `docs/superpowers/specs/2026-08-09-nd-globs-and-defects-design.md`

Entry format is defined in the plan's "Escalation protocol" section.
Statuses: `open` (needs a decision), `resolved` (decided, with reasoning
recorded), `unresolved` (escalated and still undecided at hand-off).

---

## E1 — `git add --intent-to-add` then `git commit --only` was unverified
- **Task:** 5 (pre-flight, run before dispatch)
- **Raised:** The plan asserts that staging a newly captured file with
  `git add -N`, then `git add`, then committing with `git commit --only -- <paths>`
  commits only those paths and leaves unrelated staged content staged. If that
  were wrong, defect 1's fix would need a different mechanism
  (`git stash push --staged`, or `git commit-tree` against a scratch
  `GIT_INDEX_FILE`), which is a design change rather than a code change.
- **Options:** verify empirically before writing the code, or write the code and
  find out from the test.
- **Status:** resolved
- **Resolution:** Verified in a scratch repo. With `unrelated.txt` staged and
  `tracked.txt` (modified) plus `created.txt` (untracked) as the managed paths:
  `git status --porcelain --` reported ` A created.txt` / ` M tracked.txt`;
  `git diff HEAD --` showed both, including the untracked one, because of the
  intent-to-add; the commit contained exactly `created.txt` and `tracked.txt`;
  and `git diff --cached --name-only` still listed `unrelated.txt` afterwards
  with its working-tree content intact. The plan's incantation stands as
  written. Task 5 Step 0 may be skipped.

## E2 — `flakePath` and `manifestPath` never reach the binaries
- **Task:** 10
- **Raised:** `programs.nd.flakePath` and `programs.nd.manifestPath` are
  declared in `modules/home-manager.nix:22-29` and `:69-76`, documented in the
  README, and never referenced in the module's `config` block. `nd-switch`,
  `nd-save` and `nd-status` each fall back to their own hardcoded defaults, so
  anyone who sets either option gets tools pointed at the wrong place. Not in
  the issues document; found while working out how `expectedBranch` would reach
  `nd-save`.
- **Options:** (a) fix it as part of this work, since `expectedBranch` needs the
  same route and would otherwise be a second dead option; (b) leave it and file
  it separately, keeping this change closer to the issues document.
- **Status:** resolved
- **Resolution:** (a). `expectedBranch` is unimplementable without a route from
  the module to the binary, so the route has to be built here regardless; once
  built, not also threading the two existing dead options would be leaving a
  known bug in a file being edited for exactly that reason. Implemented as
  `makeWrapper --set-default`, so an explicitly exported `ND_*` still wins and
  the documented environment overrides keep working.

## E3 — commit-subject derivation refined against the spec
- **Task:** 8
- **Raised:** The spec's rule is "if the destination starts with `.config/`, the
  component following it". For `.config/starship.toml` that yields
  `starship.toml`, giving the subject `Save starship.toml config written by the
  app`.
- **Options:** implement the spec literally, or truncate every derived token at
  its first `.` so the `.config/` and non-`.config/` branches share one
  post-step.
- **Status:** resolved
- **Resolution:** Truncate. Same shape, one uniform rule, and it is strictly
  better output on the case the spec's wording happens to miss.
  `.config/zed/settings.json` and `.config/nvim/lua/x.lua` are unaffected.
  No lookup table of application names is introduced, which was the constraint
  the spec actually cared about.

## E4 — `callPackage` does not resolve `nd-status` from the `rec` packages set
- **Task:** 4
- **Raised:** The plan (Task 5, Step 3, and by implication Task 4) states
  "`callPackage` resolves it automatically once `nd-status` is in the same `rec`
  set — confirm the `packages` attribute set is `rec` (it is)". It is `rec`, and
  it does not. `nix build --no-link --print-out-paths .#nd-switch` after adding
  the `nd-status` argument to `packages/nd-switch.nix`:

  ```
  error: evaluation aborted with the following error message:
  'lib.customisation.callPackageWith: Function called without required argument
  "nd-status" at .../packages/nd-switch.nix:6'
  ```

  `pkgs.callPackage` takes its auto-arguments from `pkgs`, not from the
  attribute set the call happens to be written inside. `rec` only puts
  `nd-status` in Nix lexical scope; it does not put it in `callPackage`'s
  lookup scope.
- **Options:** (a) pass it explicitly, `pkgs.callPackage ./packages/nd-switch.nix
  { inherit nd-status; }`; (b) build a scope with `lib.makeScope` /
  `pkgs.extend` so auto-resolution works as the plan describes.
- **Status:** resolved
- **Resolution:** (a). The plan's intent is that `nd-switch` receives the
  `nd-status` from this flake rather than a second copy; an explicit `inherit`
  achieves that in one line, and a scope would be new machinery for three
  packages. Task 5 must do the same for `nd-save` — the plan's claim there is
  wrong for the same reason.

## E5 — a Task 5 test asserts a HEAD subject its own fixture has replaced
- **Task:** 5
- **Raised:** The plan's third Task 5 case ("an unrelated edit does not make
  nd-save commit") builds a fixture, then commits on top of it:

  ```bash
  d=$(new_fixture)                       # HEAD subject is now "initial"
  printf 'noise\n' > "$d/repo/noise.txt"
  git -C "$d/repo" add noise.txt
  git -C "$d/repo" commit -qm "add noise"   # HEAD subject is now "add noise"
  ...
  check "no commit was made" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
  ```

  `git log -1 --format=%s` returns `add noise`, so the assertion fails
  regardless of whether `nd-save` behaves correctly. It is testing the wrong
  string, not a real defect. The case's intent — "nd-save added no commit" —
  is unambiguous from its comment and from the two sibling cases.
- **Options:** (a) assert the subject the fixture actually leaves at HEAD,
  `add noise`, keeping the case's intent intact; (b) drop the assertion and
  keep only the `nothing to save` check, losing the "no new commit" guarantee;
  (c) restructure the fixture so `initial` stays at HEAD, which means making the
  unrelated edit untracked and thereby removing the "unrelated committed file
  with an unstaged edit" condition the case exists to exercise.
- **Status:** resolved
- **Resolution:** (a). The assertion's purpose is to prove `nd-save` left HEAD
  where it found it; naming the commit the fixture actually ends on proves
  exactly that, and it is the smallest change that makes the case mean what its
  comment says. The case is a guard rather than a regression test — the plan
  says so itself, since the live file is byte-identical to the store and both
  the old and new `nd-save` stop at "nothing to save" — so with the subject
  corrected it passes before and after, which is the intended shape.

## E6 — `repoSubdir` has no default, so its assertion looked unreachable
- **Task:** 9 (raised by the implementing agent, adjudicated separately)
- **Raised:** `programs.nd.repoSubdir` is `types.str` with no default, so a
  config that sets `files` or `globs` but omits `repoSubdir` dies with nixpkgs'
  generic "The option 'programs.nd.repoSubdir' was accessed but has no value
  defined" before the module's friendly assertion can fire. Pre-existing, not
  introduced by this work.
- **Options:** (a) add `default = ""` so the assertion fires and the user sees
  the specific message; (b) leave it.
- **Status:** resolved
- **Resolution:** (b), leave it. Escalated to Fable for judgment. Three reasons.
  "No default" is the type-level statement of "required" and is the stronger
  mechanism; `default = ""` would make a required option render as optional in
  the generated docs, demoting a type-level guarantee to a runtime assertion.
  The generic nixpkgs error already names the option, which is the exact
  standard the neighbouring `pathExists` assertion was justified by — that one
  exists because `listFilesRecursive`'s error does *not* name the option. And
  the assertion is not dead: `types.str` cannot forbid `""`, and
  `repoSubdir = ""` is a plausible mistake for someone whose `sourceDir` sits at
  the flake root, which would silently produce repo paths with a leading `/`.
  Omission is caught by the type system, the empty string by the assertion. The
  division of labour is coherent, not accidental.

## E7 — every glob root dragged a redundant copy of its source subtree into the store
- **Task:** 9 (raised by the implementing agent, adjudicated separately)
- **Raised:** Field 1 of a glob manifest record was built as
  `cfg.sourceDir + "/${g.source}"`. Because that is an unrooted source path,
  Nix copies the entire subtree into the store as its own store path, on top of
  the per-file copies the file records already make. Observed as
  `/nix/store/9fi2f…-nv`. No reader uses the field: `nd-status` passes fields 2,
  3 and 5 to `scan_glob` and drops field 1, and `nd-save`'s blocker check reads
  field 1 of *file* records only (`awk '$4 == ""'`).
- **Options:** (a) leave it, for format symmetry and possible future use;
  (b) emit a literal `-` placeholder, documented as unused; (c) emit
  `toString (...)`, avoiding the copy but yielding a build-machine path with no
  liveness guarantee on the target; (d) find a genuinely useful payload.
- **Status:** resolved
- **Resolution:** (b). Escalated to Fable for judgment. Every hypothetical future
  use reduces to a per-file question — "did this placed file's source vanish",
  "what did this generation place under the root" — and the file records already
  answer all of them, each carrying its own store source. The symmetry argument
  is also inaccurate: the copied subtree contains files no pattern matched, so
  field 1 was never "the store source of this record" in any meaningful sense.
  (c) is worse than either, being a field that looks usable and is not. (d) has
  no candidate payload, and shrinking glob records to four fields would shift
  `kind` out of column 4 and break the single `read -r src dest repo_rel kind
  pattern` parse that both record kinds share.

  Applied to `modules/home-manager.nix` (`globPatternRecords` drops `srcRoot`;
  `manifestText` emits `-`), to the spec's Manifest v2 section, and to the three
  `new_glob_fixture` manifest lines in `tests/run.sh`. No change to
  `packages/nd-status.nix` or `packages/nd-save.nix`, neither of which reads it.

## E8 — declining `nd-save` left an intent-to-add entry in the index
- **Task:** final review (regression introduced by Task 5's own fix)
- **Raised:** Task 5 added `git add --intent-to-add -- "${paths[@]}"` before the
  confirmation prompt, so that `git diff HEAD --` can show a newly captured file
  that git does not yet track. It mutates the index before the user has agreed
  to anything, and nothing undid it on refusal. Reproduced in a scratch repo:
  after `git add -N created.txt`, a later `git commit -am "unrelated"` of the
  user's own commits `created.txt` along with their work. Confirmed against the
  real binary — the test `the declined capture stays out of the user's commit`
  failed against the unfixed `nd-save` and passes against the fixed one.

  This is defect 1's failure — application-written config landing in a commit
  that is about something else — arriving through a door the fix for defect 1
  opened.
- **Options:** (a) move the intent-to-add after the prompt, losing the preview
  of new files, which is the only reason it exists; (b) `git reset -- <paths>`
  on refusal, which would also discard staging the user did themselves on a
  managed path; (c) record which paths git did not already know, and reset
  exactly those; (d) leave it and say so in the abort message.
- **Status:** resolved
- **Resolution:** (c). Before the intent-to-add, `git ls-files --error-unmatch`
  partitions `paths` into tracked and untracked; `unstage_captures` resets only
  the untracked ones and runs on both non-committing exits (refusal, and
  "nothing to commit"). The abort message now says the index is as the user left
  it. Two tests pin it: a declined capture stays out of the index and out of the
  user's next commit, and a user's own staging of a *tracked* managed path
  survives a refusal untouched.

  Method note: the first version of the index assertion used
  `git diff --cached --name-only`, which does not show intent-to-add entries and
  so passed against the unfixed binary. Replaced with `git ls-files -- <path>`,
  which asks the index directly. Both assertions were then confirmed red against
  the unfixed `nd-save` before the fix was restored.
