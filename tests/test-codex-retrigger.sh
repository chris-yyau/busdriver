#!/usr/bin/env bash
# tests/test-codex-retrigger.sh
#
# Verifies scripts/codex-retrigger.sh — the bounded, paced per-(PR,HEAD) `@codex review`
# re-trigger that breaks the Codex-stale-on-unchanged-HEAD wait-round dead-end.
#
# `gh` is stubbed (a fake on PATH) that records every invocation and the --body it
# was given; the script's marker is redirected to a temp BUSDRIVER_STATE_DIR so the
# real repo is never touched. We assert the OBSERVABLE contract: when (and only
# when) a post happens, and that a failed post never writes the attempt marker
# (so the next wait-round retries) and never returns non-zero (never stales gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RT="$SCRIPT_DIR/scripts/codex-retrigger.sh"
BASH_BIN="$(command -v bash)"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[ -f "$RT" ] || { fail "missing $RT"; echo "Results: $passed passed, $failed failed"; exit 1; }

TMP_DIRS=()
cleanup() { local d; for d in "${TMP_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT
mk() { local d; d=$(mktemp -d); TMP_DIRS+=("$d"); printf '%s' "$d"; }

# A fake `gh`: logs the full argv to $GH_CALLLOG, the --body value to $GH_BODYFILE.
# STUB_GH_FAIL=1  → every `pr comment` fails (exit 1).
# STUB_GH_FAIL_ONCE=1 → only the FIRST `pr comment` fails, later ones succeed
#   (a single transient) — proves the bounded in-process retry recovers (#398).
make_gh_stub() {
  local bindir="$1"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_CALLLOG:?}"
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "--body" ] && printf '%s\n' "$a" >> "${GH_BODYFILE:?}"
    prev="$a"
  done
  [ "${STUB_GH_FAIL:-0}" = "1" ] && exit 1
  # This invocation was already logged above, so on the first post the count is 1.
  if [ "${STUB_GH_FAIL_ONCE:-0}" = "1" ] \
     && [ "$(grep -c 'pr comment' "${GH_CALLLOG}" 2>/dev/null)" -le 1 ]; then
    exit 1
  fi
  exit 0
fi
exit 0
STUB
  chmod +x "$bindir/gh"
}

PR=217
HEAD=11abbbdfdeadbeef
HEAD8=${HEAD:0:8}
MARKER_NAME=".pr-grind-codex-retriggered-pr${PR}-${HEAD8}.local"

# Fresh sandbox per case: returns "statedir bindir calllog bodyfile" on one line.
setup_case() {
  local state bin
  state=$(mk); bin=$(mk); make_gh_stub "$bin"
  printf '%s %s %s %s' "$state" "$bin" "$state/calls.log" "$state/body.log"
}
posts_in() { [ -f "$1" ] && grep -c 'pr comment' "$1" 2>/dev/null || echo 0; }

# ============================================================
# 1. HAPPY PATH — marker absent, opt-in default ON: posts exactly one
#    `@codex review` and writes the attempt-1 marker. Exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$STATE/$MARKER_NAME" ] \
   && [ "$(cat "$BODYFILE" 2>/dev/null)" = "@codex review" ]; then
  ok "happy path: one '@codex review' posted, marker written, exit 0"
else
  fail "happy path: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no) body='$(cat "$BODYFILE" 2>/dev/null)'"
fi

# ============================================================
# 2. SECOND ROUND, DEFAULT CONFIG — attempt-1 marker already present for this
#    (PR,HEAD): no post, exit 0. Held by the default 180s cooldown since #673/#676
#    (pre-#673 it was the hard one-shot marker); the observable contract is the same.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
: > "$STATE/$MARKER_NAME"          # pre-existing marker
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "default config: attempt-1 marker present → no second post (exit 0)"
else
  fail "default config: expected no post, rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 3. OPT-OUT — PR_GRIND_CODEX_RETRIGGER=0: no post, no marker, exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       PR_GRIND_CODEX_RETRIGGER=0 "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ] && [ ! -e "$STATE/$MARKER_NAME" ]; then
  ok "opt-out (PR_GRIND_CODEX_RETRIGGER=0): no-op, no marker (exit 0)"
else
  fail "opt-out: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 4. FAIL-SAFE — gh post fails on BOTH bounded attempts: exit 0 (never stale gate)
#    AND marker NOT written (so the next wait-round retries). The retry (#398) makes
#    this 2 attempts, not 1.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       STUB_GH_FAIL=1 "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 2 ] && [ ! -e "$STATE/$MARKER_NAME" ]; then
  ok "fail-safe: post failed both attempts → exit 0, marker NOT written (retry next round)"
else
  fail "fail-safe: rc=$rc posts=$(posts_in "$CALLLOG") (expected 2) marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 4b. TRANSIENT RECOVERY (#398) — first post fails, the bounded retry succeeds: the
#     nudge IS delivered → marker written, exit 0. Without the retry the single
#     transient would release the claim and drop the nudge with no next round behind it.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       STUB_GH_FAIL_ONCE=1 "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 2 ] && [ -e "$STATE/$MARKER_NAME" ]; then
  ok "transient recovery: first post failed, retry posted → marker written (exit 0)"
else
  fail "transient recovery: rc=$rc posts=$(posts_in "$CALLLOG") marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 5. CUSTOM PHRASE — PR_GRIND_CODEX_RETRIGGER_PHRASE overrides the body.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       PR_GRIND_CODEX_RETRIGGER_PHRASE="@codex please re-review" "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$BODYFILE" 2>/dev/null)" = "@codex please re-review" ]; then
  ok "custom phrase: posted body matches PR_GRIND_CODEX_RETRIGGER_PHRASE"
else
  fail "custom phrase: rc=$rc body='$(cat "$BODYFILE" 2>/dev/null)'"
fi

# ============================================================
# 6. BAD INPUT — non-hex HEAD is a benign skip: no post, no marker, exit 0.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "zzz123nothex" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "bad input (non-hex HEAD): benign skip, no post (exit 0)"
else
  fail "bad input: rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 7. USAGE ERROR — missing required args: exit 2, no post.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" ) || rc=$?
if [ "$rc" = 2 ] && [ "$(posts_in "$CALLLOG")" = 0 ]; then
  ok "usage error: missing args → exit 2, no post"
else
  fail "usage error: expected exit 2, got rc=$rc posts=$(posts_in "$CALLLOG")"
fi

# ============================================================
# 8. GH MISSING — `gh` not on PATH: safe skip, no marker, exit 0. (Run with an
#    empty PATH; the script reaches the `command -v gh` guard using only builtins.)
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
       "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$STATE/$MARKER_NAME" ]; then
  ok "gh missing: safe skip, no marker (exit 0)"
else
  fail "gh missing: rc=$rc marker=$([ -e "$STATE/$MARKER_NAME" ] && echo yes || echo no)"
fi

# ============================================================
# 9. SEQUENTIAL IDEMPOTENCY — two real invocations on the same (PR,HEAD): the
#    first posts + claims the marker, the second is a no-op. Validates the dedup
#    end-to-end (real post, then real re-run), not just a pre-seeded marker.
# ============================================================
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
rc=0
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
  "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
  "$BASH_BIN" "$RT" "$PR" "$HEAD" ) || rc=$?
if [ "$rc" = 0 ] && [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$STATE/$MARKER_NAME" ]; then
  ok "sequential idempotency: two real runs → exactly one post, marker held"
else
  fail "sequential idempotency: rc=$rc posts=$(posts_in "$CALLLOG") (expected 1)"
fi

# ============================================================
# #673 — BOUNDED-N RE-TRIGGER. ADR 0005 shipped one-shot per (PR,HEAD) for
# anti-spam reasons only, which made a single dropped nudge terminal for the PR —
# and #673 showed the Codex ack tiers cannot self-clear after the first fix round,
# so this nudge is the ONLY exit. It is now N attempts (default 3) paced by a
# cooldown. Cases 1–9 above already pin the DEFAULT-config behavior (the default
# 180s cooldown is what holds cases 2 and 9 to a single post); these pin that the
# budget both SPENDS and STOPS, that a failure costs nothing, and that a marker
# from the pre-#673 plugin is honored rather than granting a fresh budget.
#
# #676 — COOLDOWN/WAIT-BUDGET COUPLING. #673 shipped MAX=3/COOLDOWN=900, which
# needs 1800s to spend the full budget — over 3x the ~8-minute wait budget
# `--max-wait 8` gives the dispatcher (ADR 0005's Context section), so under
# default settings the loop bailed before attempt 2's cooldown ever elapsed,
# silently reproducing the one-shot dead end #673 existed to close. Case 18 below
# pins the corrected relationship as an executable assertion rather than prose.
# ============================================================
marker_n() {
  if [ "$1" = 1 ]; then printf '%s' "$MARKER_NAME"
  else printf '.pr-grind-codex-retriggered-pr%s-%s-%s.local' "$PR" "$HEAD8" "$1"; fi
}
# Run once in a sandbox; extra `VAR=value` args are passed as environment.
run_rt() {
  ( PATH="$BIN:$PATH" GH_CALLLOG="$CALLLOG" GH_BODYFILE="$BODYFILE" BUSDRIVER_STATE_DIR="$STATE" \
    env "$@" "$BASH_BIN" "$RT" "$PR" "$HEAD" ) >/dev/null 2>&1
}

# --- 10/11. The budget spends across rounds, then STOPS. Both directions of the
#            same guard: a guard that only ever passes is not a guard.
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
for _i in 1 2 3 4; do run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=3; done
if [ "$(posts_in "$CALLLOG")" = 3 ] \
   && [ -e "$STATE/$(marker_n 1)" ] && [ -e "$STATE/$(marker_n 2)" ] && [ -e "$STATE/$(marker_n 3)" ]; then
  ok "bounded-N: 4 rounds with cooldown disabled → exactly 3 posts, one marker per attempt"
else
  fail "bounded-N: posts=$(posts_in "$CALLLOG") (expected 3) slots=$([ -e "$STATE/$(marker_n 1)" ] && printf 1)$([ -e "$STATE/$(marker_n 2)" ] && printf 2)$([ -e "$STATE/$(marker_n 3)" ] && printf 3)"
fi

# --- 12. MAX=1 restores ADR 0005's exact one-shot (the documented escape hatch).
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=1
run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=1
if [ "$(posts_in "$CALLLOG")" = 1 ] && [ ! -e "$STATE/$(marker_n 2)" ]; then
  ok "MAX=1: restores one-shot exactly (2 rounds → 1 post, no slot 2)"
else
  fail "MAX=1: posts=$(posts_in "$CALLLOG") (expected 1)"
fi

# --- 13. A marker left by the PRE-#673 plugin uses the unsuffixed slot-1 name, so
#         it must read as "attempt 1 already spent". If the scan missed it, the
#         upgrade would silently hand every in-flight PR a fresh full budget.
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
: > "$STATE/$MARKER_NAME"
run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=3
if [ "$(posts_in "$CALLLOG")" = 1 ] && [ -e "$STATE/$(marker_n 2)" ] && [ ! -e "$STATE/$(marker_n 3)" ]; then
  ok "legacy marker: counted as attempt 1 spent → next post lands in slot 2"
else
  fail "legacy marker: posts=$(posts_in "$CALLLOG") slot2=$([ -e "$STATE/$(marker_n 2)" ] && echo yes || echo no)"
fi

# --- 14. The cooldown must BLOCK while hot and RELEASE once elapsed. Backdated with
#         `touch -t` (POSIX) rather than a sleep, so the elapsed branch is genuinely
#         executed without slowing the suite.
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
run_rt PR_GRIND_CODEX_RETRIGGER_MAX=3                      # attempt 1
run_rt PR_GRIND_CODEX_RETRIGGER_MAX=3                      # blocked: still hot
hot=$(posts_in "$CALLLOG")
touch -t 202001010000 "$STATE/$(marker_n 1)"               # age it past any cooldown
run_rt PR_GRIND_CODEX_RETRIGGER_MAX=3                      # attempt 2: cooldown elapsed
if [ "$hot" = 1 ] && [ "$(posts_in "$CALLLOG")" = 2 ] && [ -e "$STATE/$(marker_n 2)" ]; then
  ok "cooldown: blocks while hot (1 post), releases once elapsed (2 posts)"
else
  fail "cooldown: hot=$hot (expected 1) after-elapse=$(posts_in "$CALLLOG") (expected 2)"
fi

# --- 15. A malformed budget knob must fall back to the DEFAULT, never to unlimited.
#         Fail-safe direction matters here: the wrong fallback spams the PR.
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
for _i in 1 2 3 4 5; do run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=not-a-number; done
if [ "$(posts_in "$CALLLOG")" = 3 ]; then
  ok "malformed MAX: falls back to default 3, not unlimited"
else
  fail "malformed MAX: posts=$(posts_in "$CALLLOG") (expected 3)"
fi

# --- 15b. MAX has a CEILING, and it is load-bearing rather than tidiness: MAX drives
#          the slot-scan loop, so an accidental huge-but-valid integer would run that
#          many filesystem probes every wait-round and hang the merge gate (litmus
#          MEDIUM on this PR). Out-of-range must land on the DEFAULT, not the ceiling
#          and not unlimited. 10 is accepted; 11 and a fat-fingered 999999999 are not.
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
for _i in $(seq 1 12); do run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=10; done
at_ceiling=$(posts_in "$CALLLOG")
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
for _i in $(seq 1 12); do run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=999999999; done
over_ceiling=$(posts_in "$CALLLOG")
if [ "$at_ceiling" = 10 ] && [ "$over_ceiling" = 3 ]; then
  ok "MAX ceiling: 10 honored, 999999999 rejected to default 3 (bounds the scan loop)"
else
  fail "MAX ceiling: at-ceiling=$at_ceiling (expected 10) over-ceiling=$over_ceiling (expected 3)"
fi

# --- 16. A failed post must spend NO attempt and start NO cooldown — the claim is
#         released, so the next round re-derives the SAME slot. This is why the scan
#         counts occupied markers and claims the lowest free slot, rather than
#         taking the highest occupied slot (see case 17's hole-refill below).
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
run_rt STUB_GH_FAIL=1 PR_GRIND_CODEX_RETRIGGER_MAX=3
failed_marker=$([ -e "$STATE/$(marker_n 1)" ] && echo yes || echo no)
run_rt PR_GRIND_CODEX_RETRIGGER_MAX=3
if [ "$failed_marker" = no ] && [ -e "$STATE/$(marker_n 1)" ] && [ ! -e "$STATE/$(marker_n 2)" ]; then
  ok "failed post: spends no attempt, no cooldown — next round reclaims slot 1"
else
  fail "failed post: marker-after-failure=$failed_marker slot2=$([ -e "$STATE/$(marker_n 2)" ] && echo yes || echo no)"
fi

# --- 17. HOLE REFILL. A slot can be free BELOW an occupied one: a `gh pr comment`
#         still in flight when the cooldown elapses lets a second run legitimately
#         claim slot 2, and if the first post then fails it releases slot 1. Reading
#         the highest occupied slot would count that hole as spent — silently
#         shrinking the budget and making "a failed post spends no attempt" false
#         (litmus MEDIUM, PR mode). Occupancy + lowest-free must refill the hole.
read -r STATE BIN CALLLOG BODYFILE <<<"$(setup_case)"
: > "$STATE/$(marker_n 2)"                       # slot 2 occupied, slot 1 a hole
run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=3
refilled=$([ -e "$STATE/$(marker_n 1)" ] && echo yes || echo no)
run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=3
run_rt PR_GRIND_CODEX_RETRIGGER_COOLDOWN=0 PR_GRIND_CODEX_RETRIGGER_MAX=3
if [ "$refilled" = yes ] && [ "$(posts_in "$CALLLOG")" = 2 ] && [ -e "$STATE/$(marker_n 3)" ]; then
  ok "hole refill: free slot below an occupied one is reclaimed, full budget preserved"
else
  fail "hole refill: refilled=$refilled posts=$(posts_in "$CALLLOG") (expected 2, i.e. budget 3 minus the pre-seeded slot)"
fi

# --- 18. #676 — SHIPPED DEFAULTS MUST FIT THE DISPATCHER'S DEFAULT WAIT BUDGET.
#         `COOLDOWN * (MAX - 1)` is the wall-clock needed to spend the full budget
#         (MAX-1 gaps between MAX attempts); any attempt that would land later than
#         the dispatcher's `--max-wait` wall-clock is never reached, because the
#         dispatcher bails first. ADR 0005's Context section documents `--max-wait 8`
#         exhausting in ~8 minutes (480s) — that is the wall-clock this pins against.
#         A future default that violates this inequality makes the retry budget
#         unreachable in practice: the exact #676 defect (900*2=1800s vs. a ~480s
#         budget, i.e. attempt 2 would land 22.5 minutes after the dispatcher already
#         bailed). Read the values out of the SHIPPED SCRIPT rather than hardcoding
#         them here, so this fails loudly if either knob's default regresses.
#
#         THE MARGIN IS PART OF THE ASSERTION. A bare `<=` against the full 480s
#         admits COOLDOWN=240 (240*2=480 exactly), which places the last attempt at
#         the precise instant the dispatcher bails — reachable only with zero trigger
#         latency, zero marker-write time and perfectly aligned polling. That was the
#         FIRST attempt at fixing this defect and litmus flagged it MEDIUM on the same
#         PR. So the budget must be fit INSIDE, not filled: require 20% headroom, and
#         confirm this case rejects 240 as well as 900 before trusting it.
#
#         WHAT THIS DOES *NOT* PROVE — read before relying on it. `--max-wait` counts
#         wait-ROUNDS, not seconds, and the dispatcher enforces no minimum duration per
#         round. So 480s is a documented TYPICAL (ADR 0005's Context), never a
#         guarantee: eight fast rounds can exhaust the budget in well under 360s, and
#         the later attempts would be unreachable while this case still passes. Do not
#         read a green result here as "the retry budget is always reachable" (litmus
#         MEDIUM on PR #676 caught exactly that overclaim).
#
#         What it IS: a sanity bound on the two defaults against the only wall-clock
#         figure the repo actually documents — enough to catch an order-of-magnitude
#         mistake like COOLDOWN=900 (wrong by ~4x) or a zero-margin value like 240,
#         which is what the two live defects on this PR were. Closing the gap properly
#         means pacing in ROUNDS rather than wall-clock, or having the dispatcher
#         enforce a minimum wait-round duration; both are caller-side changes tracked
#         separately, not something this helper can assert from mtimes alone.
DEFAULT_MAX=$(grep -oE 'read_int_knob "\$\{PR_GRIND_CODEX_RETRIGGER_MAX:-\}" [0-9]+' "$RT" | grep -oE '[0-9]+$')
DEFAULT_COOLDOWN=$(grep -oE 'read_int_knob "\$\{PR_GRIND_CODEX_RETRIGGER_COOLDOWN:-\}" [0-9]+' "$RT" | grep -oE '[0-9]+$')
WAIT_BUDGET_WALLCLOCK=480   # ADR 0005 Context: `--max-wait 8` exhausts in ~8 min
# 80% of the budget — integer arithmetic, no bc dependency.
BUDGET_CEILING=$(( WAIT_BUDGET_WALLCLOCK * 8 / 10 ))
needed=$(( DEFAULT_COOLDOWN * (DEFAULT_MAX - 1) ))
if [ -n "$DEFAULT_MAX" ] && [ -n "$DEFAULT_COOLDOWN" ] && [ "$needed" -le "$BUDGET_CEILING" ]; then
  ok "wait-budget coupling: shipped defaults (MAX=$DEFAULT_MAX, COOLDOWN=$DEFAULT_COOLDOWN) need ${needed}s <= ${BUDGET_CEILING}s (80% of the ${WAIT_BUDGET_WALLCLOCK}s wait budget)"
else
  fail "wait-budget coupling: MAX=$DEFAULT_MAX COOLDOWN=$DEFAULT_COOLDOWN need ${needed}s > ${BUDGET_CEILING}s (80% of ${WAIT_BUDGET_WALLCLOCK}s) — the last attempt would land at or past the dispatcher's bail with no latency headroom; re-derive defaults against ADR 0005's --max-wait figure"
fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
