#!/usr/bin/env bash
# Tests for the review-CLI retry layer.
#   Part A: _is_transient_cli_error() predicate (resolve-cli.sh)
#   Part B: _run_review_with_retries() — blueprint/litmus agy/grok path
#   Part C: dispatch.sh dispatch_one() retry loop — council path (PATH-stubbed)
#   Part D: _portable_timeout perl arm — cancellation reaps the child group (#832)
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
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
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
# (agy) — a stub there named after a real util (e.g. `timeout`, which
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
# from being needlessly retried as fake server errors).
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
# Freeform council prose (no status/issues schema) that NAMES an HTTP/5xx code but
# carries review-assessment vocabulary is a verdict, not a notice — the schema
# exemption can't catch these, so _reads_as_review_prose must.
_is_bare_transient_notice 'HTTP 500 handler lacks tests'              && bad "prose 'HTTP 500 ... lacks tests' → NOT bare" || ok "prose 'HTTP 500 ... lacks tests' → NOT bare"
_is_bare_transient_notice 'the 503 retry path looks correct'         && bad "prose '503 ... looks correct' → NOT bare"    || ok "prose '503 ... looks correct' → NOT bare"
_is_bare_transient_notice 'HTTP 429 backoff needs a test'            && bad "prose 'HTTP 429 ... needs a test' → NOT bare" || ok "prose 'HTTP 429 ... needs a test' → NOT bare"
# Braces must NOT exempt a short error ENVELOPE — the hard token still wins.
_is_bare_transient_notice '{"error":"ECONNRESET: socket hang up"}'    && ok "JSON error envelope → bare"            || bad "JSON error envelope → bare"
_is_bare_transient_notice 'REVIEW_OK'                                  && bad "clean short output → NOT bare"        || ok "clean short output → NOT bare"
_long_review="$(printf 'The retry layer is overloaded with rate limit handling. %.0s' $(seq 1 20))"
_is_bare_transient_notice "$_long_review"                             && bad "long prose review → NOT bare"         || ok "long prose review → NOT bare"

# Helper: write a counter-based stub that fails $1 times (with message $2),
# then succeeds printing "REVIEW_OK". Counter persists in $3.
make_flaky() {
  local fails="$1" msg="$2" cnt="$3" path="$4" exitcode="${5:-1}"
  printf '0' > "$cnt"
  cat > "$path" <<EOF
#!/usr/bin/env bash
# A \`--version\` call is a CAPABILITY PROBE, not a review attempt: dispatch.sh
# and execute_review call \`agy --version\` once per process to decide whether
# this agy takes the prompt via argv (>=1.1) or as a path (1.0.x). Counting it
# would inflate every invocation assertion below by one and make the retry
# counts mean "attempts + 1", which is what they must NOT mean. Answer with a
# modern version and return WITHOUT touching the counter.
# Match \$1 EXACTLY — never a substring of the flattened \$*. On >=1.1 the prompt
# is delivered THROUGH argv, so a review prompt containing the text "--version"
# (e.g. this very test file, or any diff that mentions the flag) would otherwise
# be misread as a probe: the stub would exit 0 without counting, silently
# invalidating every retry assertion below.
if [ "\$1" = "--version" ]; then printf '1.1.4\n'; exit 0; fi
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
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 pipe "$BBIN/flaky" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *REVIEW_OK* && "$(cat "$C")" == 3 ]] \
  && ok "transient x2 → retried to success (3 invocations)" \
  || bad "transient x2 → retried to success (got rc=$rc inv=$(cat "$C"))"

# B2: non-transient error → NOT retried (1 invocation, exit 1)
C="$TMP/b2"; make_flaky 9 "SyntaxError: bad token" "$C" "$BBIN/hard"
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 pipe "$BBIN/hard" 2>/dev/null); rc=$?
[[ "$rc" -ne 0 && "$(cat "$C")" == 1 ]] \
  && ok "non-transient → no retry (1 invocation)" \
  || bad "non-transient → no retry (got rc=$rc inv=$(cat "$C"))"

# B3: timeout (124) → NOT retried (1 invocation, exit 124)
C="$TMP/b3"; make_flaky 9 "irrelevant" "$C" "$BBIN/timeout" 124
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 pipe "$BBIN/timeout" 2>/dev/null); rc=$?
[[ "$rc" -eq 124 && "$(cat "$C")" == 1 ]] \
  && ok "timeout(124) → no retry (1 invocation)" \
  || bad "timeout(124) → no retry (got rc=$rc inv=$(cat "$C"))"

# B4: retries exhausted (always transient-fail) with RETRIES=2 → 3 invocations
C="$TMP/b4"; make_flaky 9 "503 capacity" "$C" "$BBIN/always"
out=$(BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries agy p 5 pipe "$BBIN/always" 2>/dev/null); rc=$?
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
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 pipe "$BBIN/empty" 2>/dev/null); rc=$?
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
out=$(BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries agy p 5 pipe "$BBIN/alwaysempty" 2>/dev/null); rc=$?
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
out=$(BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries agy p 5 pipe "$BBIN/nzempty" 2>/dev/null); rc=$?
inv=$(cat "$C")
[[ "$rc" -ne 0 && "$inv" == 3 ]] \
  && ok "nonzero+empty (non-transient) → retried (3 inv), non-zero exit" \
  || bad "nonzero+empty → retried (got rc=$rc inv=$inv)"

# B8: wall-clock budget guard — a fast transient-failing CLI with RETRIES=5 but a
#     backoff that consumes the (short, 1s) timeout budget stops retrying well
#     before the retry count, so retries can't multiply the caller's timeout.
C="$TMP/b8"; make_flaky 99 "Error: 503 overloaded" "$C" "$BBIN/budget"
out=$(BUSDRIVER_CLI_RETRIES=5 BUSDRIVER_CLI_RETRY_DELAY=1 \
      _run_review_with_retries agy p 1 pipe "$BBIN/budget" 2>/dev/null); rc=$?
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
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 1 pipe "$BBIN/ok1s" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *REVIEW_OK* && "$(cat "$C")" == 1 ]] \
  && ok "--timeout 1 → first attempt runs and succeeds (not skipped by budget guard)" \
  || bad "--timeout 1 first attempt runs (got rc=$rc inv=$(cat "$C"))"

# B9b (#839): a TERM-ignoring CLI must not push the whole call past its budget.
#      The timeout wrapper waits a kill grace after TERM before KILL; unless that
#      grace comes out of the stamp, a 12s budget returns at ~17s. The lower bound
#      and the kill exit (124 perl arm, 137 coreutils -k) prove the fixture ran and
#      ignored TERM, so the grace was actually exercised.
_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
C="$TMP/b9b"; printf '0' > "$C"
cat > "$BBIN/termdeaf" <<EOF
#!/usr/bin/env bash
printf 1 > "$C"
trap '' TERM
exec sleep 30
EOF
chmod +x "$BBIN/termdeaf"
_t0=$(_ms)
out=$(BUSDRIVER_CLI_RETRIES=0 _run_review_with_retries agy p 12 pipe "$BBIN/termdeaf" 2>/dev/null); rc=$?
_dt=$(( $(_ms) - _t0 ))
[[ ( "$rc" -eq 124 || "$rc" -eq 137 ) && "$(cat "$C")" == 1 && "$_dt" -ge 11000 && "$_dt" -le 15000 ]] \
  && ok "TERM-ignoring CLI → killed within its 12s budget (${_dt}ms, rc=$rc)" \
  || bad "TERM-ignoring CLI → killed within its 12s budget (took ${_dt}ms, rc=$rc, started=$(cat "$C"))"

# B9c (#839): a larger budget never yields a shorter attempt. A CLI that needs
#      ~3s succeeds at 5s, so it must also succeed at 6s (a plain subtraction of
#      the 5s grace would stamp 1s and time it out).
cat > "$BBIN/slow3" <<'EOF'
#!/usr/bin/env bash
sleep 3
printf 'REVIEW_OK\n'
EOF
chmod +x "$BBIN/slow3"
for _b in 5 6; do
  out=$(BUSDRIVER_CLI_RETRIES=0 _run_review_with_retries agy p "$_b" pipe "$BBIN/slow3" 2>/dev/null); rc=$?
  [[ "$rc" -eq 0 && "$out" == *REVIEW_OK* ]] \
    && ok "3s CLI succeeds on a ${_b}s budget" \
    || bad "3s CLI succeeds on a ${_b}s budget (got rc=$rc)"
done

# B9d (#839): below 2x the grace the bound is partial by design, at most
#      2 x grace - budget late. Pin it: an 8s budget stamps 5s, so a TERM-ignoring
#      CLI returns by ~10s, never the unreserved 13s.
_t0=$(_ms)
out=$(BUSDRIVER_CLI_RETRIES=0 _run_review_with_retries agy p 8 pipe "$BBIN/termdeaf" 2>/dev/null); rc=$?
_dt=$(( $(_ms) - _t0 ))
[[ ( "$rc" -eq 124 || "$rc" -eq 137 ) && "$_dt" -le 11500 ]] \
  && ok "small budget → overshoot stays within the documented partial bound (${_dt}ms for 8s)" \
  || bad "small budget → overshoot stays within the documented partial bound (took ${_dt}ms for 8s, rc=$rc)"

# B10: exit-0 bare transient notice (CLI prints a network/5xx error but exits 0)
#      → NOT treated as success; retried, and exhaustion returns NON-zero so the
#      caller sees a failure instead of a silent "success". Uses a HARD error
#      token (ECONNRESET) — prose words like "rate limit" alone do NOT qualify.
C="$TMP/b10"; printf '0' > "$C"
cat > "$BBIN/zerotrans" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
printf 'ECONNRESET: socket hang up\n'   # hard transient token on a CLEAN exit
exit 0
EOF
chmod +x "$BBIN/zerotrans"
out=$(BUSDRIVER_CLI_RETRIES=2 BUSDRIVER_CLI_RETRY_DELAY=0 _run_review_with_retries agy p 5 pipe "$BBIN/zerotrans" 2>/dev/null); rc=$?
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
out=$(BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 pipe "$BBIN/jsonreview" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && "$out" == *503* && "$(cat "$C")" == 1 ]] \
  && ok "exit-0 JSON review mentioning 5xx → success, no retry (1 inv)" \
  || bad "exit-0 JSON review → success no retry (got rc=$rc inv=$(cat "$C"))"

# ── Part B2: stdin mode is an ARGUMENT, never inherited from the env ──
# A repo-controlled .claude/settings.json `env` block can set any variable
# (#325 / ADR 0016). When stdin mode was read from the environment, an injected
# `_RRWR_STDIN_MODE=none` handed /dev/null to EVERY retry-wrapped CLI — grok and
# agy 1.0.x then reviewed an EMPTY prompt, found nothing, and returned a vacuous
# PASS, silently defeating the review gate. Measured at the time: an 11-byte
# prompt arrived as STDIN_BYTES=0. Mode is now the 4th positional argument.
echo ""
echo "── stdin-mode injection resistance ─────────────────────────"
cat > "$BBIN/stdincount" <<'STUB'
#!/bin/sh
printf 'STDIN_BYTES=%s\n' "$(cat | wc -c | tr -d ' ')"
STUB
chmod +x "$BBIN/stdincount"

# pipe mode delivers the prompt (control)
out=$(_run_review_with_retries agy ELEVENCHARS 5 pipe "$BBIN/stdincount" 2>/dev/null)
[[ "$out" == *"STDIN_BYTES=11"* ]] \
  && ok "pipe mode delivers the prompt on stdin" \
  || bad "pipe mode delivers the prompt on stdin (got $out)"

# an INHERITED env value must NOT be able to starve a pipe-mode call
out=$(_RRWR_STDIN_MODE=none _run_review_with_retries agy ELEVENCHARS 5 pipe "$BBIN/stdincount" 2>/dev/null)
[[ "$out" == *"STDIN_BYTES=11"* ]] \
  && ok "inherited _RRWR_STDIN_MODE=none cannot starve a pipe-mode call" \
  || bad "inherited _RRWR_STDIN_MODE=none STARVED a pipe-mode call (got $out) — env-injection fail-open"

# an explicit `none` ARGUMENT does suppress stdin (the argv transport)
out=$(_run_review_with_retries agy ELEVENCHARS 5 none "$BBIN/stdincount" 2>/dev/null)
[[ "$out" == *"STDIN_BYTES=0"* ]] \
  && ok "explicit none argument suppresses stdin" \
  || bad "explicit none argument suppresses stdin (got $out)"

# an unknown mode falls back to pipe — degrade toward "reviewer sees the prompt"
out=$(_run_review_with_retries agy ELEVENCHARS 5 garbage "$BBIN/stdincount" 2>/dev/null)
[[ "$out" == *"STDIN_BYTES=11"* ]] \
  && ok "unknown stdin mode falls back to pipe (fail-safe direction)" \
  || bad "unknown stdin mode did not fall back to pipe (got $out)"

# B-refusal (#1141): `_portable_timeout --review` refusing to launch (status
# $_BD_PT_REFUSED) is terminal on the agy path — one attempt, exit 1 — even when the
# refusal text quotes a PATH component that matches the transient regex. The shim
# stands in for the launcher; tests/test-trusted-review-cli.sh covers the real one.
C="$TMP/bref"; printf '0' > "$C"
# shellcheck disable=SC2016  # shim source, eval'd in the subshell: expansion there is the point
refuse_shim='_portable_timeout() {
  n=$(cat "$C"); printf "%s" $((n+1)) > "$C"
  printf "%s\n" "busdriver: review PATH component resolves inside the reviewed checkout (/w/overloaded) — refusing timed dispatch." >&2
  _bd_exit_as "$_BD_PT_REFUSED"; }'
out=$(eval "$refuse_shim"; BUSDRIVER_CLI_RETRIES=3 _run_review_with_retries agy p 5 none-review /bin/true 2>&1); rc=$?
[[ "$rc" -eq 1 && "$(cat "$C")" == 1 && "$out" == *"refusing timed dispatch"* ]] \
  && ok "agy --review launcher refusal → terminal, exit 1 (1 invocation)" \
  || bad "agy --review launcher refusal → terminal (got rc=$rc inv=$(cat "$C") out=[$out])"
# ...and only the --review arms read that status: a non-review launch (grok) that
# ends with it is classified like any other failure (here: transient → retried).
printf '0' > "$C"
out=$(eval "$refuse_shim"; BUSDRIVER_CLI_RETRIES=2 _run_review_with_retries grok p 5 none-review /bin/true 2>&1); rc=$?
[[ "$(cat "$C")" == 3 ]] \
  && ok "non-review launch status $_BD_PT_REFUSED is not read as a refusal" \
  || bad "non-review launch status read as a refusal (got rc=$rc inv=$(cat "$C"))"

# ── Part C: dispatch.sh dispatch_one retry (council, PATH-stubbed) ───
echo ""
echo "── dispatch.sh dispatch_one retry ──────────────────────────"

# C1: agy transient twice then success → retried, succeeds
C="$TMP/c1"; make_flaky 2 "Error: 503 overloaded" "$C" "$STUB/agy"
O="$TMP/c1.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=3 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null
rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q REVIEW_OK "$O"; } \
  && ok "council agy transient x2 → retried to success" \
  || bad "council agy transient x2 → retried to success (rc=$rc, out=$(tr -d '\n' <"$O"))"
[[ "$(cat "$C")" == 3 ]] && ok "council retry made 3 agy invocations" \
                         || bad "council retry made 3 agy invocations (got $(cat "$C"))"

# C2: RETRIES=0 disables retry → single failing attempt
C="$TMP/c2"; make_flaky 9 "Error: 503 overloaded" "$C" "$STUB/agy"
O="$TMP/c2.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null; rc=$?
{ [[ "$(cat "$C")" == 1 ]] && [[ "$rc" -ne 0 ]]; } \
  && ok "RETRIES=0 → exactly one attempt, failure reported" \
  || bad "RETRIES=0 → exactly one attempt, failure reported (inv=$(cat "$C") rc=$rc, out=$(tr -d '\n' <"$O"))"

# C3: timeout (124) → not retried
C="$TMP/c3"; make_flaky 9 "irrelevant" "$C" "$STUB/agy" 124
O="$TMP/c3.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=3 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null; rc=$?
{ [[ "$(cat "$C")" == 1 ]] && [[ "$rc" -eq 124 ]]; } \
  && ok "council timeout(124) → no retry, failure reported" \
  || bad "council timeout(124) → no retry, failure reported (inv=$(cat "$C") rc=$rc, out=$(tr -d '\n' <"$O"))"

# C4: always-empty agy → dispatch reports failure, not a silent empty success.
C="$TMP/c4"; printf '0' > "$C"
cat > "$STUB/agy" <<EOF
#!/usr/bin/env bash
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
exit 0   # clean exit, NEVER any output
EOF
chmod +x "$STUB/agy"
O="$TMP/c4.out"
# Restricted PATH; keep /usr/bin:/bin for dispatch.sh's coreutils + perl timeout.
PATH="$STUB:/usr/bin:/bin" BUSDRIVER_CLI_RETRIES=2 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >"$O" 2>/dev/null
rc=$?
{ [[ "$rc" -ne 0 ]]; } \
  && ok "always-empty → reported failure (not silent empty success)" \
  || bad "always-empty → reported failure (rc=$rc, out=[$(tr -d '\n' <"$O")])"

# C5: --mode auto is WRITE-CAPABLE (codex --full-auto / agy --dangerously-skip-
#     permissions) → the WHOLE resilience layer is disabled: no retry (write
#     prompt invoked exactly once, never re-run) → the failure is returned honestly.
C="$TMP/c5"; make_flaky 9 "Error: 503 overloaded" "$C" "$STUB/agy"
O="$TMP/c5.out"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=3 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --mode auto --timeout 5 --prompt p >"$O" 2>/dev/null; rc=$?
{ [[ "$(cat "$C")" == 1 ]] && [[ "$rc" -ne 0 ]]; } \
  && ok "--mode auto → no retry (failure returned honestly)" \
  || bad "--mode auto → no retry (inv=$(cat "$C") rc=$rc out=[$(tr -d '\n' <"$O")])"

# C6: NONZERO exit + empty output file (non-transient) → still retried in council
#     dispatch (empty output is never a valid response). RETRIES=2 → 3 invocations.
C="$TMP/c6"; printf '0' > "$C"
cat > "$STUB/agy" <<EOF
#!/usr/bin/env bash
# --version is a capability probe, not a review attempt — see make_flaky.
# \$1-exact, never a \$* substring (the prompt travels in argv on >=1.1).
if [ "\$1" = "--version" ]; then printf '1.1.4\n'; exit 0; fi
n=\$(cat "$C" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$C"
exit 1   # nonzero, NO output
EOF
chmod +x "$STUB/agy"
PATH="$STUB:$PATH" BUSDRIVER_CLI_RETRIES=2 BUSDRIVER_CLI_RETRY_DELAY=0 \
  bash skills/dispatch-cli/scripts/dispatch.sh --cli agy --timeout 5 --prompt p >/dev/null 2>&1 || true
[[ "$(cat "$C")" == 3 ]] \
  && ok "council nonzero+empty → retried (3 invocations)" \
  || bad "council nonzero+empty → retried (got $(cat "$C"))"

# Part D (#832): the perl arm of _portable_timeout reaps its child group when the
#   wrapper itself is CANCELLED, not only on the alarm. The child calls setpgrp, so
#   perl is the only handle to it: signal perl by pid (as a caller can) and the
#   grandchild must be gone, with the 128+signo the default disposition would give.
#   Driven directly so it runs on hosts that pick the coreutils arm. Fixtures sleep at most
#   30s and are never KILLed by pid afterwards (the pid may be reused): a survivor is a FAIL,
#   and it exits on its own.
echo "Part D: perl timeout arm — cancellation reaps the child group (#832)"
# shellcheck disable=SC2016  # a literal pattern: the variable name is what is matched
[[ "$(grep -c '/usr/bin/perl -e "$_BD_PT_PERL_TO"' scripts/lib/resolve-cli.sh)" == 3 ]] \
  && ok "all three perl call sites run the shared body" \
  || bad "all three perl call sites run the shared body"
# A zombie is gone: it holds nothing, and an orphan's reaper may be slow to collect it.
# Checked by pid after the run, so a reused pid can only turn a pass into a FAIL, never the reverse.
_alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [[ -n "$st" && "$st" != Z* ]] && echo alive || echo gone; }
_gone_within() { local i; for (( i = 0; i < 30; i++ )); do [[ "$(_alive "$1")" == gone ]] && break; sleep 0.1; done; }
# The driver is the wrapper's parent and the only process that signals it. It holds the wrapper
# unreaped, so its pid cannot be reissued, and sends each signal only after waitpid(WNOHANG)
# shows the wrapper still running. Timing is its own monotonic clock. It has no handlers: the
# hang bound is a polled deadline, after which it KILLs and reaps the wrapper (rc=hang).
# Steps: file:F waits for F to be non-empty; stopped:F waits for the pid in F to be stopped;
# at:MS waits until MS after launch; alive:F records whether the pid in F still runs;
# by:MS voids the run if the next signal or check ends later than MS after launch; any
# other step is a signal for the wrapper. A run whose wrapper exited before every step ran,
# or that missed a by:, reports early=1 and does not count.
cat > "$TMP/drive.pl" <<'PL'
use strict; use warnings;
use POSIX qw(WNOHANG);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($out, $bound) = splice @ARGV, 0, 2;
my @steps; push @steps, shift @ARGV while @ARGV && $ARGV[0] ne '--'; shift @ARGV;
sub now { int(clock_gettime(CLOCK_MONOTONIC) * 1000) }
my $t0 = now(); my $deadline = $t0 + $bound * 1000;
my $p = fork; die "fork: $!" unless defined $p;
if (!$p) {
  open STDIN, '<', '/dev/null'; open STDOUT, '>', '/dev/null'; open STDERR, '>', '/dev/null';
  exec @ARGV or exit 127;
}
my ($status, $early, $sig_at, $by, $alive) = (undef, 0, 0, undef, '-');
sub done { return 1 if defined $status; return 0 unless waitpid($p, WNOHANG) == $p; $status = $?; 1 }
sub report {
  open my $fh, '>', $out or die "$out: $!";
  printf $fh "rc=%s early=%d sig_at=%d exit_at=%d alive=%s\n", $_[0], $early, $sig_at, now() - $t0, $alive;
  close $fh; exit 0;
}
sub hang { kill 'KILL', $p; waitpid $p, 0; report($_[0]) }
sub pid_in { open my $fh, '<', $_[0] or return; my $pid = <$fh> // ''; chomp $pid; $pid =~ /^\d+$/ ? $pid : undef }
sub stat_of { my $pid = pid_in($_[0]); defined $pid ? `ps -o stat= -p $pid 2>/dev/null` // '' : '' }
sub late { defined $by && now() - $t0 > $by }
STEP: for my $s (@steps) {
  if ($s =~ /^(file|stopped):(.+)$/) {
    my ($kind, $f) = ($1, $2);
    until ($kind eq 'file' ? -s $f : stat_of($f) =~ /^\s*T/) {
      if (done()) { $early = 1; last STEP }
      hang('noready') if now() > $deadline;
      select undef, undef, undef, 0.02;
    }
  } elsif ($s =~ /^by:(\d+)$/) {
    $by = $1;
  } elsif ($s =~ /^at:(\d+)$/) {
    my $at = $1;
    until (now() - $t0 >= $at) { if (done()) { $early = 1; last STEP } select undef, undef, undef, 0.02 }
  } elsif ($s =~ /^alive:(.+)$/) {
    my $st = stat_of($1); $alive = ($st =~ /\S/ && $st !~ /^\s*Z/) ? 1 : 0;
    if (done() || late()) { $early = 1; last STEP }
    $by = undef;
  } else {
    if (done() || late()) { $early = 1; last STEP }
    my $pre = now();
    kill $s, $p or die "kill $s: $!";
    $sig_at = $pre - $t0;
    if (late()) { $early = 1; last STEP }
    $by = undef;
  }
}
until (done()) { hang('hang') if now() > $deadline; select undef, undef, undef, 0.02 }
report($status & 127 ? 128 + ($status & 127) : $status >> 8);
PL
# _drive OUT BOUND STEP... -- CMD...: removes the _files fixtures write, then runs the driver, up
# to three times until a run counts. Sets _rc, _early, _alive_at (an alive: result), _exit_at
# (ms from launch to the wrapper's exit) and _el (from just before the last wrapper signal).
_drive() {
  local out=$1 i line; shift
  for (( i = 0; i < 3; i++ )); do
    rm -f "${_files[@]}" "$out"
    /usr/bin/perl "$TMP/drive.pl" "$out" "$@" || { _rc=driver; _early=0; _el=0; _exit_at=0; _alive_at=-; return; }
    line=$(cat "$out")
    _rc=${line#rc=}; _rc=${_rc%% *}
    _early=${line#*early=}; _early=${_early%% *}; _alive_at=${line#*alive=}
    local sa=${line#*sig_at=} ea=${line#*exit_at=}; sa=${sa%% *}; ea=${ea%% *}
    _el=$(( ea - sa )); _exit_at=$ea
    [[ "$_early" == 0 && "$_rc" != noready ]] && return
  done
}
for _sig in TERM:143 INT:130 HUP:129; do
  _s=${_sig%%:*}; _want=${_sig##*:}
  _pf="$TMP/cancel-$_s"; _files=("$_pf")
  # shellcheck disable=SC2016  # $! and $1 belong to the inner sh; the path travels as $1
  _drive "$TMP/out" 20 "file:$_pf" "$_s" -- \
    /usr/bin/perl -e "$_BD_PT_PERL_TO" 60 /bin/sh -c 'trap "" TERM; sleep 30 & echo $! > "$1"; wait' sh "$_pf"
  _gc=$(cat "$_pf" 2>/dev/null); [[ -n "$_gc" ]] && _gone_within "$_gc"
  [[ "$_early" == 0 && "$_rc" == "$_want" && -n "$_gc" && "$(_alive "$_gc")" == gone ]] \
    && ok "SIG$_s on perl → child group reaped, exit $_want" \
    || bad "SIG$_s on perl → child group reaped, exit $_want (got rc=$_rc early=$_early, grandchild '$_gc' $(_alive "${_gc:-0}"))"
done
# The alarm path through the same reap: a TERM-ignoring child is KILLed only after the 5s
# grace (1s alarm + grace, so at least 5s), exit 124, with no survivor in its group.
_pf="$TMP/alarm"; : > "$_pf"; _t0=$SECONDS
# shellcheck disable=SC2016  # $! and $1 belong to the inner sh; the path travels as $1
/usr/bin/perl -e "$_BD_PT_PERL_TO" 1 /bin/sh -c 'trap "" TERM; sleep 30 & echo $! > "$1"; wait' sh "$_pf" >/dev/null 2>&1
_rc=$?; _el=$(( SECONDS - _t0 )); _gc=$(cat "$_pf" 2>/dev/null)
[[ -n "$_gc" ]] && _gone_within "$_gc"
[[ "$_rc" -eq 124 && -n "$_gc" && "$(_alive "$_gc")" == gone && "$_el" -ge 5 && "$_el" -lt 15 ]] \
  && ok "alarm → TERM-ignoring child group KILLed after the grace, exit 124 (${_el}s)" \
  || bad "alarm → group KILLed, exit 124 (got rc=$_rc, ${_el}s, grandchild '${_gc}' $(_alive "${_gc:-0}"))"
# The normal path still passes the child's own status through: an exit code as is, a
# signal death as 128+signo.
/usr/bin/perl -e "$_BD_PT_PERL_TO" 10 /bin/sh -c 'exit 3' >/dev/null 2>&1; _rc=$?
[[ "$_rc" -eq 3 ]] && ok "normal exit status passes through (3)" || bad "normal exit status passes through (got $_rc)"
# shellcheck disable=SC2016  # $$ belongs to the inner sh
/usr/bin/perl -e "$_BD_PT_PERL_TO" 10 /bin/sh -c 'kill -KILL $$' >/dev/null 2>&1; _rc=$?
[[ "$_rc" -eq 137 ]] && ok "signal death passes through as 128+signo (137)" || bad "signal death passes through as 137 (got $_rc)"
# A stop and continue must not count as the exit (a CHLD is only a hint): the child stops
# itself, and a helper in its group continues it once it sees the stop. The child cannot
# exit while stopped, and whatever kills it (the group KILL, an orphaned group's HUP) kills
# the helper in the same delivery, so the helper only ever signals its live parent. The
# child's own status 7 must come back.
_pf="$TMP/stopcont"; _files=("$_pf")
cat > "$TMP/stopcont.sh" <<'SH'
me=$$; echo "$me" > "$1"
( i=0
  until [ "$(ps -o stat= -p "$me" 2>/dev/null | cut -c1)" = T ]; do
    i=$((i + 1)); [ "$i" -gt 200 ] && exit 1; sleep 0.05
  done
  kill -CONT "$me" ) &
kill -STOP "$me"
exit 7
SH
_drive "$TMP/out" 25 "file:$_pf" -- /usr/bin/perl -e "$_BD_PT_PERL_TO" 15 /bin/sh "$TMP/stopcont.sh" "$_pf"
[[ "$_early" == 0 && "$_rc" == 7 ]] && ok "a stop and continue does not end the wait (child status 7)" \
  || bad "a stop and continue does not end the wait (rc=$_rc early=$_early)"
# A lone child that exits on TERM: where kill 0 does not count the unreaped zombie (macOS)
# the grace ends at once; where it does (Linux) the grace runs out, and never past ~5s.
_pf="$TMP/lone"; _files=("$_pf")
# shellcheck disable=SC2016  # $$ and $1 belong to the inner sh
_drive "$TMP/out" 20 "file:$_pf" TERM -- \
  /usr/bin/perl -e "$_BD_PT_PERL_TO" 60 /bin/sh -c 'echo $$ > "$1"; exec sleep 30' sh "$_pf"
_sh=$(cat "$_pf" 2>/dev/null); [[ -n "$_sh" ]] && _gone_within "$_sh"
if [[ "$(uname -s)" == Darwin ]]; then _cap=2500; else _cap=7000; fi
[[ "$_early" == 0 && -n "$_sh" && "$(_alive "$_sh")" == gone && "$_rc" == 143 && "$_el" -lt "$_cap" ]] \
  && ok "a child exiting on TERM ends the grace in time (${_el}ms < ${_cap}ms)" \
  || bad "a child exiting on TERM ends the grace in time (child '$_sh', rc=$_rc early=$_early after ${_el}ms, cap ${_cap}ms)"
# A descendant that HANDLES TERM keeps the grace after the direct child has exited: the
# shell dies on TERM at once, the subshell takes ~2s to clean up and records that it finished.
# The subshell reports ready only once its trap is in place.
_done="$TMP/grace-done"; _rdy="$TMP/grace-ready"; _files=("$_done" "$_rdy")
cat > "$TMP/graceful.sh" <<'SH'
( trap 'sleep 2; echo done > "$1"; exit 0' TERM; echo ready > "$2"; i=0; while [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done ) &
wait
SH
_drive "$TMP/out" 20 "file:$_rdy" TERM -- \
  /usr/bin/perl -e "$_BD_PT_PERL_TO" 60 /bin/sh "$TMP/graceful.sh" "$_done" "$_rdy"
[[ "$_early" == 0 && "$_rc" == 143 && -s "$_done" ]] \
  && ok "descendant handling TERM finishes its cleanup inside the grace (exit 143)" \
  || bad "descendant handling TERM finishes its cleanup (got rc=$_rc early=$_early, finished=$([[ -s "$_done" ]] && echo y || echo n))"
# A stopped child must not make the wrapper uncancellable: a stop is not the exit, so perl
# stays in its signal wait and a TERM still reaps the (stopped) group. The fixture stops
# itself; the driver sends the TERM once it sees the stop, and its bound turns a hang into a FAIL.
_pf="$TMP/stopped"; _files=("$_pf")
# shellcheck disable=SC2016  # $$ and $1 belong to the inner sh
_drive "$TMP/out" 15 "stopped:$_pf" TERM -- \
  /usr/bin/perl -e "$_BD_PT_PERL_TO" 60 /bin/sh -c 'echo $$ > "$1"; kill -STOP $$; sleep 30' sh "$_pf"
_sh=$(cat "$_pf" 2>/dev/null); [[ -n "$_sh" ]] && _gone_within "$_sh"
[[ "$_early" == 0 && "$_rc" == 143 && -n "$_sh" && "$(_alive "$_sh")" == gone ]] \
  && ok "cancel while the child is stopped → reaped, exit 143" \
  || bad "cancel while the child is stopped → reaped, 143 (rc=$_rc early=$_early child '$_sh' $(_alive "${_sh:-0}"))"
# A SIGCHLD that is not the child's exit must not end the wait: the 3s deadline still decides.
# The wrapper starts after the driver's launch, so its alarm cannot fire before 3000ms on the
# driver's clock. The driver sends the CHLD within 1000ms and then checks, between 2800ms and
# 2990ms, that the child (which dies on TERM) is still running: a cleanup the CHLD started
# would have ended it (on Linux it stays a zombie until the grace runs out). A run that misses
# either window does not count. The wrapper must then be done by 10s (3s alarm, 5s grace).
_pf="$TMP/stray"; _files=("$_pf")
cat > "$TMP/stray.sh" <<'SH'
echo $$ > "$1"
i=0; while [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
SH
_drive "$TMP/out" 20 "file:$_pf" by:1000 CHLD at:2800 by:2990 "alive:$_pf" -- \
  /usr/bin/perl -e "$_BD_PT_PERL_TO" 3 /bin/sh "$TMP/stray.sh" "$_pf"
[[ "$_early" == 0 && "$_alive_at" == 1 && "$_rc" == 124 && "$_exit_at" -lt 10000 ]] \
  && ok "a stray SIGCHLD does not end the wait: the child runs on and the deadline fires (124, ${_exit_at}ms)" \
  || bad "a stray SIGCHLD does not end the wait (rc=$_rc early=$_early child running at 2.8s=$_alive_at, done at ${_exit_at}ms)"
# Run under both perl signal modes: the handlers must hold whatever PERL_SIGNALS a caller exports.
for _psig in "" unsafe; do
# A deadline arriving inside a cancellation's grace must not turn it into a timeout (124). The
# driver TERMs the wrapper once the TERM-ignoring subshell is ready, waits for the fixture to
# record the group TERM (so the wrapper is in its grace), then sends the ALRM.
_pf="$TMP/cancel-alrm"; _tm="$TMP/cancel-alrm-term"; _rdy="$TMP/cancel-alrm-ready"
_files=("$_pf" "$_tm" "$_rdy")
cat > "$TMP/termlogger.sh" <<'SH'
trap 'echo term > "$2"' TERM
( trap '' TERM; echo ready > "$3"; i=0; while [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done ) &
echo "$!" > "$1"
wait; wait
SH
_drive "$TMP/out" 20 "file:$_rdy" TERM "file:$_tm" ALRM -- \
  env -u PERL_SIGNALS ${_psig:+PERL_SIGNALS=$_psig} /usr/bin/perl -e "$_BD_PT_PERL_TO" 60 /bin/sh "$TMP/termlogger.sh" "$_pf" "$_tm" "$_rdy"
_gc=$(cat "$_pf" 2>/dev/null); [[ -n "$_gc" ]] && _gone_within "$_gc"
[[ "$_early" == 0 && "$_rc" == 143 && -n "$_gc" && "$(_alive "$_gc")" == gone ]] \
  && ok "[PERL_SIGNALS=${_psig:-default}] ALRM inside a cancellation grace → still a cancellation (143), group reaped" \
  || bad "[PERL_SIGNALS=${_psig:-default}] ALRM inside a cancellation grace → 143, group reaped (rc=$_rc early=$_early grandchild '$_gc' $(_alive "${_gc:-0}"))"
done

echo ""
echo "── Results: $PASS/$TOTAL passed ────────────────────────────"
[[ "$FAIL" -gt 0 ]] && { echo "   $FAIL FAILED"; exit 1; }
echo "   All passed."
exit 0
