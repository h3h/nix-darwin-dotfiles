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

## C5 — the end-to-end `check_status 0` after the second `nd-switch` is unreachable, as the brief warned it might be

**Status:** resolved

Task 6's brief (Caution 1) flagged that
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
tells the two apart, exactly as the brief predicted.

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
