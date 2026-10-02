#!/usr/bin/env bash
# .github#15, review requirement 5: a run with no FAIL but at least one UNKNOWN must
# not print GHOST CHECK GREEN. This drives qa/lib/outcome.sh's three-way decision
# directly, with canned note() calls — no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./outcome.sh
source ./outcome.sh

fail_count=0
check() { # description got want
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (got %s want %s)\n' "$1" "$2" "$3"
    fail_count=1
  fi
}

note_init
note "abproof" "ok   v0.3.0 @ deadbeef on main"
note "attestr" "ok   v0.5.0 @ cafef00d on main"
line=$(ghost_check_outcome); rc=$?
check "all-ok run exits 0" "$rc" 0
check "all-ok run prints GREEN" "$line" "GHOST CHECK GREEN"

note_init
note "abproof" "ok   v0.3.0 @ deadbeef on main"
note "attestr" "UNKNOWN cannot reach ghcr to get a pull token for attestr — reach unknown this pass"
line=$(ghost_check_outcome); rc=$?
check "one UNKNOWN, no FAIL: exits 2 (not 0)" "$rc" 2
check "one UNKNOWN, no FAIL: prints INCONCLUSIVE, not GREEN" "$line" \
  "GHOST CHECK INCONCLUSIVE — at least one check never got an answer at all; findings from checks that DID run still stand, but nothing here establishes the family is clean — re-run"

note_init
note "abproof" "FAIL no such repository — the image is not public"
note "attestr" "UNKNOWN cannot reach ghcr to get a pull token for attestr — reach unknown this pass"
line=$(ghost_check_outcome); rc=$?
check "FAIL beats UNKNOWN: exits 1 (RED), not 2" "$rc" 1
check "FAIL beats UNKNOWN: prints RED" "$line" \
  "GHOST CHECK RED — stop and report; do not file product findings against this state"

note_init
note "cordon" "WARN v0.1.3 declares no version anywhere in its tree, so the tag-vs-tree claim is UNVERIFIABLE"
line=$(ghost_check_outcome); rc=$?
check "pre-existing advisory WARN alone still exits 0" "$rc" 0
check "pre-existing advisory WARN alone still prints GREEN (not blocked forever)" "$line" "GHOST CHECK GREEN"

exit "$fail_count"
