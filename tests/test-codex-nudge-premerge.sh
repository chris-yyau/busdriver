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

# Single base dir so `mk` (called in $() subshells, where an array append would be
# lost) still leaves every temp dir under one tree the EXIT trap can remove.
TMP_BASE=$(mktemp -d)
cleanup() { rm -rf "$TMP_BASE"; return 0; }
trap cleanup EXIT
mk() { mktemp -d "$TMP_BASE/XXXXXX"; }

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

# run_hook_ml <cmd-file> <review_logins> <reaction_logins> [extra VAR=val ...]
# Same as run_hook but the command is a MULTI-LINE script read from a file and
# JSON-escaped with jq (so real pr-grind merge payloads — newlines, quotes, `||`,
# `$(...)`, comments — reach the hook verbatim). Sets OUT, RC, N, B.
run_hook_ml() {
  local cmdfile="$1" reviews="$2" reactions="$3"; shift 3
  local payload
  payload=$(jq -Rs --arg cwd "$REPO" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:.}}' "$cmdfile")
  set +e
  OUT=$(printf '%s' "$payload" | env PATH="$BIN:$PATH" \
        GH_BODYFILE="$BODY" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
        REVIEW_LOGINS="$reviews" REACTION_LOGINS="$reactions" "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
  set -e
  N=$(grep -c '@codex review' "$BODY" 2>/dev/null || true); [[ -n "$N" ]] || N=0
  B=$(cat "$BODY" 2>/dev/null || true)
}

# Emit the REAL pr-grind DEFAULT merge block (template-substituted: literal PR,
# NO_WORKTREE=0), comments and all, to stdout. The commented `gh pr merge`
# references are the whole point — they must NOT inflate the merge count.
emit_default_block() {
  local mrg="gh pr merge"   # keep the literal out of this test file's own gate exposure
  cat <<BLK
# NO_WORKTREE template-substituted by the dispatcher at run time
NO_WORKTREE=0
$mrg $PR --squash --delete-branch || true
# Verify via authoritative source — \`$mrg\` exit code is unreliable when
# --delete-branch hits a post-merge worktree-checkout conflict (the remote
# merge already SUCCEEDED). Empirical: surfaced during PR #98's grind.
MERGE_STATE=""
for attempt in 1 2 3; do
  MERGE_STATE=\$(gh pr view $PR --json state -q .state 2>/dev/null || echo "")
  [ "\$MERGE_STATE" = "MERGED" ] && break
  # the worktree-checkout conflict above makes \`$mrg\` exit non-zero even on success
  [ "\$attempt" -lt 3 ] && sleep 2
done
if [ "\$MERGE_STATE" != "MERGED" ]; then
  echo "PR #$PR not merged after 3 attempts; preserving worktree."
  exit 1
fi
( cd "\$WORKTREE_DIR" || exit 0; bash "\${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger-gc.sh" "$PR" ) || true
if [ "\$NO_WORKTREE" != "1" ]; then
  cd /some/original
  git worktree remove "../pr-grind-$PR" --force 2>/dev/null || true
fi
BLK
}

# Emit the REAL pr-grind ADMIN merge block: bypass-log jq write + mkdir + case
# BEFORE the merge (audit-before-privileged-action), then merge, then retry+gc.
emit_admin_block() {
  local mrg="gh pr merge"
  cat <<BLK
case "\$LOG_TRIGGER" in solo-admin-auto) LOG_EVENT="x" ;; *) LOG_EVENT="y" ;; esac
mkdir -p "\$REPO_ROOT/.claude"
jq -c -n --arg ts "\$TS" '{ts:\$ts}' >> "\$REPO_ROOT/.claude/bypass-log.jsonl" || { echo "failed"; exit 1; }
$mrg $PR --squash --delete-branch --admin || true
MERGE_STATE=""
for attempt in 1 2 3; do
  MERGE_STATE=\$(gh pr view $PR --json state -q .state 2>/dev/null || echo "")
  [ "\$MERGE_STATE" = "MERGED" ] && break
  [ "\$attempt" -lt 3 ] && sleep 2
done
if [ "\$MERGE_STATE" != "MERGED" ]; then echo "not merged"; exit 1; fi
( cd "\$WORKTREE_DIR" || exit 0; bash "\${CLAUDE_PLUGIN_ROOT}/scripts/codex-retrigger-gc.sh" "$PR" ) || true
BLK
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

# ── Case 8: a BENIGN sibling before the merge (here `echo`, with a `-R` decoy in
#    ITS args) → still nudges. The hook fires at PreToolUse, BEFORE any command
#    runs, so `echo` can't re-target; the `-R` belongs to echo, not a gh command;
#    and the real merge segment is clean and targets the cwd PR. (This is the same
#    property that lets the admin block run `jq`/`echo` before its merge.) A
#    sibling that CAN re-target (gh/git-remote/source/cd) is still skipped — see 8c/18/19.
setup_case
run_hook "echo gh pr merge -R other/repo ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "benign echo sibling: nudged (decoy -R is echo's arg)"; else fail "benign echo sibling: rc=$RC body='$B'"; fi

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

# ── Case 8h: two chained cd segments (2nd relative, not captured) → SKIP ──
setup_case
run_hook "cd . && cd nested && gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "double cd: skipped (no nudge)"; else fail "double cd: rc=$RC body='$B'"; fi

# ── Case 8i: two positional PR args (gh rejects; we must not pre-nudge one) → SKIP ──
setup_case
run_hook "gh pr merge $PR 516 --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "two positionals: skipped (no nudge)"; else fail "two positionals: rc=$RC body='$B'"; fi

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

# ══ A′ loosening (ADR 0013 rev 2026-07-17): fire on the REAL multi-line pr-grind
#    merge payloads, keeping the wrong-repo hole closed. ══════════════════════

CF="$(mk)/cmd"

# ── Case 14: REAL default merge block (multi-line, `|| true`, for/$( )/if, cd,
#    git worktree, and TWO commented `gh pr merge` decoys) → posts EXACTLY once.
#    Proves: command-word merge count is comment-safe (naive regex would see 3).
setup_case
emit_default_block > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && -z "$OUT" ]]; then ok "default block: silent approve"; else fail "default block: rc=$RC out='$OUT'"; fi
if [[ "$N" == 1 ]]; then ok "default block: posted exactly one nudge (comments not counted)"; else fail "default block: expected 1, body='$B'"; fi

# ── Case 15: REAL admin merge block (bypass-log jq/mkdir/case BEFORE the merge,
#    literal PR) → posts exactly once. Proves benign pre-merge audit cmds are OK.
setup_case
emit_admin_block > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "admin block: posted exactly one nudge"; else fail "admin block: rc=$RC body='$B'"; fi

# ── Case 16: default block but inline GH_REPO= on the merge line → SKIP.
setup_case
{ emit_default_block | sed "s#^gh pr merge $PR#GH_REPO=evil/x gh pr merge $PR#"; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "inline GH_REPO= in multiline: skipped"; else fail "inline GH_REPO= multiline: rc=$RC body='$B'"; fi

# ── Case 17: default block + a SECOND real merge appended → SKIP (count != 1).
setup_case
{ emit_default_block; printf 'gh pr merge 999 --squash\n'; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "second merge appended: skipped"; else fail "second merge: rc=$RC body='$B'"; fi

# ── Case 18: a `git remote set-url` re-target BEFORE the merge → SKIP.
setup_case
{ printf 'git remote set-url origin https://github.com/evil/x.git\n'; emit_default_block; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "git remote set-url before merge: skipped"; else fail "git remote before merge: rc=$RC body='$B'"; fi

# ── Case 19: a `cd` (uncaptured, ;-joined) BEFORE the merge in a real block → SKIP.
setup_case
{ printf 'cd /tmp\n'; emit_default_block; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "uncaptured cd before merge: skipped"; else fail "cd before merge: rc=$RC body='$B'"; fi

# ── Case 20: default block whose merge operand is a shell var (`$PR` unsub'd) → SKIP.
#    Guards the SKILL contract: the admin merge operand MUST be a literal digit.
setup_case
{ emit_default_block | sed "s#^gh pr merge $PR#gh pr merge \"\$PR\"#"; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "shell-var merge operand: skipped"; else fail "shell-var operand: rc=$RC body='$B'"; fi

# ── Case 21: a `cd` hidden behind a `then` reserved word before the merge → SKIP.
#    (leading reserved/control words are stripped so the re-targeter is analysed).
setup_case
run_hook "if true; then cd /repo-b; fi ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "reserved-word-hidden cd: skipped"; else fail "reserved cd: rc=$RC body='$B'"; fi

# ── Case 22: `git -C . remote set-url` (flagged/path git) before the merge → SKIP.
setup_case
run_hook "git -C . remote set-url origin https://github.com/evil/x.git && gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "git -C remote before merge: skipped"; else fail "git -C remote: rc=$RC body='$B'"; fi
setup_case
run_hook "/usr/bin/git remote set-url origin https://github.com/evil/x.git && gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "path-form git remote before merge: skipped"; else fail "path git remote: rc=$RC body='$B'"; fi

# ── Case 23: a `#`-decoy merge after `;` must be stripped as a comment (Bash does),
#    so it does NOT inflate the count and suppress the real block's nudge → posts once.
setup_case
{ printf 'true;# noise || gh pr merge 999 --squash\n'; emit_default_block; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "post-metachar # decoy stripped: nudged once"; else fail "# decoy: rc=$RC N=$N body='$B'"; fi

# ── Case 24: `builtin cd`/`builtin export` wrappers before the merge → SKIP.
setup_case
run_hook "builtin cd /repo-b ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "builtin cd wrapper: skipped"; else fail "builtin cd: rc=$RC body='$B'"; fi
setup_case
run_hook "builtin export GH_REPO=evil/x ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "builtin export GH_REPO=: skipped"; else fail "builtin export: rc=$RC body='$B'"; fi

# ── Case 25: concurrency joins (`&` background, `|` pipe) around the merge → SKIP.
#    An "after" segment joined concurrently could race the merge's repo resolution.
setup_case
run_hook "gh pr merge $PR --squash & git remote set-url origin https://github.com/evil/x.git" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "backgrounded merge (&): skipped"; else fail "background merge: rc=$RC body='$B'"; fi
setup_case
run_hook "gh pr merge $PR --squash | tee /tmp/x" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "piped merge (|): skipped"; else fail "piped merge: rc=$RC body='$B'"; fi

# ── Case 26: a line-continuation before `#` — Bash removes the continuation FIRST,
#    so the `#` is NOT a comment and the `cd /repo-b` after it executes → SKIP
#    (strip_continuations must run before comment stripping, else the cd is hidden).
setup_case
printf 'foo\\\n#; cd /repo-b\ngh pr merge %s --squash\n' "$PR" > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "continuation-hidden cd before merge: skipped"; else fail "continuation cd: rc=$RC N=$N body='$B'"; fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
