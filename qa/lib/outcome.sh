#!/usr/bin/env bash
# .github#15: the GREEN/RED/INCONCLUSIVE decision, extracted out of ghost-check.sh so
# it is testable without running the real network-calling halves.
#
# `note` is every half's printer; it auto-tracks outcome from the message text alone,
# so every call site — this file's pre-existing ones and any new one — reports into
# the right counter without being individually edited. Plain `WARN` is untouched on
# purpose: this file's pre-existing advisory WARNs (half 4's unverifiable tag-vs-tree
# claim, half 5's currency gaps) fire on an ordinary, understood, PERMANENT state of
# some components (cordon/slicr carry no in-tree version file) and were always meant
# to be non-gating — if `note` tracked bare WARN here too, this script could never
# print GREEN again for as long as those components exist. `UNKNOWN` is the new,
# distinct word for "this pass could not establish an answer", and that one blocks
# GREEN by design.
note_init() { fail=0; unknown=0; }
note() {
  printf '%-11s %s\n' "$1" "$2"
  case "$2" in
    FAIL\ *) fail=1 ;;
    UNKNOWN\ *) unknown=1 ;;
  esac
}

# Prints the final verdict line and returns the exit code the caller should use:
#   0  GREEN        — every check ran and found nothing wrong
#   1  RED          — at least one check got a real answer that is a defect
#   2  INCONCLUSIVE — no FAIL, but at least one check never got an answer at all
ghost_check_outcome() {
  if [ "$fail" != 0 ]; then
    echo "GHOST CHECK RED — stop and report; do not file product findings against this state"
    return 1
  elif [ "$unknown" != 0 ]; then
    echo "GHOST CHECK INCONCLUSIVE — at least one check never got an answer at all; findings from checks that DID run still stand, but nothing here establishes the family is clean — re-run"
    return 2
  else
    echo "GHOST CHECK GREEN"
    return 0
  fi
}
