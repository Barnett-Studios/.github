#!/usr/bin/env bash
# Every place a tag's tree declares THIS component's OWN version, as `path=version`
# lines. Extracted out of ghost-check.sh so it's testable with a stubbed `gh`.
#
# Half 4 used to read one file — VERSION, else Cargo.toml — and stop at the first
# hit, so a tree that declares its version in four places was compared in one.
# cxpak v3.1.4 declared 3.1.3 in three of its four and half 4 printed `ok` on every
# pass since the tag (.github#13). The stale one was `ensure-cxpak`'s
# REQUIRED_VERSION, compared with exact equality, so the shipped plugin rejected
# the binary the shipped release produced.
#
# Self-identifying by construction, which is what keeps this quiet on the other
# eight: a manifest counts only when it NAMES this component. A vendored crate's
# Cargo.toml says `name = "tree-sitter-scss"`, a seed fixture says `name = "test"`,
# a dependency pin names something else — none of them can enter the set, so no
# denylist is needed and none can rot. The census on .github#13 measured 26 benign
# version-like hits in cxpak's tree and 6 in corpus's; this rule admits none of them.
#
# Returns non-zero if the tree could not be listed, OR if any candidate file's
# content could not be fetched. "A query that failed is not an empty result" — the
# rule half 5 states, applied here twice: once to the enumeration (pre-existing),
# and once to each per-file content fetch (review — the original `|| continue` on
# that fetch treated "gh couldn't read this file" identically to "this file isn't a
# version declaration", silently shrinking the declared set by one for every
# transient failure, so the half printed `ok` over a smaller-than-real set instead
# of surfacing the gap).
version_declarations() { # repo sha
  local c="$1" sha="$2" paths path content_json body v
  paths=$(gh api "repos/$ORG/$c/git/trees/${sha}?recursive=1" --jq '.tree[]|select(.type=="blob")|.path' 2>/dev/null) || return 1
  [ -z "$paths" ] && return 1
  while IFS= read -r path; do
    case "$(basename "$path")" in
      VERSION|Cargo.toml|package.json|pyproject.toml|plugin.json|marketplace.json) ;;
      *) case "$(basename "$path")" in *"$c"*) ;; *) continue ;; esac ;;
    esac
    # The gh call and the base64 decode are deliberately two separate checks now.
    # A failed gh call (transient 5xx, timeout) means this path's status is
    # genuinely unknown, and the whole comparison must stop and say so (return 1)
    # rather than silently treat the file as absent. A successful call whose
    # `.content` fails to base64-decode is a different, narrower oddity — not a
    # request failure — and still just skips this one path (continue), same as
    # before.
    if ! content_json=$(gh api "repos/$ORG/$c/contents/${path}?ref=${sha}" --jq '.content' 2>/dev/null); then
      return 1
    fi
    body=$(printf '%s' "$content_json" | base64 -d 2>/dev/null) || continue
    v=""
    case "$(basename "$path")" in
      VERSION) v=$(printf '%s' "$body" | tr -d '\n ') ;;
      Cargo.toml|pyproject.toml)
        # Only when the manifest names THIS component, so vendored and fixture manifests
        # cannot contribute a version.
        # Section-scoped: a `version = "1"` under [dependencies.foo] is a pin, not a
        # declaration, and it sits at the start of its own line just like the real one.
        # No temp file: a predictable path in a world-writable directory, which this estate
        # argued against in baseplate#25 and which docs/standards/tooling-traps.md and
        # dotclaude#159 both rule out. Command substitution does the same job with no file.
        v=$(printf '%s' "$body" | awk -v c="$c" '
          /^\[/{sec=$0}
          sec ~ /^\[(package|project)\]/ && /^name *= *"/{gsub(/^name *= *"|".*$/,""); if ($0==c) named=1}
          sec ~ /^\[(package|project)\]/ && /^version *= *"/{if (!seen) {gsub(/^version *= *"|".*$/,""); ver=$0; seen=1}}
          END{if (named && seen) print ver}' 2>/dev/null) ;;
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
