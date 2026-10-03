#!/usr/bin/env bash
# Ghost check for the Barnett Studios AI-SDLC component family.
#
# The question is "is the published artifact the thing its version claims to be, and can an
# outsider actually get it and run it?" — asked at every surface a consumer can reach.
#
# Note on the Scriptorium original this is adapted from: there, half 1 compares the deployed
# SHA against `main`, because Scriptorium continuously deploys `main`. That anchor does NOT
# port. This family ships *releases*, so `main` running ahead of the newest tag is the normal
# state between releases, not a defect — gating on it would fire on all nine repos, every pass,
# forever. The reference here is the **tag**, and the anchor is the image's recorded source
# commit. Main-lag is reported as advisory context only.
#
# Five halves. The first four ask "is the artifact what it claims to be"; the fifth asks the
# separate question "is what it claims to be still current", which no amount of agreement can
# answer:
#   1. PROVENANCE — the published image's org.opencontainers.image.revision is exactly the
#      commit its own version tag points at, and that commit is on main. This is the real
#      check: it verifies the artifact against *source*, not against another artifact's name.
#   2. REACH      — `latest` resolves to the same digest as the newest semver tag, anonymously.
#      A consumer runs `docker pull`, which resolves `latest`; if it lags they silently get old
#      code while every version string still agrees.
#   3. CRATE      — for crates.io members, the published max version equals the newest tag and
#      nothing in the line is yanked.
#   4. CONTENT    — the tag's tree declares the version the tag names.
#   5. CURRENCY   — merged `fix(` PRs that are on main but not in the release. ADVISORY.
#   BOOT          — (with --boot) the image actually executes.
#
# Halves 2-4 are all "compare a published thing to another published thing" and can be green
# together while the image was built from the wrong source. Only half 1 can see that.
#
# And all of 1-4 can be green while the release is materially behind: they verify identity,
# never currency. Half 5 exists because that combination was observed, not imagined.
#
# Runs anonymously on purpose: a token with read:packages walks a path no consumer walks, and
# would go green against an image that had silently become private.
#
# Needs: curl, jq, gh. Docker only for --boot.
# Usage: ./ghost-check.sh [--boot]
#
# Exit / outcome (.github#15): a request that never reached the far end at all (DNS, connect,
# TLS, timeout, reset) is reported UNKNOWN, never FAIL — only a real answer (a status code, a
# registry verdict) is evidence about the artifact, and 404/401/403 are real answers with their
# own specific FAIL. UNKNOWN is deliberately a different word from this file's pre-existing
# advisory WARN (half 4's unverifiable tag-vs-tree claim, half 5's currency gaps): those fire on
# an ordinary, understood, permanent state of some components (cordon/slicr carry no in-tree
# version file) and were never meant to block a clean pass; UNKNOWN fires on "the pass itself
# could not establish an answer" and does.
#   exit 0  GHOST CHECK GREEN        — every check ran and found nothing wrong
#   exit 1  GHOST CHECK RED          — at least one check got a real answer that is a defect
#   exit 2  GHOST CHECK INCONCLUSIVE — no FAIL, but at least one check never got an answer at
#                                      all; findings from checks that DID run still stand, but
#                                      nothing here establishes the family is clean — re-run

set -uo pipefail

ORG=Barnett-Studios
# component : is-on-crates.io
IMAGES=(abproof attestr baseplate cascadr commitward cordon cxpak slicr)
CRATES=(abproof attestr baseplate cascadr commitward cxpak)
# corpus is a git-only eval set: no image, no crate. `cordon` and `corpus` on crates.io are
# UNRELATED third-party crates (wgoodall01/cordon, DanCardin/corpus) — never version-compare
# against them, it manufactures a mismatch out of nothing.
VERSIONED_REPOS=(abproof attestr baseplate cascadr commitward cordon corpus cxpak slicr)

ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

BOOT=0
[ "${1:-}" = "--boot" ] && BOOT=1

# shellcheck source=./lib/transport.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/transport.sh"
# shellcheck source=./lib/outcome.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/outcome.sh"
note_init

# .github#15: every curl site below drops `-f`/`-s`-only and reads `-w '%{http_code}'`
# instead, classified via lib/transport.sh's classify_http_status. Return code convention,
# shared by every function in this file that talks to ghcr:
#   0  ok              — stdout carries the parsed value
#   1  unknown          — no response at all, or a response that is not evidence (429/5xx/…)
#   2  not_found        — a real 404: no such repository/tag/manifest
#   3  access_rejected  — a real 401/403: not public
ghcr_token() { # repo
  local resp rc status body
  resp=$(curl -sS -w '\n%{http_code}' \
    "https://ghcr.io/token?scope=repository%3A$(echo "$ORG" | tr 'A-Z' 'a-z')%2F${1}%3Apull&service=ghcr.io" 2>&1)
  rc=$?
  curl_is_transport_failure "$rc" && return 1
  status=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$(classify_http_status "$status")" in
    ok) printf '%s' "$body" | jq -r '.token // empty' ;;
    not_found) return 2 ;;
    access_rejected) return 3 ;;
    *) return 1 ;;
  esac
}
digest() { # repo token ref
  local resp rc status headers
  resp=$(curl -sS -o /dev/null -D - -w '\n%{http_code}' -H "Authorization: Bearer $2" -H "Accept: $ACCEPT" \
    "https://ghcr.io/v2/barnett-studios/${1}/manifests/${3}" 2>&1)
  rc=$?
  curl_is_transport_failure "$rc" && return 1
  status=$(printf '%s' "$resp" | tail -1)
  headers=$(printf '%s' "$resp" | sed '$d')
  case "$(classify_http_status "$status")" in
    ok) printf '%s' "$headers" | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}' ;;
    not_found) return 2 ;;
    access_rejected) return 3 ;;
    *) return 1 ;;
  esac
}
# The config blob carries org.opencontainers.image.* as Labels. The multi-arch index itself
# carries no annotations, so descend to a real platform manifest first — and skip the
# attestation manifests, whose platform is literally {os: unknown, architecture: unknown}.
image_labels() { # repo token ref
  local idx_resp idx_rc idx_status idx m mf_resp mf_rc mf_status mf cfg blob_resp blob_rc blob_status blob
  idx_resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $2" -H "Accept: $ACCEPT" \
    "https://ghcr.io/v2/barnett-studios/${1}/manifests/${3}" 2>&1)
  idx_rc=$?
  curl_is_transport_failure "$idx_rc" && return 1
  idx_status=$(printf '%s' "$idx_resp" | tail -1)
  idx=$(printf '%s' "$idx_resp" | sed '$d')
  case "$(classify_http_status "$idx_status")" in
    ok) ;;
    not_found) return 2 ;;
    access_rejected) return 3 ;;
    *) return 1 ;;
  esac
  m=$(echo "$idx" | jq -r 'if .manifests then (.manifests[]|select(.platform.os!="unknown" and .platform.architecture!="unknown")|.digest) else empty end' | head -1)
  if [ -n "$m" ]; then
    mf_resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $2" -H "Accept: $ACCEPT" \
      "https://ghcr.io/v2/barnett-studios/${1}/manifests/${m}" 2>&1)
    mf_rc=$?
    curl_is_transport_failure "$mf_rc" && return 1
    mf_status=$(printf '%s' "$mf_resp" | tail -1)
    mf=$(printf '%s' "$mf_resp" | sed '$d')
    case "$(classify_http_status "$mf_status")" in
      ok) ;;
      not_found) return 2 ;;
      access_rejected) return 3 ;;
      *) return 1 ;;
    esac
  else
    mf="$idx"
  fi
  cfg=$(echo "$mf" | jq -r '.config.digest // empty')
  # A real 2xx response with no config digest at all is a genuine absence (a manifest
  # that is not an image/index this check understands), not a transient — not_found.
  [ -z "$cfg" ] && return 2
  blob_resp=$(curl -sS -L -w '\n%{http_code}' -H "Authorization: Bearer $2" \
    "https://ghcr.io/v2/barnett-studios/${1}/blobs/${cfg}" 2>&1)
  blob_rc=$?
  curl_is_transport_failure "$blob_rc" && return 1
  blob_status=$(printf '%s' "$blob_resp" | tail -1)
  blob=$(printf '%s' "$blob_resp" | sed '$d')
  case "$(classify_http_status "$blob_status")" in
    ok) printf '%s' "$blob" | jq -r '.config.Labels // {}' ;;
    not_found) return 2 ;;
    access_rejected) return 3 ;;
    *) return 1 ;;
  esac
}
newest_semver() { printf '%s\n' "$@" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }

# macOS ships bash 3.2, which has no associative arrays. A temp file keyed by component is
# the portable substitute; the supported platform is macOS, so `declare -A` is not available.
VERMAP=$(mktemp)
trap 'rm -f "$VERMAP"' EXIT
vers() { awk -v k="$1" '$1==k{print $2; exit}' "$VERMAP"; }

echo "== half 1: provenance — the image is built from the commit its version tag names"
for c in "${IMAGES[@]}"; do
  tok=$(ghcr_token "$c"); rc=$?
  case $rc in
    0) ;;
    2) note "$c" FAIL "no such repository — the image is not public"; continue ;;
    3) note "$c" FAIL "anonymous pull token rejected — the image is not public"; continue ;;
    *) note "$c" UNKNOWN "cannot reach ghcr to get a pull token for $c — provenance unknown this pass"; continue ;;
  esac
  if [ -z "$tok" ]; then note "$c" FAIL "no anonymous pull token — the image is not public"; continue; fi

  labels=$(image_labels "$c" "$tok" latest); rc=$?
  case $rc in
    0) ;;
    2) note "$c" FAIL "cannot read :latest config — no such tag"; continue ;;
    3) note "$c" FAIL ":latest config access rejected — the image is not public"; continue ;;
    *) note "$c" UNKNOWN "cannot reach ghcr to read :latest config for $c — provenance unknown this pass"; continue ;;
  esac
  ver=$(echo "$labels" | jq -r '."org.opencontainers.image.version" // empty')
  rev=$(echo "$labels" | jq -r '."org.opencontainers.image.revision" // empty')
  if [ -z "$ver" ] || [ -z "$rev" ]; then
    note "$c" FAIL ":latest carries no image.version/revision label — provenance unverifiable"; continue
  fi
  echo "$c $ver" >> "$VERMAP"

  # /tags returns commit.sha already peeled through annotated tags. `-i` is what
  # exposes the status even on a non-2xx (.github#15) — a 404 here means the
  # repository itself does not exist (a real finding); 429/5xx/no-response at all
  # is UNKNOWN. Status read before any pipe to `head`, not after: `| head -1` takes
  # head's exit status (0 regardless of gh), the same trap .github#11 fixed in half 5.
  if ! raw=$(gh_api_raw "repos/$ORG/$c/tags" --paginate --jq ".[]|select(.name==\"v${ver}\")|.commit.sha"); then
    note "$c" UNKNOWN "cannot query tags for $c — provenance unknown this pass (no response at all)"; continue
  fi
  status=$(printf '%s\n' "$raw" | head -1)
  case "$(classify_http_status "$status")" in
    ok) tagsha=$(printf '%s\n' "$raw" | tail -n +2 | head -1) ;;
    not_found) note "$c" FAIL "repos/$ORG/$c does not exist — an image nobody can trace to source"; continue ;;
    *) note "$c" UNKNOWN "cannot query tags for $c — provenance unknown this pass (status=$status)"; continue ;;
  esac
  if [ -z "$tagsha" ]; then
    note "$c" FAIL ":latest claims $ver but no tag v$ver exists — an image nobody can trace to source"; continue
  fi
  if [ "$rev" != "$tagsha" ]; then
    note "$c" FAIL ":latest($ver) built from ${rev:0:12} but v$ver is ${tagsha:0:12} — image and tag disagree"; continue
  fi

  # A 404 here means `rev` (or `main`) does not exist at all — a real, different
  # finding from "exists but diverged" (a 200 whose .status is neither identical nor
  # behind, handled below). 429/5xx/no-response is UNKNOWN, never a silent FAIL — a
  # transient 500 used to print straight into the FAIL message (`status=`, the error
  # body, or empty) with nothing to tell it apart from a real divergence (.github#15).
  if ! raw=$(gh_api_raw "repos/$ORG/$c/compare/main...${rev}" --jq '.status'); then
    note "$c" UNKNOWN "cannot compare ${rev:0:12} against main — provenance unknown this pass (no response at all)"; continue
  fi
  status=$(printf '%s\n' "$raw" | head -1)
  case "$(classify_http_status "$status")" in
    ok) onmain=$(printf '%s\n' "$raw" | tail -n +2 | head -1) ;;
    not_found) note "$c" FAIL "${rev:0:12} does not exist on $c — the published commit is unreachable"; continue ;;
    *) note "$c" UNKNOWN "cannot compare ${rev:0:12} against main — provenance unknown this pass (status=$status)"; continue ;;
  esac
  case "$onmain" in
    identical|behind) ;;
    *) note "$c" FAIL "the published commit ${rev:0:12} is not an ancestor of main (status=$onmain)"; continue ;;
  esac
  lag=$(gh api "repos/$ORG/$c/compare/v${ver}...main" --jq '.ahead_by' 2>/dev/null)
  note "$c" ok "v$ver @ ${rev:0:12} on main · main is +${lag:-?} commits (advisory)"
done

echo "== half 2: reach — what an anonymous \`docker pull\` actually resolves"
for c in "${IMAGES[@]}"; do
  tok=$(ghcr_token "$c"); rc=$?
  case $rc in
    0) ;;
    2) note "$c" FAIL "no such repository — the image is not public"; continue ;;
    3) note "$c" FAIL "anonymous pull token rejected — the image is not public"; continue ;;
    *) note "$c" UNKNOWN "cannot reach ghcr to get a pull token for $c — reach unknown this pass"; continue ;;
  esac
  [ -z "$tok" ] && continue

  # .github#15: no `-f` here either, same reason as ghcr_token()/digest() — curl's
  # own exit code only tells us whether the registry answered AT ALL; the status
  # (via `-w`) tells us what it answered. A real empty tag list (a legitimate "no
  # tags", 200) must not read the same as a 404 (no such repository) or a request
  # that never landed.
  resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $tok" \
    "https://ghcr.io/v2/barnett-studios/${c}/tags/list" 2>&1)
  rc=$?
  if curl_is_transport_failure "$rc"; then
    note "$c" UNKNOWN "cannot reach the registry to list tags for $c — reach unknown this pass"; continue
  fi
  status=$(printf '%s' "$resp" | tail -1)
  tags_body=$(printf '%s' "$resp" | sed '$d')
  case "$(classify_http_status "$status")" in
    ok) tags=$(printf '%s' "$tags_body" | jq -r '.tags[]?' 2>/dev/null) ;;
    not_found) note "$c" FAIL "no such repository on ghcr — the README's docker pull gets nothing"; continue ;;
    access_rejected) note "$c" FAIL "tags list access rejected for $c — the image is not public"; continue ;;
    *) note "$c" UNKNOWN "cannot reach the registry to list tags for $c — reach unknown this pass (status=$status)"; continue ;;
  esac
  newest=$(newest_semver $tags)
  [ -z "$newest" ] && { note "$c" FAIL "no semver tag published"; continue; }

  dl=$(digest "$c" "$tok" latest); rc=$?
  case $rc in
    0) ;;
    2) note "$c" FAIL "no :latest manifest — the README's docker pull gets nothing"; continue ;;
    3) note "$c" FAIL ":latest manifest access rejected for $c — the image is not public"; continue ;;
    *) note "$c" UNKNOWN "cannot reach :latest manifest for $c — reach unknown this pass"; continue ;;
  esac
  dn=$(digest "$c" "$tok" "$newest"); rc=$?
  case $rc in
    0) ;;
    2) note "$c" FAIL "no :$newest manifest — a published tag with no manifest"; continue ;;
    3) note "$c" FAIL ":$newest manifest access rejected for $c — the image is not public"; continue ;;
    *) note "$c" UNKNOWN "cannot reach :$newest manifest for $c — reach unknown this pass"; continue ;;
  esac

  if [ -z "$dl" ]; then note "$c" FAIL "no :latest — the README's docker pull gets nothing"
  elif [ "$dl" != "$dn" ]; then note "$c" FAIL ":latest is STALE vs $newest — consumers silently receive an older image"
  elif [ -n "$(vers "$c")" ] && [ "$newest" != "$(vers "$c")" ]; then
    note "$c" FAIL ":latest labels itself $(vers "$c") but $newest is published — latest is not the newest"
  else note "$c" ok ":latest == :$newest (${dl:0:19})"; fi
done

echo "== half 3: crates.io — the published crate matches the tag and is not yanked"
for c in "${CRATES[@]}"; do
  # .github#15 review requirement 2: this site was still `curl -fsS` with no status
  # read — a transient failure returned empty `$j`, `repo` parsed out of it as
  # empty, and the name-collision guard below turned "crates.io didn't answer" into
  # a real-sounding "points at '' — not this org's crate" FAIL. Same `-w`/classify
  # treatment as every other curl site in this file.
  resp=$(curl -sS -w '\n%{http_code}' "https://crates.io/api/v1/crates/$c" -H 'User-Agent: barnett-studios-qa' 2>&1)
  rc=$?
  if curl_is_transport_failure "$rc"; then
    note "$c" UNKNOWN "cannot reach crates.io for $c — crate check unknown this pass"; continue
  fi
  status=$(printf '%s' "$resp" | tail -1)
  j=$(printf '%s' "$resp" | sed '$d')
  case "$(classify_http_status "$status")" in
    ok) ;;
    not_found) note "$c" FAIL "crates.io has no crate named $c"; continue ;;
    *) note "$c" UNKNOWN "crates.io returned status=$status for $c — crate check unknown this pass"; continue ;;
  esac
  repo=$(echo "$j" | jq -r '.crate.repository // ""')
  # Guard against name collisions with unrelated crates before believing any version.
  case "$repo" in
    *"github.com/$ORG/$c"*) ;;
    *) note "$c" FAIL "crates.io/$c points at '$repo' — not this org's crate"; continue ;;
  esac
  max=$(echo "$j" | jq -r '.crate.max_version')
  yanked=$(echo "$j" | jq -r '[.versions[]|select(.yanked)|.num]|join(",")')
  want=$(vers "$c")
  if [ -n "$want" ] && [ "$max" != "$want" ]; then
    note "$c" FAIL "crates.io has $max but the published image is $want — the two consumer paths disagree"
  elif [ -n "$yanked" ]; then note "$c" ok "$max (yanked in line: $yanked)"
  else note "$c" ok "$max"; fi
done

# shellcheck source=./lib/version_declarations.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/version_declarations.sh"

echo "== half 4: the tag's own content agrees with the tag's name"
# corpus#30's defect class, generalised: a tag named v0.2.0 whose tree declares 0.4.0. Reported
# as WARN, not FAIL — a red ghost check means "your findings this pass are untrustworthy, stop",
# and corpus tag drift does not make a finding about cascadr wrong. Gating every future pass on
# an already-filed product defect trains the loop to ignore its own red.
for c in "${VERSIONED_REPOS[@]}"; do
  # .github#15 review requirement 5: both lookups below were unguarded `gh api`
  # calls with no status read at all — the exact bug class this whole file exists
  # to fix, just not yet applied here. A failed call leaves its raw error JSON on
  # stdout (gh does not apply --jq on a non-2xx); `tag`/`sha` would then be that
  # JSON blob rather than empty, so `[ -z ]` misses it and the next lookup searches
  # for a tag literally named the error body. Guarded the same way half 1 already
  # is: `if ! x=$(...)` reads gh's own exit status, never the body.
  if ! tag=$(gh api "repos/$ORG/$c/tags" --jq '.[0].name' 2>/dev/null); then
    note "$c" UNKNOWN "cannot list tags for $c — half 4 unknown this pass (no response at all)"; continue
  fi
  [ -z "$tag" ] && { note "$c" WARN "no tags at all"; continue; }
  if ! sha_all=$(gh api "repos/$ORG/$c/tags" --jq ".[]|select(.name==\"$tag\")|.commit.sha" 2>/dev/null); then
    note "$c" UNKNOWN "cannot resolve $tag to a commit for $c — half 4 unknown this pass (no response at all)"; continue
  fi
  sha=$(printf '%s\n' "$sha_all" | head -1)
  # `|| decls=""` mapped a FAILED tree listing onto the identical state as "the tree was read
  # and declares nothing", and the message below then asserted a fact about a tree that was
  # never listed. That is the rule half 5 states, broken by the enumeration half 4 now depends
  # on: a query that failed is not an empty result. The cost is not a false green — it is a
  # WARN with the wrong cause, which is how a transient 502 gets filed as a product defect
  # (.github#15, where a transient 500 accused attestr of unpublished provenance). Reported as
  # UNKNOWN, not WARN (review requirement 5): this is a genuine transient request failure, not
  # the permanent "no version file in this tree" state the WARN two blocks down reports.
  if ! decls=$(version_declarations "$c" "$sha"); then
    note "$c" UNKNOWN "cannot list $tag's tree for $c — half 4 unknown this pass (the API call \
failed; this says nothing about what the tree declares)"
    continue
  fi
  # "Nothing to contradict" was reported as `ok`, and it is not one. The file this half
  # compares against is simply absent at that ref, so the comparison did not happen — a check
  # that could not run is UNKNOWN, not a pass. It fired on two of the nine: cordon and slicr
  # carry no VERSION or Cargo.toml at their latest tag, and both their CONTRACTs assert
  # "`VERSION` holds this component's version and every release carries a matching
  # `v<version>` tag" — the exact claim this half exists to verify, waved through on the
  # strength of the file being missing. A future tag cut without VERSION in the tree would be
  # waved through the same way.
  #
  # Still not a FAIL, for half 4's stated reason: a red ghost check means "stop, your findings
  # are untrustworthy", and an unverifiable version claim about one component does not make a
  # finding about another wrong. `main`'s value is printed as context, not compared — this
  # half is about the TAG's tree, and a tag whose tree lacks the file cannot be fixed by
  # reading a different ref.
  if [ -z "$decls" ]; then
    mv=$(gh api "repos/$ORG/$c/contents/VERSION?ref=main" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n ')
    note "$c" WARN "$tag declares no version anywhere in its tree, so the tag-vs-tree claim is UNVERIFIABLE${mv:+ (main says $mv)}"
    continue
  fi
  n=$(printf '%s\n' "$decls" | grep -c .)
  bad=$(printf '%s\n' "$decls" | awk -F= -v t="$tag" '"v" $2 != t {printf "%s%s=%s", (c++?", ":""), $1, $2}')
  # The count is printed on the green line too. "ok" over a subset is what this half used to
  # say, and the number is the only thing that tells a reader which question was answered.
  if [ -n "$bad" ]; then
    note "$c" WARN "$tag names a tree that declares $bad — a version pin misdescribes what it pins ($n declaration(s) compared)"
  else note "$c" ok "$tag == every one of $n declaration(s)"; fi
done

echo "== half 5: currency — merged fixes the release does not contain (advisory, a FLOOR)"
# The four halves above all test AGREEMENT: tag↔commit, latest↔digest, crates.io↔tag,
# content↔name. Every one of them can be green while the version consumers install still
# contains defects the repo has already closed. That is not hypothetical: the pass logged at
# 2026-08-14T02:08Z measured cascadr#9 (the cache-integrity guard) and baseplate#5 (the
# java_test false positives) live in the published artifacts with all four halves green.
#
# `main is +N commits (advisory)` in half 1 is the only existing hint, and it is the wrong
# resolution — +13 commits reads identically whether they are typo fixes or a security guard.
#
# ADVISORY, never a FAIL: nothing here touches `fail`. Shipping cadence is the maintainer's
# call, and a red ghost check means "your findings this pass are untrustworthy, stop" — which
# release debt does not make true.
#
# Deliberately narrow. Only merged PRs whose title carries a conventional-commit `fix` scope
# (`fix(...)` or `fix:`); docs/test/feat/refactor are excluded so a docs-heavy week does not
# cry wolf. This UNDER-reports on purpose — a fix that shipped under `feat(` or an
# unconventional title is missed. For an advisory line, silence on a real fix is a smaller
# harm than noise on a docs commit, and the count is a floor, not a total.
#
# A FAILED QUERY IS NOT A CLEAN RESULT — the same rule half 4 states three blocks up, "a
# check that could not run is UNKNOWN, not a pass", applied to the two lookups here that
# could print `ok` without an answer. `2>/dev/null` discards the diagnostic and `$( )`
# discards the status, so an empty result reads the same whether the query said "none" or
# never answered. Driven, with only the named query failing and everything else real:
#
#   pulls query fails   ->  all 9 printed `ok <tag> carries every merged fix`, and the run
#                           still ended GHOST CHECK GREEN — 33 unreleased fixes erased
#   tags query fails    ->  all 9 printed `ok no tags — nothing to be behind`, while half 4
#                           printed `WARN no tags at all` for the very same failure
#
# The second one is why both are fixed and not just the reported one: `[ -z "$tag" ]` looks
# like a guard, and it is — it just resolves the wrong way. This matters more than a usual
# flake because the rotation reads a FALLING debt count as "a release shipped"; a transient
# failure produces exactly that signal, so the instrument can announce a release that did not
# happen (.github#11).
for c in "${VERSIONED_REPOS[@]}"; do
  # Review requirement 5: the four guards below report UNKNOWN, not WARN — each is
  # a genuine transient request failure (gh never got a usable response), the same
  # class half 1/2/3's UNKNOWN sites report, not the permanent "this value is
  # legitimately absent" state half 4's WARN two sections up reports.
  if ! tag=$(gh api "repos/$ORG/$c/tags" --jq '.[0].name' 2>/dev/null); then
    note "$c" UNKNOWN "cannot list tags — currency unknown this pass"; continue
  fi
  [ -z "$tag" ] && { note "$c" ok "no tags — nothing to be behind"; continue; }
  # Guarded too, and my reason for exempting it was wrong in a way worth recording: I argued
  # that a failure here lands on the `tagdate` WARN below, so it could not print a clean
  # line. It can. `gh` writes the API ERROR BODY TO STDOUT — `{"message":"No commit found
  # for SHA: ",…}` — so `tagdate` is that JSON blob, `[ -z ]` is false, the WARN is skipped,
  # and the blob becomes awk's `d`. `{` sorts above every digit, so `$1 > d` is false for
  # every merged PR, `n=0`, and all nine components print `ok <tag> carries every merged
  # fix` — 33 unreleased fixes erased by a query that failed.
  #
  # Which is the same defect one layer along: emptiness is not a failure signal, because a
  # failed `gh` leaves a JSON object on stdout. Only the STATUS says whether it ran, and
  # `if ! x=$(…)` reads it and never looks at stdout at all.
  #
  # The pipe is separate from the status read on purpose: `x=$(gh … | head -1)` takes
  # `head`'s status, which is 0 whatever `gh` did — the same trap as the `| awk` below.
  if ! sha=$(gh api "repos/$ORG/$c/tags" --jq ".[]|select(.name==\"$tag\")|.commit.sha" 2>/dev/null); then
    note "$c" UNKNOWN "cannot resolve $tag to a commit — currency unknown this pass"; continue
  fi
  sha="$(printf '%s\n' "$sha" | head -1)"
  [ -z "$sha" ] && { note "$c" WARN "$tag resolves to no commit — currency unknown"; continue; }
  # The release PR itself merges within a second of the tag commit, so the boundary is fuzzy
  # by about that much. It only ever admits the release commit, which is not a `fix(`.
  if ! tagdate=$(gh api "repos/$ORG/$c/commits/$sha" --jq '.commit.committer.date' 2>/dev/null); then
    note "$c" UNKNOWN "cannot date $tag — currency unknown this pass"; continue
  fi
  # Status AND emptiness: a call that succeeds but yields nothing is also not a date.
  [ -z "$tagdate" ] && { note "$c" WARN "cannot date $tag — currency unknown"; continue; }
  # TSV out of jq, comparison in awk: ISO-8601 compares correctly as a string, and this keeps
  # the jq filter single-quoted instead of nesting shell quotes inside a jq regex.
  # Two steps, so the query's status is consulted before its emptiness is interpreted. As one
  # pipeline the assignment took awk's status and the failure vanished.
  if ! merged=$(gh api "repos/$ORG/$c/pulls?state=closed&per_page=100" --paginate \
                  --jq '.[]|select(.merged_at!=null)|"\(.merged_at)\t\(.number)\t\(.title)"' 2>/dev/null); then
    note "$c" UNKNOWN "cannot list merged PRs — currency unknown this pass"; continue
  fi
  debt=$(printf '%s\n' "$merged" \
         | awk -F'\t' -v d="$tagdate" '$1>d && $3 ~ /^fix[(:]/ {printf "#%s ", $2}')
  n=$(printf '%s' "$debt" | tr ' ' '\n' | grep -c '^#')
  if [ "$n" = 0 ]; then note "$c" ok "$tag carries every merged fix"
  else note "$c" DEBT "$n unreleased fix(es) since $tag: ${debt% }"; fi
done

if [ "$BOOT" = 1 ]; then
  echo "== boot: the image executes"
  for c in "${IMAGES[@]}"; do
    # ${c} braces are load-bearing under zsh, where "$c:latest" applies the :l (lowercase)
    # modifier and silently yields `abproofatest:latest`. The registry answers `denied`, which
    # is indistinguishable from a private image. Cost this check an hour and a whole false
    # theory about stale docker credentials.
    img="ghcr.io/barnett-studios/${c}:latest"
    # .github#15: a transient transport failure (TLS handshake timeout, connection
    # reset, i/o timeout — measured hitting this exact line at ~8% per request) is
    # not evidence about the image at all. "manifest unknown"/"name unknown" is a
    # real "no such image" answer; denied/unauthorized/a literal 403 or 401 status
    # is a real access rejection. Checked LAST, and in that order — not first:
    # local-environment-failure must run before either, because "permission denied"
    # talking to a local docker.sock contains "denied", and "docker: command not
    # found" is a local failure too; both would otherwise read as the registry's
    # own verdict (review requirement 3). Read the error rather than treat every
    # nonzero pull the same.
    if ! pull_out=$(docker pull "$img" 2>&1); then
      if docker_pull_is_local_environment_failure "$pull_out"; then
        note "$c" UNKNOWN "cannot pull $c at all — local docker environment unknown this pass: $(printf '%s' "$pull_out" | tail -1)"; continue
      elif docker_pull_is_not_found "$pull_out"; then
        note "$c" FAIL "anonymous docker pull: no such image/tag: $(printf '%s' "$pull_out" | tail -1)"; continue
      elif docker_pull_is_access_rejection "$pull_out"; then
        note "$c" FAIL "anonymous docker pull rejected: $(printf '%s' "$pull_out" | tail -1)"; continue
      else
        note "$c" UNKNOWN "cannot reach the registry to pull $c — reach unknown this pass: $(printf '%s' "$pull_out" | tail -1)"; continue
      fi
    fi
    if [ "$c" = cordon ]; then
      # cordon's image is deliberately NOT a CLI: it is the swappable <runtime> argument to
      # cordon-run.sh, documented as `git + python3 + build-essential` with no entrypoint.
      # Probing it with --help asserts a promise its README explicitly disclaims.
      docker run --rm "$img" python3 -c 'print(1)' >/dev/null 2>&1 \
        && note "$c" ok "runtime image has the documented python3" \
        || note "$c" FAIL "runtime image lacks the documented python3"
    else
      out=$(timeout 90 docker run --rm "$img" --help 2>&1); rc=$?
      # "Does it boot", not "does --help exit 0": a usage message on rc=2 is a booted binary
      # making a style choice (slicr does exactly this). 125/126/127 mean nothing ran.
      #
      # 124 is `timeout` killing it, and it must FAIL rather than read as "executes". This
      # check reported `baseplate ok executes (rc=124)` on 2026-08-14 — i.e. it called a
      # 90-second hang a passing boot. A hang is the failure mode this family exists to bound
      # (see cordon's README: "the failure you actually get is a hang, not an escape"), so it
      # is the last thing the boot probe should wave through. That instance did not reproduce
      # in four subsequent runs and was not filed; the misclassification is the real defect.
      case "$rc" in
        124) note "$c" FAIL "HUNG — killed at the 90s deadline; re-run, and file it if it recurs" ;;
        125|126|127) note "$c" FAIL "does not execute (rc=$rc): $(echo "$out"|head -1)" ;;
        *) if [ -z "$out" ]; then note "$c" FAIL "ran but produced no output"
           else note "$c" ok "executes (rc=$rc)"; fi ;;
      esac
    fi
  done
fi

echo
# .github#15: GREEN must mean every check ran and found nothing wrong — not "nothing
# that ran found anything wrong". A pass where some check never got an answer at all
# is not evidence the family is clean; it is evidence this pass didn't finish asking.
# ghost_check_outcome (qa/lib/outcome.sh) is the tested decision; this just applies it.
ghost_check_outcome
exit $?
