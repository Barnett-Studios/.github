#!/usr/bin/env bash
# .github#15: ghost-check.sh's halves 1/2 and the boot docker-pull probe all collapsed
# "the far end gave a real answer" and "we never reached the far end at all" into one
# FAIL. This is the classifier that keeps them apart, tested without touching the
# network — every case here is a canned exit code or canned error string, not a live
# curl/gh/docker call.
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

# curl *without* -f exits 0 on any HTTP response, including 404/403/500 — it only
# fails for a transport problem that never produced a response at all. These are the
# curl exit codes this family has actually hit chasing this bug (6 resolve, 7
# connect, 28 timeout, 35 SSL connect, 52 empty reply, 56 recv error).
for rc in 6 7 28 35 52 56; do
  curl_is_transport_failure "$rc"
  check "curl exit $rc is a transport failure" "$?" 0
done
curl_is_transport_failure 0
check "curl exit 0 (a real HTTP response) is not a transport failure" "$?" 1

# docker/registry text: denied/unauthorized/403 is the registry answering "no" —
# evidence about the artifact. Everything else observed in the wild (TLS handshake
# timeout, connection reset, i/o timeout) is the request never landing at all.
docker_pull_is_access_rejection "denied: requested access to the resource is denied"
check "denied is an access rejection" "$?" 0
docker_pull_is_access_rejection "Error response from daemon: unauthorized: authentication required"
check "unauthorized is an access rejection" "$?" 0
docker_pull_is_access_rejection "Error response from daemon: pull access denied, repository does not exist or may require 'docker login': denied: requested access to the resource is denied"
check "403-shaped denied message is an access rejection" "$?" 0
docker_pull_is_access_rejection "Error response from daemon: Get \"https://ghcr.io/v2/\": net/http: TLS handshake timeout"
check "TLS handshake timeout is NOT an access rejection" "$?" 1
docker_pull_is_access_rejection "Error response from daemon: Get \"https://ghcr.io/v2/\": dial tcp: connection reset by peer"
check "connection reset is NOT an access rejection" "$?" 1
docker_pull_is_access_rejection "Error response from daemon: Get \"https://ghcr.io/v2/\": i/o timeout"
check "i/o timeout is NOT an access rejection" "$?" 1

exit "$fail"
