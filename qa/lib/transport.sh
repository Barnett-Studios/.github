#!/usr/bin/env bash
# .github#15: a failed request is not evidence about the artifact unless the far end
# actually answered. These predicates are the discriminators ghost-check.sh's gating
# halves were missing — read the failure, don't treat "something went wrong" as "the
# registry/API said no".

# Every curl call site here drops `-f` and reads the outcome via `-w '%{http_code}'`
# instead, so a real 404/401/403/429/5xx always makes curl exit 0 with that code
# captured — classify_http_status (below) is what turns the code into an outcome. A
# *nonzero* curl exit under that regime therefore means curl never got an HTTP
# response to classify at all: DNS, connect, TLS, timeout, reset, aborted.
#
# An earlier version of this fix whitelisted specific curl exit codes (6, 7, 28, 35,
# 52, 56) as "transport failure" and treated everything else as a real answer. Review
# caught that an incomplete whitelist silently re-admits this exact bug for any curl
# failure mode not enumerated — so this inverts it: trust the documented contract (0
# means curl got a response to report), never enumerate the ways curl can fail to.
curl_is_transport_failure() { # $1 = curl exit code
  [ "$1" -ne 0 ]
}

# Classify a numeric HTTP status from a response that was actually received (never
# call this on a transport failure — there is no status to classify). Echoes one of:
#   ok              2xx — the request succeeded
#   not_found       404 — the far end answered "no such thing", a real finding
#   access_rejected 401/403 — the far end answered "not for you", also a real finding
#   unknown         anything else (429, 5xx, a redirect not followed, 1xx, garbage) —
#                   the far end answered, but not with evidence about the artifact;
#                   429/5xx mean "ask later", not "here is the artifact's state"
classify_http_status() { # $1 = three-digit HTTP status
  case "$1" in
    2??) echo ok ;;
    404) echo not_found ;;
    401 | 403) echo access_rejected ;;
    *) echo unknown ;;
  esac
}

# `docker pull`'s stderr on a *real* answer names it: "manifest unknown" / "name
# unknown" / "not found" is the registry saying no such tag/repository exists — a
# real FAIL, the same "not_found" outcome classify_http_status reports for a 404.
docker_pull_is_not_found() { # $1 = combined stdout+stderr of a failed `docker pull`
  case "$1" in
    *"manifest unknown"* | *"name unknown"* | *"not found"*) return 0 ;;
    *) return 1 ;;
  esac
}

# A literal "403 Forbidden" / "401 Unauthorized" status phrase, or the registry's own
# denied/unauthorized verdict text, is an access rejection — also a real answer. Not
# a bare `*403*`: review flagged that a bare three-digit match can fire on a URL, a
# digest, or body text that happens to contain the digits coincidentally, with no
# bearing on access at all.
docker_pull_is_access_rejection() { # $1 = combined stdout+stderr of a failed `docker pull`
  case "$1" in
    *"403 Forbidden"* | *"401 Unauthorized"* | *denied* | *unauthorized*) return 0 ;;
    *) return 1 ;;
  esac
}

# `gh api -i "$@"` — `-i` is what exposes the HTTP status line even on a failure;
# without it a failed call's body IS the only output and the status is invisible
# (.github#15's own mechanism: a 500's body printed straight into a FAIL message,
# with no status to tell it apart from a real 404). `--jq` in "$@", if present, still
# filters the body on a 2xx (observed); gh does not apply it on a non-2xx response,
# so the body there is the raw JSON error — still useful for a caller's message.
#
# Prints the status on the first line and the body on the rest; the caller splits
# with `head -1` / `tail -n +2` and classifies the status with classify_http_status.
# Returns nonzero only when there is no status line at all — gh/the network never
# produced an HTTP response (DNS, connect, TLS, timeout): a transport failure, not a
# status code of any kind.
gh_api_raw() { # args passed straight to `gh api -i`
  local raw status
  raw=$(gh api -i "$@" 2>&1)
  status=$(printf '%s\n' "$raw" | head -1 | awk '/^HTTP\// {print $2}')
  [ -z "$status" ] && return 1
  printf '%s\n' "$status"
  printf '%s\n' "$raw" | awk 'body{print} /^\r?$/{body=1}'
}
