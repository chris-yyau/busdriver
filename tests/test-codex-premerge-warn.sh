#!/usr/bin/env bash
# Tests for ADR 0024 — the non-gating missing-Codex advisory on pre-merge allow
# paths. Covers the three new pieces and their gate integration:
#
#   1. scripts/codex-engagement-probe.sh   engaged | none | unknown (PR-scoped)
#   2. scripts/codex-premerge-warn.sh       warn | silent (the bounded predicate)
#   3. pre-merge-gate.sh allow_merge()      emits systemMessage (NO decision) on
#                                           an allow path when warn; byte-identical
#                                           silence otherwise; NEVER a block.
#
# The gate integration cases are the load-bearing ones: they prove the advisory
# is (a) operator-visible via top-level systemMessage, (b) carries no
# decision/permissionDecision (non-gating, constraint 8), and (c) a detection
# failure NEVER turns into {"decision":"block"} (constraint 1).
#
# Usage: bash tests/test-codex-premerge-warn.sh
# Exit: 0 if all pass, 1 if any fail.
set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0; TOTAL=0
ok()   { printf "  PASS  %s\n" "$1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
bad()  { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

PROBE="scripts/codex-engagement-probe.sh"
WARN="scripts/codex-premerge-warn.sh"
GATE="hooks/gate-scripts/pre-merge-gate.sh"
MARKER=".claude/pr-grind-clean.local"

# ── Hermetic gh stub ──────────────────────────────────────────────────
# One stub covers all three consumers, branching on argv:
#   * `pr checks`                 → every required check passes (gate CI verify)
#   * `api graphql …pullRequests` → active-repo fixture (STUB_ACTIVE)
#   * `api --paginate …/reviews|/reactions --jq …` → engagement fixture
#                                   (STUB_ENGAGEMENT: engaged|none|unknown)
# STUB_ACTIVE governs the REPO-level active probe (graphql over recent PRs);
# STUB_ENGAGEMENT governs THIS PR's reviews/reactions — independent, so the
# #444 case (active repo, none on this PR) is expressible.
STUBDIR=$(mktemp -d)
cat > "$STUBDIR/gh" <<'STUB'
#!/usr/bin/env bash
# args: $1=api|pr ...
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ]; then
  python3 - <<'PY' 2>/dev/null || printf 'shellcheck\tpass\t1s\thttps://x\n'
import json
try:
    names=[c["name"] for c in json.load(open(".github/required-checks.lock")).get("required",[])]
except Exception:
    names=[]
for n in (names or ["shellcheck"]):
    print(f"{n}\tpass\t1s\thttps://x")
PY
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  # codex-active-repo.sh graphql. Emit one PR node; include a Codex review when
  # STUB_ACTIVE=1, else an empty node → HIT=0 → inactive.
  if [ "${STUB_ACTIVE:-0}" = "1" ]; then
    printf '%s' '{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]},"reactions":{"nodes":[]}}]}}}}'
  else
    printf '%s' '{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":{"nodes":[]},"reactions":{"nodes":[]}}]}}}}'
  fi
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  # Engagement probe: `gh api --paginate <endpoint> --jq '<filter>'`. The stub
  # emits what --jq WOULD produce (the logins, one per line). unknown = exit 1.
  case "${STUB_ENGAGEMENT:-none}" in
    engaged) printf 'chatgpt-codex-connector\n'; exit 0 ;;
    unknown) exit 1 ;;
    *)       exit 0 ;;   # none: clean fetch, no logins
  esac
fi
exit 0
STUB
chmod +x "$STUBDIR/gh"
export PATH="$STUBDIR:$PATH"

# ── Save/restore the gate scratch markers this test writes (pr-grind-clean /
#    skip / bypass), which live under the gate's resolved REPO_DIR (this cwd).
#    We deliberately do NOT touch the force-on marker: it lives at the
#    git-common-dir parent (the MAIN repo root, shared across worktrees), so
#    mutating it would open a cross-worktree window and risk stranding operator
#    state on a SIGKILL. Instead the gate cases are driven by STUB_ACTIVE — and
#    they are force-on-AGNOSTIC: force-on and active both route to the same
#    engagement probe, so each case's expected result holds whether or not the
#    operator's force-on marker happens to be present. The force-on BRANCH itself
#    is covered hermetically at the adapter level above (throwaway repo).
SKIP_FILE=".claude/skip-pr-grind.local"
BYP_FILE=".claude/.merge-bypass-pending.local"
STASH=$(mktemp -d)
for f in "$MARKER" "$SKIP_FILE" "$BYP_FILE"; do
  [ -f "$f" ] && cp -p "$f" "$STASH/$(basename "$f")"
done
restore_markers() {
  for f in "$MARKER" "$SKIP_FILE" "$BYP_FILE"; do
    b="$STASH/$(basename "$f")"
    if [ -f "$b" ]; then cp -p "$b" "$f"; else rm -f "$f"; fi
  done
}
# Restore markers FIRST, then remove the backup dir — reversing this deletes
# $STASH before restore_markers reads it, stranding every backup.
cleanup() { restore_markers; rm -rf "$STUBDIR" "$STASH"; }
trap cleanup EXIT
mkdir -p .claude
rm -f "$MARKER" "$SKIP_FILE" "$BYP_FILE"

# ═══════════════════════════════════════════════════════════════════════
echo "── codex-engagement-probe (engaged|none|unknown) ───────────"

probe() { STUB_ENGAGEMENT="$1" bash "$PROBE" chris-yyau/busdriver 459 2>/dev/null; }

[ "$(probe engaged)" = "engaged" ] && ok "engaged: Codex login in reviews" || bad "engaged case"
[ "$(probe none)"    = "none"    ] && ok "none: clean fetch, no Codex login" || bad "none case"
[ "$(probe unknown)" = "unknown" ] && ok "unknown: fetch failure → unknown (not none)" || bad "unknown case"

# Bad input → unknown (fail toward silence, never none).
[ "$(bash "$PROBE" "bad/owner/repo" 459 2>/dev/null)" = "unknown" ] && ok "bad owner/repo → unknown" || bad "bad owner/repo"
[ "$(bash "$PROBE" chris-yyau/busdriver "not-a-number" 2>/dev/null)" = "unknown" ] && ok "non-numeric PR → unknown" || bad "non-numeric PR"
# Single-token stdout only (no stray output).
LINES=$(probe none | wc -l | tr -d ' ')
[ "$LINES" = "1" ] && ok "single-token stdout (exactly one line)" || bad "stdout not single token ($LINES lines)"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── codex-premerge-warn (warn|silent truth table) ───────────"

# Force-on is resolved from the REPO_DIR's main-repo-root .claude/. The busdriver
# repo itself carries an operator force-on marker, so to test pure active/inactive
# semantics WITHOUT touching that marker we use a throwaway git repo (no marker)
# as REPO_DIR. owner/repo is still passed explicitly (drives the gh stub); only
# force-on resolution reads REPO_DIR.
TMPREPO=$(mktemp -d)
git -C "$TMPREPO" init -q
git -C "$TMPREPO" remote add origin https://github.com/chris-yyau/busdriver.git
warn() { local active="$1" eng="$2"; STUB_ACTIVE="$active" STUB_ENGAGEMENT="$eng" bash "$WARN" chris-yyau/busdriver 459 "$TMPREPO" 2>/dev/null; }

[ "$(warn 1 none)"    = "warn"   ] && ok "active + none → warn (the #444 gap)" || bad "active+none"
[ "$(warn 1 engaged)" = "silent" ] && ok "active + engaged → silent" || bad "active+engaged"
[ "$(warn 1 unknown)" = "silent" ] && ok "active + unknown → silent (fail toward silence)" || bad "active+unknown"
[ "$(warn 0 none)"    = "silent" ] && ok "inactive + none → silent (nothing to warn)" || bad "inactive+none"

# ── Origin canonicalization (the `canon=...` sed in codex_none_warning) ─────
# Greptile #461 P1: credentialed HTTPS origins (token-auth checkouts, e.g.
# `https://x-access-token:TOKEN@github.com/owner/repo.git`) must still
# canonicalize to `github.com/owner/repo` — the userinfo `:` must not be
# mistaken for the git@ scp-style host/path separator. Exercised directly
# against the same sed expression the gate uses (not via the gh-stubbed
# `warn()` helper, which bypasses origin resolution entirely).
canon_of() {
  printf '%s' "$1" | sed -E 's#^git@#https://#; s#^https?://##; s#^[^/@]*@##; s#:#/#; s#\.git/?$##; s#/+$##'
}
[ "$(canon_of 'https://x-access-token:ghp_abc123@github.com/chris-yyau/busdriver.git')" = "github.com/chris-yyau/busdriver" ] \
  && ok "credentialed HTTPS origin canonicalizes past userinfo" || bad "credentialed HTTPS origin canon"
[ "$(canon_of 'https://github.com/chris-yyau/busdriver.git')" = "github.com/chris-yyau/busdriver" ] \
  && ok "plain HTTPS origin unaffected by userinfo strip" || bad "plain HTTPS origin canon regressed"
[ "$(canon_of 'git@github.com:chris-yyau/busdriver.git')" = "github.com/chris-yyau/busdriver" ] \
  && ok "scp-style git@ origin unaffected by userinfo strip" || bad "scp-style git@ origin canon regressed"

# Kill switch → silent, zero network (constraint 4). Verified by pointing gh at a
# stub that HARD-FAILS if called: kill switch must short-circuit before any gh.
FAILGH=$(mktemp -d); cat > "$FAILGH/gh" <<'S'
#!/usr/bin/env bash
echo "gh must NOT be called under kill switch" >&2; exit 42
S
chmod +x "$FAILGH/gh"
KS_OUT=$(PATH="$FAILGH:$PATH" PR_GRIND_CODEX_RETRIGGER=0 bash "$WARN" chris-yyau/busdriver 459 "$TMPREPO" 2>/dev/null)
[ "$KS_OUT" = "silent" ] && ok "kill switch → silent, no gh call" || bad "kill switch (got '$KS_OUT')"
rm -rf "$FAILGH"

# Force-on marker in the throwaway repo: even on an INACTIVE repo, force-on +
# none → warn (the force-on-only repo where the gate is the sole surface).
mkdir -p "$TMPREPO/.claude"; : > "$TMPREPO/.claude/pr-grind-codex-expected.local"
[ "$(warn 0 none)" = "warn" ] && ok "force-on + inactive + none → warn (sole-surface repo)" || bad "force-on+none"
rm -f "$TMPREPO/.claude/pr-grind-codex-expected.local"
rm -rf "$TMPREPO"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "── pre-merge-gate integration (allow_merge epilogue) ───────"

MERGE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 459 --squash"}}'
# Fresh marker for PR 459 → hits the pr-grind-clean + CI allow path.
gate_out() { echo "459" > "$MARKER"; printf '%s' "$MERGE_INPUT" | STUB_ACTIVE="$1" STUB_ENGAGEMENT="$2" bash "$GATE" 2>/dev/null; rm -f "$MARKER"; }

# 1. active + none → allow path emits a systemMessage advisory...
OUT=$(gate_out 1 none)
if printf '%s' "$OUT" | grep -q '"systemMessage"' && printf '%s' "$OUT" | grep -q 'has not engaged'; then
  ok "allow path emits systemMessage advisory on active+none"
else
  bad "allow path should emit systemMessage advisory (got: $OUT)"
fi
# 2. ...and it carries NO decision/permissionDecision (non-gating — constraint 8)
if printf '%s' "$OUT" | grep -qE '"(decision|permissionDecision)"'; then
  bad "advisory MUST NOT carry decision/permissionDecision (got: $OUT)"
else
  ok "advisory carries no decision/permissionDecision (non-gating)"
fi
# 3. ...and it is valid JSON
if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "advisory output is valid JSON"
else
  bad "advisory output must be valid JSON (got: $OUT)"
fi

# 4. active + engaged → silent allow: byte-for-byte empty stdout (old behavior)
OUT=$(gate_out 1 engaged)
[ -z "$OUT" ] && ok "active+engaged → silent allow (empty stdout, byte-identical)" || bad "engaged should be silent (got: $OUT)"

# (The force-on BRANCH is covered hermetically at the adapter level above with a
#  throwaway repo — "force-on + inactive + none → warn". We do not re-test it at
#  the gate level because that would require mutating the shared main-repo
#  force-on marker; the gate→adapter→warn wiring is already proven by case 1.)

# 6. Kill switch → silent even when active+none (constraint 4)
echo "459" > "$MARKER"
OUT=$(printf '%s' "$MERGE_INPUT" | PR_GRIND_CODEX_RETRIGGER=0 STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
rm -f "$MARKER"
[ -z "$OUT" ] && ok "kill switch → silent allow even on active+none" || bad "kill switch at gate (got: $OUT)"

# 7. Constraint 1 — a detection failure NEVER emits a block. Point the probe's
#    engagement fetch at 'unknown' (fetch error) on an active repo: must still
#    ALLOW (empty), never {"decision":"block"}.
OUT=$(gate_out 1 unknown)
if printf '%s' "$OUT" | grep -q '"block"'; then
  bad "detection failure emitted a block — constraint 1 VIOLATED (got: $OUT)"
else
  ok "detection failure never emits a block (allows, constraint 1)"
fi

# 8. Advisory fires on the SKIP allow path too (not only the marker path). Age a
#    skip file >30s and merge with no marker → skip path → active+none warns.
#    SKIP_FILE/BYP_FILE are saved+restored by Setup, so this owns them safely.
rm -f "$MARKER"
touch "$SKIP_FILE"
touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$SKIP_FILE" 2>/dev/null || touch -d "2 minutes ago" "$SKIP_FILE" 2>/dev/null || true
rm -f "$BYP_FILE"
OUT=$(printf '%s' "$MERGE_INPUT" | STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
if printf '%s' "$OUT" | grep -q '"systemMessage"' && ! printf '%s' "$OUT" | grep -q '"block"'; then
  ok "advisory fires on the skip-pr-grind allow path too"
else
  bad "skip path should also warn+allow (got: $OUT)"
fi
rm -f "$SKIP_FILE" "$BYP_FILE"

# 9. Repo/host override (-R other/repo) → advisory SILENT even on active+none
#    (constraint 5 — origin-derived target may be the wrong repo).
echo "459" > "$MARKER"
OVERRIDE_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 459 -R other/repo --squash"}}'
OUT=$(printf '%s' "$OVERRIDE_INPUT" | STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
rm -f "$MARKER"
# The gate blocks a marker-PR≠merge-PR mismatch, but -R 459 still parses PR 459
# matching the marker, so it reaches the allow path; the advisory must be silent.
if printf '%s' "$OUT" | grep -q '"systemMessage"'; then
  bad "repo-override merge should NOT warn (wrong-repo risk, constraint 5) — got: $OUT"
else
  ok "repo-override (-R) → advisory silent (constraint 5)"
fi

# 9b. Attached short-option form (-Rother/repo, no space) must ALSO suppress.
echo "459" > "$MARKER"
ATTACHED_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 459 -Rother/repo --squash"}}'
OUT=$(printf '%s' "$ATTACHED_INPUT" | STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
rm -f "$MARKER"
if printf '%s' "$OUT" | grep -q '"systemMessage"'; then
  bad "attached -Rother/repo should NOT warn (constraint 5) — got: $OUT"
else
  ok "repo-override attached form (-Rother/repo) → advisory silent"
fi

# 9c. Token-splitting quoted form (-"R"other) must ALSO suppress — the detector
#     normalizes away quote/backslash chars before the substring test.
echo "459" > "$MARKER"
SPLITQ_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"gh pr merge 459 -\"R\"other/repo --squash"}}'
OUT=$(printf '%s' "$SPLITQ_INPUT" | STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
rm -f "$MARKER"
if printf '%s' "$OUT" | grep -q '"systemMessage"'; then
  bad 'split-quote -"R"other should NOT warn (constraint 5) — got: '"$OUT"
else
  ok "repo-override split-quote form (-\"R\"other) → advisory silent"
fi

# 9d. Inline GH_REPO= host/repo assignment (checked against the normalized cmd
#     like the flags) must ALSO suppress.
echo "459" > "$MARKER"
GHREPO_INPUT='{"tool_name":"Bash","toolName":"Bash","tool_input":{"command":"GH_REPO=other/repo gh pr merge 459 --squash"}}'
OUT=$(printf '%s' "$GHREPO_INPUT" | STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
rm -f "$MARKER"
if printf '%s' "$OUT" | grep -q '"systemMessage"'; then
  bad "GH_REPO= override should NOT warn (constraint 5) — got: $OUT"
else
  ok "repo-override GH_REPO= assignment → advisory silent"
fi

# 10. Budget reservation (constraint 2): when almost no time remains inside the
#     outer hook timeout, the advisory is SKIPPED (silent) rather than risking a
#     harness kill of an authorized merge. Force it by shrinking the outer cap so
#     remaining = outer - elapsed - 4 < 2 → skip. Active+none would normally warn.
echo "459" > "$MARKER"
OUT=$(printf '%s' "$MERGE_INPUT" | CODEX_WARN_OUTER_BUDGET=4 STUB_ACTIVE=1 STUB_ENGAGEMENT=none bash "$GATE" 2>/dev/null)
rm -f "$MARKER"
[ -z "$OUT" ] && ok "tiny remaining budget → advisory skipped (silent, never overruns cap)" || bad "should skip advisory when no headroom (got: $OUT)"

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
printf "  %d/%d passed" "$PASS" "$TOTAL"
[ "$FAIL" -gt 0 ] && printf " — %d FAILED" "$FAIL"
printf "\n"
[ "$FAIL" -eq 0 ]
