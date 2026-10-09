#!/usr/bin/env bash
# test-agy-dispatch-arm.sh — the SHARED agy dispatch arm (plain `--cli agy`
# reviewer slots + the `agy-prose` lane), and the `bare` model-id grammar.
#
# No real agy binary is invoked: every behavioural case stubs agy on PATH, and
# every dispatch either refuses before agy or reaches the stub. Offline + CI-safe.
#
# The invariants that matter:
#   (a) plain `--cli agy` (blueprint-review reviewer_1, council.pragmatist) never
#       picks up a lane's model or `--mode plan`; and
#   (b) every agy dispatch scopes to the CWD via `--add-dir "$PWD"` (#686), so an
#       unscoped reviewer cannot cite a remembered foreign tree. Sections 5b/5c
#       assert the real argv both reviewer entry points (dispatch.sh and
#       execute_review) reach agy with.
# Coverage moved here from test-agy-read-lane.sh when the agy-read lane was
# withdrawn (ADR 0052 follow-up); lane-specific cases now drive `agy-prose`.

# Literal grep patterns ($PWD, ${...}) must never expand, and several checks
# deliberately consume a command's output rather than its status.
# shellcheck disable=SC2016,SC2312
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh"
RESOLVE="$REPO_ROOT/scripts/lib/resolve-cli.sh"

FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; FAILED=1; }

# agy-prose refuses a group/world-writable $TMPDIR (CI's /tmp is 1777), so every
# lane dispatch below runs with a private mode-700 temp dir OUTSIDE any checkout.
# Anchored at /tmp on purpose: a bare `mktemp -d` inherits the ambient $TMPDIR,
# and one pointing into the checkout would make agy-prose refuse every case.
prose_tmp="$(mktemp -d /tmp/agy-arm-prose.XXXXXX)" || { echo "FAIL — mktemp -d failed for prose_tmp"; exit 1; }
chmod 700 "$prose_tmp"
# The ONE cleanup trap for every fixture in this file (a second `trap ... EXIT`
# would replace it). `${var:-}` keeps it set -u safe for fixtures not yet made.
trap 'rm -rf "${prose_tmp:-}" "${wd_stub:-}" "${tmp_home:-}" "${ags_stub:-}" "${ags_cwd:-}" "${er_cwd:-}" "${er_stub:-}" "${er_ng:-}" "${agy_stub_dir:-}" "${agyv_stub:-}" "${agyh_decoy:-}" "${agyh_stub:-}"' EXIT

# ── 1. agy-read is withdrawn, not silently remapped ─────────────
# A stale caller must get a loud refusal — never a dispatch on plain agy, which
# would run with the reviewer's model and no plan mode.
wd_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for wd_stub"; exit 1; }
printf '#!/bin/sh\nprintf "AGY_WAS_INVOKED\\n"\n' > "$wd_stub/agy"; chmod +x "$wd_stub/agy"
out="$(PATH="$wd_stub:$PATH" "$DISPATCH" --cli agy-read --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"Invalid --cli value 'agy-read'"* && "$out" != *"AGY_WAS_INVOKED"* \
      && "$out" != *"|agy-read|"* ]]; then
  pass "--cli agy-read is rejected (withdrawn), agy is never invoked, enum no longer lists it"
else
  fail "--cli agy-read must be rejected without invoking agy (rc=$rc): $out"
fi
rm -rf "$wd_stub"

# ── 3. the config reader accepts a BARE agy id ──────────────────
# The pi grammar requires provider/model; agy ids have no slash, so a shared
# regex would silently reject every valid value. Driven through the prose lane's
# key, the one remaining `bare`-grammar consumer. It has no shipped default, so a
# rejected value resolves EMPTY — and dispatch then refuses a non-empty invalid
# string via the presence probe (pinned in test-agy-prose-lane.sh §5).
tmp_home="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for tmp_home"; exit 1; }
mkdir -p "$tmp_home/.claude"

check_model() {  # <json-value> <expected> <label>
  printf '{"writing_prose":{"model":%s}}\n' "$1" > "$tmp_home/.claude/busdriver.json"
  local got
  got="$(
    # shellcheck disable=SC1090
    source "$RESOLVE" >/dev/null 2>&1
    HOME="$tmp_home" resolve_writing_prose_model 2>/dev/null
    printf '%s' "$_BD_WRITING_PROSE_MODEL"
  )"
  if [[ "$got" == "$2" ]]; then pass "$3"; else fail "$3 (got '$got', want '$2')"; fi
}

check_model '"probe-model-a"' 'probe-model-a' \
  'bare id is accepted verbatim'
check_model '"probe-model-b"' 'probe-model-b' \
  'a different bare id is honoured (config actually drives the lane)'
# Option injection and junk must be rejected, not reach argv.
check_model '"--dangerously-skip-permissions"' '' \
  'leading-dash value is rejected by the grammar (no option injection into agy argv)'
check_model '"has space"' '' \
  'whitespace value is rejected by the grammar'
# A JSON number or boolean must be rejected rather than being stringified by
# `jq -r` and forwarded verbatim to `agy --model` — jq and the python3 fallback
# must agree on this (PR #687 Codex finding).
check_model '123' '' \
  'numeric config value is rejected (jq/python parity)'
check_model 'true' '' \
  'boolean config value is rejected (jq/python parity)'

# ── 4. pi's grammar is unchanged (no cross-contamination) ───────
printf '{"pi_read":{"model":"bare-no-slash"}}\n' > "$tmp_home/.claude/busdriver.json"
got="$(
  # shellcheck disable=SC1090
  source "$RESOLVE" >/dev/null 2>&1
  HOME="$tmp_home" resolve_pi_read_model 2>/dev/null
  printf '%s' "$_BD_PI_READ_MODEL"
)"
# pi-read ships no default, so a rejected bare id resolves EMPTY. That proves
# the grammar did not leak: writing_prose accepts bare ids, pi-read must not.
if [[ -z "$got" ]]; then
  pass "pi still requires provider/model (bare id resolves empty, no default)"
else
  fail "pi grammar leaked the bare shape (got '$got')"
fi

# ── 5/6. the workspace argv: --add-dir UNCONDITIONAL, guard workspace lane-only ──
#   --add-dir : MEASURED 2026-08-17 — without it agy resolves a remembered
#               workspace and cited a stale checkout with confident file:line
#               refs (wrong tree, no error). Since #686 it is UNCONDITIONAL —
#               plain `--cli agy` is the blueprint-review reviewer_1 /
#               council.pragmatist slot, and an unscoped reviewer can return
#               findings about a DIFFERENT checkout than the one under review.
#   guard     : every READONLY agy dispatch runs from `_agy_guarded` (a fresh
#               workspace holding the deny-by-default agy-review-guard hook).
#               Measured 2026-10-10 under toolPermission always-proceed: from the
#               checkout, both `--sandbox` and `--sandbox --mode plan` (the prose
#               lane's previous boundary) wrote into it on request, so --mode plan
#               must not come back as a boundary anywhere in this file.
scope_build="$(grep -cE '^[[:space:]]+local _agy_lane=\(--add-dir "\$PWD"\) _agy_run=\(_agy_guarded\)$' "$DISPATCH")"
scope_plan="$(grep -vE '^[[:space:]]*#' "$DISPATCH" | grep -c -- '--mode plan')" || true
lane_sites="$(grep -cE '^[[:space:]]+"\$\{_agy_lane\[@\]\+"\$\{_agy_lane\[@\]\}"\}" \\$' "$DISPATCH")"
agy_sites="$(grep -cE '_portable_timeout "\$_budget" agy ' "$DISPATCH")"
run_sites="$(grep -cE '^[[:space:]]+"\$\{_agy_run\[@\]\+"\$\{_agy_run\[@\]\}"\}" _portable_timeout "\$_budget" agy --sandbox \\$' "$DISPATCH")"
if [[ "$scope_build" == "1" && "$lane_sites" == "$agy_sites" && "$lane_sites" == "4" ]]; then
  pass "workspace argv built once, expanded at all $agy_sites agy call sites"
else
  fail "scope_build=$scope_build lane_sites=$lane_sites agy_sites=$agy_sites (want 1/4/4)"
fi

# --add-dir must be UNCONDITIONAL: removing it silently re-exposes the reviewer
# slot to agy's remembered workspace (the #686 defect). The guard reaches BOTH
# readonly call sites and neither auto site; --mode plan is gone.
if [[ "$scope_build" == "1" && "$run_sites" == "2" && "$scope_plan" == "0" ]]; then
  pass "--add-dir unconditional; guard workspace at both readonly sites only; no --mode plan"
else
  fail "want build=1 run_sites=2 plan=0 (got build=$scope_build run_sites=$run_sites plan=$scope_plan)"
fi

# ── 5b. the dispatch shapes, observed from inside a stub agy ──
# Behavioural, not structural: the stub prints its argv, its cwd, whether the
# guard hook is staged there, and the Hindsight env it inherited. A grep-only
# guard could be defeated by moving a flag out of the shared array.
#   plain --cli agy (reviewer_1 / council.pragmatist) and agy-prose alike: run
#     from a fresh /tmp/agy-review-guard.* workspace with the guard staged,
#     --add-dir still the dispatch CWD (#686), no --mode plan, and the
#     workspace is removed afterwards.
#   both (readonly): Hindsight read-only — RETAIN_SESSIONS=false, AUTO_INJECT=pages,
#     even when the caller exported the opposite.
ags_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for ags_stub"; exit 1; }
ags_cwd="$(cd "$(mktemp -d)" && pwd -P)" || { echo "FAIL — mktemp -d failed for ags_cwd"; exit 1; }
cat > "$ags_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.5.0\n'; exit 0; fi
printf 'AGY_ARGV:%s\n' "$*"
printf 'AGY_CWD:%s\n' "$(pwd -P)"
if [ -f .agents/hooks.json ] && [ -f .agents/guard.py ]; then printf 'AGY_GUARD:yes\n'; else printf 'AGY_GUARD:no\n'; fi
printf 'AGY_HS:%s/%s\n' "${HINDSIGHT_RETAIN_SESSIONS-unset}" "${HINDSIGHT_AUTO_INJECT-unset}"
STUB
chmod +x "$ags_stub/agy"

out="$(cd "$ags_cwd" && HINDSIGHT_RETAIN_SESSIONS=true HINDSIGHT_AUTO_INJECT=reflect PATH="$ags_stub:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"
plain_ws="$(printf '%s\n' "$out" | sed -n 's/^AGY_CWD://p' | head -1)"
if [[ "$out" == *"--add-dir $ags_cwd"* && "$out" != *"--mode plan"* && "$out" == *"AGY_GUARD:yes"* \
      && "$plain_ws" == */agy-review-guard.* && ! -e "$plain_ws" && "$out" == *"AGY_HS:false/pages"* ]]; then
  pass "plain readonly --cli agy runs from a removed guard workspace (--add-dir the dispatch CWD, no --mode plan), Hindsight read-only"
else
  fail "plain --cli agy shape wrong (ws='$plain_ws' out: $out)"
fi

# --mode auto is the writing agent: it must NOT run from the guard workspace.
out="$(cd "$ags_cwd" && PATH="$ags_stub:$PATH" "$DISPATCH" --cli agy --mode auto --prompt x 2>&1)"
if [[ "$out" == *"AGY_CWD:$ags_cwd"* && "$out" == *"AGY_GUARD:no"* ]]; then
  pass "--mode auto agy runs from the dispatch CWD, unguarded"
else
  fail "--mode auto agy must run unguarded from the dispatch CWD (out: $out)"
fi

# An explicit neutral --model keeps this case independent of the operator's real
# .writing_prose.model, which agy-prose reads from the password-DB home and
# refuses before agy when it is invalid.
out="$(cd "$ags_cwd" && TMPDIR="$prose_tmp" HINDSIGHT_RETAIN_SESSIONS=true PATH="$ags_stub:$PATH" "$DISPATCH" --cli agy-prose --model probe-model-a --prompt x 2>&1)"
prose_ws="$(printf '%s\n' "$out" | sed -n 's/^AGY_CWD://p' | head -1)"
if [[ "$out" == *"--add-dir $ags_cwd"* && "$out" != *"--mode plan"* && "$out" == *"AGY_GUARD:yes"* \
      && "$prose_ws" == */agy-review-guard.* && ! -e "$prose_ws" && "$out" == *"AGY_HS:false/pages"* ]]; then
  pass "agy-prose runs from a removed guard workspace with the guard staged, --add-dir the dispatch CWD, no --mode plan"
else
  fail "agy-prose shape wrong (ws='$prose_ws' out: $out)"
fi

# Outside a checkout agy is not pinned, so a relative PATH entry must still resolve
# against the dispatch CWD, not the guard workspace. PATH drops every other agy.
mkdir -p "$ags_cwd/rel/bin" && cp "$ags_stub/agy" "$ags_cwd/rel/bin/agy"
rel_path="rel/bin"
IFS=: read -r -a _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do [[ -n "$_d" && ! -x "$_d/agy" ]] && rel_path="$rel_path:$_d"; done
out="$(cd "$ags_cwd" && PATH="$rel_path" "$DISPATCH" --cli agy --prompt x 2>&1)"
if [[ "$out" == *"AGY_GUARD:yes"* && "$out" == *"AGY_ARGV:"* ]]; then
  pass "readonly agy found through a relative PATH entry still launches in the guard workspace"
else
  fail "relative PATH agy did not launch (out: $out)"
fi
rm -rf "$ags_cwd/rel"

# The guard workspace is its own git repo, so the agy pin must be taken against
# the REAL checkout, not the workspace: an agy shipped inside the checkout must never run.
git -C "$ags_cwd" init -q && mkdir "$ags_cwd/bin"
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo 1.5.0; exit 0; }\necho CHECKOUT_AGY_RAN\n' > "$ags_cwd/bin/agy"
chmod +x "$ags_cwd/bin/agy"
out="$(cd "$ags_cwd" && PATH="$ags_cwd/bin:$ags_stub:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"
if [[ "$out" != *"CHECKOUT_AGY_RAN"* && "$out" != *"AGY_ARGV:"* && "$out" == *"resolves inside the reviewed checkout"* ]]; then
  pass "readonly agy refuses an agy that resolves inside the dispatch checkout"
else
  fail "readonly agy ran or did not refuse a checkout-shipped agy (out: $out)"
fi
rm -rf "$ags_stub" "$ags_cwd"

# ── 5c. execute_review (blueprint-review/litmus reviewer path) scopes too ──
# dispatch_one is not the only agy reviewer entry point: blueprint-review's
# reviewer_1 and litmus-via-agy run through execute_review in
# scripts/lib/resolve-cli.sh, which builds its OWN argv. Both of its agy
# transports must carry `--add-dir "$PWD"` — a reviewer of record must resolve
# the tree under review, not agy's remembered workspace (#686).
# argv0 is the trust-resolved ABSOLUTE binary ("$_agy_bin"), not a bare `agy`
# token: #789 made the reviewer of record execute the path _resolve_trusted_cli_bin
# returned rather than whatever PATH offers. Pin that form — matching a bare `agy`
# here would silently pass again if the arm ever regressed to PATH resolution.
er_sites="$(grep -cE '^[[:space:]]+"\$_bd_agy_bin" --sandbox --add-dir "\$PWD"' "$RESOLVE")"
if [[ "$er_sites" == "2" ]]; then
  pass "execute_review agy arm passes --add-dir \"\$PWD\" on both transports"
else
  fail "execute_review agy arm must pass --add-dir \"\$PWD\" on both transports (found $er_sites/2)"
fi

# Behavioral, part 1 — SUCCESSFUL review dispatch. The reviewer path resolves agy
# through _resolve_trusted_cli_bin, which is fail-CLOSED in BOTH directions: it
# refuses unless it can establish the reviewed checkout AND place the binary
# outside it. So the success fixture must be a real Git checkout — the condition
# every real review runs under — with the stub in a sibling directory outside it.
# A bare mktemp cwd exercises the refusal path instead, which part 2 now asserts
# on purpose rather than leaving it as an accident of the fixture (#789).
er_cwd="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for er_cwd"; exit 1; }
er_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for er_stub"; exit 1; }
# Plain `git init` (no -b): the branch name is never used here, and `--initial-branch`
# needs Git >= 2.28 — on an older git this fixture aborted the whole suite.
git -C "$er_cwd" init -q >/dev/null 2>&1 || { echo "FAIL — git init failed for er_cwd"; exit 1; }
# 1.1.x pins the argv rung this #686 contract is about. agy >=1.2 takes the stream-json rung, which
# deliberately scopes agy to a fresh guard workspace instead of the checkout (#840); that scoping is
# pinned in tests/test-agy-stream-transport.sh.
cat > "$er_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.1.4\n'; exit 0; fi
printf 'ER_ARGV:%s\n' "$*"
STUB
chmod +x "$er_stub/agy"
out="$(cd "$er_cwd" && REPO_ROOT="$REPO_ROOT" PATH="$er_stub:$PATH" bash -c '
  . "$REPO_ROOT/scripts/lib/resolve-cli.sh" 2>/dev/null
  execute_review agy "review" 10 2>&1')"
if [[ "$out" == *"ER_ARGV:"* && "$out" == *"--add-dir $er_cwd"* ]]; then
  pass "execute_review (reviewer path) scopes agy to the dispatch CWD"
else
  fail "execute_review agy must pass --add-dir \"\$PWD\" (out: $out)"
fi

# Behavioral, part 2 — the PRESERVED fail-CLOSED contract, asserted by name. With
# no checkout to verify a binary against, the reviewer path must refuse and must
# NOT reach the stub. Same stub, same PATH as part 1; only the cwd differs, so a
# pass here can only come from the missing checkout.
er_ng="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for er_ng"; exit 1; }
out_ng="$(cd "$er_ng" && REPO_ROOT="$REPO_ROOT" PATH="$er_stub:$PATH" bash -c '
  . "$REPO_ROOT/scripts/lib/resolve-cli.sh" 2>/dev/null
  execute_review agy "review" 10 2>&1')" || true
if [[ "$out_ng" == *"refusing review dispatch"* && "$out_ng" != *"ER_ARGV:"* ]]; then
  pass "execute_review agy refuses fail-CLOSED outside a Git checkout (no dispatch)"
else
  fail "execute_review agy outside a checkout must refuse without dispatching (out: $out_ng)"
fi
rm -rf "$er_cwd" "$er_stub" "$er_ng"

# ── 8. the audit trail names the lane, not plain "agy" ──────────
# The desugar sets CLI=agy so dispatch mechanics stay on the shared arm, but
# the lanes send content to potentially different third parties and differ in
# write posture — an audit entry that reads plain "agy" cannot tell which lane
# ran. REPORT_CLI_NAME must be captured before CLI is overwritten, and
# OUTFILE/the console status line/log_event must all key off it (falling back to
# $CLI for every other --cli value). (PR #687 Codex finding.)
#
# CodeRabbit finding (PR #687, efcd4b9d): independent `grep -q` checks only
# prove each pattern exists SOMEWHERE in the file — they pass even if
# REPORT_CLI_NAME is captured AFTER $CLI is overwritten, or if REPORT_NAME is
# built from something other than the validated REPORT_CLI_NAME/CLI pair. Pin
# the actual control-flow order with line numbers instead: init empty →
# agy-prose desugar capture → REPORT_NAME assignment → vocabulary whitelist →
# OUTFILE construction, each strictly after the last.
line_of() { grep -nE "$1" "$DISPATCH" | head -1 | cut -d: -f1; }

l_init="$(line_of '^REPORT_CLI_NAME=""$')"
l_capture="$(line_of '^[[:space:]]+REPORT_CLI_NAME="agy-prose"$')"
l_assign="$(line_of '^[[:space:]]+REPORT_NAME="\$\{REPORT_CLI_NAME:-\$CLI\}"$')"
l_whitelist="$(line_of '^[[:space:]]+codex\|agy\|agy-prose\|grok\|pi-read\) ;;$')"
l_outfile="$(line_of 'OUTFILE="\$\{OUT_DIR\}/dispatch-\$\{REPORT_NAME\}-\$\{STAMP\}\.txt"')"
l_log="$(line_of 'log_event "\$REPORT_NAME"')"
l_console="$(line_of 'echo "\$\{REPORT_NAME\} →')"

if [[ -n "$l_init" && -n "$l_capture" && -n "$l_assign" && -n "$l_whitelist" \
      && -n "$l_outfile" && -n "$l_log" && -n "$l_console" ]] \
   && (( l_init < l_capture && l_capture < l_assign \
         && l_assign < l_whitelist && l_whitelist < l_outfile \
         && l_outfile <= l_log && l_outfile <= l_console )); then
  pass "REPORT_CLI_NAME/REPORT_NAME control-flow order: init < agy-prose capture < assign < whitelist < OUTFILE/log/console"
else
  fail "REPORT_CLI_NAME/REPORT_NAME sites are out of order or missing (init=$l_init capture=$l_capture assign=$l_assign whitelist=$l_whitelist outfile=$l_outfile log=$l_log console=$l_console) — audit identity or path safety could regress silently"
fi

# REPORT_CLI_NAME feeds a FILENAME and the audit log, so it is a provenance
# field. It MUST be initialized at top level: without that, an INHERITED
# environment variable would set the logged provider identity and inject path
# components into the output filename on EVERY invocation — and a committed
# .claude/settings.json `env` block is repo-controlled (#325 / ADR 0016), so an
# ambient value is attacker-reachable. Litmus caught this as a HIGH.
if [[ -n "$l_init" ]]; then
  pass "REPORT_CLI_NAME is initialized empty (no inherited-env provenance forgery)"
else
  fail "REPORT_CLI_NAME has no unconditional empty initializer — an inherited env var could forge the audit identity and inject path components into OUTFILE"
fi

# Defense in depth: even if a future edit reintroduces a non-literal source, the
# value must be constrained to the lane vocabulary before it reaches a path.
if [[ -n "$l_whitelist" ]]; then
  pass "REPORT_NAME is whitelisted against the lane vocabulary before use in a path"
else
  fail "REPORT_NAME has no vocabulary whitelist — an unexpected value could reach OUTFILE"
fi

# ── 8b. the bare grammar's accept/reject boundaries ──────────────
# This validator guards an argv slot, so the REJECT set matters as much as the
# accept set: anything that could become a second option, a path, or a shell
# metacharacter must be rejected instead of reaching agy's argv.
for bad in '"prov/model"' '"has\ttab"' '"-lead"' '"/lead"' \
           '"trail/"' '"a/b"' '"semi;colon"' '"dollar$var"' '"pipe|x"' \
           '"amp&x"' '"paren(x)"' '""' '"  "'; do
  check_model "$bad" '' "grammar rejects $bad"
done
# Accepted: the characters the validator's comment claims are allowed must
# actually be allowed, or the comment is the only thing enforcing them.
for good in a A0 x.y x_9 m:tag m@ver a-b.c:d@e; do
  check_model "\"$good\"" "$good" "grammar accepts $good"
done

# ── 9. jq/python parity across JSON value types ──────────────────
# The reader has TWO backends (jq, then a python3 fallback) and they disagreed:
# `jq -r` stringifies a number/boolean, so `{"model":123}` passed the bare-ID
# regex and reached `agy --model`, while python's isinstance(v,str) rejected it.
# The property that matters is backend-independent: NO non-string JSON type may
# ever survive validation, whichever reader ran. Checked as a table, not one
# example, because the original bug was exactly a missed type.
for badtype in 123 -1 0 1.5 true false null '[]' '["a"]' '{}' '{"a":1}'; do
  check_model "$badtype" '' "non-string JSON ($badtype) is rejected"
done

# ── 10. agy 1.0.x + a model-pinned lane refuses rather than dropping --model ───
# (PR #687 Codex finding.) agy 1.0.x does not support --model, so a lane
# dispatch carrying one would reach the /dev/stdin transport with an unsupported
# flag on every attempt. End-to-end: stub `agy --version` as 1.0.0 on PATH and
# pass --model explicitly (the lane's own model resolution reads the real
# password-DB home and cannot be redirected, so an explicit --model is the only
# way to exercise the guard without touching the operator's real config).
agy_stub_dir="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for agy_stub_dir"; exit 1; }
cat > "$agy_stub_dir/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.0.0\n'; exit 0; fi
printf 'AGY_WAS_INVOKED\n'
STUB
chmod +x "$agy_stub_dir/agy"
# Model id deliberately avoids the leak-sweep's vendor-name patterns in
# tests/test-lane-model-config.sh — this is an arbitrary stand-in, not a
# real provider/model, and the refusal path is triggered by the CLI version
# alone, not by the value.
out="$(TMPDIR="$prose_tmp" PATH="$agy_stub_dir:$PATH" "$DISPATCH" --cli agy-prose --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"does not support it"* && "$out" == *"stub-model-3.7"* \
      && "$out" != *"AGY_WAS_INVOKED"* ]]; then
  pass "agy-prose on a 1.0.x agy install refuses loudly instead of dropping --model or invoking agy"
else
  fail "agy-prose + agy 1.0.0 should refuse before invoking agy (rc=$rc): $out"
fi

# The refusal is NOT lane-scoped (#689). Removing the blanket --model refusal
# made plain `--cli agy --model X` reachable, so on 1.0.x it would forward an
# unsupported flag and surface agy's own internal error instead of the
# dispatcher's actionable one. Codex (round 7) and Greptile both flagged it.
# The refusal is a HARD exit, not exit_code=1: a config error must fail the
# dispatch loudly, before agy is ever invoked.
out="$(PATH="$agy_stub_dir:$PATH" "$DISPATCH" --cli agy --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"does not support it"* && "$out" == *"stub-model-3.7"* \
      && "$out" != *"AGY_WAS_INVOKED"* ]]; then
  pass "plain --cli agy --model on a 1.0.x install refuses loudly too (not lane-scoped)"
else
  fail "plain --cli agy --model + agy 1.0.0 should refuse before invoking agy (rc=$rc): $out"
fi

# ...but plain `--cli agy` with NO --model is the reviewer_1 / council.pragmatist
# shape and MUST still reach agy on a 1.0.x install. Guards the widening above
# against over-reach: the predicate is "a model was requested", not "agy is old".
out="$(PATH="$agy_stub_dir:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"; rc=$?
if [[ "$out" == *"AGY_WAS_INVOKED"* && "$out" != *"does not support it"* ]]; then
  pass "plain --cli agy with no --model still dispatches on a 1.0.x install"
else
  fail "plain --cli agy (no --model) must still reach agy on 1.0.x (rc=$rc): $out"
fi
rm -rf "$agy_stub_dir"

# ── 10b. an INCONCLUSIVE version probe refuses a model-pinned dispatch ──
# (Codex P2 on PR #687.) `_agy_wants_argv_prompt` bounds `agy --version` at 2s
# and classifies timeout/unparseable as MODERN — the right default for prompt
# delivery, but not evidence of `--model` support. A 1.0.x install whose version
# command is slow was therefore routed down the argv path with `--model`
# attached, skipping the confirmed-1.0.x refusal entirely, and the operator got
# agy's raw option/path error instead of an actionable one. Reproduced with Codex's own shape: a stub whose
# `--version` sleeps past the probe budget.
agyv_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for agyv_stub"; exit 1; }
cat > "$agyv_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then sleep 3; printf '1.0.0\n'; exit 0; fi
printf 'AGY_WAS_INVOKED\n'
STUB
chmod +x "$agyv_stub/agy"
out="$(TMPDIR="$prose_tmp" PATH="$agyv_stub:$PATH" "$DISPATCH" --cli agy-prose --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"support is unconfirmed"* && "$out" == *"stub-model-3.7"* \
      && "$out" != *"AGY_WAS_INVOKED"* ]]; then
  pass "an inconclusive agy --version probe refuses a model-pinned dispatch (does not assume support)"
else
  fail "slow-version 1.0.x + --model should refuse, not forward --model (rc=$rc): $out"
fi

# Same slow probe, but NO --model: the reviewer_1 / council.pragmatist shape must
# still dispatch. Guards the refusal above against over-reach — the predicate is
# "a model was requested we cannot honour", never "the probe was slow".
out="$(PATH="$agyv_stub:$PATH" "$DISPATCH" --cli agy --prompt x 2>&1)"; rc=$?
if [[ "$out" == *"AGY_WAS_INVOKED"* && "$out" != *"support is unconfirmed"* ]]; then
  pass "an inconclusive probe with no --model still dispatches (reviewer path unaffected)"
else
  fail "plain --cli agy (no --model) must still dispatch on a slow-version install (rc=$rc): $out"
fi
# The conclusive-probe flag must not be forgeable from the environment. A
# committed .claude/settings.json `env` block is repo-controlled (#325 / ADR
# 0016), so an inherited "1" would forge "version confirmed" and re-enable
# exactly the --model forwarding the guard above exists to refuse. Same
# discipline (and same reason) as `_AGY_ARGV_PROMPT`, whose own env-override
# check lives in tests/test-agy-argv-limit.sh.
out="$(TMPDIR="$prose_tmp" PATH="$agyv_stub:$PATH" _AGY_PROBE_CONCLUSIVE=1 "$DISPATCH" --cli agy-prose --model stub-model-3.7 --prompt x 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"support is unconfirmed"* && "$out" != *"AGY_WAS_INVOKED"* ]]; then
  pass "an inherited _AGY_PROBE_CONCLUSIVE=1 cannot forge version confirmation"
else
  fail "env _AGY_PROBE_CONCLUSIVE=1 must not bypass the inconclusive-probe refusal (rc=$rc): $out"
fi
rm -rf "$agyv_stub"

# ── 11. the lane pins a trusted $HOME on the agy PROCESS ─────────
# (PR #687 Codex P1.) A trusted, password-DB-derived home used only to read the
# lane's model key still let the agy child inherit $HOME — which
# `.claude/settings.json` can set from a reviewed checkout. agy loads and
# persists its own ~/.gemini config, auth and plan artifacts from $HOME on EVERY
# invocation, so an inherited one hands the lane's entire agy configuration to
# the repo under review. Behavioural, not structural: stub agy so it prints the
# $HOME it actually received, dispatch with $HOME pointed at a decoy, and assert
# the child saw the password-DB home. Run for BOTH model paths, because the
# original defect was specifically that `--model` skipped the derivation.
agyh_real="$(eval echo "~$(/usr/bin/id -un)")"
agyh_decoy="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for agyh_decoy"; exit 1; }
agyh_stub="$(mktemp -d)" || { echo "FAIL — mktemp -d failed for agyh_stub"; exit 1; }
cat > "$agyh_stub/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '1.5.0\n'; exit 0; fi
printf 'AGY_SAW_HOME=[%s]\n' "$HOME"
STUB
chmod +x "$agyh_stub/agy"
for agyh_case in explicit-model resolved-model; do
  if [[ "$agyh_case" == explicit-model ]]; then
    set -- --model stub-model-3.7
  else
    set --
  fi
  out="$(HOME="$agyh_decoy" TMPDIR="$prose_tmp" PATH="$agyh_stub:$PATH" \
         "$DISPATCH" --cli agy-prose "$@" --prompt x 2>&1)" || true
  # resolved-model reads .writing_prose.model from the operator's REAL
  # password-DB home (it cannot be redirected) and refuses before agy if that
  # value is invalid. That host cannot exercise this case — say so rather than
  # fail: the $HOME export runs BEFORE model resolution, so explicit-model alone
  # proves the pin.
  if [[ "$agyh_case" == resolved-model && "$out" == *".writing_prose.model is set to"* ]]; then
    pass "$agyh_case: NOT EXERCISED on this host (its .writing_prose.model is invalid, so the lane refused before agy); the \$HOME pin is proven by explicit-model"
  elif [[ "$out" != *"AGY_SAW_HOME="* ]]; then
    fail "$agyh_case: stub agy was never invoked, so the \$HOME pin is unproven: $out"
  elif [[ "$out" == *"AGY_SAW_HOME=[$agyh_decoy]"* ]]; then
    fail "$agyh_case: agy inherited the injectable \$HOME ($agyh_decoy) instead of the password-DB home"
  elif [[ "$out" == *"AGY_SAW_HOME=[$agyh_real]"* ]]; then
    pass "$agyh_case: agy-prose pins the password-DB \$HOME on the agy process"
  else
    fail "$agyh_case: agy saw an unexpected \$HOME (wanted $agyh_real): $out"
  fi
done
set --
rm -rf "$agyh_decoy" "$agyh_stub"

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-agy-dispatch-arm"; else echo "FAIL: test-agy-dispatch-arm"; fi
exit "$FAILED"
