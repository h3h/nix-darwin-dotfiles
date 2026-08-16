# Design: `programs.nd.host`, a declared configuration attribute

Date: 2026-08-15
Status: approved
Target release: v0.2.2

Closes [issue #5](https://github.com/h3h/nix-darwin-dotfiles/issues/5), but not
with the mechanism the issue proposes. The issue asks for automatic detection;
this design declines detection and adds a declared option instead. The reasoning
is in "Decisions taken during design". Checked against `48c8a3e`.

## Context

`nd-switch` resolves the flake attribute to build from the machine's hostname:

```sh
# packages/nd-switch.nix:24
host="${ND_HOST:-$(/bin/hostname -s)}"
```

and uses it twice, at `:270` for `nix build` and `:284` for the switch itself.
`--rollback` returns before either, so it never resolves an attribute at all.

That default is right for a repo that names each configuration after the machine
it runs on, which is the multi-host, multi-user layout the README's example
describes. It is wrong for a host-agnostic single-user flake, which exposes one
`darwinConfigurations.default` precisely so that no hostname appears anywhere in
the repo. Against such a flake `nd-switch` looks for `.#$(hostname -s)`, finds
nothing, and fails.

The only lever today is `ND_HOST=default` on every invocation. That works, and
it is per-invocation configuration — it reintroduces exactly the hardcoded
literal that the `default` output exists to remove, and it has to be remembered
every time.

## Decisions taken during design

**No detection.** The issue proposes probing the flake — evaluating
`darwinConfigurations` attribute names and falling back to `default` when no
host-named attribute exists. It is rejected. The probe is a `nix eval` on the
happy path of every switch, and it buys the ability to omit a single line of
configuration from a file that already carries `flakePath`, `sourceDir`,
`repoSubdir`, `files` and `globs`. Detection also has to answer questions a
declaration does not raise at all: what to do when the probe itself fails
because the flake has a syntax error, or needs the network, or exposes no
`darwinConfigurations` output. Each answer is a judgement call encoded in the
tool, and each one can be wrong in a way the user cannot see.

**No pre-flight validation either.** When the resolved attribute is not in the
flake, `nix build` reports it, and its message already names the attribute it
looked for. Checking first would mean the same `nix eval` on every run, to
improve an error that is not bad.

**The option is called `host`, not `configuration` or `hostAttr`.** It sets
`ND_HOST` and it is the hostname in every case but one, so the name that matches
the variable wins over the name that is technically more accurate for the
minority case. The description carries the nuance.

**`ND_HOST` is set on all three wrappers**, though only `nd-switch` reads it.
This follows the convention `modules/home-manager.nix:140` already states for
`ND_EXPECTED_BRANCH`, which only `nd-save` reads.

## The option

Declared beside `expectedBranch` in `modules/home-manager.nix`:

```nix
host = mkOption {
  type = types.str;
  default = "";
  example = "default";
  description = ''
    `darwinConfigurations` attribute `nd-switch` builds and switches to.
    Empty means the short hostname.

    A multi-host repo names each configuration after its machine, and the
    hostname finds it with nothing declared here. A host-agnostic single-user
    flake exposes one `darwinConfigurations.default` instead, precisely so no
    hostname is written down anywhere; set this to `default` and `nd-switch`
    stops looking for a machine-named attribute.

    `ND_HOST` overrides this for one run.
  '';
};
```

`types.str` with `""` meaning unset, rather than `types.nullOr types.str` with
`null`, because `expectedBranch` directly above establishes that convention and
there is no behavioural difference between them.

Precedence falls out of `--set-default` with no new code:

| set | wins |
| --- | --- |
| `ND_HOST` exported | `ND_HOST` |
| `programs.nd.host` declared, no `ND_HOST` | the option |
| neither | the short hostname |

## Changes per file

### `packages/nd-switch.nix`

None. Line 24 already reads `${ND_HOST:-$(/bin/hostname -s)}`, and
`--set-default` fills that gap without displacing an explicit export. The
program does not learn that the option exists, which is the point: the option is
a default for a variable `nd-switch` already honours.

### `modules/home-manager.nix`

The `mkOption` above, and one change to how `wrap` builds its arguments.

The current `makeWrapper` call is a backslash-continued command whose only
conditional argument is `lib.optionalString`-guarded and last. That works
*because* it is last: a conditional argument in the middle collapses to an empty
line between a trailing `\` and the next flag, which ends the command there and
silently drops every argument after it. Adding a second conditional flag
therefore changes what the construct can safely express, so `wrap` builds its
flags as a Nix list:

```nix
wrapFlags = lib.concatStringsSep " " (
  [
    "--set-default ND_FLAKE ${lib.escapeShellArg cfg.flakePath}"
    "--set-default ND_MANIFEST ${lib.escapeShellArg "${config.home.homeDirectory}/${cfg.manifestPath}"}"
  ]
  ++ lib.optional (cfg.host != "") "--set-default ND_HOST ${lib.escapeShellArg cfg.host}"
  ++ lib.optional (cfg.expectedBranch != "") "--set-default ND_EXPECTED_BRANCH ${lib.escapeShellArg cfg.expectedBranch}"
);
```

leaving `makeWrapper "${drv}/bin/${name}" "$out/bin/${name}" ${wrapFlags}` with
no conditional shell syntax in it. This is a refactor of the line the change
edits, not unrelated cleanup: the failure it removes is one this change would
otherwise introduce.

### `README.md`

The environment-override paragraph (`:247-252`) opens with "`nd-switch` reads
the hostname, so it needs no per-machine configuration", which stops being the
whole truth. It becomes:

> `nd-switch` reads the hostname, so a repo that names each configuration after
> its machine needs nothing declared. A host-agnostic flake that exposes a
> single `darwinConfigurations.default` — so that no hostname is written down
> anywhere — sets `programs.nd.host = "default"` once instead.

and `host` joins the list of options baked into the wrappers as defaults in the
same paragraph.

The install example at `:106-133` is left alone. It is an `alice` multi-host
layout, so omitting `host` is the example correctly demonstrating the default;
adding a commented-out line would show the option in the one configuration that
should not set it.

One bullet is added under Limitations, which is where this repo records
deliberate non-features:

> - `nd-switch` does not inspect the flake to discover which configurations it
>   exposes. It builds the hostname, or `programs.nd.host` if you set one; if
>   that attribute is not there, `nix build` says so and names it.

That bullet is the written record of the detection decision above, so the next
person to want it finds the reasoning instead of refiling the issue.

## Tests

The wrapper suite already has the shape this needs; the work is mirroring
`expectedBranch` through it.

### `tests/module.nix`

`base` gains `host = "example";`. The value is deliberately neither a plausible
hostname nor `default`: a fixture value that could coincide with the developer's
real machine or a real attribute is a fixture value that lets an assertion pass
for the wrong reason.

A second evaluation mirrors `noBranch`:

```nix
# host defaults to "", which must leave ND_HOST unset rather than set it to the
# empty string — nd-switch reads an absent ND_HOST as "use the hostname", and an
# empty one would be a hostname the wrapper chose for the user.
noHost = evalND (base // { host = ""; });
```

exported as `wrapNoHostSwitch = wrapperOf noHost "nd-switch";`, along with
`host = base.host;`.

### `flake.nix`

Two exports beside the existing ones at `:88-95`: `ND_WRAP_NOHOST_SWITCH` and
`ND_HOST_VALUE`.

### `tests/module.sh`

Both new variables join the required-variable guard at `:19-22`, and `ND_HOST`
joins the `unset` at `:31`. That last one matters more than its neighbours: a
developer running the suite on their own machine may genuinely have `ND_HOST`
exported, and the wrapper cases assert on what `--set-default` does with an
inherited value.

Inside the existing per-wrapper loop, beside the `ND_FLAKE`, `ND_MANIFEST` and
`ND_EXPECTED_BRANCH` pairs:

- each wrapper gets `ND_HOST` from `host`;
- each wrapper lets an explicit `ND_HOST` win.

And after the loop, beside the empty-`expectedBranch` case:

- an empty `host` sets nothing, asserted against `ND_WRAP_NOHOST_SWITCH` and
  expecting `NOTSET`.

### `tests/run.sh`

One behavioural case. `ND_HOST` appears nowhere in the suite today, and the
option's entire value rests on `nd-switch` honouring the variable — the wrapper
setting it correctly means nothing if the program ignores it:

```sh
# The module's `host` option is a --set-default for this variable, so what it
# buys depends entirely on ND_HOST selecting the attribute that gets built.
d=$(new_fixture)
out=$(HOME="$d/home" ND_FLAKE="$d/repo" ND_HOST=default "$ND_SWITCH" --build 2>&1)
check "ND_HOST selects the configuration attribute" "building default from" "$out"
rm -rf "$d"
```

Like every other `--build` case in the file, this dies at `nix build` against
the fixture's stub `{}` flake; the assertion is on the line printed before that.

No second end-to-end case is added to `tests/module.sh`. It already carries
exactly one, on the reasoning that reading the exports back is not the same as
the program receiving them, and between that case and the `run.sh` case above
both halves are covered: the wrapper sets the variable, and the program acts on
it.

## What this does not change

- `nd-status` and `nd-save` resolve no configuration attribute, and are
  unaffected beyond carrying a variable they do not read.
- `nd-switch --rollback` never resolves an attribute — `darwin-rebuild
  --rollback` and `--switch-generation` take a generation, not a flake
  reference — so the option has no bearing on it.
- Existing configurations. `host` defaults to `""`, no `ND_HOST` is set, and
  hostname resolution is byte-for-byte what it is today.
- The drift gate, the manifest format, and every classification kind.
