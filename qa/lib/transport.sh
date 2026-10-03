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

# A LOCAL environment failure — docker missing, the daemon down, no permission on
# the socket — is not an answer from the registry at all, and must be checked
# before the two predicates below: "permission denied" (a local socket problem)
# contains the bare word "denied", and "docker: command not found" contains the
# bare phrase "not found" — both would otherwise misclassify as the registry's own
# verdict. Review caught exactly this: a local failure reported as a real FAIL about
# the artifact's public visibility, when it is actually "this runner can't even ask".
docker_pull_is_local_environment_failure() { # $1 = combined stdout+stderr of a failed `docker pull`
  case "$1" in
    *"command not found"* | *"Cannot connect to the Docker daemon"* | *"docker.sock"* | *"is the docker daemon running"*) return 0 ;;
    *) return 1 ;;
  esac
}

# `docker pull`'s stderr on a *real* answer names it: "manifest unknown" / "name
# unknown" is the registry saying no such tag/repository exists — a real FAIL, the
# same "not_found" outcome classify_http_status reports for a 404. Deliberately NOT
# a bare `*"not found"*`: "docker: command not found" (the binary itself missing)
# contains that exact phrase and is a local failure, not a registry answer — caught
# by docker_pull_is_local_environment_failure, which callers must check first.
docker_pull_is_not_found() { # $1 = combined stdout+stderr of a failed `docker pull`
  case "$1" in
    *"manifest unknown"* | *"name unknown"*) return 0 ;;
    *) return 1 ;;
  esac
}

# A literal "403 Forbidden" / "401 Unauthorized" status phrase, or the registry's own
# denied/unauthorized verdict text, is an access rejection — also a real answer. Not
# a bare `*403*`: review flagged that a bare three-digit match can fire on a URL, a
# digest, or body text that happens to contain the digits coincidentally, with no
# bearing on access at all. Callers must check docker_pull_is_local_environment_failure
# first — "permission denied" talking to the local docker.sock also contains "denied".
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
#
# `--paginate` in "$@" repeats the whole status-line+headers+blank-line block once
# PER PAGE — measured directly (a 21-commit repo at per_page=2 produced 21 such
# blocks, each followed by that page's own filtered body, with no separating blank
# line between one page's body and the next page's status line). The original cut
# only the FIRST block and let every later page's headers flow straight into the
# body as if they were content — invisible on every repo in this family today (none
# has over 100 tags) and silently wrong the day one does. The awk script below strips
# EVERY status-line+headers block, however many pages there are, not just the first.
#
# A SECOND bug lived here too: this function never looked at gh's own exit status
# at all. If page 1 of a paginated fetch succeeds (200) and a later page fails
# partway (a transient 502), gh's overall exit is nonzero — but page 1's 200 was
# already on stdout, so reading only the FIRST status line (as the original did)
# reports a clean 200 over an incomplete, unreliable body. Live, not hypothetical:
# cxpak carries 38 tags today, already above gh's 30-per-page default, so any
# --paginate tags call on it fetches 2 real pages and is exposed to this.
#
# Single- vs multi-block responses are handled differently on purpose. A
# single-block response (no pagination, or a 404 that never got far enough to
# paginate) has gh's exit mirror that ONE status — nonzero on a 4xx/5xx too — and
# that status IS the answer, classified by the caller via classify_http_status, not
# here. Multiple blocks are only possible via --paginate; a fully successful
# paginated fetch has gh exit 0 AND every block 2xx, so anything else (a nonzero
# exit, or any block that isn't 2xx) means at least one page's request failed or
# answered with something other than success, and the aggregate body may be
# missing what that page would have contributed — a transport failure, not a
# status to classify.
gh_api_raw() { # args passed straight to `gh api -i`
  local raw rc statuses nblocks nbad first_status
  raw=$(gh api -i "$@" 2>&1)
  rc=$?
  statuses=$(printf '%s\n' "$raw" | awk '/^HTTP\// {print $2}')
  nblocks=$(printf '%s\n' "$statuses" | grep -c .)
  [ "$nblocks" -eq 0 ] && return 1
  first_status=$(printf '%s\n' "$statuses" | head -1)
  # A paginated call can lose a later page at the transport level (no HTTP/ line at
  # all), leaving one 200 block; gh's exit is then the only signal that the body is
  # partial. Single-page calls keep classifying 404/403 (gh exits nonzero on those).
  case " $* " in
    *" --paginate "*) [ "$rc" -ne 0 ] && return 1 ;;
  esac
  if [ "$nblocks" -gt 1 ]; then
    nbad=$(printf '%s\n' "$statuses" | grep -vc '^2..$')
    if [ "$rc" -ne 0 ] || [ "$nbad" -gt 0 ]; then
      return 1
    fi
  fi
  printf '%s\n' "$first_status"
  printf '%s\n' "$raw" | awk '
    /^HTTP\// { inheader = 1; next }
    inheader && /^\r?$/ { inheader = 0; next }
    inheader { next }
    { print }
  '
}
