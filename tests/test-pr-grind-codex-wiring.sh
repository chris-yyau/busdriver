#!/usr/bin/env bash
# tests/test-pr-grind-codex-wiring.sh — static drift/wiring guard for the Codex
# auto-detect + GC restructure in skills/pr-grind/SKILL.md (ADR 0013 rev, #320/#327).
#
# CEILING (named honestly): golden-grep proves WIRING and ordering, not runtime
# behavior (syntax / branch nesting / var scope). The behavioral weight is carried
# by the three mechanism scripts' unit tests (test-codex-active-repo.sh,
# test-codex-retrigger-gc.sh, test-codex-nudge-if-expected.sh) plus the existing
# pr-grind integration. This test exists to catch the specific regressions the
# blueprint review flagged: swallowed stderr, bare script paths, mis-anchored GC,
# the two distant merge blocks drifting, and the default block's <PR_NUMBER> token.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$SCRIPT_DIR/skills/pr-grind/SKILL.md"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
has()  { grep -qF "$1" "$SKILL"; }        # fixed-string presence
hasre(){ grep -qE "$1" "$SKILL"; }        # regex presence

[ -f "$SKILL" ] || { fail "missing $SKILL"; echo "Results: $passed passed, $failed failed"; exit 1; }

# (a) CODEX_REGRACE initialized to CODEX_DONE (decouples warning from grace>0)
has 'CODEX_REGRACE="$CODEX_DONE"' && ok "CODEX_REGRACE init present" \
  || fail "missing CODEX_REGRACE=\"\$CODEX_DONE\" init"

# (b) grace guard keeps the `2>/dev/null` fail-soft redirect
has '[ "${CODEX_GRACE}" -gt 0 ] 2>/dev/null' && ok "grace guard retains 2>/dev/null" \
  || fail "grace guard dropped 2>/dev/null"

# (c) detector call discards STDOUT ONLY (stderr diagnostic must survive)
has 'scripts/codex-active-repo.sh" "$OWNER/$REPO" >/dev/null' \
  && ok "detector call redirects stdout only" \
  || fail "detector call missing / not stdout-only"
if grep -qE 'codex-active-repo\.sh" "\$OWNER/\$REPO" >/dev/null 2>&1' "$SKILL"; then
  fail "detector call swallows stderr (>/dev/null 2>&1) — diagnostic lost"
else
  ok "detector call does NOT swallow stderr"
fi

# (d) both scripts invoked via ${CLAUDE_PLUGIN_ROOT}/scripts/ — reject bare names
has '${CLAUDE_PLUGIN_ROOT}/scripts/codex-active-repo.sh' && ok "detector uses plugin-root path" \
  || fail "detector not invoked via \${CLAUDE_PLUGIN_ROOT}/scripts/"
has '${CLAUDE_PLUGIN_ROOT}/scripts/codex-nudge-if-expected.sh' && ok "nudge uses plugin-root path" \
  || fail "nudge not invoked via \${CLAUDE_PLUGIN_ROOT}/scripts/"
if grep -qE 'bash "?codex-(active-repo|nudge-if-expected|retrigger-gc)\.sh' "$SKILL"; then
  fail "a Codex script is invoked by BARE name (PATH not guaranteed)"
else
  ok "no bare-name Codex script invocations"
fi

# (e) nudge passes the active bit POSITIONALLY (arg after $OWNER/$REPO), not env
has 'codex-nudge-if-expected.sh" "$PR" "$HEAD_FULL_SHA" "$OWNER/$REPO" "$CODEX_REPO_ACTIVE"' \
  && ok "nudge receives \$CODEX_REPO_ACTIVE positionally" \
  || fail "nudge missing positional \$CODEX_REPO_ACTIVE arg"
if grep -qE 'CODEX_REPO_ACTIVE=.*bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/codex-nudge' "$SKILL"; then
  fail "active bit passed as ENV to the nudge (injectable — see #325)"
else
  ok "active bit not passed as env to the nudge"
fi

# (f) warning gated on CODEX_REPO_ACTIVE==1 AND the kill switch; copy says "engaged"
has '[ "$CODEX_REGRACE" = "none" ] && [ "$CODEX_REPO_ACTIVE" = "1" ]' \
  && ok "warning gated on none + CODEX_REPO_ACTIVE=1" \
  || fail "warning gate condition missing/changed"
has '[ "${PR_GRIND_CODEX_RETRIGGER:-1}" != "0" ]' \
  && ok "kill-switch guard present on detection" \
  || fail "kill-switch guard missing"
has 'has engaged on recent PRs of this repo' && ok 'warning copy says "engaged" (not "reviewed")' \
  || fail "warning copy missing / not engagement-accurate"

# (f2) Clean-path hoist (#467): the `none`-nudge must fire the instant a round
# converges to clean, DECOUPLED from COMPLETION — so a dispatcher that front-runs a
# merge-state probe and skips COMPLETION wholesale can never drop the nudge. Assert
# (1) the hoisted call exists with its clean guard, (2) the wrapper call sits INSIDE
# that guarded block (between the guard and the next `├──` sibling — not merely present
# somewhere in the file), and (3) the block is ORDERED BEFORE the COMPLETION FRESH_ACKS
# re-query (else it's re-buried in COMPLETION).
if has 'If RESULT_STATUS == clean AND RESULT_CODEX_ACK == "none"'; then
  ok "clean-path Codex nudge guard present (#467)"
else
  fail "clean-path Codex nudge guard missing (#467 regression — nudge re-buried in COMPLETION)"
fi
# (2) the wrapper invocation must live BETWEEN the guard line and the next `├──` node,
# proving it is inside the guarded clean-path block rather than orphaned elsewhere.
# shellcheck disable=SC2016  # $PR_NUMBER is matched literally, not expanded
HOIST_IN_BLOCK=$(awk '
  /If RESULT_STATUS == clean AND RESULT_CODEX_ACK == "none"/ { inblk=1; next }
  inblk && /^  ├──/                                          { inblk=0 }
  inblk && /codex-nudge-if-expected\.sh" "\$PR_NUMBER"/      { found=1 }
  END { print found ? "OK" : "BAD" }' "$SKILL")
if [[ "$HOIST_IN_BLOCK" == OK ]]; then
  ok "clean-path hoist call is inside the guarded block, using \$PR_NUMBER (#467)"
else
  fail "clean-path hoist call not inside the guarded block (#467 — guard/call decoupled)"
fi
# (3) ordering: guard must precede the COMPLETION FRESH_ACKS re-query.
HOIST_ORDER=$(awk '
  /If RESULT_STATUS == clean AND RESULT_CODEX_ACK == "none"/ { if (!hoist) hoist=NR }
  /^FRESH_ACKS="cursor=/                                     { if (!fresh) fresh=NR }
  END { print (hoist && fresh && hoist < fresh) ? "OK" : "BAD" }' "$SKILL")
if [[ "$HOIST_ORDER" == OK ]]; then
  ok "clean-path hoist ordered before COMPLETION FRESH_ACKS (#467)"
else
  fail "clean-path hoist NOT before COMPLETION nudge — ordering regression (#467)"
fi
# (4) the hoisted guard must ALSO include the kill-switch check — otherwise the
# nudge would post while PR_GRIND_CODEX_RETRIGGER=0, violating the documented
# off-switch behavior (cubic finding, PR #470).
HOIST_KILLSWITCH=$(awk '
  /If RESULT_STATUS == clean AND RESULT_CODEX_ACK == "none"/ { inblk=1; next }
  inblk && /^  ├──/                                          { inblk=0 }
  inblk && /PR_GRIND_CODEX_RETRIGGER:-1.*!= "0"/              { found=1 }
  END { print found ? "OK" : "BAD" }' "$SKILL")
if [[ "$HOIST_KILLSWITCH" == OK ]]; then
  ok "clean-path hoist guard includes kill-switch check (#470)"
else
  fail "clean-path hoist guard missing kill-switch check — nudge could post while PR_GRIND_CODEX_RETRIGGER=0 (#470)"
fi

# (5) gh-routing containment (#470 P1 / #416): the hoisted subshell makes credentialed
# `gh` calls, so a repo-controlled GH_HOST/GH_REPO could redirect them to an attacker
# host/repo. The block MUST pin the host + clear the repo override, and MUST NOT derive
# the repo from an ambient `gh repo view` (itself routable). Scope both checks to the
# hoisted block so they can't be satisfied by an unrelated site elsewhere in the file.
HOIST_CONTAIN=$(awk '
  /If RESULT_STATUS == clean AND RESULT_CODEX_ACK == "none"/ { inblk=1; next }
  inblk && /^  ├──/                                          { inblk=0 }
  inblk && /export GH_HOST=github\.com/                      { pin=1 }
  inblk && /unset GH_REPO/                                   { clr=1 }
  inblk && /\$\(gh repo view/                                { ambient=1 }
  END { print (pin && clr && !ambient) ? "OK" : "BAD" }' "$SKILL")
if [[ "$HOIST_CONTAIN" == OK ]]; then
  ok "clean-path hoist pins GH_HOST + clears GH_REPO, no ambient gh repo view (#470 P1)"
else
  fail "clean-path hoist missing gh-routing containment (GH_HOST pin / GH_REPO unset) or still uses ambient gh repo view (#470 P1 / #416)"
fi

# (g) GC wired into BOTH merge blocks after a MERGED guard; correct PR token per block
GC_COUNT=$(grep -c 'codex-retrigger-gc.sh' "$SKILL" || true)
[ "$GC_COUNT" -eq 2 ] && ok "codex-retrigger-gc.sh wired exactly twice" \
  || fail "expected 2 gc call sites, found $GC_COUNT"
has 'codex-retrigger-gc.sh" "$PR"' && ok "auto-admin block GC uses \$PR" \
  || fail "auto-admin GC not using \$PR"
has 'codex-retrigger-gc.sh" "<PR_NUMBER>"' && ok "default block GC uses <PR_NUMBER> template literal" \
  || fail "default GC not using <PR_NUMBER>"
# ordering: every gc call must be preceded by a MERGE_STATE==MERGED guard
ORDER_OK=$(awk '
  /MERGE_STATE" != "MERGED"/ { seen=1 }
  /codex-retrigger-gc\.sh/   { if (!seen) { print "BAD"; exit } }
  END { print "OK" }' "$SKILL")
[ "$ORDER_OK" = "OK" ] && ok "each GC call follows a MERGE_STATE==MERGED guard" \
  || fail "a GC call precedes its MERGED guard"

# (h) #427 head guard: BOTH executable merge invocations must pass
# --match-head-commit bound to the CLASSIFIED head SHA. Without it the merge is
# a non-atomic check-then-act — a push landing after classification merges an
# unreviewed head.
has 'gh pr merge "$PR" --squash --delete-branch --admin --match-head-commit "$REVIEWED_HEAD"' \
  && ok "auto-admin merge carries --match-head-commit" \
  || fail "auto-admin merge missing --match-head-commit (#427)"
has 'gh pr merge <PR_NUMBER> --squash --delete-branch --match-head-commit "$REVIEWED_HEAD"' \
  && ok "default merge carries --match-head-commit" \
  || fail "default merge missing --match-head-commit (#427)"
# REVIEWED_HEAD must be TEMPLATE-SUBSTITUTED with the classified SHA, never
# re-derived at merge time. Re-deriving blesses whatever local HEAD is current —
# including a commit that landed after classification — which shrinks the guard
# to remote-only pushes instead of closing the race.
TEMPLATE_COUNT=$(grep -c 'REVIEWED_HEAD=<full 40-char SHA' "$SKILL" || true)
[ "$TEMPLATE_COUNT" -eq 2 ] && ok "REVIEWED_HEAD template-substituted in both merge blocks" \
  || fail "expected 2 REVIEWED_HEAD template placeholders, found $TEMPLATE_COUNT"
if grep -qF 'REVIEWED_HEAD=$(' "$SKILL"; then
  fail "REVIEWED_HEAD re-derived at merge time — defeats the #427 guard"
else
  ok "REVIEWED_HEAD never re-derived in a merge block"
fi
# Same trap in the operator-facing [admin] decision templates: they must carry
# the substituted <REVIEWED_HEAD> token, never a live rev-parse.
if grep -qF -- '--match-head-commit $(' "$SKILL"; then
  fail "an [admin] template re-derives the SHA inline — defeats the #427 guard"
else
  ok "no --match-head-commit site re-derives the SHA inline"
fi
TMPL_ADMIN=$(grep -c -- '--admin --match-head-commit <REVIEWED_HEAD>' "$SKILL" || true)
[ "$TMPL_ADMIN" -eq 4 ] && ok "all 4 [admin] decision templates carry the head guard" \
  || fail "expected 4 guarded [admin] templates, found $TMPL_ADMIN"

# (i) #427 P1 gap (PR #429 review): on a --match-head-commit rejection (HEAD moved
# after classification, MERGE_STATE never reaches MERGED), the already-written
# pr-grind-clean.local marker must be invalidated in BOTH merge blocks — else a
# subsequent plain `gh pr merge` (no head guard) can sail through pre-merge-gate.sh
# on the stale marker and merge an unclassified head.
MARKER_RM_COUNT=$(grep -c 'rm -f "$MARKER_REPO_ROOT/.claude/pr-grind-clean.local"' "$SKILL" || true)
[ "$MARKER_RM_COUNT" -eq 2 ] && ok "clean marker invalidated on merge-state mismatch in both blocks" \
  || fail "expected 2 marker-invalidation sites, found $MARKER_RM_COUNT (#427 P1 gap)"
# ordering: every marker-invalidation must be preceded (in the same failure branch)
# by a MERGE_STATE != MERGED guard, and appear before that branch's exit 1 — so it
# actually fires on the guard-rejection path rather than unconditionally.
MARKER_ORDER_OK=$(awk '
  /MERGE_STATE" != "MERGED"/ { in_branch=1 }
  in_branch && /rm -f "\$MARKER_REPO_ROOT\/\.claude\/pr-grind-clean\.local"/ { seen_rm=1 }
  in_branch && /exit 1/ {
    if (!seen_rm) { found_bad=1; exit }
    in_branch=0; seen_rm=0
  }
  END { print (found_bad ? "BAD" : "OK") }' "$SKILL")
[ "$MARKER_ORDER_OK" = "OK" ] && ok "marker invalidation precedes exit 1 in its failure branch" \
  || fail "marker invalidation missing/misordered relative to exit 1"
# ── Codex first-engagement POLL loop (#420) ────────────────────────────
# WHY: the grace was a single blind `sleep 20`, but measured @codex-review →
# review latency on this repo is 3m37s–7m27s (PRs #412/#419/#409/#390). The
# re-poll always observed `none` and merged seconds before the review landed.
# These assert the blind sleep cannot come back.
hasre 'CODEX_GRACE="\$\{PR_GRIND_CODEX_GRACE_SECS:-480\}"' \
  && ok "grace deadline default is 480s (> measured Codex latency)" \
  || fail "CODEX_GRACE default is not 480 — a sub-minute default re-opens #420"
hasre 'CODEX_POLL="\$\{PR_GRIND_CODEX_POLL_SECS:-30\}"' \
  && ok "poll interval default 30s present" || fail "missing CODEX_POLL default"
has 'case "$CODEX_GRACE" in' && has 'case "$CODEX_POLL"' \
  && ok "both knobs sanitized against non-numeric input" \
  || fail "CODEX_GRACE/CODEX_POLL not sanitized"
has 'CODEX_DEADLINE=$(( $(date +%s) + CODEX_WAIT ))' \
  && ok "deadline computed once, before the loop" \
  || fail "deadline missing or recomputed inside the loop (wait could extend past CODEX_WAIT)"
has '_CODEX_REM=$(( CODEX_DEADLINE - $(date +%s) ))' \
  && ok "deadline tested at top of loop (never an unbounded hang)" || fail "missing deadline test"
# The long deadline must apply ONLY where Codex is expected. Without this, raising
# the default imposed an 8-minute wait on every Codex-LESS repo's merge.
has 'if [ "$CODEX_REPO_ACTIVE" != "1" ] && [ "$CODEX_EXPECTED" != "1" ]; then' \
  && ok "long wait gated on proven-active OR force-on" \
  || fail "wait not gated — Codex-less repos would pay the full deadline"
has 'pr-grind-codex-expected.local' \
  && ok "force-on opt-in resolved for the wait gate" || fail "force-on file not consulted"
# The force-on marker MUST resolve identically to codex-nudge-if-expected.sh:60-64
# (WORKTREE_DIR cwd, BUSDRIVER_MAIN_ROOT honored, LITERAL .claude) — a divergence
# lets the wrapper nudge while this gate caps the wait at 20s.
has '${_MR}/.claude/pr-grind-codex-expected.local' \
  && ok "force-on marker uses literal .claude (matches the wrapper)" \
  || fail "force-on marker path diverges from the wrapper's"
if grep -q 'BUSDRIVER_STATE_DIR:-.claude}/pr-grind-codex-expected' "$SKILL"; then
  fail "force-on marker honors BUSDRIVER_STATE_DIR but the wrapper does not — mismatch"
else
  ok "force-on marker does not diverge via BUSDRIVER_STATE_DIR"
fi
# After the wait, the FULL ledger must be recomputed -- not just the Codex entry.
# Re-folding Codex alone leaves 5 bots at pre-wait values across a 480s window, so a
# bot that posts CHANGES_REQUESTED during it would still read as passing.
hasre 'FRESH_ACKS="cursor=\$\(bash "\$ACK_SCRIPT" cursor.*greptile-apps=\$\(bash "\$ACK_SCRIPT" greptile-apps' \
  && ok "full 6-bot ledger recomputed after the wait" \
  || fail "post-wait ledger not fully recomputed — stale bot acks could authorize merge"
if grep -q 's/chatgpt-codex-connector=none/chatgpt-codex-connector=' "$SKILL"; then
  fail "Codex-only sed re-fold still present — the other 5 bots stay stale"
else
  ok "Codex-only sed re-fold removed"
fi
# HEAD must be re-verified after the wait: acks are classified against the PRE-wait
# HEAD_SHA while `gh pr merge` targets the live PR, so a push during the window
# would carry old acks onto a new head.
# The Codex verdict normalization must be fail-CLOSED. A `?*` arm matches every
# non-empty string and would accept arbitrary ack-ledger output.
if grep -qE 'none \| stale \| \?\*' "$SKILL"; then
  fail "verdict normalization has a ?* arm — fail-OPEN, accepts any non-empty value"
else
  ok "verdict normalization has no fail-open ?* arm"
fi
# A length check here would be a severe bug: ack-ledger emits the SHORT sha
# (SKILL.md: `git rev-parse HEAD | cut -c1-8`), so requiring 40 chars would stale
# every valid ack and block every merge where Codex engaged.
if grep -qE '\$\{#CODEX_REGRACE\}" -eq 40' "$SKILL"; then
  fail "verdict normalization length-checks for 40 chars — ack-ledger emits an 8-char sha"
else
  ok "verdict normalization does not length-check the sha"
fi
# ack-ledger's contract is exactly none | stale | the CURRENT HEAD_SHA, so the
# guard must test equality with HEAD_SHA -- not "looks like hex", which admits
# stray values like `f` or an unrelated SHA as successful acks.
has 'none | stale | "$HEAD_SHA") : ;;' \
  && ok "verdict matched against the ack-ledger contract (none|stale|HEAD_SHA)" \
  || fail "verdict not matched against \$HEAD_SHA — a stray value could read as an ack"
_norm() {  # mirrors the SKILL normalization; $2 = current HEAD_SHA
  local v="$1" HEAD_SHA="$2"
  case "$v" in
    none | stale | "$HEAD_SHA") : ;;
    *) v=stale ;;
  esac
  echo "$v"
}
[ "$(_norm none abc12345)" = "none" ] && [ "$(_norm stale abc12345)" = "stale" ] \
  && [ "$(_norm abc12345 abc12345)" = "abc12345" ] \
  && ok "normalization preserves valid verdicts (none/stale/current HEAD_SHA)" \
  || fail "normalization corrupted a valid verdict"
[ "$(_norm '' abc12345)" = "stale" ] && [ "$(_norm 'ERROR: boom' abc12345)" = "stale" ] \
  && [ "$(_norm deadbeef abc12345)" = "stale" ] && [ "$(_norm f abc12345)" = "stale" ] \
  && ok "normalization blocks empty / error / stray-hex / other-SHA (fail-CLOSED)" \
  || fail "normalization let a malformed verdict through"
has 'CODEX_HEAD_NOW=$(gh pr view "$PR" --json headRefOid' \
  && ok "HEAD re-verified after the wait" || fail "no post-wait HEAD re-verify — merge could target an unreviewed head"
has '[ -z "$CODEX_HEAD_NOW" ] || [ "$CODEX_HEAD_NOW" != "$HEAD_FULL_SHA" ]' \
  && ok "HEAD guard fails CLOSED on divergence AND on lookup failure" \
  || fail "HEAD guard not fail-closed"
# Tier-D carry-forward must survive the in-loop refresh that replaces ALL_CHECK_RUNS.
hasre '\[ -f "\$AUGMENT_SCRIPT" \] && \. "\$AUGMENT_SCRIPT"' \
  && ok "Tier-D augmentation re-applied after the refresh" \
  || fail "augment-equiv-acks not re-sourced — Tier-D acks lost on force-push"
# ...but ONCE, after the loop — the in-loop verdict is Codex-only (no Tier D), so
# per-interval re-sourcing would add a repo view + GraphQL call to all 16 rounds.
AUG_AFTER_DONE=$(awk '
  /^  done$/                              { done_seen = 1 }
  /\[ -f "\$AUGMENT_SCRIPT" \] && \. /    { print (done_seen ? "AFTER" : "BEFORE") }' "$SKILL" \
  | tail -1)
[ "$AUG_AFTER_DONE" = "AFTER" ] \
  && ok "augmentation re-sourced outside the loop (not per interval)" \
  || fail "augmentation re-sourced INSIDE the poll loop — dozens of wasted API calls"
# A fetch glitch must not be mistaken for engagement.
has '[ "$CODEX_REGRACE" != "none" ] && [ "$FETCH_OK" = "1" ] && break' \
  && ok "poll exits only on a verdict from a COMPLETE snapshot" \
  || fail "loop can exit on a transient fetch failure read as engagement"
has 'FETCH_OK=1' \
  && ok "FETCH_OK reset per poll (one bad round does not poison the rest)" \
  || fail "FETCH_OK not reset per iteration — sticky failure condemns every later poll"
# Leading zeros: `0480` passes an all-digits test but $(( )) reads it as octal.
has 'CODEX_GRACE=$((10#$CODEX_GRACE))' && has 'CODEX_POLL=$((10#$CODEX_POLL))' \
  && ok "both knobs canonicalized with 10# (no octal abort)" \
  || fail "missing 10# canonicalization — PR_GRIND_CODEX_GRACE_SECS=0480 aborts the shell"
# Prove the octal trap is real and the guard defuses it, both outcomes.
_octal_raw() { local v="$1"; case "$v" in ''|*[!0-9]*) v=480 ;; esac; echo $(( 100 + v )); }
_octal_fix() { local v="$1"; case "$v" in ''|*[!0-9]*) v=480 ;; esac; v=$((10#$v)); echo $(( 100 + v )); }
# Run in an explicit SUBSHELL: a fatal arithmetic error would otherwise be able to
# take down this test shell before the remaining checks run, depending on bash
# version. The subshell absorbs it and we judge on its exit status.
if ( _octal_raw 0480 ) >/dev/null 2>&1; then
  fail "expected bare arithmetic to reject 0480 as octal — trap assumption wrong"
else
  ok "unguarded arithmetic DOES abort on 0480 (the trap is real)"
fi
[ "$(_octal_fix 0480 2>/dev/null)" = "580" ] \
  && ok "10# canonicalization accepts 0480 as decimal 480" || fail "10# guard did not defuse 0480"
# Interval > deadline would overshoot on the very first sleep.
has '[ "$CODEX_POLL" -gt "$CODEX_WAIT" ] && CODEX_POLL="$CODEX_WAIT"' \
  && ok "poll interval clamped to the deadline" || fail "poll interval not clamped"
has 'if [ "$_CODEX_REM" -lt "$CODEX_POLL" ]; then sleep "$_CODEX_REM"; else sleep "$CODEX_POLL"; fi' \
  && ok "each sleep clamped to remaining time (no overrun)" || fail "sleep not clamped to remaining"
if grep -qE '^[[:space:]]*sleep "\$CODEX_GRACE"[[:space:]]*$' "$SKILL"; then
  fail "blind 'sleep \$CODEX_GRACE' still present — the #420 regression"
else
  ok "no blind full-grace sleep remains"
fi

# Behavioral check of the loop CONTROL FLOW — both outcomes, per "prove the guard
# fires". CEILING: this is a replica of the loop skeleton, not the SKILL prose
# itself (markdown prose is not sourceable); the greps above pin the real block to
# this shape. It proves the deadline math terminates and the early-exit works.
_loop() {  # $1=wait $2=poll $3=iterations-until-engagement (0 = never)
  local CODEX_WAIT="$1" CODEX_POLL="$2" want="$3" n=0 CODEX_REGRACE=none
  local CODEX_DEADLINE _CODEX_REM
  [ "$CODEX_POLL" -gt "$CODEX_WAIT" ] && CODEX_POLL="$CODEX_WAIT"
  CODEX_DEADLINE=$(( $(date +%s) + CODEX_WAIT ))
  while :; do
    _CODEX_REM=$(( CODEX_DEADLINE - $(date +%s) ))
    [ "$_CODEX_REM" -le 0 ] && break
    if [ "$_CODEX_REM" -lt "$CODEX_POLL" ]; then sleep "$_CODEX_REM"; else sleep "$CODEX_POLL"; fi
    n=$((n + 1))
    [ "$want" -gt 0 ] && [ "$n" -ge "$want" ] && CODEX_REGRACE=engaged
    [ "$CODEX_REGRACE" != "none" ] && break
  done
  echo "$CODEX_REGRACE:$n"
}
# PASS outcome: engages on poll 2 → breaks early, well inside the deadline.
[ "$(_loop 10 1 2)" = "engaged:2" ] \
  && ok "loop exits early on engagement" || fail "loop did not early-exit on engagement"
# FAIL outcome: never engages → terminates at the deadline rather than spinning.
_R=$(_loop 2 1 0)
case "$_R" in none:*) ok "loop terminates at deadline when Codex never engages" ;;
              *) fail "loop did not terminate at deadline (got $_R)" ;; esac
# Interval LARGER than the deadline must still respect the deadline, not the
# interval — the PR_GRIND_CODEX_POLL_SECS=3600 / deadline=480 case from review.
_T0=$(date +%s); _R=$(_loop 2 3600 0); _T1=$(date +%s)
[ $(( _T1 - _T0 )) -le 4 ] \
  && ok "poll > deadline still bounded by the deadline (took $(( _T1 - _T0 ))s)" \
  || fail "poll > deadline overshot: took $(( _T1 - _T0 ))s for a 2s deadline"

# (j) deadline last-good fallback must restore the PAYLOADS + FETCH_OK, not just
# the Codex verdict. The five non-Codex reviewers are recomputed after the poll
# loop from those same six variables; restoring the verdict alone leaves them on
# the incomplete snapshot and fails every one closed to `stale`, blocking a merge
# for the transient reason the fallback exists to absorb.
has 'CODEX_LG_OK=0' && ok "last-good payload snapshot flag initialized" \
  || fail "CODEX_LG_OK not initialized — payload fallback missing"
for v in CODEX_LG_REACTIONS CODEX_LG_REVIEWS CODEX_LG_COMMENTS CODEX_LG_CHECK_RUNS CODEX_LG_STATUSES CODEX_LG_THREADS; do
  has "$v=" && ok "payload snapshot var $v present" || fail "missing payload snapshot var $v"
done
has '[ "$FETCH_OK" != "1" ] && [ "$CODEX_LG_OK" = "1" ]' \
  && ok "deadline restore gated on a COMPLETE snapshot having been seen" \
  || fail "deadline restore not gated on CODEX_LG_OK — could restore garbage or fail open"
# The restore must clear FETCH_OK, else the post-loop recompute still fails closed.
# Bound the search to the restore block itself (stop at its closing `fi`).
# Unbounded, this matched the per-iteration `FETCH_OK=1` reset further down the
# loop and passed even when the restore had none — a vacuous assertion.
if awk '/\[ "\$FETCH_OK" != "1" \] && \[ "\$CODEX_LG_OK" = "1" \]/ { r=1; next }
        r && /^ *fi *$/ { r=0 }
        r && /^ *FETCH_OK=1 *$/ { found=1 }
        END { exit !found }' "$SKILL"; then
  ok "deadline restore resets FETCH_OK=1"
else
  fail "deadline restore does not reset FETCH_OK — other reviewers still fail closed"
fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
