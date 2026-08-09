# nix-darwin-dotfiles

Manage dotfiles with nix-darwin **without** giving up the application's own
settings UI — and without letting those edits quietly rot in an uncommitted
working tree.

Provides a home-manager module plus two commands, `nd-switch` and `nd-save`.

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
   and the file's path inside your flake repo.
2. **Detection.** A file has drifted when it differs from the store source it
   was placed from. That is a content comparison against *what was actually
   installed*, which is what makes the next point work.
3. **Gate.** `nd-switch` refuses to switch while any managed file has drifted,
   because switching would copy over it.
4. **Capture.** `nd-save` copies drifted files back into the repo and commits
   them.

### Why compare against the store, not the repo

Comparing the home file to the repo file cannot distinguish two opposite
situations:

- the application changed the file, and the change needs saving; or
- you edited the repo, and the change needs placing.

Both look like "these differ". Comparing against the store path *the current
generation installed* separates them exactly: that is the last known-placed
content, so a difference means something rewrote it afterwards.

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
  };
}
```

`sourceDir` and `repoSubdir` describe the same directory twice, once as a store
path for placement and once as a repo-relative path for copy-back. They have to
agree; nothing verifies that for you.

## Usage

```console
$ nd-switch                 # build, then switch this host
$ nd-switch --build         # build only: no sudo, no switch
$ nd-switch --allow-dirty   # switch even though managed files drifted
$ nd-switch --rollback      # back one generation
$ nd-switch --rollback 3    # back three
$ nd-save                   # copy drifted files back, review, commit
$ nd-save -m "Update Zed"   # with a commit message
$ nd-save -y                # skip the confirmation
```

A typical session:

```console
$ nd-switch
nd-switch: these files changed since they were placed:
  .config/zed/settings.json
nd-switch: switching would overwrite them.
nd-switch: run 'nd-save' to copy them back and commit, or --allow-dirty to discard

$ nd-save -m "Turn on inlay hints"
nd-save: copied back into the repo
  .config/zed/settings.json
...
nd-save: will commit to branch 'main'
nd-save: proceed? [y/N] y
nd-save: committed. Not pushed.

$ nd-switch
nd-switch: building mymac from /Users/alice/.config/nix-darwin
```

With zsh integration enabled (the default), an interactive shell prints a single
line when anything has drifted:

```
nd: 2 config file(s) drifted — run nd-save to audit and commit
```

`nd-switch` reads the hostname, so it needs no per-machine configuration.
`ND_FLAKE`, `ND_HOST` and `ND_MANIFEST` override the defaults.

## Safety

- **`nd-save` scans before it copies.** Applications write credentials into
  their own config routinely, and your flake repo may be shared. If a drifted
  file contains credential-shaped content, nothing is copied and nothing is
  staged — a secret copied into the working tree and then refused is a secret
  waiting to be committed later by accident.
- **`nd-save` never pushes.**
- **The scan is pattern-based.** It catches common key shapes and any
  `api_key` / `token` / `secret` / `password` assignment. It will not catch a
  bare high-entropy string under an innocuous key name. It is a backstop, not a
  guarantee.
- **Activation removes a pre-existing symlink before copying.** Without that,
  `install` writes *through* an old `mkOutOfStoreSymlink` straight back into the
  repo, silently preserving the behaviour this module replaces.
- **`nd-save` commits to whatever branch is checked out.** It prints the branch
  and asks first, but does not refuse an unexpected one.

## Tests

```console
$ nix flake check          # runs the suite in a sandbox
$ bash tests/run.sh        # or directly
```

40 cases covering argument parsing, drift detection, the gate and its override,
flag ordering, copy-back, commit contents, declining, and credential refusal.
Every case builds a synthetic `$HOME`, manifest and throwaway git repo, so the
suite needs no sudo, performs no switch, and never touches a real home
directory.

## Limitations

- Files are placed mode `0644`. Managing anything that must be executable or
  private needs a change here.
- Only regular files. Directories must be listed file by file.
- `nd-switch --rollback` reverts the generation, and placed files come back with
  it — but any drift you had not saved is gone, exactly as with the gate.
- macOS and nix-darwin only. The package builds anywhere; `nd-switch` calls
  `darwin-rebuild`.

## Licence

MIT.
