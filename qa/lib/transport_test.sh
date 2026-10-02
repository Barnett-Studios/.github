#!/usr/bin/env bash
# .github#15: ghost-check.sh's halves 1/2 and the boot docker-pull probe all collapsed
# "the far end gave a real answer" and "we never reached the far end at all" into one
# FAIL. This is the classifier that keeps them apart, tested without touching the
# network — every case here is a canned exit code, a canned HTTP status, a canned
# error string, or a stubbed `gh`/`curl` — not a live network call.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=./transport.sh
source ./transport.sh

fail=0
check() { # description got want
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (got %s want %s)\n' "$1" "$2" "$3"
    fail=1
  fi
}

# curl *without* -f exits 0 on any HTTP response, including 404/403/500; a nonzero
# exit is unconditionally a transport failure now (review: no whitelist of specific
# codes — an incomplete one silently re-admits the bug for any code not listed).
for rc in 1 2 6 7 28 35 52 56 99; do
  curl_is_transport_failure "$rc"
  check "curl exit $rc is a transport failure" "$?" 0
done
curl_is_transport_failure 0
check "curl exit 0 (a real HTTP response) is not a transport failure" "$?" 1

# classify_http_status: the four-way split a real response gets sorted into.
for status in 200 201 204 299; do
  check "status $status classifies ok" "$(classify_http_status "$status")" ok
done
check "404 classifies not_found" "$(classify_http_status 404)" not_found
check "401 classifies access_rejected" "$(classify_http_status 401)" access_rejected
check "403 classifies access_rejected" "$(classify_http_status 403)" access_rejected
for status in 429 500 502 503 504 301 100; do
  check "status $status classifies unknown (not evidence)" "$(classify_http_status "$status")" unknown
done

# docker pull: "not found"-shaped text is a real FAIL, not a transient.
docker_pull_is_not_found "manifest unknown: manifest unknown"
check "'manifest unknown' is not_found" "$?" 0
docker_pull_is_not_found "Error response from daemon: name unknown: repository not found"
check "'name unknown' is not_found" "$?" 0
docker_pull_is_not_found "Error response from daemon: Get \"https://ghcr.io/v2/\": i/o timeout"
check "i/o timeout is NOT not_found" "$?" 1

# docker pull: access rejection is matched on the literal status phrase or the
# registry's own verdict words — never a bare `*403*` (review: a URL/digest/body can
# coincidentally contain those digits with no bearing on access).
docker_pull_is_access_rejection "denied: requested access to the resource is denied"
check "denied is an access rejection" "$?" 0
docker_pull_is_access_rejection "Error response from daemon: unauthorized: authentication required"
check "unauthorized is an access rejection" "$?" 0
docker_pull_is_access_rejection "Error response from daemon: Get \"https://ghcr.io/v2/...\": 403 Forbidden"
check "literal '403 Forbidden' phrase is an access rejection" "$?" 0
docker_pull_is_access_rejection "Error response from daemon: Get \"https://ghcr.io/v2/\": net/http: TLS handshake timeout"
check "TLS handshake timeout is NOT an access rejection" "$?" 1
docker_pull_is_access_rejection "Error response from daemon: Get \"https://ghcr.io/v2/\": dial tcp: connection reset by peer"
check "connection reset is NOT an access rejection" "$?" 1
docker_pull_is_access_rejection "pulling sha256:403abc... layer 403def0 failed: i/o timeout"
check "a coincidental '403' substring is NOT an access rejection" "$?" 1

# gh_api_raw: stub `gh` itself (shadows the real binary for this process only) so the
# status-line parsing is exercised against the exact three shapes `gh api -i` is
# observed to produce, with no network and no real gh/token required.
gh() {
  case "$GH_STUB_CASE" in
    ok)
      printf 'HTTP/2.0 200 OK\r\n'
      printf 'Content-Type: application/json\r\n'
      printf '\r\n'
      printf 'v0.3.0\n'
      ;;
    not_found)
      printf 'HTTP/2.0 404 Not Found\r\n'
      printf 'Content-Type: application/json\r\n'
      printf '\r\n'
      printf '{"message":"Not Found"}'
      return 1
      ;;
    transport)
      printf 'error connecting to api.github.com\n'
      printf 'check your internet connection or https://githubstatus.com\n'
      return 1
      ;;
  esac
}

GH_STUB_CASE=ok
raw=$(gh_api_raw "repos/x/y/tags")
rc=$?
check "gh_api_raw rc on a 200" "$rc" 0
check "gh_api_raw status line on a 200" "$(printf '%s' "$raw" | head -1)" 200
check "gh_api_raw body on a 200" "$(printf '%s' "$raw" | tail -n +2)" "v0.3.0"

GH_STUB_CASE=not_found
raw=$(gh_api_raw "repos/x/y/tags")
rc=$?
check "gh_api_raw rc on a 404 (a real response, not a transport failure)" "$rc" 0
check "gh_api_raw status line on a 404" "$(printf '%s' "$raw" | head -1)" 404

GH_STUB_CASE=transport
gh_api_raw "repos/x/y/tags" >/dev/null
check "gh_api_raw rc when gh never got a response at all" "$?" 1

unset -f gh

exit "$fail"
