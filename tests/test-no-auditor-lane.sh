#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted source text throughout is literal, not an expansion
# shellcheck disable=SC2312  # assertions intentionally use command substitution
# tests/test-no-auditor-lane.sh
# ADR 0051: the Mechanism Witness (auditor) and the opencode CLI were withdrawn.
# The LIVE files below must not reference them again; their Version History
# sections and everything outside LIVE (docs/adr, CHANGELOG, plan history, tests)
# are out of scope. This 10-file list IS the contract: it is the surface an upstream
# sync or a careless revert would bring the lane back through.
#
# Two kinds of allowance, both exact, never a regex or a bare word:
#   ALLOW_LINES  - whole lines, compared after trimming outer whitespace: the
#                  removed-CLI set statements (opencode is a removed CLI, like amp).
#                  Honoured ONLY in scripts/lib/resolve-cli.sh, the one file that
#                  owns the removed set. A line that merely CONTAINS one of these,
#                  e.g. the same label with a dispatching body, is not allowed.
#   ALLOW_SUBSTR - substrings deleted before matching: the pi provider name and
#                  README's #251 history sentence. Anything else on that line is
#                  still matched.
# Known limit: the scan is line-by-line, so an allowed label whose body sits on
# the following lines is judged by those lines alone.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

# Word-bounded `opencode` written portably (BSD and GNU grep share no \b).
PAT='opencode-review-config|--execute-opencode|resolve_auditor_model|AUDITOR_|_AUD_|_aud_|\.auditor\.model|council\.auditor|blueprint-review\.auditor|MECHANISM_WITNESS|Mechanism Witness|auditor\.json|witness\.txt|(^|[^A-Za-z0-9_])opencode([^A-Za-z0-9_]|$)'
ALLOW_LINES=(
  'elif [[ "$cli" == "amp" || "$cli" == "claude" || "$cli" == "aider" || "$cli" == "opencode" ]]; then'
  'amp|claude|aider|opencode)'
  'elif [[ "$default_primary" == "amp" || "$default_primary" == "claude" || "$default_primary" == "aider" || "$default_primary" == "opencode" ]]; then'
  'elif [[ "$default_fallback" == "amp" || "$default_fallback" == "claude" || "$default_fallback" == "aider" || "$default_fallback" == "opencode" ]]; then'
  'gemini|amp|claude|aider|opencode) i=$((i + 1)); continue ;;'
  'if [[ "$cli" != "opencode" ]]; then'
  'if [[ -n "$cli" && "$cli" != "opencode" ]]; then'
)
ALLOW_SUBSTR=(
  'opencode-go'
  'the `opencode/` port was removed in [#251]'
)

# stdin → "<n>:<line>" for every line that still matches PAT after the allowances.
# $1 = 1 to honour ALLOW_LINES (resolve-cli.sh only), 0 otherwise.
scan() {
  local allow_lines="$1" line t tok
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$allow_lines" == 1 ]]; then
      t="${line#"${line%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
      for tok in "${ALLOW_LINES[@]}"; do
        if [[ "$t" == "$tok" ]]; then line=""; break; fi
      done
    fi
    for tok in "${ALLOW_SUBSTR[@]}"; do line="${line//"$tok"/}"; done
    printf '%s\n' "$line"
  done | {
    # grep rc 1 is "no matches"; anything higher is a failed search, which must
    # never read as clean, so it is reported as a hit.
    grep -nE "$PAT"; rc=$?
    (( rc <= 1 )) || echo "scan error: grep exited $rc"
  }
}
hits_in() { printf '%s\n' "$1" | scan "${2:-1}" | grep -c . || true; }

# <file> → ok | bad:<n> | unreadable. Fail CLOSED: a missing or malformed file, or
# a .routes that is absent or not an object, is `unreadable`, never `ok`.
routes_verdict() {
  local out
  out="$(jq 'if (.routes | type) == "object" then [.routes | keys[] | select(test("auditor"))] | length else error("routes is not an object") end' "$1" 2>/dev/null)" || out=""
  if [[ "$out" == "0" ]]; then
    echo ok
  elif [[ "$out" =~ ^[1-9][0-9]*$ ]]; then
    echo "bad:$out"
  else
    echo unreadable
  fi
}

expect() {   # <label> <want> <got>
  if [[ "$3" == "$2" ]]; then pass "self-test: $1"; else fail "self-test: $1 (want '$2', got '$3')"; fi
}

# ── Self-tests: the guard must fire on forbidden code even beside an allowed token.
expect "opencode arm beside opencode-go"   1 "$(hits_in '  opencode) model=opencode-go/x ;;')"
expect "partial removed set"               1 "$(hits_in '      amp|opencode) run_review ;;')"
expect "removed-set label, dispatching body" 1 "$(hits_in '      amp|claude|aider|opencode) execute_review "$cli" "$prompt" ;;')"
expect "auditor-only branch"               1 "$(hits_in 'elif [[ "$cli" == "opencode" ]]; then')"
expect "comment naming opencode"           1 "$(hits_in '  # ["amp"] or ["gemini", "opencode"] route.')"
expect "witness flag"                      1 "$(hits_in 'MECHANISM_WITNESS=1')"
expect "witness dispatch by variable name" 1 "$(hits_in '  "$DISPATCH" --cli "$AUDITOR_CLI" < "$D/witness.txt" &')"
expect "loop witness budget"               1 "$(hits_in '  _AUD_TIMEOUT=1800')"
expect "removed-set line is allowed"       0 "$(hits_in '          gemini|amp|claude|aider|opencode) i=$((i + 1)); continue ;;')"
expect "bare removed-set label is allowed" 0 "$(hits_in '      amp|claude|aider|opencode)')"
expect "removed-set line outside resolve-cli.sh is a hit" 1 "$(hits_in '      amp|claude|aider|opencode)' 0)"
expect "provider is allowed"               0 "$(hits_in 'pi_read.model: opencode-go/deepseek-v4.1-flash')"
expect "grep error is a hit, not clean"    1 "$(PAT='(' hits_in 'x' 2>/dev/null)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '{' > "$tmp/bad.json"
printf '{}' > "$tmp/noroutes.json"
printf '{"routes":[]}' > "$tmp/array.json"
printf '{"routes":{"council.auditor":["opencode"]}}' > "$tmp/aud.json"
printf '{"routes":{"council.critic":["codex"]}}' > "$tmp/ok.json"
expect "malformed config fails closed"  unreadable "$(routes_verdict "$tmp/bad.json")"
expect "missing .routes fails closed"   unreadable "$(routes_verdict "$tmp/noroutes.json")"
expect "array .routes fails closed"     unreadable "$(routes_verdict "$tmp/array.json")"
expect "auditor route detected"         bad:1      "$(routes_verdict "$tmp/aud.json")"
expect "clean config passes"            ok         "$(routes_verdict "$tmp/ok.json")"

LIVE=(
  scripts/lib/resolve-cli.sh
  skills/dispatch-cli/scripts/dispatch.sh
  skills/blueprint-review/scripts/run-design-review-loop.sh
  skills/council/SKILL.md
  skills/blueprint-review/SKILL.md
  skills/dispatch-cli/SKILL.md
  skills/writing-prose/SKILL.md
  commands/ultimate-council.md
  README.md
  .claude/CLAUDE.md
)

# ── Live files.
for rel in "${LIVE[@]}"; do
  f="$DIR/$rel"
  if [[ ! -f "$f" ]]; then fail "$rel missing"; continue; fi
  allow=0; [[ "$rel" == scripts/lib/resolve-cli.sh ]] && allow=1
  # Fail CLOSED: an unreadable or empty body must never read as "clean".
  if ! body="$(awk '/^## Version History/{exit} {print}' "$f")"; then
    fail "$rel could not be read"; continue
  fi
  if [[ -z "$body" ]]; then fail "$rel has no body to scan"; continue; fi
  hits="$(printf '%s\n' "$body" | scan "$allow")"
  if [[ -n "$hits" ]]; then
    fail "$rel references the withdrawn lane:"; printf '%s\n' "$hits" | head -5
  else
    pass "$rel clean"
  fi
done

if [[ -e "$DIR/scripts/lib/opencode-review-config.json" ]]; then
  fail "opencode-review-config.json still present"
else
  pass "opencode-review-config.json deleted"
fi

verdict="$(routes_verdict "$DIR/.claude/busdriver.json")"
case "$verdict" in
  ok)    pass ".claude/busdriver.json has no auditor routes" ;;
  bad:*) fail ".claude/busdriver.json still routes ${verdict#bad:} auditor role(s)" ;;
  *)     fail ".claude/busdriver.json could not be inspected" ;;
esac

if [[ "$FAIL" = 0 ]]; then
  echo "PASS test-no-auditor-lane"
else
  echo "FAIL test-no-auditor-lane"; exit 1
fi
