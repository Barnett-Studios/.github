#!/usr/bin/env bash
# .github#15: the GREEN/RED/INCONCLUSIVE decision, extracted out of ghost-check.sh so
# it is testable without running the real network-calling halves.
#
# `note` is every half's printer. Review (round 2) caught that sniffing the outcome
# out of the message TEXT ("does $2 start with the word FAIL?") is exactly the class
# of fragility this whole fix exists to remove elsewhere — a message that happens to
# start with the wrong word, or a future call site that forgets the convention,
# silently miscounts. `note` now takes the outcome as its own argument, so there is
# nothing to sniff and nothing to get wrong by phrasing.
#
# outcome is one of: ok | FAIL | WARN | UNKNOWN | DEBT.
#   FAIL    — a real answer that is a defect. Gates: blocks GREEN (exit 1, RED).
#   UNKNOWN — the pass could not establish an answer at all (a transient request
#             failure, or a response that is not evidence — 429/5xx). Gates: blocks
#             GREEN short of a FAIL (exit 2, INCONCLUSIVE).
#   WARN    — an ordinary, understood, PERMANENT gap in what can be verified (half
#             4's unverifiable tag-vs-tree claim for a component with no in-tree
#             version file, half 5's "a version pin misdescribes what it pins").
#             Non-gating by design: cordon/slicr will carry no VERSION file for as
#             long as they exist, and if WARN gated too this script could never
#             print GREEN again.
#   DEBT    — half 5's advisory unreleased-fix count. Non-gating.
#   ok      — nothing wrong, and the check actually ran.
note_init() { fail=0; unknown=0; }
note() { # component outcome message
  printf '%-11s %-7s %s\n' "$1" "$2" "$3"
  case "$2" in
    FAIL) fail=1 ;;
    UNKNOWN) unknown=1 ;;
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
