# Escalations — the `captured` kind

Work log for [the captured-kind plan](plans/2026-08-11-nd-captured-kind.md),
implementing [its spec](specs/2026-08-11-nd-captured-kind-design.md).

One entry per deviation, ambiguity or surprise. An entry is opened the moment
the question arises and closed in the same document when it is answered, so the
reasoning survives the session that produced it. The existing
`escalations.md` is the model.

Statuses: **open**, **resolved**, **deferred to the maintainer**.

## Entries

## C1 — no existing test needed reclassification, contrary to the brief's expectation

**Status:** resolved

Task 1's brief warned that adding `ND_FLAKE` to `run_status`, plus routing both
`nd-status` emitters through `kind_for`, would very likely flip some existing
fixture's classification, since `run_switch` and `run_save` already export
`ND_FLAKE` and both call `nd-status` internally. The brief laid out three
outcomes for each such failure — the case was pinning the deadlock and its
expectation needed updating, the reclassification was incidental to what the
case tests, or the reclassification was a genuine defect in `kind_for` — and
asked for an escalation entry for whichever applied.

After Steps 1, 2, 4, 5 and 6 were all in place, the full suite was run against
the rebuilt `nd-status`, `nd-switch` and `nd-save` binaries: 223 checks, 0
failures, including every pre-existing `nd-switch` and `nd-save` case. None of
the three outcomes above applied to anything, because nothing flipped.

The reason, checked case by case rather than assumed: `kind_for` only runs on a
record that already fails the store comparison (a file record where `cmp`
against the store source returns 1) or a glob-discovered file with no manifest
record at all — the two branches that used to print `drifted` and `new`
unconditionally. Every existing fixture that reaches either branch does so via
the `drift()` helper, which always rewrites the live file to `setting = 2`
while the repo's committed copy of `files/config.toml` stays at `setting = 1`
(the store's content) unless a test explicitly overwrites it — and every test
that does explicitly overwrite the repo copy sets it to some third value
(`"my unplaced edit"`, `"staged only"`, `"staged by me"`, a directory, a
different app's content) that also does not equal the drifted live content.
`cmp` inside `kind_for` therefore always finds a difference and falls through
to the fallback kind before the `git ls-files` check is ever reached. The same
holds on the glob side: every existing `new`-file case either has no repo
counterpart at all or a repo counterpart with content that differs from what
was written to `$HOME` (e.g. `'{"plug":"mine"}'` vs `'{"plug":"abc"}'`). The one
place a capture's repo copy does end up byte-identical and tracked — the
end-to-end lazy-lock test at the bottom of `tests/run.sh` — reaches that state
by manifest edit, not through `drifted`/`new` classification, and the resulting
record has `cmp` against the *store* (which is now the repo copy itself)
succeed, so it never reaches `kind_for` at all; it simply stops appearing in
the output, which is exactly what that test already asserted (`check_not
"once placed it is no longer new"`, `check_not "and it has not drifted"`).

No fixture was touched and no expectation was loosened. This entry exists
because the brief predicted breakage that a full run did not reproduce, and
recording why closes the loop rather than leaving a silent gap between what
Step 7 asked for and what the diff shows.

## C2 — `--allow-dirty --build` keeps the `--allow-dirty` label, not `--build` — reversed

**Status:** resolved

Task 3's brief (Step 4) checks `build_only` before `allow_dirty`, so that
`--allow-dirty --build` would take the new `--build` label ("nothing is being
placed, so they are left alone") instead of the `--allow-dirty` label
("OVERWRITTEN" / "their contents will be discarded"). The task's own
instructions flagged this as something to watch, on the assumption that the
pre-existing `--allow-dirty` cases "do not pass `--build`."

Reading `tests/run.sh` before writing any code showed that assumption is
false: three pre-existing cases — "--allow-dirty names what it will discard"
and its neighbors around line 179, "the discard warning precedes the build"
around line 192, and "--allow-dirty still reports missing" around line 247 —
already call `run_switch "$d" --build --allow-dirty`, and assert the
`--allow-dirty` wording (`OVERWRITTEN`, `contents will be discarded`, `Run
'nd-save' first to keep them`) verbatim. Implementing Step 4 exactly as
written was verified empirically (build + `tests/run.sh`) to turn all three
red, because the label those cases depend on stopped being chosen.

The decision originally taken here was to swap the two branches so
`allow_dirty` is checked before `build_only`: `--allow-dirty` alone or
combined with `--build` would then keep producing the wording those three
cases pinned, and `build_only` would only get its own `--build` label when
`--allow-dirty` was not also given. That was read at the time as required by
this task's stronger, explicit constraint — "the existing `--allow-dirty` and
`--rollback` cases must keep their current wording and behaviour exactly" —
which appeared to rule out the brief's ordering as written.

This was escalated and has been overruled. The adjudicator ran the built
`nd-switch` against a reproduction of `new_fixture` with a tracing `sudo`
stub and confirmed empirically that `--build --allow-dirty` never switches
regardless of branch order: `nd-switch` runs under `errexit`, the fixture's
`flake.nix` is a bare `{}`, so `nix build` fails and the script exits before
`sudo darwin-rebuild` is ever reached — sudo was never invoked. `--build` in
those three test invocations is therefore belt-and-braces and does no work;
the tests pin `--allow-dirty`'s wording, not `--build`'s. The swapped code
printed a warning about an overwrite that cannot happen for this
invocation — the same wording-diverging-from-action defect this whole area of
the code exists to prevent, reintroduced by the fix meant to protect it.

Escalation C4 in this same log already applied the identical reasoning to a
different pre-existing test: `--build` there was incidental to what the case
tested (the plain drift gate), so C4 changed the incidental test to fit
correct code rather than bending the code to fit the incidental flag. C2's
three tests are in exactly that position, and the original resolution did the
reverse: it changed correct code to fit an incidental invocation.

The "existing `--allow-dirty` cases keep their current wording exactly"
constraint protects the assertions, not the specific invocation that reaches
them. Every one of those assertions is unchanged. What shipped instead:
`build_only` is checked before `allow_dirty` (matching the brief's original
order), the comment above that branch explains why — `--build` never
switches even when `--allow-dirty` rides along, so the OVERWRITTEN/discarded
wording would be false for that invocation, and a caller who wants the
discard warning gets it on a run that can actually discard, i.e. a switch
without `--build` — and the three pre-existing test invocations had `--build`
dropped, with the two drifted-fixture cases routed through `run_rollback`
instead of `run_switch` so a stubbed `sudo` stays on `PATH` as a backstop.
Their assertions are pinned character-for-character on a run that can
actually discard, instead of on one that never could. The swap had also cost
the suite the stronger combined-flag assertions (drifted file named, "nothing
is being placed", no `OVERWRITTEN`, no `contents will be discarded`, for both
flag orders); those are restored as part of this reversal.

## C3 — three new `--build` regression assertions cannot rely on real `nix build` succeeding

**Status:** resolved

Task 3's brief (Step 1) appends three test blocks. Two of them —
`--allow-dirty --build` and `--build --allow-dirty`, run through
`run_rollback` — assert `check_status ... 0 "$st"` and
`check "..." "build only, not switching" "$out"`, both of which are reachable
in the current code only after `nix build --no-link
"$flake#darwinConfigurations.$host.system"` returns successfully. A third
assertion, on the plain `--build` case, similarly asserts `check_status
"--build is not blocked by drift" 0 "$st"`.

`new_fixture` (the fixture every one of these cases uses) writes
`flake.nix` as the literal text `{}`, which Nix rejects as flake output with
`error: flake '...' lacks attribute 'outputs'` — confirmed directly with `nix
build --no-link` against a fixture built by hand, independent of this
sandbox or network access; it is a property of the fixture, not the
environment. Every existing `--build` assertion elsewhere in `tests/run.sh`
already works around this by asserting only that the literal string
`"building"` (the echo that runs immediately before the `nix build` call)
appears, and never checking exit status or anything printed after it — see
the comment on "a missing file does not block" a few lines above, which
states the same reasoning for a different case: "Reaching the build step is
the thing that actually discriminates: a block exits before it." Exit status
in particular is not just unreachable but actively misleading here: a real
`nix build` failure and a gate refusal both exit 1, so `check_status`
comparing to `0` cannot distinguish "the gate blocked" from "the gate did not
block, but the stub flake failed to build" — a fix to the drift gate can
never turn that assertion green.

The three assertions were changed to match the file's established pattern:
`check_status` was dropped from all three, `"build only, not switching"` was
replaced with `"building"`, and `check_not "... darwin-rebuild"` was kept
(that string only appears past the same unreachable point, so its absence is
still a real, if currently vacuous in this fixture, regression pin — the
same shape as the existing "an unreadable source is not reported as drift"
style assertions in this file). The message-content assertions the brief
specified — `.config/app/config.toml` named, "nothing is being placed"
present, no `OVERWRITTEN`, no `contents will be discarded` — were kept
verbatim, since those are the assertions that actually exercise the label
change Step 3 makes.

## C4 — the pre-existing gate test moved off `--build`

**Status:** resolved

Before Step 3/4 were applied, the very first drift case in `tests/run.sh`
("The gate. This is the behaviour the whole design rests on.") called
`run_switch "$d" --build` on a drifted fixture and asserted the plain-gate
refusal: `"changed since they were placed"`, `"nd-save"`, and
`check_status ... 1`. That is the exact input Task 3 changes the meaning of:
after Step 3/4, `--build` on a drifted fixture no longer refuses by design,
so this case necessarily flipped from pass to fail once the fix landed —
confirmed empirically, it was the sole remaining failure after fixing C2 and
C3.

The task's floor is "234 passed, 0 failed, no existing assertion may
regress," which on its face this appears to violate. But the assertions in
this block are not testing `--build`; the block's own comment says they are
testing "the gate," and `--build` was only the flag the case happened to
invoke it through. Leaving the case unchanged would mean the suite could
never reach 0 failures with the drift gate correctly fixed — the two
requirements are mutually exclusive for this one case, and the task's stated
purpose ("`--build` is refused by the drift gate although it places
nothing") is unambiguous about which one is the actual defect. The case was
changed to invoke `run_switch "$d"` with no flags, which still calls into the
same default (empty-label) branch of `report_status` and still refuses drift
exactly as before — the assertions and their wording were not touched, only
the flag that reaches them. This is arguably a small improvement in
precision as a side effect: the exit-1 check no longer coincides with a real
`nix build` failure (see C3) and is now driven purely by the gate's own
`return 1` / `exit 1`, reached before `nix build` is ever invoked.

The sibling case just above it (clean fixture, `run_switch "$d" --build`,
asserting only the absence of drift text) was left untouched: it carries no
drift, so neither label branch is ever reached, and it is unaffected by
either defect.

## C5 — the end-to-end `check_status 0` after the second `nd-switch` is unreachable

**Status:** resolved

Task 6's dispatch instructions — which carried two cautions the extracted
brief file does not contain — flagged that
`check_status "the switch is now allowed" 0 "$st"`, in the end-to-end block
appended to `tests/run.sh`, is very likely structurally unreachable, because
the fixture's `flake.nix` is the literal text `{}` and a real `nix build`
against it always fails under `errexit` — the same fact C3 already
established for a different case. It asked that this be verified empirically
rather than assumed, and if unreachable, that the assertion be replaced with
one that discriminates the fixed behaviour from the deadlocked one by
checking that the `building` line was reached, since a gate refusal exits
before that line ever prints.

Verified empirically: with the assertion in place exactly as the brief wrote
it, the built `nd-switch` was run against the case's fixture (drift, then
`nd-save -y` to capture it, then a second `run_switch` with no flags). The
second `nd-switch` correctly did not refuse — `report_status ""` returned 0,
because the file classifies as `captured` rather than `drifted` once the
repo copy matches and is tracked — reached `echo "nd-switch: building ..."`,
then ran `nix build --no-link "$flake#darwinConfigurations.$host.system"`
against the bare-`{}` fixture, which failed and, under the script's
`set -euo pipefail`, made the whole invocation exit 1. `check_status
"the switch is now allowed" 0 "$st"` failed with "wanted exit 0, got 1" —
the sole failure in an otherwise-279-passing run. This exit 1 is
indistinguishable from the gate's own `exit 1` on the deadlocked (pre-fix)
code path: both are 1, so no value of `$st` this fixture can ever produce
tells the two apart, exactly as the dispatch predicted.

The assertion was replaced with the file's established convention (already
used a few cases above, for "a missing file does not block", and by C3 for
the `--build`/`--allow-dirty` regression assertions): drop `check_status`
entirely, keep capturing `$out` from `run_switch "$d"`, and rely on
`check "and reaches the build" "building" "$out"` — already present
immediately below in the brief's own text — to discriminate the two
behaviours. Reaching the `building` echo requires `report_status ""` to have
returned 0, which requires the file to have classified as `captured` rather
than `drifted`; the deadlocked code path never gets there, because it
returns 1 and `exit 1`s before that echo runs. A comment was added at the
call site pointing at this entry and at C3, so a future reader does not
re-diagnose the same unreachability. No other line in the block changed:
`st=$?` was dropped along with the assertion that consumed it, since nothing
else reads it.

Re-run after the change: 279 passed, 0 failed — the full suite, including
this block and the floor of 269 pre-existing checks. `nix flake check` also
passed.

## C6 — the analogous pathspec-not-a-path defect in `nd-save`, and the commit leak it enables, is left alone

**Status:** resolved

The final whole-branch review (2026-08-11) found that `nd-status`'s
`kind_for` passed `$repo_rel` to `git ls-files --error-unmatch -- "$repo_rel"`
as a pathspec rather than a literal path: a repo path containing `[`, `*` or
`?` is read as a glob, and can match a *different* tracked file at a
different location. A tracked decoy at `files/c1.toml` made `git ls-files --
'files/c[1].toml'` exit 0 and report an untracked repo copy of that name as
`captured`, which is exactly the miscall the design's tracked-only rule
exists to rule out: an untracked file is invisible to a flake build, so the
user would lose it on the next switch. This was fixed in `nd-status.nix` with
`git --literal-pathspecs`, and pinned with a new `tests/run.sh` case (a
tracked decoy plus an untracked repo copy named with glob metacharacters,
asserting `drifted`, not `captured`).

A re-review found the same defect at nine call sites in `packages/nd-save.nix`,
and, verified against real git rather than assumed, a worse consequence than
the misclassification above: given a managed repo path `files/c[1].toml` and
an unrelated tracked file `files/c1.toml` that the user has modified in their
own working tree, `git add -- "${paths[@]}"` (:544) stages **both** — git
matches the literal path exactly and the decoy by glob — and
`git commit --only -m "$msg" -- "${paths[@]}"` (:551) commits both. That is
precisely the leak the comment written directly above those two lines exists
to prevent: "The repo may be shared, so that is a data leak, not a private
mistake." The defect that comment is warning about, and the defect that
defeats the scoping it is describing, are the same defect.

Fixing only the two call sites this entry originally named — the
staged-content guard and the untracked-path lookup, below — would leave that
commit leak fully in place: neither of those two lines is the `add` or the
`commit --only`. All nine sites carry the same defect and none is safe to
leave out of a fix, verified line-by-line against the current file:

- `git -C "$flake" diff --cached --quiet -- "$repo_rel"` (:281) — the
  staged-content guard that runs ahead of the unplaced-edit blocker; a decoy
  match here would compare the wrong path's index entry against HEAD.
- `git -C "$flake" ls-files --error-unmatch -- "$p"` (:414) — the loop that
  decides which newly captured paths were untracked before
  `git add --intent-to-add`, so `unstage_captures`/`on_exit` knows what to
  reset on a non-commit exit; a decoy match here misreports the real path's
  tracked status.
- `git -C "$flake" reset -q -- "''${untracked[@]}"` (:421), in
  `unstage_captures` — the abort path for the two lines above.
- `git -C "$flake" add --intent-to-add -- "''${paths[@]}"` (:491) — could stage
  an intent-to-add entry for the decoy as a side effect of capturing the real
  path.
- `git -C "$flake" status --porcelain -- "''${paths[@]}"` (:493) — the
  "nothing to commit" check; a decoy match could make it see changes that are
  not the capture's, or hide the capture's own.
- `git -C "$flake" --no-pager diff HEAD -- "''${paths[@]}"` (:506) and
  `git -C "$flake" --no-pager diff -- "''${paths[@]}"` (:508) — the preview
  shown before the confirmation prompt; a decoy match could show the user a
  diff of a file they never asked nd-save to touch, or hide the real one.
- `git -C "$flake" add -- "''${paths[@]}"` (:544) — the first commit-leak site
  above.
- `git -C "$flake" commit --only -m "$msg" -- "''${paths[@]}"` (:551) — the
  second, and the one that makes the leak permanent: once committed, the
  decoy's content is in history under a subject about someone else's config.

All nine predate this branch; none was touched by it.

Fixing it here was considered and rejected. This branch's whole reviewable
surface is the `captured` kind and two small `nd-switch` defects; widening a
targeted fix into untouched, unrelated code the moment the same bug shape is
noticed elsewhere is how a reviewable branch stops being reviewable, and how a
reviewer's approval of "the captured kind" quietly becomes approval of
changes to `nd-save`'s capture path that were never in the design doc and
never asked for. The maintainer can decide whether `nd-save` gets the same
`--literal-pathspecs` treatment as its own, separately reviewed change — but
should treat it as one change covering all nine sites, not just the two a
first pass happens to notice, since the two that actually write history
(:544, :551) are not the two most readers would find first.

**Resolution (2026-08-12).** The maintainer asked for this fix as its own,
separately reviewed change, exactly the path this entry left open. Before
writing anything, the leak was reproduced against the built (pre-fix)
`nd-save`: a fixture with the managed path `files/c[1].toml`, a tracked decoy
`files/c1.toml` modified in the working tree, and a drift on the managed
file. Running `nd-save -y` committed both files into HEAD, and the
pre-commit preview showed the decoy's diff alongside the real one — the exact
behaviour this entry described, confirmed rather than assumed.

What shipped is not nine independent `--literal-pathspecs` flags. Every `git
-C "$flake"` call in the file — the nine that take a pathspec, and the six
that do not (`rev-parse --git-dir`, `branch --show-current`, `rev-parse
--git-path index`, both `rev-parse --verify --quiet HEAD` calls, and
`rev-parse --verify --quiet HEAD > /dev/null`) — now goes through one
function:

```
nd_git() {
  git --literal-pathspecs -C "$flake" "$@"
}
```

The reasoning, recorded in a comment above the function: nine separate call
sites each had to remember the flag, and nine separate sites each forgot it.
Patching only the nine named above — even patching all nine by hand, one at a
time — leaves the tenth call, the one added to this file next year, with
nothing to remind it. Routing every invocation through `nd_git`, including
the six that carry no pathspec at all, turns "remember the flag" into
"there is only one way to call git here" — an exception in that list would
have been a tenth place to forget, so there isn't one. This is the same
uniformity argument `nd-status.nix`'s `kind_for` comment makes for its own
single call site, generalised to a file with fifteen.

One mechanical wrinkle: `git -C "$flake" --no-pager diff HEAD -- ...` needed
`--no-pager` to stay a main-command option ahead of the `diff` subcommand
inside `nd_git`'s argument list (`nd_git --no-pager diff HEAD -- ...`
expands to `git --literal-pathspecs -C "$flake" --no-pager diff HEAD --
...`, which is valid, since `--literal-pathspecs`, `-C` and `--no-pager` are
all main-command options and none of them follow the subcommand). Every
`$( )` capture, `if !` condition and `|| true`/`> /dev/null 2>&1` exit-status
consumer keeps its original semantics, because `nd_git` is a plain
pass-through function, not a subshell or a status-swallowing wrapper.

**Tests that pin it**, added to the `nd-save` section of `tests/run.sh`:

- "the glob-metacharacter path is still captured and committed" and its
  neighbours — the commit-leak fixture itself: a managed `files/c[1].toml`
  plus a tracked, working-tree-modified `files/c1.toml`, drifted and saved.
  Asserts the decoy is in neither the commit nor the index, that its working
  tree is untouched, and that the managed file is still captured and
  committed correctly — the fix must not cost the real path its coverage.
- "a staged decoy does not block the managed path" and its neighbours — the
  staged-content guard at old :281, with the decoy's *index* entry (not its
  working tree) differing from HEAD. Before the fix this guard consulted the
  decoy's index entry while reporting on the managed path's name; the case
  asserts the guard now reaches the correct decision — no block — for the
  real path, and that the decoy's own staged edit is neither swept into the
  commit nor disturbed.

The untracked-path lookup (old :414, feeding `unstage_captures`) was
considered for a third case and left without one, on the record rather than
by omission: a decoy has to be tracked in the index for `ls-files` to report
a false match at all, and a repo with anything in the index already has an
on-disk `.git/index` — which is exactly the condition under which nd-save's
own index-snapshot restore (added for a different reason: it also recovers
staging on a *tracked* managed path, which a path-scoped reset cannot)
already restores the whole index verbatim on decline, independent of what the
lookup's `untracked` array says. Verified directly: the pre-fix binary,
run against a fixture with a tracked decoy and a declined capture, left the
index in exactly the state the fixed binary does, because the snapshot path
fully masks the array path whenever a decoy exists to trigger it. The call is
still routed through `nd_git` — it is still wrong on its own terms — but
nothing observable in this suite currently distinguishes the two versions
through it.

Full verification: `nix build --no-link --print-out-paths .#nd-switch
.#nd-save .#nd-status`, then `tests/run.sh` against the three resulting
binaries, reported

```
passed 313, failed 0
```

— the 302 this branch closed with, plus the eleven new checks above. `nix
flake check` passed: `tests`, `module`, `glob` and `glob-engines` all built
clean.

## C7 — documentation corrections found during the final review, gathered into one entry

**Status:** resolved

Three inaccuracies in comments and documentation, none of them behavioural,
were found during the final whole-branch review and corrected together:

- `tests/run.sh`'s comment on the "directory in the repo's place" nd-status
  case said `cmp` exits 2 for a directory, "which is 'I could not read one of
  them', not 'they match'". `kind_for`'s own `[ ! -f "$flake/$repo_rel" ]`
  guard rejects a directory before `cmp` is ever invoked, so the case is
  pinning the guard, not `cmp`'s exit status. The comment was rewritten to say
  that, with a clause noting the `cmp`-exits-2 reasoning is genuine and is
  exactly the reasoning behind the unplaced-edit blocker in
  `packages/nd-save.nix` — which is presumably where the sentence was copied
  from — naming the file rather than a line distance, since the blocker's own
  tests are in this same file, a few hundred lines **up** from this comment,
  not down, so a future reader does not conclude one of the two comments is
  wrong or go looking in the wrong direction. (A re-review after this entry
  was first written caught that this bullet, and the comment it describes,
  both originally said "down" — corrected in both places, along with the
  test comment, at the same time.)

- `README.md`'s "Gate" bullet and `nd-switch --help` both described
  `--allow-dirty` and `--rollback` as the only ways to bypass the drift gate.
  This branch made `--build` a third: `report_status` is now called for it and
  its return value ignored. Both were updated to name `--build` and explain
  why it differs from the other two — it places nothing, so it has nothing to
  discard, and it reports what it found rather than warning about an
  overwrite that cannot happen.

- `modules/home-manager.nix`'s `enableZshIntegration` description said the
  notice counts "drifted, missing and newly appeared files". The notice has
  counted five kinds plus an `unrecognised` catch-all since `unreadable` was
  added, and `captured` made it six kinds plus the catch-all; the description
  was updated to name them. `unreadable` was already missing from this
  description before this branch — that omission predates the `captured`
  work and is folded into this same correction rather than opened as its own
  entry, since it is the same class of drift between the option's prose and
  what the notice actually does.

No behaviour changed for any of the three; all are comment or documentation
text.

## C8 — the `module` flake check did not already have `pkgs.git`

**Status:** resolved

The final-review brief for adding a `captured` case to `tests/module.sh`'s
round trip stated `pkgs.git` was already in the check's `nativeBuildInputs`.
Reading `flake.nix` before writing the case showed that is true of the
`tests` check (`checks.<system>.tests`, which runs `tests/run.sh`) but not of
the `module` check (`checks.<system>.module`, which runs `tests/module.sh`
and is what the brief's own instructions name): its `pkgs.runCommand
"nd-module-tests" { } ''...''` passed an empty attrset, with no
`nativeBuildInputs` at all.

The new case needs a real repository, so `git` was added to that
derivation's `nativeBuildInputs` in `flake.nix` as part of the same change.
This is the minimum needed to make the brief's own request buildable — the
case cannot exist without it — rather than a widening of scope: nothing else
about the `module` check changed. Verified with `nix flake check`, which
rebuilt `nd-module-tests` and passed, including the new
"captured (round trip)" case.

## C9 — a re-review found the captured-glob "no commit was made" guard cannot fail, and its comment named the wrong regression

**Status:** resolved

A re-review of `tests/run.sh`'s captured-glob `nd-save` case (the one
asserting `check "no commit was made" "captured" ...`, added in the same wave
as this branch's other `nd-save` captured coverage) found the assertion
structurally unable to fail, and the comment above it wrong about what it
catches.

The fixture commits a repo copy that is already byte-identical to what
`nd-save` would copy. So on either regression the comment named — folding
`captured` back into `candidates`, or dropping `captured` from `nd-status`
altogether — `git status --porcelain -- "${paths[@]}"` still reports empty
before `git commit` is ever reached, or the run exits even earlier still (see
below), so HEAD does not move on either side of the change. No value this
fixture can produce distinguishes "regressed" from "not regressed" for this
one assertion — the same shape C5 and C3 already found elsewhere in this file
for a `nix build` that cannot succeed against this fixture's `flake.nix`.

The comment's own claim was checked and found wrong, not just unverified. It
said "no commit was made" was what actually distinguished a fold-in
regression from correct behaviour, on the theory that the file would be
copied (a no-op) and committed underneath an otherwise-unchanged report. That
is not what the code does. This is a glob record — field 1 is the placeholder
`-` (E7), so it has no file record — and folding `captured` into `candidates`
sends it to the blocker loop's `*)` arm, whose `src` lookup is keyed on a file
record (`$4 == ""`). The lookup comes back empty, "cannot tell what was
placed here" fires, and the run exits 1 before any copy or commit — a failure
the pre-existing `check_status "a captured glob file is not an error" 0`
already catches. Dropping `captured` from `nd-status` entirely, the other
regression the comment claimed to guard, is caught the same pre-existing way:
the file reads as plain `new` with an existing repo copy, "already in the
repo, never placed" fires, and both `check_status` and the case's
`check_not` go red. Neither regression ever reaches a commit for this
fixture, so "no commit was made" was never the discriminator, on either side
of the fix.

**Options:** (a) drop the assertion, since it cannot fail and the comment
claiming it could was simply wrong; (b) keep it and rewrite the comment to say
truthfully what does and does not depend on it.

**Resolution:** (b). The assertion is not harmful — it is cheap, and it would
catch an unrelated mistake this case does not currently name: a future
rewrite of the commit step that runs `git commit` regardless of what
`git status --porcelain` reported. That is worth one line of insurance even
though it is not the insurance the original comment advertised. What was not
acceptable was leaving the false claim in place: a comment asserting a test
catches a regression it structurally cannot catch is worse than no comment,
because the next reader trusts it instead of checking. The comment was
rewritten to name the two regressions this case actually catches (both via
the pre-existing `check_status`/`check_not` pair, not the new line), state
plainly that "no commit was made" cannot distinguish either, and say why the
line is kept anyway.

---

## Closing state

9 of 9 entries are resolved. Nothing is left open for the maintainer.

C6 was the one exception, and it closed the way its own text anticipated: the
maintainer asked for the fix as a separate, dedicated change, and it landed as
one. `packages/nd-save.nix` now routes every `git -C "$flake"` call —
including the six that take no pathspec — through a single `nd_git()` helper
defined in the file (`git --literal-pathspecs -C "$flake" "$@"`), rather than
nine independent `--literal-pathspecs` flags: the point was to make "call git
with a pathspec, unguarded" structurally impossible in this file, not merely
absent from the nine sites a review happened to find. The defect was
reproduced against the pre-fix binary before any code changed — a managed
path `files/c[1].toml` alongside a modified, tracked decoy `files/c1.toml`
was committed together by `nd-save -y`, with the decoy's diff also shown in
the pre-commit preview — and re-checked afterward to confirm the decoy no
longer appears in the commit, the index, or the preview, while the managed
path is still captured and committed correctly. See C6's own entry above for
the full account, including the one call site (the untracked-path lookup
feeding `unstage_captures`) whose fix could not be pinned with an observable
test, and why.

**Final verification**, run after C6 landed on top of the other five fixes
and this closing section: the suite (built via `nix build --no-link
--print-out-paths .#nd-switch .#nd-save .#nd-status`, then `bash
tests/run.sh` against the three resulting binaries) reported

```
passed 313, failed 0
```

— the 302 this branch closed with before C6, plus eleven new checks: two
`nd-save` fixtures pinning the commit leak and the staged-content guard
against a glob-metacharacter managed path and a tracked decoy. `nix flake
check` passed: `tests`, `module`, `glob` and `glob-engines` all built clean.
