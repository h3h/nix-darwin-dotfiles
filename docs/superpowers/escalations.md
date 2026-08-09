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
