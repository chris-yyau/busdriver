#!/usr/bin/env bash
# Tests for the CLI retry layer added in front of the droid fallback.
#   Part A: _is_transient_cli_error() predicate (resolve-cli.sh)
#   Part B: _run_review_with_retries() — blueprint/litmus agy/grok path
#   Part C: dispatch.sh dispatch_one() retry loop — council path (PATH-stubbed)
#
# Retries fire on transient/empty failures, NEVER on timeout (124) or
# non-transient errors. All cases pin BUSDRIVER_CLI_RETRY_DELAY=0 so the suite
# stays fast.
#
# Usage: bash tests/test-cli-retry.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2015: A&&B||C is intentional pass/fail branching here.
# SC2312: $(cat "$counter") inside [[ ]] — masking cat's return is harmless (a
#         missing counter file correctly fails the assertion anyway).
# shellcheck disable=SC2015,SC2312
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0; TOTAL=0
ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); }
bad() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); }

# shellcheck disable=SC1091
source scripts/lib/resolve-cli.sh

TMP=$(mktemp -d) || { echo "mktemp -d failed"; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d produced no directory"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Part B invokes stubs by ABSOLUTE path → its dir ($BBIN) is NEVER put on PATH.
# Part C prepends $STUB to PATH, so $STUB must contain ONLY the CLIs under test
# (agy/droid) — a stub there named after a real util (e.g. `timeout`, which
# _portable_timeout invokes) would shadow it and break the dispatch subprocess.
BBIN="$TMP/b"; mkdir -p "$BBIN"
STUB="$TMP/bin"; mkdir -p "$STUB"

export BUSDRIVER_CLI_RETRY_DELAY=0   # no real sleeping in tests

# ── Part A: _is_transient_cli_error ─────────────────────────────────
echo "── _is_transient_cli_error ─────────────────────────────────"
printf 'Error: 503 service overloaded\n'        | _is_transient_cli_error && ok "503 → transient"            || bad "503 → transient"
printf 'rate limit exceeded\n'                   | _is_transient_cli_error && ok "rate limit → transient"     || bad "rate limit → transient"
printf 'ECONNRESET socket hang up\n'             | _is_transient_cli_error && ok "ECONNRESET → transient"     || bad "ECONNRESET → transient"
printf 'EAGAIN temporarily unavailable\n'        | _is_transient_cli_error && ok "EAGAIN → transient"         || bad "EAGAIN → transient"
printf 'SyntaxError: unexpected token at line 4' | _is_transient_cli_error && bad "syntax error → NOT transient" || ok "syntax error → NOT transient"
printf 'review complete: 0 issues'               | _is_transient_cli_error && bad "clean output → NOT transient" || ok "clean output → NOT transient"
# 5xx must be context-qualified: a bare 3-digit run with no HTTP/status context
# or reason phrase is NOT transient (guards "line 503"/"port 5000"/"1500 tokens"
# from being needlessly retried + droid-escalated as fake server errors).
printf '503 Service Unavailable\n'               | _is_transient_cli_error && ok "503 reason phrase → transient"     || bad "503 reason phrase → transient"
printf 'Request failed with status code 502\n'   | _is_transient_cli_error && ok "status code 502 → transient"        || bad "status code 502 → transient"
printf 'SyntaxError at line 503 of review.js\n'  | _is_transient_cli_error && bad "line 503 → NOT transient"          || ok "line 503 → NOT transient"
printf 'unable to bind on port 5000, exiting\n'  | _is_transient_cli_error && bad "port 5000 → NOT transient"         || ok "port 5000 → NOT transient"
printf 'prompt consumed 1500 tokens, aborting\n' | _is_transient_cli_error && bad "1500 tokens → NOT transient"       || ok "1500 tokens → NOT transient"
# HTTP 429 rate limiting (4xx) is transient too, via phrase or context-qualified code.
printf 'HTTP 429 Too Many Requests\n'             | _is_transient_cli_error && ok "429 too many requests → transient" || bad "429 too many requests → transient"
printf 'review flagged at line 429 of foo.js\n'   | _is_transient_cli_error && bad "line 429 → NOT transient"         || ok "line 429 → NOT transient"

# ── Part A2: _is_bare_transient_notice ──────────────────────────────
# Distinguishes a short clean-exit error notice (retry) from a real review that
# merely discusses rate limits / 5xx (accept). Guards the success/break path.
echo "── _is_bare_transient_notice ───────────────────────────────"
_is_bare_transient_notice 'ECONNRESET: socket hang up'                 && ok "bare network notice → bare"            || bad "bare network notice → bare"
_is_bare_transient_notice '503 Service Unavailable'                    && ok "bare 503 notice → bare"                || bad "bare 503 notice → bare"
_is_bare_transient_notice 'HTTP 429 Too Many Requests'                 && ok "bare 429 notice → bare"                || bad "bare 429 notice → bare"
# Short, non-JSON reviews that merely USE prose words ("capacity", "rate limit")
# must NOT be misread as bare notices — only HARD error tokens count.
_is_bare_transient_notice 'capacity handling looks correct'           && bad "short prose 'capacity' → NOT bare"    || ok "short prose 'capacity' → NOT bare"
_is_bare_transient_notice 'rate limit logic is fine'                  && bad "short prose 'rate limit' → NOT bare"  || ok "short prose 'rate limit' → NOT bare"
_is_bare_transient_notice '{"status":"FAIL","issues":[{"description":"handle the 503 / rate limit path"}]}' && bad "JSON review mentioning 5xx → NOT bare" || ok "JSON review mentioning 5xx → NOT bare"
# A genuine review (status+issues schema) may name a 5xx / reason phrase in a
# finding without being a notice — the schema exempts it regardless of wording.
_is_bare_transient_notice '{"status":"FAIL","issues":[{"description":"the bad gateway path lacks tests"}]}' && bad "review JSON naming a reason phrase → NOT bare" || ok "review JSON naming a reason phrase → NOT bare"
_is_bare_transient_notice '{"status":"FAIL","issues":[{"description":"HTTP 500 handler lacks tests"}]}'      && bad "review JSON naming HTTP 5xx → NOT bare"        || ok "review JSON naming HTTP 5xx → NOT bare"
# A bare reason-phrase notice (no schema) IS transient — in either word order.
_is_bare_transient_notice '502 Bad Gateway'                           && ok "bare 502 (code-first) → bare"          || bad "bare 502 (code-first) → bare"
_is_bare_transient_notice 'Bad Gateway (502)'                         && ok "bare Bad Gateway (phrase-first) → bare" || bad "bare Bad Gateway (phrase-first) → bare"
# Braces must NOT exempt a short error ENVELOPE — the hard token still wins.
_is_bare_transient_notice '{"error":"ECONNRESET: socket hang up"}'    && ok "JSON error envelope → bare"            || bad "JSON error envelope → bare"
_is_bare_transient_notice 'REVIEW_OK'                                  && bad "clean short output → NOT bare"        || ok "clean short output → NOT bare"
_long_review="$(printf 'The retry layer is overloaded with rate limit handling. %.0s' $(seq 1 20))"
_is_bare_transient_notice "$_long_review"                             && bad "long prose review → NOT bare"         || ok "long prose review → NOT bare"

# Helper: write a counter-based stub that fails $1 times (with message $2),
# then succeeds printing "REVIEW_OK". Counter persists in $3.
make_flaky() {
  local fails="$1" msg="$2" cnt="$3" path="$4" exitcode="${5:-1}"
  : > "$cnt"; printf '0' > "$cnt"
  cat > "$path" <<EOF
#!/usr/bin/env bash
n=\$(cat "$cnt" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$cnt"
if [ "\$n" -le "$fails" ]; then printf '%s\n' "$msg" >&2; exit $exitcode; fi
printf 'REVIEW_OK\n'
EOF
  chmod +x "$path"
}

# ── Part B: _run_review_with_retries ────────────────────────────────
echo ""
echo "── _run_review_with_retries (agy/grok path) ────────────────"

# B1: transient twice then success → retried, exit 0, 3 invocations
C="$TMP/b1"; make_flaky 2 "Error: 503 overloaded" "$C" "$BBIN/flaky"
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 "$BBIN/flaky" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *REVIEW_OK* && "$(cat "$C")" == 3 ]] \
  && ok "transient x2 → retried to success (3 invocations)" \
  || bad "transient x2 → retried to success (got rc=$rc inv=$(cat "$C"))"

# B2: non-transient error → NOT retried (1 invocation, exit 1)
C="$TMP/b2"; make_flaky 9 "SyntaxError: bad token" "$C" "$BBIN/hard"
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 "$BBIN/hard" 2>/dev/null); rc=$?
[[ "$rc" -ne 0 && "$(cat "$C")" == 1 ]] \
  && ok "non-transient → no retry (1 invocation)" \
  || bad "non-transient → no retry (got rc=$rc inv=$(cat "$C"))"

# B3: timeout (124) → NOT retried (1 invocation, exit 124)
C="$TMP/b3"; make_flaky 9 "irrelevant" "$C" "$BBIN/timeout" 124
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 "$BBIN/timeout" 2>/dev/null); rc=$?
[[ "$rc" -eq 124 && "$(cat "$C")" == 1 ]] \
  && ok "timeout(124) → no retry (1 invocation)" \
  || bad "timeout(124) → no retry (got rc=$rc inv=$(cat "$C"))"

# B4: retries exhausted (always transient-fail) with RETRIES=2 → 3 invocations
C="$TMP/b4"; make_flaky 9 "503 capacity" "$C" "$BBIN/always"
out=$(BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries agy p 5 "$BBIN/always" 2>/dev/null); rc=$?
[[ "$rc" -ne 0 && "$(cat "$C")" == 3 ]] \
  && ok "exhaustion → RETRIES=2 yields 3 invocations, final exit nonzero" \
  || bad "exhaustion → RETRIES=2 yields 3 invocations (got rc=$rc inv=$(cat "$C"))"

# B5: empty output on clean exit → retried
C="$TMP/b5"; : > "$C"; printf '0' > "$C"
cat > "$BBIN/empty" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
if [ "\$n" -le 1 ]; then exit 0; fi   # first attempt: clean exit, NO output
printf 'REVIEW_OK\n'
EOF
chmod +x "$BBIN/empty"
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 "$BBIN/empty" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *REVIEW_OK* && "$(cat "$C")" == 2 ]] \
  && ok "empty-on-clean-exit → retried" \
  || bad "empty-on-clean-exit → retried (got rc=$rc inv=$(cat "$C"))"

# B6: ALWAYS empty on clean exit → exhausts retries → returns NON-zero (an
#     empty review must not look like a clean success to the caller).
C="$TMP/b6"; printf '0' > "$C"
cat > "$BBIN/alwaysempty" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
exit 0   # clean exit, NEVER any output
EOF
chmod +x "$BBIN/alwaysempty"
out=$(BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries agy p 5 "$BBIN/alwaysempty" 2>/dev/null); rc=$?
inv=$(cat "$C")
[[ "$rc" -ne 0 && -z "$out" && "$inv" == 3 ]] \
  && ok "always-empty → exhausts (3 inv) and returns non-zero (not false success)" \
  || bad "always-empty → exhausts and returns non-zero (got rc=$rc inv=$inv out=[$out])"

# B7: NONZERO exit + empty output (non-transient text) → still retried, because
#     empty output is never a valid review regardless of exit code.
C="$TMP/b7"; printf '0' > "$C"
cat > "$BBIN/nzempty" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
exit 1   # nonzero, NO output, no transient marker in (absent) text
EOF
chmod +x "$BBIN/nzempty"
out=$(BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries agy p 5 "$BBIN/nzempty" 2>/dev/null); rc=$?
inv=$(cat "$C")
[[ "$rc" -ne 0 && "$inv" == 3 ]] \
  && ok "nonzero+empty (non-transient) → retried (3 inv), non-zero exit" \
  || bad "nonzero+empty → retried (got rc=$rc inv=$inv)"

# B8: wall-clock budget guard — a fast transient-failing CLI with RETRIES=5 but a
#     backoff that consumes the (short, 1s) timeout budget stops retrying well
#     before the retry count, so retries can't multiply the caller's timeout.
C="$TMP/b8"; make_flaky 99 "Error: 503 overloaded" "$C" "$BBIN/budget"
out=$(BUSDRIVER_CLI_RETRIES=5 BUSDRIVER_CLI_RETRY_DELAY=1 \
      _run_review_with_retries agy p 1 "$BBIN/budget" 2>/dev/null); rc=$?
inv=$(cat "$C")
# inv >= 1: the first attempt must ALWAYS run (never skipped by the budget guard);
# inv <= 3: retries are still bounded well below RETRIES=5 by the spent budget;
# rc != 124: budget exhaustion is a CLI failure, NOT a real timeout signal.
[[ "$rc" -ne 0 && "$rc" -ne 124 && "$inv" -ge 1 && "$inv" -le 3 ]] \
  && ok "budget guard → first ran, bounded retries, non-timeout exit ($inv inv, rc=$rc)" \
  || bad "budget guard → first-ran/bounded/non-124 (got inv=$inv rc=$rc)"

# B9: a valid --timeout 1 (1s) call MUST run its first (successful) attempt — the
#     boundary fix must not let a sub-second clock tick skip the only invocation.
C="$TMP/b9"; printf '0' > "$C"
cat > "$BBIN/ok1s" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
printf 'REVIEW_OK\n'
EOF
chmod +x "$BBIN/ok1s"
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 1 "$BBIN/ok1s" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *REVIEW_OK* && "$(cat "$C")" == 1 ]] \
  && ok "--timeout 1 → first attempt runs and succeeds (not skipped by budget guard)" \
  || bad "--timeout 1 first attempt runs (got rc=$rc inv=$(cat "$C"))"

# B10: exit-0 bare transient notice (CLI prints a network/5xx error but exits 0)
#      → NOT treated as success; retried, and exhaustion returns NON-zero so the
#      droid fallback can fire instead of a silent "success". Uses a HARD error
#      token (ECONNRESET) — prose words like "rate limit" alone do NOT qualify.
C="$TMP/b10"; printf '0' > "$C"
cat > "$BBIN/zerotrans" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
printf 'ECONNRESET: socket hang up\n'   # hard transient token on a CLEAN exit
exit 0
EOF
chmod +x "$BBIN/zerotrans"
out=$(BUSDRIVER_CLI_RETRIES=2 BUSDRIVER_CLI_RETRY_DELAY=0 _run_review_with_retries agy p 5 "$BBIN/zerotrans" 2>/dev/null); rc=$?
[[ "$rc" -ne 0 && "$(cat "$C")" == 3 ]] \
  && ok "exit-0 bare transient → retried (3 inv), exhaustion non-zero" \
  || bad "exit-0 bare transient → retried+nonzero (got rc=$rc inv=$(cat "$C"))"

# B11: a real review payload that exits 0 and merely DISCUSSES rate limits / 5xx
#      (carries a JSON object) is accepted on the first attempt — never retried.
C="$TMP/b11"; printf '0' > "$C"
cat > "$BBIN/jsonreview" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
printf '%s\n' '{"status":"FAIL","issues":[{"description":"handle the 503 rate limit path"}]}'
EOF
chmod +x "$BBIN/jsonreview"
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 "$BBIN/jsonreview" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *503* && "$(cat "$C")" == 1 ]] \
  && ok "exit-0 JSON review mentioning 5xx → success, no retry (1 inv)" \
  || bad "exit-0 JSON review → success no retry (got rc=$rc inv=$(cat "$C"))"

# ── Part C: dispatch.sh dispatch_one retry (council, PATH-stubbed) ───
echo ""
echo "── dispatch.sh dispatch_one retry ──────────────────────────"

# C1: agy transient twice then success → retried, succeeds, droid NOT called
C="$TMP/c1"; make_flaky 2 "Error: 503 overloaded" "$C" "$STUB/agy"
printf '#!/usr/bin/env bash\necho DROID_RESCUE\n' > "$STUB/droid"; chmod +x "$STUB/droid"
O="$TMP/c1.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=3 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null
rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q REVIEW_OK "$O" && ! grep -q DROID_RESCUE "$O"; } \
  && ok "council agy transient x2 → retried to success, no droid" \
  || bad "council agy transient x2 → retried to success (rc=$rc, out=$(tr -d '\n' <"$O"))"
[[ "$(cat "$C")" == 3 ]] && ok "council retry made 3 agy invocations" \
                         || bad "council retry made 3 agy invocations (got $(cat "$C"))"

# C2: RETRIES=0 disables retry → single failing attempt → droid fallback fires
C="$TMP/c2"; make_flaky 9 "Error: 503 overloaded" "$C" "$STUB/agy"
O="$TMP/c2.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null || true
{ [[ "$(cat "$C")" == 1 ]] && grep -q DROID_RESCUE "$O"; } \
  && ok "RETRIES=0 → one attempt then droid fallback" \
  || bad "RETRIES=0 → one attempt then droid fallback (inv=$(cat "$C"), out=$(tr -d '\n' <"$O"))"

# C3: timeout (124) → not retried, droid fallback fires
C="$TMP/c3"; make_flaky 9 "irrelevant" "$C" "$STUB/agy" 124
O="$TMP/c3.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=3 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null || true
{ [[ "$(cat "$C")" == 1 ]] && grep -q DROID_RESCUE "$O"; } \
  && ok "council timeout(124) → no retry, droid fallback" \
  || bad "council timeout(124) → no retry, droid fallback (inv=$(cat "$C"), out=$(tr -d '\n' <"$O"))"

# C4: always-empty agy + droid UNAVAILABLE (restricted PATH) → dispatch reports
#     failure, not a silent empty success.
C="$TMP/c4"; printf '0' > "$C"
rm -f "$STUB/droid"   # remove the droid stub so droid is genuinely unavailable
cat > "$STUB/agy" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
exit 0   # clean exit, NEVER any output
EOF
chmod +x "$STUB/agy"
O="$TMP/c4.out"
# PATH excludes the dirs holding the real droid (~/.local/bin) so droid is
# unavailable; keep /usr/bin:/bin for dispatch.sh's coreutils + perl timeout.
PATH="$STUB:/usr/bin:/bin" BUSDRIVER_CLI_RETRIES=2 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null
rc=$?
{ [[ "$rc" -ne 0 ]] && ! grep -q DROID_RESCUE "$O"; } \
  && ok "always-empty + no droid → reported failure (not silent empty success)" \
  || bad "always-empty + no droid → reported failure (rc=$rc, out=[$(tr -d '\n' <"$O")])"

# C5: --mode auto is WRITE-CAPABLE (codex --full-auto / agy --dangerously-skip-
#     permissions) → the WHOLE resilience layer is disabled: no retry (write
#     prompt invoked exactly once, never re-run) AND no read-only droid fallback
#     (which couldn't complete the write anyway) → the failure is returned honestly.
C="$TMP/c5"; make_flaky 9 "Error: 503 overloaded" "$C" "$STUB/agy"
printf '#!/usr/bin/env bash\necho DROID_RESCUE\n' > "$STUB/droid"; chmod +x "$STUB/droid"
O="$TMP/c5.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=3 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --mode auto --timeout 5 --prompt p >"$O" 2>/dev/null; rc=$?
{ [[ "$(cat "$C")" == 1 ]] && [[ "$rc" -ne 0 ]] && ! grep -q DROID_RESCUE "$O"; } \
  && ok "--mode auto → no retry + no droid fallback (failure returned honestly)" \
  || bad "--mode auto → no retry/no droid (inv=$(cat "$C") rc=$rc out=[$(tr -d '\n' <"$O")])"

# C6: NONZERO exit + empty output file (non-transient) → still retried in council
#     dispatch (empty output is never a valid response). RETRIES=2 → 3 invocations.
C="$TMP/c6"; printf '0' > "$C"
cat > "$STUB/agy" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
exit 1   # nonzero, NO output
EOF
chmod +x "$STUB/agy"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=2 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >/dev/null 2>&1 || true
[[ "$(cat "$C")" == 3 ]] \
  && ok "council nonzero+empty → retried (3 invocations)" \
  || bad "council nonzero+empty → retried (got $(cat "$C"))"

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
[[ "$FAIL" -gt 0 ]] && { echo "   $FAIL FAILED"; exit 1; }
echo "   All passed."
exit 0
