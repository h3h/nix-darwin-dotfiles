# Design: glob-tracked files, and the v0.1.0 defect fixes

Date: 2026-08-09
Status: approved, not yet implemented
Target release: v0.2.0

Covers every defect in `nix-darwin-dotfiles-issues.md` except 7, plus a
replacement for 7 that the issues document did not propose.

## Context

`programs.nd` copies declared files from the store into `$HOME` at activation
and records what it placed in a manifest. A file has drifted when its content
differs from the store source recorded for it. `nd-switch` refuses to switch
over drift; `nd-save` copies drift back into the flake repo and commits it.

Two problems motivate this change.

The first is that `nd-save`'s git operations are repo-wide where they should be
manifest-scoped, and it overwrites the repo copy of a managed file without
checking whether that copy carries an edit the user has not yet placed. Both can
destroy work.

The second is that only individually declared files are tracked. An application
that creates a file of its own — lazy.nvim rewriting `lazy-lock.json` on every
plugin update — produces something the system cannot see. Defect 7 in the issues
document proposed managed directories. That was rejected during design: a
directory sweeps up caches, sockets and lock files, and the exclusion list
needed to make it safe is a worse interface than saying what you want directly.
Globs say what you want directly.

## Decisions taken during design

Recorded because each closed off an alternative that will look attractive again
later.

**Globs, not directories.** A managed directory needs an ignore list to be
usable, and an ignore list is a denylist maintained against an application you
do not control. A glob is an allowlist. Nothing enters the repo that a pattern
did not name.

**Patterns are required, with no default.** A default of `[ "**" ]` would be
whole-directory tracking wearing a glob's clothes.

**A new file inside a glob root does not block `nd-switch`.** Switching cannot
overwrite a file the store has no source for, so the gate has nothing to
protect. It is reported and the switch proceeds. `nd-save` then copies it into
the repo, after which the next evaluation places it like any other managed file
and it becomes ordinary drift-tracked content. The loop closes on its own.

**The credential scan keeps its pattern list.** Entropy scoring produces false
positives on hashes, UUIDs, base64 blobs and colour tables, which is most of
what these files contain. A scanner that cries wolf gets disabled and is then
worse than none, because it is trusted and silent. The decision is recorded in
the source and pinned by negative tests, so a future entropy check cannot land
without proving it does not break them.

**File modes stay 0644 (defect 8 closed as wontfix).** The position that defect
5's scan already enforces is that no credential belongs in a managed file. If
that holds, 0644 is correct. Git records only the executable bit, so a per-file
mode could not survive the repo round-trip in any case. A source comment will
say so.

## Manifest v2

The format gains a record kind as a fourth field. Three-field lines keep their
current meaning, so a new tool reading a manifest written by an older generation
works without a migration.

```
<store src>	<dest>	<repo_rel>                     # placed file (3 fields)
-	<dest root>	<repo root>	glob	<ERE>         # glob root (5 fields)
```

Field 1 of a glob record is a literal `-`. Nothing reads it: `nd-status` scans a
glob root with the destination root, the repo root and the ERE, and every file a
pattern matches already carries its own store source in its own file record.
Interpolating the source root there would copy the whole subtree into the store
a second time, on top of the per-file copies — and would not even be accurate,
since the subtree contains files no pattern matched. The column is kept rather
than dropped so `read -r src dest repo_rel kind pattern` stays a single parse for
both record kinds.

All readers use `read -r src dest repo_rel kind pattern`. On a three-field line
`kind` and `pattern` are empty, which is the file case.

The reverse direction — an old tool reading a new manifest — misreads a glob
line as a file whose destination is a directory, and reports false drift. This
cannot happen in practice: the generation that writes the manifest ships the
tools that read it, and activation rewrites the manifest before the new tools
are on `PATH`. It is recorded here rather than defended against.

A glob entry emits **both** kinds of record:

- one three-field file record for every file Nix finds under the source root at
  evaluation time that matches a pattern, so placement and drift detection are
  byte-for-byte the same code path as a declared file; and
- one five-field glob record per pattern, used only to recognise files that
  appear later.

Nothing about drift detection changes. Globs add discovery of files that do not
exist yet.

## Glob syntax and translation

Patterns are relative to both roots simultaneously: the source root under
`sourceDir`, and the destination root under `$HOME`. They never contain a
leading slash.

Supported syntax, and nothing else:

| Token | Meaning | ERE |
| --- | --- | --- |
| `**/` | zero or more leading directory components | `(.*/)?` |
| `/**` at end | everything below this directory | `/.*` |
| `*` | any run of characters within one component | `[^/]*` |
| `?` | one character within one component | `[^/]` |

Bracket expressions (`[abc]`) and brace expansion (`{a,b}`) are **not**
supported. Their characters are escaped and matched literally. Supporting them
means a second parser for a gain that listing two patterns already covers.

A run of two or more `*` that is not `**/` or a trailing `/**` collapses to a
single `*`.

### The translator lives in Nix

`lib/glob.nix` exports `globToERE :: string -> string`, returning an
**unanchored** ERE. Both consumers anchor it themselves and agree by
construction:

- Nix matches with `builtins.match`, which requires the whole string to match;
- `nd-status` matches with `grep -qxE`, where `-x` requires the whole line to
  match.

One translator, two anchoring mechanisms that mean the same thing. The
alternative — a Nix matcher for evaluation and a shell matcher for runtime —
is two implementations of the same grammar that will disagree eventually.

The manifest therefore carries the ERE, not the source glob. The cost is that
the manifest is less legible and test fixtures write regexes; `globToERE` is
exported so tests can compare against it rather than transcribing by hand.

### Translation algorithm

Ordered, because the steps are not commutative:

1. Replace `**/` with the sentinel `@@ND_GS@@`.
2. Replace `/**` with the sentinel `@@ND_GSTAIL@@`.
3. Collapse any remaining `**` to `*`.
4. Escape ERE metacharacters: `\` first, then `.` `+` `(` `)` `[` `]` `{` `}`
   `^` `$` `|`. Not `*` or `?`, which are handled next.
5. Replace `*` with `[^/]*` and `?` with `[^/]`.
6. Expand `@@ND_GS@@` to `(.*/)?` and `@@ND_GSTAIL@@` to `/.*`.

Sentinels are expanded last because their replacements contain characters that
steps 4 and 5 would otherwise mangle. They are chosen from characters that step
4 does not touch.

Worked examples:

| Glob | ERE | Matches |
| --- | --- | --- |
| `init.lua` | `init\.lua` | `init.lua` only |
| `lua/**/*.lua` | `lua/(.*/)?[^/]*\.lua` | `lua/x.lua`, `lua/plugins/lsp/init.lua` |
| `**/*.json` | `(.*/)?[^/]*\.json` | `a.json`, `deep/nested/b.json` |
| `colors/**` | `colors/.*` | anything below `colors/` |
| `*.lua` | `[^/]*\.lua` | `init.lua`, not `lua/x.lua` |

### Evaluation-time enumeration

For each glob entry, walk `sourceDir + "/" + source` with
`lib.filesystem.listFilesRecursive`, take each path's position relative to the
root, and keep it if any pattern's ERE matches. Each survivor becomes a file
record and is placed exactly as a declared file is.

An assertion fires if the source root does not exist, because
`listFilesRecursive` on a missing path is an evaluation error whose message does
not name the option that caused it.

An empty match set is not an error. A glob that currently matches nothing in the
repo but will match files the app creates is a legitimate and expected
configuration — that is `lazy-lock.json` on a fresh machine.

## New package: `nd-status`

Drift scanning is currently written four times: `nd-switch.nix:108`,
`nd-save.nix:53`, `nd-save.nix:73`, and the zsh hook in
`home-manager.nix:137`. Globs make each copy larger. They become one program.

```
usage: nd-status
```

Reads `ND_MANIFEST` (default `$HOME/.local/state/nd/manifest`) and `$HOME`. No
flags. Writes tab-separated classification lines to stdout:

```
drifted	.config/zed/settings.json	modules/users/b/files/zed/settings.json
missing	.config/zed/keymap.json	modules/users/b/files/zed/keymap.json
new	.config/nvim/lazy-lock.json	modules/users/b/files/nvim/lazy-lock.json
```

Columns are kind, destination relative to `$HOME`, and path relative to the
flake repo root. Output is passed through `sort -u`, which deduplicates a file
matched by two patterns of the same root and groups kinds deterministically
(`drifted` before `missing` before `new`).

Exit status is 0 whenever the manifest was read, findings or not. It is 1 only
when the manifest is absent or unreadable, with a message on stderr. Classifying
is this program's job; deciding what a finding means belongs to its callers.

Classification:

- **`drifted`** — a file record whose destination exists and differs from its
  store source.
- **`missing`** — a file record whose destination does not exist.
- **`new`** — a regular file under a glob root whose path relative to that root
  matches the root's ERE, and which is not already the destination of any file
  record.

`find -type f` is used for the walk, so symlinks, sockets, FIFOs and directories
are skipped. The walk uses `-print0` with `read -r -d ''`, so it does not
mis-split a path containing a newline.

The output format cannot represent such a path, though: it is line-based, and so
is the membership test that excludes already-placed destinations. A file whose
path relative to its glob root contains a newline is therefore **skipped**, with
one warning per file on stderr naming it. Skipping loudly beats emitting a line
that every consumer will parse as two.

### Consumers

- **`nd-switch`** blocks on `drifted` (unchanged behaviour, unchanged message).
  It lists `missing` under "will be restored" and `new` under "not yet in the
  repo", and continues in both cases. `--allow-dirty` suppresses the block, not
  the reports.
- **`nd-save`** copies `drifted` and `new`. It lists `missing` and skips them —
  there is nothing to save.
- **The zsh hook** counts lines by kind and prints one line naming the non-zero
  counts. This replaces an in-shell loop that forks one `cmp` per managed file
  with a single fork, so the hook gets cheaper as well as more capable.

`nd-status` is added to `home.packages` alongside `nd-switch` and `nd-save` when
`installPackages` is true. It is a third public binary, which is real interface
surface; it is justified by collapsing four copies of the scanning logic into
one, and by being the only reasonable place to put the glob walk.

## Option: `programs.nd.globs`

```nix
programs.nd.globs = mkOption {
  type = types.attrsOf (types.submodule {
    options = {
      source = mkOption { type = types.str; };
      patterns = mkOption { type = types.listOf types.str; };
    };
  });
  default = { };
};
```

Keyed by destination root relative to `$HOME`. `source` is relative to
`sourceDir`. `patterns` is required.

```nix
programs.nd.globs = {
  ".config/nvim" = {
    source = "nvim";
    patterns = [ "init.lua" "lua/**/*.lua" "lazy-lock.json" ];
  };
};
```

`files` is unchanged, in both type and meaning. The two options coexist; a
destination declared in `files` that also matches a glob is placed once (as a
declared file) and never reported as `new`, because `nd-status` excludes every
file-record destination from the new-file scan.

The existing assertion that `repoSubdir` must be set when `files` is non-empty
extends to `globs`.

## Option: `programs.nd.expectedBranch` (defect 3)

```nix
expectedBranch = mkOption {
  type = types.str;
  default = "";      # no constraint
};
```

Threaded to `nd-save` as `ND_EXPECTED_BRANCH`. A `--branch NAME` flag overrides
the environment.

- Constraint set, branch matches: proceed.
- Constraint set, branch differs: refuse, **including under `-y`**. The
  unattended path is precisely the one that needs the check.
- Constraint empty: no constraint. Print the branch and prompt, as today.
- Detached HEAD (`git branch --show-current` empty): refuse unconditionally,
  regardless of `-y`, `--branch` or `--force`. Today this reports `branch ''`
  and commits onto a detached HEAD, where the commit is unreachable as soon as
  anything else is checked out.

## The remaining defect fixes

### 1 — scope git operations to the managed paths

`nd-save` collects the repo-relative path of every file it actually copied this
run into an array, and scopes all three git operations to it:

- `git status --porcelain -- "${paths[@]}"` — answers "did the copies change
  anything", not "is the whole repository clean".
- `git diff HEAD -- "${paths[@]}"` for the preview. `HEAD` rather than the
  working tree, so the preview shows staged changes to managed paths as well as
  unstaged ones. Today's preview omits exactly the content the commit sweeps in.
- `git add -- "${paths[@]}"` then `git commit --only -m "$msg" -- "${paths[@]}"`.

The `add` is needed because a newly captured glob file is untracked, and
`commit --only` rejects a pathspec git does not know. `--only` then commits the
named paths from the working tree, leaving any other staged content staged and
uncommitted. That property is what the test asserts.

`git add` on a managed path discards whatever was previously staged for that
path in favour of the working-tree content. For a managed file that is the
intended outcome. Documented, not defended.

### 2 — refuse to overwrite an unplaced repo edit

Before copying anything, for each file to be copied:

- a `drifted` record whose repo file exists and differs from its store source
  carries an edit that has not been placed yet — **blocker**;
- a `new` record whose repo file already exists is a file added to the repo but
  never placed — **blocker**;
- everything else proceeds.

Blockers are collected, listed by name, and the run refuses with exit 1 having
written nothing. `--force` overrides. The refusal must never be silent, which is
the entire content of defect 2.

The rule is deliberately conditional: "the repo differs from the store" is the
right question for a declared file and a meaningless one for a file the app
just invented, which has no store source at all. Tests pin both directions.

Ordering, which matters and must be preserved: credential scan, then blocker
check, then copy. Both refusals happen before any write, so a refused run leaves
the working tree untouched.

This also fixes the related bug at `nd-save.nix:126-128`, where every manifest
entry with an existing repo file was staged, including managed files that had
not drifted. Only copied paths are staged now.

### 4 — commit subjects that name what changed

Derived from the destinations copied, with no lookup table:

```
app(dest) = if dest starts with ".config/"
            then the component following it
            else basename, with a leading "." stripped, truncated at the first "."
```

`.config/zed/settings.json` → `zed`. `.config/nvim/lua/plugins/lsp.lua` →
`nvim`. `.wezterm.lua` → `wezterm`.

Deduplicated and sorted, then:

- one: `Save zed config written by the app`
- two: `Save config written by wezterm and zed`
- three or more: `Save config written by nvim, wezterm and zed`

Lower case and unprettified, because capitalising `wezterm` to `WezTerm` needs a
table of application names that goes stale the first time a file is added. An
explicit `-m` still wins.

### 5 — credential scan unchanged, decision recorded

The regex at `nd-save.nix:57` is kept verbatim. A source comment records why,
in the same style as the comment that records the scan's placement. Newly
discovered glob files are scanned too — they are being copied into the repo, so
they are exactly as dangerous.

Negative test cases are added that must not trip the scan: a hex colour table, a
UUID, and a base64 data URI.

### 6 — missing files are their own category

`nd-status` already separates them. Neither tool treats a deletion as drift and
neither blocks on it. `nd-switch` says the file will be restored; `nd-save` says
it is being skipped. The behaviour that annoyed nobody — restoring — is kept.
The behaviour that did — doing it silently — is not.

### 9 — dry-run activation writes nothing

The manifest content is built into a shell variable during activation and
written once, inside a guard on the same variable home-manager's `run` helper
keys off.

That variable is `DRY_RUN`, tested for existence, not `DRY_RUN_CMD`. Verified
against `home-manager.sh`, where `run()` is:

```sh
function run() {
    ...
    if [[ -v DRY_RUN ]] ; then
        echo "$@"
    ...
}
```

and against the generated `activate`, which sets `DRY_RUN_CMD` only for
backwards compatibility and comments it as deprecated. Home-manager's own code
uses `if [[ ! -v DRY_RUN ]]`. So:

```sh
if [[ -v DRY_RUN ]]; then
  echo "would write manifest to $manifest"
else
  printf '%s' "$ndManifest" > "$manifest.new"
  mv "$manifest.new" "$manifest"
fi
```

Activation runs under bash, so `[[ -v ]]` is available. The activation script's
shebang is bash and it runs `set -eu; set -o pipefail`.

The temporary file and rename are kept for atomicity; both now sit inside the
guard, so a dry run no longer leaves an orphaned `manifest.new`.

### Not a defect: `&&` under `errexit`

Worth recording, because it looks like a bug and is not, and the next reader
will re-derive it.

`writeShellApplication` and home-manager activation both set `errexit`.
`nd-save.nix:128` (`[ -e "$flake/$repo_rel" ] && git ... add`) and
`home-manager.nix:121` (`[ -L "$HOME/${dest}" ] && run rm -f`) look like they
abort the script whenever the test fails. Tested against bash 5:

- `false && echo hi` at the top level of a script under `set -euo pipefail`:
  does not exit.
- the same inside a `for`/`while` body: does not exit.
- the same inside a **function**: the function returns 1, and the call site then
  trips `errexit`.

Both existing occurrences are top-level statements inside loops, so both are
safe today. The hazard is real but latent: the statement becomes fatal if it is
ever moved into a function, and it sets the script's exit status if it ever
becomes the last statement.

No fix to the existing lines is required. New code uses explicit
`if ... then ... fi` rather than `&&` as a statement, and `nd-status` — which
does use functions — must not contain an `&&` statement at all.

## Test plan

`tests/run.sh` gains cases in the existing style: synthetic `$HOME`, synthetic
manifest, throwaway git repo, no sudo, no switch. A second fixture builder is
added for glob roots.

**Glob translation** — a `nix eval` check comparing `globToERE` output against
the worked examples table above, plus a `checks` entry so `nix flake check`
covers it.

**`nd-status`** — drifted, missing and new each classified correctly; a file
matching two patterns emitted once; a file matching no pattern not emitted; a
declared file inside a glob root never reported as new; a symlink and a
directory under a glob root skipped; a path containing a newline skipped with a
warning rather than emitted; a missing manifest exiting 1.

**Defect 1** — extend `tests/run.sh:155`, which currently passes vacuously. Add
a second tracked file to the fixture, modify and `git add` it, drift the managed
file, run `nd-save -y`, then assert the commit touches only
`files/config.toml`, and that the unrelated file is still staged and still
uncommitted.

**Defect 2** — repo file edited and live file undrifted: nothing committed. Both
edited: refusal, repo file unchanged, exit 1, offender named. `--force` with
both edited: copy proceeds. New glob capture with no repo counterpart: proceeds
and creates parent directories. New glob capture whose repo counterpart already
exists: refusal.

**Defect 3** — expected branch matching; mismatching under `-y`; mismatching
with `--branch` override; detached HEAD refused with `-y` and with `--branch`.

**Defect 4** — single-file drift names that file's app; multi-file drift names
all of them in sorted order; `-m` overrides; a non-`.config` destination like
`.wezterm.lua` derives `wezterm`.

**Defect 5** — the three existing positives, plus three negatives that must not
trip: hex colour table, UUID, base64 data URI.

**Defect 6** — destination removed: `nd-switch` names it and does **not** print
the drift-block message, and `nd-save` names it and skips it without failing.
The assertion is on the absence of the block, not on the exit status: the
fixture's `flake.nix` is a stub, so `nd-switch --build` reaches `nix build` and
fails there. Every existing `--build` case has the same shape.

**Defect 9** — activation under dry run leaves no `manifest.new` and does not
modify `manifest`. Exercised at the shell level against the generated activation
snippet rather than by running home-manager.

**End-to-end glob loop** — place from a glob, have the "app" create a matching
file, `nd-save` it, confirm it lands in the repo at the right path, and confirm
a re-evaluation would now enumerate it as a file record.

## Versioning

`globs` and `expectedBranch` are public interface additions, and `nd-status` is
a new binary. That is a minor bump: **v0.2.0**. Defects 1, 2, 4, 6 and 9 are
patch-level but ship in the same release. Consumers need a `flake.lock` update.

Defect 8 is closed as wontfix in this release and needs no version treatment.

## Out of scope

- Whole-directory tracking. Rejected above; globs replace it.
- Bracket expressions and brace expansion in patterns.
- Per-file modes (defect 8, wontfix).
- Entropy-based or third-party credential scanning (defect 5, decided against).
- Pushing. `nd-save` still never pushes.
- Updating the consumer repo's `docs/superpowers/plans/bfults-todo.md`, which
  the issues document notes is obsolete. Separate work, and it is gitignored in
  a different repository.

## README changes

- `globs` documented alongside `files`, with the syntax table and the
  `lazy-lock.json` example.
- `expectedBranch` documented.
- `nd-status` documented as a command.
- Safety section: the branch guard now refuses rather than merely printing.
- Limitations: drop "Only regular files. Directories must be listed file by
  file." Keep the 0644 entry and say it is deliberate.
- The case count near the end of the file is stated as a number and will be
  wrong after this change.
