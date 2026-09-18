#!/usr/bin/env bash
# tests/test-ack-ledger-typesafe-union.sh — the TypeSafe/Jev union classifier in
# scripts/ack-ledger.sh.
#
# NO NETWORK. `curl` is shadowed by a stub on PATH whose canned response each case
# controls, so this pins the COMPOSITION (opt-in resolution, union direction,
# failure terminal) and never the model's judgment. Model calibration lives in
# scripts/typesafe-ack-eval.sh, which makes real calls and is not run by CI.
#
# The four properties that must not regress, in the order they matter:
#   1. OFF is today's behaviour — no config, no call, the regex answer stands.
#   2. The union only ADDS demotes. A high noul demotes a description the regex
#      acked; it can never lift a demote the regex found.
#   3. ON + broken transport DEMOTES (fail-closed), mirroring `grep rc>=2`.
#   4. Consent is authenticated by LOCATION. A repo-local .claude/busdriver.json
#      cannot turn the lane on, and no env spelling turns it on either.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACK_SCRIPT="$SCRIPT_DIR/scripts/ack-ledger.sh"
passed=0; failed=0

if [[ ! -f "$ACK_SCRIPT" ]]; then
  echo "FAIL: ack-ledger.sh missing at $ACK_SCRIPT"; exit 1
fi

# check <expected> <actual> <label> — one form for every case. `if`, not
# `[[ ]] && ok || fail`: that idiom runs the failure arm whenever the success arm
# reports non-zero, which is how a passing test quietly becomes a failing one.
check() {
  if [[ "$2" == "$1" ]]; then
    echo "OK:   $3"; passed=$((passed + 1))
  else
    echo "FAIL: $3 — expected '$1', got '$2'"; failed=$((failed + 1))
  fi
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Same env contract as tests/test-ack-ledger-status-description.sh. These shapes
# are load-bearing — a missing pageInfo or the wrong comment envelope makes every
# case demote, which reads as a working harness and is not one.
HEAD_SHA="abc12345"
HEAD_FULL_SHA="abc1234500000000000000000000000000000000"
EMPTY_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
EMPTY_CHECK_RUNS='{"check_runs":[]}'
EMPTY_REACTIONS='[]'
WALKTHROUGH_COMMENT='{"comments":[{"author":{"login":"coderabbitai[bot]"},"createdAt":"2026-01-01T00:00:00Z","body":"## Walkthrough\nThe post-merge hook now uses GitHub PR state to confirm merges."}]}'
PRIOR_REVIEW='[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"oldcommit","body":"Please qualify this by the API result."}]'

# A description the REGEX acks — it is one of the three documented under-block
# residuals, i.e. exactly the case this lane exists for. Any demote below
# therefore came from the union and never from the regex.
REGEX_ACKS='The scheduled nightly review started, failed to complete'
# A description the REGEX demotes. Used to prove the union never lifts.
REGEX_DEMOTES='Review rate limited'

mk_status() {
  jq -nc --arg d "$1" \
    '[{context:"CodeRabbit",state:"success",description:$d,target_url:null,created_at:"2026-01-01T00:01:00Z",id:2}]'
}

# write_curl_stub <mode> — a noul value, or "http-fail" / "garbage" /
# "http-error" (500) / "redirect" (302).
write_curl_stub() {
  mkdir -p "$TMP/bin"
  # exit_if names a flag whose PRESENCE makes the stub fail. That is how a flag
  # is pinned rather than a failure path: the assertion reads "demote", which can
  # only happen if the flag reached curl.
  local body code exit_if='' leak_guard=''
  case "$1" in
    http-fail)
      printf '#!/bin/sh\nexit 7\n' > "$TMP/bin/curl"
      chmod +x "$TMP/bin/curl"
      return 0 ;;
    garbage)
      body='<html>502</html>'; code=200 ;;
    http-error)
      # A 5xx CARRYING a parseable low-noul body. The stub branches on whether
      # `--fail` was passed, so this pins the FLAG rather than merely the failure
      # path: without it the ledger reads 0.01 out of an error envelope.
      body='{"answers":{"review_did_not_run":{"type":"noul","noul":0.01}}}'
      code=500; exit_if='--fail' ;;
    no-config)
      # Pins `-q`. Without it curl reads a `.curlrc` — and `CURL_HOME=.` points
      # that at the checkout — so a committed config can add a second
      # destination that receives the Authorization header and the body. The
      # stub cannot simulate that leak; it asserts the flag that prevents it.
      body='{"answers":{"review_did_not_run":{"type":"noul","noul":0.01}}}'
      code=200; exit_if='-q' ;;
    multidoc)
      # A 200 whose body is a CONCATENATION: an empty object followed by a valid
      # low-noul answer. Streaming jq discards the first and emits the second, so
      # the ledger would act on an answer it never asked one request for.
      body='{} {"answers":{"review_did_not_run":{"type":"noul","noul":0.01}}}'
      code=200 ;;
    multidoc-two-answers)
      # Two VALID documents. Streaming jq emits TWO newline-separated numbers;
      # the awk comparison cannot evaluate that, and treating its error as
      # "below threshold" was an ack.
      body='{"answers":{"review_did_not_run":{"type":"noul","noul":0.99}}} {"answers":{"review_did_not_run":{"type":"noul","noul":0.01}}}'
      code=200 ;;
    redirect)
      # A 3xx with the same body. `--fail` does NOT cover this range and curl
      # exits 0 with the body on stdout, so only an explicit status check
      # demotes it — the gap a `--fail`-only round left open.
      body='{"answers":{"review_did_not_run":{"type":"noul","noul":0.01}}}'
      code=302 ;;
    leak-check)
      # Answers normally UNLESS a proxy/CA variable reached it. Those are the
      # channels `env -i` exists to cut: a leak turns an ack into a demote.
      body='{"answers":{"review_did_not_run":{"type":"noul","noul":0.01}}}'
      code=200; leak_guard=1 ;;
    *)
      body="{\"answers\":{\"review_did_not_run\":{\"type\":\"noul\",\"noul\":$1}}}"
      code=200 ;;
  esac
  # Every stub emits the body and then the status on a LAST line, because the
  # caller asks for it with -w '\n%{http_code}'.
  {
    printf '#!/bin/sh\n'
    if [[ -n "$exit_if" ]]; then
      # shellcheck disable=SC2016  # literal on purpose: "$@" must reach the
      # GENERATED stub and be expanded when the stub runs, not here.
      printf 'for a in "$@"; do [ "$a" = "%s" ] && exit 22; done\n' "$exit_if"
    fi
    if [[ -n "$leak_guard" ]]; then
      # shellcheck disable=SC2016  # the GENERATED stub reads its own env, not ours.
      printf '[ -n "${https_proxy:-}" ] && exit 23\n'
      # shellcheck disable=SC2016
      printf '[ -n "${CURL_CA_BUNDLE:-}" ] && exit 23\n'
    fi
    printf "printf '%%s\\\\n%%s' '%s' '%s'\n" "$body" "$code"
  } > "$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
}

# write_home_config none | <enabled> [threshold] | default-threshold
write_home_config() {
  mkdir -p "$TMP/home/.claude"
  case "$1" in
    none)              rm -f "$TMP/home/.claude/busdriver.json" ;;
    default-threshold) jq -nc '{typesafe:{ack_ledger:{enabled:true}}}' \
                         > "$TMP/home/.claude/busdriver.json" ;;
    *)                 jq -nc --argjson e "$1" --argjson t "${2:-0.9}" \
                         '{typesafe:{ack_ledger:{enabled:$e,threshold:$t}}}' \
                         > "$TMP/home/.claude/busdriver.json" ;;
  esac
}

run_ledger() {  # $1 = description; env supplied by the caller's prefix
  ALL_STATUSES="$(mk_status "$1")" \
  FETCH_OK=1 ALL_THREADS="$EMPTY_THREADS" ALL_REVIEWS="$PRIOR_REVIEW" \
  ALL_COMMENTS="$WALKTHROUGH_COMMENT" ALL_CHECK_RUNS="$EMPTY_CHECK_RUNS" \
  ALL_REACTIONS="$EMPTY_REACTIONS" \
  HEAD_SHA="$HEAD_SHA" HEAD_FULL_SHA="$HEAD_FULL_SHA" \
  HEAD_COMMITTED_DATE="" HEAD_PUSH_DATE="" HEAD_CHECKS_DATE="" \
  bash "$ACK_SCRIPT" coderabbitai 2>/dev/null || echo ERR
}

# Lane-ON cases drive the classifier as a FUNCTION rather than through the whole
# ledger, because production resolves the operator's home from the PASSWORD
# DATABASE. An inherited $HOME is repo-injectable — that is the entire point of
# the check — so no test can hand the script a fake home from outside the
# process. It sources the script instead (the source guard stops it before the
# ledger's main body) and overrides that one resolver in-process. The end-to-end
# baseline above and the two injection pins below still run the real ledger.
# Echoes demote|ack; TS_HOME overrides the resolved home.
run_union() {  # $1 = description; env supplied by the caller's prefix
  bash -c '
    BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1
    . "$1" || exit 3
    _ts_home="$2"   # captured: inside the function, $2 is the FUNCTION arg
    _typesafe_home() { _TYPESAFE_HOME="$_ts_home"; [[ -n "$_TYPESAFE_HOME" ]]; }
    if _noul_says_non_review "$3"; then echo demote; else echo ack; fi
  ' _ "$ACK_SCRIPT" "${TS_HOME:-$TMP/home}" "$1"
}

# Runs one snippet against the REAL _typesafe_home (no override, unlike
# run_union) and echoes _TYPESAFE_HOME_RESOLVED afterwards. That flag is the only
# externally visible trace of whether the password-DB lookup ran, and of whether
# its memo survived — a caller that wraps the lookup in a command substitution
# gets the work done in a subshell and leaves the flag at 0 in the parent.
probe_home_state() {  # $1 = snippet run after sourcing
  bash -c '
    BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1
    . "$1" || exit 3
    eval "$2"
    printf "%s\n" "$_TYPESAFE_HOME_RESOLVED"
  ' _ "$ACK_SCRIPT" "$1"
}

# --- baseline: prove BOTH outcomes are reachable before testing the union -----
write_home_config none
check "$HEAD_SHA" "$(HOME="$TMP/home" TYPESAFE_API_KEY="" run_ledger "$REGEX_ACKS")" \
  "baseline: the regex acks the under-block residual"
check stale "$(HOME="$TMP/home" TYPESAFE_API_KEY="" run_ledger "$REGEX_DEMOTES")" \
  "baseline: the regex demotes 'Review rate limited'"

# --- 1. OFF is today's behaviour ---------------------------------------------
# Each case below arms a stub that WOULD demote if it were ever consulted.
write_curl_stub 0.99

write_home_config none
check ack "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "no operator config => lane off, regex ack stands"

write_home_config false
check ack "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled:false => lane off"

# A missing key is "not configured", NOT a failed check: it must not demote, or
# every repo that never opted in would start stalling the moment this shipped.
write_home_config true
check ack "$(TYPESAFE_API_KEY="" PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled but no API key => off, not a demote"

# --- 2. the union ADDS demotes, and only adds --------------------------------
write_home_config true 0.9

write_curl_stub 0.94
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "union: noul 0.94 >= 0.9 demotes a description the regex acked"

write_curl_stub 0.40
check ack "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "union: noul 0.40 < 0.9 leaves the regex ack alone"

write_curl_stub 0.9
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "union: noul exactly at threshold demotes (>= is inclusive)"

# The direction that must never exist. End-to-end on purpose, unlike its
# neighbours: this pins a property of the COMPOSITION, not of the classifier.
# _noul_says_non_review is reached only after the regex has already acked, so
# calling it directly with a description the regex DEMOTES would assert nothing
# at all. The whole ledger is what shows the demote survives.
write_curl_stub 0.01
check stale "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_ledger "$REGEX_DEMOTES")" \
  "union never lifts: noul 0.01 leaves the regex demote in place"

# --- 3. enabled + broken transport fails CLOSED ------------------------------
write_curl_stub http-fail
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + curl failure => demote (fail-closed)"

write_curl_stub garbage
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + unparseable body => demote (fail-closed)"

# A non-200 whose body WOULD parse. Asserting `stale` proves `--fail` reached
# curl: without it the stub returns noul 0.01, which is below every threshold and
# would leave the ack standing.
write_curl_stub http-error
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + HTTP 500 carrying a parseable low noul => demote (--fail is passed)"

# The 3xx case `--fail` does NOT cover. curl exits 0 and hands over the body, so
# only the explicit %{http_code} == 200 test can demote this one.
write_curl_stub redirect
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + HTTP 302 carrying a parseable low noul => demote (status is checked, not just --fail)"

# A 200 whose body holds MORE THAN ONE JSON document. Both shapes were acks
# before --slurp + the three-way awk status: the first because streaming jq
# discards the junk document and emits the real one, the second because two
# numbers make awk error and the error was read as "below threshold".
write_curl_stub multidoc
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + body with {} then a valid answer => demote (exactly one document)"
write_curl_stub multidoc-two-answers
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + body with two valid answers => demote (unevaluable comparison is not an ack)"

# `-q` must reach curl. Without it a checkout's .curlrc — reachable through a
# repo-injectable CURL_HOME — can add a destination that receives the
# Authorization header and the request body, before any check in this function
# runs. The stub fails when it sees -q, so only a demote proves the flag is there.
write_curl_stub no-config
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "curl is invoked with -q (config files disabled — no .curlrc destination injection)"

# A probability outside [0,1] is a malformed judgment, not a low score. Both
# values compare FALSE against any threshold in (0,1], so a type-only check
# would have silently preserved the ack.
write_curl_stub -1
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + negative noul => demote (range-checked, not just typed)"
write_curl_stub 5
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "enabled + noul above 1 => demote (range-checked)"

# --- 3b. the default threshold is 0.8, and it is measured --------------------
# See _typesafe_optin's comment and scripts/typesafe-ack-eval.sh. Pinned from
# both sides so a silent change to the fallback cannot slip past.
write_home_config default-threshold
write_curl_stub 0.81
check demote "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "default threshold: 0.81 demotes (default <= 0.81)"
write_curl_stub 0.79
check ack "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "default threshold: 0.79 does not demote (default > 0.79)"

# An out-of-range threshold is a refusal, not a clamp: the lane reads as OFF.
write_curl_stub 0.99
write_home_config true 7
check ack "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "out-of-range threshold => lane declines (off), not clamped"

# --- 4. consent is authenticated by LOCATION ---------------------------------
# ADR 0012: a checked-out repo must not be able to make this machine call a
# third party. A repo-local .claude/busdriver.json is repo-controlled input.
write_home_config none
write_curl_stub 0.99
mkdir -p "$TMP/repo/.claude"
jq -nc '{typesafe:{ack_ledger:{enabled:true,threshold:0.5}}}' > "$TMP/repo/.claude/busdriver.json"
check ack \
  "$(cd "$TMP/repo" && TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "repo-local .claude/busdriver.json CANNOT enable the lane"

# --- 5. an env-set HOME cannot enable the lane -------------------------------
# $HOME is repo-injectable (a committed settings.json `env` block sets it), so
# consent is read from the PASSWORD-DATABASE home instead. Pin exactly that: the
# resolver points at an empty directory, $HOME holds a fully enabling config,
# and the armed stub would demote if it were ever reached. Anything but `ack`
# means $HOME reached the consent check.
mkdir -p "$TMP/nohome"
write_curl_stub 0.99
write_home_config true 0.5
check ack \
  "$(HOME="$TMP/home" TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" TS_HOME="$TMP/nohome" \
       run_union "$REGEX_ACKS")" \
  "an env-set HOME cannot enable the lane"

# --- 6. no environment reaches curl ------------------------------------------
# Pinning the URL in the script does not pin curl's DESTINATION. `https_proxy`
# plus a repo-supplied CURL_CA_BUNDLE is a TLS-intercepting proxy that receives
# the Authorization header on a request that still looks pinned from inside the
# script, and both are settable from a committed settings.json `env` block.
# Enumerating those names is the treadmill; `env -i PATH=... HOME=/nonexistent`
# is the allowlist. The stub refuses to answer if either reaches it, so a leak
# shows up here as a demote.
write_curl_stub leak-check
write_home_config true 0.9
check ack \
  "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" https_proxy=http://127.0.0.1:1 \
     CURL_CA_BUNDLE=/nonexistent/ca.pem run_union "$REGEX_ACKS")" \
  "no proxy/CA environment reaches curl"

# --- 7. the home lookup is ordered last, and memoizes in the caller ----------
# Both of these are regressions this branch introduced and then fixed, so they
# are pinned rather than described. The curl stub is armed only so a machine
# whose real operator config DOES enable the lane makes no network call here;
# the assertions are on the flag, which is the same either way.
write_curl_stub 0.01

# The lookup must not run when the cheap env checks already answer: it forked
# python3 once per bot status, in every repo, for a value the next line discards.
check 0 \
  "$(ACK_LEDGER_TYPESAFE=0 TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" \
       probe_home_state '_noul_says_non_review "Review completed" || true')" \
  "lane off: the password-DB lookup is never reached"

# And when it does run, the memo must land in the CALLER, not in a subshell that
# is discarded — once through _typesafe_optin, once through the entry point.
check 1 \
  "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" \
       probe_home_state '_typesafe_optin || true')" \
  "the home memo survives _typesafe_optin"
check 1 \
  "$(TYPESAFE_API_KEY=k PATH="$TMP/bin:$PATH" \
       probe_home_state '_noul_says_non_review "Review completed" || true')" \
  "the home memo survives the classifier entry point"

# The env var is a kill switch only: it turns the lane OFF...
write_home_config true 0.9
check ack \
  "$(TYPESAFE_API_KEY=k ACK_LEDGER_TYPESAFE=0 PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "ACK_LEDGER_TYPESAFE=0 kills the lane (restores regex-only)"

# ...and there is no env spelling that turns it ON.
write_home_config none
check ack \
  "$(TYPESAFE_API_KEY=k ACK_LEDGER_TYPESAFE=1 PATH="$TMP/bin:$PATH" run_union "$REGEX_ACKS")" \
  "ACK_LEDGER_TYPESAFE=1 does NOT enable the lane without operator config"

echo
echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
