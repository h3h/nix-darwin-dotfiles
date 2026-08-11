# Design: the `captured` kind, and two smaller `nd-switch` defects

Date: 2026-08-11
Status: approved; not yet implemented
Target release: v0.2.1

Fixes [issue #1](https://github.com/h3h/nix-darwin-dotfiles/issues/1). The issue
was filed against `v0.1.0`; every claim in it was re-checked against `44f8761`
before this spec was written, and one of them has changed shape since. See
"State at `44f8761`" below.

## Context

Three versions of a managed file exist at any moment: the store source the
current generation placed, the live file under `$HOME`, and the copy in the
flake repo. `nd-status` classifies each managed path by comparing the first two.
A difference is `drifted`, and `nd-switch` refuses to switch while anything is
drifted, because a switch would place over it.

That comparison is deliberate and its reasoning is sound. Comparing the live
file against the repo instead cannot tell "the application rewrote this" from "I
edited the repo and want to place it", and would refuse exactly the switch the
user meant to run.

What the two-way comparison misses is that there are three states, not two:

| live vs placed | live vs repo | meaning | correct action |
| --- | --- | --- | --- |
| same | same | nothing happened | switch |
| differs | differs | the application rewrote it, not yet captured | refuse |
| differs | **same** | the application rewrote it, `nd-save` already captured it | **switch** |

The third row is currently classified `drifted` and refused. The refusal is
self-perpetuating: only an activation rewrites the manifest, and `nd-switch` is
the thing declining to activate. `nd-save` cannot break the cycle either,
because the state it would need to change is the manifest, which activation
owns.

Switching in the third row is lossless by construction. The new generation
builds that file *from* the repo copy, which is byte-identical to what is live,
so the overwrite has nothing to discard.

## State at `44f8761`

The issue describes `nd-save` becoming a silent no-op after it captures
(`git status --porcelain` on a clean tree). That is `v0.1.0` behaviour. Since
then `nd-status` was extracted to own classification, and `nd-save` gained the
unplaced-edit guard from E14. The deadlock survived both changes and now
announces itself:

```
$ nd-switch
nd-switch: these files changed since they were placed:
  .config/app/config.toml
nd-switch: switching would overwrite them.
nd-switch: run 'nd-save' to copy them back and commit, or --allow-dirty to discard

$ nd-save
nd-save: the repo carries edits that were never placed; nothing copied:
  files/config.toml (repo copy differs from what was placed)
nd-save: switch first to place them, or re-run with --force to overwrite.
```

Each command names the other. Both refusals are correct on their own terms, and
neither is reachable from the other. This is worth recording because it changes
where the fix lands: the issue's suggested patch rewrites a manifest loop in
`nd-switch` that no longer exists there, and would also leave `nd-save`'s half of
the deadlock in place.

`--allow-dirty` clears it, and is safe in exactly this state, for the reason the
third row is lossless. It is not safe in the second row. That one flag carrying
two very different risks is the other cost of not distinguishing the rows.

## Decisions taken during design

**A new kind in `nd-status`, not a second comparison in `nd-switch`.**
`nd-status` exists because the same scan had been written four times — in
`nd-switch`, twice in `nd-save`, and again in the zsh notice — and a new category
meant editing all four consistently. Adding a repo comparison to `nd-switch`
would re-fork that, and would only fix half the deadlock: `nd-save`'s E14 guard
refuses on the same state, from its own comparison, and would go on refusing.
Reclassifying at the source fixes both callers at once, because the file simply
stops being a `drifted` candidate.

**The reference is the repo working tree, and the path must be tracked.** This
is what `nix build` will actually consume, verified rather than assumed:

```
$ nix eval /path/to/dirty/repo#x
warning: Git tree '/path/to/dirty/repo' is dirty
"WORKTREE\n"
```

A tracked file's uncommitted modification is what gets built. An **untracked**
file is invisible to Nix entirely — it fails evaluation with "To make it visible
to Nix, run: git add". So a repo copy that matches live byte-for-byte but is
untracked would not survive the switch, and calling it captured would be a lie
that costs the user their file. Both conditions are required.

Comparing against committed `HEAD` instead was rejected: it refuses the state
`nd-save` leaves behind when the user declines its commit prompt — files copied
into the working tree, index restored, nothing committed — which is a legitimate
way to reach the third row and one the user reached on purpose.

**Everything undecidable is `drifted`.** A missing repo, an unreadable repo copy,
a `cmp` that exits 2, a `git` that is absent from `PATH` or returns non-zero for
any reason: all fall through to `drifted`. This is E14's rule applied to a new
question. "I cannot tell whether this content is safe to overwrite" is not a
reason to overwrite it.

**`nd-status` takes `git` from the caller's `PATH`, not `runtimeInputs`.** Same
reason `nd-save` does: the closure does not carry a second `git`, and the flake
check supplies one. `nd-status` also gains `ND_FLAKE`, which it has not needed
until now. That is a real widening of its inputs — it has been answerable from
the manifest and `$HOME` alone — but the manifest's third field is a
repo-relative path and has always been meaningless without a repo root. The
field was already there; only the root is new.

**`--build` reports and never blocks.** It places nothing, so the gate has
nothing to protect, and blocking it removes the one non-destructive way to
inspect the situation while stuck. It keeps the report, because seeing what
`nd-status` thinks is the reason to reach for it. It does **not** reuse the
`--allow-dirty` wording: "will be OVERWRITTEN" and "their contents will be
discarded" are false for a command that does not switch, and a false warning
teaches the user to skim the true one.

## The `captured` kind

`nd-status` gains a fifth kind. Its output format, exit status and `sort -u`
pass are unchanged.

```
captured    the live file differs from the store source that placed it, but the
            repo already holds that exact content and Git can see it, so the
            next switch re-places it and discards nothing
```

A path is `captured` when **all** of these hold, and `drifted` (or `new`)
otherwise:

1. `repo_rel` is non-empty and `$flake/$repo_rel` exists;
2. `cmp -s "$flake/$repo_rel" "$HOME/$dest"` exits `0`;
3. `git -C "$flake" ls-files --error-unmatch -- "$repo_rel"` exits `0`.

`$flake` is `${ND_FLAKE:-$HOME/.config/nix-darwin}`, matching every other tool.

Under `errexit`, each of `cmp` and `git ls-files` needs its status captured
explicitly rather than tested inline in a way that swallows it — the failure
mode E11 documents, where a non-zero exit is absorbed by an `if` condition and a
whole category goes quiet.

### It applies to both record kinds

**File records.** The check runs in `scan()`, on the branch that currently emits
`drifted` after `cmp` returns 1.

**Glob records.** The check also runs in `scan_glob()`, on the line that
currently emits `new`. A file the application invented has no store source, so
"did it drift" is meaningless for it — but "is this exact content already in the
repo, where the next switch will place it from" is the same question with the
same answer, and it has the same wrong outcome today.

The glob case is not a deadlock: `nd-switch` never gated on `new`, so a switch
clears it. It is a false sentence. `nd-save` captures a `new` file, commits it,
and then on the next run refuses with

```
  files/nv/lazy-lock.json (already in the repo, never placed)
```

about a file `nd-save` itself put there one run earlier. Reclassifying makes that
blocker unreachable for content `nd-save` captured, and it keeps firing for what
it was written for: a repo file at that path whose content is *different* and was
never placed.

### Ordering

`captured` sorts before `drifted` under `sort -u`, which changes the order of
`nd-status` output but not its content. Nothing parses it positionally; every
consumer greps anchored to the kind and its tab.

## Changes per program

### `nd-status`

Add `flake`, add the three-condition check to `scan()` and `scan_glob()`, add
`captured` to the `--help` kind list.

### `nd-switch`

- Add `captured` to the known-kinds pattern in the `unknown` catch-all. Without
  this the new kind is reported as a kind `nd-switch` does not know, which reads
  as version skew between two programs that ship together.
- Report it, non-blocking, in `report_status`:

  ```
  nd-switch: these changed since they were placed, and the repo already holds the change:
    .config/app/config.toml
  nd-switch: switching re-places them from the repo; nothing is lost.
  ```

- The `drifted` gate is unchanged. Genuine uncaptured drift still refuses, with
  the same words and the same exit status. This is the property the fix must not
  cost, and the tests below pin it.

### `nd-save`

- Add `captured` to the known-kinds pattern in its `unknown` catch-all.
- `candidates` stays `drifted|new`, so a captured path is not copied and the E14
  blocker never runs against it. No change is needed to the blocker itself.
- Report and redirect:

  ```
  nd-save: these are already in the repo; there is nothing to copy:
    .config/app/config.toml
  nd-save: run 'nd-switch' to place them.
  ```

- The "nothing to save, every placed file still matches" message must not be the
  only thing printed when captured paths exist — that sentence is false, and it
  is the sentence that made the `v0.1.0` deadlock unreadable. The existing
  `unreadable`/`unknown` condition on that branch gains `captured`.

### `modules/nd-notice.zsh`

- A `(captured$'\t'*)` arm and an `N captured` part. Without the arm the default
  arm counts it as `unrecognised`, which is the right failure but the wrong word
  for a kind that shipped in the same generation.
- The advice line is unconditionally "run `nd-save` to audit and commit". For a
  captured-only state the action is `nd-switch`, and `nd-save` will decline. The
  advice says `nd-switch` instead when `captured` is non-zero and every kind
  `nd-save` can act on — `drifted` and `new` — is zero. `missing` does not change
  it either way: a switch is what restores a missing file too. `unreadable` and
  `unrecognised` do keep the `nd-save` advice, because `nd-save` is where both are
  explained at length.

### `README.md`

The detection section lists the kinds. Add `captured`, and add the third row of
the table in "Context" above to the explanation of why the gate compares against
the store rather than the repo — that passage currently states the two-way
reasoning as complete.

## The two smaller defects

### `--build` is blocked by the gate

`report_status` runs before the `build_only` exit, so `nd-switch --build` refuses
while anything is drifted, though it places nothing. Fix: call `report_status`
with a `--build` label, and ignore its return.

The labelled branch currently prints one pair of sentences, written for
`--allow-dirty` and `--rollback`, which do overwrite. `--build` needs its own:

```
nd-switch: --build: these files changed since they were placed:
  .config/app/config.toml
nd-switch: nothing is being placed, so they are left alone.
```

`missing`, `new`, `unreadable` and `unknown` are already unlabelled and need no
change.

### The stale `--allow-dirty --build` comment

The comment above the argument loop says positional checks let
`--allow-dirty --build` perform a switch, because `--build` was never consumed.
This does not reproduce at `44f8761`: both orders set `build_only`, and both exit
before `sudo`. The comment is deleted. The sentence before it, explaining that
the loop exists so flags work in any order, stays.

The behaviour is pinned by a test rather than left to the comment, so a future
refactor of the loop cannot quietly reintroduce it.

## Tests

`tests/run.sh`. `run_status` currently passes only `HOME`; it gains `ND_FLAKE`,
without which every new case reads the default flake path and everything falls
through to `drifted`.

Classification, against `new_fixture`:

- live drifted and repo copy matching and tracked is `captured`
- live drifted and repo copy matching but **untracked** is `drifted`
- live drifted and repo copy differing is `drifted`
- live drifted and repo copy absent is `drifted`
- live drifted with `ND_FLAKE` pointing at a non-repository is `drifted`
- a clean file is still classified as nothing at all

Classification, against `new_glob_fixture`:

- an invented file whose repo copy matches and is tracked is `captured`
- an invented file with no repo copy is still `new`
- an invented file whose repo copy matches but is untracked is `new`

`nd-switch`:

- `captured` does not block, and the file is named
- `captured` names the store-vs-repo situation, not "would overwrite"
- genuine drift still blocks, still names the file, still points at `nd-save`
- a mixed run — one captured, one drifted — still blocks on the drifted one
- `--build` with drift does not block and still reaches the build step
- `--build` with drift names the drifted file
- `--build` says nothing about overwriting
- `--allow-dirty --build` builds only and never reaches `darwin-rebuild`

`nd-save`:

- a captured file is not copied and not committed
- the output points at `nd-switch`
- the output does not say every placed file still matches
- a captured glob file is not refused with "already in the repo, never placed"
- a repo copy that differs and was never placed is still refused, with that
  wording

End to end, the loop the issue is about, in one case:

- drift a file, `nd-save -y`, then `nd-switch` succeeds

`modules/nd-notice.zsh`, via the existing notice tests:

- a captured file is counted as captured, not unrecognised
- a captured-only state advises `nd-switch`
- a state with both captured and drifted still advises `nd-save`

## What this does not change

**`nd-status` output stays machine-readable.** Considered during this design and
deferred, so that it is not re-proposed as if new. The format is `<kind>` TAB
`<dest>` TAB `<repo path>`, and a clean system prints nothing — which reads as a
broken command until you know it. A prose mode grouping findings by kind with a
line of advice each, with the current format moved behind `--porcelain` for the
three callers, is the obvious improvement, and `captured` makes the case
slightly stronger by adding a sixth word to learn. It is deferred because the
decision is better made after using the command than from a mockup, and because
it widens a three-program change to four. Nothing here forecloses it: the kinds
are the contract, not the layout.

`--allow-dirty` keeps its meaning and its wording. Splitting the third row out
removes the case where it was the only way forward, which is most of what made
it ambiguous; whether it should further distinguish its two remaining risks is
not part of this change.

E17 — whether `--rollback` should honour the gate — is untouched and stays open.
A rollback will report `captured` the same way a switch does.

The manifest format is unchanged. No new state is written anywhere. The whole
fix reads existing fields.
