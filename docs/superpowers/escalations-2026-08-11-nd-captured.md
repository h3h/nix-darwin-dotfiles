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
