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

  # Every arm matches the kind up to the tab that ends the field, and there is a
  # default. Without one, a kind this notice predates incremented nothing and
  # the notice stayed silent while nd-status was reporting a finding — which is
  # what `unreadable` did the day it was added. Without the tab, a kind whose
  # name merely begins with a known one ("newly-placed") would be counted as
  # that kind and reported under the wrong word.
  local -i drifted=0 captured=0 missing=0 created=0 unreadable=0 unrecognised=0
  local l
  for l in $lines; do
    case $l in
      (drifted$'\t'*)    (( drifted++ )) ;;
      (captured$'\t'*)   (( captured++ )) ;;
      (missing$'\t'*)    (( missing++ )) ;;
      (new$'\t'*)        (( created++ )) ;;
      (unreadable$'\t'*) (( unreadable++ )) ;;
      (*)                (( unrecognised++ )) ;;
    esac
  done

  local -a parts
  (( drifted )) && parts+=("$drifted drifted")
  (( captured )) && parts+=("$captured captured")
  (( missing )) && parts+=("$missing missing")
  (( created )) && parts+=("$created new")
  (( unreadable )) && parts+=("$unreadable unreadable")
  (( unrecognised )) && parts+=("$unrecognised unrecognised")
  (( $#parts )) || return 0

  # nd-save is the right advice for everything it can act on, and the wrong
  # advice for a state made only of captured files: it will decline them and
  # send you here again. A switch is what places captured content — and what
  # restores a missing file — so when nothing is drifted or new, say so.
  # unreadable and unrecognised keep the nd-save advice, because nd-save is
  # where both are explained at length.
  local advice="run %Bnd-save%b to audit and commit"
  if (( captured && ! drifted && ! created && ! unreadable && ! unrecognised )); then
    advice="run %Bnd-switch%b to place them"
  fi

  print -P "%F{yellow}nd:%f ${(j:, :)parts} config file(s) — $advice"
}
