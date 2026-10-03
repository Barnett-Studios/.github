#!/usr/bin/env bash
# .github#28 review: a failed per-file contents fetch inside version_declarations
# must not silently shrink the declared set — it must fail the whole comparison
# (UNKNOWN upstream), the same "a query that failed is not an empty result" rule
# half 5 already states for its own calls. Stubbed `gh`, no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./version_declarations.sh
source ./version_declarations.sh

fail=0
check() { # description got want
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (got %s want %s)\n' "$1" "$2" "$3"
    fail=1
  fi
}

ORG=Barnett-Studios

gh() {
  case "$GH_STUB_CASE" in
    tree_and_content_ok)
      case "$2" in
        *"/git/trees/"*) printf 'VERSION\n' ;;
        *"/contents/"*) printf '%s\n' "$(printf '1.2.3' | base64)" ;;
      esac
      ;;
    content_fetch_fails)
      case "$2" in
        *"/git/trees/"*) printf 'VERSION\n' ;;
        *"/contents/"*) return 1 ;;
      esac
      ;;
  esac
}

GH_STUB_CASE=tree_and_content_ok
decls=$(version_declarations widget deadbeef)
rc=$?
check "a clean tree+content read returns 0" "$rc" 0
check "...and reports the one declaration" "$decls" "VERSION=1.2.3"

# The regression: before this fix, a failed contents fetch (gh exits nonzero, no
# --jq applied, body is the raw error JSON) piped into `base64 -d`, which failed
# too, tripping the OLD `|| continue` — so this path silently dropped out of the
# set and the function still returned 0 with n=0 (reported upstream as "ok, zero
# declarations" or folded into "declares no version", never as UNKNOWN).
GH_STUB_CASE=content_fetch_fails
version_declarations widget deadbeef >/dev/null
check "a failed contents fetch fails the whole comparison, not just this path" "$?" 1

unset -f gh
exit "$fail"
