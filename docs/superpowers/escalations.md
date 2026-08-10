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

## E9 — the spec's escape list is wrong for `builtins.match`; `]` and `-` must not be escaped
- **Task:** F1 (adversarial review follow-up)
- **Raised:** The spec's translation algorithm, step 4, says "Escape ERE
  metacharacters: `\` first, then `.` `+` `(` `)` `[` `]` `{` `}` `^` `$` `|`",
  and `lib/glob.nix` implemented exactly that. GNU grep accepts `\]`;
  `builtins.match` rejects it outright. So `patterns = [ "[abc].lua" ]`, a case
  both the module's option description and the README document as supported
  ("bracket characters are matched literally"), aborted evaluation of the user's
  entire home-manager config:

  ```
  $ nix eval --impure --raw --expr 'let ... in glob.matchesAny [ (glob.globToERE "[abc].lua") ] "a.lua"'
  error: invalid regular expression '\[abc\]\.lua'
  ```

  Every candidate character was then probed against both engines rather than
  reasoned about. Escaped as `\c`, against `builtins.match` and `grep -qxE`:

  | char | `builtins.match "\c"` | `grep -qxE '\c'` |
  | --- | --- | --- |
  | `\ . + ( ) [ { } ^ $ \|` | ok | ok |
  | `]` | **throws** | ok |
  | `-` | **throws** | ok |
  | `<` `>` | throws | no match (word boundaries) |
  | `=` | throws | throws |

  Unescaped, both engines treat a bare `]` and a bare `}` as literal; both
  engines reject a bare `{`.
- **Options:** (a) drop `]` from the table, keep `}`; (b) drop both `]` and `}`,
  on the symmetry argument that they are the closing halves of the same pairs;
  (c) keep the table and make `matchesAny` pre-strip escapes it knows
  `builtins.match` dislikes, i.e. a second translator in the file whose whole
  purpose is that there is only one.
- **Status:** resolved
- **Resolution:** (a). The principle that survives contact with both engines is
  "escape exactly the characters that are special to POSIX ERE". `]` outside a
  bracket expression is *ordinary* in POSIX, so `\]` is an escape of a
  non-special character — undefined by POSIX, tolerated by GNU grep, rejected by
  std::regex. `}` is different: POSIX leaves a stray `}` undefined rather than
  ordinary, it is part of interval syntax, and both engines accept `\}`. So the
  two are not symmetric and (b) would drop an escape that is doing real work.
  Correctness of the `]` case does not depend on the escape: `[` is still
  escaped, so no bracket expression can ever open, so every `]` in the output is
  unambiguously literal to both engines. `-` is absent for the same reason as
  `]` and there is now a comment saying it must stay absent, because adding it
  looks harmless and is not. (c) is the design's stated failure mode.

  This makes the spec's step 4 stale. `docs/.../design.md` is outside this
  change's ownership, so it is not edited here: **the spec's escape list still
  names `]` and should be corrected to `\` `.` `+` `(` `)` `[` `{` `}` `^` `$`
  `|`, with a note that the list is empirical.** `lib/glob.nix` carries the
  reasoning and the failing repl transcript inline so the next editor does not
  re-derive it from the spec.

## E10 — the star-run collapse was documented but never implemented
- **Task:** F3 (adversarial review follow-up)
- **Raised:** `lib/glob.nix` and the spec both claim "a run of two or more `*`
  that is neither `**/` nor a trailing `/**` collapses to a single `*`".
  `lib.replaceStrings [ "**" ] [ "*" ]` is one left-to-right pass, so it halves
  a run instead of collapsing it. Confirmed by reverting the fix and reading the
  check's failure output:

  ```
  "g":"***.lua","got":"[^/]*[^/]*\\.lua"}
  "g":"**********.lua","got":"[^/]*[^/]*[^/]*[^/]*[^/]*\\.lua"}
  ```

  Behaviourally equivalent, so no user-visible bug, but chained unbounded
  quantifiers are the classic backtracking shape for `builtins.match`
  (std::regex), and the comment was simply false.
- **Options:** (a) iterate `replaceStrings` to a fixed point, making the
  documented behaviour true; (b) correct the comment to describe the halving.
- **Status:** resolved
- **Resolution:** (a). The plan and the spec both state the collapse as the
  design's intent, so weakening the comment would be changing the design to
  match an implementation slip. The fix is four lines of self-recursion bounded
  by the string length, it removes the backtracking shape rather than
  documenting it, and it is cheaper than explaining in the comment why the
  output has five chained `[^/]*` in it. Three translation cases pin it —
  `***.lua`, `**********.lua`, and `***/x.lua`, which checks that a long run
  ending in `/` still yields the `**/` token.

## E11 — `nd-status` passes a translated ERE to `grep` without `--`
- **Task:** F2 (adversarial review follow-up), observation only
- **Raised:** While building the cross-engine check, `packages/nd-status.nix:71`
  and `:74` read:

  ```sh
  if ! printf '%s' "$rel" | grep -qxE "$ere"; then
  ```

  `globToERE` does not escape `-`, and cannot (see E9), so a pattern beginning
  with `-` — `-foo/**`, plausible for a dotfile repo with a `-` prefixed
  directory — reaches `grep` as an option rather than a pattern:

  ```
  $ printf -- '-foo/x\n' | grep -qxE "-foo/.*"; echo $?
  grep: error: option -f: cannot read oo/.*
  2
  ```

  It fails silently rather than loudly. Exit 2 is not 0, the call sits under
  `if ! ... ; then continue; fi`, and `errexit` does not apply inside an `if`
  condition, so every path under that root is skipped and nothing is reported.
  The new
  `tests/glob-engines.sh` uses `grep -qxE -- "$ere"`, which is why the check does
  not reproduce it, and there is deliberately no case with a leading `-`.
- **Options:** (a) fix `nd-status.nix`; (b) drop the `--` from the test script so
  the check reflects what `nd-status` actually runs, and add a leading-`-` case;
  (c) report it and leave both as they are.
- **Status:** resolved
- **Resolution:** (a), fixed in `packages/nd-status.nix`. `--` now precedes the
  pattern at both call sites: `grep -qxE -- "$ere"` for the pattern match and
  `grep -qxF -- "$dest_prefix$rel"` for the placed-membership test. The second
  was not in the original report and has the same exposure, for a destination
  root beginning with `-`.

  Reproduced first against the unfixed binary, with `-foo/.*` added as a fourth
  glob record and `.config/nv/-foo/a.txt` created under the root:

  ```
  grep: oo/.*: No such file or directory
  grep: oo/.*: No such file or directory
  grep: oo/.*: No such file or directory
  grep: oo/.*: No such file or directory
  new	.config/nv/new1.lua	files/nv/new1.lua
  ```

  Four errors, one per file under the root, and `-foo/a.txt` reported by
  nothing. Pinned by `a pattern starting with a dash still matches` and
  `a pattern starting with a dash is not read as options` in `tests/run.sh`,
  both confirmed red against the unfixed `nd-status`.

  Option (b) is now moot: `tests/glob-engines.sh` already passes `--`, which is
  what `nd-status` does, so the check and the program agree. **Still outstanding
  and not mine to do** — see E21 for the `tests/glob.nix` case the original
  report asked for.

## E12 — an answer that ended without a newline is not an answer
- **Task:** adversarial review, finding F1
- **Raised:** `read -r reply` returns non-zero at end of input, and `nd-save`
  runs under `errexit`, so the script died before the `case` on every input
  that ended without a newline. `printf 'n' | nd-save` printed nothing after
  the prompt and left the intent-to-add entry in the index; `printf 'y' |
  nd-save` exited 1 having copied the files and committed nothing. Bash still
  assigns the partial line to `reply` in both cases, so the fix has a choice to
  make: honour the partial answer, or discard it.
- **Options:** (a) `if ! read -r reply; then reply=""; fi` — an unterminated
  answer takes the default, which is no; (b) `read -r reply || true` — honour
  whatever arrived, so `printf 'y'` commits.
- **Status:** resolved
- **Resolution:** (a). The three ways to reach a failed `read` are a pipe that
  ended mid-answer, closed stdin (cron, a dead pipe, `< /dev/null`) and Ctrl-D.
  None of them is a person saying yes to a commit, and two of them are the
  unattended case, where the whole point of the prompt is that nobody agreed to
  anything. `-y` exists for callers that mean yes. Under (b), `nd-save </dev/null`
  in a script would commit whenever the config happened to contain a `y` — a
  silent commit from an input that was never an answer, which is the same class
  of surprise defect 3 was filed for. Tests pin all three doors, plus SIGINT.

## E13 — restoring the index by snapshot rather than by path-scoped reset
- **Task:** adversarial review, findings F1 and F2
- **Raised:** E8's `unstage_captures` resets only the paths git did not already
  know. That is correct for a decline, and it is not enough for a failed commit
  (F2): by then `git add -- <paths>` has replaced whatever the user had staged
  on a *tracked* managed path, and a path-scoped reset cannot put that content
  back — it can only reset to HEAD, which discards it just as thoroughly.
  Reproduced with a `pre-commit` hook that exits 1: `nd-save -y` exited 1 with
  no diagnostic and `git diff --cached --name-only` listed the capture.
- **Options:** (a) leave the tracked case unrecoverable and print a message
  naming what is left staged; (b) snapshot `$GIT_DIR/index` before the first
  mutation and copy it back on any exit that does not commit; (c) rebuild the
  commit against a scratch `GIT_INDEX_FILE` so the real index is never touched.
- **Status:** resolved
- **Resolution:** (b), with (a) as the fallback. A byte copy of the index file
  restores the exact prior state — intent-to-add entries, the user's staging of
  a tracked managed path, everything — which is strictly more than the reset
  can do, and it subsumes `unstage_captures` on every path that reaches it.
  `unstage_captures` is kept and used when no snapshot could be taken: a
  repository that has never staged anything has no index file to copy.
  (c) is a larger rewrite of the commit step for no additional coverage, since
  the working-tree copies still have to happen before the commit either way.

  Two things this deliberately does not solve, recorded rather than hidden.
  A concurrent `git add` in another terminal, between the snapshot and the
  restore, is clobbered; the window is the length of one prompt, and the
  path-scoped reset has the same exposure. And a `pre-commit` hook that stages
  work of its own before failing has that staging discarded — the commit it was
  staging for did not happen.

## E14 — the unplaced-edit guard now fails closed on an undeterminable source
- **Task:** adversarial review, finding F3
- **Raised:** The defect-2 blocker looked the store source up with
  `awk -F'\t' -v d="$dest" '$2 == d && $4 == ""'`. `awk -v` runs the assigned
  value through escape processing, so a destination containing a backslash
  (`.config/app/co\nfig.toml`) reached the comparison with the backslash
  sequence expanded, never matched, and left `$src` empty. `[ -n "$src" ]` then
  short-circuited the check: `nd-save -y` exited 0 and overwrote an unplaced
  repo edit. Fixing the lookup (`ENVIRON`, which does no escape processing)
  leaves the question the short-circuit was hiding: what should happen when the
  store source genuinely cannot be determined?
- **Options:** (a) keep skipping the check, i.e. copy over the repo file;
  (b) treat an undeterminable source as a blocker whenever the repo already
  holds a file at that path.
- **Status:** resolved
- **Resolution:** (b). "I cannot tell what was placed here" is not a reason to
  overwrite a file, it is the reason not to; the whole point of the guard is
  that the repo copy may be work that exists nowhere else. It cannot fire
  spuriously in normal operation, either: `nd-status` only reports a path as
  `drifted` on the strength of a manifest file record, so an empty `$src` means
  the manifest disagrees with itself. It stays scoped to paths where the repo
  file exists, because with nothing there, there is nothing to destroy.
  `--force` still overrides, as it does for every other blocker.

## E15 — a staged-only edit on a managed path: block, or document the gap
- **Task:** adversarial review, finding F7
- **Raised:** The defect-2 guard compares the working tree with the store and
  never looks at the index. With staged content on a managed path and a working
  tree that matches the store, `nd-save -y` runs `git add` over the path and the
  staged blob becomes unreachable — not in the working tree, which the copy has
  just overwritten, and not in any commit. The review left the call open:
  extend the blocker, or document the gap in a source comment.
- **Options:** (a) treat "this path has staged content differing from HEAD" as
  a blocker, overridable by `--force`; (b) document it and leave it; (c) try to
  preserve the staged blob, e.g. by stashing the index around the capture.
- **Status:** resolved
- **Resolution:** (a). Three reasons. It is the same loss defect 2 exists to
  prevent — uncommitted work in the repo destroyed by a copy the preview shows
  as though it were the only change — and the guard already refuses that loss
  when it is one version to the left, in the working tree; refusing it there and
  permitting it in the index is an inconsistency, not a policy. The test is one
  command, `git diff --cached --quiet -- <path>`, and it is exact rather than
  heuristic. And the false-positive cost is small and recoverable: the run
  refuses, names the path, and `--force` is one flag away, whereas the failure
  it prevents is silent and permanent.

  (c) was rejected as the wrong shape. Preserving the blob means either
  committing it (nd-save must never commit work the user did not offer it) or
  stashing it, which moves the user's staging somewhere they did not put it and
  have not been told about. Refusing hands the decision back to the person who
  staged the content, which is where it belongs.

  Note that E13's index snapshot does not cover this: the snapshot restores the
  index when the run does *not* commit, and this case is a run that succeeds.

## E16 — `--allow-dirty` names what it discards, and does not back it up
- **Task:** defect 10
- **Raised:** The issues document's fix for defect 10 says "consider copying
  each drifted file to `<path>.nd-bak` first, mirroring home-manager's own
  `backupFileExtension`", and the spec defers the question here rather than
  settling it. The list-and-warn half is not in doubt; the backup half is.
- **Options:** (a) warn only — name every drifted file, say the contents will be
  discarded, proceed; (b) also copy each drifted file to `<path>.nd-bak`;
  (c) offer the backup behind a new flag or a `programs.nd` option.
- **Status:** resolved
- **Resolution:** (a), warn only. No `.nd-bak`, no new flag, no option, no
  change to `modules/`. Two reasons, both about the copy being wrong rather than
  merely unnecessary.

  `nd-switch` does not perform the overwrite — activation does, several minutes
  and two failure points later. A copy taken here is stale the moment `nix
  build` fails, the sudo prompt is refused, or activation itself dies, and a
  stale `.nd-bak` sitting beside a file that was never touched is worse than no
  backup: it reads as a record of an overwrite that did not happen.

  And a `.nd-bak` inside a glob root can match the user's own pattern.
  `colors/**` matches `colors/x.vim.nd-bak`, so `nd-status` would report the
  backup as `new` and `nd-save` would capture it into the repo and commit it.
  The mechanism meant to protect the file would put a copy of it somewhere the
  user never asked for, permanently.

  The warning is the whole fix: it names every file, says the contents will be
  discarded, points at `nd-save`, and prints before `nix build` and before the
  sudo prompt, so there is still something to interrupt. `nd-save` is the
  backup, and it is one command away.

## E17 — a rollback warns about drift but is not gated by it
- **Task:** defect 10, second door (found during review, not in the issues file)
- **Raised:** `packages/nd-switch.nix`'s `--rollback` branch returned before the
  drift check was ever reached, so `nd-switch --rollback` ran
  `sudo darwin-rebuild switch --rollback`, activation overwrote every drifted
  file, and nothing was printed. Defect 10's loss, through a door
  `--allow-dirty` does not guard. Reproduced against the unfixed binary with a
  drifted fixture and a stub `sudo`:

  ```
  nd-switch: rolling back one generation from 56
  stub sudo darwin-rebuild switch --rollback
  nd-switch: done. Relaunch your terminal fully if PATH or packages changed.
  ```

  Not one word about the drifted file it was about to discard.
- **Options:** (a) warn and proceed, the same list-and-warn the `--allow-dirty`
  path now gets; (b) gate it as the ordinary switch is gated, with
  `--allow-dirty` as the override; (c) gate it with its own override.
- **Status:** resolved for the warning, **open for the gate**
- **Resolution:** (a) is implemented. `report_status "--rollback"` runs at the
  top of the rollback branch, before `readlink` and well before `sudo`, and
  prints the same "will be OVERWRITTEN … contents will be discarded" block the
  `--allow-dirty` path prints. It does not refuse.

  The reason not to gate is that a rollback is what you reach for when something
  is already broken, and the tool refusing to run the repair because a config
  file drifted is the wrong trade — especially since the drift may be a
  consequence of whatever you are rolling back from.

  **This half is a genuine open question and I did not settle it.** The argument
  the other way is real: an ordinary switch and a rollback destroy drifted
  content identically, `--allow-dirty` already exists as the override, and
  "warn on one path, refuse on the other" is an inconsistency a user has to
  learn rather than derive. Whether `--rollback` should honour the gate with
  `--allow-dirty` as its escape hatch is the maintainer's call. If it changes,
  `--rollback is not blocked` and `--rollback still rolls back` in `tests/run.sh`
  are the two cases that encode the current answer.

## E18 — a trailing slash in a `globs` key is normalised in `nd-status`, not rejected
- **Task:** `nd-status` robustness
- **Raised:** `scan_glob` computed `rel="${f#"$HOME/$root/"}"`. With a `globs`
  key of `.config/nv/`, `root` is `.config/nv/`, the prefix `$HOME/.config/nv//`
  never matches, and `rel` stays absolute. Observed against the unfixed binary:

  ```
  new	.config/nv///var/folders/…/home/.config/nv/init.lua	files/nv//var/folders/…/home/.config/nv/init.lua
  ```

  Every placed file is reported `new` forever, because the membership test
  against `placed` cannot match either, and `nd-save` would `mkdir -p` and
  `install` that path inside the repo — an absolute path grafted under the repo
  root.
- **Options:** (a) normalise in `nd-status` only; (b) normalise in
  `nd-status` and also reject or normalise the key in `modules/home-manager.nix`;
  (c) reject in the module only.
- **Status:** resolved for `nd-status`, **open for the module**
- **Resolution:** (a) is implemented. `strip_trailing_slashes` normalises both
  the destination root and the repo root, and the relative path is now derived
  from the exact string `find` was given, so the strip cannot miss. A root that
  normalises away entirely is handled by moving the separator into a prefix
  variable rather than the format string. Pinned by
  `a trailing slash in the root still yields relative paths` and its two
  siblings, all red against the unfixed binary.

  `nd-status` has to be robust here regardless of what the module does, because
  the manifest is a plain text file a user can edit and a truncated write can
  damage. But (b) is the better whole answer and I could not implement it:
  `modules/` is outside this change's ownership. **For the module's owner:**
  `programs.nd.globs` should either strip trailing slashes from its keys or
  assert against them, because a key of `.config/nv/` is a plausible typo that
  currently produces no evaluation error and a silently broken manifest.

## E19 — an unreadable store source is its own kind, and does not block the switch
- **Task:** `nd-status` robustness
- **Raised:** `cmp -s` exits 1 for "they differ" and 2 for "I could not read
  one of them", and `! cmp -s` treats both as drift. With the store source
  deleted, `nd-status` reported `drifted` and `nd-save` then blamed the user's
  repo for a difference from a file neither of them could open:

  ```
  drifted	.config/app/config.toml	files/config.toml
  nd-save: the repo carries edits that were never placed; nothing copied:
    files/config.toml (repo copy differs from what was placed)
  ```

  Distinguishing the two exit statuses is not in question. What the new kind
  should be called, and whether `nd-switch` should refuse on it, are.
- **Options:** for the name, `unreadable` / `unknown` / `unresolvable`. For the
  gate: (a) warn and proceed; (b) block as `drifted` blocks, with
  `--allow-dirty` as the override; (c) block with no override.
- **Status:** resolved
- **Resolution:** `unreadable`, and (a) warn and proceed.

  The name says what is true and nothing more — the source could not be opened —
  rather than `unknown`, which in this program would collide with "a kind the
  reader does not recognise", which is a different thing that `nd-switch` now
  also reports.

  Warn rather than block, for one decisive reason: the switch is the repair.
  Activation rewrites the manifest with the current generation's store paths, so
  the unreadable source stops being unreadable precisely by switching. Blocking
  would leave the tool unable to fix its own broken state, with no route out but
  `--allow-dirty` — which is the flag for "discard my drift", a thing the user
  has not been shown any evidence of. E14 reached the opposite conclusion for
  `nd-save` on a superficially similar "I cannot tell" case, and the difference
  is exactly this: there, refusing preserved repo work that existed nowhere
  else and there was no repair path; here, refusing preserves nothing and
  blocks the repair.

  The warning is loud, names every file, says the switch will overwrite them,
  and says the classification cannot be made either way. Pinned by five cases
  under `an unreadable source …` in `tests/run.sh`.

  `nd-switch` also now reports any kind it does not recognise, rather than
  dropping the line, so a newer `nd-status` paired with an older `nd-switch`
  cannot lose a whole category in silence. That branch is not covered by a test:
  `nd-status` comes from `runtimeInputs`, which precedes the caller's `PATH`, so
  the suite cannot substitute a stub that emits an invented kind.

## E20 — `nd-save` and the zsh notice both drop the `unreadable` kind
- **Task:** `nd-status` robustness, hand-off
- **Raised:** E19 adds a fourth kind. Two consumers I do not own were written
  against three and neither has a default branch.

  `packages/nd-save.nix:154` builds its work list with
  `grep -E '^(drifted|new)'`, so an `unreadable` line is not a candidate and not
  a `missing` either. `nd-save` therefore says "nothing to save" for a file it
  cannot classify — quieter than the old behaviour of blaming the user's repo,
  and still silent about a file the next switch will overwrite. `nd-save`'s own
  blocker check has the same `cmp -s` conflation at `:264` for the repo-side
  comparison.

  `modules/nd-notice.zsh:22-27` counts `drifted`, `missing` and `new` in a
  `case` with no default, so an `unreadable` line increments nothing and the
  notice stays silent even though `nd-status` found something.
- **Options:** (a) fix them here, out of ownership; (b) raise it and leave both
  as they are.
- **Status:** unresolved — **for the owners of `packages/nd-save.nix` and
  `modules/nd-notice.zsh`**
- **Resolution:** (b). `packages/nd-save.nix` and `modules/` are outside this
  change's ownership and editing them would put two agents in the same files.
  What is needed:

  - `nd-save` should report `unreadable` the way it reports `missing` — name the
    files, say it cannot tell whether they drifted, and skip them — rather than
    letting them fall off the end into "nothing to save".
  - `nd-save`'s repo-side `cmp -s "$src" "$flake/$repo_rel"` should distinguish
    exit 1 from exit ≥2 as `nd-status` now does. Today an unreadable `$src`
    reads as "the repo differs", which is E14's fail-closed blocker firing for
    the wrong reason and naming the wrong file.
  - `nd_notice` should either count unrecognised kinds under a catch-all or say
    that `nd-status` reported something it does not understand. A silent `case`
    default is how a new kind disappears.

  Until then, `nd-switch` is the only consumer that says anything about an
  unreadable source, which is why its warning tells the user to copy the file
  aside by hand rather than pointing at `nd-save`.

## E21 — E11's `tests/glob.nix` case is still outstanding
- **Task:** E11 close-out, hand-off
- **Raised:** E11's resolution asked that, once `nd-status` passed `--` to grep,
  `{ g = "-foo/**"; s = "-foo/x"; want = true; }` be added to `matches` in
  `tests/glob.nix`. The `--` has landed and `tests/run.sh` now covers the
  shell side end to end, but `tests/glob*.{nix,sh}` are outside this change's
  ownership.
- **Options:** (a) add it anyway; (b) raise it for the owner.
- **Status:** unresolved — **for the owner of `tests/glob.nix`**
- **Resolution:** (b). The case is already correct against `builtins.match` —
  E9's table shows `-` is not escaped and does not need to be — so it should
  pass on the first run; it exists to stop the escape table growing a `-` later,
  which would break the ERE for both engines. Nothing else in the glob checks
  needs to change: `tests/glob-engines.sh` already passes `--`, which is now
  what `nd-status` does.
