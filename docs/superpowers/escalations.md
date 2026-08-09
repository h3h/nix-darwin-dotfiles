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
