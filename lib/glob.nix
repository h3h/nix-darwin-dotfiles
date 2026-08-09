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
#
# Two engines read this output, and they do not accept the same escapes.
# `tests/glob.nix` plus the `glob-engines` flake check feed every case to both;
# nothing here may be changed on reasoning alone.
let
  # A run of two or more `*` collapses to a single `*`.
  #
  # `replaceStrings` is one left-to-right pass, so a single call turns `***`
  # into `**` and `**********` into `*****`; those survive to the wildcard step
  # and become chained `[^/]*[^/]*…`. That is behaviourally equivalent but it is
  # a backtracking shape for `builtins.match` (std::regex), so iterate to a
  # fixed point and make the collapse real. Bounded by the string length.
  collapseStars =
    s:
    let
      s' = lib.replaceStrings [ "**" ] [ "*" ] s;
    in
    if s' == s then s else collapseStars s';

  # ERE metacharacters that both engines accept as `\c`, verified against
  # `builtins.match` and `grep -qxE` by the `glob-engines` check.
  #
  # `]` is deliberately absent. Outside a bracket expression it is already an
  # ordinary character in POSIX ERE, so `\]` is an escape of a non-special
  # character — undefined by POSIX, accepted by GNU grep, and rejected outright
  # by `builtins.match`:
  #
  #     nix-repl> builtins.match "\\]" "]"
  #     error: invalid regular expression '\]'
  #
  # `[` is escaped, so no bracket expression can ever open, so every `]` in the
  # output is unambiguously literal to both engines. `}` stays escaped: unlike
  # `]`, POSIX leaves a stray `}` undefined rather than ordinary, and both
  # engines accept `\}`.
  #
  # `-` is likewise absent and must stay absent: `\-` throws in `builtins.match`
  # for the same reason as `\]`.
  metachars = [
    "\\"
    "."
    "+"
    "("
    ")"
    "["
    "{"
    "}"
    "^"
    "$"
    "|"
  ];
in
rec {
  # Supported syntax, and nothing else:
  #
  #   **/     zero or more leading directory components   (.*/)?
  #   /**     everything below this directory (trailing)  /.*
  #   *       any run of characters within one component  [^/]*
  #   ?       one character within one component          [^/]
  #
  # Bracket expressions and brace expansion are NOT supported; their characters
  # are escaped or emitted literally, and either way match themselves.
  # Supporting them means a second parser for a gain that listing two patterns
  # already covers.
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
      collapseStars
      (lib.replaceStrings metachars (map (c: "\\" + c) metachars))
      (lib.replaceStrings [ "*" "?" ] [ "[^/]*" "[^/]" ])
      (lib.replaceStrings [ gs gsTail ] [ "(.*/)?" "/.*" ])
    ];

  # True when `rel` matches any of the already-translated EREs.
  matchesAny = eres: rel: lib.any (e: builtins.match e rel != null) eres;
}
