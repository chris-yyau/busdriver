#!/usr/bin/env bash
# test-provenance-guard.sh - #254 item 1: provenance guard (fail-CLOSED).
#
# Fails if a `status: local` skill declares third-party provenance in its
# SKILL.md frontmatter - i.e. it was vendored from a known upstream but tracked
# as local, where sync-upstream.sh (which processes `status != local`) gives it
# ZERO drift detection. That is the exact blind spot #254 targets: PR #307 fixed
# the 136 existing instances; this guard stops recurrence.
#
# Origin signal (proven by the #254 audit): vendored skills carry the vendor in
# their SKILL.md frontmatter - `author: vercel`, `source: github.com/firecrawl/
# skills`, etc. A busdriver-original skill carries none (or author: busdriver /
# the maintainer). The guard flags any local SKILL.md whose frontmatter:
#   - has `author:` (incl. nested `metadata.author:`) not in LOCAL_AUTHORS, OR
#   - has `source:`/`homepage:` pointing to a github.com org other than the
#     maintainer's (LOCAL_GH_ORG).
# Fix on a flag: register the upstream in .upstream-sources.json and flip the
# file(s) local -> custom (see #254 / PR #307).
#
# Genuine-original exceptions (a busdriver skill that legitimately carries a
# vendor-ish signal) go in tests/provenance-guard-allowlist.txt (one skill dir
# per line, `#` comments; absent = empty). A pattern-derived DISTILLATION must
# not copy the vendor's `author:` frontmatter - mark it with an
# `<!-- Origin: inspired by <upstream> -->` comment and keep it local (e.g.
# skills/canary, distilled from gstack).
#
# Boundary: frontmatter only. In-body citations of a vendor (a best-practices
# skill that references vendor docs) are NOT provenance and are not flagged.
# SKILL.md is the provenance-bearing file; non-SKILL.md local files are out of
# scope here (their skill's SKILL.md is what gets checked).
#
# shellcheck disable=SC2312  # the value-extraction pipelines below intentionally ignore pipe exit; extracted values are validated explicitly, and the jq enumeration checks its own exit code directly.
set -u

MANIFEST_NAME=".upstream-sources.json"
# Maintainer / busdriver-owned author values (case-insensitive) legitimate on a
# local skill. Everything else is treated as external.
LOCAL_AUTHORS=$'busdriver\nchris-yyau\nchris yau'
# Maintainer's github org - a source/homepage under this org is first-party.
LOCAL_GH_ORG="chris-yyau"

_norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//'; }

# run_guard <root-dir> : scans <root>/.upstream-sources.json, prints FAIL lines,
# sets GUARD_FAILS / GUARD_CHECKED, returns 0 iff clean. Parameterized on root so
# the self-test below can point it at throwaway fixtures.
run_guard() {
  local root="$1"
  local manifest="$root/$MANIFEST_NAME"
  local allowlist="$root/tests/provenance-guard-allowlist.txt"
  GUARD_FAILS=0
  GUARD_CHECKED=0
  [[ -f "$manifest" ]] || { echo "SKIP: manifest not present at $manifest"; return 0; }
  jq empty "$manifest" 2>/dev/null || { echo "FAIL: $manifest does not parse as JSON"; GUARD_FAILS=1; return 1; }

  local allowed=""
  [[ -f "$allowlist" ]] && allowed="$(grep -vE '^[[:space:]]*(#|$)' "$allowlist" 2>/dev/null || true)"

  # Capture the enumeration explicitly and check jq's exit code: a masked jq
  # error inside process substitution could otherwise leave GUARD_FAILS==0 and
  # report a false PASS. Cross-check processed==expected so a partial extraction
  # (jq erroring mid-stream) also fails CLOSED.
  local local_skills expected processed=0
  local_skills="$(jq -r '.files[] | select(.status=="local") | .path | select(test("^skills/[^/]+/SKILL\\.md$"))' "$manifest")" \
    || { echo "FAIL: jq enumeration of local skills failed"; GUARD_FAILS=1; return 1; }
  expected="$(jq '[.files[] | select(.status=="local") | .path | select(test("^skills/[^/]+/SKILL\\.md$"))] | length' "$manifest")" \
    || { echo "FAIL: jq count of local skills failed"; GUARD_FAILS=1; return 1; }

  local path dir fm author a val url org field
  # here-string (not a pipe) so the loop runs in this shell and the
  # GUARD_FAILS/GUARD_CHECKED/processed increments persist.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    processed=$((processed + 1))
    [[ -f "$root/$path" ]] || continue   # on-disk existence is test-upstream-manifest's invariant 6
    dir="${path#skills/}"; dir="skills/${dir%%/*}"
    if [[ -n "$allowed" ]] && grep -qxF -- "$dir" <<< "$allowed"; then continue; fi
    GUARD_CHECKED=$((GUARD_CHECKED + 1))
    # frontmatter = lines between the first two `---` fences
    fm="$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2) exit; next} n==1{print}' "$root/$path")"
    # author (top-level OR nested metadata.author - the indent-tolerant grep catches both)
    author="$(printf '%s\n' "$fm" | grep -iE '^[[:space:]]*author:' | head -1 | sed 's/^[^:]*://')"
    a="$(_norm "$author")"
    if [[ -n "$a" ]] && ! grep -qixF -- "$a" <<< "$LOCAL_AUTHORS"; then
      echo "FAIL: $path frontmatter author='$a' is external but status=local"
      echo "      -> register its upstream in $MANIFEST_NAME and flip to custom (see #254 / PR #307),"
      echo "         or allowlist $dir in tests/provenance-guard-allowlist.txt if genuinely original."
      GUARD_FAILS=$((GUARD_FAILS + 1))
    fi
    for field in source homepage; do
      val="$(printf '%s\n' "$fm" | grep -iE "^[[:space:]]*${field}:" | head -1 | sed 's/^[^:]*://')"
      url="$(_norm "$val")"
      case "$url" in
        *github.com/*)
          org="${url##*github.com/}"; org="${org%%/*}"
          if [[ -n "$org" && "$org" != "$LOCAL_GH_ORG" ]]; then
            echo "FAIL: $path frontmatter $field -> github.com/$org (external) but status=local"
            echo "      -> register its upstream and flip to custom, or allowlist $dir."
            GUARD_FAILS=$((GUARD_FAILS + 1))
          fi
          ;;
      esac
    done
  done <<< "$local_skills"

  if [[ "$processed" -ne "$expected" ]]; then
    echo "FAIL: processed $processed local skills but manifest declares $expected (incomplete enumeration - closing)"
    GUARD_FAILS=$((GUARD_FAILS + 1))
  fi
  [[ "$GUARD_FAILS" -eq 0 ]]
}

# Prove the detection logic actually fires before trusting a PASS on the real
# repo. A guard that silently stops detecting is worse than no guard.
selftest() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064  # expand $tmp now so the RETURN trap cleans the right dir
  trap "rm -rf '$tmp'" RETURN
  local m='{"version":"1.0","upstreams":{},"files":[{"path":"skills/acme/SKILL.md","source":"local","status":"local"}]}'

  # bad: external author on a local skill -> MUST flag
  mkdir -p "$tmp/bad/skills/acme"
  printf '%s\n' "$m" > "$tmp/bad/$MANIFEST_NAME"
  printf -- '---\nname: acme\nauthor: acmecorp\n---\n# Acme\n' > "$tmp/bad/skills/acme/SKILL.md"
  if run_guard "$tmp/bad" >/dev/null 2>&1; then echo "SELF-TEST FAIL: did not flag a vendored-author local skill"; return 1; fi

  # bad: NESTED metadata.author (the shape the Vercel skills used) -> MUST flag.
  # Locks in the indent-tolerant `^[[:space:]]*author:` match so a future edit
  # that narrows it to top-level-only fails here instead of silently regressing.
  mkdir -p "$tmp/badnest/skills/acme"
  printf '%s\n' "$m" > "$tmp/badnest/$MANIFEST_NAME"
  printf -- '---\nname: acme\nmetadata:\n  author: acmecorp\n  version: "1.0.0"\n---\n# Acme\n' > "$tmp/badnest/skills/acme/SKILL.md"
  if run_guard "$tmp/badnest" >/dev/null 2>&1; then echo "SELF-TEST FAIL: did not flag nested metadata.author"; return 1; fi

  # bad: external github source URL -> MUST flag
  mkdir -p "$tmp/ghsrc/skills/acme"
  printf '%s\n' "$m" > "$tmp/ghsrc/$MANIFEST_NAME"
  printf -- '---\nname: acme\nsource: https://github.com/acmecorp/skills\n---\n# Acme\n' > "$tmp/ghsrc/skills/acme/SKILL.md"
  if run_guard "$tmp/ghsrc" >/dev/null 2>&1; then echo "SELF-TEST FAIL: did not flag an external github source"; return 1; fi

  # good: no external provenance -> MUST pass
  mkdir -p "$tmp/good/skills/acme"
  printf '%s\n' "$m" > "$tmp/good/$MANIFEST_NAME"
  printf -- '---\nname: acme\nauthor: busdriver\n---\n# Acme\n' > "$tmp/good/skills/acme/SKILL.md"
  if ! run_guard "$tmp/good" >/dev/null 2>&1; then echo "SELF-TEST FAIL: flagged a clean local skill"; return 1; fi

  # good: maintainer's own github org -> MUST pass
  mkdir -p "$tmp/ok/skills/acme"
  printf '%s\n' "$m" > "$tmp/ok/$MANIFEST_NAME"
  printf -- '---\nname: acme\nsource: https://github.com/chris-yyau/helmet\n---\n# Acme\n' > "$tmp/ok/skills/acme/SKILL.md"
  if ! run_guard "$tmp/ok" >/dev/null 2>&1; then echo "SELF-TEST FAIL: flagged a first-party github source"; return 1; fi

  return 0
}

# Fail CLOSED, not SKIP: this is an enforcement guard, and jq is a hard
# dependency of the whole gate ecosystem (and preinstalled on the CI runner).
# Silently passing when we cannot run the check is a fail-open.
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for the provenance guard (fail-closed) - install jq" >&2; exit 1; }

if ! selftest; then exit 1; fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
[[ -f "$REPO_ROOT/$MANIFEST_NAME" ]] || { echo "SKIP: $MANIFEST_NAME not present"; exit 0; }

if run_guard "$REPO_ROOT"; then
  echo "PASS: provenance guard clean (${GUARD_CHECKED} local skills checked, self-test OK)"
  exit 0
fi
echo "---"
echo "A local skill declares third-party provenance in its SKILL.md frontmatter."
echo "Vendored skills must be registered under an upstream and tracked custom/sync"
echo "so sync-upstream.sh (which skips status=local) can detect drift. See #254."
exit 1
