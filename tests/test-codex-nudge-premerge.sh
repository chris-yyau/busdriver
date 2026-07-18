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
# #416 containment probe: record the routing env EVERY gh invocation actually sees,
# so a test can assert no repo-controlled GH_REPO/GH_HOST ever reaches an outbound
# call. Written before any dispatch so `pr view`, `api`, and `pr comment` all log.
[[ -n "${GH_ENVFILE:-}" ]] && printf 'GH_REPO=%s GH_HOST=%s\n' "${GH_REPO-<unset>}" "${GH_HOST-<unset>}" >> "$GH_ENVFILE"
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
    */reviews*)
      # STUB_REVIEWS_FAIL_ONCE=1: fail only the FIRST reviews read (a transient),
      # succeed after — proves the hook's bounded fetch retry recovers (#398). The
      # attempt count persists across the stub's separate processes via a file.
      if [[ "${STUB_REVIEWS_FAIL_ONCE:-0}" == "1" ]]; then
        printf 'x\n' >> "${STUB_ATTEMPTS_FILE:?}"
        [[ "$(wc -l < "${STUB_ATTEMPTS_FILE}")" -le 1 ]] && exit 1
      fi
      printf '%s' "${REVIEW_LOGINS:-}" ;;
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
  ENVF="$(mk)/ghenv"; : > "$ENVF"
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
        GH_ENVFILE="$ENVF" GH_BODYFILE="$BODY" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
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
        GH_ENVFILE="$ENVF" GH_BODYFILE="$BODY" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
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

# ── Case 8: ANY command before the merge (here `echo`) → SKIP under merge-first.
#    We don't classify siblings as benign/hostile (a denylist can't be complete);
#    the merge must be the FIRST command (modulo pure assignments + a captured cd).
setup_case
run_hook "echo gh pr merge -R other/repo ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "command before merge (echo): skipped (merge-first)"; else fail "echo before merge: rc=$RC body='$B'"; fi

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

# ── Case 8f: a ';'-joined LITERAL cd to a DIFFERENT repo (here /tmp, not the cwd
#    origin) → SKIP. ADR 0018 loosened the parser to ACCEPT a standalone literal cd
#    (it is captured as target_dir), so the skip here is now enforced DOWNSTREAM by
#    the hook's gh-pr-view==cwd-origin equality guard (/tmp has no github origin),
#    NOT by the parser's merge-first rejection. Net effect unchanged: no wrong-repo nudge.
setup_case
run_hook "cd /tmp ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "semicolon cd to non-origin dir: skipped (downstream equality guard)"; else fail "semicolon cd: rc=$RC body='$B'"; fi

# ── Case 8f2 (ADR 0018): a ';'-joined ABSOLUTE literal cd to the SAME repo → NUDGE.
#    This is the shape pr-grind's CWD-reset rule makes agents emit (`cd "$WORKTREE_DIR"`
#    template-substituted to an absolute path on its own line, then the merge). Before
#    ADR 0018 the parser rejected it merge-first and the `none`-nudge silently no-op'd
#    on every rule-compliant pr-grind merge. (Absolute required — see Case 8f9.)
setup_case
run_hook "cd $REPO ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "semicolon absolute cd to cwd repo: nudged (ADR 0018)"; else fail "semicolon abs cd same-repo: rc=$RC N=$N body='$B'"; fi

# ── Case 8f3 (ADR 0018 boundary): a standalone NON-LITERAL cd ($VAR / $(...) — a
#    statically-unknown target) stays parser-REJECTED (only plain literals are
#    trusted; the &&-capture path still handles the substitution form when joined).
setup_case
# shellcheck disable=SC2016  # the literal $DEST is the point of this case
run_hook 'cd $DEST ; gh pr merge '"$PR"' --squash' "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "semicolon cd \$VAR (non-literal): skipped (parser)"; else fail "semicolon cd \$VAR: rc=$RC body='$B'"; fi

# ── Case 8f4 (ADR 0018 finding 1): a cd segment carrying a $(retargeter) in an
#    assignment prefix must NOT be trusted just because it ends in a literal cd — the
#    subst_rt check gates it → SKIP. Uses an ABSOLUTE cd to the cwd repo so the ONLY
#    thing forcing the skip is subst_rt: were that guard removed, the absolute cd would
#    otherwise nudge, so this test genuinely isolates it (Greptile: `cd .` did not).
setup_case
CF8="$(mk)/cmd"
# shellcheck disable=SC2016  # the literal $(...) is the payload under test
printf 'X="$(git remote set-url origin https://github.com/evil/x.git)" cd %s ; gh pr merge %s --squash\n' "$REPO" "$PR" > "$CF8"
run_hook_ml "$CF8" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "cd with \$(retargeter) assignment prefix: skipped"; else fail "cd+subst prefix: rc=$RC N=$N body='$B'"; fi

# ── Case 8f5 (ADR 0018 finding 2): an EXTERNAL `/tmp/cd` (basename 'cd' but not the
#    builtin — cannot change the shell's cwd) must NOT be treated as a cd → SKIP.
setup_case
run_hook "/tmp/cd /repo-b ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "external /tmp/cd (not builtin): skipped"; else fail "external cd: rc=$RC body='$B'"; fi

# ── Case 8f6 (ADR 0018 finding 3): TWO builtin cds before the merge cannot be
#    statically composed (a trailing relative `cd .` mis-resolves) → SKIP.
setup_case
run_hook "cd /repo-b ; cd . ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "double builtin cd (composition): skipped"; else fail "double cd: rc=$RC body='$B'"; fi

# ── Case 8f7 (ADR 0018 finding 4): a SUBSHELL-grouped cd `( cd /repo-b )` does not
#    change the parent (merge) cwd → SKIP. Also covers the &&-joined subshell form.
setup_case
run_hook "( cd /repo-b ) ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "subshell-grouped cd (;): skipped"; else fail "subshell cd ;: rc=$RC body='$B'"; fi
setup_case
run_hook "( cd /repo-b ) && gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "subshell-grouped cd (&&): skipped"; else fail "subshell cd &&: rc=$RC body='$B'"; fi

# ── Case 8f8 (ADR 0018 finding 5): CDPATH re-points a RELATIVE cd operand outside the
#    payload cwd → SKIP (CDPATH is a sensitive assignment; relative cd is also rejected).
setup_case
run_hook "CDPATH=/repo-b cd leaf ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "CDPATH= relative cd: skipped"; else fail "CDPATH cd: rc=$RC body='$B'"; fi

# ── Case 8f9 (ADR 0018): a RELATIVE literal cd (subject to CDPATH / composition) is
#    NOT trusted by the standalone path → SKIP (only absolute literals qualify).
setup_case
run_hook "cd leaf ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "relative literal cd: skipped (absolute-only)"; else fail "relative cd: rc=$RC body='$B'"; fi

# ── Case 8f10 (ADR 0018): invariant matrix over {cd prefix} × {separator}. The parser
#    nudges IFF a single ABSOLUTE literal cd to the cwd repo reaches the merge via a
#    sequential success-composing operator (';' or '&&') outside any subshell. Every
#    other combination — non-origin target, relative operand, subshell grouping, or a
#    '||'/'&' operator (merge runs in a different/original cwd, or not at all) — skips.
#    Asserts the core property (accepted target_dir == the merge's real runtime cwd)
#    across the grammar, not just hand-picked points.
matrix_fail=0
M_BAD_PREFIX=("cd /tmp" "cd leaf" "( cd $REPO )")   # non-origin / relative / subshell
for sep in ";" "&&" "||" "&"; do
  # absolute cd to the cwd repo: nudge ONLY for the sequential success operators
  setup_case
  run_hook "cd $REPO $sep gh pr merge $PR --squash" "" ""
  want=0; [[ "$sep" == ";" || "$sep" == "&&" ]] && want=1
  if [[ "$N" != "$want" ]]; then matrix_fail=$((matrix_fail+1)); echo "  matrix: 'cd \$REPO $sep merge' → N=$N want=$want"; fi
  # every unsafe prefix: never nudge, regardless of separator
  for pfx in "${M_BAD_PREFIX[@]}"; do
    setup_case
    run_hook "$pfx $sep gh pr merge $PR --squash" "" ""
    if [[ "$N" != 0 ]]; then matrix_fail=$((matrix_fail+1)); echo "  matrix: '$pfx $sep merge' → N=$N want=0"; fi
  done
done
if [[ "$matrix_fail" == 0 ]]; then ok "invariant matrix (prefix×separator): accept iff abs-cwd-cd + sequential op"; else fail "invariant matrix: $matrix_fail wrong verdicts"; fi

# ── Case 8f11 (ADR 0018 finding 6): an absolute cd target containing a `..` component
#    → SKIP. Logical `cd` cancels `..` textually while `git -C` resolves it physically
#    through symlinks, so the two can land in different repos.
setup_case
run_hook "cd $REPO/../evil ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "absolute cd with .. component: skipped"; else fail "dotdot cd: rc=$RC body='$B'"; fi

# ── Case 8f12 (ADR 0018): a QUOTED absolute cd to the cwd repo still nudges (shlex
#    strips the quotes; the resolved literal is unchanged). Property coverage for
#    quoted operands alongside the bare-word matrix.
setup_case
CFQ="$(mk)/cmd"
printf 'cd "%s" ; gh pr merge %s --squash\n' "$REPO" "$PR" > "$CFQ"
run_hook_ml "$CFQ" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "quoted absolute cd to cwd repo: nudged"; else fail "quoted abs cd: rc=$RC N=$N body='$B'"; fi

# ── Case 8f13 (ADR 0018 cross-cwd origin guard — the standalone-cd backstop): a cd to
#    a DIFFERENT-origin repo than the payload cwd → SKIP. This is the general closure
#    for "the cd may not have executed as parsed" (a `cd` shell function/alias, a
#    conditional, a failed cd, a symlink/.. divergence): the merge could run in the
#    payload cwd (repo A) while target_dir names repo B, so unless A and B share an
#    origin the nudge is refused. Here REPO2 has origin evil/x while payload cwd is the
#    testowner/testrepo sandbox → guard skips before any post.
setup_case
REPO2=$(mk)
( cd "$REPO2"
  git init -q; git config user.email t@t.t; git config user.name t
  git commit -q --allow-empty -m init
  git remote add origin "https://github.com/evil/x.git" ) >/dev/null 2>&1
run_hook "cd $REPO2 ; gh pr merge $PR --squash" "" "" GH_SLUG=evil/x
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "cross-cwd origin mismatch (target≠payload repo): skipped"; else fail "cross-cwd guard: rc=$RC N=$N body='$B'"; fi
# same guard, but target shares the payload origin → still nudges (worktree-equivalent)
setup_case
run_hook "cd $REPO ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "cross-cwd origin match (same repo): nudged"; else fail "cross-cwd match: rc=$RC N=$N body='$B'"; fi

# ── Case 8f14 (ADR 0018 finding 7): a `cd` behind reserved/control-flow words is
#    CONDITIONAL (may not execute) → the parser refuses to treat it as a trusted
#    literal cd (had_reserved) → SKIP.
setup_case
run_hook "if true; then cd /repo-b; fi ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "conditional cd behind reserved words: skipped"; else fail "conditional cd: rc=$RC body='$B'"; fi

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

# ── Case 12 (#416): INHERITED GH_REPO/GH_HOST must never reach a `gh` call ──
# A committed `.claude/settings.json` `env` block is repo-controlled, so these are
# hostile input. hooks.json no longer re-imports them and the hook pins GH_HOST /
# clears GH_REPO, so the nudge still lands on the CWD repo's own PR and EVERY gh
# invocation (pr view, api, the delegate's pr comment) sees the pinned routing.
# Simulates the leak the `env -i` line used to allow by setting them directly.
setup_case
run_hook "gh pr merge $PR --squash" "" "" GH_REPO=other/repo GH_HOST=evil.example.com
LEAK=$(grep -vc 'GH_REPO=<unset> GH_HOST=github.com' "$ENVF" 2>/dev/null || true); [[ -n "$LEAK" ]] || LEAK=0
SAW=$(wc -l < "$ENVF" | tr -d ' ')
if [[ "$RC" == 0 && "$N" == 1 && "$LEAK" == 0 && "$SAW" -gt 0 ]]; then
  ok "inherited GH_REPO/GH_HOST: contained (nudge on cwd repo, $SAW gh calls all pinned)"
else
  fail "#416 env containment: rc=$RC N=$N leaked=$LEAK of $SAW gh calls; env log: $(cat "$ENVF")"
fi

# ── Case 12b (#416): hooks.json must not re-import routing/state env on line 78 ──
NUDGE_LINE=$(grep -n 'codex-nudge-premerge.sh' "$SCRIPT_DIR/hooks/hooks.json" | head -1)
if [[ -n "$NUDGE_LINE" ]] && ! printf '%s' "$NUDGE_LINE" | grep -qE 'GH_REPO=|GH_HOST=|BUSDRIVER_STATE_DIR='; then
  ok "hooks.json nudge registration passes no GH_REPO/GH_HOST/BUSDRIVER_STATE_DIR"
else
  fail "#416: hooks.json re-imports repo-controlled env for the nudge hook: $NUDGE_LINE"
fi

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

# ── Case 15: REAL admin approver-gap block writes bypass-log jq/mkdir/case BEFORE
#    the merge, so it is NOT merge-first → SKIP (hook). The admin path is covered by
#    the SKILL-prose nudge instead; the hook owns the default + skip-bypass paths.
setup_case
emit_admin_block > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "admin block (audit-before-merge): skipped, prose covers it"; else fail "admin block: rc=$RC body='$B'"; fi

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

# ── Case 19: a standalone literal `cd` to a DIFFERENT repo (/tmp) before the real
#    block → SKIP via the downstream equality guard (ADR 0018 accepts the literal cd
#    at the parser; /tmp has no matching github origin so the hook skips). No nudge.
setup_case
{ printf 'cd /tmp\n'; emit_default_block; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "standalone cd to non-origin dir before block: skipped (downstream guard)"; else fail "cd before merge: rc=$RC body='$B'"; fi

# ── Case 19b (ADR 0018 REGRESSION TEST for the #403 miss): the EXACT rule-compliant
#    pr-grind shape — a standalone literal `cd <repo>` on its own line, then the
#    `NO_WORKTREE=…` assignment, then the merge — must NUDGE. This is the command that
#    silently no-op'd the `none`-nudge in session 261270ad. cd to the sandbox repo so
#    the downstream origin equality passes.
setup_case
{ printf 'cd %s\n' "$REPO"; emit_default_block; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "standalone literal cd to cwd repo before block: nudged (ADR 0018 / #403 regression)"; else fail "session-shape cd before block: rc=$RC N=$N body='$B'"; fi

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

# ── Case 23: a `#`-decoy merge after `;` (post-metachar) must be stripped as a
#    comment (Bash does), so the decoy does NOT inflate the merge count. Merge stays
#    FIRST; the comment trails it → posts exactly once.
setup_case
run_hook "gh pr merge $PR --squash ;# noise || gh pr merge 999 --squash" "" ""
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
#    Built with explicit pieces so the payload UNAMBIGUOUSLY contains backslash+LF.
setup_case
{ printf 'foo'; printf '%s' "\\"; printf '\n#; cd /repo-b\ngh pr merge %s --squash\n' "$PR"; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "continuation-hidden cd before merge: skipped"; else fail "continuation cd: rc=$RC N=$N body='$B'"; fi

# ── Case 27: an escaped space before `#` (\ #) — Bash keeps the escaped space in
#    the word, so the `#` is mid-word (NOT a comment) and the `cd /repo-b` runs →
#    SKIP (the escaped char must not make a following `#` a comment start).
setup_case
{ printf 'printf x '; printf '%s' "\\"; printf ' #; cd /repo-b\ngh pr merge %s --squash\n' "$PR"; } > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "escaped-space-then-# hidden cd: skipped"; else fail "escaped-space cd: rc=$RC N=$N body='$B'"; fi

# ── Case 28: assignment hidden behind a reserved word (`then GH_REPO=…`) plus a
#    bare `export GH_REPO` — both must be caught (interleaved strip + bare-name export).
setup_case
run_hook "if true; then GH_REPO=evil/x; export GH_REPO; fi; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "reserved-hidden sensitive assign + bare export: skipped"; else fail "hidden assign: rc=$RC body='$B'"; fi

# ── Case 29: Git env-config injection (GIT_CONFIG_* rewrites remote.origin.url) → SKIP.
setup_case
run_hook "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0=https://github.com/evil/x gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "GIT_CONFIG_* injection: skipped"; else fail "GIT_CONFIG: rc=$RC body='$B'"; fi

# ── Case 30: combinatorial — every {prefix} × {reserved} × {retargeter} placed
#    BEFORE a real merge MUST skip; a benign prefix/reserved with NO retargeter posts.
#    Guards the parser's grammar interaction beyond hand-picked cases (review LOW).
prefixes=("" "GH_REPO=evil/x " "GIT_DIR=/x/.git " "NO_WORKTREE=0 ")
reserved=("" "then " "{ ")
retargets=("cd /x" "gh pr view 1" "git remote -v" "source ./y" "builtin cd /x" "export GH_REPO")
combo_fail=0
for pfx in "${prefixes[@]}"; do
  for rsv in "${reserved[@]}"; do
    for rt in "${retargets[@]}"; do
      setup_case
      run_hook "${pfx}${rsv}${rt} ; gh pr merge $PR --squash" "" ""
      if [[ "$RC" != 0 || "$N" != 0 ]]; then combo_fail=$((combo_fail+1)); echo "  combo posted (should skip): [${pfx}${rsv}${rt}] N=$N"; fi
    done
  done
done
if [[ "$combo_fail" == 0 ]]; then ok "combinatorial retargeters-before-merge: all skipped"; else fail "combinatorial: $combo_fail combos wrongly posted"; fi
# a benign prefix + reserved with NO retargeter (just the merge) still posts once
setup_case
run_hook "NO_WORKTREE=0 ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "benign prefix, no retargeter: nudged"; else fail "benign prefix: rc=$RC body='$B'"; fi

# ── Case 31: `pushd`/`popd` dir-changing builtins before the merge → SKIP.
setup_case
run_hook "pushd /repo-b ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "pushd before merge: skipped"; else fail "pushd: rc=$RC body='$B'"; fi

# ── Case 32: a re-targeter hidden in a command substitution before the merge
#    (echo "$(git remote set-url …)") → SKIP (substitution content is scanned).
setup_case
# shellcheck disable=SC2016  # the literal $(...) is the payload under test, not for expansion
printf 'echo "$(git remote set-url origin https://github.com/evil/x.git)" ; gh pr merge %s --squash\n' "$PR" > "$CF"
run_hook_ml "$CF" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "retargeter in \$( ) before merge: skipped"; else fail "subst retargeter: rc=$RC body='$B'"; fi

# ── Case 33: position-aware — a sensitive assignment / pipe WHOLLY AFTER a
#    sequential merge must NOT suppress the nudge (post-merge can't re-target).
setup_case
run_hook "gh pr merge $PR --squash ; GH_REPO=x/y true" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "sensitive assign after merge: still nudged"; else fail "post-merge sensitive: rc=$RC N=$N body='$B'"; fi
setup_case
run_hook "gh pr merge $PR --squash ; echo done | tee /tmp/log" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "pipe after merge: still nudged"; else fail "post-merge pipe: rc=$RC N=$N body='$B'"; fi

# ── Case 34: merge as a LOOP CONDITION (`while gh pr merge; do <retarget>; done`)
#    re-runs after the body's retargeter → SKIP.
setup_case
run_hook "while gh pr merge $PR --squash; do cd /repo-b; done" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "merge as while-condition: skipped"; else fail "while-merge: rc=$RC body='$B'"; fi

# ── Case 35: merge inside a LOOP BODY (`for …; do gh pr merge; cd …; done`) → SKIP.
setup_case
run_hook "for i in 1 2; do gh pr merge $PR --squash; cd /repo-b; done" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "merge in for-body: skipped"; else fail "for-body merge: rc=$RC body='$B'"; fi

# ── Case 36: process substitution in the merge segment (--body-file <(/tmp/x)) runs
#    a command concurrently → SKIP.
setup_case
run_hook "gh pr merge $PR --squash --body-file <(/tmp/retarget)" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "process-substitution in merge seg: skipped"; else fail "proc-subst: rc=$RC body='$B'"; fi

# ── Case 37: any shell expansion in the merge segment → SKIP (merge-seg allowlist).
#    brace {a,--repo=evil}, and glob/pathname [-!]*/* — both inject extra args at
#    runtime though shlex sees one token.
setup_case
run_hook "gh pr merge $PR --squash --body-file {safe,--repo=evil/x}" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "brace expansion in merge seg: skipped"; else fail "brace expansion: rc=$RC body='$B'"; fi
setup_case
run_hook "gh pr merge $PR --squash --body-file [-!]*/*" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "glob/pathname expansion in merge seg: skipped"; else fail "glob expansion: rc=$RC body='$B'"; fi
# a normal merge with only literal flags still nudges (allowlist admits it)
setup_case
run_hook "gh pr merge $PR --squash --delete-branch --admin" "" ""
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "plain literal merge flags: nudged"; else fail "plain merge: rc=$RC body='$B'"; fi

# ── Case 38: Bash append-assignment export of a sensitive var (GH_REPO+=…) → SKIP.
#    (merge-first already skips the `export` command before the merge; this also
#    proves the sensitive-name check normalizes the `+=` append form.)
setup_case
run_hook "export GH_REPO+=evil/x ; gh pr merge $PR --squash" "" ""
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "export GH_REPO+= append: skipped"; else fail "append export: rc=$RC body='$B'"; fi

# ── Case 39: the `none`-check jq filter must tolerate a ghost/deleted reviewer or
#    any malformed (non-object) array element. A bare `.[].user.login` exits non-zero
#    on such an element → `gh` non-zero → `|| exit 0` → a false-negative MISSED nudge.
#    Extract the filter from the HOOK's actual `--jq '…'` CODE line (not a hardcoded
#    copy) so reverting the `?`s fails here. ANCHOR on `--jq '`: a bare filter-pattern
#    grep also matches the explanatory comment above line 211 (which quotes the filter),
#    so a regressed runtime line would be shadowed by the still-defensive comment and the
#    test would pass vacuously (Greptile P1, #397). The comment has no `--jq '`, so
#    anchoring on it targets only the runtime code. Fixture mixes a bare string, a
#    null-user element, and the real login.
NONE_FILTER=$(grep -oE "\-\-jq '[^']*'" "$HOOK" | head -1 | cut -d"'" -f2)
NF_OUT=$(printf '%s' '["ghost",{"user":null},{"user":{"login":"chatgpt-codex-connector[bot]"}}]' \
  | jq -r "${NONE_FILTER:-.INVALID}" 2>&1) || true
if [[ "$NF_OUT" == "chatgpt-codex-connector[bot]" ]]; then
  ok "none-check jq filter tolerates ghost/null elements (no false-negative skip)"
else
  fail "none-check jq must tolerate ghost/null elements — filter='$NONE_FILTER' out='$NF_OUT'"
fi

# ── Case 40: TRANSIENT `none`-guard fetch (#398) — the first reviews read fails, the
#    hook's bounded retry succeeds → the nudge STILL fires. Without the retry the
#    single transient would `|| exit 0` and silently drop the nudge on this
#    inline/admin merge (the sole delivery path, no pr-grind COMPLETION re-poll).
setup_case
ATT="$(mk)/attempts"
run_hook "gh pr merge $PR --squash" "" "" STUB_REVIEWS_FAIL_ONCE=1 STUB_ATTEMPTS_FILE="$ATT"
if [[ "$RC" == 0 && "$N" == 1 ]]; then ok "transient reviews fetch: retry recovered → nudged once"; else fail "transient fetch: rc=$RC N=$N body='$B'"; fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
