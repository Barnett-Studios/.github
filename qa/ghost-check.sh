#!/usr/bin/env bash
# Ghost check for the Barnett Studios AI-SDLC component family.
#
# Two halves, both required, same reason as the Scriptorium original:
#   1. AGREEMENT — is the published artifact the version `main` says it is?
#   2. BOOT      — does a clean anonymous consumer actually get that artifact, and does it run?
#
# Half 1 alone is the wrong check for the defect class it exists for: every version can agree
# while `docker pull ghcr.io/barnett-studios/<x>` (which resolves `latest`) hands the consumer a
# months-old image. Agreement says nothing about what an outsider receives.
#
# Runs anonymously on purpose — a token with read:packages would test a path no consumer walks.
# Needs: curl, jq. Docker only for --boot.
#
# Usage: ./ghost-check.sh [--boot]
#   --boot  additionally pull each `latest` and run its --help (slow, needs docker)

set -uo pipefail

COMPONENTS=(abproof attestr baseplate cascadr commitward cordon cxpak slicr)
# corpus is a git-submodule data repo: no image, no crate. Its agreement check is tags-vs-VERSION.
DATA_REPOS=(corpus)

BOOT=0
[ "${1:-}" = "--boot" ] && BOOT=1

fail=0
note() { printf '%-11s %s\n' "$1" "$2"; }

ghcr_token() {
  curl -fsS "https://ghcr.io/token?scope=repository%3Abarnett-studios%2F$1%3Apull&service=ghcr.io" \
    | jq -r '.token // empty'
}

# Resolve a tag to its manifest digest. Accept every manifest media type: asking for only one
# makes the registry 404 an image published under the other, which reads as "missing" not "wrong".
digest() {
  curl -fsS -o /dev/null -D - -H "Authorization: Bearer $2" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/barnett-studios/$1/manifests/$3" \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}'
}

echo "== half 1+2: published artifact agreement and what an anonymous consumer receives"
for c in "${COMPONENTS[@]}"; do
  release=$(gh api "repos/Barnett-Studios/$c/releases/latest" --jq '.tag_name' 2>/dev/null | tr -d 'v')
  tok=$(ghcr_token "$c")
  if [ -z "$tok" ]; then note "$c" "FAIL no anonymous pull token — image is not public"; fail=1; continue; fi

  tags=$(curl -fsS -H "Authorization: Bearer $tok" "https://ghcr.io/v2/barnett-studios/$c/tags/list")
  newest=$(echo "$tags" | jq -r '[.tags[]|select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))]
                                 | sort_by(split(".")|map(tonumber)) | last // empty')
  if [ -z "$newest" ]; then note "$c" "FAIL no semver tag published"; fail=1; continue; fi

  d_latest=$(digest "$c" "$tok" latest)
  d_newest=$(digest "$c" "$tok" "$newest")
  msg="release=${release:-none} newest=$newest"

  if [ -z "$d_latest" ]; then
    note "$c" "FAIL $msg — no :latest tag; README's docker pull gets nothing"; fail=1; continue
  fi
  if [ "$d_latest" != "$d_newest" ]; then
    note "$c" "FAIL $msg — :latest is STALE, consumers silently receive an older image"; fail=1; continue
  fi
  if [ -n "$release" ] && [ "$release" != "$newest" ]; then
    note "$c" "FAIL $msg — GitHub release and published image disagree"; fail=1; continue
  fi

  if [ "$BOOT" = 1 ]; then
    # ${c} braces are load-bearing: in zsh "$c:latest" applies the :l (lowercase) history
    # modifier and silently yields e.g. `abproofatest:latest`, which the registry rejects as
    # `denied` — indistinguishable from a genuinely private image. Cost this check an hour.
    img="ghcr.io/barnett-studios/${c}:latest"
    if ! docker pull "$img" >/dev/null 2>&1; then
      note "$c" "FAIL $msg — anonymous docker pull rejected"; fail=1; continue
    fi
    # cordon's image is deliberately NOT a CLI: it is the swappable <runtime> argument to
    # cordon-run.sh, documented as `git + python3 + build-essential` with no entrypoint.
    # Probing it with --help asserts a promise the README explicitly disclaims.
    if [ "$c" = cordon ]; then
      docker run --rm "$img" python3 -c 'print(1)' >/dev/null 2>&1 \
        || { note "$c" "FAIL $msg — runtime image lacks the documented python3"; fail=1; continue; }
    else
      # "Does it boot", not "does --help exit 0". A usage message on rc=2 is a booted binary
      # making a style choice; 125/126/127 are docker/exec failures and mean nothing ran.
      out=$(timeout 90 docker run --rm "$img" --help 2>&1); rc=$?
      case "$rc" in
        125|126|127) note "$c" "FAIL $msg — image does not execute (rc=$rc): $(echo "$out"|head -1)"; fail=1; continue ;;
      esac
      [ -z "$out" ] && { note "$c" "FAIL $msg — ran but produced no output at all"; fail=1; continue; }
    fi
    msg="$msg boot=ok"
  fi
  note "$c" "ok   $msg"
done

# WARN, not FAIL, and the distinction is the point: a RED ghost check means "your findings this
# pass are untrustworthy, stop". Corpus tag drift does not make a finding about cascadr wrong, so
# gating every future pass on it would train the loop to ignore its own red. It is a filed product
# defect (corpus#30), not a broken substrate.
echo "== data repos (advisory): VERSION and the newest release tag agree"
for c in "${DATA_REPOS[@]}"; do
  v=$(gh api "repos/Barnett-Studios/$c/contents/VERSION" --jq '.content' 2>/dev/null | base64 -d | tr -d '\n ')
  t=$(gh api "repos/Barnett-Studios/$c/releases/latest" --jq '.tag_name' 2>/dev/null | tr -d 'v')
  if [ -z "$v" ]; then note "$c" "WARN no VERSION file"
  elif [ "$v" != "$t" ]; then note "$c" "WARN VERSION=$v but newest release=v$t — a version pin cannot reach $v (corpus#30)"
  else note "$c" "ok   VERSION=$v release=v$t"; fi
done

[ "$fail" = 0 ] && echo "GHOST CHECK GREEN" || echo "GHOST CHECK RED — stop and report; do not file product findings against this state"
exit "$fail"
