# Design: multiple managed-file sources (`programs.nd.sources`)

Date: 2026-10-08
Status: approved
Checked against `62828a4`.

## Context

`programs.nd` has exactly one source of managed files: `sourceDir` in the store,
mirrored at `flakePath/repoSubdir` in a working tree. `nd-save` copies drift
back into that one tree and commits there, and `nd-switch` builds that one flake.

That stops working once a person's common dotfiles live in a different repo from
the flake that builds their machine — concretely, h3h's common config moving
into this repo as a shared home-manager module, consumed by both a personal
flake and a team flake (`omc/nix-darwin`), each of which still owns its own
machine-specific files. Each consumer needs to place files from two sources and
capture drift back into whichever repo owns each file.

This design covers only the nd tool change. Extracting the shared h3h module and
rewiring the two consumers are separate pieces of work that depend on it.

## Decisions taken during design

**Build from the local checkout, not the locked input.** A second source reaches
the consumer's flake as a flake input, locked to a revision. If `nd-switch` built
from that revision, the `captured` gate would become unsafe: `nd-save` writes a
capture into the source's checkout, the locked revision does not have it, and the
switch silently overwrites the live file with the older content. `captured`
passes the gate today only because the switch rebuilds from the repo that already
holds the capture; building each extra source from its checkout keeps that true.
The consumer's lock is allowed to lag the checkout, and `nd-switch` says so.

Rejected: always building the locked revision and blocking on a capture the lock
lacks (every shared tweak becomes commit, push, `nix flake update`, then switch);
building the locked revision without a block (silently loses captures).

Consequence worth naming: when the extra source is this repo, overriding the
input also builds nd's own code from the working tree. A half-finished nd change
in the checkout is live on the next switch.

**A destination belongs to exactly one source.** Two sources claiming the same
destination, or the same glob root, fail evaluation, naming both. A consumer
opts out of a shared entry by setting it to `null` and declaring its own.
Rejected: a priority order, which shadows files silently and makes `nd-save`'s
target depend on which source won.

**The most specific glob root wins.** A file is `new` when no manifest record
exists for its destination, whichever source placed it, so nested roots from
different sources already coexist for placed files. A file that appears later
under both — a new script in a team-only skill directory inside a shared
`.claude/skills` root — would be reported by both scans with two different repo
paths. A glob scan therefore skips any path that lies under a deeper glob root,
from any source.

## Configuration surface

```nix
programs.nd = {
  # Unchanged: the default source, which is the flake nd-switch builds.
  flakePath = "/Users/alice/.config/nix-darwin";
  sourceDir = ./files;
  repoSubdir = "modules/users/alice/files";
  files = { ... };   # attrsOf (nullOr str)
  globs = { ... };   # attrsOf (nullOr submodule)

  sources.<name> = {
    input      = "nix-darwin-dotfiles";                       # flake input name in the default flake
    checkout   = "/Users/alice/Sites/alice/nix-darwin-dotfiles"; # git working tree of that input
    sourceDir  = ./files;                                     # store path, set by the declaring module
    repoSubdir = "alice/files";                               # sourceDir relative to checkout
    files      = { ".posh.toml" = "posh.toml"; };             # attrsOf (nullOr str); null opts out
    globs      = { ".config/nvim" = { ... }; };               # attrsOf (nullOr submodule)
  };
};
```

A shared module declares `sources.<name>.{sourceDir,repoSubdir,files,globs}`.
The consumer sets `input` and `checkout`, which only it knows.

`files` and `globs` become `nullOr` at the top level too, so the opt-out is the
same everywhere. A `null` entry is dropped before records, assertions or
manifest lines are built.

New evaluation failures, each naming the option:

- a destination declared by two sources (both named);
- a glob root declared by two sources (both named);
- `sources.<name>.checkout` not an absolute path, or ending in `/`;
- `sources.<name>.input` empty;
- the existing relative-path and glob-source assertions, applied per source.

## Manifest

Unchanged layout. Field 3 — the repo path — is **absolute** for records from an
extra source (`<checkout>/<repoSubdir>/<rel>`, and `<checkout>/<repoSubdir>/<source>`
for a glob record's repo root) and stays relative to `ND_FLAKE` for the default
source. Readers branch on a leading `/`. The manifest is only ever read by the
tools of the generation that wrote it, so no cross-version case arises.

## Tools

### Wrapper

The module bakes the extra sources into all three wrappers as `ND_OVERRIDES`:
one `input<TAB>checkout` line per source, `--set-default` like every other
`ND_*` value.

### `nd-switch`

For each `ND_OVERRIDES` line whose checkout contains a `flake.nix` and is a git
work tree, pass `--override-input <input> git+file://<checkout>` to both
`nix build` and `darwin-rebuild switch`. A `git+file` override sees uncommitted
changes to tracked files and not untracked ones — the same visibility the
default flake already has, and the one `captured` relies on.

One line per source before building:

```
nd-switch: nix-darwin-dotfiles from /Users/alice/Sites/alice/nix-darwin-dotfiles (HEAD abc1234)
nd-switch:   lock is at def5678 — push it, then: nix flake update nix-darwin-dotfiles
```

The second line only when the checkout's HEAD differs from the locked revision
(read from the default flake's `flake.lock`). A checkout that is absent, or not a
git work tree with a `flake.nix`, falls back to the locked revision with a
one-line notice and no override.

`--override-input` does not write the consumer's `flake.lock`; the
implementation verifies this rather than assuming it.

The override takes effect from the generation after the one that first declares
a source, because the wrapper comes from the running generation. The first
switch with a new source builds from the lock.

### `nd-status`

- `kind_for` resolves each record's repo path (absolute, or under `ND_FLAKE`)
  and runs the tracked-file check with `git -C` in the directory holding it.
- `scan_glob` receives the full list of glob roots and skips any path under a
  deeper root than its own.

Output format is unchanged. Field 3 of a line from an extra source is absolute.

### `nd-save`

1. Group the files to capture by target repo (the git top level of each repo
   path).
2. Run every existing blocker check — staged content on a managed path, detached
   HEAD, never-placed-but-present, repo copy differing from what was placed, the
   credential scan — across **all** groups before copying anything. Any blocker
   aborts the whole run with every repo untouched.
3. Copy and commit once per repo, with the same message, using the existing
   index-handling and `commit --only` procedure, factored into a per-repo
   function.

`expectedBranch` / `--branch` apply to the default repo only. A detached HEAD is
refused in any repo. If one repo commits and a later one fails, `nd-save` names
each repo it committed in, with the commit, and exits non-zero; it does not
undo earlier commits. After committing in an extra source's repo it prints the
push-and-update reminder.

## Testing

`tests/run.sh` gains a second fixture repo and covers:

- drifted, captured, missing and new per source, with absolute repo paths;
- nested glob roots across sources: a new file under the deeper root is reported
  once, against the deeper root's repo;
- a two-repo `nd-save`, plus a blocker in one repo aborting both with neither
  touched;
- detached HEAD in the extra repo refused;
- the `--override-input` arguments `nd-switch` passes, the lagging-lock line, and
  the missing-checkout fallback, through the existing `nix` / `darwin-rebuild`
  stubs.

`tests/module.nix` / `tests/module.sh` cover the collision and null-opt-out
assertions, absolute repo paths in the expected manifest, and `ND_OVERRIDES` in
the wrappers.

README gains a "Multiple sources" section.
