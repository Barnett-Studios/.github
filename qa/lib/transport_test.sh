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

# docker pull: "not found"-shaped text is a real FAIL, not a transient. Deliberately
# NOT a bare "not found" — review caught that "docker: command not found" (the
# binary itself missing, a local failure) contains that exact phrase.
docker_pull_is_not_found "manifest unknown: manifest unknown"
check "'manifest unknown' is not_found" "$?" 0
docker_pull_is_not_found "Error response from daemon: name unknown: repository not found"
check "'name unknown' is not_found" "$?" 0
docker_pull_is_not_found "Error response from daemon: Get \"https://ghcr.io/v2/\": i/o timeout"
check "i/o timeout is NOT not_found" "$?" 1
docker_pull_is_not_found "bash: docker: command not found"
check "'command not found' (docker missing) is NOT not_found" "$?" 1

# docker pull: a LOCAL environment failure is neither a registry FAIL nor a
# transport UNKNOWN-about-the-artifact — it's "this runner can't even ask", and
# must be checked before the two predicates above (review: "permission denied"
# talking to docker.sock contains "denied"; "docker: command not found" contains
# "not found" — both would otherwise misclassify as the registry's own verdict).
docker_pull_is_local_environment_failure "bash: docker: command not found"
check "docker binary missing is a local environment failure" "$?" 0
docker_pull_is_local_environment_failure "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock"
check "docker.sock permission denied is a local environment failure" "$?" 0
docker_pull_is_local_environment_failure "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
check "daemon not running is a local environment failure" "$?" 0
docker_pull_is_local_environment_failure "denied: requested access to the resource is denied"
check "a real registry denial is NOT a local environment failure" "$?" 1
docker_pull_is_local_environment_failure "manifest unknown: manifest unknown"
check "a real not_found is NOT a local environment failure" "$?" 1

# The ordering the boot call site must use: check local-environment first, so
# "permission denied ... docker.sock" never reaches docker_pull_is_access_rejection
# at all and can't be misread as the registry saying no.
sock_err="Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock"
docker_pull_is_access_rejection "$sock_err"
check "(without the ordering) docker.sock permission denied WOULD match access_rejection" "$?" 0
docker_pull_is_local_environment_failure "$sock_err"
check "but local-environment-failure catches it first, checked before access_rejection" "$?" 0

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
    paginated)
      # `--paginate` repeats the whole status-line+headers+blank-line block once
      # PER PAGE (measured against a real 21-commit repo at per_page=2). Three
      # pages here stands in for a >100-item listing (e.g. tags) that would
      # paginate in the real world — the shape is identical regardless of what's
      # being listed.
      for page in 1 2 3; do
        printf 'HTTP/2.0 200 OK\r\n'
        printf 'Content-Type: application/json\r\n'
        printf 'Link: <...>; rel="next"\r\n'
        printf '\r\n'
        printf 'item-%s\n' "$page"
      done
      ;;
    paginated_partial_failure)
      # review requirement 1: cxpak has 38 tags today, already above gh's default
      # 30-per-page — any --paginate tags call on it fetches 2 real pages. If page
      # 2 fails partway (a transient 502), page 1's 200 was already printed before
      # gh learned that, and gh's OWN overall exit is nonzero. The original bug:
      # gh_api_raw never looked at that exit status at all, so it read page 1's
      # 200 as if it were the whole, reliable answer.
      printf 'HTTP/2.0 200 OK\r\n'
      printf 'Content-Type: application/json\r\n'
      printf 'Link: <...>; rel="next"\r\n'
      printf '\r\n'
      printf 'page1-item\n'
      printf 'HTTP/2.0 502 Bad Gateway\r\n'
      printf 'Content-Type: application/json\r\n'
      printf '\r\n'
      printf '{"message":"Bad Gateway"}'
      return 1
      ;;
    paginated_page2_transport_failure)
      # page 1 answered 200, then page 2 died at the transport level (timeout or
      # reset) with no HTTP/ status line at all: one status block, gh exit 1.
      printf 'HTTP/2.0 200 OK\r\n'
      printf 'Content-Type: application/json\r\n'
      printf 'Link: <...>; rel="next"\r\n'
      printf '\r\n'
      printf 'page1-item\n'
      printf 'error connecting to api.github.com\n' >&2
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

# Review requirement 1: `--paginate` leaked page 2+'s status-line+headers into the
# body — this is the >100-item regression guard. The body must be exactly the three
# items, concatenated, with NO "HTTP/" line or header text anywhere in it.
GH_STUB_CASE=paginated
raw=$(gh_api_raw "repos/x/y/tags" --paginate)
body=$(printf '%s' "$raw" | tail -n +2)
check "gh_api_raw status line on a paginated response" "$(printf '%s' "$raw" | head -1)" 200
check "gh_api_raw concatenates all 3 pages' bodies" "$body" "$(printf 'item-1\nitem-2\nitem-3')"
leaked=$(printf '%s' "$body" | grep -c "^HTTP/\|^Content-Type:\|^Link:" || true)
check "no page's status line or headers leak into the concatenated body" "$leaked" 0

# review requirement 1 (MAJOR): a partial pagination failure — page 1 succeeded
# (200), page 2 failed (502), gh's own exit is nonzero — must be a transport
# failure (UNKNOWN upstream), never "page 1's 200 is the answer". Live, not
# hypothetical: cxpak has 38 tags, already above gh's 30-per-page default.
GH_STUB_CASE=paginated_partial_failure
gh_api_raw "repos/x/y/tags" --paginate >/dev/null
check "a page-2 failure mid-pagination is a transport failure, not page 1's 200" "$?" 1

# A paginated call whose later page failed with NO status line (transport-level)
# leaves a single 200 block; gh's nonzero exit is the only signal, so it must count.
GH_STUB_CASE=paginated_page2_transport_failure
gh_api_raw "repos/x/y/tags" --paginate >/dev/null
check "a paginated call with gh exit 1 and one 200 block is a transport failure" "$?" 1

# ...but a paginated call whose ONLY response is a real 404 is still a real answer
# (repo deleted/renamed): it must reach classification, not be demoted to UNKNOWN.
GH_STUB_CASE=not_found
raw=$(gh_api_raw "repos/x/y/tags" --paginate)
rc=$?
check "a paginated single 404 is still a response, not a transport failure" "$rc" 0
check "a paginated single 404 keeps its status" "$(printf '%s' "$raw" | head -1)" 404

unset -f gh

exit "$fail"
