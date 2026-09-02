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
fail=0
note() { printf '%-11s %s\n' "$1" "$2"; }

ghcr_token() {
  curl -fsS "https://ghcr.io/token?scope=repository%3A$(echo "$ORG" | tr 'A-Z' 'a-z')%2F${1}%3Apull&service=ghcr.io" | jq -r '.token // empty'
}
digest() { # repo token ref
  curl -fsS -o /dev/null -D - -H "Authorization: Bearer $2" -H "Accept: $ACCEPT" \
    "https://ghcr.io/v2/barnett-studios/${1}/manifests/${3}" \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}
# The config blob carries org.opencontainers.image.* as Labels. The multi-arch index itself
# carries no annotations, so descend to a real platform manifest first — and skip the
# attestation manifests, whose platform is literally {os: unknown, architecture: unknown}.
image_labels() { # repo token ref
  local idx m mf cfg
  idx=$(curl -fsS -H "Authorization: Bearer $2" -H "Accept: $ACCEPT" "https://ghcr.io/v2/barnett-studios/${1}/manifests/${3}")
  m=$(echo "$idx" | jq -r 'if .manifests then (.manifests[]|select(.platform.os!="unknown" and .platform.architecture!="unknown")|.digest) else empty end' | head -1)
  if [ -n "$m" ]; then
    mf=$(curl -fsS -H "Authorization: Bearer $2" -H "Accept: $ACCEPT" "https://ghcr.io/v2/barnett-studios/${1}/manifests/${m}")
  else mf="$idx"; fi
  cfg=$(echo "$mf" | jq -r '.config.digest // empty')
  [ -z "$cfg" ] && return 1
  curl -fsSL -H "Authorization: Bearer $2" "https://ghcr.io/v2/barnett-studios/${1}/blobs/${cfg}" | jq -r '.config.Labels // {}'
}
newest_semver() { printf '%s\n' "$@" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }

# macOS ships bash 3.2, which has no associative arrays. A temp file keyed by component is
# the portable substitute; the supported platform is macOS, so `declare -A` is not available.
VERMAP=$(mktemp)
trap 'rm -f "$VERMAP"' EXIT
vers() { awk -v k="$1" '$1==k{print $2; exit}' "$VERMAP"; }

echo "== half 1: provenance — the image is built from the commit its version tag names"
for c in "${IMAGES[@]}"; do
  tok=$(ghcr_token "$c")
  if [ -z "$tok" ]; then note "$c" "FAIL no anonymous pull token — the image is not public"; fail=1; continue; fi
  labels=$(image_labels "$c" "$tok" latest) || { note "$c" "FAIL cannot read :latest config — no such tag?"; fail=1; continue; }
  ver=$(echo "$labels" | jq -r '."org.opencontainers.image.version" // empty')
  rev=$(echo "$labels" | jq -r '."org.opencontainers.image.revision" // empty')
  if [ -z "$ver" ] || [ -z "$rev" ]; then
    note "$c" "FAIL :latest carries no image.version/revision label — provenance unverifiable"; fail=1; continue
  fi
  echo "$c $ver" >> "$VERMAP"
  # /tags returns commit.sha already peeled through annotated tags.
  tagsha=$(gh api "repos/$ORG/$c/tags" --paginate --jq ".[]|select(.name==\"v${ver}\")|.commit.sha" 2>/dev/null | head -1)
  if [ -z "$tagsha" ]; then
    note "$c" "FAIL :latest claims $ver but no tag v$ver exists — an image nobody can trace to source"; fail=1; continue
  fi
  if [ "$rev" != "$tagsha" ]; then
    note "$c" "FAIL :latest($ver) built from ${rev:0:12} but v$ver is ${tagsha:0:12} — image and tag disagree"; fail=1; continue
  fi
  onmain=$(gh api "repos/$ORG/$c/compare/main...${rev}" --jq '.status' 2>/dev/null)
  case "$onmain" in
    identical|behind) ;;
    *) note "$c" "FAIL the published commit ${rev:0:12} is not an ancestor of main (status=$onmain)"; fail=1; continue ;;
  esac
  lag=$(gh api "repos/$ORG/$c/compare/v${ver}...main" --jq '.ahead_by' 2>/dev/null)
  note "$c" "ok   v$ver @ ${rev:0:12} on main · main is +${lag:-?} commits (advisory)"
done

echo "== half 2: reach — what an anonymous \`docker pull\` actually resolves"
for c in "${IMAGES[@]}"; do
  tok=$(ghcr_token "$c"); [ -z "$tok" ] && continue
  tags=$(curl -fsS -H "Authorization: Bearer $tok" "https://ghcr.io/v2/barnett-studios/${c}/tags/list" | jq -r '.tags[]?')
  newest=$(newest_semver $tags)
  [ -z "$newest" ] && { note "$c" "FAIL no semver tag published"; fail=1; continue; }
  dl=$(digest "$c" "$tok" latest); dn=$(digest "$c" "$tok" "$newest")
  if [ -z "$dl" ]; then note "$c" "FAIL no :latest — the README's docker pull gets nothing"; fail=1
  elif [ "$dl" != "$dn" ]; then note "$c" "FAIL :latest is STALE vs $newest — consumers silently receive an older image"; fail=1
  elif [ -n "$(vers "$c")" ] && [ "$newest" != "$(vers "$c")" ]; then
    note "$c" "FAIL :latest labels itself $(vers "$c") but $newest is published — latest is not the newest"; fail=1
  else note "$c" "ok   :latest == :$newest (${dl:0:19})"; fi
done

echo "== half 3: crates.io — the published crate matches the tag and is not yanked"
for c in "${CRATES[@]}"; do
  j=$(curl -fsS "https://crates.io/api/v1/crates/$c" -H 'User-Agent: barnett-studios-qa')
  repo=$(echo "$j" | jq -r '.crate.repository // ""')
  # Guard against name collisions with unrelated crates before believing any version.
  case "$repo" in
    *"github.com/$ORG/$c"*) ;;
    *) note "$c" "FAIL crates.io/$c points at '$repo' — not this org's crate"; fail=1; continue ;;
  esac
  max=$(echo "$j" | jq -r '.crate.max_version')
  yanked=$(echo "$j" | jq -r '[.versions[]|select(.yanked)|.num]|join(",")')
  want=$(vers "$c")
  if [ -n "$want" ] && [ "$max" != "$want" ]; then
    note "$c" "FAIL crates.io has $max but the published image is $want — the two consumer paths disagree"; fail=1
  elif [ -n "$yanked" ]; then note "$c" "ok   $max (yanked in line: $yanked)"
  else note "$c" "ok   $max"; fi
done

# Every place the tag's tree declares THIS component's OWN version, as `path=version` lines.
#
# Half 4 used to read one file — VERSION, else Cargo.toml — and stop at the first hit, so a tree
# that declares its version in four places was compared in one. cxpak v3.1.4 declared 3.1.3 in
# three of its four and half 4 printed `ok` on every pass since the tag (.github#13). The stale
# one was `ensure-cxpak`'s REQUIRED_VERSION, compared with exact equality, so the shipped plugin
# rejected the binary the shipped release produced.
#
# Self-identifying by construction, which is what keeps this quiet on the other eight: a manifest
# counts only when it NAMES this component. A vendored crate's Cargo.toml says
# `name = "tree-sitter-scss"`, a seed fixture says `name = "test"`, a dependency pin names
# something else — none of them can enter the set, so no denylist is needed and none can rot. The
# census on .github#13 measured 26 benign version-like hits in cxpak's tree and 6 in corpus's;
# this rule admits none of them.
#
# Returns non-zero if the tree could not be listed. A query that failed is not an empty result —
# the rule half 5 states, applied to the enumeration half 4 now depends on.
version_declarations() { # repo sha
  local c="$1" sha="$2" paths path body v
  paths=$(gh api "repos/$ORG/$c/git/trees/${sha}?recursive=1" --jq '.tree[]|select(.type=="blob")|.path' 2>/dev/null) || return 1
  [ -z "$paths" ] && return 1
  while IFS= read -r path; do
    case "$(basename "$path")" in
      VERSION|Cargo.toml|package.json|pyproject.toml|plugin.json|marketplace.json) ;;
      *) case "$(basename "$path")" in *"$c"*) ;; *) continue ;; esac ;;
    esac
    body=$(gh api "repos/$ORG/$c/contents/${path}?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || continue
    v=""
    case "$(basename "$path")" in
      VERSION) v=$(printf '%s' "$body" | tr -d '\n ') ;;
      Cargo.toml|pyproject.toml)
        # Only when the manifest names THIS component, so vendored and fixture manifests
        # cannot contribute a version.
        # Section-scoped: a `version = "1"` under [dependencies.foo] is a pin, not a
        # declaration, and it sits at the start of its own line just like the real one.
        printf '%s' "$body" | awk -v c="$c" '
          /^\[/{sec=$0}
          sec ~ /^\[(package|project)\]/ && /^name *= *"/{gsub(/^name *= *"|".*$/,""); if ($0==c) named=1}
          sec ~ /^\[(package|project)\]/ && /^version *= *"/{if (!seen) {gsub(/^version *= *"|".*$/,""); ver=$0; seen=1}}
          END{if (named && seen) print ver}' > /tmp/.gc_v$$ 2>/dev/null
        v=$(cat /tmp/.gc_v$$ 2>/dev/null); rm -f /tmp/.gc_v$$ ;;
      package.json|plugin.json)
        v=$(printf '%s' "$body" | jq -r --arg c "$c" 'select(.name==$c)|.version // empty' 2>/dev/null) ;;
      marketplace.json)
        v=$(printf '%s' "$body" | jq -r --arg c "$c" '.plugins[]?|select(.name==$c)|.version // empty' 2>/dev/null) ;;
      *)
        # A resolver script pinning the binary it fetches — the shape that broke cxpak. Only
        # considered for a file whose own name carries the component's, checked above.
        v=$(printf '%s' "$body" | awk -F'"' '/^[A-Z_]*REQUIRED_VERSION *= *"/{print $2; exit}') ;;
    esac
    case "$v" in
      [0-9]*.[0-9]*.[0-9]*) printf '%s=%s\n' "$path" "$v" ;;
    esac
  done <<< "$paths"
  return 0
}

echo "== half 4: the tag's own content agrees with the tag's name"
# corpus#30's defect class, generalised: a tag named v0.2.0 whose tree declares 0.4.0. Reported
# as WARN, not FAIL — a red ghost check means "your findings this pass are untrustworthy, stop",
# and corpus tag drift does not make a finding about cascadr wrong. Gating every future pass on
# an already-filed product defect trains the loop to ignore its own red.
for c in "${VERSIONED_REPOS[@]}"; do
  tag=$(gh api "repos/$ORG/$c/tags" --jq '.[0].name' 2>/dev/null)
  [ -z "$tag" ] && { note "$c" "WARN no tags at all"; continue; }
  sha=$(gh api "repos/$ORG/$c/tags" --jq ".[]|select(.name==\"$tag\")|.commit.sha" 2>/dev/null | head -1)
  decls=$(version_declarations "$c" "$sha") || decls=""
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
    note "$c" "WARN $tag declares no version anywhere in its tree, so the tag-vs-tree claim is UNVERIFIABLE${mv:+ (main says $mv)}"
    continue
  fi
  n=$(printf '%s\n' "$decls" | grep -c .)
  bad=$(printf '%s\n' "$decls" | awk -F= -v t="$tag" '"v" $2 != t {printf "%s%s=%s", (c++?", ":""), $1, $2}')
  # The count is printed on the green line too. "ok" over a subset is what this half used to
  # say, and the number is the only thing that tells a reader which question was answered.
  if [ -n "$bad" ]; then
    note "$c" "WARN $tag names a tree that declares $bad — a version pin misdescribes what it pins ($n declaration(s) compared)"
  else note "$c" "ok   $tag == every one of $n declaration(s)"; fi
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
  if ! tag=$(gh api "repos/$ORG/$c/tags" --jq '.[0].name' 2>/dev/null); then
    note "$c" "WARN cannot list tags — currency unknown"; continue
  fi
  [ -z "$tag" ] && { note "$c" "ok   no tags — nothing to be behind"; continue; }
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
    note "$c" "WARN cannot resolve $tag to a commit — currency unknown"; continue
  fi
  sha="$(printf '%s\n' "$sha" | head -1)"
  [ -z "$sha" ] && { note "$c" "WARN $tag resolves to no commit — currency unknown"; continue; }
  # The release PR itself merges within a second of the tag commit, so the boundary is fuzzy
  # by about that much. It only ever admits the release commit, which is not a `fix(`.
  if ! tagdate=$(gh api "repos/$ORG/$c/commits/$sha" --jq '.commit.committer.date' 2>/dev/null); then
    note "$c" "WARN cannot date $tag — currency unknown"; continue
  fi
  # Status AND emptiness: a call that succeeds but yields nothing is also not a date.
  [ -z "$tagdate" ] && { note "$c" "WARN cannot date $tag — currency unknown"; continue; }
  # TSV out of jq, comparison in awk: ISO-8601 compares correctly as a string, and this keeps
  # the jq filter single-quoted instead of nesting shell quotes inside a jq regex.
  # Two steps, so the query's status is consulted before its emptiness is interpreted. As one
  # pipeline the assignment took awk's status and the failure vanished.
  if ! merged=$(gh api "repos/$ORG/$c/pulls?state=closed&per_page=100" --paginate \
                  --jq '.[]|select(.merged_at!=null)|"\(.merged_at)\t\(.number)\t\(.title)"' 2>/dev/null); then
    note "$c" "WARN cannot list merged PRs — currency unknown"; continue
  fi
  debt=$(printf '%s\n' "$merged" \
         | awk -F'\t' -v d="$tagdate" '$1>d && $3 ~ /^fix[(:]/ {printf "#%s ", $2}')
  n=$(printf '%s' "$debt" | tr ' ' '\n' | grep -c '^#')
  if [ "$n" = 0 ]; then note "$c" "ok   $tag carries every merged fix"
  else note "$c" "DEBT $n unreleased fix(es) since $tag: ${debt% }"; fi
done

if [ "$BOOT" = 1 ]; then
  echo "== boot: the image executes"
  for c in "${IMAGES[@]}"; do
    # ${c} braces are load-bearing under zsh, where "$c:latest" applies the :l (lowercase)
    # modifier and silently yields `abproofatest:latest`. The registry answers `denied`, which
    # is indistinguishable from a private image. Cost this check an hour and a whole false
    # theory about stale docker credentials.
    img="ghcr.io/barnett-studios/${c}:latest"
    docker pull "$img" >/dev/null 2>&1 || { note "$c" "FAIL anonymous docker pull rejected"; fail=1; continue; }
    if [ "$c" = cordon ]; then
      # cordon's image is deliberately NOT a CLI: it is the swappable <runtime> argument to
      # cordon-run.sh, documented as `git + python3 + build-essential` with no entrypoint.
      # Probing it with --help asserts a promise its README explicitly disclaims.
      docker run --rm "$img" python3 -c 'print(1)' >/dev/null 2>&1 \
        && note "$c" "ok   runtime image has the documented python3" \
        || { note "$c" "FAIL runtime image lacks the documented python3"; fail=1; }
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
        124) note "$c" "FAIL HUNG — killed at the 90s deadline; re-run, and file it if it recurs"; fail=1 ;;
        125|126|127) note "$c" "FAIL does not execute (rc=$rc): $(echo "$out"|head -1)"; fail=1 ;;
        *) if [ -z "$out" ]; then note "$c" "FAIL ran but produced no output"; fail=1
           else note "$c" "ok   executes (rc=$rc)"; fi ;;
      esac
    fi
  done
fi

echo
[ "$fail" = 0 ] && echo "GHOST CHECK GREEN" \
  || echo "GHOST CHECK RED — stop and report; do not file product findings against this state"
exit "$fail"
