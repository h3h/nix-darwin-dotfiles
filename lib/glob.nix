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
        [
          "\\"
          "."
          "+"
          "("
          ")"
          "["
          "]"
          "{"
          "}"
          "^"
          "$"
          "|"
        ]
        [
          "\\\\"
          "\\."
          "\\+"
          "\\("
          "\\)"
          "\\["
          "\\]"
          "\\{"
          "\\}"
          "\\^"
          "\\$"
          "\\|"
        ]
      )
      (lib.replaceStrings [ "*" "?" ] [ "[^/]*" "[^/]" ])
      (lib.replaceStrings [ gs gsTail ] [ "(.*/)?" "/.*" ])
    ];

  # True when `rel` matches any of the already-translated EREs.
  matchesAny = eres: rel: lib.any (e: builtins.match e rel != null) eres;
}
