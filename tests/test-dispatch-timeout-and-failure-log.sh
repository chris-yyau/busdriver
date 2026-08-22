#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # assertions intentionally use command substitution
# shellcheck disable=SC2015  # `ok` always returns 0, so A && ok || bad is a real if-then-else here
# shellcheck disable=SC2016  # the static assertion greps for LITERAL source text; expansion is what must NOT happen
# shellcheck disable=SC2329  # cleanup() is invoked indirectly, via the EXIT trap
# tests/test-dispatch-timeout-and-failure-log.sh
#
# Two changes in skills/dispatch-cli/scripts/dispatch.sh:
#
#   1. The default --timeout is 600, raised from 300. The old default sat BELOW
#      the pi lane's median (measured in-tree traces: 315s and 307s), so pi's
#      successful runs were being killed by the cap and the lane looked flaky.
#   2. log_event archives a FAILED run's output into $LOG_DIR/failures/. Output
#      files live in $TMPDIR, which the OS reaps and a reboot wipes, so a
#      failure's only diagnostic routinely vanished before anyone read it.
#
# Every timeout assertion reads the pre-dispatch BANNER, so nothing here ever
# waits on a real timeout — the suite runs in seconds. The single deliberate
# exception is test 4g (issue #599): a genuine --timeout 1 with a sleeping
# stub, the only live exercise of the timeout→archive path. It waits exactly
# the 1s budget.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
DISPATCH="skills/dispatch-cli/scripts/dispatch.sh"
RUN_BASH="$BASH"   # see test-dispatch-skipped-status.sh — #595, bash 3.2 breaks the pi arm

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
case "$TMP" in
  /*) [[ -d "$TMP" ]] || { echo "FATAL: mktemp -d gave a non-directory" >&2; exit 1; } ;;
  *)  echo "FATAL: mktemp -d gave a non-absolute path: '$TMP'" >&2; exit 1 ;;
esac
STUB="$TMP/stub"; mkdir -p "$STUB"

# Isolate LOG_DIR. dispatch.sh builds it as "$HOME/$STATE_DIR/homunculus" and
# sanitizes STATE_DIR to a safe relative name, so a unique BUSDRIVER_STATE_DIR
# redirects the log away from the operator's real ~/.claude.
# The `dispatchtest-` prefix is load-bearing: cleanup below refuses to remove
# anything else, so a future edit that lets the sanitizer rewrite this to
# `.claude` can never turn the teardown into `rm -rf ~/.claude`.
TEST_STATE="dispatchtest-$$-${RANDOM}"
TEST_LOGROOT="$HOME/$TEST_STATE"
# ALIAS_ROOT is set later (test 4e) but declared/cleaned here so the EXIT trap
# covers it too: if the suite is interrupted (Ctrl-C/kill) after ALIAS_ROOT is
# created but before test 4e's own inline rm runs, the trap is the only thing
# that still removes it. `${ALIAS_ROOT:-}` guards the case against unset/unbound
# before test 4e assigns it (set -u is active).
ALIAS_ROOT=""
# Same reasoning as ALIAS_ROOT — test 4f creates this one, and an interrupted
# run would otherwise strand it in $HOME holding a failed run's output.
PIPE_ROOT=""
cleanup() {
  rm -rf "$TMP"
  case "$TEST_STATE" in
    dispatchtest-*) [[ -n "$TEST_LOGROOT" ]] && rm -rf "$TEST_LOGROOT" ;;
    *) echo "REFUSING to remove unexpected log root '$TEST_LOGROOT'" >&2 ;;
  esac
  case "${ALIAS_ROOT:-}" in
    "") ;;
    "$HOME"/dispatchtest-alias-*) rm -rf "$ALIAS_ROOT" ;;
    *) echo "REFUSING to remove unexpected alias root '$ALIAS_ROOT'" >&2 ;;
  esac
  case "${PIPE_ROOT:-}" in
    "") ;;
    "$HOME"/dispatchtest-pipe-*) rm -rf "$PIPE_ROOT" ;;
    *) echo "REFUSING to remove unexpected pipe root '$PIPE_ROOT'" >&2 ;;
  esac
}
trap cleanup EXIT

mk_codex_ok()   { printf '#!/usr/bin/env bash\necho CODEX_OK\n'                        > "$STUB/codex"; chmod +x "$STUB/codex"; }
mk_codex_fail() { printf '#!/usr/bin/env bash\necho "BOOM_DIAGNOSTIC"\nexit 3\n'       > "$STUB/codex"; chmod +x "$STUB/codex"; }
mk_codex_sleep(){ printf '#!/usr/bin/env bash\nsleep 60\n'                              > "$STUB/codex"; chmod +x "$STUB/codex"; }

BASE_PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"
banner() { PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" "$RUN_BASH" "$DISPATCH" "$@" 2>&1 | head -1; }

echo "── dispatch.sh timeout default + failure archiving ─────────"

# ── 1. The default is 600, not 300. This is the whole point of the change:
#      at 300 the pi lane killed its own successful 315s/307s runs.
mk_codex_ok
B="$(banner --cli codex --prompt p)"
[[ "$B" == *"600s timeout"* ]] \
  && ok "default timeout is 600s" \
  || bad "default timeout is not 600s (banner: $B)"

# ── 2. An explicit --timeout still wins. The operator override must not be
#      silently replaced by the new default.
B="$(banner --cli codex --timeout 20 --prompt p)"
[[ "$B" == *"20s timeout"* ]] \
  && ok "explicit --timeout overrides the default" \
  || bad "explicit --timeout was ignored (banner: $B)"

# ── 3. Validation still rejects a non-positive-integer value. Guards against a
#      future "default it when unset" edit that would let `--timeout ''` through.
B="$(banner --cli codex --timeout "" --prompt p)"
[[ "$B" == *"must be a positive integer"* ]] \
  && ok "--timeout '' is still rejected" \
  || bad "--timeout '' was accepted (banner: $B)"
B="$(banner --cli codex --timeout 0 --prompt p)"
[[ "$B" == *"must be a positive integer"* ]] \
  && ok "--timeout 0 is still rejected" \
  || bad "--timeout 0 was accepted (banner: $B)"

# ── 4. A FAILED run's output is archived somewhere durable. Without this, the
#      log records `error` and points at a $TMPDIR path that may already be gone
#      — which is exactly how the cause of a real 465s pi failure was lost.
mk_codex_fail
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 20 --prompt p >/dev/null 2>&1
FDIR="$TEST_LOGROOT/homunculus/failures"
if [[ -d "$FDIR" ]] && grep -rqs BOOM_DIAGNOSTIC "$FDIR"; then
  ok "a failed run's output is archived under \$LOG_DIR/failures"
else
  bad "failed run was not archived (looked in $FDIR)"
fi

# ── 4b. The archive must not be WORLD/GROUP READABLE. The original sits in a
#      per-user mode-700 $TMPDIR; copying it under $HOME at the caller's umask
#      (commonly 022) would downgrade protected model output — repo source, and
#      whatever a diagnostic quoted — to any local user who can traverse $HOME.
_perm_bad=""
if [[ -d "$FDIR" ]]; then
  # GNU stat's `-f` flag means "show filesystem status", not "custom format" —
  # `stat -f '%Lp' dir` on Linux SUCCEEDS (exit 0) but prints filesystem info
  # (device ID, block size, ...), not the file mode, so a BSD-first `||` chain
  # never falls through to the GNU form and this assertion fails on every
  # Linux CI run. Try the GNU form (`stat -c`) first — it errors loudly on
  # macOS (no `-c` flag there), correctly falling back to the BSD `stat -f`.
  _dmode=$(stat -c '%a' "$FDIR" 2>/dev/null || stat -f '%Lp' "$FDIR" 2>/dev/null || echo "")
  [[ "$_dmode" == "700" ]] || _perm_bad="dir=$_dmode"
  while IFS= read -r _f; do
    _fmode=$(stat -c '%a' "$_f" 2>/dev/null || stat -f '%Lp' "$_f" 2>/dev/null || echo "")
    [[ "$_fmode" == "600" ]] || _perm_bad="$_perm_bad file=$_fmode"
  done < <(find "$FDIR" -type f 2>/dev/null)
else
  _perm_bad="no archive dir"
fi
[[ -z "$_perm_bad" ]] \
  && ok "archive dir is 700 and archived files are 600" \
  || bad "archive permissions are too open ($_perm_bad)"

# ── 4c. The archive keeps the TAIL. A CLI appends its fatal error last, so a
#      head-based cap would preserve everything except the failure cause.
BIGSTUB="$STUB/codex"
{ printf '#!/usr/bin/env bash\n'
  printf 'for i in $(seq 1 4000); do printf "PADPADPADPADPADPADPADPADPADPADPADPADPADPADPADPADPAD_%%s\\n" "$i"; done\n'
  printf 'echo TAIL_ERROR_MARKER\n'
  printf 'exit 3\n'; } > "$BIGSTUB"
chmod +x "$BIGSTUB"
rm -rf "$TEST_LOGROOT"
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 20 --prompt p >/dev/null 2>&1
if grep -rqs TAIL_ERROR_MARKER "$TEST_LOGROOT/homunculus/failures"; then
  ok "an over-cap failure keeps the trailing error, not the leading padding"
else
  bad "the trailing error was truncated away — archive kept the head instead of the tail"
fi

# Rebuild the small failing stub for the log-pointer assertion below.
rm -rf "$TEST_LOGROOT"
mk_codex_fail
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 20 --prompt p >/dev/null 2>&1

# ── 4d. A symlink at the archive path must be UNLINKED, never written through.
#      `>` follows symlinks and this write TRUNCATES, so a link left behind in a
#      once-group-writable failures/ would redirect it onto an arbitrary file the
#      operator can write; `chmod 700` stops NEW entries but does not remove one
#      already there.
#
#      STATIC, deliberately. Staging this at runtime would require planting the
#      link at the exact destination basename BEFORE the write, and that name
#      embeds the dispatch process's own `$(date +%s)-$$` stamp — unknowable from
#      out here. A test that plants a link under some OTHER name and then asserts
#      the victim survived passes whether or not the guard exists, which is worse
#      than no test. So assert the guard chain itself is present and ordered.
grep -q 'rm -f "$_fdest"' "$DISPATCH" \
  && ok "the archive unlinks any existing entry before writing" \
  || bad "the pre-write unlink is gone — a planted symlink would be followed"
grep -q '\[\[ ! -e "$_fdest" && ! -L "$_fdest" \]\]' "$DISPATCH" \
  && ok "the archive re-checks the path is clear after unlinking" \
  || bad "the post-unlink re-check is gone — a re-planted entry would be written through"
grep -q '\[\[ ! -L "$_fdir" \]\]' "$DISPATCH" \
  && ok "a symlinked failures/ directory is refused" \
  || bad "failures/ symlink guard is gone — mkdir -p and chmod would follow it"
grep -q '\[\[ "$4" != "$_fdest" \]\]' "$DISPATCH" \
  && ok "source and destination being the same path is refused" \
  || bad "same-path guard is gone — the unlink would destroy the only diagnostic"
# A string compare misses aliases: `failures//x` vs `failures/x`, or a symlinked
# $TMPDIR. `-ef` compares device+inode and catches both. Without it the unlink
# destroys the only diagnostic — the exact inverse of what the archive is for.
grep -q '! \[\[ "${4%/\*}" -ef "$_fdir" \]\]' "$DISPATCH" \
  && ok "an aliased same-directory source is refused (device+inode, not string)" \
  || bad "the -ef same-file guard is gone — a trailing slash or symlinked TMPDIR would destroy the diagnostic"

# ── 4e. RUNTIME version of the same-file guard. Unlike the symlink case above,
#      this one IS stageable: point $TMPDIR at the failures directory itself
#      (with a trailing slash, so a string compare of the paths does NOT match)
#      and confirm the diagnostic survives. Without the `-ef` device+inode test
#      the unlink fires on the source and the archive destroys the only evidence
#      it exists to preserve.
ALIAS_STATE="dispatchtest-alias-$$-${RANDOM}"
ALIAS_ROOT="$HOME/$ALIAS_STATE"
mkdir -p "$ALIAS_ROOT/homunculus/failures"
printf '#!/usr/bin/env bash\necho ALIAS_DIAGNOSTIC\nexit 3\n' > "$STUB/codex"; chmod +x "$STUB/codex"
PATH="$BASE_PATH" TMPDIR="$ALIAS_ROOT/homunculus/failures/" BUSDRIVER_STATE_DIR="$ALIAS_STATE" \
  BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 20 --prompt p >/dev/null 2>&1
if grep -rqs ALIAS_DIAGNOSTIC "$ALIAS_ROOT/homunculus/failures"; then
  ok "an aliased TMPDIR does not destroy the diagnostic (runtime)"
else
  bad "the archive destroyed its own source when TMPDIR aliased failures/"
fi
case "$ALIAS_STATE" in
  dispatchtest-alias-*) rm -rf "$ALIAS_ROOT" ;;
  *) echo "REFUSING to remove unexpected alias root '$ALIAS_ROOT'" >&2 ;;
esac

# Restore the small failing stub for the log-pointer assertion below.
rm -rf "$TEST_LOGROOT"
mk_codex_fail
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 20 --prompt p >/dev/null 2>&1

# ── 4f. A consumer that exits early must not cost the run its audit trail.
#      `cat` dies on SIGPIPE as soon as `| head -1` closes the pipe, and it is
#      the last command of an `&&` list, so `set -e` takes the script down before
#      log_event runs — losing BOTH the log entry and the archive for a run that
#      had already completed. The output must exceed the pipe buffer (~64KB) or
#      `cat` finishes before the signal ever arrives and this passes vacuously.
PIPE_STATE="dispatchtest-pipe-$$-${RANDOM}"
PIPE_ROOT="$HOME/$PIPE_STATE"
{ printf '#!/usr/bin/env bash\n'
  printf 'for i in $(seq 1 40000); do printf "LINE_%%s_PADPADPADPADPADPADPADPADPADPADPADPADPADPAD\\n" "$i"; done\n'
  printf 'echo FATAL_TAIL\n'
  printf 'exit 3\n'; } > "$STUB/codex"
chmod +x "$STUB/codex"
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$PIPE_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 30 --prompt p 2>/dev/null | head -1 >/dev/null
if [[ -s "$PIPE_ROOT/homunculus/dispatch-log.jsonl" ]] \
   && [[ -n "$(find "$PIPE_ROOT/homunculus/failures" -type f 2>/dev/null)" ]]; then
  ok "an early-exiting consumer still leaves a log entry and an archive"
else
  bad "SIGPIPE killed the script before log_event — the failed run left no audit trail"
fi
# ── 4g. RUNTIME timeout (issue #599): a real short --timeout with a sleeping
#      CLI must be logged as status=timeout AND archived, with the log line
#      pointing at the durable failures/ copy. This is the one live exercise of
#      the timeout→archive path; every other assertion in this suite reads the
#      banner, so this is the deliberate single exception to "runs in seconds":
#      the wait is exactly the 1s budget, not a poll.
#      Calibration knob: --timeout 1 is the smallest legal value (0 and '' are
#      rejected in test 3), and the stub sleeps 60s — it cannot finish within
#      ANY budget the CLI accepts, so no platform timing tolerance is needed.
#      Ceiling: adds ~1s (plus dispatch startup, which precedes the timer).
rm -rf "$TEST_LOGROOT"
mk_codex_sleep
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 1 --prompt p >/dev/null 2>&1
LOGF="$TEST_LOGROOT/homunculus/dispatch-log.jsonl"
_TOUT_OUT=""
[[ -f "$LOGF" ]] && _TOUT_OUT="$(grep -o '"output_file":"[^"]*"' "$LOGF")"
_TOUT_OUT="${_TOUT_OUT#\"output_file\":\"}"
_TOUT_OUT="${_TOUT_OUT%\"}"
if [[ -f "$LOGF" ]] && grep -q '"status":"timeout"' "$LOGF" \
   && [[ "$_TOUT_OUT" == "$TEST_LOGROOT"/homunculus/failures/* ]] \
   && [[ -f "$_TOUT_OUT" ]]; then
  ok "runtime timeout is logged as status=timeout and archived ($_TOUT_OUT)"
else
  bad "runtime timeout was not logged/archived (log=$_TOUT_OUT)"
fi

# ── 5. ...and the log line POINTS at the durable copy, not at the $TMPDIR path
#      that may no longer exist. An archive nothing references is not a fix.
LOGF="$TEST_LOGROOT/homunculus/dispatch-log.jsonl"
if [[ -f "$LOGF" ]] && grep -q '"output_file":"[^"]*/failures/' "$LOGF"; then
  ok "the log entry points at the archived copy"
else
  bad "log entry still points at the volatile \$TMPDIR path"
fi

# ── 6. A SUCCESSFUL run is NOT archived — otherwise this grows without bound
#      and archives every dispatch the repo ever makes.
rm -rf "$TEST_LOGROOT"
mk_codex_ok
PATH="$BASE_PATH" BUSDRIVER_STATE_DIR="$TEST_STATE" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  "$RUN_BASH" "$DISPATCH" --cli codex --timeout 20 --prompt p >/dev/null 2>&1
if [[ -d "$TEST_LOGROOT/homunculus/failures" ]]; then
  bad "a successful run was archived — failures/ would grow without bound"
else
  ok "a successful run is not archived"
fi

# ── 7. Static: the archive is restricted to error/timeout. `skipped` (#594) is
#      deterministic — its reason is a fixed message this script wrote — so
#      archiving it would add noise without adding evidence.
grep -q 'if \[\[ "$2" == "error" || "$2" == "timeout" \]\] && \[\[ -f "$4" \]\]; then' "$DISPATCH" \
  && ok "archiving is gated to error/timeout only" \
  || bad "the archive gate changed shape — confirm skipped/success are still excluded"

echo ""
echo "── $PASS passed, $FAIL failed ──────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
