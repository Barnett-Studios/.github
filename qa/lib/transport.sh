#!/usr/bin/env bash
# .github#15: a failed request is not evidence about the artifact unless the far end
# actually answered. These two predicates are the discriminator ghost-check.sh's
# gating halves were missing — read the failure, don't treat "something went wrong"
# as "the registry/API said no".

# curl *without* -f exits 0 on any HTTP response it receives, including 4xx/5xx — it
# only returns nonzero when the request never produced a response at all (DNS, TLS,
# connect, timeout, reset). That split is exactly "did the far end answer", so ghost-
# check's curl call sites drop -f and classify on curl's own exit code instead of on
# an empty body, which empty-on-404 and empty-on-timeout otherwise render identical.
#
# Not exhaustive — the six below are the ones this family has actually hit chasing
# this bug (curl(1)): 6 could not resolve host, 7 could not connect, 28 operation
# timeout, 35 SSL connect error, 52 empty reply from server, 56 recv failure.
curl_is_transport_failure() { # $1 = curl exit code
  case "$1" in
    6 | 7 | 28 | 35 | 52 | 56) return 0 ;;
    *) return 1 ;;
  esac
}

# docker pull's stderr on an access rejection names it: denied / unauthorized / a
# 403. Everything else this check has observed in the wild (TLS handshake timeout,
# connection reset, i/o timeout) is the request never reaching the registry's access
# check at all, and must not be read as the registry's verdict.
docker_pull_is_access_rejection() { # $1 = combined stdout+stderr of a failed `docker pull`
  case "$1" in
    *denied* | *unauthorized* | *403*) return 0 ;;
    *) return 1 ;;
  esac
}
