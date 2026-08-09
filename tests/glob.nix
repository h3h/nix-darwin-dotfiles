{ lib }:

let
  glob = import ../lib/glob.nix { inherit lib; };

  # Exact translations. These are the worked examples from the spec.
  translations = [
    {
      g = "init.lua";
      e = "init\\.lua";
    }
    {
      g = "lua/**/*.lua";
      e = "lua/(.*/)?[^/]*\\.lua";
    }
    {
      g = "**/*.json";
      e = "(.*/)?[^/]*\\.json";
    }
    {
      g = "colors/**";
      e = "colors/.*";
    }
    {
      g = "*.lua";
      e = "[^/]*\\.lua";
    }
    {
      g = "?.lua";
      e = "[^/]\\.lua";
    }
    {
      g = "a+b(c).txt";
      e = "a\\+b\\(c\\)\\.txt";
    }
    {
      g = "lazy-lock.json";
      e = "lazy-lock\\.json";
    }
    # `]` is emitted literally, not as `\]`, which `builtins.match` rejects.
    {
      g = "[abc].lua";
      e = "\\[abc]\\.lua";
    }
    # The collapse is a fixed point, not a single `replaceStrings` pass: a pass
    # would leave `**` here and translate it to `[^/]*[^/]*`.
    {
      g = "***.lua";
      e = "[^/]*\\.lua";
    }
    {
      g = "**********.lua";
      e = "[^/]*\\.lua";
    }
    # A run longer than two still yields the `**/` token when it ends in `/`.
    {
      g = "***/x.lua";
      e = "[^/]*(.*/)?x\\.lua";
    }
  ];

  # Behaviour. A correct-looking ERE that matches the wrong set is still wrong.
  #
  # Every case here is run twice: through `builtins.match` below, and through
  # `grep -qxE` by `tests/glob-engines.sh`, which fails if the two disagree.
  # Add cases here and both engines pick them up.
  matches = [
    # --- token: **/ ---
    {
      g = "lua/**/*.lua";
      s = "lua/x.lua";
      want = true;
    }
    {
      g = "lua/**/*.lua";
      s = "lua/plugins/lsp/init.lua";
      want = true;
    }
    {
      g = "lua/**/*.lua";
      s = "init.lua";
      want = false;
    }
    {
      g = "lua/**/*.lua";
      s = "lua/x.vim";
      want = false;
    }
    {
      g = "**/*.json";
      s = "a.json";
      want = true;
    }
    {
      g = "**/*.json";
      s = "deep/nested/b.json";
      want = true;
    }
    {
      g = "**/*.json";
      s = "a.jsonx";
      want = false;
    }

    # --- token: trailing /** ---
    {
      g = "colors/**";
      s = "colors/a/b.vim";
      want = true;
    }
    {
      g = "colors/**";
      s = "colors/a";
      want = true;
    }
    {
      g = "colors/**";
      s = "colors";
      want = false;
    }
    {
      g = "colors/**";
      s = "othercolors/a";
      want = false;
    }

    # --- token: * ---
    {
      g = "*.lua";
      s = "init.lua";
      want = true;
    }
    {
      g = "*.lua";
      s = "lua/x.lua";
      want = false;
    }
    {
      g = "*.lua";
      s = "init.vim";
      want = false;
    }

    # --- token: ? ---
    {
      g = "?.lua";
      s = "a.lua";
      want = true;
    }
    {
      g = "?.lua";
      s = "ab.lua";
      want = false;
    }
    {
      g = "?.lua";
      s = ".lua";
      want = false;
    }

    # --- collapsed star runs (F3) ---
    {
      g = "***.lua";
      s = "init.lua";
      want = true;
    }
    {
      g = "***.lua";
      s = "lua/x.lua";
      want = false;
    }
    {
      g = "**********.lua";
      s = "init.lua";
      want = true;
    }

    # --- literal, no wildcards ---
    {
      g = "lazy-lock.json";
      s = "lazy-lock.json";
      want = true;
    }
    {
      g = "lazy-lock.json";
      s = "lazy-lockXjson";
      want = false;
    }

    # --- every character in the escape table, positive and negative ---
    # `.` — unescaped it would match any character.
    {
      g = "a.b";
      s = "a.b";
      want = true;
    }
    {
      g = "a.b";
      s = "axb";
      want = false;
    }
    # `+` — unescaped it would make `a` one-or-more.
    {
      g = "a+b.txt";
      s = "a+b.txt";
      want = true;
    }
    {
      g = "a+b.txt";
      s = "ab.txt";
      want = false;
    }
    # `(` and `)` — unescaped they would group.
    {
      g = "a(c).txt";
      s = "a(c).txt";
      want = true;
    }
    {
      g = "a(c).txt";
      s = "ac.txt";
      want = false;
    }
    # `[` and `]` — the case that broke evaluation. See F1.
    {
      g = "[abc].lua";
      s = "[abc].lua";
      want = true;
    }
    {
      g = "[abc].lua";
      s = "a.lua";
      want = false;
    }
    # `]` on its own, with no `[` anywhere in the pattern.
    {
      g = "a]b.txt";
      s = "a]b.txt";
      want = true;
    }
    {
      g = "a]b.txt";
      s = "ab.txt";
      want = false;
    }
    # `{` and `}` — unescaped they would form an interval expression.
    {
      g = "a{2}.txt";
      s = "a{2}.txt";
      want = true;
    }
    {
      g = "a{2}.txt";
      s = "aa.txt";
      want = false;
    }
    # `{` on its own, and `}` on its own.
    {
      g = "a{b.txt";
      s = "a{b.txt";
      want = true;
    }
    {
      g = "a}b.txt";
      s = "a}b.txt";
      want = true;
    }
    {
      g = "a}b.txt";
      s = "ab.txt";
      want = false;
    }
    # `^` — unescaped it is an anchor and would vanish from the middle.
    {
      g = "a^b.txt";
      s = "a^b.txt";
      want = true;
    }
    {
      g = "a^b.txt";
      s = "ab.txt";
      want = false;
    }
    # `$` — same.
    {
      g = "a$b.txt";
      s = "a$b.txt";
      want = true;
    }
    {
      g = "a$b.txt";
      s = "ab.txt";
      want = false;
    }
    # `|` — unescaped it would alternate.
    {
      g = "a|b.txt";
      s = "a|b.txt";
      want = true;
    }
    {
      g = "a|b.txt";
      s = "a";
      want = false;
    }
    {
      g = "a|b.txt";
      s = "b.txt";
      want = false;
    }
    # `\` — must survive as a literal backslash in both engines.
    {
      g = "a\\b.txt";
      s = "a\\b.txt";
      want = true;
    }
    {
      g = "a\\b.txt";
      s = "ab.txt";
      want = false;
    }
    # `-`, which is NOT escaped and must not be: `\-` throws in builtins.match.
    {
      g = "a-b.txt";
      s = "a-b.txt";
      want = true;
    }

    # --- metacharacters combined with the wildcard tokens ---
    {
      g = "**/[a].{b}";
      s = "x/y/[a].{b}";
      want = true;
    }
    {
      g = "**/[a].{b}";
      s = "[a].{b}";
      want = true;
    }
    {
      g = "**/[a].{b}";
      s = "x/y/a.b";
      want = false;
    }
    {
      g = "cfg/**";
      s = "cfg/a]b/c{d}.txt";
      want = true;
    }
    {
      g = "*].lua";
      s = "x].lua";
      want = true;
    }
    {
      g = "*].lua";
      s = "x/y].lua";
      want = false;
    }
  ];

  translationFailures = lib.filter (c: glob.globToERE c.g != c.e) (
    map (c: c // { got = glob.globToERE c.g; }) translations
  );

  withERE = map (c: c // { ere = glob.globToERE c.g; }) matches;

  matchFailures = lib.filter (c: (builtins.match c.ere c.s != null) != c.want) withERE;
in
{
  inherit translationFailures matchFailures;
  ok = translationFailures == [ ] && matchFailures == [ ];

  # Payload for `tests/glob-engines.sh`, which re-runs every case through
  # `grep -qxE` and fails if grep disagrees with the verdict Nix recorded here.
  # Tab-separated: glob, ERE, subject, want, the `builtins.match` verdict.
  # No field may contain a tab or a newline; none of the cases do.
  engineCases = lib.concatMapStrings (
    c:
    lib.concatStringsSep "\t" [
      c.g
      c.ere
      c.s
      (if c.want then "1" else "0")
      (if builtins.match c.ere c.s != null then "1" else "0")
    ]
    + "\n"
  ) withERE;
}
