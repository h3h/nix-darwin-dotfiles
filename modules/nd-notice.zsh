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
