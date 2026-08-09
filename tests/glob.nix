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
  ];

  # Behaviour. A correct-looking ERE that matches the wrong set is still wrong.
  matches = [
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
      g = "colors/**";
      s = "colors/a/b.vim";
      want = true;
    }
    {
      g = "colors/**";
      s = "colors";
      want = false;
    }
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
  ];

  translationFailures = lib.filter (c: glob.globToERE c.g != c.e) (
    map (c: c // { got = glob.globToERE c.g; }) translations
  );

  matchFailures = lib.filter (c: (builtins.match (glob.globToERE c.g) c.s != null) != c.want) (
    map (c: c // { ere = glob.globToERE c.g; }) matches
  );
in
{
  inherit translationFailures matchFailures;
  ok = translationFailures == [ ] && matchFailures == [ ];
}
