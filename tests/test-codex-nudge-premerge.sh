#!/usr/bin/env bash
# tests/test-codex-nudge-premerge.sh
#
# Verifies hooks/gate-scripts/codex-nudge-premerge.sh — the NON-GATING PreToolUse
# hook that fires the `@codex review` nudge deterministically on `gh pr merge`
# when Codex is `none` (never engaged) on the PR AND the repo is Codex-active,
# delegating the one-shot post to the real codex-nudge-if-expected → codex-retrigger
# chain. Only `gh` is stubbed — it serves: PR/repo/HEAD resolution (`pr view --json
# number,headRefOid,url`), the active probe (graphql), the fully-paginated
# `none`-check (REST reviews/reactions), and records `pr comment`. Every other
# script runs for real against a throwaway git repo.
#
# Contract asserted: the hook NEVER writes stdout and always exits 0 (approve);
# posts exactly once on none+active (explicit PR, current-branch, and a `-R` DECOY
# in a sibling command); and NOT on already-engaged / kill-switch / non-merge /
# a real `-R`/`--repo` override / an inline `GH_REPO=` override.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/gate-scripts/codex-nudge-premerge.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
if [[ ! -f "$HOOK" ]]; then fail "missing $HOOK"; echo "Results: 0 passed, 1 failed"; exit 1; fi

TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [[ -n "${d:-}" ]] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT
mk() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

PR=515
HEAD=abcdef0123456789abcdef0123456789abcdef01
SLUG=testowner/testrepo

# gh stub. Dispatch on the full argv ($*):
#   pr comment  → append --body to $GH_BODYFILE
#   pr view     → {number,headRefOid,url} JSON (mirrors gh's own target resolution)
#   api graphql …pullRequests( → $ACTIVE_FIXTURE (codex-active-repo.sh probe)
#   api …/pulls/<n>/reviews    → $REVIEW_LOGINS (none-check, one login per line)
#   api …/issues/<n>/reactions → $REACTION_LOGINS
make_gh_stub() {
  cat > "$1/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "comment" ]]; then
  prev=""; for a in "$@"; do [[ "$prev" == "--body" ]] && printf '%s\n' "$a" >> "${GH_BODYFILE:?}"; prev="$a"; done
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  printf '{"number":%s,"headRefOid":"%s","url":"https://github.com/%s/pull/%s"}\n' \
    "${GH_PR_NUMBER:?}" "${HEAD_FIXT:?}" "${GH_SLUG:?}" "${GH_PR_NUMBER:?}"
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  case "$*" in
    *graphql*)    case "$*" in *'pullRequests('*) [[ -n "${ACTIVE_FIXTURE:-}" ]] && cat "$ACTIVE_FIXTURE" ;; esac ;;
    */reviews*)   printf '%s' "${REVIEW_LOGINS:-}" ;;
    */reactions*) printf '%s' "${REACTION_LOGINS:-}" ;;
  esac
  exit 0
fi
exit 0
STUB
  chmod +x "$1/gh"
}

# active probe: a recent PR carries a Codex review → repo is Codex-active.
ACTIVE_JSON='{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]},"reactions":{"nodes":[]}}]}}}}'

# Fresh sandbox git repo (origin decides cwd repo) + gh stub on PATH per case.
# Sets globals: REPO BIN BODY AF.
setup_case() {
  REPO=$(mk); BIN=$(mk); BODY="$(mk)/bodies"; : > "$BODY"
  ( cd "$REPO"
    git init -q
    git config user.email t@t.t; git config user.name t
    git commit -q --allow-empty -m init
    git remote add origin "https://github.com/$SLUG.git" ) >/dev/null 2>&1
  make_gh_stub "$BIN"
  AF="$(mk)/af"; printf '%s' "$ACTIVE_JSON" > "$AF"
}

# run_hook <cmd> <review_logins> <reaction_logins> [extra VAR=val ...]
# Sets OUT, RC, N (nudge count), B (body content).
run_hook() {
  local cmd="$1" reviews="$2" reactions="$3"; shift 3
  local payload
  payload=$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$REPO" "$cmd")
  set +e
  OUT=$(printf '%s' "$payload" | env PATH="$BIN:$PATH" \
        GH_BODYFILE="$BODY" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
        REVIEW_LOGINS="$reviews" REACTION_LOGINS="$reactions" "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
  set -e
  N=$(grep -c '@codex review' "$BODY" 2>/dev/null || true); [[ -n "$N" ]] || N=0
  B=$(cat "$BODY" 2>/dev/null || true)
}

# ── Case 1: none + active, explicit PR → posts exactly one `@codex review` ──
setup_case
run_hook "gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && -z "$OUT" ]]; then ok "none+active: silent approve (exit 0, no stdout)"; else fail "none+active: rc=$RC stdout='$OUT'"; fi
if [[ "$N" == 1 ]]; then ok "none+active: posted exactly one '@codex review'"; else fail "none+active: expected 1 nudge, body='$B'"; fi

# ── Case 2: Codex already engaged via a review → NO post ──
setup_case
run_hook "gh pr merge $PR --squash" "someone
chatgpt-codex-connector" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "already-engaged (review): no nudge"; else fail "already-engaged: rc=$RC body='$B'"; fi

# ── Case 2b: Codex engaged only via a reaction ([bot] suffix) → NO post ──
setup_case
run_hook "gh pr merge $PR --squash" "" "chatgpt-codex-connector[bot]"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "already-engaged (reaction): no nudge"; else fail "already-engaged reaction: rc=$RC body='$B'"; fi

# ── Case 3: kill switch → NO post ──
setup_case
run_hook "gh pr merge $PR --squash" "" "" PR_GRIND_CODEX_RETRIGGER=0
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "kill-switch: no nudge"; else fail "kill-switch: rc=$RC body='$B'"; fi

# ── Case 4: non-merge command → no-op ──
setup_case
run_hook "git status" "" ""
if [[ "$RC" == 0 && -z "$OUT" && "$N" == 0 ]]; then ok "non-merge: no-op"; else fail "non-merge: rc=$RC stdout='$OUT' body='$B'"; fi

# ── Case 5: current-branch merge (no PR positional) → resolves via `gh pr view`, posts once ──
setup_case
run_hook "gh pr merge --squash --admin" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "current-branch merge: resolved PR + posted one nudge"; else fail "current-branch merge: rc=$RC body='$B'"; fi

# ── Case 6: real `-R other/repo` override → SKIP (cannot replicate), no post ──
setup_case
run_hook "gh pr merge $PR -R other/repo --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "-R override: skipped (no nudge)"; else fail "-R override: rc=$RC body='$B'"; fi

# ── Case 7: inline GH_REPO= override on the merge → SKIP, no post ──
setup_case
run_hook "GH_REPO=other/repo gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "inline GH_REPO=: skipped (no nudge)"; else fail "inline GH_REPO=: rc=$RC body='$B'"; fi

# ── Case 8: any non-cd/non-gh-pr sibling command (here an `echo` decoy) → SKIP ──
# A preceding arbitrary command could mutate env/remote before the merge, so the
# whole invocation is treated as un-analyzable and skipped.
setup_case
run_hook "echo gh pr merge -R other/repo ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "sibling command (echo): skipped (no nudge)"; else fail "sibling echo: rc=$RC body='$B'"; fi

# ── Case 8b: a `cd` prefix IS allowed (the canonical worktree form) → posts once ──
setup_case
run_hook "cd . && gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "cd prefix: nudged"; else fail "cd prefix: rc=$RC body='$B'"; fi

# ── Case 8c: a `gh pr checkout`/non-merge gh prefix (mutates branch) → SKIP ──
setup_case
run_hook "gh pr checkout 516 && gh pr merge --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "gh pr checkout prefix: skipped (no nudge)"; else fail "gh pr checkout prefix: rc=$RC body='$B'"; fi

# ── Case 8d: two chained merges in one call → SKIP (pre-merge gate blocks these too) ──
setup_case
run_hook "gh pr merge $PR --squash ; gh pr merge 516 --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "multi-merge: skipped (no nudge)"; else fail "multi-merge: rc=$RC body='$B'"; fi

# ── Case 8e: a preceding `source`/arbitrary command → SKIP (may re-target) ──
setup_case
run_hook "source ./retarget.sh ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "source prefix: skipped (no nudge)"; else fail "source prefix: rc=$RC body='$B'"; fi

# ── Case 8f: a ';'-joined cd (NOT captured as the merge's &&-prefix) → SKIP ──
setup_case
run_hook "cd /tmp ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "semicolon cd: skipped (no nudge)"; else fail "semicolon cd: rc=$RC body='$B'"; fi

# ── Case 8g: an inline GIT_DIR= env prefix (redirects git) → SKIP ──
setup_case
run_hook "GIT_DIR=/x/.git gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "GIT_DIR= prefix: skipped (no nudge)"; else fail "GIT_DIR= prefix: rc=$RC body='$B'"; fi

# ── Case 9: GLOBAL `-R` (before the subcommand) → SKIP, no post ──
setup_case
run_hook "gh -R other/repo pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "global -R: skipped (no nudge)"; else fail "global -R: rc=$RC body='$B'"; fi

# ── Case 10: gh resolves a DIFFERENT repo than cwd (e.g. inherited GH_REPO) ──
# The equality gate (resolved url host/owner/repo == cwd origin) must reject it.
setup_case
run_hook "gh pr merge $PR --squash" "" "" GH_SLUG=other/repo
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "target!=cwd: skipped (no nudge)"; else fail "target!=cwd: rc=$RC body='$B'"; fi

# ── Case 11: a shell variable in the merge args ($OPTS could expand to -R) → SKIP ──
setup_case
# shellcheck disable=SC2016  # the literal $OPTS is the point of this case
run_hook 'gh pr merge '"$PR"' $OPTS --squash' "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "shell-var in args: skipped (no nudge)"; else fail "shell-var: rc=$RC body='$B'"; fi

# ── Case 12: INHERITED GH_REPO in the env → SKIP (re-targets vs default host) ──
setup_case
run_hook "gh pr merge $PR --squash" "" "" GH_REPO=other/repo
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "inherited GH_REPO: skipped (no nudge)"; else fail "inherited GH_REPO: rc=$RC body='$B'"; fi

# ── Case 13: preceding standalone GH_REPO= assignment segment → SKIP ──
setup_case
run_hook "GH_REPO=other/repo ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "standalone GH_REPO= assignment: skipped (no nudge)"; else fail "standalone GH_REPO=: rc=$RC body='$B'"; fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
