# nd globs and v0.1.0 defect fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add glob-tracked files to `programs.nd` so application-created files such as `lazy-lock.json` are captured, and fix defects 1–6 and 9 from `nix-darwin-dotfiles-issues.md`.

**Architecture:** A new `lib/glob.nix` translates glob patterns to unanchored EREs at evaluation time; the home-manager module enumerates matches into ordinary file records and writes one extra manifest record per pattern. A new `nd-status` package becomes the single reader of the manifest, classifying every managed path as `drifted`, `missing` or `new`, and `nd-switch`, `nd-save` and the zsh notice all consume its output instead of each re-implementing the scan.

**Tech Stack:** Nix flakes, `writeShellApplication` (bash 5, `set -euo pipefail`, shellcheck at build time), home-manager modules, POSIX `find`/`grep`/`awk`, a bash test harness in `tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-08-09-nd-globs-and-defects-design.md`. Read it before starting. Everything here implements it; where this plan refines a spec decision, it says so explicitly.

## Global Constraints

- Every shell script is built by `writeShellApplication`, which runs shellcheck at build time. A shellcheck warning fails the build. There is no suppression budget: fix the code, do not add `# shellcheck disable`.
- Scripts run under `set -o errexit -o nounset -o pipefail`.
- **Never use `A && B` as a statement.** Use `if ... then ... fi`. Verified: a failing `&&` statement is harmless at the top level and inside loop bodies, but inside a function it makes the function return 1 and trips `errexit` at the call site. New code uses `if`.
- Nix indented strings (`''...''`) escape `${` as `''${`. Every shell parameter expansion inside one needs it. A bare `\n` inside an indented string is a literal backslash-n, which is what bash `$'\n'` needs.
- Manifest fields are tab-separated. Field 4 is the record kind; empty means "file". Three-field lines must keep working.
- `globToERE` returns an **unanchored** ERE. Nix anchors via `builtins.match` (whole-string); shell anchors via `grep -qxE` (whole-line). Never add `^` or `$` to the output.
- Commit after every task. Conventional-commit style subjects, matching the existing history's sentence case. Never add co-sign trailers.
- Run `nix flake check` before every commit. It runs shellcheck, the eval tests and `tests/run.sh`.
- `nixfmt-rfc-style` is the formatter. Run `nix fmt` on changed `.nix` files before committing.

## Escalation protocol

An **escalation** is anything that blocks a step, contradicts the spec, or is a decision the plan does not settle. Do not guess and move on, and do not silently change the design.

Append to `docs/superpowers/escalations.md`, which Task 0 creates. Each entry:

```markdown
## E<N> — <one-line title>
- **Task:** <task number>
- **Raised:** <what was expected, what actually happened, with the exact command and output>
- **Options:** <the choices, with the trade-off of each>
- **Status:** open | resolved | unresolved
- **Resolution:** <what was decided and why, once decided>
```

Resolve an escalation in the task that raised it wherever the plan or spec already implies an answer. Leave it `open` only when it genuinely needs a judgement call.

---

## File Structure

**Create:**
- `lib/glob.nix` — `globToERE`, the only glob-to-regex translator in the project.
- `tests/glob.nix` — pure evaluation test for `globToERE`; returns lists of failures.
- `packages/nd-status.nix` — classifies manifest entries. The only manifest reader.
- `modules/nd-notice.zsh` — the zsh startup notice, as a standalone sourceable file so it can be tested.
- `docs/superpowers/escalations.md` — escalation log.

**Modify:**
- `flake.nix` — expose `nd-status`, add the glob eval check, add `zsh` and `ND_STATUS` to the test check.
- `packages/nd-switch.nix` — consume `nd-status`; report `missing` and `new`; keep blocking on `drifted`.
- `packages/nd-save.nix` — substantially rewritten: `nd-status` consumer, branch guard, blocker check, scoped git operations, derived commit subject.
- `modules/home-manager.nix` — `globs` and `expectedBranch` options, glob enumeration, manifest v2, dry-run fix, wrappers that thread `flakePath` and `manifestPath`, zsh notice from the new file.
- `tests/run.sh` — new fixtures and cases throughout.
- `README.md` — document everything new; correct the limitations.

---

### Task 0: Escalation log and worktree hygiene

**Files:**
- Create: `docs/superpowers/escalations.md`

- [ ] **Step 1: Create the escalation log**

```markdown
# Escalations — nd globs and defect fixes

Plan: `docs/superpowers/plans/2026-08-09-nd-globs-and-defects.md`

Entry format is defined in the plan's "Escalation protocol" section.
Statuses: `open` (needs a decision), `resolved` (decided, with reasoning
recorded), `unresolved` (escalated and still undecided at hand-off).

No escalations yet.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/escalations.md
git commit -m "Add escalation log for the globs and defects work"
```

---

### Task 1: `globToERE`

**Files:**
- Create: `lib/glob.nix`
- Create: `tests/glob.nix`
- Modify: `flake.nix`

**Interfaces:**
- Produces: `globToERE :: string -> string`, imported as `import ./lib/glob.nix { inherit lib; }`. Returns an unanchored POSIX ERE. Used by `modules/home-manager.nix` (Task 8) and by `tests/glob.nix`.

- [ ] **Step 1: Write the failing test**

Create `tests/glob.nix`. It is a pure function of `lib` returning two lists; empty lists mean pass.

```nix
{ lib }:

let
  glob = import ../lib/glob.nix { inherit lib; };

  # Exact translations. These are the worked examples from the spec.
  translations = [
    { g = "init.lua";       e = "init\\.lua"; }
    { g = "lua/**/*.lua";   e = "lua/(.*/)?[^/]*\\.lua"; }
    { g = "**/*.json";      e = "(.*/)?[^/]*\\.json"; }
    { g = "colors/**";      e = "colors/.*"; }
    { g = "*.lua";          e = "[^/]*\\.lua"; }
    { g = "?.lua";          e = "[^/]\\.lua"; }
    { g = "a+b(c).txt";     e = "a\\+b\\(c\\)\\.txt"; }
    { g = "lazy-lock.json"; e = "lazy-lock\\.json"; }
  ];

  # Behaviour. A correct-looking ERE that matches the wrong set is still wrong.
  matches = [
    { g = "lua/**/*.lua";   s = "lua/x.lua";               want = true; }
    { g = "lua/**/*.lua";   s = "lua/plugins/lsp/init.lua"; want = true; }
    { g = "lua/**/*.lua";   s = "init.lua";                want = false; }
    { g = "lua/**/*.lua";   s = "lua/x.vim";               want = false; }
    { g = "*.lua";          s = "init.lua";                want = true; }
    { g = "*.lua";          s = "lua/x.lua";               want = false; }
    { g = "**/*.json";      s = "a.json";                  want = true; }
    { g = "**/*.json";      s = "deep/nested/b.json";      want = true; }
    { g = "colors/**";      s = "colors/a/b.vim";          want = true; }
    { g = "colors/**";      s = "colors";                  want = false; }
    { g = "lazy-lock.json"; s = "lazy-lock.json";          want = true; }
    { g = "lazy-lock.json"; s = "lazy-lockXjson";          want = false; }
    { g = "?.lua";          s = "a.lua";                   want = true; }
    { g = "?.lua";          s = "ab.lua";                  want = false; }
  ];

  translationFailures = lib.filter (c: glob.globToERE c.g != c.e) (
    map (c: c // { got = glob.globToERE c.g; }) translations
  );

  matchFailures = lib.filter (
    c: (builtins.match (glob.globToERE c.g) c.s != null) != c.want
  ) (map (c: c // { ere = glob.globToERE c.g; }) matches);
in
{
  inherit translationFailures matchFailures;
  ok = translationFailures == [ ] && matchFailures == [ ];
}
```

Add the check to `flake.nix` inside the `checks = forAllSystems (pkgs: ... )` attribute set, alongside `tests`:

```nix
          glob =
            let
              r = import ./tests/glob.nix { inherit (pkgs) lib; };
            in
            if r.ok then
              pkgs.runCommand "nd-glob-tests" { } "touch $out"
            else
              throw ''
                globToERE translation failures: ${builtins.toJSON r.translationFailures}
                globToERE match failures: ${builtins.toJSON r.matchFailures}
              '';
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `nix flake check 2>&1 | tail -20`
Expected: an evaluation error naming `lib/glob.nix` — the file does not exist yet.

- [ ] **Step 3: Implement `lib/glob.nix`**

```nix
{ lib }:

# Glob-to-ERE translation, in exactly one place.
#
# The alternative — a matcher in Nix for evaluation time and a second one in
# shell for runtime — is two implementations of one grammar, and they diverge
# the first time either is touched. Instead this runs at evaluation time only,
# and the resulting ERE is written into the manifest for the shell to hand
# straight to grep.
#
# The result is deliberately UNANCHORED. `builtins.match` requires the whole
# string to match and `grep -qxE` requires the whole line to match, so both
# callers anchor by their own mechanism and agree by construction. Adding ^...$
# here would be wrong for `builtins.match`.
rec {
  # Supported syntax, and nothing else:
  #
  #   **/     zero or more leading directory components   (.*/)?
  #   /**     everything below this directory (trailing)  /.*
  #   *       any run of characters within one component  [^/]*
  #   ?       one character within one component          [^/]
  #
  # Bracket expressions and brace expansion are NOT supported; their characters
  # are escaped and matched literally. Supporting them means a second parser for
  # a gain that listing two patterns already covers.
  #
  # A run of two or more `*` that is neither `**/` nor a trailing `/**`
  # collapses to a single `*`.
  globToERE =
    glob:
    let
      # Sentinels stand in for the multi-character tokens while the single
      # characters around them are escaped. They are made of characters that
      # neither the escape step nor the wildcard step touches, and they are
      # expanded last because their replacements contain characters that both of
      # those steps would otherwise mangle. The steps are not commutative.
      gs = "@@ND_GS@@";
      gsTail = "@@ND_GSTAIL@@";
    in
    lib.pipe glob [
      (lib.replaceStrings [ "**/" ] [ gs ])
      (lib.replaceStrings [ "/**" ] [ gsTail ])
      (lib.replaceStrings [ "**" ] [ "*" ])
      (lib.replaceStrings
        [ "\\" "." "+" "(" ")" "[" "]" "{" "}" "^" "$" "|" ]
        [ "\\\\" "\\." "\\+" "\\(" "\\)" "\\[" "\\]" "\\{" "\\}" "\\^" "\\$" "\\|" ]
      )
      (lib.replaceStrings [ "*" "?" ] [ "[^/]*" "[^/]" ])
      (lib.replaceStrings [ gs gsTail ] [ "(.*/)?" "/.*" ])
    ];

  # True when `rel` matches any of the already-translated EREs.
  matchesAny = eres: rel: lib.any (e: builtins.match e rel != null) eres;
}
```

`lib.replaceStrings` makes a single left-to-right pass with all patterns considered together, so the backslash a replacement introduces is not rescanned by a later pattern in the same call. That is why the whole escape table is one call rather than twelve.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0.

If a translation differs from the table, do not change the table to match the code. The table is the spec. Fix the code, or raise an escalation if you believe the table is wrong.

- [ ] **Step 5: Format and commit**

```bash
nix fmt lib/glob.nix tests/glob.nix flake.nix
git add lib/glob.nix tests/glob.nix flake.nix
git commit -m "Add globToERE and its evaluation tests"
```

---

### Task 2: `nd-status`, file records only

Globs come in Task 3. This task moves the existing drift scan into one program and adds the `missing` category (defect 6).

**Files:**
- Create: `packages/nd-status.nix`
- Modify: `flake.nix`
- Modify: `tests/run.sh`

**Interfaces:**
- Produces: an `nd-status` executable. Reads `ND_MANIFEST` (default `$HOME/.local/state/nd/manifest`) and `$HOME`. Writes `<kind>\t<dest>\t<repo_rel>` lines to stdout, `sort -u`'d. Kinds so far: `drifted`, `missing`. Exit 0 whenever the manifest was read; exit 1 only if it is absent.
- Consumed by: Tasks 4 (`nd-switch`), 5 (`nd-save`), 10 (zsh notice).

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`, after the `nd-save` block and before the final summary. First add the runner near the other runners at line 82:

```bash
run_status() { HOME="$1/home" "$ND_STATUS" "${@:2}" 2>&1; }
```

Add `ND_STATUS` to the environment plumbing at the top of the file, mirroring the existing two:

```bash
ND_STATUS="${ND_STATUS:-}"
```

and inside the `if [ -z "$ND_SWITCH" ] ...` fallback block:

```bash
  ND_STATUS="$(nix build --no-link --print-out-paths "$root#nd-status")/bin/nd-status"
```

Extend that block's guard so a missing `ND_STATUS` also triggers the fallback:

```bash
if [ -z "$ND_SWITCH" ] || [ -z "$ND_SAVE" ] || [ -z "$ND_STATUS" ]; then
```

Then the cases:

```bash
echo "nd-status"

d=$(new_fixture)
out=$(run_status "$d")
check_empty "clean fixture reports nothing" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_status "$d")
check "drifted is classified" "drifted	.config/app/config.toml	files/config.toml" "$out"
rm -rf "$d"

d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_status "$d")
check "a deleted file is missing, not drifted" "missing	.config/app/config.toml	files/config.toml" "$out"
check_not "a deleted file is not drift" "drifted" "$out"
rm -rf "$d"

d=$(new_fixture)
out=$(HOME="$d/home" ND_MANIFEST="$d/nope" "$ND_STATUS" 2>&1); st=$?
check "missing manifest is reported" "no manifest" "$out"
check_status "missing manifest exits 1" 1 "$st"
rm -rf "$d"

# Findings are not an error condition. Callers decide what a finding means.
d=$(new_fixture)
drift "$d"
HOME="$d/home" "$ND_STATUS" > /dev/null 2>&1; st=$?
check_status "findings still exit 0" 0 "$st"
rm -rf "$d"
```

The literal tabs in the `check` arguments above must be real tab characters, not spaces. Verify with `grep -P '\t' tests/run.sh` after writing.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run.sh` with `ND_STATUS` unset so it tries to build.
Expected: the `nix build .#nd-status` fallback fails — the package does not exist.

- [ ] **Step 3: Implement `packages/nd-status.nix`**

```nix
{
  writeShellApplication,
  coreutils,
  findutils,
  gnugrep,
}:

# nd-status — classify every managed path the manifest knows about.
#
# One program rather than four. Before this existed, the same scan was written
# in nd-switch, twice in nd-save, and again in the zsh startup notice, and
# adding a category meant editing all four consistently.
#
# Output is <kind> TAB <dest relative to $HOME> TAB <path relative to the flake
# repo root>, passed through `sort -u`. Exit status is 0 whenever the manifest
# was read, findings or not: classifying is this program's job, and deciding
# what a finding means belongs to its callers.
writeShellApplication {
  name = "nd-status";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
  ];
  text = ''
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"

    case "''${1:-}" in
      -h | --help)
        echo "usage: nd-status"
        echo "  Classifies managed paths as drifted, missing or new."
        echo "  Prints: <kind> TAB <path under \$HOME> TAB <path under the repo root>"
        exit 0
        ;;
      "") ;;
      *)
        echo "nd-status: unknown argument: $1" >&2
        exit 1
        ;;
    esac

    if [ ! -f "$manifest" ]; then
      echo "nd-status: no manifest at $manifest — has a switch run yet?" >&2
      exit 1
    fi

    tab="$(printf '\t')"

    scan() {
      local src dest repo_rel kind pattern
      while IFS="$tab" read -r src dest repo_rel kind pattern; do
        if [ -z "''${dest:-}" ]; then
          continue
        fi
        case "''${kind:-}" in
          glob)
            : # Task 3.
            ;;
          *)
            if [ ! -e "$HOME/$dest" ]; then
              printf 'missing\t%s\t%s\n' "$dest" "$repo_rel"
            elif ! cmp -s "$src" "$HOME/$dest"; then
              printf 'drifted\t%s\t%s\n' "$dest" "$repo_rel"
            fi
            ;;
        esac
      done < "$manifest"
    }

    scan | sort -u
  '';
}
```

Add to `flake.nix`, in the `packages` set and in `default`'s `paths`:

```nix
        nd-status = pkgs.callPackage ./packages/nd-status.nix { };
```

```nix
          paths = [
            nd-switch
            nd-save
            nd-status
          ];
```

And in the `tests` check, export it:

```nix
            export ND_STATUS="${self.packages.${system}.nd-status}/bin/nd-status"
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0, and the suite prints the new `nd-status` block with every case `ok`.

Note the shellcheck hazard: `pattern` is assigned by `read` and unused in this task. shellcheck does not warn on unused `read` targets, but if it does on your version, keep the variable and add a `: "''${pattern:-}"` line rather than dropping it — Task 3 needs it.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-status.nix flake.nix
git add packages/nd-status.nix flake.nix tests/run.sh
git commit -m "Add nd-status, and report deleted managed files as missing"
```

---

### Task 3: `nd-status` glob records

**Files:**
- Modify: `packages/nd-status.nix`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: manifest glob records, `<store root>\t<dest root>\t<repo root>\tglob\t<ERE>`, written by Task 8. This task writes them by hand in fixtures.
- Produces: the `new` kind.

- [ ] **Step 1: Write the failing tests**

Add a second fixture builder next to `new_fixture` in `tests/run.sh`:

```bash
# A $HOME with a glob-tracked root: two placed files, a manifest carrying both
# file records and a glob record, and a git repo acting as the flake.
#
# The ERE in the manifest is what globToERE produces for "**/*.lua" — the
# manifest carries regexes, not globs, so the shell never parses a glob.
new_glob_fixture() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/home/.local/state/nd" "$d/home/.config/nv/lua" \
           "$d/repo/files/nv/lua" "$d/store/lua"

  printf 'return 1\n' > "$d/store/init.lua"
  printf 'return 2\n' > "$d/store/lua/plug.lua"
  chmod 0444 "$d/store/init.lua" "$d/store/lua/plug.lua"

  install -m 0644 "$d/store/init.lua"     "$d/home/.config/nv/init.lua"
  install -m 0644 "$d/store/lua/plug.lua" "$d/home/.config/nv/lua/plug.lua"
  install -m 0644 "$d/store/init.lua"     "$d/repo/files/nv/init.lua"
  install -m 0644 "$d/store/lua/plug.lua" "$d/repo/files/nv/lua/plug.lua"
  printf '{}\n' > "$d/repo/flake.nix"

  {
    printf '%s\t%s\t%s\n' "$d/store/init.lua"     ".config/nv/init.lua"     "files/nv/init.lua"
    printf '%s\t%s\t%s\n' "$d/store/lua/plug.lua" ".config/nv/lua/plug.lua" "files/nv/lua/plug.lua"
    printf '%s\t%s\t%s\t%s\t%s\n' "$d/store" ".config/nv" "files/nv" "glob" '(.*/)?[^/]*\.lua'
    printf '%s\t%s\t%s\t%s\t%s\n' "$d/store" ".config/nv" "files/nv" "glob" 'lazy-lock\.json'
  } > "$d/home/.local/state/nd/manifest"

  git -C "$d/repo" init -q -b main
  git -C "$d/repo" config user.email t@example.com
  git -C "$d/repo" config user.name Test
  git -C "$d/repo" add -A
  git -C "$d/repo" commit -qm initial
  printf '%s' "$d"
}
```

Then the cases, in the `nd-status` block:

```bash
d=$(new_glob_fixture)
out=$(run_status "$d")
check_empty "glob fixture with no extra files reports nothing" "$out"
rm -rf "$d"

# The whole point of defect 7: a file the application invented.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_status "$d")
check "an app-created file is new" "new	.config/nv/lazy-lock.json	files/nv/lazy-lock.json" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf 'return 3\n' > "$d/home/.config/nv/lua/extra.lua"
out=$(run_status "$d")
check "a new file in a subdirectory is found" "new	.config/nv/lua/extra.lua	files/nv/lua/extra.lua" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf 'junk\n' > "$d/home/.config/nv/notes.txt"
out=$(run_status "$d")
check_not "a file matching no pattern is ignored" "notes.txt" "$out"
rm -rf "$d"

# A placed file is inside the glob root and matches the pattern. It is already
# tracked; reporting it as new would make every switch look like a capture.
d=$(new_glob_fixture)
out=$(run_status "$d")
check_not "a placed file inside the root is never new" "new	.config/nv/init.lua" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
drift_glob() { printf 'return 99\n' > "$1/home/.config/nv/init.lua"; }
drift_glob "$d"
out=$(run_status "$d")
check "a placed file inside the root still drifts" "drifted	.config/nv/init.lua	files/nv/init.lua" "$out"
rm -rf "$d"

# Two patterns could both match one file. It must be reported once.
d=$(new_glob_fixture)
printf '%s\t%s\t%s\t%s\t%s\n' "$d/store" ".config/nv" "files/nv" "glob" '(.*/)?extra\.lua' \
  >> "$d/home/.local/state/nd/manifest"
printf 'return 3\n' > "$d/home/.config/nv/lua/extra.lua"
out=$(run_status "$d" | grep -c 'extra.lua')
check "a file matching two patterns is emitted once" "1" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
ln -s /etc/hosts "$d/home/.config/nv/link.lua"
mkdir -p "$d/home/.config/nv/dir.lua"
out=$(run_status "$d")
check_not "a symlink under the root is skipped" "link.lua" "$out"
check_not "a directory under the root is skipped" "dir.lua" "$out"
rm -rf "$d"

# The output format is line-based and cannot represent this. Skipping loudly
# beats emitting a line every consumer parses as two.
d=$(new_glob_fixture)
touch "$d/home/.config/nv/$(printf 'we\nird').lua"
out=$(run_status "$d")
check "a path with a newline is skipped with a warning" "skipping path with a newline" "$out"
check_not "a path with a newline is not emitted" "new	.config/nv/we" "$out"
rm -rf "$d"

# A glob root the application has not created yet is not an error.
d=$(new_glob_fixture)
rm -rf "$d/home/.config/nv"
out=$(run_status "$d"); st=$?
check_status "an absent glob root exits 0" 0 "$st"
check "an absent glob root reports its files missing" "missing	.config/nv/init.lua" "$out"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: the new-file cases FAIL — `scan` currently does nothing for `glob` records.

- [ ] **Step 3: Implement the glob branch**

Replace the `glob)` case body and add `scan_glob` above `scan` in `packages/nd-status.nix`. Also add the `placed` computation between the manifest check and `scan`:

```sh
    # Every destination the manifest places explicitly. A placed file is never
    # "new" however many glob patterns also happen to match it — otherwise every
    # managed file inside a glob root would be reported on every run.
    #
    # cut's default delimiter is tab, which is the manifest's.
    placed="$(cut -f2 "$manifest")"

    scan_glob() {
      local root="$1" repo_root="$2" ere="$3"
      local f rel
      if [ ! -d "$HOME/$root" ]; then
        return 0
      fi
      while IFS= read -r -d "" f; do
        rel="''${f#"$HOME/$root/"}"
        # The output is line-based, and so is the membership test below. A path
        # containing a newline cannot be represented in either, so it is skipped
        # rather than emitted as something both would misparse.
        if [ "''${rel%%$'\n'*}" != "$rel" ]; then
          echo "nd-status: skipping path with a newline under $root" >&2
          continue
        fi
        if ! printf '%s' "$rel" | grep -qxE "$ere"; then
          continue
        fi
        if printf '%s\n' "$placed" | grep -qxF "$root/$rel"; then
          continue
        fi
        printf 'new\t%s\t%s\n' "$root/$rel" "$repo_root/$rel"
      done < <(find "$HOME/$root" -type f -print0)
    }
```

and in `scan`:

```sh
          glob)
            scan_glob "$dest" "$repo_rel" "$pattern"
            ;;
```

`find -type f` is false for a symlink, a directory, a socket and a FIFO, which is the whole of the skip list. The walk uses `-print0` with `read -r -d ""` so it does not mis-split on a newline before the check above can catch it.

`scan_glob` reads from a process substitution, not from stdin, so it does not consume the manifest that `scan`'s own `while` loop is reading.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-status.nix
git add packages/nd-status.nix tests/run.sh
git commit -m "Report files an application created under a glob root as new"
```

---

### Task 4: `nd-switch` consumes `nd-status`

**Files:**
- Modify: `packages/nd-switch.nix:106-126`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `nd-status` on `PATH` via `runtimeInputs`.

- [ ] **Step 1: Write the failing tests**

In the `nd-switch` block of `tests/run.sh`:

```bash
# Defect 6. A deletion is not drift and must not block, but it must be said.
# The fixture's flake.nix is a stub, so nd-switch --build reaches `nix build`
# and fails there; the assertion is on the absence of the block, not the exit
# status. Every existing --build case has the same shape.
d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_switch "$d" --build)
check "a missing file is named" "will be restored" "$out"
check "a missing file names the path" ".config/app/config.toml" "$out"
check_not "a missing file does not block" "changed since they were placed" "$out"
rm -rf "$d"

# A new file cannot be overwritten by a switch — there is nothing in the store
# to overwrite it with — so the gate has nothing to protect and must not fire.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_switch "$d" --build)
check "a new file is named" "not yet in the repo" "$out"
check "a new file names the path" "lazy-lock.json" "$out"
check_not "a new file does not block" "changed since they were placed" "$out"
rm -rf "$d"

# --allow-dirty suppresses the block, not the reports.
d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_switch "$d" --build --allow-dirty)
check "--allow-dirty still reports missing" "will be restored" "$out"
rm -rf "$d"
```

`run_switch` needs `ND_FLAKE` pointing at the glob fixture's repo, which it already does.

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: the `will be restored` and `not yet in the repo` cases FAIL.

- [ ] **Step 3: Replace the scan block**

In `packages/nd-switch.nix`, change the header to take `nd-status` and `gnused`:

```nix
{
  writeShellApplication,
  coreutils,
  gnused,
  gnugrep,
  nd-status,
}:
```

```nix
  runtimeInputs = [
    coreutils
    gnused
    gnugrep
    nd-status
  ];
```

Replace lines 106–126 (the `if [ -z "$allow_dirty" ] && [ -f "$manifest" ]; then ... fi` block) with:

```sh
    # Refuse to place over config an application rewrote. The comparison is
    # against the store path the current generation installed, not against the
    # repo: comparing to the repo cannot tell "the app changed this file" from
    # "I edited the repo and want to place it", and would refuse exactly the
    # switch you meant to run. nd-status owns that comparison.
    #
    # Only `drifted` blocks. A `missing` file will be restored by the switch and
    # a `new` file has no store source to be overwritten by, so neither has
    # anything for the gate to protect — but both are reported, because
    # restoring a file somebody deleted on purpose without saying so is the
    # behaviour defect 6 is about.
    if [ -f "$manifest" ]; then
      status="$(nd-status)"

      drifted="$(printf '%s\n' "$status" | grep '^drifted' | cut -f2 || true)"
      missing="$(printf '%s\n' "$status" | grep '^missing' | cut -f2 || true)"
      created="$(printf '%s\n' "$status" | grep '^new' | cut -f2 || true)"

      if [ -n "$missing" ]; then
        echo "nd-switch: these managed files are gone and will be restored:" >&2
        printf '%s\n' "$missing" | sed 's/^/  /' >&2
      fi

      if [ -n "$created" ]; then
        echo "nd-switch: these files are not yet in the repo:" >&2
        printf '%s\n' "$created" | sed 's/^/  /' >&2
        echo "nd-switch: run 'nd-save' to capture them." >&2
      fi

      if [ -z "$allow_dirty" ] && [ -n "$drifted" ]; then
        echo "nd-switch: these files changed since they were placed:" >&2
        printf '%s\n' "$drifted" | sed 's/^/  /' >&2
        echo "nd-switch: switching would overwrite them." >&2
        echo "nd-switch: run 'nd-save' to copy them back and commit, or --allow-dirty to discard" >&2
        exit 1
      fi
    fi
```

The `|| true` on each pipeline is required: `grep` exits 1 when it matches nothing, and `pipefail` plus `errexit` would take that as a fatal error.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0. Every pre-existing `nd-switch` case still passes — in particular `clean tree does not report drift`, `drift is detected`, `drift exits 1` and `--allow-dirty skips the gate`, which are the behaviours the whole design rests on.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-switch.nix
git add packages/nd-switch.nix tests/run.sh
git commit -m "Report missing and new files from nd-switch without blocking on them"
```

---

### Task 5: `nd-save` — scope git operations to what was copied (defect 1)

The largest task. It restructures `nd-save` around `nd-status` and fixes the data-leak defect. Defects 2, 3 and 4 land in Tasks 6–8 on top of this structure.

**Files:**
- Modify: `packages/nd-save.nix` (rewritten)
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `nd-status` on `PATH`.
- Produces: `--force` and `--branch NAME` flags are parsed here but not yet honoured; Tasks 6 and 7 add their behaviour. Parsing them now avoids three rewrites of the argument loop.

- [ ] **Step 0: Verify the git incantation before writing it**

`git commit --only -- <path>` rejects a pathspec git does not know, and a newly captured file is untracked. The plan assumes `git add --intent-to-add` then `git add` then `git commit --only` works. Verify rather than assume:

```bash
set -e
d=$(mktemp -d); cd "$d"
git init -q -b main; git config user.email t@e.com; git config user.name T
echo one > tracked.txt; echo other > unrelated.txt
git add -A; git commit -qm initial
echo changed > unrelated.txt; git add unrelated.txt   # staged, must NOT be committed
echo two > tracked.txt                                # managed, must be committed
echo new > created.txt                                # managed and untracked
git add -N -- tracked.txt created.txt
git --no-pager diff HEAD --stat -- tracked.txt created.txt
git add -- tracked.txt created.txt
git commit -q --only -m "scoped" -- tracked.txt created.txt
echo "--- files in commit ---"; git show --stat --format= HEAD
echo "--- still staged ---";    git diff --cached --name-only
```

Expected: the commit contains `tracked.txt` and `created.txt` only, and `unrelated.txt` is still listed as staged. If `commit --only` errors on the intent-to-add entry, or sweeps in `unrelated.txt`, **raise an escalation** with the exact output and stop — the alternatives are `git stash push --staged` around the commit, or building the commit with `git commit-tree` against a scratch index via `GIT_INDEX_FILE`, and choosing between them is a judgement call.

- [ ] **Step 1: Write the failing tests**

Replace the existing `only the managed file is committed` case at `tests/run.sh:155`. It passes vacuously today because the fixture never stages anything else.

```bash
# Defect 1. `git commit` with no pathspec commits everything already in the
# index, so anything the user staged beforehand lands in a commit whose message
# says it is application-written config. The fixture must therefore contain
# something else, staged.
d=$(new_fixture)
printf 'unrelated\n' > "$d/repo/other.txt"
git -C "$d/repo" add other.txt
git -C "$d/repo" commit -qm "add other"
printf 'half-finished edit\n' > "$d/repo/other.txt"
git -C "$d/repo" add other.txt
drift "$d"
out=$(run_save "$d" -y)
check "the commit touches the managed file" "files/config.toml" "$(git -C "$d/repo" show --stat --format= HEAD)"
check_not "the commit does not touch the staged file" "other.txt" "$(git -C "$d/repo" show --stat --format= HEAD)"
check "the unrelated edit is still staged" "other.txt" "$(git -C "$d/repo" diff --cached --name-only)"
check "the unrelated edit is still uncommitted" "half-finished edit" "$(cat "$d/repo/other.txt")"
rm -rf "$d"

# The preview showed every unrelated unstaged edit and hid every staged one —
# precisely the content the unscoped commit was about to sweep in.
d=$(new_fixture)
printf 'noise\n' > "$d/repo/noise.txt"
git -C "$d/repo" add noise.txt
git -C "$d/repo" commit -qm "add noise"
printf 'unstaged noise\n' > "$d/repo/noise.txt"
drift "$d"
out=$(run_save "$d" -y)
check_not "the preview excludes unrelated edits" "unstaged noise" "$out"
check "the preview includes the managed change" "setting = 2" "$out"
rm -rf "$d"

# A repository-wide `git status` answered "is the repo clean" when the question
# was "did the copies change anything", so an unrelated edit made nd-save
# proceed past an exit it should have taken.
d=$(new_fixture)
printf 'noise\n' > "$d/repo/noise.txt"
git -C "$d/repo" add noise.txt
git -C "$d/repo" commit -qm "add noise"
printf 'unstaged noise\n' > "$d/repo/noise.txt"
# The live file differs from the store but matches what is already committed,
# so there is genuinely nothing to commit.
printf 'setting = 1\n' > "$d/home/.config/app/config.toml"
touch "$d/home/.config/app/config.toml"
out=$(run_save "$d" -y)
check "an unrelated edit does not make nd-save commit" "nothing to save" "$out"
check "no commit was made" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"
```

The third case relies on the file being byte-identical to the store, so `nd-status` reports nothing and `nd-save` exits at "nothing to save". If you need a case where the file drifts but the copy matches HEAD, drift the live file *and* commit the same content to the repo first.

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: `the commit does not touch the staged file` and `the unrelated edit is still staged` FAIL.

- [ ] **Step 3: Rewrite `packages/nd-save.nix`**

```nix
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  nd-status,
}:

# nd-save — copy application-written config back into the repo and commit it.
#
# Reads the manifest that the home-manager module writes at activation, by way
# of nd-status, which owns the classification. A file differs from its store
# source exactly when something rewrote it after it was placed; a file under a
# glob root with no store source at all is something the application created.
# Both are saved. A file that is simply gone is reported and skipped.
#
# git is not in runtimeInputs on purpose: it is taken from the caller's PATH so
# the closure does not carry a second git, and the flake check supplies one.
writeShellApplication {
  name = "nd-save";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    gawk
    nd-status
  ];
  text = ''
    flake="''${ND_FLAKE:-$HOME/.config/nix-darwin}"
    manifest="''${ND_MANIFEST:-$HOME/.local/state/nd/manifest}"
    msg=""
    assume_yes=""
    force=""

    while [ $# -gt 0 ]; do
      case "$1" in
        -m)
          shift
          msg="''${1:-}"
          shift || true
          ;;
        -y | --yes)
          assume_yes=1
          shift
          ;;
        --force)
          force=1
          shift
          ;;
        -h | --help)
          echo "usage: nd-save [-m MESSAGE] [-y] [--force]"
          echo "  Copies config that applications rewrote back into the flake repo,"
          echo "  then commits it. Never pushes."
          echo "  --force  overwrite repo files that carry edits never placed"
          exit 0
          ;;
        *)
          echo "nd-save: unknown argument: $1" >&2
          exit 1
          ;;
      esac
    done

    if [ ! -f "$manifest" ]; then
      echo "nd-save: no manifest at $manifest — has a switch run yet?" >&2
      exit 1
    fi

    if ! git -C "$flake" rev-parse --git-dir > /dev/null 2>&1; then
      echo "nd-save: $flake is not a git repository" >&2
      exit 1
    fi

    tab="$(printf '\t')"
    status="$(nd-status)"

    missing="$(printf '%s\n' "$status" | grep '^missing' | cut -f2 || true)"
    candidates="$(printf '%s\n' "$status" | grep -E '^(drifted|new)' || true)"

    if [ -n "$missing" ]; then
      echo "nd-save: these managed files are gone; there is nothing to save for them:"
      printf '%s\n' "$missing" | sed 's/^/  /'
      echo "nd-save: the next switch will restore them."
      echo
    fi

    if [ -z "$candidates" ]; then
      echo "nd-save: nothing to save, every placed file still matches"
      exit 0
    fi

    # Scan BEFORE copying. Applications write credentials into their own config
    # as a matter of course, and the flake repo may be shared. Copying first and
    # refusing afterwards would leave the secret in the working tree for someone
    # to commit later by accident.
    secrets=""
    while IFS="$tab" read -r _kind dest _repo_rel; do
      if [ -z "''${dest:-}" ]; then
        continue
      fi
      if grep -inE '(ghp_|gho_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|"?(api_?key|secret|password|token)"?[[:space:]]*[:=])' "$HOME/$dest" > /dev/null; then
        secrets="$secrets$dest
    "
      fi
    done < <(printf '%s\n' "$candidates")

    if [ -n "$secrets" ]; then
      echo "nd-save: credential-shaped content in these files, nothing copied:" >&2
      printf '%s' "$secrets" | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '  %s\n' "$line" >&2
        fi
      done
      echo "nd-save: remove it, or copy and stage by hand with git add -p" >&2
      exit 1
    fi

    copied=""
    paths=()
    while IFS="$tab" read -r kind dest repo_rel; do
      if [ -z "''${dest:-}" ]; then
        continue
      fi
      dir="$(dirname "$flake/$repo_rel")"
      case "$kind" in
        new)
          # A file the application invented has no repo counterpart yet, and its
          # parent may not exist either.
          mkdir -p "$dir"
          ;;
        *)
          # A declared file's directory always exists; if it does not, repoSubdir
          # disagrees with sourceDir and creating it would hide that.
          if [ ! -d "$dir" ]; then
            echo "nd-save: no such directory in the repo: $(dirname "$repo_rel")" >&2
            exit 1
          fi
          ;;
      esac
      # 0644 is deliberate, not an oversight. See the comment in
      # modules/home-manager.nix on why per-file modes are not offered.
      install -m 0644 "$HOME/$dest" "$flake/$repo_rel"
      copied="$copied$dest
    "
      paths+=("$repo_rel")
    done < <(printf '%s\n' "$candidates")

    echo "nd-save: copied back into the repo"
    printf '%s' "$copied" | while IFS= read -r line; do
      if [ -n "$line" ]; then
        printf '  %s\n' "$line"
      fi
    done
    echo

    # Every git operation below takes a pathspec. Unscoped, they each answered
    # the wrong question: `status` answered "is the repository clean" rather
    # than "did the copies change anything"; `diff -- .` showed every unrelated
    # unstaged edit and hid every staged one; and a bare `commit` swept the
    # whole index into a commit whose message says it is application-written
    # config. The repo may be shared, so that is a data leak, not a private
    # mistake.
    #
    # --intent-to-add makes a newly captured file visible to `diff HEAD`, which
    # otherwise shows nothing for an untracked path, and makes it a pathspec
    # `commit --only` will accept.
    git -C "$flake" add --intent-to-add -- "''${paths[@]}"

    if [ -z "$(git -C "$flake" status --porcelain -- "''${paths[@]}")" ]; then
      echo "nd-save: copies are identical to the committed versions, nothing to commit"
      exit 0
    fi

    echo "nd-save: changes"
    git -C "$flake" --no-pager diff HEAD -- "''${paths[@]}"
    echo

    branch="$(git -C "$flake" branch --show-current)"
    echo "nd-save: will commit to branch '$branch'"

    if [ -z "$assume_yes" ]; then
      printf "nd-save: proceed? [y/N] "
      read -r reply
      case "$reply" in
        y | Y) ;;
        *)
          echo "nd-save: aborted. Files were copied into the repo but nothing was committed."
          exit 1
          ;;
      esac
    fi

    if [ -z "$msg" ]; then
      msg="Update config written by applications"
    fi

    git -C "$flake" add -- "''${paths[@]}"
    git -C "$flake" commit --only -m "$msg" -- "''${paths[@]}"
    echo "nd-save: committed. Not pushed."
  '';
}
```

`force` is assigned and unused in this task. shellcheck warns SC2034 on unused variables. If the build fails on it, add `: "$force"` immediately after the argument loop with a comment saying Task 6 consumes it, rather than deleting the flag.

Update `flake.nix` so `nd-save` and `nd-switch` receive `nd-status`. `callPackage` resolves it automatically once `nd-status` is in the same `rec` set — confirm the `packages` attribute set is `rec` (it is) and that `nd-status` is defined before use.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0. All pre-existing `nd-save` cases must still pass, especially `declining aborts`, `declining leaves the commit unmade` and the three credential cases.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-save.nix flake.nix
git add packages/nd-save.nix flake.nix tests/run.sh
git commit -m "Scope nd-save's git operations to the files it copied"
```

---

### Task 6: `nd-save` — refuse to overwrite an unplaced repo edit (defect 2)

**Files:**
- Modify: `packages/nd-save.nix`
- Modify: `tests/run.sh`

- [ ] **Step 1: Write the failing tests**

```bash
# Defect 2. Three versions of a managed file exist: the store source, the live
# file, and the repo working tree. nd-save compared only the first two before
# overwriting the third, so an edit made in the repo and not yet placed was
# destroyed with no warning, no backup, and no mention in the preview — the
# preview is computed after the copy, so it showed the app's content as though
# it were the only change.
d=$(new_fixture)
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y); st=$?
check "an unplaced repo edit is refused" "never placed" "$out"
check "the refusal names the file" "files/config.toml" "$out"
check_status "the refusal exits 1" 1 "$st"
check "the repo edit survives" "my unplaced edit" "$(cat "$d/repo/files/config.toml")"
check "nothing was committed" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# --force is the escape hatch. It must overwrite, because that is what it says.
d=$(new_fixture)
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/files/config.toml"
drift "$d"
out=$(run_save "$d" -y --force)
check "--force overwrites" "copied back into the repo" "$out"
check "--force really overwrote" "setting = 2" "$(cat "$d/repo/files/config.toml")"
rm -rf "$d"

# The related bug at the old :126-128: every manifest entry whose repo file
# existed was staged, so an uncommitted edit to a managed file that had NOT
# drifted was committed anyway.
d=$(new_fixture)
printf 'setting = 3 # my unplaced edit\n' > "$d/repo/files/config.toml"
out=$(run_save "$d" -y)
check "an undrifted file with a repo edit is not committed" "nothing to save" "$out"
check "the repo edit survives" "my unplaced edit" "$(cat "$d/repo/files/config.toml")"
check "nothing was committed" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# The rule is conditional. "Repo differs from store" is meaningless for a file
# the app just invented, which has no store source at all — for those the
# question is whether the repo already has a file there.
d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_save "$d" -y)
check "a new capture with no repo counterpart proceeds" "copied back into the repo" "$out"
check "the new file lands in the repo" '"plug":"abc"' "$(cat "$d/repo/files/nv/lazy-lock.json")"
rm -rf "$d"

d=$(new_glob_fixture)
printf '{"plug":"abc"}\n' > "$d/home/.config/nv/lazy-lock.json"
printf '{"plug":"mine"}\n' > "$d/repo/files/nv/lazy-lock.json"
out=$(run_save "$d" -y); st=$?
check "a new capture whose repo file exists is refused" "never placed" "$out"
check_status "that refusal exits 1" 1 "$st"
check "the repo file survives" '"plug":"mine"' "$(cat "$d/repo/files/nv/lazy-lock.json")"
rm -rf "$d"

# Parent directories for a capture in a subdirectory the repo does not have.
d=$(new_glob_fixture)
mkdir -p "$d/home/.config/nv/lua/deep"
printf 'return 4\n' > "$d/home/.config/nv/lua/deep/new.lua"
out=$(run_save "$d" -y)
check "a nested capture creates its repo directory" "copied back into the repo" "$out"
check "the nested file lands in the repo" "return 4" "$(cat "$d/repo/files/nv/lua/deep/new.lua")"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: `an unplaced repo edit is refused`, `the repo edit survives` and `a new capture whose repo file exists is refused` FAIL.

- [ ] **Step 3: Add the blocker check**

Insert immediately after the credential-scan block and before `copied=""` in `packages/nd-save.nix`:

```sh
    # Three versions of any managed file exist: the store source, the live file
    # in $HOME, and the file in the repo working tree. Drift is a difference
    # between the first two. If the third also differs from the store, the repo
    # carries an edit that has not been placed yet, and copying over it destroys
    # work that nd-save never even showed you — the preview is computed after
    # the copy.
    #
    # nd-switch gets the analogous case right and documents why: it compares
    # against the store, not the repo, because comparing to the repo cannot
    # distinguish "the app changed this" from "I edited the repo and want to
    # place it". This is the same three-way awareness on the save side.
    #
    # The rule is conditional on purpose. "The repo differs from the store" is
    # the right question for a declared file and a meaningless one for a file
    # the application just invented, which has no store source at all — for
    # those the question is whether the repo already holds a file there.
    blockers=""
    while IFS="$tab" read -r kind dest repo_rel; do
      if [ -z "''${dest:-}" ]; then
        continue
      fi
      case "$kind" in
        new)
          if [ -e "$flake/$repo_rel" ]; then
            blockers="$blockers$repo_rel (already in the repo, never placed)
    "
          fi
          ;;
        *)
          src="$(awk -F'\t' -v d="$dest" '$2 == d && $4 == "" { print $1; exit }' "$manifest")"
          if [ -n "$src" ] && [ -e "$flake/$repo_rel" ] && ! cmp -s "$src" "$flake/$repo_rel"; then
            blockers="$blockers$repo_rel (repo copy differs from what was placed)
    "
          fi
          ;;
      esac
    done < <(printf '%s\n' "$candidates")

    if [ -n "$blockers" ] && [ -z "$force" ]; then
      echo "nd-save: the repo carries edits that were never placed; nothing copied:" >&2
      printf '%s' "$blockers" | while IFS= read -r line; do
        if [ -n "$line" ]; then
          printf '  %s\n' "$line" >&2
        fi
      done
      echo "nd-save: switch first to place them, or re-run with --force to overwrite." >&2
      exit 1
    fi
```

The ordering — credential scan, blocker check, copy — must be preserved. Both refusals happen before any write, so a refused run leaves the working tree untouched. The credential test `repo working tree is untouched` already asserts this for one of them.

Remove the `: "$force"` shellcheck placeholder from Task 5 if you added one.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-save.nix
git add packages/nd-save.nix tests/run.sh
git commit -m "Refuse to overwrite repo edits that were never placed"
```

---

### Task 7: `nd-save` — branch guard (defect 3)

**Files:**
- Modify: `packages/nd-save.nix`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `ND_EXPECTED_BRANCH` from the environment. Task 9 sets it from `programs.nd.expectedBranch`.
- Produces: `--branch NAME`.

- [ ] **Step 1: Write the failing tests**

```bash
# Defect 3. With -y the branch was printed to a terminal nobody is reading and
# the commit proceeded regardless, so the unattended path was the one with no
# check at all.
d=$(new_fixture)
drift "$d"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_EXPECTED_BRANCH=main "$ND_SAVE" -y 2>&1); st=$?
check "the expected branch matching proceeds" "committed" "$out"
check_status "matching exits 0" 0 "$st"
rm -rf "$d"

d=$(new_fixture)
git -C "$d/repo" switch -q -c topic
drift "$d"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_EXPECTED_BRANCH=main "$ND_SAVE" -y 2>&1); st=$?
check "a mismatched branch is refused under -y" "expected 'main'" "$out"
check_status "a mismatched branch exits 1" 1 "$st"
check "nothing was committed" "initial" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

d=$(new_fixture)
git -C "$d/repo" switch -q -c topic
drift "$d"
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_EXPECTED_BRANCH=main "$ND_SAVE" -y --branch topic 2>&1)
check "--branch overrides the environment" "committed" "$out"
rm -rf "$d"

# git branch --show-current prints an empty string on a detached HEAD, which the
# old code reported as branch '' and then committed onto anyway. That commit is
# unreachable the moment anything else is checked out.
d=$(new_fixture)
git -C "$d/repo" checkout -q --detach HEAD
drift "$d"
out=$(run_save "$d" -y); st=$?
check "a detached HEAD is refused" "detached" "$out"
check_status "a detached HEAD exits 1" 1 "$st"
rm -rf "$d"

d=$(new_fixture)
git -C "$d/repo" checkout -q --detach HEAD
drift "$d"
out=$(run_save "$d" -y --branch main --force); st=$?
check "a detached HEAD is refused even with --branch and --force" "detached" "$out"
check_status "that still exits 1" 1 "$st"
rm -rf "$d"

# No constraint set is the existing behaviour: print and prompt, do not refuse.
d=$(new_fixture)
git -C "$d/repo" switch -q -c topic
drift "$d"
out=$(run_save "$d" -y)
check "no constraint means no refusal" "committed" "$out"
check "the branch is still printed" "branch 'topic'" "$out"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: the mismatch and detached-HEAD cases FAIL.

- [ ] **Step 3: Implement the guard**

Add to the variable block at the top of the script:

```sh
    expected_branch="''${ND_EXPECTED_BRANCH:-}"
```

Add to the argument loop, before the `-h` case:

```sh
        --branch)
          shift
          expected_branch="''${1:-}"
          shift || true
          ;;
```

Update the usage text:

```sh
          echo "usage: nd-save [-m MESSAGE] [-y] [--force] [--branch NAME]"
          echo "  Copies config that applications rewrote back into the flake repo,"
          echo "  then commits it. Never pushes."
          echo "  --force        overwrite repo files that carry edits never placed"
          echo "  --branch NAME  require this branch; overrides ND_EXPECTED_BRANCH"
```

Insert immediately after the `rev-parse --git-dir` check, before `tab=` — the guard runs before any work so a refused run does nothing at all:

```sh
    # The branch guard runs before the scan and before any copy. With -y the old
    # code printed the branch to a terminal nobody is reading and committed
    # regardless, so the unattended path — the one -y exists for — was the only
    # path with no check.
    branch="$(git -C "$flake" branch --show-current)"

    if [ -z "$branch" ]; then
      echo "nd-save: HEAD is detached in $flake — refusing." >&2
      echo "nd-save: a commit here becomes unreachable as soon as anything else is checked out." >&2
      echo "nd-save: run 'git switch <branch>' first." >&2
      exit 1
    fi

    if [ -n "$expected_branch" ] && [ "$branch" != "$expected_branch" ]; then
      echo "nd-save: on branch '$branch', expected '$expected_branch' — refusing." >&2
      echo "nd-save: nd-save is prompted by a shell notice rather than by you choosing a" >&2
      echo "nd-save: moment, so app config lands on whatever topic branch happens to be out." >&2
      echo "nd-save: switch branch, or pass --branch '$branch' to commit here anyway." >&2
      exit 1
    fi
```

Delete the later `branch="$(git -C "$flake" branch --show-current)"` line, keeping the `echo "nd-save: will commit to branch '$branch'"` that follows it.

Detached HEAD is refused before `--branch` and `--force` are consulted, which is why the check is first and unconditional.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-save.nix
git add packages/nd-save.nix tests/run.sh
git commit -m "Refuse to commit on an unexpected branch or a detached HEAD"
```

---

### Task 8: `nd-save` — derived commit subjects (defect 4) and the scan comment (defect 5)

**Files:**
- Modify: `packages/nd-save.nix`
- Modify: `tests/run.sh`

**Refinement of the spec:** the spec's derivation says "if the destination starts with `.config/`, the component following it". That yields `starship.toml` for `.config/starship.toml`. This plan truncates every derived token at its first `.` and strips a leading one, so `.config/starship.toml` gives `starship`, `.config/zed/settings.json` gives `zed`, and `.wezterm.lua` gives `wezterm`. Same shape, one uniform rule, strictly better output. Record this in the escalation log as a resolved deviation.

- [ ] **Step 1: Write the failing tests**

```bash
# Defect 4. Every commit said "Update config written by applications", so
# `git log --oneline` told you nothing about which application rewrote what.
d=$(new_fixture)
drift "$d"
run_save "$d" -y > /dev/null
check "a single file names its app" "Save app config written by the app" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
run_save "$d" -y -m "Explicit subject" > /dev/null
check "-m still wins" "Explicit subject" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# Two apps. The fixture gets a second managed file under a different .config
# component.
d=$(new_fixture)
mkdir -p "$d/home/.config/zed" "$d/repo/files/zed"
printf 'a\n' > "$d/store-source-2"
chmod 0444 "$d/store-source-2"
install -m 0644 "$d/store-source-2" "$d/home/.config/zed/settings.json"
install -m 0644 "$d/store-source-2" "$d/repo/files/zed/settings.json"
printf '%s\t%s\t%s\n' "$d/store-source-2" ".config/zed/settings.json" "files/zed/settings.json" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A; git -C "$d/repo" commit -qm "add zed"
drift "$d"
printf 'b\n' > "$d/home/.config/zed/settings.json"
run_save "$d" -y > /dev/null
check "two apps are both named" "Save config written by app and zed" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# A destination outside .config/ derives from the basename.
d=$(new_fixture)
printf 'x\n' > "$d/store-source-3"
chmod 0444 "$d/store-source-3"
install -m 0644 "$d/store-source-3" "$d/home/.wezterm.lua"
install -m 0644 "$d/store-source-3" "$d/repo/files/wezterm.lua"
printf '%s\t%s\t%s\n' "$d/store-source-3" ".wezterm.lua" "files/wezterm.lua" \
  >> "$d/home/.local/state/nd/manifest"
git -C "$d/repo" add -A; git -C "$d/repo" commit -qm "add wezterm"
printf 'y\n' > "$d/home/.wezterm.lua"
run_save "$d" -y > /dev/null
check "a dotfile outside .config derives its name" "Save wezterm config written by the app" "$(git -C "$d/repo" log -1 --format=%s)"
rm -rf "$d"

# Defect 5 negatives. These must NOT trip the scan. They exist so a future
# entropy check cannot land without proving it does not break them.
for benign in \
  '{"red": "#ff0044", "green": "#00ff88", "blue": "#0044ff"}' \
  '{"id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"}' \
  '{"icon": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="}'; do
  d=$(new_fixture)
  printf '%s\n' "$benign" > "$d/home/.config/app/config.toml"
  out=$(run_save "$d" -y); st=$?
  check_not "benign content is not a credential: ${benign:0:22}" "credential-shaped content" "$out"
  check_status "benign content exits 0" 0 "$st"
  rm -rf "$d"
done
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: the four subject cases FAIL. The three benign cases should already pass — if one does not, the regex has a false positive the spec did not anticipate; raise an escalation rather than weakening the regex.

- [ ] **Step 3: Implement the derivation**

Add two functions above the argument loop in `packages/nd-save.nix`:

```sh
    # The application a destination belongs to, derived rather than looked up. A
    # lookup table of application names goes stale the first time a file is
    # added, and a wrong name in a commit subject is worse than a lower-case
    # one — so this stays unprettified: "zed", not "Zed"; "wezterm", not
    # "WezTerm".
    app_of() {
      local dest="$1" token
      case "$dest" in
        .config/*)
          token="''${dest#.config/}"
          token="''${token%%/*}"
          ;;
        *)
          token="$(basename "$dest")"
          ;;
      esac
      token="''${token#.}"
      printf '%s' "''${token%%.*}"
    }

    derive_subject() {
      local apps n list head tail
      apps="$(printf '%s' "$copied" | sed '/^[[:space:]]*$/d' | while IFS= read -r d; do
        app_of "$(printf '%s' "$d" | sed 's/^[[:space:]]*//')"
        printf '\n'
      done | sort -u)"

      n="$(printf '%s\n' "$apps" | sed '/^$/d' | wc -l | tr -d ' ')"

      if [ "$n" -le 1 ]; then
        printf 'Save %s config written by the app' "$apps"
        return 0
      fi

      list="$(printf '%s\n' "$apps" | sed '/^$/d' | paste -sd'|' - | sed 's/|/, /g')"
      head="''${list%, *}"
      tail="''${list##*, }"
      printf 'Save config written by %s and %s' "$head" "$tail"
    }
```

The `sed 's/^[[:space:]]*//'` is needed because `copied` accumulates lines with the indentation the Nix indented string leaves on the continuation. If you restructure `copied` to avoid that indentation, drop the `sed` — but then check every other consumer of `copied`.

Replace the default-message block:

```sh
    if [ -z "$msg" ]; then
      msg="$(derive_subject)"
    fi
```

Add the scan-policy comment above the credential `grep`, extending the existing "Scan BEFORE copying" comment:

```sh
    # The pattern list is deliberately not an entropy check, and this is a
    # decision rather than an omission. Entropy scoring on application config
    # false-positives on exactly what these files are full of — hashes, UUIDs,
    # base64 icons, colour tables, minified snippets — and a scanner that cries
    # wolf gets switched off within a week, at which point it is worse than no
    # scanner because it is still trusted and now silent. This catches known key
    # prefixes and suspiciously named assignments and nothing else; it is a
    # backstop, not a guarantee. tests/run.sh pins three benign shapes that must
    # never trip it, so a future entropy check cannot land without proving it
    # does not break them.
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0.

- [ ] **Step 5: Commit**

```bash
nix fmt packages/nd-save.nix
git add packages/nd-save.nix tests/run.sh
git commit -m "Name the applications that changed in the default commit subject"
```

---

### Task 9: The `globs` option and manifest v2

**Files:**
- Modify: `modules/home-manager.nix`

**Interfaces:**
- Consumes: `globToERE` from `lib/glob.nix` (Task 1).
- Produces: manifest records in the format `nd-status` (Tasks 2, 3) already reads.

- [ ] **Step 1: Add the option and the enumeration**

Add to the `let` block at the top of `modules/home-manager.nix`:

```nix
  globLib = import ../lib/glob.nix { inherit lib; };

  # A glob entry contributes ordinary file records for everything that matches
  # in the repo right now, plus one glob record per pattern so nd-status can
  # recognise files the application creates later. Placement and drift detection
  # are therefore byte-for-byte the same code path as a declared file; globs add
  # discovery of files that do not exist yet, and nothing else.
  globFileRecords =
    destRoot: g:
    let
      root = cfg.sourceDir + "/${g.source}";
      eres = map globLib.globToERE g.patterns;
      relOf = p: lib.removePrefix "${toString root}/" (toString p);
    in
    map
      (p: {
        dest = "${destRoot}/${relOf p}";
        src = p;
        repoRel = "${cfg.repoSubdir}/${g.source}/${relOf p}";
      })
      (lib.filter (p: globLib.matchesAny eres (relOf p)) (lib.filesystem.listFilesRecursive root));

  globPatternRecords =
    destRoot: g:
    map (p: {
      srcRoot = cfg.sourceDir + "/${g.source}";
      inherit destRoot;
      repoRoot = "${cfg.repoSubdir}/${g.source}";
      ere = globLib.globToERE p;
    }) g.patterns;

  fileRecords =
    lib.mapAttrsToList (dest: rel: {
      inherit dest;
      src = cfg.sourceDir + "/${rel}";
      repoRel = "${cfg.repoSubdir}/${rel}";
    }) cfg.files
    ++ lib.concatLists (lib.mapAttrsToList globFileRecords cfg.globs);

  patternRecords = lib.concatLists (lib.mapAttrsToList globPatternRecords cfg.globs);

  # Field 4 is the record kind; absent means "file", so the three-field lines a
  # previous generation wrote keep parsing.
  manifestText = lib.concatStrings (
    map (f: "${f.src}\t${f.dest}\t${f.repoRel}\n") fileRecords
    ++ map (g: "${g.srcRoot}\t${g.destRoot}\t${g.repoRoot}\tglob\t${g.ere}\n") patternRecords
  );
```

Add the option after `files`:

```nix
    globs = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            source = mkOption {
              type = types.str;
              example = "nvim";
              description = "Directory holding the matching files, relative to {option}`sourceDir`.";
            };
            patterns = mkOption {
              type = types.listOf types.str;
              example = [
                "init.lua"
                "lua/**/*.lua"
                "lazy-lock.json"
              ];
              description = ''
                Glob patterns, relative to both {option}`source` and the
                destination root. Required: there is deliberately no default,
                because a default of `[ "**" ]` would be whole-directory
                tracking wearing a glob's clothes.

                Supported syntax is `**/` (zero or more directories), a trailing
                `/**` (everything below), `*` (within one component) and `?`.
                Bracket expressions and brace expansion are not supported and
                match literally.
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          ".config/nvim" = {
            source = "nvim";
            patterns = [ "init.lua" "lua/**/*.lua" "lazy-lock.json" ];
          };
        }
      '';
      description = ''
        Managed file *sets*, keyed by destination root relative to `$HOME`.

        Everything matching is placed exactly as {option}`files` entries are. In
        addition, a file that appears under the destination root later and
        matches a pattern — the canonical case being lazy.nvim rewriting
        `lazy-lock.json` on every plugin update — is reported by `nd-status` as
        new and captured by `nd-save`, after which the next evaluation places it
        like any other managed file.

        Only what a pattern names is ever captured. This is an allowlist on
        purpose: a managed *directory* would need an ignore list maintained
        against an application you do not control.
      '';
    };
```

Extend the assertion:

```nix
    assertions = [
      {
        assertion = (cfg.files == { } && cfg.globs == { }) || cfg.repoSubdir != "";
        message = "programs.nd.repoSubdir must be set when programs.nd.files or programs.nd.globs is non-empty.";
      }
    ]
    ++ lib.mapAttrsToList (destRoot: g: {
      assertion = builtins.pathExists (cfg.sourceDir + "/${g.source}");
      message = "programs.nd.globs.\"${destRoot}\".source = \"${g.source}\" does not exist under programs.nd.sourceDir.";
    }) cfg.globs
    ++ lib.mapAttrsToList (destRoot: g: {
      assertion = g.patterns != [ ];
      message = "programs.nd.globs.\"${destRoot}\".patterns is empty, so the entry places and captures nothing.";
    }) cfg.globs;
```

The `pathExists` assertion exists because `lib.filesystem.listFilesRecursive` on a missing path throws an evaluation error whose message does not name the option that caused it.

An empty match set is **not** an error. A glob matching nothing in the repo today but destined to match `lazy-lock.json` tomorrow is the expected state on a fresh machine.

- [ ] **Step 2: Rewrite the activation block**

Replace `home.activation.ndPlaceManagedConfigs` entirely:

```nix
    # Copy into place and record what was placed.
    #
    # A pre-existing symlink is removed first. Without that, `install` writes
    # *through* an old out-of-store symlink straight back into the repo, which
    # silently preserves the exact behaviour this module replaces.
    #
    # 0644 is deliberate. The position the credential scan in nd-save enforces is
    # that no credential belongs in a managed file; if that holds, 0644 is
    # correct. A per-file mode option would not survive the repo round-trip in
    # any case, because git records only the executable bit. Closed as wontfix,
    # not overlooked.
    home.activation.ndPlaceManagedConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      manifest="$HOME/${cfg.manifestPath}"
      run mkdir -p "$(dirname "$manifest")"

      ${lib.concatMapStringsSep "\n" (f: ''
        run mkdir -p "$(dirname "$HOME/${f.dest}")"
        if [ -L "$HOME/${f.dest}" ]; then
          run rm -f "$HOME/${f.dest}"
        fi
        run install -m 0644 ${f.src} "$HOME/${f.dest}"
      '') fileRecords}

      # Built in one variable and written once, so a dry run writes nothing at
      # all. Previously the scratch file was truncated and appended to directly
      # while only the final `mv` went through `run`, so a dry run left an
      # orphaned manifest.new behind. `run` keys off DRY_RUN, not the deprecated
      # DRY_RUN_CMD.
      ndManifest=${lib.escapeShellArg manifestText}

      if [[ -v DRY_RUN ]]; then
        echo "nd: would write manifest to $manifest"
      else
        printf '%s' "$ndManifest" > "$manifest.new"
        mv "$manifest.new" "$manifest"
      fi
    '';
```

- [ ] **Step 3: Verify it evaluates and places correctly**

There is no home-manager harness in this repo, so check the generated text directly:

```bash
nix eval --impure --expr '
  let
    pkgs = import <nixpkgs> {};
    lib = pkgs.lib;
    glob = import ./lib/glob.nix { inherit lib; };
    src = ./tests/fixtures/src;
  in {
    eres = map glob.globToERE [ "init.lua" "lua/**/*.lua" "lazy-lock.json" ];
    found = map toString (lib.filesystem.listFilesRecursive (src + "/nv"));
  }
' --raw 2>&1 | head
```

Create the fixture tree it reads first:

```bash
mkdir -p tests/fixtures/src/nv/lua
printf 'return 1\n' > tests/fixtures/src/nv/init.lua
printf 'return 2\n' > tests/fixtures/src/nv/lua/plug.lua
printf 'not matched\n' > tests/fixtures/src/nv/notes.txt
```

Expected: `found` lists all three files, and the EREs are the ones Task 1 pins. Confirm by eye that `notes.txt` is not matched by any of them.

If `lib.filesystem.listFilesRecursive` is not present in the pinned nixpkgs, raise an escalation — the fallback is a hand-rolled `builtins.readDir` recursion, which is ten lines but wants its own test.

- [ ] **Step 4: Run the full suite**

Run: `nix flake check`
Expected: exits 0. Nothing in `tests/run.sh` exercises the module yet; Task 12 adds the end-to-end case.

- [ ] **Step 5: Commit**

```bash
nix fmt modules/home-manager.nix
git add modules/home-manager.nix tests/fixtures
git commit -m "Add programs.nd.globs and write manifest v2"
```

---

### Task 10: Thread `flakePath`, `manifestPath` and `expectedBranch` to the tools

**Not in the issues document.** `programs.nd.flakePath` and `programs.nd.manifestPath` are declared, documented in the README, and never passed to `nd-switch`, `nd-save` or `nd-status`, all three of which fall back to their own hardcoded defaults. Anyone who sets either option gets tools pointed somewhere else. Record this in the escalation log as a resolved finding, with the reasoning that it is a prerequisite for `expectedBranch` (Task 7's `ND_EXPECTED_BRANCH`) having any route from the module to the binary at all.

**Files:**
- Modify: `modules/home-manager.nix`

- [ ] **Step 1: Add the `expectedBranch` option**

After `manifestPath`:

```nix
    expectedBranch = mkOption {
      type = types.str;
      default = "";
      example = "main";
      description = ''
        Branch `nd-save` is allowed to commit to. Empty means no constraint.

        When set and the checked-out branch differs, `nd-save` refuses —
        including under `-y`, because the unattended path is the one with nobody
        reading the branch name. `--branch NAME` overrides it for one run.

        A detached HEAD is refused whatever this is set to: the commit would be
        unreachable as soon as anything else is checked out.
      '';
    };
```

- [ ] **Step 2: Wrap the three binaries**

Add to the `let` block:

```nix
  # The declared options have to reach the binaries. Without this, flakePath and
  # manifestPath are documented settings that silently do nothing, because each
  # tool falls back to its own hardcoded default.
  #
  # --set-default rather than --set: an explicitly exported variable still wins,
  # which is what the tests and the documented ND_* overrides rely on.
  ndPkgs = self.packages.${pkgs.stdenv.hostPlatform.system};

  wrap =
    name: drv:
    pkgs.runCommand "${name}-nd"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = drv.meta or { };
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper "${drv}/bin/${name}" "$out/bin/${name}" \
          --set-default ND_FLAKE ${lib.escapeShellArg cfg.flakePath} \
          --set-default ND_MANIFEST ${lib.escapeShellArg "${config.home.homeDirectory}/${cfg.manifestPath}"} \
          ${lib.optionalString (cfg.expectedBranch != "")
            "--set-default ND_EXPECTED_BRANCH ${lib.escapeShellArg cfg.expectedBranch}"
          }
      '';

  ndSwitch = wrap "nd-switch" ndPkgs.nd-switch;
  ndSave = wrap "nd-save" ndPkgs.nd-save;
  ndStatus = wrap "nd-status" ndPkgs.nd-status;
```

`ND_EXPECTED_BRANCH` is set on all three for uniformity; only `nd-save` reads it.

Replace `home.packages`:

```nix
    home.packages = mkIf cfg.installPackages [
      ndSwitch
      ndSave
      ndStatus
    ];
```

- [ ] **Step 3: Verify the wrappers**

```bash
nix build --no-link --print-out-paths .#nd-save
```

Then check by hand that a wrapper built from a scratch expression sets the variables:

```bash
nix eval --impure --raw --expr '
  let pkgs = import <nixpkgs> {}; in
  toString (pkgs.runCommand "probe" { nativeBuildInputs = [ pkgs.makeWrapper ]; } "
    mkdir -p $out/bin
    makeWrapper ${pkgs.coreutils}/bin/env $out/bin/probe --set-default ND_FLAKE /tmp/x
  ")
'
```

Expected: the wrapper script contains `export ND_FLAKE`. If `makeWrapper` is unavailable in this context, raise an escalation; the alternative is `home.sessionVariables`, which is weaker because it only reaches login shells.

- [ ] **Step 4: Run the full suite**

Run: `nix flake check`
Expected: exits 0. The suite invokes the unwrapped store paths directly and sets `ND_FLAKE`/`ND_MANIFEST` itself, so wrapping does not affect it.

- [ ] **Step 5: Commit**

```bash
nix fmt modules/home-manager.nix
git add modules/home-manager.nix
git commit -m "Pass flakePath, manifestPath and expectedBranch through to the tools"
```

---

### Task 11: The zsh notice, as a testable file

**Files:**
- Create: `modules/nd-notice.zsh`
- Modify: `modules/home-manager.nix`
- Modify: `flake.nix`
- Modify: `tests/run.sh`

- [ ] **Step 1: Write the failing test**

Add `zsh` to the `tests` check in `flake.nix`:

```nix
          tests = pkgs.runCommand "nd-tests" {
            nativeBuildInputs = [ pkgs.git pkgs.zsh ];
          } ''
```

and export the notice's path so the suite can source it:

```nix
            export ND_NOTICE="${./modules/nd-notice.zsh}"
```

Mirror the fallback in `tests/run.sh`:

```bash
ND_NOTICE="${ND_NOTICE:-}"
if [ -z "$ND_NOTICE" ]; then
  ND_NOTICE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/modules/nd-notice.zsh"
fi
```

Add the runner and cases:

```bash
echo "zsh notice"

run_notice() {
  HOME="$1/home" PATH="$(dirname "$ND_STATUS"):$PATH" \
    zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1
}

d=$(new_fixture)
out=$(run_notice "$d")
check_empty "a clean tree prints nothing" "$out"
rm -rf "$d"

d=$(new_fixture)
drift "$d"
out=$(run_notice "$d")
check "drift is announced" "1 drifted" "$out"
check "the notice points at nd-save" "nd-save" "$out"
rm -rf "$d"

d=$(new_fixture)
rm "$d/home/.config/app/config.toml"
out=$(run_notice "$d")
check "a missing file is announced" "1 missing" "$out"
rm -rf "$d"

d=$(new_glob_fixture)
printf '{}\n' > "$d/home/.config/nv/lazy-lock.json"
out=$(run_notice "$d")
check "a new file is announced" "1 new" "$out"
rm -rf "$d"

d=$(new_fixture)
out=$(HOME="$d/home" ND_MANIFEST="$d/nope" PATH="$(dirname "$ND_STATUS"):$PATH" \
  zsh -f -c "source '$ND_NOTICE'; nd_notice" 2>&1)
check_empty "no manifest prints nothing" "$out"
rm -rf "$d"
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix flake check 2>&1 | grep -E 'FAIL|passed'`
Expected: failures — `modules/nd-notice.zsh` does not exist.

- [ ] **Step 3: Write `modules/nd-notice.zsh`**

```zsh
# One-line notice at interactive zsh startup when managed config needs
# attention. Sourced by programs.nd's zsh integration; kept in its own file so
# the test suite can source and call it directly.
#
# This forks nd-status once. The loop it replaces forked one cmp per managed
# file, so this gets cheaper as the managed set grows, as well as gaining the
# missing and new categories.
nd_notice() {
  emulate -L zsh
  setopt local_options no_nomatch

  (( $+commands[nd-status] )) || return 0

  local -a lines
  lines=( ${(f)"$(nd-status 2>/dev/null)"} )
  lines=( ${lines:#} )
  (( $#lines )) || return 0

  local -i drifted=0 missing=0 created=0
  local l
  for l in $lines; do
    case $l in
      (drifted*) (( drifted++ )) ;;
      (missing*) (( missing++ )) ;;
      (new*)     (( created++ )) ;;
    esac
  done

  local -a parts
  (( drifted )) && parts+=("$drifted drifted")
  (( missing )) && parts+=("$missing missing")
  (( created )) && parts+=("$created new")
  (( $#parts )) || return 0

  print -P "%F{yellow}nd:%f ${(j:, :)parts} config file(s) — run %Bnd-save%b to audit and commit"
}
```

`(( x )) && parts+=(...)` is a zsh arithmetic statement, not a shell `&&` under `errexit`; the notice runs in an interactive shell with no `errexit`, so the constraint in Global Constraints does not apply here. It applies to the `writeShellApplication` scripts.

- [ ] **Step 4: Wire it into the module**

Replace `programs.zsh.initContent`:

```nix
    programs.zsh.initContent = mkIf cfg.enableZshIntegration (
      lib.mkAfter ''
        source ${./nd-notice.zsh}
        nd_notice
      ''
    );
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `nix flake check`
Expected: exits 0.

- [ ] **Step 6: Commit**

```bash
nix fmt modules/home-manager.nix flake.nix
git add modules/nd-notice.zsh modules/home-manager.nix flake.nix tests/run.sh
git commit -m "Move the zsh notice into its own file and cover missing and new"
```

---

### Task 12: The end-to-end glob loop

The property the whole design rests on: an app creates a file, `nd-save` captures it, and the next evaluation would place it as an ordinary managed file.

**Files:**
- Modify: `tests/run.sh`

- [ ] **Step 1: Write the test**

```bash
echo "end to end"

# lazy.nvim rewrites lazy-lock.json on every plugin update. It is a file the
# user never declares, whose whole purpose is to be regenerated. Capturing it
# must land it at the right repo path and leave the repo in a state where the
# next evaluation enumerates it as an ordinary file record.
d=$(new_glob_fixture)
printf '{"nvim-treesitter":{"commit":"abc123"}}\n' > "$d/home/.config/nv/lazy-lock.json"

out=$(run_switch "$d" --build)
check "the switch reports it without blocking" "not yet in the repo" "$out"
check_not "the switch is not blocked" "changed since they were placed" "$out"

out=$(run_save "$d" -y)
check "nd-save captures it" "lazy-lock.json" "$out"
check "it lands at the right repo path" "abc123" "$(cat "$d/repo/files/nv/lazy-lock.json")"
check "it is committed" "files/nv/lazy-lock.json" "$(git -C "$d/repo" show --stat --format= HEAD)"
check "the subject names the app" "Save nv config written by the app" "$(git -C "$d/repo" log -1 --format=%s)"

# It is now in the repo, so the next evaluation places it. Simulate that by
# adding the file record a switch would write, and confirm it stops being new.
printf '%s\t%s\t%s\n' "$d/repo/files/nv/lazy-lock.json" ".config/nv/lazy-lock.json" "files/nv/lazy-lock.json" \
  >> "$d/home/.local/state/nd/manifest"
out=$(run_status "$d")
check_not "once placed it is no longer new" "new	.config/nv/lazy-lock.json" "$out"
check_not "and it has not drifted" "drifted" "$out"

# The loop closed: a second save has nothing to do.
out=$(run_save "$d" -y)
check "the loop is closed" "nothing to save" "$out"
rm -rf "$d"
```

The subject assertion expects `nv`, because the fixture's destination root is `.config/nv`. Confirm against Task 8's `app_of`.

- [ ] **Step 2: Run it**

Run: `nix flake check`
Expected: exits 0. If `once placed it is no longer new` fails, the `placed` membership test in `nd-status` is not matching — check that column 2 of the appended record is exactly `.config/nv/lazy-lock.json` with real tabs.

- [ ] **Step 3: Commit**

```bash
git add tests/run.sh
git commit -m "Cover the full capture loop for an application-created file"
```

---

### Task 13: README and the case count

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Count the cases**

```bash
nix flake check 2>&1 | grep -E '^passed'
```

Use that number in the Tests section. The README currently claims 40 and will be wrong.

- [ ] **Step 2: Rewrite the affected sections**

Changes, in file order:

1. **Install** — after the `files` example, add the `globs` example and the syntax table:

````markdown
    globs = {
      ".config/nvim" = {
        source = "nvim";
        patterns = [ "init.lua" "lua/**/*.lua" "lazy-lock.json" ];
      };
    };
```

`files` names one file each. `globs` names a *set*: everything matching is
placed, and a file that appears under the destination root later and matches a
pattern is captured rather than ignored. That is what makes lazy.nvim's
`lazy-lock.json` — a file you never declare, whose whole purpose is to be
regenerated — trackable.

| Pattern | Matches |
| --- | --- |
| `init.lua` | that file, at the root |
| `*.lua` | any `.lua` directly under the root |
| `lua/**/*.lua` | any `.lua` at any depth under `lua/` |
| `**/*.json` | any `.json` at any depth |
| `colors/**` | everything below `colors/` |

Only what a pattern names is ever captured. This is an allowlist deliberately: a
managed *directory* would need an ignore list maintained against an application
you do not control.
````

2. **Usage** — add:

```console
$ nd-status                 # what has drifted, gone missing, or appeared
$ nd-save --force           # overwrite repo edits that were never placed
$ nd-save --branch main     # require a branch for this run
```

3. **Usage** — update the typical session to show the derived subject and the missing/new reports.

4. **Safety** — replace the last bullet:

```markdown
- **`nd-save` refuses an unexpected branch.** Set `programs.nd.expectedBranch`
  and it refuses to commit anywhere else, including under `-y`. A detached HEAD
  is refused whatever you set, because the commit would be unreachable as soon
  as anything else is checked out.
- **`nd-save` refuses to overwrite repo edits that were never placed.** If the
  repo copy of a managed file differs from what was last placed, you have an
  edit waiting to be switched in; nd-save names it and stops rather than copying
  over it. `--force` overrides.
- **`nd-save` commits only the files it copied.** Anything else you had staged
  stays staged and uncommitted.
```

5. **Limitations** — delete "Only regular files. Directories must be listed file by file." Replace with:

```markdown
- Files are placed mode `0644`, deliberately: the credential scan's position is
  that nothing secret belongs in a managed file, and git records only the
  executable bit, so a per-file mode could not survive the round-trip anyway.
- Glob patterns support `**/`, a trailing `/**`, `*` and `?`. Bracket
  expressions and brace expansion match literally.
- A path containing a newline under a glob root is skipped, with a warning.
```

6. **Tests** — correct the count and mention what is new.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document globs, nd-status, the branch guard and the new refusals"
```

---

### Task 14: Version bump and final sweep

**Files:**
- Modify: `flake.nix` (description only, if it carries a version)
- Modify: `docs/superpowers/escalations.md`

- [ ] **Step 1: Resolve or escalate every open entry**

Read `docs/superpowers/escalations.md`. Every entry must be `resolved` or `unresolved`. Nothing stays `open`.

- [ ] **Step 2: Full check from clean**

```bash
git status --porcelain
nix flake check
bash -c 'ND_SWITCH=$(nix build --no-link --print-out-paths .#nd-switch)/bin/nd-switch \
ND_SAVE=$(nix build --no-link --print-out-paths .#nd-save)/bin/nd-save \
ND_STATUS=$(nix build --no-link --print-out-paths .#nd-status)/bin/nd-status \
bash tests/run.sh'
```

Expected: a clean tree, `nix flake check` exits 0, and the direct run reports `failed 0`.

- [ ] **Step 3: Tag the release**

`globs`, `expectedBranch` and the `nd-status` binary are public interface additions, so this is a minor bump.

```bash
git tag -a v0.2.0 -m "Glob-tracked files, nd-status, and the v0.1.0 defect fixes"
```

Do not push the tag.

- [ ] **Step 4: Commit any escalation-log changes**

```bash
git add docs/superpowers/escalations.md
git commit -m "Close out the escalation log"
```

---

## Self-Review

**Spec coverage.** Manifest v2 → Task 9. Glob syntax and translation → Task 1. Evaluation-time enumeration → Task 9. `nd-status` → Tasks 2, 3. Consumers → Tasks 4, 5, 11. `programs.nd.globs` → Task 9. `expectedBranch` → Tasks 7, 10. Defect 1 → Task 5. Defect 2 → Task 6. Defect 3 → Task 7. Defect 4 → Task 8. Defect 5 → Task 8. Defect 6 → Tasks 2, 4, 5. Defect 8 → Task 9 (comment). Defect 9 → Task 9. Test plan → distributed across the task that owns each behaviour, plus Task 12. Versioning → Task 14. README → Task 13.

**Beyond the spec, deliberately.** Task 10 fixes `flakePath` and `manifestPath` never reaching the binaries — not in the issues document, discovered while designing the `expectedBranch` route, and a prerequisite for it. Task 8 refines the spec's subject derivation to truncate at the first `.`. Task 11 extracts the zsh notice so it can be tested at all. Each is called out at its task and belongs in the escalation log as a resolved deviation.

**Known unverified.** Task 5 Step 0 exists because `git add --intent-to-add` followed by `git commit --only` is asserted, not yet proven. It is the one place the plan could be wrong in a way that changes the design rather than the code, which is why it is a step with its own escalation trigger rather than an assumption buried in an implementation.
