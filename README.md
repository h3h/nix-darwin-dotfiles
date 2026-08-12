# nix-darwin-dotfiles

Manage dotfiles with nix-darwin **without** giving up the application's own
settings UI — and without letting those edits quietly rot in an uncommitted
working tree.

Provides a home-manager module plus three commands: `nd-switch`, `nd-save` and
`nd-status`.

## The problem

Nix wants to own your dotfiles. Applications want to own them too — Zed writes
`settings.json` every time you toggle a preference. The usual answers both hurt:

**Read-only store files.** `home.file.<name>.source` symlinks into
`/nix/store`, so the app cannot write at all. Its settings UI silently fails or
errors. Every change means editing the repo and rebuilding.

**Out-of-store symlinks.** `mkOutOfStoreSymlink` points the home path at your
repo working tree, so the app can write and the change lands in the repo. This
is the common advice, and it solves only half the problem:

- Nothing tells you a file changed. It sits uncommitted until you happen to run
  `git status`.
- The home path and the repo file are the *same inode*, so `git checkout` and
  `git stash` rewrite live config underneath a running application. Switching
  branches changes your editor settings.
- A generation rollback cannot revert them, because they follow the working
  tree rather than the generation — so rollback is partial for exactly the
  files most likely to have been fiddled with.

## The approach

Copy, don't symlink. Then make the drift visible and easy to capture.

1. **Placement.** At activation, each managed file is copied from the store into
   place, and a manifest records what was placed: store source, destination,
   and the file's path inside your flake repo. Each glob pattern also gets a
   record, so files the application creates later can be recognised.
2. **Detection.** `nd-status` reads the manifest and classifies every managed
   path as `drifted` (differs from the store source it was placed from),
   `captured` (differs from the store source, or was never placed, but the repo
   already holds that exact content where git can see it), `missing` (deleted),
   `new` (a file under a glob root that matches a pattern and has no record yet)
   or `unreadable` (the store source cannot be opened, so drift cannot be
   decided either way). Drift is a content comparison against *what was actually
   installed*, which is what makes the next point work.
3. **Gate.** `nd-switch` refuses to switch while any managed file has drifted,
   because switching would copy over it. `captured`, `missing`, `new` and
   `unreadable` are reported but do not block: a captured file is rebuilt from
   the repo copy that already matches it, so the overwrite discards nothing; a
   missing file will be restored by the switch; a new file has no store source
   to be overwritten by; and an unreadable source is repaired by the switch,
   which rewrites the manifest.
   `--allow-dirty` and `--rollback` both bypass the gate, and both name every
   drifted file and say its contents will be discarded before anything is built
   and before sudo is asked for anything.
4. **Capture.** `nd-save` copies drifted and new files back into the repo and
   commits them.

### Why compare against the store, not the repo

Comparing the home file to the repo file cannot distinguish two opposite
situations:

- the application changed the file, and the change needs saving; or
- you edited the repo, and the change needs placing.

Both look like "these differ". Comparing against the store path *the current
generation installed* separates them exactly: that is the last known-placed
content, so a difference means something rewrote it afterwards.

There are three states, not two, and the third is why `captured` exists:

| live vs placed | live vs repo | meaning | what happens |
| --- | --- | --- | --- |
| same | same | nothing happened | switch |
| differs | differs | the app rewrote it, not yet captured | refuse — this is what the gate is for |
| differs | same | the app rewrote it, `nd-save` already captured it | switch; the new generation builds this file *from* the repo copy, so the overwrite discards nothing |

Before the third row was distinguished, it was classified as drift and refused,
and the refusal was self-perpetuating: only an activation rewrites the manifest,
and `nd-switch` was the thing declining to activate. `nd-save` could not break it
either, because the state it would have had to change is the manifest, which
activation owns. `nd-status` decides the third row by asking whether the repo
copy is byte-identical to the live file *and* visible to git — an untracked file
is invisible to a flake build, so a byte-identical untracked copy would not
survive the switch. Anything it cannot decide stays `drifted`.

## Install

```nix
{
  inputs.nix-darwin-dotfiles.url = "github:h3h/nix-darwin-dotfiles";
}
```

Then, in your home-manager configuration:

```nix
{
  imports = [ inputs.nix-darwin-dotfiles.homeManagerModules.default ];

  programs.nd = {
    enable = true;

    # Where nd-save copies files back to, and commits.
    flakePath = "/Users/alice/.config/nix-darwin";

    # The managed files, and where they live inside the flake.
    sourceDir = ./files;
    repoSubdir = "modules/users/alice/files";

    files = {
      ".config/zed/settings.json" = "zed/settings.json";
      ".config/zed/keymap.json" = "zed/keymap.json";
      ".config/wezterm/wezterm.lua" = "wezterm/wezterm.lua";
    };

    globs = {
      ".config/nvim" = {
        source = "nvim";
        patterns = [ "init.lua" "lua/**/*.lua" "lazy-lock.json" ];
      };
    };

    # Optional: refuse to commit anywhere else.
    expectedBranch = "main";
  };
}
```

`sourceDir` and `repoSubdir` describe the same directory twice, once as a store
path for placement and once as a repo-relative path for copy-back. They have to
agree; nothing verifies that for you.

`files` names one file each. `globs` names a *set*, keyed by destination root:
everything matching is placed exactly as a `files` entry would be, and a file
that appears under the destination root later and matches a pattern is captured
rather than ignored. That is what makes lazy.nvim's `lazy-lock.json` — a file
you never declare, whose whole purpose is to be regenerated — trackable.

| Pattern | Matches |
| --- | --- |
| `init.lua` | that file, at the root |
| `*.lua` | any `.lua` directly under the root |
| `?.lua` | a one-character name, directly under the root |
| `lua/**/*.lua` | any `.lua` at any depth under `lua/` |
| `**/*.json` | any `.json` at any depth |
| `colors/**` | everything below `colors/` |

Bracket expressions and brace expansion are not supported; their characters are
escaped and matched literally.

Only what a pattern names is ever captured. This is an allowlist deliberately: a
managed *directory* would need an ignore list maintained against an application
you do not control.

## Usage

```console
$ nd-switch                 # build, then switch this host
$ nd-switch --build         # build only: no sudo, no switch
$ nd-switch --allow-dirty   # switch anyway, discarding drift (named first)
$ nd-switch --rollback      # back one generation
$ nd-switch --rollback 3    # back three
$ nd-save                   # copy drifted and new files back, review, commit
$ nd-save -m "Update Zed"   # with a commit message
$ nd-save -y                # skip the confirmation
$ nd-save --force           # overwrite repo edits that were never placed
$ nd-save --branch main     # require a branch for this run
$ nd-status                 # what drifted, was captured, went missing, appeared or cannot be read
```

`nd-status` prints one line per finding, `<kind>` TAB `<path under $HOME>` TAB
`<path under the repo root>`, and exits 0 whether or not it found anything —
findings are not an error condition, and what one means is the caller's
decision. It exits 1 when there is no manifest to read, and on a bad argument.

A typical session — Zed has rewritten its settings, and lazy.nvim has written a
`lazy-lock.json` that the repo has never seen:

```console
$ nd-status
drifted	.config/zed/settings.json	files/zed/settings.json
new	.config/nvim/lazy-lock.json	files/nvim/lazy-lock.json

$ nd-switch
nd-switch: these files are not yet in the repo:
  .config/nvim/lazy-lock.json
nd-switch: run 'nd-save' to capture them.
nd-switch: these files changed since they were placed:
  .config/zed/settings.json
nd-switch: switching would overwrite them.
nd-switch: run 'nd-save' to copy them back and commit, or --allow-dirty to discard

$ nd-save
nd-save: copied back into the repo
  .config/zed/settings.json
  .config/nvim/lazy-lock.json

nd-save: changes
diff --git a/files/nvim/lazy-lock.json b/files/nvim/lazy-lock.json
new file mode 100644
...
nd-save: will commit to branch 'main'
nd-save: proceed? [y/N] y
[main 3772a45] Save config written by nvim and zed
 2 files changed, 2 insertions(+), 1 deletion(-)
 create mode 100644 files/nvim/lazy-lock.json
nd-save: committed. Not pushed.

$ nd-switch
nd-switch: building mymac from /Users/alice/.config/nix-darwin
```

The commit subject is derived from the destinations, so `git log --oneline`
says which application rewrote what. One application gives `Save zed config
written by the app`; several give `Save config written by nvim and zed`. `-m`
still wins.

Deleting a managed file is not drift, so it does not block a switch — but it is
reported, by both commands:

```console
$ nd-switch
nd-switch: these managed files are gone and will be restored:
  .config/zed/settings.json

$ nd-save
nd-save: these managed files are gone; there is nothing to save for them:
  .config/zed/settings.json
nd-save: the next switch will restore them.
```

With zsh integration enabled (the default), an interactive shell prints a single
line when anything needs attention. It forks `nd-status` once, whatever the
number of managed files:

```
nd: 1 missing, 1 new config file(s) — run nd-save to audit and commit
```

`nd-switch` reads the hostname, so it needs no per-machine configuration. The
defaults are overridable from the environment: `ND_FLAKE` and `ND_HOST` by
`nd-switch`, `ND_FLAKE`, `ND_MANIFEST` and `ND_EXPECTED_BRANCH` by `nd-save`,
`ND_MANIFEST` by all three. When the commands come from the module, `flakePath`,
`manifestPath` and `expectedBranch` are baked into wrappers as *defaults*, so an
explicitly exported `ND_*` still wins.

## Safety

- **`nd-save` scans before it copies.** Applications write credentials into
  their own config routinely, and your flake repo may be shared. If any file it
  is about to save contains credential-shaped content, nothing is copied and
  nothing is staged — a secret copied into the working tree and then refused is
  a secret waiting to be committed later by accident.
- **`nd-save` never pushes.**
- **The scan is pattern-based.** It catches common key shapes and any
  `api_key` / `token` / `secret` / `password` assignment. It will not catch a
  bare high-entropy string under an innocuous key name. It is a backstop, not a
  guarantee.
- **Activation removes a pre-existing symlink before copying.** Without that,
  `install` writes *through* an old `mkOutOfStoreSymlink` straight back into the
  repo, silently preserving the behaviour this module replaces.
- **`nd-save` refuses an unexpected branch.** Set `programs.nd.expectedBranch`
  and it refuses to commit anywhere else, including under `-y`. `--branch NAME`
  overrides it for one run. With no expected branch set, `nd-save` prints the
  branch and proceeds, as before. A detached HEAD is refused whatever you set,
  because the commit would be unreachable as soon as anything else is checked
  out.
- **`nd-save` refuses to overwrite repo edits that were never placed.** If the
  repo copy of a managed file differs from what was last placed, you have an
  edit waiting to be switched in; nd-save names it and stops rather than copying
  over it. The same applies to a newly captured file whose repo path is already
  occupied. `--force` overrides.
- **`nd-save` refuses to overwrite content you have staged.** If a managed
  repo path has staged content that differs from `HEAD`, saving over it would
  make that blob unreachable — the same loss as the previous bullet, one version
  to the left. `--force` overrides.
- **`nd-save` commits only the files it copied.** Every git operation it runs
  takes a pathspec, so anything else you had staged stays staged and
  uncommitted.
- **`nd-save` leaves the index as it found it on every exit that does not
  commit.** It marks a newly captured file `--intent-to-add` before the
  confirmation prompt, so the preview can show a file git does not yet track. If
  you decline, interrupt it, or the commit fails, the index is restored — an
  entry left behind would be swept into your next `git commit -am`, which is the
  first bullet's failure through a different door.

## Tests

```console
$ nix flake check          # runs the suite in a sandbox
$ bash tests/run.sh        # or directly
```

210 cases covering argument parsing; drift, missing, new and unreadable
classification; the gate, its two overrides and what they say they will discard;
flag ordering; copy-back; commit scoping and contents; the branch guard and
detached HEAD; the unplaced-repo-edit and staged-content refusals and `--force`;
what the index looks like after every exit that does not commit; derived commit
subjects; credential refusal and the benign shapes that must not trip it; the
zsh notice; and the end-to-end capture loop for an application-created file.
Every case builds a synthetic `$HOME`, manifest and throwaway git repo, so the
suite needs no sudo, performs no switch, and never touches a real home
directory.

`nix flake check` runs three further checks:

- `tests/glob.nix`, a pure evaluation test pinning `globToERE`'s translations
  and the file sets they match.
- `tests/glob-engines.sh`, which replays every one of those cases through
  `grep -qxE` and fails if it disagrees with the verdict `builtins.match` gave
  the same regex. The two engines are not the same dialect — `\]` is fine to one
  and fatal to the other — so "one translator, two anchoring mechanisms" has to
  be tested rather than asserted.
- `tests/module.nix` and `tests/module.sh`, 59 cases evaluating the real
  home-manager module against a stubbed option surface: the exact manifest text
  it generates, which files each pattern enumerates, that a dry-run activation
  writes nothing at all, that the option wrappers export what they should and
  still let an explicit `ND_*` win, and a round trip feeding the generated
  manifest to the real `nd-status`. That last one is the only place the code
  that writes the manifest and the code that reads it meet.

## Limitations

- Files are placed mode `0644`, deliberately: the credential scan's position is
  that nothing secret belongs in a managed file, and git records only the
  executable bit, so a per-file mode could not survive the round-trip anyway.
- Glob patterns support `**/`, a trailing `/**`, `*` and `?`. Bracket
  expressions and brace expansion match literally.
- Only regular files are enumerated under a glob root; symlinks, directories and
  anything else `find -type f` rejects are skipped.
- A path containing a newline or a tab under a glob root is skipped, with a
  warning. The output format is one tab-separated record per line and cannot
  represent either.
- `nd-switch --rollback` reverts the generation, and placed files come back with
  it — but any drift you had not saved is gone. It names what it is about to
  discard first; unlike an ordinary switch, it warns rather than refusing,
  because a rollback is usually the repair.
- macOS and nix-darwin only. The package builds anywhere; `nd-switch` calls
  `darwin-rebuild`.

## Licence

MIT.
