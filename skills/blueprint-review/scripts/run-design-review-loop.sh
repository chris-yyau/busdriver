#!/bin/bash -p
# #803: re-exec privileged before sourcing anything. Privileged mode makes bash
# ignore BASH_ENV, and BASH_ENV is the whole environment-reachable path into this
# process: it is honoured for `bash script.sh`, so a prelude can install a DEBUG
# trap (which then steers EVERY parent-shell variable, defeating any in-library
# check) or declare the review-lib state readonly (which neither assignment nor
# `builtin unset` can clear). Measured both ways against resolve-cli.sh: without
# -p the planted script executed; with -p both attempts return the correct value.
# Privileged mode also refuses to import BASH_FUNC_* shadows, which is #803's
# original class. Same guard and same reasoning as skills/litmus/scripts/
# run-review-loop.sh — "$BASH", not /bin/bash, so the SAME interpreter is re-exec'd
# rather than silently downgraded to macOS bash 3.2.
if [[ "$-" != *p* ]]; then
    exec "${BASH:-/bin/bash}" -p "$0" "$@"
fi
# #803: privileged mode protects THIS shell only. It makes bash ignore BASH_ENV/ENV
# and refuse BASH_FUNC_* imports, but it leaves those entries sitting in the
# ENVIRONMENT, so any unprivileged bash CHILD re-processes them. Measured: with
# BASH_ENV pointing at a file containing `exit 0`, a child launched from a
# privileged parent exited 0 without running its body at all. Scrub them here,
# where -p guarantees `unset` is the real builtin and no shadow was imported.
# BASH_FUNC_* entries cannot be removed this way -- their names are not valid
# identifiers, and `unset "BASH_FUNC_x%%"` leaves the environ entry in place
# (measured; an unprivileged grandchild still imported it) -- so every child this
# script launches is started with -p rather than relying on the scrub alone.
# BD803-CLEAN-ENV-BEGIN
# #803: privileged mode protects THIS shell only. It makes bash ignore BASH_ENV/ENV
# and refuse BASH_FUNC_* imports, but it leaves every one of those entries sitting in
# the ENVIRONMENT, so any unprivileged descendant re-imports them -- including a
# plain `#!/bin/bash` helper reached through a sourced library, which no amount of
# care in THIS file would cover. Measured: BASH_ENV pointing at a file containing
# `exit 0` made a child exit 0 without running its body, and a forged
# BASH_FUNC_python3%% was imported by an unprivileged grandchild.
# BASH_FUNC_* entries cannot be removed with `unset` -- their names are not valid
# identifiers and the environ entry survives (measured) -- so strip them by rebuilding
# the environment once, here. After this exec the tree is clean, so the branch cannot
# repeat. SHELLOPTS/BASHOPTS are readonly and cannot be unset; -p already ignores them.
unset BASH_ENV ENV
_bd803_envclean=()
while IFS='=' read -r _bd803_n _; do
  case "$_bd803_n" in BASH_FUNC_*) _bd803_envclean+=(-u "$_bd803_n") ;; esac
done < <(/usr/bin/env)
if [[ ${#_bd803_envclean[@]} -gt 0 ]]; then
  exec /usr/bin/env "${_bd803_envclean[@]}" "${BASH:-/bin/bash}" -p "$0" "$@"
fi
unset _bd803_envclean _bd803_n
# BD803-CLEAN-ENV-END
# shellcheck disable=SC1091  # dynamic $SCRIPT_DIR/$_PLUGIN_ROOT source paths are not resolvable at lint time
# Three-tier design review: Agy + Codex (parallel) → Claude arbiter
#
# Architecture (post-A++ council fix, 2026-03-27):
#   - Agy + Codex run in parallel as independent reviewers
#   - Claude validates their findings against the codebase (arbiter)
#   - Claude's verdict is the sole convergence signal
#   - No Jaccard consensus, no auto-fix engine, no mechanical convergence
#
# Critic requirements implemented:
#   1. Run-scoped artifact isolation (stale output cleanup + run_id metadata)
#   2. Hard freshness contract (spec_hash + run_id + iteration in every output)
#   3. Atomic completion protocol (write to .pending, rename on success)
#   4. Claude verdict as first-class convergence (no consensus.json dependency)
#   5. Explicit progress model (severity breakdown, not binary FAIL/PASS)

# Intentional pipeline patterns throughout (printf | shasum | cut,
# shasum | cut, jq -r '.issues[] | ...', etc.) where the inner command's
# exit code is not load-bearing — SC2312 here would force noisy refactors
# with no real signal gain.
# shellcheck disable=SC2312

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"

# Source shared CLI resolution library
_PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}}"
# shellcheck source=../../../scripts/lib/resolve-cli.sh
source "$_PLUGIN_ROOT/scripts/lib/resolve-cli.sh"
# Optional ultra-oracle (ChatGPT Pro) auxiliary advisory (opt-in; visible best-effort).
# shellcheck source=../../../scripts/lib/ultra-oracle.sh
source "$_PLUGIN_ROOT/scripts/lib/ultra-oracle.sh" 2>/dev/null || true
ULTRA_ORACLE_ADVISORY_FILE=""        # set only when a fresh dispatch happens (non-claude-only)
ULTRA_ORACLE_DISPATCH_STATUS=""      # dispatched | skipped:* | error
ULTRA_ORACLE_DEADLINE=0              # epoch secs; set at dispatch, 0 = nothing in flight

# Grace margin added to the oracle cap for the .rc poll. Overridable ONLY to
# shorten (the tests need single-digit waits; a real run must not be extendable).
# ULTRA_ORACLE_RC_GRACE is repo-injectable via a committed settings.json `env`
# block (#325 / ADR 0016) and it bounds a wait, so it gets the same treatment the
# sibling BLUEPRINT_AUDITOR_GRACE already has below: non-numeric -> default,
# leading zeros stripped so a padded value is measured by significant digits,
# length-capped BEFORE $((10#…)) so an oversized digit string can never reach the
# arithmetic and wrap, floor 1, and an UPPER clamp at the default.
_UORA_RC_GRACE_DEFAULT=90
_uora_rc_grace() {
  local g="${ULTRA_ORACLE_RC_GRACE:-$_UORA_RC_GRACE_DEFAULT}"
  case "$g" in ''|*[!0-9]*) g="$_UORA_RC_GRACE_DEFAULT" ;; esac
  g="${g#"${g%%[!0]*}"}"
  [ -z "$g" ] && g=0
  [ "${#g}" -ge 8 ] && g="$_UORA_RC_GRACE_DEFAULT"
  g=$((10#$g))
  [ "$g" -lt 1 ] && g="$_UORA_RC_GRACE_DEFAULT"
  [ "$g" -gt "$_UORA_RC_GRACE_DEFAULT" ] && g="$_UORA_RC_GRACE_DEFAULT"
  printf '%s' "$g"
}
source "$SCRIPT_DIR/lib/state_management.sh"

# Ensure output directory exists (namespaced per design doc)
REVIEW_DIR=$(get_review_dir)
mkdir -p "$REVIEW_DIR"

# Cross-platform millisecond timestamp
millis() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  elif command -v python3 &>/dev/null; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    echo "$(date +%s)000"
  fi
}

# Blueprint runtime droid fallback: rescue a failed reviewer slot once via droid.
# Blueprint caps droid at ONE voice (all 3 reviewers share one prompt, so two
# droids would be near-duplicate signal). On a valid PASS/FAIL verdict, writes
# droid's extracted JSON with droid attribution + the round's freshness stamp.
# run_id is injected HERE: the freshness loop only fills a MISSING run_id and
# would otherwise treat a droid-supplied run_id as STALE and discard the rescue.
# Returns 0 on success (caller then stops — one droid voice).
_bp_droid_rescue() {
  local slot="$1" out="$2" cli="${3:-$1}" raw droid_exit=0
  # grok is NEVER rescued by droid, by name and unconditionally. This is the
  # blueprint-side half of the PR #704 P1 fix; the dispatch-side half lives in
  # `should_escalate_to_droid` (scripts/lib/resolve-cli.sh), which THIS path
  # does not call — the loop below reaches this function directly, so the two
  # guards are independent and both are required.
  #
  # A grok slot reaches here with status not PASS/FAIL, which includes the case
  # that matters: the static preflight PASSED and grok then failed at RUNTIME
  # because the custom sandbox profile could not be applied, so grok refused to
  # start with its protections missing. Rescuing that slot would take the very
  # prompt whose containment just proved unenforceable — and the repo content
  # quoted inside `$FULL_PROMPT` — and send it to droid, a different provider.
  # The protection would invert into the leak it exists to prevent.
  #
  # Keyed on the resolved CLI ($cli), NOT the slot label ($slot). $slot is the
  # historical output-file position (agy/codex/grok — still used below for
  # filenames and log lines) and a route override or BUSDRIVER_REVIEW_CLI=grok
  # can put grok's CLI in the agy or codex slot. Keying on $slot alone would
  # miss that case and forward the prompt (plus quoted repo content) to droid —
  # the exact cross-provider leak this guard exists to close. Reported by
  # Cursor Bugbot on PR #704. Keyed on the CLI NAME, not on grok's failure
  # text: a message matcher would have to enumerate every way a sandbox can
  # fail to apply, and any message it did not anticipate fails OPEN into
  # exactly this forward. Accepted cost is that an ordinary transient grok
  # failure gets no droid stand-in — the voice is simply reported failed,
  # matching the dispatch-side rule.
  # Return 2 (not 1) here: no droid attempt was made — the one-droid-voice cap
  # was never spent — so the caller must keep scanning for a later failed slot
  # instead of stopping. A route override can place grok's CLI in reviewer 1
  # or 2 (Cursor Bugbot + Codex, PR #704 round 2): if the caller unconditionally
  # stopped after this exclusion, a later genuinely-rescuable non-grok slot
  # would never get its droid attempt even though droid was never launched.
  if [[ "$cli" == "grok" ]]; then
    log_warning "  grok failed at runtime → NOT rescued via droid (cross-provider containment, PR #704)"
    return 2
  fi
  raw=$(get_review_file "${slot}-droid-raw.txt")
  # Carry over any findings #714's salvage recovered for this slot. Without
  # this the rescue's own artifact replaces them wholesale and the very
  # findings the salvage exists to preserve are deleted a few lines before
  # the arbiter reads them. They keep their own `.reviewer` tag through the
  # droid retag below, so the two voices stay distinguishable.
  #
  # Read from the salvage's out-of-band sidecar, NEVER from the artifact. The
  # exit-0 path writes model-authored JSON through verbatim, so any in-artifact
  # provenance — an `.issues[].reviewer` tag, a `metadata.salvaged_status` —
  # is forgeable by the payload: a reviewer exiting 0 with a parseable
  # NON-verdict could stamp it and ride issues that passed no completeness
  # check into the rescued artifact, where before #714 the droid artifact
  # simply replaced them. The sidecar is written only by the salvage, only
  # after its check, and its round key is rejected below when stale.
  # (Codex + the litmus reviewer, PR #738.)
  local _prev_issues='[]'
  if [[ -f "${out}.salvaged" ]]; then
    _prev_issues=$(jq -c --arg rid "$RUN_ID" --argjson iter "${CURRENT_ITERATION:-1}" \
      'if .run_id==$rid and .iteration==$iter then [(.issues // [])[] | select(.reviewer != null)] else [] end' \
      "${out}.salvaged" 2>/dev/null || echo '[]')
  fi
  [[ -n "$_prev_issues" ]] || _prev_issues='[]'
  log_warning "  ${slot} failed at runtime → retrying once via droid"
  execute_review "droid" "$FULL_PROMPT" > "$raw" 2>&1 || droid_exit=$?
  if [[ "$droid_exit" -ne 0 ]]; then
    log_warning "  droid rescue ${slot}: exit $droid_exit — keeping error entry"; return 1
  fi
  # Keep the extractor's stderr reason: "never found the JSON" and "found it and
  # it is malformed" were indistinguishable in the log while a fence-shaped
  # payload silently lost every rescue for four sessions (#503).
  local _x_err=""
  if ! _x_err=$(python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$raw" 2>&1 > "${out}.pending"); then
    rm -f "${out}.pending"
    log_warning "  droid rescue ${slot}: ${_x_err:-extraction failed} — keeping error entry"; return 1
  fi
  if ! jq -e '(.status=="PASS" or .status=="FAIL") and (.issues|type=="array")' "${out}.pending" >/dev/null 2>&1; then
    rm -f "${out}.pending"; log_warning "  droid rescue ${slot}: no usable verdict — keeping error entry"; return 1
  fi
  if jq --arg from "$slot" --arg rid "$RUN_ID" --argjson iter "${CURRENT_ITERATION:-1}" --arg hash "$SPEC_HASH" \
        --argjson prev "$_prev_issues" \
       '.reviewer_id="droid" | .reviewer="droid"
        | (.issues = (((.issues // []) | map(.reviewer="droid")) + $prev))
        | .metadata.carried_salvaged_issues=($prev|length)
        | .metadata.runtime_escalated_from=$from | .metadata.run_id=$rid
        | .metadata.iteration=$iter | .metadata.spec_hash=$hash' \
       "${out}.pending" > "${out}.tagged" 2>/dev/null; then
    mv "${out}.tagged" "$out"; rm -f "${out}.pending"
    log_info "  ${slot}→droid rescue succeeded"; return 0
  fi
  rm -f "${out}.pending" "${out}.tagged"
  log_warning "  droid rescue ${slot}: retag failed — keeping error entry"; return 1
}

# Issue #714: recover a complete verdict from a reviewer that exited non-zero.
# A CLI can print its whole review and then die on shutdown; the exit-0 branch
# below was the ONLY place the extractor ran, so a raw file holding a full
# schema-valid FAIL with 7 substantive findings became an ERROR slot and the
# findings never reached arbitration.
#
# Recovers CONTENT, never COVERAGE. The artifact stays `status: ERROR` with its
# `error` field intact, so `derive_coverage` still reports the slot
# runtime-failed and the droid rescue still treats it as rescuable — exactly as
# before this function existed. What changes is that the reviewer's issues now
# ride along into the arbiter's context instead of being deleted.
#
# That split is the whole safety argument, and it is not cosmetic. This is the
# first site that runs the extractor over a transcript whose reviewer is KNOWN
# to have failed, which inverts the extractor's own safety property: on an
# exit-0 transcript the genuine verdict prints last and wins, while on a failed
# one the genuine verdict is exactly what may be absent. The extractor has a
# documented, deliberately-unfixed hole where a verdict-shaped object quoted
# inside an unpinned command echo is promoted (see
# `test_an_unpinned_echo_still_promotes_its_quoted_pass_preexisting` in
# lib/test_extract_review_json.py), and `_execute_codex` re-emits the WHOLE
# captured transcript — command output included — so a reviewed design document
# that embeds an example verdict can put one there. If a salvaged object could
# fulfil a coverage slot, that document would be authorizing its own gate: three
# apparently-fulfilled lenses and a passing arbiter would grant the marker while
# a reviewer never returned a verdict. Because the slot stays ERROR, the worst a
# forged payload can do is add issues to the arbiter's context — content the
# arbiter already reads straight out of the document, pushing toward blocking,
# never toward a marker.
#
# ONE bounded attempt, fail-closed: the same extractor `_bp_droid_rescue` uses,
# the same complete PASS/FAIL + issues[] check. Attribution is overwritten from
# the RESOLVED cli, never trusted from the payload (the shared prompt schema
# only shows `agy|codex|grok`, so a droid reviewer self-labels `codex` — #714),
# and run_id/iteration/spec_hash/duration are injected as on the exit-0 path.
# `runtime_escalated_from` is DELETED: `derive_coverage` reads it as "a droid
# rescue ran", and nothing was dispatched here.
_bp_salvage_nonzero_verdict() {
  local slot="$1" out="$2" raw="$3" cli="$4" rc="$5" duration="${6:-0}" _x_err=""
  [[ -s "$raw" ]] || return 1
  if ! _x_err=$(python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$raw" 2>&1 > "${out}.pending"); then
    rm -f "${out}.pending"
    log_warning "  ${slot}: exit $rc and ${_x_err:-extraction failed} — keeping error entry"; return 1
  fi
  if ! jq -e '(.status=="PASS" or .status=="FAIL") and (.issues|type=="array")' "${out}.pending" >/dev/null 2>&1; then
    rm -f "${out}.pending"
    log_warning "  ${slot}: exit $rc and no complete verdict in raw output — keeping error entry"; return 1
  fi
  if jq --arg cli "$cli" --arg rid "$RUN_ID" --argjson iter "${CURRENT_ITERATION:-1}" \
        --arg hash "$SPEC_HASH" --argjson rc "$rc" --argjson dur "$duration" \
       '.metadata.salvaged_status = .status
        | .status = "ERROR"
        | .error = "CLI exited non-zero (exit \($rc)) — verdict salvaged from raw output for arbitration; slot NOT counted as coverage (#714)"
        | .reviewer_id=$cli | .reviewer=$cli | (.issues = ((.issues // []) | map(.reviewer=$cli)))
        | del(.metadata.runtime_escalated_from)
        | .metadata.run_id=$rid | .metadata.iteration=$iter | .metadata.spec_hash=$hash
        | .metadata.review_duration_ms=$dur | .metadata.salvaged_exit_code=$rc' \
       "${out}.pending" > "${out}.tagged" 2>/dev/null && mv "${out}.tagged" "$out"; then
    rm -f "${out}.pending"
    # Out-of-band carry-over record for `_bp_droid_rescue`. NOT a field in the
    # artifact: the exit-0 path writes model-authored JSON through verbatim, so
    # any in-artifact marker is forgeable by the payload — a parseable
    # NON-verdict could stamp its own provenance and ride unvalidated issues
    # into the rescued artifact. This file is written only here, only after the
    # completeness check, and is keyed to the round so a leftover from an
    # earlier run or iteration cannot authorize a carry-over either.
    jq -n --arg rid "$RUN_ID" --argjson iter "${CURRENT_ITERATION:-1}" \
          --argjson issues "$(jq -c '.issues // []' "$out" 2>/dev/null || echo '[]')" \
          '{run_id:$rid, iteration:$iter, issues:$issues}' > "${out}.salvaged" 2>/dev/null \
      || rm -f "${out}.salvaged"
    log_warning "  ${slot}: CLI exited $rc but printed a complete verdict — findings salvaged for arbitration (slot still counts as failed, #714)"; return 0
  fi
  rm -f "${out}.pending" "${out}.tagged"
  log_warning "  ${slot}: exit $rc and retag failed — keeping error entry"; return 1
}

# Generate a short run ID for artifact isolation
generate_run_id() {
  local input
  input="$(date +%s)-$$"
  if command -v shasum &>/dev/null; then
    printf '%s' "$input" | shasum -a 256 | cut -c1-8
  elif command -v sha256sum &>/dev/null; then
    printf '%s' "$input" | sha256sum | cut -c1-8
  else
    printf '%s' "$input" | cut -c1-8
  fi
}

# Compute SHA-256 of design spec for freshness contract
# Fallback chain: shasum (macOS) → sha256sum (Linux) → python3
#
# $file is passed via env var — NOT interpolated into the python source
# string — so a path containing `'` or python fragments cannot escape the
# python -c body and execute arbitrary code.
compute_spec_hash() {
  local file="$1"
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
    _CSH_FILE="$file" python3 -c 'import hashlib, os; print(hashlib.sha256(open(os.environ["_CSH_FILE"], "rb").read()).hexdigest())'
  else
    echo "no-hash-tool"
  fi
}

# Parse command line arguments
AUTO_MODE=false
CLAUDE_ONLY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO_MODE=true
      log_info "Auto-iteration mode enabled"
      shift
      ;;
    --skip-claude)
      log_error "--skip-claude flag has been removed (violates three-tier review)."
      log_error "Claude is the arbiter — skipping it removes the convergence signal."
      exit 1
      ;;
    --claude-only)
      CLAUDE_ONLY=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --auto          Auto-iteration mode (iterate until Claude verdict is PASS)"
      echo "  --claude-only   Skip Agy+Codex, only run Phase 3-5 (Claude validation + convergence)"
      echo "  --help          Show this help message"
      echo ""
      echo "Architecture:"
      echo "  1. Agy + Codex review in PARALLEL"
      echo "  2. Claude validates findings against codebase (arbiter)"
      echo "  3. Claude's verdict = convergence signal"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Run with --help for usage information"
      exit 1
      ;;
  esac
done

log_info "=== Design Review (Three-Tier, Claude Arbiter) ==="
if [[ "$AUTO_MODE" == "true" ]]; then
  log_info "Mode: AUTO (iterate until Claude PASS)"
else
  log_info "Mode: INTERACTIVE (pause for Claude validation + human review)"
fi
log_info ""

# Check for state file
STATE_FILE=$(get_state_file)
if [[ ! -f "$STATE_FILE" ]]; then
  log_error "State file not found. Run: bash -p scripts/init-design-review.sh <design_file> first"
  exit 1
fi

# Get design file from state
DESIGN_FILE=$(get_design_file)
log_info "Design file: $DESIGN_FILE"

# ── Task 2 (ADR-D): snapshot this doc's marker tokens BEFORE the review runs ──
# On PASS we prune exactly this snapshot. A token re-armed DURING the review (a
# concurrent edit → new nonce) is NOT in the snapshot, so it survives the prune
# and the existence-keyed reader keeps blocking — the lost-rearm race is killed
# by construction (design test (i)). The key is the physical abspath, so this
# never cross-clears a divergent branch's token in another worktree.
_MARKER_RESOLVER="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/../../..}}/hooks/gate-scripts/lib/resolve-repo-dir.sh"
_MARKER_SNAP=()
_MARKER_RESOLVE_OK=false
if [[ ! -f "$_MARKER_RESOLVER" ]]; then
  # Unset SCRIPT_DIR / plugin root collapses the fallback to "/…" — the resolver
  # won't exist, so prune would be a silent no-op. Warn rather than pretend.
  log_warning "Marker resolver not found at $_MARKER_RESOLVER; token prune will be skipped on PASS (drain manually if needed)."
elif [[ -f "$DESIGN_FILE" ]]; then
  _mk_glob="$(bash -p "$_MARKER_RESOLVER" marker-glob "$DESIGN_FILE" 2>/dev/null || true)"
  if [[ -n "$_mk_glob" ]]; then
    _MARKER_RESOLVE_OK=true
    shopt -s nullglob 2>/dev/null || true
    for _mk_f in "$_mk_glob"*; do _MARKER_SNAP+=("$_mk_f"); done
    shopt -u nullglob 2>/dev/null || true
  else
    log_warning "Could not resolve the marker dir for $DESIGN_FILE; token prune will be skipped on PASS (drain manually if needed)."
  fi
fi

# Compute spec hash for freshness contract (Critic #2)
SPEC_HASH=$(compute_spec_hash "$DESIGN_FILE")
log_info "Spec hash: ${SPEC_HASH:0:12}..."

if [[ "$CLAUDE_ONLY" == "true" ]]; then
  # --claude-only: recover run_id from existing Codex/Agy/Grok outputs
  CODEX_FILE=$(get_review_file "codex.json")
  AGY_FILE=$(get_review_file "agy.json")
  GROK_FILE=$(get_review_file "grok.json")
  RUN_ID=""
  if [[ -f "$CODEX_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$CODEX_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" && -f "$AGY_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$AGY_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" && -f "$GROK_FILE" ]]; then
    RUN_ID=$(jq -r '.metadata.run_id // ""' "$GROK_FILE" 2>/dev/null || echo "")
  fi
  if [[ -z "$RUN_ID" ]]; then
    log_error "--claude-only requires existing Agy/Codex/Grok outputs with run_id."
    log_error "Run without --claude-only first to generate them."
    exit 1
  fi
  # Path-traversal guard (Codex #487): RUN_ID is interpolated into
  # "$STATE_DIR/ultra-oracle/${RUN_ID}-plan-review.md" below (line ~971) to
  # locate the salvaged ultra-oracle advisory. Since RUN_ID here comes from
  # an on-disk reviewer JSON rather than generate_run_id() (which always
  # emits 8 lowercase hex chars, but other callers/tests use looser
  # alphanumeric IDs), an attacker-influenced or corrupted metadata.run_id
  # containing path separators (e.g. "../../../secret") could make the
  # advisory path resolve outside the state directory and get its contents
  # read into the Claude prompt. Allowlist to filename-safe characters
  # (alphanumeric, underscore, hyphen) rather than the stricter generated-ID
  # shape, so this still accepts any legitimately-shaped run_id while
  # rejecting path separators, "..", and other traversal-capable input.
  if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "Recovered run_id '$RUN_ID' contains characters unsafe for use as a path component; refusing to use it."
    exit 1
  fi
  log_info "Mode: CLAUDE-ONLY (Phase 3-5 only)"
  log_info "Recovered run ID: $RUN_ID"
  AGY_AVAILABLE=false
  CODEX_AVAILABLE=false
  GROK_AVAILABLE=false
else
  # Normal mode: generate fresh run ID
  RUN_ID=$(generate_run_id)
  log_info "Run ID: $RUN_ID"

  # Resolve CLIs from config
  log_info "Resolving reviewer CLIs..."
  REVIEWER_1_CLI=$(resolve_role_cli "blueprint-review.reviewer_1")
  REVIEWER_2_CLI=$(resolve_role_cli "blueprint-review.reviewer_2")
  REVIEWER_3_CLI=$(resolve_role_cli "blueprint-review.reviewer_3")
  log_info "  Reviewer 1: $REVIEWER_1_CLI"
  log_info "  Reviewer 2: $REVIEWER_2_CLI"
  log_info "  Reviewer 3: $REVIEWER_3_CLI"

  # Duplicate detection (council-validated decision 4c). For 3 reviewers the
  # simple rule is: if reviewer_2 collides with reviewer_1, run single-reviewer
  # mode (the existing pattern); if reviewer_3 collides with either, we just
  # skip reviewer_3 (one less voice, arbitration proceeds). This avoids
  # combinatorial 3-way duplicate-output copying for an edge case.
  DUPLICATE_MODE=false
  if [[ "$REVIEWER_1_CLI" == "$REVIEWER_2_CLI" && "$REVIEWER_1_CLI" != "none" && "$REVIEWER_1_CLI" != "builtin" && ! "$REVIEWER_1_CLI" =~ ^(missing|unsupported): ]]; then
    DUPLICATE_MODE=true
    log_warning "  Degraded: reviewer_1 and reviewer_2 resolved to $REVIEWER_1_CLI (single-reviewer mode for that pair)"
  fi
  REVIEWER_3_DUPLICATE=false
  if [[ "$REVIEWER_3_CLI" != "none" && "$REVIEWER_3_CLI" != "builtin" && ! "$REVIEWER_3_CLI" =~ ^(missing|unsupported): ]]; then
    # Note: collision check compares RESOLVED PRIMARIES, not the effective
    # running set. Edge case: if reviewer_1==reviewer_2==reviewer_3==droid,
    # DUPLICATE_MODE skips reviewer_2 and REVIEWER_3_DUPLICATE skips
    # reviewer_3, leaving only reviewer_1's single droid run. This is the
    # conservative behavior (avoid running near-identical CLI+prompt twice
    # under different role labels) — a fresh droid run would likely produce
    # near-identical JSON output. If non-deterministic LLM voice multiplication
    # ever becomes desired here, lift this restriction and let DUPLICATE_MODE-
    # skipped slots be backfilled by reviewer_3.
    if [[ "$REVIEWER_3_CLI" == "$REVIEWER_1_CLI" || "$REVIEWER_3_CLI" == "$REVIEWER_2_CLI" ]]; then
      REVIEWER_3_DUPLICATE=true
      log_warning "  Degraded: reviewer_3 ($REVIEWER_3_CLI) duplicates a higher slot — voice skipped (see code comment for the DUPLICATE_MODE+reviewer_3 edge case)"
    fi
  fi

  # Set availability flags for backward compat with rest of script
  AGY_AVAILABLE=false
  CODEX_AVAILABLE=false
  GROK_AVAILABLE=false
  [[ "$REVIEWER_1_CLI" != "none" && "$REVIEWER_1_CLI" != "builtin" && ! "$REVIEWER_1_CLI" =~ ^(missing|unsupported): ]] && AGY_AVAILABLE=true
  [[ "$REVIEWER_2_CLI" != "none" && "$REVIEWER_2_CLI" != "builtin" && ! "$REVIEWER_2_CLI" =~ ^(missing|unsupported): && "$DUPLICATE_MODE" == "false" ]] && CODEX_AVAILABLE=true
  [[ "$REVIEWER_3_CLI" != "none" && "$REVIEWER_3_CLI" != "builtin" && ! "$REVIEWER_3_CLI" =~ ^(missing|unsupported): && "$REVIEWER_3_DUPLICATE" == "false" ]] && GROK_AVAILABLE=true

  # Duplicate mode: after single reviewer runs, its output will be copied to both paths (see post-wait block below)
fi

# ── Coverage provenance helpers (flag: BLUEPRINT_COVERAGE_PROVENANCE, default on) ──
# See docs/plans/DESIGN-blueprint-review-coverage-provenance.md. Records WHICH
# reviewer slots actually ran (vs fell back to droid / collapsed to a duplicate /
# errored) so a degraded run is never silently counted as "3 reviewers ran".
_coverage_enabled() {
  case "${BLUEPRINT_COVERAGE_PROVENANCE:-1}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}
_coverage_role_for_slot() { case "$1" in 1) echo "blueprint-review.reviewer_1" ;; 2) echo "blueprint-review.reviewer_2" ;; 3) echo "blueprint-review.reviewer_3" ;; esac; }
_coverage_file_for_slot() { case "$1" in 1) echo "$AGY_OUTPUT_FILE" ;; 2) echo "$CODEX_OUTPUT_FILE" ;; 3) echo "$GROK_OUTPUT_FILE" ;; esac; }

# persist_dispatch_provenance: NON-claude-only. Capture requested/actual/resolve-
# reason per slot (incl. DUPLICATE override) so --claude-only derivation can read
# them from state without the runtime shell vars. fulfilled finalized in derive_coverage.
persist_dispatch_provenance() {
  _coverage_enabled || return 0
  local n role req act rreason
  for n in 1 2 3; do
    role=$(_coverage_role_for_slot "$n")
    IFS=$'\t' read -r req act rreason < <(describe_role_resolution "$role")
    [[ "$n" == "2" && "${DUPLICATE_MODE:-false}" == "true" ]] && rreason="duplicate"
    [[ "$n" == "3" && "${REVIEWER_3_DUPLICATE:-false}" == "true" ]] && rreason="duplicate"
    update_coverage_slot "$n" "$req" "$act" "" "$rreason"
  done
}

# derive_coverage: BOTH modes. Finalize fulfilled+reason per slot from the reviewer
# JSON (status / run_id / runtime_escalated_from) + persisted resolve-reason, using
# the precedence order. Then recompute coverage_status + append per-iteration history.
derive_coverage() {
  _coverage_enabled || return 0
  _ensure_coverage_fields
  local n file req act rreason jstatus rid esc haserr final fulfilled
  for n in 1 2 3; do
    file=$(_coverage_file_for_slot "$n")
    req=$(get_state_field "reviewer_${n}_requested")
    act=$(get_state_field "reviewer_${n}_actual")
    rreason=$(get_state_field "reviewer_${n}_reason")
    # Persisted resolve-time reason wins first: a slot intentionally skipped or
    # degraded at dispatch (duplicate / explicit-none / missing-cli / unsupported-cli
    # / builtin / resolve-droid-fallback) keeps that reason regardless of any
    # synthesized ERROR-stub artifact written for it in --claude-only mode.
    if [[ -n "$rreason" && "$rreason" != "ok" ]]; then
      final="$rreason"
    elif [[ -z "$file" || ! -s "$file" ]]; then
      final="missing-output"
    elif ! jq -e . "$file" >/dev/null 2>&1; then
      final="invalid-json"
    else
      jstatus=$(jq -r '.status // "ERROR"' "$file" 2>/dev/null)
      rid=$(jq -r '.metadata.run_id // ""' "$file" 2>/dev/null)
      esc=$(jq -r '.metadata.runtime_escalated_from // ""' "$file" 2>/dev/null)
      haserr=$(jq -r 'has("error")' "$file" 2>/dev/null)
      if [[ "$jstatus" == "ERROR" || "$haserr" == "true" ]]; then
        final="runtime-failed"
      elif [[ -n "${RUN_ID:-}" && "$rid" != "$RUN_ID" ]]; then
        # A PASS/FAIL artifact whose run_id is missing or doesn't match the
        # current run is not fresh coverage (freshness contract) — never fulfilled.
        final="stale"
      elif [[ -n "$esc" && "$esc" != "null" ]]; then
        final="runtime-droid-rescue"
      elif [[ "$jstatus" == "PASS" || "$jstatus" == "FAIL" ]]; then
        final="ok"
      else
        final="runtime-failed"
      fi
    fi
    fulfilled="false"; [[ "$final" == "ok" ]] && fulfilled="true"
    update_coverage_slot "$n" "$req" "$act" "$fulfilled" "$final"
  done
  recompute_coverage_status
  append_coverage_history "$(get_state_field fulfilled_lens_count)"
}

# record_coverage_finalize: at terminal sites. Once-guarded. Emits the COVERAGE
# summary line + appends ONE cross-review trend entry. The durable doc-marker is
# written separately at the PASS-marker site (co-located with the verdict marker).
record_coverage_finalize() {
  _coverage_enabled || return 0
  [[ "${COVERAGE_FINALIZED:-0}" == "1" ]] && return 0
  COVERAGE_FINALIZED=1
  local cstatus ccount detail n r slug
  cstatus=$(get_state_field "coverage_status")
  ccount=$(get_state_field "fulfilled_lens_count")
  [[ -z "$cstatus" ]] && return 0
  detail=""
  for n in 1 2 3; do
    r=$(get_state_field "reviewer_${n}_reason")
    [[ -n "$r" && "$r" != "ok" ]] && detail="${detail:+$detail }reviewer_${n}=${r}"
  done
  if [[ "$cstatus" == "DEGRADED" ]]; then
    log_warning "  COVERAGE: DEGRADED — ${ccount}/3 lenses (${detail})"
  else
    log_info "  COVERAGE: FULL — ${ccount}/3 lenses"
  fi
  append_to_state "COVERAGE: ${cstatus} ${ccount}/3 ${detail}"
  slug=$(get_review_slug "$DESIGN_FILE")
  append_coverage_trend "$slug" "$ccount"
}

# Main iteration loop
while true; do
  CURRENT_ITERATION=$(get_current_iteration)
  MAX_ITERATIONS=$(get_max_iterations)

  log_info ""
  log_info "=== Iteration $CURRENT_ITERATION of $MAX_ITERATIONS ==="
  log_info ""

  # Check if max iterations reached
  if is_max_iterations_reached; then
    log_warning "Maximum iterations ($MAX_ITERATIONS) reached"
    log_info "Design review did not converge. Human intervention required."
    log_info "Options: fix issues and re-run, or create $STATE_DIR/skip-design-review.local in terminal."
    record_coverage_finalize
    mark_review_complete "max_iterations_exceeded"
    exit 1
  fi

  if [[ "$CLAUDE_ONLY" == "true" ]]; then
    # --claude-only: skip cleanup and Agy+Codex+Grok, jump straight to Phase 3
    log_info "Claude-only mode: skipping Phase 1-2 (using existing Agy+Codex+Grok outputs)"

    AGY_OUTPUT_FILE=$(get_review_file "agy.json")
    CODEX_OUTPUT_FILE=$(get_review_file "codex.json")
    GROK_OUTPUT_FILE=$(get_review_file "grok.json")
    # Mechanism Witness: bind the path in --claude-only resume too (it is set in
    # the normal-review branch only, but read unconditionally when the arbiter
    # prompt is assembled — under `set -u` an unbound read aborts the resume).
    # A prior iteration's auditor.json is reused if present; otherwise the read
    # site falls back to an "unavailable" stub.
    AUDITOR_OUTPUT_FILE=$(get_review_file "auditor.json")
    # Synthesize "no signal" error artifacts for any missing reviewer files so
    # downstream prompt-build cats always have a valid JSON target. Without
    # this, a missing agy.json or codex.json causes `cat "$AGY_OUTPUT_FILE"`
    # to feed an empty section to Claude, silently dropping that reviewer's
    # voice from arbitration. All three slots get the same treatment.
    [[ -f "$AGY_OUTPUT_FILE" ]] || \
      create_error_json "agy" "CLI not available (claude-only mode; no prior agy output)" > "$AGY_OUTPUT_FILE"
    [[ -f "$CODEX_OUTPUT_FILE" ]] || \
      create_error_json "codex" "CLI not available (claude-only mode; no prior codex output)" > "$CODEX_OUTPUT_FILE"
    [[ -f "$GROK_OUTPUT_FILE" ]] || \
      create_error_json "grok" "CLI not available (claude-only mode; no prior grok output)" > "$GROK_OUTPUT_FILE"
    AGY_STATUS=$(jq -r '.status' "$AGY_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    GROK_STATUS=$(jq -r '.status' "$GROK_OUTPUT_FILE" 2>/dev/null || echo "ERROR")
    DESIGN_CONTENT=$(cat "$DESIGN_FILE")
    REVIEW_START=$(millis)
  else

  # ── Critic #1: Clean stale outputs from previous iteration ────────
  # Decision 7 (ADR 0003): claude.json is NOT preserved across full iterations.
  # The reviewer artifacts are deleted and re-rolled below, so any existing
  # verdict was rendered against reviews that are about to disappear —
  # the pre-v3.3 spec_hash-only preservation let a stale verdict converge a
  # re-run on reviews it never saw. The legitimate pre-written-verdict flow is
  # --claude-only, which skips this cleanup and recovers run_id from the
  # reviewer artifacts on disk — meaningful because the arbiter is dispatched
  # against those same artifacts (the script cannot itself enforce that
  # correspondence end-to-end; see ADR 0003 "Orchestration responsibility").
  log_info "Cleaning stale artifacts..."
  rm -f "$(get_review_file "agy.json")" \
        "$(get_review_file "agy-raw.txt")" \
        "$(get_review_file "agy.json.pending")" \
        "$(get_review_file "codex.json")" \
        "$(get_review_file "codex-raw.txt")" \
        "$(get_review_file "codex.json.pending")" \
        "$(get_review_file "grok.json")" \
        "$(get_review_file "grok-raw.txt")" \
        "$(get_review_file "grok.json.pending")" \
        "$(get_review_file "auditor.json")" \
        "$(get_review_file "auditor-raw.txt")" \
        "$(get_review_file "claude.json")" \
        "$(get_review_file "claude.json.pending")" \
        "$(get_review_file "claude-validation-prompt.txt")" \
        "$(get_review_file "consensus.json")" \
        "$(get_review_file "decisions.json")" \
        "$(get_review_file "autofix-log.json")" \
        "$(get_review_file "autofix-summary.json")" \
        "$(get_review_file "report.txt")" \
        2>/dev/null || true
  log_info "  Stale artifacts cleared"

  # ── Optional ultra-oracle auxiliary advisory: dispatch in background (parallel) ──
  # Opt-in; visible best-effort. Capture the TYPED status (a skip writes no .rc).
  # Never in --claude-only mode (no design re-transmitted when the operator chose Claude-only).
  if [ "$CLAUDE_ONLY" != "true" ] && command -v ultra_oracle_surface_enabled >/dev/null 2>&1 && ultra_oracle_surface_enabled blueprintReview; then
    ULTRA_ORACLE_ADVISORY_FILE="$STATE_DIR/ultra-oracle/${RUN_ID}-plan-review.md"
    rm -f "$ULTRA_ORACLE_ADVISORY_FILE" "$ULTRA_ORACLE_ADVISORY_FILE.rc" "$ULTRA_ORACLE_ADVISORY_FILE.hint" \
          "$ULTRA_ORACLE_ADVISORY_FILE.dispatch.err" 2>/dev/null || true
    # stderr is deliberately NOT discarded here (#501). It is the only carrier of
    # the adapter's stale-browser-lock recovery pointer ("... remove it to unblock:
    # rm -f '<lockfile>'", ultra-oracle.sh ~:772). The shared lock has no
    # auto-reclaim, so swallowing that message left the operator with a wedged
    # surface and no instruction. Adapter noise on stderr is the price.
    ULTRA_ORACLE_DISPATCH_STATUS="$(ultra_oracle_consult --mode background --slug "ultra oracle plan review" \
      --out "$ULTRA_ORACLE_ADVISORY_FILE" --context "$DESIGN_FILE" \
      --prompt "You are an auxiliary design reviewer. Review this implementation plan for architectural risks, missing decomposition, and underspecified steps. Be concise." || true)"
    # Absolute deadline for the .rc poll below, anchored at DISPATCH (#501).
    # The poll used to start a FRESH `cap + 90` after the reviewers finished. That
    # was harmless while the dispatch blocked (the child wrote .rc as its last act,
    # so .rc always existed by then and the poll was a no-op). Now that the dispatch
    # returns immediately, the consult runs concurrently with the reviewers, and a
    # fresh budget would ADD to the reviewer window — worst case reviewers + cap + 90,
    # i.e. worse than before. Anchoring at dispatch credits the concurrent time.
    if [ "$ULTRA_ORACLE_DISPATCH_STATUS" = "dispatched" ]; then
      ULTRA_ORACLE_DEADLINE=$(( $(date +%s) + $(ultra_oracle_timeout_cap) + $(_uora_rc_grace) ))
    fi
  fi

  # Read design file content and build prompt
  DESIGN_CONTENT=$(cat "$DESIGN_FILE")
  PROMPT=$(cat "$SCRIPT_DIR/../prompts/comprehensive_review_prompt.txt")
  FULL_PROMPT="$PROMPT

Document to review:
---
$DESIGN_CONTENT
---"

  # Pre-execution safety warning whenever grok will be invoked, regardless
  # of which reviewer slot it landed in. Gate checks ALL three reviewer
  # CLIs because a route override or BUSDRIVER_REVIEW_CLI could put grok
  # into reviewer_1 or reviewer_2 (not just reviewer_3). Printed BEFORE
  # the subshell stderr redirect so the operator sees it in real time —
  # the warning inside execute_review's grok case is captured into the
  # per-reviewer raw file and only visible if the file is inspected.
  # Suppressible via BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1.
  if [[ "${BUSDRIVER_GROK_QUIET_SANDBOX_WARN:-0}" != "1" ]] && \
     [[ "$REVIEWER_1_CLI" == "grok" || "$REVIEWER_2_CLI" == "grok" || "$REVIEWER_3_CLI" == "grok" ]]; then
    log_warning "  grok dispatch in blueprint-review: containment is --sandbox busdriver-review, a custom kernel profile that refuses to start if it cannot be enforced (reads confined to CWD) + --deny Bash/Edit/MCPTool (shell, writes and MCP denied) — all dispatcher-side; the grok user-config is NOT part of the boundary. RESIDUAL: network egress is not blocked on macOS and grok's web tools stay open, so CWD-readable content can still leave. Design-document content flows through this path — review the dispatch.sh grok-case comment for the full threat model. Set BUSDRIVER_GROK_QUIET_SANDBOX_WARN=1 to suppress."
  fi

  # ── Phase 1: Launch Agy + Codex + Grok in PARALLEL ────────────
  log_info "Phase 1: Launching Agy + Codex + Grok reviews in parallel..."

  AGY_OUTPUT_FILE=$(get_review_file "agy.json")
  CODEX_OUTPUT_FILE=$(get_review_file "codex.json")
  GROK_OUTPUT_FILE=$(get_review_file "grok.json")

  REVIEW_START=$(millis)

  # Blueprint caps droid at one voice, so disable codex's internal _execute_codex
  # droid fallback during Phase 1 — the single post-run rescue below owns the one
  # droid slot (codex could otherwise become a hidden second droid). Codex's own
  # transient retries still run. Covers codex in ANY reviewer slot.
  export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1

  # Blueprint review is a gate of record — raise the per-reviewer retry budget to
  # 5 (the most important paths get more patience before the single droid rescue
  # fires). Covers codex (LITMUS_CODEX_RETRIES) and agy/grok (BUSDRIVER_CLI_RETRIES
  # via execute_review's retry wrapper). `:-5` respects an explicit operator
  # override exported in the parent shell.
  export LITMUS_CODEX_RETRIES="${LITMUS_CODEX_RETRIES:-5}"
  export BUSDRIVER_CLI_RETRIES="${BUSDRIVER_CLI_RETRIES:-5}"

  # Same argument for the reasoning tier: a gate of record declares its own tier
  # rather than inheriting whatever `~/.codex/config.toml` says this week (it said
  # `high` on 2026-07-27 while the sibling PR gate's message claimed xhigh — the
  # drift that motivated this pin). Mirrors litmus PR mode; the pre-commit path is
  # deliberately left on the CLI default.
  #
  # FORCED, NOT `:-xhigh`: an ambient value is repo-injectable via a committed
  # `.claude/settings.json` `env` block (#325 / ADR 0016), and the design document
  # under review must not get to weaken its own reviewer to `minimal`.
  export LITMUS_CODEX_EFFORT=xhigh

  # agy reviews headless (--print) and cannot prompt for tool permission, so
  # without --dangerously-skip-permissions every read_file/command request auto-
  # denies and the agy slot dies, silently dropping coverage below FULL and
  # withholding the PASS marker (#424). execute_review gates that flag on this
  # opt-in so the SHARED litmus path (arbitrary/untrusted diffs) stays sandbox-
  # only; blueprint-review opts in because the reviewed artifact is an operator-
  # authored design doc and agy stays --sandbox-contained (writes/network blocked).
  export BUSDRIVER_AGY_REVIEW_SKIP_PERMS="${BUSDRIVER_AGY_REVIEW_SKIP_PERMS:-1}"

  # Run Agy (reviewer 1) in background
  (
    if [[ "$AGY_AVAILABLE" == "true" ]]; then
      AGY_RAW_FILE=$(get_review_file "agy-raw.txt")
      AGY_START=$(millis)

      # Capture exit code per execute_review contract (exit 3 = BUILTIN_FALLBACK)
      REVIEWER_EXIT=0
      execute_review "$REVIEWER_1_CLI" "$FULL_PROMPT" > "$AGY_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        AGY_END=$(millis)
        AGY_DURATION=$((AGY_END - AGY_START))

        # Surface the extractor's reason instead of discarding it: "never found
        # the JSON" and "found it and it is malformed" were indistinguishable in
        # the log, which is how #503 stayed invisible for four sessions.
        if _x_err=$(python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$AGY_RAW_FILE" 2>&1 > "${AGY_OUTPUT_FILE}.pending"); then
          # Inject freshness metadata (Critic #2)
          # Validates JSON has expected structure before injecting.
          # All values are passed via env vars (single-quoted python -c source
          # string) so paths or hash strings containing `'` cannot escape into
          # the python body.
          # || true: don't let injection failure kill subshell under set -e
          _MIM_PENDING="${AGY_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$AGY_DURATION" \
          python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    print("Skipping metadata injection: unexpected JSON structure", file=sys.stderr)
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' 2>/dev/null || true
          mv "${AGY_OUTPUT_FILE}.pending" "$AGY_OUTPUT_FILE"
        else
          create_error_json "agy" "Output was not valid JSON: ${_x_err:-no detail}" > "$AGY_OUTPUT_FILE"
        fi
      # #714: ANY non-zero exit may still have printed a complete verdict —
      # exit 3 included. `_execute_codex` re-emits the captured CLI output on
      # stderr and THEN returns 3, and this block captures 2>&1, so the codex
      # reviewer's lost verdict arrives here rather than on the ordinary path.
      # One bounded, fail-closed salvage attempt ahead of both error branches.
      # Probed as a condition on purpose (SC2310): a failed salvage must fall
      # through to the error branches, never abort the subshell under `set -e`.
      elif _bp_salvage_nonzero_verdict "agy" "$AGY_OUTPUT_FILE" "$AGY_RAW_FILE" \
             "$REVIEWER_1_CLI" "$REVIEWER_EXIT" "$(( $(millis) - AGY_START ))"; then
        :
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "agy" "CLI unavailable (builtin fallback — retry exhaustion)" > "$AGY_OUTPUT_FILE"
      else
        create_error_json "agy" "CLI execution failed (exit $REVIEWER_EXIT)" > "$AGY_OUTPUT_FILE"
      fi
    else
      create_error_json "agy" "CLI not available" > "$AGY_OUTPUT_FILE"
    fi
  ) &
  AGY_PID=$!

  # Run Codex in background
  (
    if [[ "$CODEX_AVAILABLE" == "true" ]]; then
      CODEX_RAW_FILE=$(get_review_file "codex-raw.txt")
      CODEX_START=$(millis)

      # Capture exit code per execute_review contract (exit 3 = BUILTIN_FALLBACK)
      REVIEWER_EXIT=0
      execute_review "$REVIEWER_2_CLI" "$FULL_PROMPT" > "$CODEX_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        CODEX_END=$(millis)
        CODEX_DURATION=$((CODEX_END - CODEX_START))

        # Surface the extractor's reason instead of discarding it: "never found
        # the JSON" and "found it and it is malformed" were indistinguishable in
        # the log, which is how #503 stayed invisible for four sessions.
        if _x_err=$(python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$CODEX_RAW_FILE" 2>&1 > "${CODEX_OUTPUT_FILE}.pending"); then
          # Inject freshness metadata (Critic #2)
          # Validates JSON has expected structure before injecting.
          # All values are passed via env vars (single-quoted python -c source
          # string) so paths or hash strings containing `'` cannot escape into
          # the python body.
          # || true: don't let injection failure kill subshell under set -e
          _MIM_PENDING="${CODEX_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$CODEX_DURATION" \
          python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    print("Skipping metadata injection: unexpected JSON structure", file=sys.stderr)
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' 2>/dev/null || true
          mv "${CODEX_OUTPUT_FILE}.pending" "$CODEX_OUTPUT_FILE"
        else
          create_error_json "codex" "Output was not valid JSON: ${_x_err:-no detail}" > "$CODEX_OUTPUT_FILE"
        fi
      # #714: ANY non-zero exit may still have printed a complete verdict —
      # exit 3 included. `_execute_codex` re-emits the captured CLI output on
      # stderr and THEN returns 3, and this block captures 2>&1, so the codex
      # reviewer's lost verdict arrives here rather than on the ordinary path.
      # One bounded, fail-closed salvage attempt ahead of both error branches.
      # Probed as a condition on purpose (SC2310): a failed salvage must fall
      # through to the error branches, never abort the subshell under `set -e`.
      elif _bp_salvage_nonzero_verdict "codex" "$CODEX_OUTPUT_FILE" "$CODEX_RAW_FILE" \
             "$REVIEWER_2_CLI" "$REVIEWER_EXIT" "$(( $(millis) - CODEX_START ))"; then
        :
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "codex" "CLI unavailable (builtin fallback — retry exhaustion)" > "$CODEX_OUTPUT_FILE"
      else
        create_error_json "codex" "CLI execution failed (exit $REVIEWER_EXIT)" > "$CODEX_OUTPUT_FILE"
      fi
    else
      create_error_json "codex" "CLI not available" > "$CODEX_OUTPUT_FILE"
    fi
  ) &
  CODEX_PID=$!

  # Run Grok (reviewer 3) in background — clone of the Codex block above with
  # s/CODEX/GROK/g and s/codex/grok/g. Mirrors execute_review contract,
  # JSON-extraction, metadata injection, and error handling. Added 2026-05-26
  # to extend voice-lineage diversity into design review (xAI Grok backend).
  (
    if [[ "$GROK_AVAILABLE" == "true" ]]; then
      GROK_RAW_FILE=$(get_review_file "grok-raw.txt")
      GROK_START=$(millis)

      REVIEWER_EXIT=0
      execute_review "$REVIEWER_3_CLI" "$FULL_PROMPT" > "$GROK_RAW_FILE" 2>&1 || REVIEWER_EXIT=$?

      if [[ "$REVIEWER_EXIT" -eq 0 ]]; then
        GROK_END=$(millis)
        GROK_DURATION=$((GROK_END - GROK_START))

        # Surface the extractor's reason instead of discarding it: "never found
        # the JSON" and "found it and it is malformed" were indistinguishable in
        # the log, which is how #503 stayed invisible for four sessions.
        if _x_err=$(python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$GROK_RAW_FILE" 2>&1 > "${GROK_OUTPUT_FILE}.pending"); then
          _MIM_PENDING="${GROK_OUTPUT_FILE}.pending" \
          _MIM_RUN_ID="$RUN_ID" \
          _MIM_ITERATION="$CURRENT_ITERATION" \
          _MIM_SPEC_HASH="$SPEC_HASH" \
          _MIM_DURATION="$GROK_DURATION" \
          python3 -c '
import json, os, sys
pending = os.environ["_MIM_PENDING"]
with open(pending) as f:
    data = json.load(f)
if not isinstance(data, dict) or "status" not in data:
    print("Skipping metadata injection: unexpected JSON structure", file=sys.stderr)
    sys.exit(0)
data.setdefault("metadata", {})
data["metadata"]["run_id"] = os.environ["_MIM_RUN_ID"]
data["metadata"]["iteration"] = int(os.environ["_MIM_ITERATION"])
data["metadata"]["spec_hash"] = os.environ["_MIM_SPEC_HASH"]
data["metadata"]["review_duration_ms"] = int(os.environ["_MIM_DURATION"])
with open(pending, "w") as f:
    json.dump(data, f, indent=2)
' 2>/dev/null || true
          mv "${GROK_OUTPUT_FILE}.pending" "$GROK_OUTPUT_FILE"
        else
          create_error_json "grok" "Output was not valid JSON: ${_x_err:-no detail}" > "$GROK_OUTPUT_FILE"
        fi
      # #714: ANY non-zero exit may still have printed a complete verdict —
      # exit 3 included. `_execute_codex` re-emits the captured CLI output on
      # stderr and THEN returns 3, and this block captures 2>&1, so the codex
      # reviewer's lost verdict arrives here rather than on the ordinary path.
      # One bounded, fail-closed salvage attempt ahead of both error branches.
      # Probed as a condition on purpose (SC2310): a failed salvage must fall
      # through to the error branches, never abort the subshell under `set -e`.
      elif _bp_salvage_nonzero_verdict "grok" "$GROK_OUTPUT_FILE" "$GROK_RAW_FILE" \
             "$REVIEWER_3_CLI" "$REVIEWER_EXIT" "$(( $(millis) - GROK_START ))"; then
        :
      elif [[ "$REVIEWER_EXIT" -eq 3 ]]; then
        # BUILTIN_FALLBACK: CLI retry exhaustion — degraded mode, not hard error.
        # Arbiter proceeds with fewer external voices.
        create_error_json "grok" "CLI unavailable (builtin fallback — retry exhaustion)" > "$GROK_OUTPUT_FILE"
      else
        create_error_json "grok" "CLI execution failed (exit $REVIEWER_EXIT)" > "$GROK_OUTPUT_FILE"
      fi
    else
      create_error_json "grok" "CLI not available" > "$GROK_OUTPUT_FILE"
    fi
  ) &
  GROK_PID=$!

  # ── Mechanism Witness (AUXILIARY, non-converging) ────────────────
  # A 4th voice that is deliberately NOT a coverage slot. The gate condition is
  # `coverage_status == FULL AND fulfilled_lens_count == 3`; making this a real
  # slot would raise that to 4/4, so any witness stall would WITHHOLD PASS. The
  # backing model (a slow reasoning model by default) was measured stalling silently on a
  # meaningful fraction of generation-heavy prompts, which would convert model
  # flakiness directly into blocked design reviews. Modeled on the UltraOracle
  # witness instead: its verdict reaches the arbiter, it never counts as a lens,
  # and its absence is noted rather than gating. (Internal identifiers keep the
  # `auditor` name — the config route key `blueprint-review.auditor`, auditor.json,
  # AUDITOR_*; only the surface framing is the Mechanism Witness. See ADR 0027.)
  #
  # Findings are LEADS, not verdicts — measured 1 true positive / 1 confident
  # false positive / 1 correct NOTHING-FOUND across three already-passed PRs,
  # with inverted confidence labels. The arbiter must verify before acting.
  AUDITOR_CLI=$(resolve_role_cli "blueprint-review.auditor")
  AUDITOR_OUTPUT_FILE=$(get_review_file "auditor.json")
  AUDITOR_PID=""
  AUDITOR_DEADLINE=0                   # epoch secs; set at dispatch, 0 = nothing in flight
  # Auditor's own budget — the ceiling on how long its dispatch may run AND the
  # bound the post-reviewer reap waits for (see the reap below). Sanitize: it is
  # arithmetic input for the reap's `+10` margin, and a non-numeric env value
  # (repo-injectable via settings.json) would otherwise break `$(( ))`.
  # DEFAULT AND CLAMP 1800s. This WIDENS the 600s DoS bound ADR 0027 accepted,
  # deliberately and on the record — see the 2026-08-03 revision in
  # docs/adr/0027-k3-mechanism-witness-ultimate-tier.md.
  #
  # Be precise about what that bound protects, because it is easy to defend the
  # wrong door. The threat is NOT "a branch injects a large
  # BLUEPRINT_AUDITOR_TIMEOUT" — a branch does not need the env var at all. It
  # only needs the witness to be SLOW, which an adversarial or merely enormous design doc
  # achieves on its own, and then the DEFAULT is what grants the stall. A
  # source-aware ceiling that clamps env-supplied values tighter than the
  # compiled default was tried here and removed: it cannot reduce the worst case,
  # because omitting the variable already reaches it.
  # So the honest statement is the simple one: this reap sits ON THE CRITICAL
  # PATH before the arbiter (Phase 3), and ANY branch under review can hold it
  # for up to this many seconds per round. 1800 accepts a 30-minute worst case
  # where ADR 0027 accepted 10, because the witness was observed timing out at 600 on real
  # design docs and the auxiliary lens was lost on every such round. Accepted for
  # a single-operator repo where the maintainer alone chooses when to run the
  # gate and on which branch; on a multi-contributor repo this belongs at 600.
  # Sizing vs the council Mechanism Witness: council clamps at 900s
  # (skills/council/SKILL.md `COUNCIL_AUDITOR_TIMEOUT`), so at 1800 this is now
  # 2x council, INVERTING the original relationship — blueprint used to be the
  # SMALLER of the two precisely because this reap is on the arbiter's critical
  # path while council's witness runs concurrently with the oracle and adds no
  # serial time. (An earlier version of this comment claimed council was 3600s;
  # that was wrong — 3600 is the ultra-oracle's `timeoutCapSeconds` ceiling, a
  # different budget entirely.) The inversion is deliberate, not harmonization:
  # The witness needs the time here and council does not have the evidence to justify it.
  #
  # HARNESS BUDGET: the operator's BASH_MAX_TIMEOUT_MS must exceed the serial
  # worst case, which is a FORMULA, not a fixed number — it moves with the
  # oracle's configured cap:
  #     attach_preflight + max( reviewers(≤1200) + this reap's marginal add
  #                             + droid rescue(≤1200),
  #                             ultraOracle.timeoutCapSeconds + 90 )
  # attach_preflight is NOT inside either term. In oracle ATTACH mode with a cold
  # Chrome, ultra_oracle_consult runs scripts/ultra-oracle-attach-preflight.sh
  # SYNCHRONOUSLY, and ULTRA_ORACLE_DEADLINE is only anchored AFTER dispatch
  # returns — so the preflight elapses before the oracle's own budget starts
  # counting and is invisible to both terms. Bounded but non-zero: the launch wait
  # is LAUNCH_WAIT_SECONDS=15 plus Chrome teardown, so budget ~20-30s. Zero when
  # Chrome is already warm or attach mode is off.
  # At the shipped oracle cap the left term binds (~3010s ⇒ ~3.0e6 ms); at the
  # documented oracle ceiling of 3600 the RIGHT term binds instead (3690s ⇒
  # ~3.7e6 ms). Size the harness budget from whichever term is larger for YOUR
  # `ultraOracle.timeoutCapSeconds`, not from a remembered constant.
  # This reap does NOT stack a full 1800 on top of the reviewers: AUDITOR_DEADLINE
  # is anchored at DISPATCH (#506, set below), T0 alongside the reviewers, so it
  # adds only ~610s past a worst-case reviewer wait. Do not re-derive it as
  # reviewers+1800+rescue — that over-provisions by ~20 minutes.
  # If the budget is too small the loop does not necessarily die outright: ADR
  # 0030 treats the Bash cap as a foreground-wait boundary and the harness may
  # background an overlong call. Do not rely on that — #547 records a backgrounded
  # round being killed with a 0-byte output, losing three completed reviewer
  # artifacts, because nothing checkpoints them.
  # See SKILL.md's run-command timeout note, #547, ADR 0027, and ADR 0030.
  _AUD_TIMEOUT="${BLUEPRINT_AUDITOR_TIMEOUT:-1800}"
  case "$_AUD_TIMEOUT" in ''|*[!0-9]*) _AUD_TIMEOUT=1800 ;; esac      # non-numeric → default
  # Strip leading zeros so a zero-padded value (0001800 → 1800) is measured by
  # its SIGNIFICANT digits, then cap the length BEFORE `$((10#…))` so an
  # oversized digit string can never reach the arithmetic (where it would wrap
  # 64-bit to some in-range garbage the clamp can't distinguish). Max legal is
  # 1800 (4 digits); ≥8 significant digits (>9,999,999) is well past it AND the
  # 64-bit danger zone → clamp to the max before the arithmetic.
  _AUD_TIMEOUT="${_AUD_TIMEOUT#"${_AUD_TIMEOUT%%[!0]*}"}"
  [[ -z "$_AUD_TIMEOUT" ]] && _AUD_TIMEOUT=0                          # all-zeros → 0 (→ default below)
  [[ "${#_AUD_TIMEOUT}" -ge 8 ]] && _AUD_TIMEOUT=1800                 # >7 sig digits → clamp to max
  _AUD_TIMEOUT=$((10#$_AUD_TIMEOUT))                                  # base-10 on a ≤7-digit value: never octal, never overflow
  # CLAMP — this value gates the reap below, so an unbounded (repo-injectable)
  # BLUEPRINT_AUDITOR_TIMEOUT is still a DoS multiplier: 9999999 would stall
  # arbitration for ~115 days. The clamp bounds the env vector at the same 1800
  # the default already allows, so the override grants no time a branch could not
  # get by simply omitting it — see the threat note above.
  [[ "$_AUD_TIMEOUT" -lt 1 ]] && _AUD_TIMEOUT=1800
  [[ "$_AUD_TIMEOUT" -gt 1800 ]] && _AUD_TIMEOUT=1800
  if [[ "$AUDITOR_CLI" != "none" && "$AUDITOR_CLI" != "builtin" && ! "$AUDITOR_CLI" =~ ^(missing|unsupported): ]]; then
    (
      _aud_raw=$(get_review_file "auditor-raw.txt")
      _aud_exit=0
      # EXPLICIT budget (default 600s, NOT execute_review's 1200s default). This
      # is the witness's own ceiling — the reap below waits for exactly this,
      # not a stingy tail after the reviewers finish, so a slow reasoning model
      # (a slow reasoning model by default) gets its full budget just like the UltraOracle and
      # fable witnesses do. execute_review's internal _portable_timeout still
      # hard-stops the process at this cap, so it can never actually run longer.
      execute_review "$AUDITOR_CLI" "$FULL_PROMPT" "$_AUD_TIMEOUT" > "$_aud_raw" 2>&1 || _aud_exit=$?
      # ATOMIC write: build the JSON in a temp file, then rename into place. A
      # grace-period kill of this background job could otherwise interrupt a
      # direct write and leave a partial auditor.json that `cat` reads happily —
      # arbitration would then see truncated advice instead of the "unavailable"
      # fallback. `mv` on the same filesystem is atomic: the reader sees the old
      # file, the complete new file, or nothing — never a half-written one.
      _aud_tmp="${AUDITOR_OUTPUT_FILE}.tmp.$$"
      if [[ "$_aud_exit" -eq 0 ]] && [[ -s "$_aud_raw" ]]; then
        if ! _x_err=$(python3 "$SCRIPT_DIR/lib/extract_review_json.py" "$_aud_raw" 2>&1 > "$_aud_tmp"); then
          create_error_json "auditor" "unparseable witness output: ${_x_err:-no detail}" > "$_aud_tmp"
        fi
      elif [[ "$_aud_exit" -eq 4 ]]; then
        # rc 4 = SKIPPED (execute_review contract): no `.auditor.model` configured,
        # so the witness never ran. ADR 0027's ABSENT-vs-FAILED distinction — an
        # unset optional config key must not be reported as a failure. The message
        # deliberately contains "not available" so the render below classifies it
        # as absent rather than FAILED.
        create_error_json "auditor" "witness not available — no .auditor.model configured (never ran)" > "$_aud_tmp"
      else
        # Empty output on a clean exit is the observed silent-stall shape — must
        # read as "witness absent", never as "witness found nothing".
        create_error_json "auditor" "witness failed or returned empty (rc=$_aud_exit)" > "$_aud_tmp"
      fi
      mv -f "$_aud_tmp" "$AUDITOR_OUTPUT_FILE" 2>/dev/null || rm -f "$_aud_tmp"
    ) &
    AUDITOR_PID=$!
    # Absolute deadline for the reap below, anchored at DISPATCH (#506). The witness runs
    # CONCURRENTLY with the three reviewers, but `_aud_grace` starts counting only
    # after their `wait`s — so a counter-only bound charges a fresh budget+10 on
    # top of the reviewer window (worst case R + T + 10 on the critical path ahead
    # of the arbiter). Anchoring here credits the concurrent time. Same fix the
    # UltraOracle poll got in #501 (ULTRA_ORACLE_DEADLINE, ~:539).
    AUDITOR_DEADLINE=$(( $(date +%s) + _AUD_TIMEOUT + 10 ))
  else
    create_error_json "auditor" "CLI not available ($AUDITOR_CLI)" > "$AUDITOR_OUTPUT_FILE"
  fi

  # Wait for all three to complete
  log_info "  Waiting for parallel reviews..."
  wait "$AGY_PID" 2>/dev/null || true
  wait "$CODEX_PID" 2>/dev/null || true
  wait "$GROK_PID" 2>/dev/null || true
  # BOUNDED reap for the Mechanism Witness. It waits the witness's OWN budget
  # (_AUD_TIMEOUT + a 10s margin — the same shape as the UltraOracle's `cap+10`
  # poll), NOT a 20s tail after the reviewers finish. The witness is a slow reasoning
  # model; on a real generation-heavy prompt it needs minutes, and the old 20s
  # tail reaped it mid-flight on every run (zero auditor.json ever produced).
  # This still can't stall arbitration unboundedly: execute_review's internal
  # _portable_timeout hard-stops the process at _AUD_TIMEOUT, so this loop only
  # POLLS to that ceiling; the +10 is slack for the child to finish its atomic
  # write. Override with BLUEPRINT_AUDITOR_GRACE to force an earlier reap.
  #
  # TWO bounds, whichever fires first (#506):
  #   - AUDITOR_DEADLINE — absolute, anchored at DISPATCH, so the time the
  #     reviewers already spent counts against the witness's budget instead of
  #     being added to it. This is the bound that matters when the primary
  #     _portable_timeout fails to reap (its perl fallback reparents the child to
  #     init, so the `pgrep -P` tree-kill below cannot reach a TERM-ignoring
  #     process — found during #504 review).
  #   - _aud_grace counter — retained as a backstop. The deadline uses `date +%s`,
  #     which is WALL-CLOCK: a backward NTP step during the window would otherwise
  #     stall this loop. $SECONDS is not monotonic either, so a counter is the only
  #     clock-independent bound available in portable bash. It is also what makes a
  #     shortening BLUEPRINT_AUDITOR_GRACE bite.
  # A zero deadline (nothing dispatched) cannot reach here — the enclosing branch
  # requires a live AUDITOR_PID — but the `-gt 0` guard keeps the loop correct if
  # that ever changes.
  if [[ -n "${AUDITOR_PID:-}" ]]; then
    _aud_grace_cap="${BLUEPRINT_AUDITOR_GRACE:-$(( _AUD_TIMEOUT + 10 ))}"
    case "$_aud_grace_cap" in ''|*[!0-9]*) _aud_grace_cap=$(( _AUD_TIMEOUT + 10 )) ;; esac
    _aud_grace_cap="${_aud_grace_cap#"${_aud_grace_cap%%[!0]*}"}"          # strip leading zeros
    [[ -z "$_aud_grace_cap" ]] && _aud_grace_cap=0                          # all-zeros → 0
    [[ "${#_aud_grace_cap}" -ge 8 ]] && _aud_grace_cap=$(( _AUD_TIMEOUT + 10 ))  # >7 sig digits → default (keeps 10# off oversized input; upper bound re-clamps below)
    _aud_grace_cap=$((10#$_aud_grace_cap))   # base-10 on a ≤7-digit value: never octal, never overflow
    # The override may only SHORTEN the reap, never extend it past the budget+10
    # — a repo-injected BLUEPRINT_AUDITOR_GRACE must not lengthen the stall (this
    # upper bound also corrals any >64-bit wrapped value to <= budget+10).
    [[ "$_aud_grace_cap" -gt $(( _AUD_TIMEOUT + 10 )) ]] && _aud_grace_cap=$(( _AUD_TIMEOUT + 10 ))
    [[ "$_aud_grace_cap" -lt 1 ]] && _aud_grace_cap=1
    _aud_grace=0
    while kill -0 "$AUDITOR_PID" 2>/dev/null; do
      if [[ "$_aud_grace" -ge "$_aud_grace_cap" ]] \
         || { [[ "$AUDITOR_DEADLINE" -gt 0 ]] && [[ "$(date +%s)" -ge "$AUDITOR_DEADLINE" ]]; }; then
        # Kill the whole descendant TREE, not just the subshell — execute_review
        # and opencode run as descendants and would otherwise orphan and keep
        # using the network until their own 300s timeout. Portable recursive
        # walk via `pgrep -P` (no process-group/setsid dependency).
        _kill_tree() {
          local _p="$1" _c
          for _c in $(pgrep -P "$_p" 2>/dev/null); do _kill_tree "$_c"; done
          kill "$_p" 2>/dev/null || true
        }
        _kill_tree "$AUDITOR_PID"
        log_warning "  Mechanism Witness exceeded its budget (${_aud_grace_cap}s reap cap or its dispatch-anchored deadline) — killed its process tree, proceeding without it"
        break
      fi
      sleep 1; _aud_grace=$((_aud_grace + 1))
    done
    wait "$AUDITOR_PID" 2>/dev/null || true
    # A reap-kill (or a crash before the atomic mv) can leave NO auditor.json even
    # though the witness WAS dispatched. Without this, the status summary below reads
    # a missing file as "absent — not dispatched", contradicting the timeout warning
    # just logged and the ran/absent/FAILED contract. Record an explicit failure so
    # the summary reports FAILED (dispatched → timed out/killed), never "not
    # dispatched". Non-gating; the arbiter reads it as an unavailable auxiliary.
    if [[ ! -s "$AUDITOR_OUTPUT_FILE" ]]; then
      create_error_json "auditor" "witness killed at reap limit or produced no output (dispatched, no auditor.json written)" > "$AUDITOR_OUTPUT_FILE"
    fi
  fi

  REVIEW_END=$(millis)
  REVIEW_DURATION=$((REVIEW_END - REVIEW_START))
  log_info "  Both reviews completed in ${REVIEW_DURATION}ms (parallel)"

  # ── Runtime droid fallback (capped at one voice) ─────────────────
  # All 3 reviewers share one prompt, so two droids = duplicate signal. Escalate
  # the FIRST failed reviewer (status not PASS/FAIL) to droid and STOP. Single
  # sequential process → no lock needed. Runs BEFORE the dup-copy so a rescued
  # reviewer_1 propagates to reviewer_2's path. Skipped entirely if droid is
  # ALREADY a voice via a resolve-time availability fallback in any slot —
  # otherwise a runtime rescue would produce a second droid-authored file.
  if is_cli_available droid \
     && [[ "$REVIEWER_1_CLI" != "droid" && "$REVIEWER_2_CLI" != "droid" && "$REVIEWER_3_CLI" != "droid" ]]; then
    for _slot in agy codex grok; do
      case "$_slot" in
        agy)   _so="$AGY_OUTPUT_FILE";   _av="$AGY_AVAILABLE";   _cli="$REVIEWER_1_CLI" ;;
        codex) _so="$CODEX_OUTPUT_FILE"; _av="$CODEX_AVAILABLE"; _cli="$REVIEWER_2_CLI" ;;
        grok)  _so="$GROK_OUTPUT_FILE";  _av="$GROK_AVAILABLE";  _cli="$REVIEWER_3_CLI" ;;
      esac
      [[ "$_av" == "true" ]] || continue
      _st=$(jq -r '.status // "MISSING"' "$_so" 2>/dev/null || echo MISSING)
      [[ "$_st" == "PASS" || "$_st" == "FAIL" ]] && continue   # ran fine — not a runtime failure
      # First failed reviewer that gets an ACTUAL droid attempt: ONE droid
      # attempt total, then stop regardless of outcome. A failed/slow droid
      # must not trigger more long rescue waits (execute_review's timeout is
      # 1200s) — and the cap is one droid voice. $_slot is the output-file
      # position (filenames/logging); $_cli is the RESOLVED CLI that actually
      # ran there — a route override can put grok in the agy or codex slot,
      # so the grok exclusion inside _bp_droid_rescue must key on $_cli, not
      # $_slot (PR #704).
      #
      # rc==2 means _bp_droid_rescue excluded a grok slot WITHOUT launching
      # droid — no rescue attempt was spent, so the one-voice cap is still
      # unspent and the scan must continue to the next failed slot. Only rc==1
      # (a genuine droid attempt that failed) or rc==0 (success) stops the
      # loop. Without this, a route override placing grok in reviewer 1 or 2
      # would consume the loop's single rescue opportunity on a slot that
      # never dispatched droid, starving a later legitimately-rescuable
      # non-grok slot (Cursor Bugbot + Codex, PR #704 round 2).
      # shellcheck disable=SC2310  # rescue handles its own errors; rc captured explicitly
      _rescue_rc=0
      _bp_droid_rescue "$_slot" "$_so" "$_cli" || _rescue_rc=$?
      [[ "$_rescue_rc" -eq 2 ]] && continue
      break
    done
  fi

  # Duplicate mode: copy single reviewer's output to both paths
  if [[ "$DUPLICATE_MODE" == "true" ]]; then
    if [[ -f "$AGY_OUTPUT_FILE" ]] && validate_json_file "$AGY_OUTPUT_FILE" 2>/dev/null; then
      cp "$AGY_OUTPUT_FILE" "$CODEX_OUTPUT_FILE"
      log_info "  Duplicate mode: copied reviewer 1 output to reviewer 2 path"
    fi
  fi

  # ── Phase 2: Validate outputs ────────────────────────────────────
  log_info "Phase 2: Validating review outputs..."

  if ! validate_json_file "$AGY_OUTPUT_FILE"; then
    log_error "Agy output invalid or missing — fail-closed"
    create_error_json "agy" "Output missing or invalid after review" > "$AGY_OUTPUT_FILE"
  fi

  if ! validate_json_file "$CODEX_OUTPUT_FILE"; then
    log_error "Codex output invalid or missing — fail-closed"
    create_error_json "codex" "Output missing or invalid after review" > "$CODEX_OUTPUT_FILE"
  fi

  if ! validate_json_file "$GROK_OUTPUT_FILE"; then
    log_error "Grok output invalid or missing — fail-closed"
    create_error_json "grok" "Output missing or invalid after review" > "$GROK_OUTPUT_FILE"
  fi

  # Freshness check (Critic #2): validate or inject run_id
  for review_file in "$AGY_OUTPUT_FILE" "$CODEX_OUTPUT_FILE" "$GROK_OUTPUT_FILE"; do
    FILE_RUN_ID=$(jq -r '.metadata.run_id // ""' "$review_file" 2>/dev/null || echo "")
    REVIEWER=$(jq -r '.reviewer_id // "unknown"' "$review_file" 2>/dev/null || echo "unknown")
    if [[ -z "$FILE_RUN_ID" ]]; then
      # Missing run_id: try to inject it via jq (fallback if python3 injection failed)
      if jq --arg rid "$RUN_ID" --argjson iter "$CURRENT_ITERATION" --arg hash "$SPEC_HASH" \
        '.metadata.run_id = $rid | .metadata.iteration = $iter | .metadata.spec_hash = $hash' \
        "$review_file" > "${review_file}.tmp" 2>/dev/null; then
        mv "${review_file}.tmp" "$review_file"
        log_warning "Injected missing run_id into $review_file via jq fallback"
      else
        rm -f "${review_file}.tmp"
        log_error "MISSING run_id in $review_file and jq injection failed — fail-closed"
        create_error_json "$REVIEWER" "Missing run_id metadata (freshness contract violation)" > "$review_file"
      fi
    elif [[ "$FILE_RUN_ID" != "$RUN_ID" ]]; then
      log_error "STALE OUTPUT: $review_file has run_id=$FILE_RUN_ID, expected $RUN_ID"
      create_error_json "$REVIEWER" "Stale output from previous run" > "$review_file"
    fi
  done

  AGY_STATUS=$(jq -r '.status' "$AGY_OUTPUT_FILE")
  CODEX_STATUS=$(jq -r '.status' "$CODEX_OUTPUT_FILE")
  GROK_STATUS=$(jq -r '.status' "$GROK_OUTPUT_FILE")

  log_info "  Agy:    $AGY_STATUS ($(jq '.issues | length' "$AGY_OUTPUT_FILE") issues)"
  log_info "  Codex:  $CODEX_STATUS ($(jq '.issues | length' "$CODEX_OUTPUT_FILE") issues)"
  log_info "  Grok:   $GROK_STATUS ($(jq '.issues | length' "$GROK_OUTPUT_FILE") issues)"

  # Mechanism Witness — AUXILIARY, never gates coverage. A one-line status so
  # the operator can always see whether the claim-vs-mechanism voice actually fired
  # (it was silently invisible before — its output only ever reaches the arbiter's
  # context, never a report section). Derived from auditor.json: ERROR shape means
  # absent (opencode unavailable) or failed/timed-out; anything else means it ran,
  # with a best-effort finding count (.issues or .findings).
  if [[ -f "$AUDITOR_OUTPUT_FILE" ]]; then
    _mw_status=$(jq -r '.status // "OK"' "$AUDITOR_OUTPUT_FILE" 2>/dev/null || echo "UNREADABLE")
    if [[ "$_mw_status" == "ERROR" ]]; then
      _mw_err=$(jq -r '.error // "unknown"' "$AUDITOR_OUTPUT_FILE" 2>/dev/null || echo "unknown")
      case "$_mw_err" in
        *"no .auditor.model configured"*) log_info "  Mechanism Witness: absent — no .auditor.model configured (never ran; set it in ~/.claude/busdriver.json to enable)" ;;
        *"not available"*) log_info "  Mechanism Witness: absent — opencode unavailable (no fallback)" ;;
        *)                 log_info "  Mechanism Witness: FAILED — $_mw_err (auxiliary; review unaffected)" ;;
      esac
    elif [[ "$_mw_status" == "UNREADABLE" ]]; then
      log_info "  Mechanism Witness: FAILED — auditor.json present but corrupt/unparseable (auxiliary; review unaffected)"
    else
      _mw_n=$(jq '(.issues // .findings // []) | length' "$AUDITOR_OUTPUT_FILE" 2>/dev/null || echo "?")
      log_info "  Mechanism Witness: ran ($_mw_n findings — LEADS not verdicts, arbiter verifies)"
    fi
  else
    log_info "  Mechanism Witness: absent — no output file (not dispatched)"
  fi

  # Coverage provenance: capture which slots actually ran (non-claude-only only)
  persist_dispatch_provenance
  fi  # end of CLAUDE_ONLY guard (Phase 1-2 skipped in claude-only mode)

  # Coverage provenance: finalize fulfilled/reason from this iteration's outputs (both modes)
  derive_coverage

  # ── Phase 3: Claude validation (arbiter) ──────────────────────────
  log_info "Phase 3: Claude validation (arbiter)..."

  CLAUDE_OUTPUT_FILE=$(get_review_file "claude.json")
  CLAUDE_PROMPT_FILE=$(get_review_file "claude-validation-prompt.txt")

  CLAUDE_START=$(millis)

  CLAUDE_PROMPT=$(cat "$SCRIPT_DIR/../prompts/claude_validation_prompt.txt")

  # Coverage provenance section for the arbiter (empty when flag off)
  COVERAGE_SECTION=""
  if _coverage_enabled; then
    _cs_status=$(get_state_field "coverage_status")
    _cs_count=$(get_state_field "fulfilled_lens_count")
    COVERAGE_SECTION="## Coverage (reviewer provenance for THIS run)"$'\n'
    for _cs_n in 1 2 3; do
      COVERAGE_SECTION+="reviewer_${_cs_n}: requested=$(get_state_field "reviewer_${_cs_n}_requested") actual=$(get_state_field "reviewer_${_cs_n}_actual") fulfilled=$(get_state_field "reviewer_${_cs_n}_fulfilled") reason=$(get_state_field "reviewer_${_cs_n}_reason")"$'\n'
    done
    COVERAGE_SECTION+="Coverage: ${_cs_status} (${_cs_count}/3 fulfilled). Treat UNFULFILLED slots as ABSENT coverage: do NOT weight a duplicate/fallback/errored slot as independent agreement."
  fi

  AGY_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$AGY_OUTPUT_FILE" 2>/dev/null || echo "No issues")
  CODEX_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$CODEX_OUTPUT_FILE" 2>/dev/null || echo "No issues")
  GROK_ISSUES=$(jq -r '.issues[] | "- [\(.severity)] \(.section): \(.description)"' "$GROK_OUTPUT_FILE" 2>/dev/null || echo "No issues")

  # ── In --claude-only, re-point at the advisory the ORIGINAL pass landed on disk (#486) ──
  # The Phase 1-2 dispatch (incl. ultra-oracle) is skipped in claude-only mode, so
  # ULTRA_ORACLE_ADVISORY_FILE is empty here — but the finalizing re-run REBUILDS the
  # arbiter prompt, and without this the whole advisory section is dropped SILENTLY (the
  # inject branch needs the file var set; the warning fallback below is gated off in
  # claude-only). A salvaged (#458) or normal advisory persists at the deterministic
  # RUN_ID path; re-point at it so the inject-or-warn logic runs instead of vanishing.
  # DISPATCH_STATUS != "dispatched" so the wait loop is skipped (the file already landed
  # or never will) — a missing/empty file falls through to the visible WARNING banner.
  #
  # Resolve enablement from USER config DIRECTLY via _read_config_value (always loaded from
  # resolve-cli.sh), NOT the optional adapter's ultra_oracle_surface_enabled — so an adapter
  # that failed to source cannot turn a persisted advisory into a silent drop (the adapter
  # is not needed to just READ the on-disk file). USER config ONLY, mirroring the enablement
  # probe in the warning fallback below: a repo-controlled project config must not flip it.
  if [[ "$CLAUDE_ONLY" == "true" ]] && [[ -z "${ULTRA_ORACLE_ADVISORY_FILE:-}" ]]; then
    _uora_co_cfg="$HOME/$STATE_DIR/busdriver.json"
    _uora_co_en=""
    if [[ -f "$_uora_co_cfg" ]]; then
      _uora_co_en="$(_read_config_value "$_uora_co_cfg" '.ultraOracle.blueprintReview.enabled' 2>/dev/null || true)"
    fi
    case "$(printf '%s' "$_uora_co_en" | tr '[:upper:]' '[:lower:]')" in
      true|1)
        ULTRA_ORACLE_ADVISORY_FILE="$STATE_DIR/ultra-oracle/${RUN_ID}-plan-review.md"
        ULTRA_ORACLE_DISPATCH_STATUS="advisory not harvested before arbiter re-run" ;;
    esac
  fi

  # ── Build the ultra-oracle advisory section (status-aware; only wait if dispatched) ──
  ULTRA_ORACLE_ADVISORY_SECTION=""
  # One-line operator status for the oracle (#502), set by each branch below and
  # emitted once after the section is built. Everything the oracle produces
  # otherwise lands ONLY in the arbiter's prompt file, so "did the oracle fire?"
  # was answerable only by opening claude-validation-prompt.txt — the exact gap
  # ADR 0027 closed for the Mechanism Witness.
  #
  # EMPTY MEANS SILENT, and that is the one deliberate divergence from the witness's line.
  # The witness is always-on, so its "absent" carries information. The oracle is a
  # default-OFF USER-config opt-in, so a line on every review would be noise for
  # everyone who never enabled it. The surrounding code already draws exactly this
  # boundary (disabled -> silent, enabled-but-unloadable -> warn); this inherits
  # it rather than introducing a second rule.
  _uora_status_line=""
  if [ -n "${ULTRA_ORACLE_ADVISORY_FILE:-}" ]; then
    if [ "$ULTRA_ORACLE_DISPATCH_STATUS" = "dispatched" ]; then
      # Grace margin BEYOND the oracle cap: on a real timeout the background child writes
      # .rc/.hint only AFTER _portable_timeout kills oracle at t=cap, so waiting exactly
      # cap races the child and reads no .rc (banner falls to "timeout (no completion)"
      # and drops the #340 hint). +90s lets the marker + hint land AND covers the #458
      # post-cap salvage harvest (ULTRA_ORACLE_SALVAGE_CAP, default 30s) that can run after
      # a full-cap watched run. The common #458 case early-kills in seconds, so this only
      # raises the rare worst-case ceiling, not the typical wait.
      #
      # TWO bounds, exit on whichever fires first (#501):
      #   - ULTRA_ORACLE_DEADLINE — absolute, anchored at DISPATCH, so the time the
      #     reviewers already spent counts against the oracle's budget instead of
      #     being added to it. This is the bound that matters now the dispatch is
      #     genuinely non-blocking.
      #   - _uora_wait counter — retained as a backstop. The deadline uses
      #     `date +%s`, which is WALL-CLOCK (see the same hazard noted at
      #     ultra-oracle.sh ~:455): a backward NTP step during the window would
      #     otherwise stall this loop. $SECONDS is not monotonic either, so a
      #     counter is the only clock-independent bound available in portable bash.
      # A zero/unset deadline (adapter absent, or a status other than "dispatched")
      # cannot reach here — the enclosing branch requires "dispatched" — but the
      # `-gt 0` guard keeps the loop correct if that ever changes.
      _uora_wait=0; _uora_cap=$(( $(ultra_oracle_timeout_cap) + $(_uora_rc_grace) ))
      while [ ! -f "$ULTRA_ORACLE_ADVISORY_FILE.rc" ] \
         && [ "$_uora_wait" -lt "$_uora_cap" ] \
         && { [ "$ULTRA_ORACLE_DEADLINE" -le 0 ] || [ "$(date +%s)" -lt "$ULTRA_ORACLE_DEADLINE" ]; }; do
        sleep 2; _uora_wait=$((_uora_wait + 2))
      done
    fi
    if [[ -s "$ULTRA_ORACLE_ADVISORY_FILE" ]] && [[ -f "$ULTRA_ORACLE_ADVISORY_FILE.rc" ]] && [[ "$(cat "$ULTRA_ORACLE_ADVISORY_FILE.rc")" = "0" ]]; then
      ULTRA_ORACLE_ADVISORY_SECTION="=============================================================================
OPTIONAL ULTRA-ORACLE (ChatGPT Pro) ADVISORY -- AUXILIARY, *NOT* A REVIEWER. There are still exactly THREE reviewers (Agy/Codex/Grok); do NOT count this block as a 4th lens or as independent agreement:
=============================================================================

$(cat "$ULTRA_ORACLE_ADVISORY_FILE")"
      # Size the verdict in LINES, not findings: unlike the witness's auditor.json the oracle
      # advisory is free prose with no countable schema, so a finding count would be
      # invented.
      #
      # `awk END{print NR}`, not `wc -l`: wc counts NEWLINES, so a verdict whose last
      # line has no trailing newline is under-counted — a single-line advisory written
      # without one reports "ran (0 lines)", which reads as an empty verdict. awk's NR
      # counts the final partial line too.
      _uora_n="$(awk 'END{print NR}' "$ULTRA_ORACLE_ADVISORY_FILE" 2>/dev/null | tr -dc '0-9')"
      [ -n "$_uora_n" ] || _uora_n="?"
      _uora_status_line="UltraOracle (ChatGPT Pro): ran ($_uora_n lines -- AUXILIARY, not a reviewer)"
    else
      _uora_rc="$(cat "$ULTRA_ORACLE_ADVISORY_FILE.rc" 2>/dev/null || true)"
      if [ "$ULTRA_ORACLE_DISPATCH_STATUS" != "dispatched" ]; then _uora_term="$ULTRA_ORACLE_DISPATCH_STATUS"
      elif [ "$_uora_rc" = "124" ]; then _uora_term="timeout"
      elif [ -z "$_uora_rc" ]; then _uora_term="timeout (no completion within cap)"
      elif [ "$_uora_rc" != "0" ]; then _uora_term="error (rc=$_uora_rc)"
      else _uora_term="error (empty verdict)"; fi
      # Fold in the adapter's actionable hint (#340) for a known failure (cookie
      # decryption blocked / not-signed-in / Cloudflare) so THIS banner — the one the
      # operator actually sees, since blueprint-review calls the adapter directly rather
      # than via ultra-oracle-run.sh — names the next step, not just a status code.
      _uora_hint="$(cat "$ULTRA_ORACLE_ADVISORY_FILE.hint" 2>/dev/null || true)"
      _uora_suffix=""; [ -n "$_uora_hint" ] && _uora_suffix=" -- $_uora_hint"
      # Surface the dispatch sidecar ON THE CONSOLE. The child writes its own stderr
      # there (adapter `2>>"$out.dispatch.err"`), and its most important payload is
      # the stale-browser-lock recovery pointer — a shared mutex with NO auto-reclaim,
      # so an unseen strand wedges every oracle surface until cleared by hand. The
      # banner above only ever reaches the ARBITER PROMPT (#502), never the operator,
      # so writing the sidecar into it would keep the instruction invisible. log_warning
      # is the one channel the operator actually reads during a run.
      if [ -s "$ULTRA_ORACLE_ADVISORY_FILE.dispatch.err" ]; then
        log_warning "  UltraOracle dispatch stderr ($ULTRA_ORACLE_ADVISORY_FILE.dispatch.err):"
        while IFS= read -r _uora_l; do log_warning "    $_uora_l"; done \
          < <(head -c 4000 "$ULTRA_ORACLE_ADVISORY_FILE.dispatch.err" | head -20)
      fi
      ULTRA_ORACLE_ADVISORY_SECTION="=============================================================================
WARNING: ULTRA-ORACLE ADVISORY FAILED [$_uora_term]$_uora_suffix -- verdict NOT included (visible best-effort; the gate converges on the THREE reviewers Agy/Codex/Grok).
============================================================================="
      # ABSENT vs FAILED, the distinction ADR 0027 drew for the witness: "never ran" must
      # never be reported as a failure, nor a failure as "nothing found".
      #
      # THREE statuses reach here without the oracle ever having run. The advisory
      # FILE variable is assigned BEFORE the consult (see the dispatch site), so a
      # skip does NOT skip this branch — it lands here with no .rc, and a naive
      # `FAILED -- $_uora_term` would report a deliberate operator opt-out as a
      # failure. `ultra_oracle_consult`'s contract (ultra-oracle.sh ~:796) is
      # `ok | skipped:unavailable | skipped:user | timeout | error | dispatched`.
      #
      # Deliberately NOT unified with the arbiter-prompt banner above, which still
      # renders these as FAILED: its wording is asserted by
      # tests/test-blueprint-review-claude-only-oracle-inject.sh and documented in
      # SKILL.md, so correcting it is a wider change than this status line. Tracked
      # separately; the log line is the operator-facing surface and is correct here.
      case "$ULTRA_ORACLE_DISPATCH_STATUS" in
        skipped:user)
          _uora_status_line="UltraOracle (ChatGPT Pro): absent -- operator opt-out ($STATE_DIR/skip-ultra-oracle.local)" ;;
        skipped:unavailable)
          _uora_status_line="UltraOracle (ChatGPT Pro): absent -- oracle CLI not available" ;;
        "advisory not harvested before arbiter re-run")
          _uora_status_line="UltraOracle (ChatGPT Pro): absent -- $ULTRA_ORACLE_DISPATCH_STATUS" ;;
        *)
          _uora_status_line="UltraOracle (ChatGPT Pro): FAILED -- ${_uora_term}${_uora_suffix} (auxiliary; review unaffected)" ;;
      esac
    fi
  elif [ "${CLAUDE_ONLY:-false}" != "true" ]; then
    # The advisory file was never set. Either the surface is disabled (stay silent)
    # OR the optional adapter failed to source while enabled (must warn — never
    # silent). Check config via _read_config_value (always loaded from resolve-cli.sh)
    # so the warning does not depend on the optional adapter's own functions.
    # USER config ONLY (mirrors ultra_oracle_config_get_user): a repo-controlled
    # project config must NOT flip this enablement probe — reading it would
    # contradict the user-config-only opt-in boundary the whole feature enforces
    # (a branch could otherwise surface a misleading "enabled" warning).
    _uora_en=""
    _uora_user_cfg="$HOME/$STATE_DIR/busdriver.json"
    if [ -f "$_uora_user_cfg" ]; then
      _uora_en="$(_read_config_value "$_uora_user_cfg" '.ultraOracle.blueprintReview.enabled' 2>/dev/null || true)"
    fi
    case "$(printf '%s' "$_uora_en" | tr '[:upper:]' '[:lower:]')" in
      true|1)
        ULTRA_ORACLE_ADVISORY_SECTION="=============================================================================
WARNING: ULTRA-ORACLE ADVISORY enabled but the adapter could not be loaded -- verdict NOT included (visible best-effort; gate converges on the THREE reviewers).
============================================================================="
        _uora_status_line="UltraOracle (ChatGPT Pro): FAILED -- adapter could not be loaded (auxiliary; review unaffected)" ;;
    esac
    # No `else` on purpose: surface disabled -> no section AND no status line.
  fi

  # Emit the oracle's one-line status. Unlike the witness line (Phase 2), this sits in
  # Phase 3 because the oracle's outcome is not known until the advisory section is
  # built. Consequence, documented in SKILL.md: it DOES print on --claude-only
  # resumes, where the witness line does not.
  [ -n "$_uora_status_line" ] && log_info "  $_uora_status_line"

  cat > "$CLAUDE_PROMPT_FILE" <<EOF
$CLAUDE_PROMPT

$COVERAGE_SECTION

=============================================================================
FRESHNESS CONTRACT (include in your output metadata):
  run_id: $RUN_ID
  iteration: $CURRENT_ITERATION
  spec_hash: $SPEC_HASH
=============================================================================

DESIGN DOCUMENT TO VALIDATE:
=============================================================================

$DESIGN_CONTENT

=============================================================================
AGY REVIEW RESULTS (Status: $AGY_STATUS):
=============================================================================

$AGY_ISSUES

Full output:
$(cat "$AGY_OUTPUT_FILE")

=============================================================================
CODEX REVIEW RESULTS (Status: $CODEX_STATUS):
=============================================================================

$CODEX_ISSUES

Full output:
$(cat "$CODEX_OUTPUT_FILE")

=============================================================================
GROK REVIEW RESULTS (Status: $GROK_STATUS):
=============================================================================

$GROK_ISSUES

Full output:
$(cat "$GROK_OUTPUT_FILE")

$ULTRA_ORACLE_ADVISORY_SECTION

=============================================================================
MECHANISM WITNESS (opencode) -- AUXILIARY, *NOT* A REVIEWER. There are
still exactly THREE reviewers (Agy/Codex/Grok); do NOT count this block as a 4th
lens or as independent agreement. Its lens is claim-vs-mechanism: places where
the document says one thing and the cited mechanism does another.

TREAT AS LEADS, NOT VERDICTS. Measured across three already-passed PRs: 1 real
defect both Codex-xhigh and the Opus backstop missed, 1 confidently-worded false
positive, 1 correct NOTHING FOUND -- with confidence labels INVERTED (the
hallucination was MEDIUM, the real defect LOW). Verify each claim against the
cited file:line before weighting it. An error/empty block below means the
witness was ABSENT, which is NOT evidence that nothing was found.
=============================================================================

$(cat "$AUDITOR_OUTPUT_FILE" 2>/dev/null || echo '{"status":"ERROR","note":"mechanism witness unavailable"}')

=============================================================================
VALIDATION TASK:
=============================================================================

1. Read the design document and all three reviews (Agy, Codex, Grok). An optional ULTRA-ORACLE advisory block may also appear above; it is AUXILIARY context, NOT a reviewer — the reviewer count is always three, and the advisory must not be counted toward independent agreement.
2. For each issue: validate against codebase, assign validation_type
3. Search for issues they missed (validation_type: new_finding)
4. Output strict JSON with your verdict
5. Include run_id, iteration, spec_hash in metadata

Note: if any reviewer slot was unavailable (CLI not installed or failed),
its output will contain an error field — treat such slots as "no signal"
rather than "PASS". Arbitration proceeds with the reviewers that returned.

IMPORTANT: Use Read, Grep, Glob tools to examine the codebase.
EOF

  log_info "  Validation prompt: $CLAUDE_PROMPT_FILE"

  if [[ "$AUTO_MODE" == "true" ]]; then
    log_info "  Auto mode: Claude validation must be completed by the calling skill."
  elif [[ ! -t 0 ]]; then
    # Non-interactive (piped stdin) — agent invocation.
    # The agent can't write claude.json while this subprocess blocks on read.
    # Exit with code 2 so the calling skill can:
    #   1. Read the prompt file
    #   2. Write claude.json with codebase-grounded validation
    #   3. Re-run with --claude-only (skips artifact cleanup + Phase 1-2)
    log_info ""
    log_info "  Non-interactive stdin detected (agent invocation)."
    if [[ -f "$CLAUDE_OUTPUT_FILE" ]]; then
      log_info "  Found existing Claude output — continuing."
    else
      log_info "  Claude output needed. Write to: $CLAUDE_OUTPUT_FILE"
      log_info "  Then re-run with: --claude-only"
      log_info "  Prompt file: $CLAUDE_PROMPT_FILE"
      mark_review_complete "awaiting_claude_validation"
      exit 2
    fi
  else
    log_info ""
    log_info "  MANUAL STEP: Complete Claude validation with codebase context."
    log_info "  Write output to: $CLAUDE_OUTPUT_FILE"
    log_info "  Press ENTER when done..."
    read -r
  fi

  if [[ ! -f "$CLAUDE_OUTPUT_FILE" ]]; then
    log_error "Claude validation output not found: $CLAUDE_OUTPUT_FILE"
    log_error "Three-tier review requires Claude as arbiter."
    log_info "  1. Read: cat $CLAUDE_PROMPT_FILE"
    log_info "  2. Write output to: $CLAUDE_OUTPUT_FILE"
    log_info "  3. Re-run this script with --claude-only"
    mark_review_complete "awaiting_claude_validation"
    exit 1
  fi

  # MOVED AHEAD OF THE FRESHNESS/JSON GATES (#656, Codex review on bceb00e7). Every
  # exit between here and the verdict classification is fail-CLOSED and takes the
  # script down: the freshness check below (`stale_claude_output`), validate_json_file
  # (`invalid_claude_output`), and the countability guard (`uncountable_claude_output`).
  # While this block sat AFTER them, a truncated or run_id-less claude.json exited at
  # the freshness check and left the prior PASS standing in the document — the exact
  # fail-open this block exists to close, reachable through the guards added to close it.
  # The trigger is "a verdict FILE is present" (checked just above), not "the verdict
  # parsed": a round that has a verdict to judge has already superseded the last one.
  # HOISTED AGAIN (#656): these are now needed by the intake refusal a few lines
  # below (an uncountable verdict must be able to downgrade a stale PASS before it
  # exits), not only by Phase 5. Pure move — they depend only on DESIGN_FILE.
  # Atomic in-place sed via an UNPREDICTABLE mktemp sibling — never a fixed
  # `${DESIGN_FILE}.tmp`/.covtmp name a pre-existing symlink could hijack into
  # truncating an arbitrary target. (Concurrent reviews of the SAME doc are already
  # prevented upstream by the loop's review-pointer guard, so this only needs to be
  # single-writer-safe.) The mode is copied from the source AFTER sed writes the
  # temp — before-write would make a read-only (0444) source's redirect fail — so the
  # replacement keeps the doc's original perms rather than mktemp's 0600. The temp is
  # always removed, including on an mv failure, so no `.dr-edit.*` copy is leaked.
  #
  # HOISTED (#656) out of the approved-only branch below: the parked terminal state
  # added by #656 must also be able to downgrade a stale PASS, and a second copy of
  # this helper is exactly the "third copy drifting" defect this repo already tracks.
  # Pure move — no logic change; it depends only on DESIGN_FILE.
  _dr_atomic_sed() {  # <sed-expr> <file>
    local _e="$1" _f="$2" _d _t _m
    _d=$(dirname -- "$_f") || return 1
    _t=$(mktemp "$_d/.dr-edit.XXXXXX") || return 1
    # `if` guards throughout (never `cmd && ...`): a failing left-of-&& would trip
    # set -e and skip the temp cleanup below.
    if sed "$_e" "$_f" > "$_t"; then
      # Copy the source mode onto the temp (GNU `stat -c` / BSD `stat -f`) before the
      # swap; best-effort, and 0600 is the safe fallback if the mode is unreadable.
      _m=$(stat -c '%a' "$_f" 2>/dev/null || stat -f '%Lp' "$_f" 2>/dev/null || true)
      if [[ -n "$_m" ]]; then chmod "$_m" "$_t" 2>/dev/null || true; fi
      if mv -f "$_t" "$_f"; then return 0; fi
    fi
    rm -f "$_t"
    return 1
  }

  # WHOLE-LINE marker regexes (the writer always emits each marker on its own line).
  # Every detect (grep) and rewrite (sed) below anchors to these so a marker string
  # embedded in PROSE — `... the <!-- design-reviewed: PASS --> marker ...` — is never
  # matched or corrupted. A marker ALONE on its own line is treated as a real marker
  # by BOTH the writer here AND the reader (_doc_reviewed matches any occurrence): this
  # is inherent to the machine-consumed marker design, so a tracked design doc must not
  # place a bare-line marker example (even inside a ``` fence). No ERE-only metachars,
  # so the same pattern is valid in grep BRE and sed BRE.
  # _RE_COV keys on a line STARTING with the coverage prefix (not a complete `-->`),
  # matching the reader's total count — so the upsert/strip below can also REPAIR a
  # truncated/split/malformed stale marker line, not just a well-formed one. `.*$`
  # consumes the rest of that line so the whole line is replaced/deleted. A prefix
  # mid-line in prose is not at line start ⇒ untouched.
  _RE_COV='^[[:space:]]*<!-- design-review-coverage:.*$'
  _RE_PASS='^[[:space:]]*<!-- design-reviewed: PASS -->[[:space:]]*$'
  _RE_PEND='^[[:space:]]*<!-- design-reviewed: PENDING -->[[:space:]]*$'

  # #656: a PASS from a PRIOR run is superseded the moment a new round renders a verdict
  # on this document — the approval branch re-stamps it below if and only if the NEW
  # verdict earns it. Downgrading here, ahead of every fallible per-iteration write
  # (validation, state fields, history appends, the follow-up file), is what makes the
  # withholding paths trustworthy: each of those exits the script under `set -e`, and a
  # failure anywhere between "verdict is in" and "document made honest" would leave a
  # stale PASS standing over a blocking or malformed verdict. The readers
  # (_doc_reviewed / gate_design_pass_honored) honor the DOCUMENT, never state.md, so the
  # document is what has to be fixed first. ONE site ahead of everything fallible, rather
  # than one per withholding branch — the per-branch downgrades below are kept as their
  # own contract (#355 / #663) but are now no-ops in practice.
  #
  # Delegated to marker_ops.py `downgrade-pass` rather than the local grep/sed pair, for
  # the reason #449 already wrote down: a shell strip is byte-level and LF-only, while the
  # authoritative reader parses in TEXT mode where `\r`, `\n` and `\r\n` are ALL line
  # boundaries. On a bare-CR document the shell pattern misses a marker the gate still
  # honors — a stale PASS surviving precisely the check meant to remove it. Downgrading in
  # the reader's own engine is the only way the two cannot diverge.
  _MARKER_OPS="$_PLUGIN_ROOT/hooks/gate-scripts/lib/marker_ops.py"
  if [[ -f "$DESIGN_FILE" ]]; then
    if [[ ! -f "$_MARKER_OPS" ]] || ! command -v python3 >/dev/null 2>&1; then
      # Fail-CLOSED: unable to prove the document does not carry an honored PASS.
      log_error "Cannot reach the marker engine ($_MARKER_OPS) to clear a prior PASS."
      log_error "  Refusing to judge a document whose marker state cannot be normalized."
      exit 1
    fi
    # `-I` (isolated), matching every other marker_ops caller in the tree
    # (check-design-document.sh:271, design-clear.sh:347): the repo being reviewed can
    # ship a PYTHONPATH/sitecustomize, and an authorization control must not run inside
    # an interpreter its subject can furnish.
    if python3 -I "$_MARKER_OPS" downgrade-pass "$DESIGN_FILE"; then
      log_info "  Prior PASS (if any) downgraded to PENDING pending this round's verdict."
    else
      log_error "Could not downgrade the prior PASS in '$DESIGN_FILE'."
      log_error "  Refusing to judge a document that may still read PASS — it would be"
      log_error "  honored whatever this run concludes. Fix the write error, then re-run."
      exit 1
    fi
  fi

  # Freshness check on Claude output (Critic #2)
  # Decision 7 (ADR 0003): the verdict must come from the CURRENT run, with a
  # matching spec_hash. The pre-v3.3 branch accepted a different-run verdict on
  # spec_hash match alone — but reviewer artifacts re-roll every full run, so
  # that let a verdict pass judgment on reviews it never saw. --claude-only
  # recovers RUN_ID from the reviewer artifacts on disk, so the legitimate
  # pre-written-verdict flow still matches; anything else is stale (fail-closed,
  # including missing metadata — the old -n guard let run_id-less verdicts pass).
  if ! FRESHNESS_REASON=$(validate_claude_verdict_freshness "$CLAUDE_OUTPUT_FILE" "$RUN_ID" "$SPEC_HASH" 2>&1); then
    log_error "STALE CLAUDE OUTPUT: $FRESHNESS_REASON"
    log_error "Re-dispatch the arbiter against the current validation prompt, then re-run with --claude-only."
    mark_review_complete "stale_claude_output"
    exit 1
  fi

  # Validate Claude JSON before parsing (fail-closed)
  if ! validate_json_file "$CLAUDE_OUTPUT_FILE"; then
    log_error "Claude output is invalid JSON — fail-closed"
    mark_review_complete "invalid_claude_output"
    exit 1
  fi

  CLAUDE_END=$(millis)
  CLAUDE_DURATION=$((CLAUDE_END - CLAUDE_START))

  # #656 (intake). validate_json_file only proves the file PARSES. A verdict that parses
  # but cannot be COUNTED — `.issues: false`, an object, a string, absent — reaches
  # `jq '.issues | length'` on the next line and aborts the whole script under `set -e`,
  # BEFORE Phase 5 can withhold the PASS or take a stale one away. Refuse it here, where
  # the exit is deliberate and the doc can still be made honest. Same shape the droid
  # rescue already demands of a reviewer verdict (`_bp_droid_rescue`).
  if ! jq -e '(.status == "PASS" or .status == "FAIL") and (.issues | type == "array")' \
       "$CLAUDE_OUTPUT_FILE" >/dev/null 2>&1; then
    log_error "Claude output is not a countable verdict — fail-closed."
    log_error "  Needs a \"status\" of PASS|FAIL and an \"issues\" ARRAY: $CLAUDE_OUTPUT_FILE"
    # Persist the same parked posture the Phase 5 write-site guard uses for this
    # exact reason (arbiter_verdict_uncountable), so a reader of state.md sees a
    # consistent terminal-state contract regardless of which guard caught the
    # uncountable verdict. mark_review_complete only writes status/active.
    update_state_field "progress_status" "\"parked_no_progress\""
    update_state_field "early_stopped" "\"arbiter_verdict_uncountable\""
    mark_review_complete "uncountable_claude_output"
    exit 1
  fi

  CLAUDE_STATUS=$(jq -r '.status' "$CLAUDE_OUTPUT_FILE")
  CLAUDE_ISSUE_COUNT=$(jq '.issues | length' "$CLAUDE_OUTPUT_FILE")
  log_info "  Claude: $CLAUDE_STATUS ($CLAUDE_ISSUE_COUNT issues, ${CLAUDE_DURATION}ms)"

  update_review_statuses "$AGY_STATUS" "$CODEX_STATUS" "$CLAUDE_STATUS" "$GROK_STATUS"

  # ── Phase 4: Progress analysis (Critic #5) ────────────────────────
  # Category-aware convergence: line-level findings (test-code typos, lint, perf)
  # belong to TDD-discovery time and shouldn't block plan review. Scope-expansion
  # findings ("OUT OF SCOPE for this PR", "follow-up") get deferred to a
  # follow-up-issues.md file instead of blocking convergence.
  log_info "Phase 4: Progress analysis..."

  # Categories that are TDD-discoverable — first test run catches these in seconds.
  TDD_DISCOVERABLE_CATEGORIES='["technical-accuracy","bugs","implementation","best-practices","maintainability","performance"]'
  # Suggestion patterns that signal scope-expansion findings (defer to follow-up PR).
  SCOPE_EXPANSION_PATTERN="OUT OF SCOPE|follow-up PR|deferred to follow-up|post-merge|inherited from parent"

  # Plan-blocking counts exclude TDD-discoverable categories AND scope-expansion suggestions.
  #
  # ONE definition of the plan-blocking predicate, parameterised by severity. The
  # counters here AND the #656 write-site guard below both evaluate it — a second
  # hand-written copy is exactly the "third copy drifting" defect this repo tracks.
  # shellcheck disable=SC2016  # $sevs/$tdd/$pat/$c/$s are jq variables, not shell ones
  _PB_FILTER='[.issues[] | select(
      (.severity as $s | $sevs | index($s))
      and .confidence >= 0.5
      and (.category as $c | $tdd | index($c) | not)
      and ((.suggestion // "") | test($pat) | not)
    )] | length'

  # Prints the count. Exits NON-ZERO when the arbiter output cannot be counted
  # (no .issues array, entries jq cannot compare) — callers choose the posture.
  _plan_blocking() {  # <severities-json-array>
    jq --argjson tdd "$TDD_DISCOVERABLE_CATEGORIES" --arg pat "$SCOPE_EXPANSION_PATTERN" \
       --argjson sevs "$1" "$_PB_FILTER" "$CLAUDE_OUTPUT_FILE"
  }

  # The `|| echo 0` default below is a FAIL-OPEN, left in place deliberately: these
  # counts only steer WHICH convergence branch runs, and the authorization to stamp
  # PASS is re-derived fail-CLOSED at the write site (_arbiter_earns_pass).
  # shellcheck disable=SC2310  # the || is the point: an uncountable verdict must not
  # abort here, it must fall through to the fail-CLOSED write-site guard below.
  PLAN_BLOCKING_HIGH=$(_plan_blocking '["high"]' 2>/dev/null || echo 0)
  # shellcheck disable=SC2310
  PLAN_BLOCKING_MEDIUM=$(_plan_blocking '["medium"]' 2>/dev/null || echo 0)

  # #656 (write-site invariant): whether the arbiter's verdict EARNS a PASS marker,
  # re-derived from claude.json at the decision point rather than trusted from the
  # PROGRESS_STATUS string computed 200 lines earlier and mutated by three branches.
  #
  # The counters above default to 0 on ANY jq failure, and their select() silently
  # drops entries jq cannot compare. So a syntactically valid arbiter verdict the
  # loop cannot actually COUNT reads as "zero findings" and stamps PASS. Measured on
  # this tree before the fix — all four stamped `design-reviewed: PASS` and exited 0
  # while claude.json said `"status": "FAIL"`:
  #   * .issues absent / null
  #   * 7 HIGH entries with no `confidence` field   (the shape #656 was filed on)
  #   * 7 HIGH entries spelled "High"
  #   * status FAIL enumerating no issues at all
  # Same defect class #663 closed on the trajectory path: a NON-verdict (there "no
  # progress", here "uncountable") laundered into a quality verdict.
  #
  # Fail-CLOSED — every conjunct must be provably true or the PASS is withheld.
  # `confidence` is required on high/medium ONLY: LOW_COUNT has never required it,
  # so demanding it on lows would reject verdicts that are legitimate today. It must also
  # be IN RANGE: the counters filter on `>= 0.5`, so an out-of-band `-1` (or `1.5`, which
  # over-counts) is silently dropped exactly like a missing field — numeric-type alone is
  # not enough, the documented 0.0-1.0 domain is what makes the comparison meaningful. A FAIL
  # that enumerates nothing contradicts itself (the arbiter prompt's own rule is
  # "status FAIL if any high/medium with confidence >= 0.5"), so it is not countable
  # either. Deferral semantics are UNCHANGED: a FAIL whose findings are all
  # TDD-discoverable or scope-expansion still has zero plan-blocking and still passes.
  _arbiter_earns_pass() {
    jq -e \
      --argjson tdd "$TDD_DISCOVERABLE_CATEGORIES" \
      --arg pat "$SCOPE_EXPANSION_PATTERN" \
      --argjson sevs '["high","medium"]' \
      '(.status == "PASS" or .status == "FAIL")
       and (.issues | type == "array")
       and (.status == "PASS" or (.issues | length) > 0)
       and (all(.issues[]; .severity as $s | ["high","medium","low"] | index($s)))
       and (all(.issues[] | select(.severity != "low");
                (.confidence | type == "number") and .confidence >= 0 and .confidence <= 1))
       and (('"$_PB_FILTER"') == 0)' \
      "$CLAUDE_OUTPUT_FILE" >/dev/null 2>&1
  }

  HIGH_COUNT=$(jq '[.issues[] | select(.severity == "high" and .confidence >= 0.5)] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)
  MEDIUM_COUNT=$(jq '[.issues[] | select(.severity == "medium" and .confidence >= 0.5)] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)
  LOW_COUNT=$(jq '[.issues[] | select(.severity == "low")] | length' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo 0)

  DEFERRED_COUNT=$(( (HIGH_COUNT + MEDIUM_COUNT) - (PLAN_BLOCKING_HIGH + PLAN_BLOCKING_MEDIUM) ))
  # Clamp to >= 0 — if the two jq groups error-default differently (one returns
  # 0, the other returns real values), the subtraction can underflow.
  if [[ "$DEFERRED_COUNT" -lt 0 ]]; then
    DEFERRED_COUNT=0
  fi

  # Write deferred issues to a follow-up file so the user sees what was set aside.
  if [[ "$DEFERRED_COUNT" -gt 0 ]]; then
    FOLLOWUP_FILE=$(get_review_file "follow-up-issues.md")
    {
      printf '# Deferred Findings (TDD-discoverable + scope-expansion)\n\n'
      printf 'These findings were not blocked at design-review time because they fall into one of two buckets:\n\n'
      printf '1. **TDD-discoverable**: line-level concerns (test stubs, lint, perf) that the first test run catches in seconds.\n'
      printf '2. **Scope-expansion**: legitimate findings explicitly marked as "OUT OF SCOPE for this PR" or "follow-up PR" by the arbiter.\n\n'
      printf 'Address them during implementation (TDD) or open a follow-up issue (scope-expansion).\n\n'
      printf -- '---\n\n'
      jq -r --argjson tdd "$TDD_DISCOVERABLE_CATEGORIES" --arg pat "$SCOPE_EXPANSION_PATTERN" \
        '.issues[] | select(
          (.severity == "high" or .severity == "medium")
          and .confidence >= 0.5
          and ((.category as $c | $tdd | index($c)) or ((.suggestion // "") | test($pat)))
        ) | "## [\(.severity | ascii_upcase)] \(.section)\n\n**Category:** \(.category) | **Confidence:** \(.confidence)\n\n**Description:** \(.description)\n\n**Suggestion:** \(.suggestion)\n"' \
        "$CLAUDE_OUTPUT_FILE" 2>/dev/null
    } > "$FOLLOWUP_FILE"
    log_info "  Deferred $DEFERRED_COUNT issue(s) to: $FOLLOWUP_FILE"
  fi

  # Convergence based on plan-blocking counts only (Fix 1).
  # Capture the persisted progress_status BEFORE recomputing so the medium
  # history reset (below) can detect a state re-entry transition.
  PREV_PROGRESS_STATUS=$(get_state_field "progress_status")
  if [[ "$PLAN_BLOCKING_HIGH" -gt 0 ]]; then
    PROGRESS_STATUS="blocked_by_high_issues"
  elif [[ "$PLAN_BLOCKING_MEDIUM" -gt 0 ]]; then
    PROGRESS_STATUS="medium_issues_remaining"
  elif [[ "$LOW_COUNT" -gt 0 || "$DEFERRED_COUNT" -gt 0 ]]; then
    PROGRESS_STATUS="low_issues_only"
  else
    PROGRESS_STATUS="passed"
  fi

  # Why the park reason is a SHELL var written later rather than persisted at the point
  # of decision (#656): every persistence call is fallible, and under `set -e` a failing
  # one exits the script. If that happened between deciding to park and rewriting the
  # document, a stale PASS would survive a withheld verdict — the durable, reader-visible
  # fix must land BEFORE the bookkeeping, so the parked branch writes both together after
  # the downgrade succeeds.
  _PARK_REASON=""
  update_state_field "progress_status" "\"$PROGRESS_STATUS\""
  update_state_field "high_issues" "$HIGH_COUNT"
  update_state_field "medium_issues" "$MEDIUM_COUNT"
  update_state_field "low_issues" "$LOW_COUNT"
  update_state_field "plan_blocking_high" "$PLAN_BLOCKING_HIGH"
  update_state_field "plan_blocking_medium" "$PLAN_BLOCKING_MEDIUM"
  update_state_field "deferred_issues" "$DEFERRED_COUNT"

  # Track plan-blocking-high trajectory for early-stop check (Fix 2).
  append_high_history "$PLAN_BLOCKING_HIGH"
  # Track plan-blocking-medium trajectory ONLY when MEDIUM is the current
  # blocker. Pushing during iterations where HIGH was still the blocker would
  # inflate the history with stale counts and falsely satisfy check_no_progress
  # on the first medium_issues_remaining iteration — the user hadn't focused
  # on MEDIUMs yet, so seeing the same MEDIUM count isn't a "no progress"
  # signal. Trajectory comparison only begins once medium_issues_remaining
  # has held for ≥2 iterations.
  if [[ "$PROGRESS_STATUS" == "medium_issues_remaining" ]]; then
    # On re-entry (medium → blocked_by_high → medium), stale pre-HIGH entries
    # would cause check_no_progress to fire immediately on the first re-entered
    # MEDIUM iteration. Reset the history at the transition boundary so only
    # the current MEDIUM stint's trajectory is evaluated.
    if [[ "$PREV_PROGRESS_STATUS" != "medium_issues_remaining" ]]; then
      update_state_field "medium_issues_history" "\"[]\""
    fi
    append_medium_history "$PLAN_BLOCKING_MEDIUM"
  fi

  # Surface Claude's validation_notes so the user sees the arbiter's reasoning (Fix 5).
  VALIDATION_NOTES=$(jq -r '.validation_notes // ""' "$CLAUDE_OUTPUT_FILE" 2>/dev/null || echo "")
  if [[ -n "$VALIDATION_NOTES" && "$VALIDATION_NOTES" != "null" ]]; then
    log_info ""
    log_info "  Claude validation notes:"
    printf '%s\n' "$VALIDATION_NOTES" | sed 's/^/    /'
    log_info ""
  fi

  log_info "  Status: $PROGRESS_STATUS"
  log_info "  Issues: $HIGH_COUNT high ($PLAN_BLOCKING_HIGH plan-blocking), $MEDIUM_COUNT medium ($PLAN_BLOCKING_MEDIUM plan-blocking), $LOW_COUNT low"
  if [[ "$DEFERRED_COUNT" -gt 0 ]]; then
    log_info "  Deferred to TDD/follow-up: $DEFERRED_COUNT (see follow-up-issues.md)"
  fi

  # Trajectory-aware early stop (Fix 2): if plan-blocking-high didn't strictly
  # decrease from the prior iteration, the loop is unproductive — accept current
  # state as low_issues_only rather than grind through max_iterations.
  #
  # window=1 (compare iteration N to N-1) so the check fires after iteration 2
  # under default max_iterations=5. With window=2 the check would need 3 entries
  # before firing, giving the loop one extra grinding iteration with no payoff.
  #
  # IMPORTANT: only gate on blocked_by_high_issues. The trajectory tracks HIGH
  # only, so a medium_issues_remaining state (HIGH=0, MEDIUM>0) would trivially
  # satisfy "HIGH didn't decrease" and produce a false PASS while blocking
  # MEDIUMs remain. (Surfaced by PR #55 review — copilot-pull-request-reviewer.)
  if [[ "$PROGRESS_STATUS" == "blocked_by_high_issues" ]]; then
    HISTORY=$(get_high_history)
    if [[ "$CURRENT_ITERATION" -ge 2 ]] && check_no_progress "$HISTORY" 1; then
      log_warning ""
      log_warning "  Trajectory: plan-blocking HIGH did not decrease from prior iteration ($HISTORY)"
      log_warning "  Auto-stop: convergence loop unproductive — PARKING (this is not an approval)"
      # #656: was low_issues_only, i.e. a PASS state. A no-progress signal is not a
      # quality verdict; park instead. Handled at the parked_no_progress branch in Phase 5.
      PROGRESS_STATUS="parked_no_progress"
      _PARK_REASON="no_improvement_trajectory"
    fi
  fi

  # Parallel trajectory check for medium_issues_remaining state. HIGH is already
  # resolved (PLAN_BLOCKING_HIGH==0) but MEDIUMs persist — without this, the loop
  # has no circuit breaker for stuck MEDIUM convergence and grinds to max_iter
  # (empirically observed in growth-engine task-13-content-audit, iter 3/3 with
  # high_issues_history=[2,0] and 3 MEDIUMs unresolved).
  if [[ "$PROGRESS_STATUS" == "medium_issues_remaining" ]]; then
    MEDIUM_HISTORY=$(get_medium_history)
    if [[ "$CURRENT_ITERATION" -ge 2 ]] && check_no_progress "$MEDIUM_HISTORY" 1; then
      log_warning ""
      log_warning "  Trajectory: plan-blocking MEDIUM did not decrease from prior iteration ($MEDIUM_HISTORY)"
      log_warning "  Auto-stop: convergence loop unproductive — PARKING (this is not an approval)"
      # #656: was low_issues_only, i.e. a PASS state. See the HIGH branch above.
      PROGRESS_STATUS="parked_no_progress"
      _PARK_REASON="no_improvement_trajectory"
    fi
  fi


  # ── Phase 5: Convergence (Critic #4: Claude verdict) ──────────────
  log_info "Phase 5: Convergence check..."

  # #656 (write-site invariant, second half): before ANY terminal branch runs, refuse
  # to let a PASS state stand unless the arbiter output actually earns it. This is the
  # single place the invariant from SKILL.md's <EXTREMELY-IMPORTANT> block — "mark PASS
  # ONLY when the arbiter's verdict has no HIGH/MEDIUM issues" — is enforced against
  # the verdict FILE rather than against a derived string. #663 closed one path into
  # the approval branch; this closes the branch itself, so a future path cannot reopen it.
  #
  # Reroutes into the parked branch below (identical posture: withhold PASS, downgrade a
  # stale PASS, leave tokens ARMED, exit non-zero) with a DISTINCT early_stopped reason —
  # the parked branch's own text says "stopped making progress", which would misdescribe
  # a schema refusal, so the real reason is logged here before the flip.
  #
  # `if ! _arbiter_earns_pass` and never a bare call: this script runs under `set -e`.
  # Deliberately a `case`, not a bracket comparison against the approval states: the
  # sibling contract test locates the APPROVAL branch by grepping for the first such
  # comparison in the file, so a second textual copy here (in code OR in a comment)
  # shadows it and breaks its ordering assertion. This guard is not the approval
  # branch and must not read like one.
  _pass_state=false
  case "$PROGRESS_STATUS" in passed|low_issues_only) _pass_state=true ;; esac
  # shellcheck disable=SC2310  # predicate used in a condition by design (matches the
  # _coverage_enabled sites below); its failure IS the branch, not an error to propagate.
  if [[ "$_pass_state" == true ]] && ! _arbiter_earns_pass; then
    log_error ""
    log_error "  ARBITER VERDICT NOT COUNTABLE — refusing to authorize on it."
    log_error "  The loop read zero plan-blocking findings, but re-deriving that"
    log_error "  directly from the verdict file fails its schema/zero check."
    log_error "  Verdict file: $CLAUDE_OUTPUT_FILE"
    log_error "  Arbiter status: ${CLAUDE_STATUS:-<unset>} | issues recorded: ${CLAUDE_ISSUE_COUNT:-<unset>}"
    log_error "  Every issue needs a severity of high|medium|low, and every high/medium"
    log_error "  a numeric confidence; a FAIL status must enumerate its findings."
    PROGRESS_STATUS="parked_no_progress"
    _PARK_REASON="arbiter_verdict_uncountable"
  fi

  # #656: an early stop is a PROCESS signal ("this loop stopped making progress"),
  # NEVER a quality verdict. Resolving it to low_issues_only laundered it into a PASS
  # state and stamped `design-reviewed: PASS` onto documents whose arbiter verdict was
  # FAIL with plan-blocking HIGH still open (six such markers found on this repo, one of
  # them on the ADR that introduced the arbiter). The correct terminal state for "we
  # stopped improving with findings open" is PARKED, not APPROVED.
  #
  # Posture is deliberately identical to the degraded_coverage branch below (#355):
  # withhold the PASS, downgrade any stale PASS so the doc does not contradict the
  # verdict, leave the pending tokens ARMED (never prune — the pre-implementation gate
  # keys on tokens, so this is what actually keeps implementation blocked),
  # mark_review_complete so the caller stops re-invoking, and exit non-zero.
  if [[ "$PROGRESS_STATUS" == "parked_no_progress" ]]; then
    log_warning ""
    log_warning "=== DESIGN NOT CONVERGED — PARKED ==="
    log_warning "  The loop stopped making progress with plan-blocking issues still open."
    log_warning "  Run: $RUN_ID | High: $HIGH_COUNT | Medium: $MEDIUM_COUNT | Low: $LOW_COUNT"
    log_warning "  PASS is WITHHELD — this is not an approval. Review stays PENDING."
    log_warning "  Pending review tokens left ARMED — implementation stays gated."
    log_warning "  Address the findings and re-run, or create skip-design-review.local to proceed knowingly."
    if [[ -f "$DESIGN_FILE" ]] && grep -q "$_RE_PASS" "$DESIGN_FILE" 2>/dev/null; then
      # shellcheck disable=SC2310  # predicate used in a condition by design
      if _dr_atomic_sed "s|$_RE_PASS|<!-- design-reviewed: PENDING -->|" "$DESIGN_FILE"; then
        log_warning "  Stale PASS from a prior run downgraded to PENDING."
      else
        # Rewrite failed (temp-file create/swap error, read-only dir, full disk).
        # STOP HERE — deliberately do NOT fall through to mark_review_complete.
        #
        # It is tempting to continue so the review does not stay "active" forever,
        # and an earlier revision of this branch did exactly that on the grounds
        # that "pending tokens stay ARMED, so the gate blocks regardless of what
        # the doc marker says". That reasoning is WRONG and was caught in review:
        # the pre-implementation gate is token-EXISTENCE based, and a review can be
        # run against a document that never had a token armed (init-design-review.sh
        # accepts any readable document). In that case there is no token to block
        # on, the doc's stale PASS is the ONLY signal a reader sees, and continuing
        # would let implementation proceed on a design the arbiter FAILED.
        #
        # So this is the fail-CLOSED direction: a review left "active" is a visible
        # stall the operator can see and fix; a honored stale PASS is a silent
        # authorization they cannot. Exit non-zero WITHOUT completing the review.
        log_error "  Stale PASS downgrade FAILED and the doc still reads PASS."
        log_error "  Refusing to complete the review — that PASS would otherwise be honored."
        log_error "  Fix the write error, then either re-run the review or hand-edit"
        log_error "  '$DESIGN_FILE' to '<!-- design-reviewed: PENDING -->'."
        exit 1
      fi
    fi
    # Coverage provenance summary + trend entry belong on every terminal path,
    # parked included — otherwise repeated degraded parked runs are invisible to
    # the chronic-coverage warning (this park path was the only terminal branch
    # skipping it).
    #
    # Called PLAINLY, exactly as the other two terminal sites do (max-iterations at
    # :447, approved/degraded at :1809). An `if ! record_coverage_finalize` wrapper was
    # tried and removed: putting the call in a condition disables `set -e` for the
    # whole function, so an early failure (append_to_state) is masked whenever the
    # final command (append_coverage_trend) succeeds — the wrapper would report
    # success and swallow the warning while state.md silently lacks its COVERAGE line.
    # A guard that reports success on a partial failure is worse than no guard.
    #
    # So the failure posture here is `set -e` abort, matching every sibling path. That
    # leaves the review "active" — which on THIS branch is the deliberate fail-closed
    # stance already adopted for the downgrade failure above, not an oversight.
    # Persisted only NOW — after the document is honest. See _PARK_REASON in Phase 4.
    update_state_field "progress_status" "\"$PROGRESS_STATUS\""
    update_state_field "early_stopped" "\"${_PARK_REASON:-no_improvement_trajectory}\""
    record_coverage_finalize
    mark_review_complete "parked_no_progress"
    exit 1
  fi

  if [[ "$PROGRESS_STATUS" == "passed" || "$PROGRESS_STATUS" == "low_issues_only" ]]; then
    log_info ""
    log_info "=== DESIGN APPROVED ==="
    log_info "  Verdict: $PROGRESS_STATUS | Run: $RUN_ID"
    log_info ""

    # #355: implementation may be authorized ONLY on CONFIRMED FULL coverage. Fail
    # CLOSED: when coverage tracking is on, any status that is not exactly "FULL"
    # (DEGRADED, UNKNOWN, empty, malformed) withholds the PASS marker AND leaves the
    # pending tokens armed below — the pre-implementation gate keys on token
    # existence, so a bare non-prune is what actually keeps a security-gate plan
    # blocked. Writing the coverage marker first keeps provenance honest either way.
    # Authorize (stamp PASS + prune tokens) ONLY on the SAME invariant the readers
    # enforce: coverage_status == FULL AND fulfilled_lens_count == 3. Checking status
    # alone would let a torn/contradictory state (status FULL with count 2) prune the
    # tokens while the reader rejects the resulting `FULL 2/3` marker — a fail-open.
    _cov_block=false
    # shellcheck disable=SC2310  # predicate used in a condition by design (matches the coverage-marker block below)
    if _coverage_enabled; then
      _cov_status_now="$(get_state_field "coverage_status")"
      _cov_count_now="$(get_state_field "fulfilled_lens_count")"
      if [[ "$_cov_status_now" != "FULL" || "$_cov_count_now" != "3" ]]; then
        _cov_block=true
      fi
    fi

    # (_dr_atomic_sed and the _RE_* marker regexes are defined above Phase 5 — hoisted
    # out of this branch by #656 so the parked terminal state can share them.)

    # Write the coverage provenance marker FIRST — BEFORE any PASS — so a durable
    # PASS is never present without its coverage marker beside it. A crash between the
    # two would otherwise leave a bare PASS that _doc_reviewed honors (no coverage
    # marker = honorable). Always upsert: it records the honest DEGRADED/FULL status.
    # shellcheck disable=SC2310  # predicate used in a condition by design
    if _coverage_enabled && [[ -f "$DESIGN_FILE" ]]; then
      _cov_status=$(get_state_field "coverage_status")
      _cov_count=$(get_state_field "fulfilled_lens_count")
      _cov_detail=""
      for _cn in 1 2 3; do
        _cr=$(get_state_field "reviewer_${_cn}_reason")
        [[ -n "$_cr" && "$_cr" != "ok" ]] && _cov_detail="${_cov_detail:+$_cov_detail }reviewer_${_cn}=${_cr}"
      done
      _cov_marker="<!-- design-review-coverage: ${_cov_status:-UNKNOWN} ${_cov_count}/3 ${_cov_detail} -->"
      if grep -q "$_RE_COV" "$DESIGN_FILE" 2>/dev/null; then
        _dr_atomic_sed "s|$_RE_COV|${_cov_marker}|" "$DESIGN_FILE"
      else
        # Leading '\n' guarantees the marker lands on its OWN line even when the file
        # lacks a trailing newline — otherwise it would fuse onto the last line
        # (`text<!-- ... -->`), which the whole-line regex could never find or replace,
        # so a later FULL review would append a duplicate instead of updating it.
        printf '\n%s\n' "$_cov_marker" >> "$DESIGN_FILE"
      fi
    elif [[ -f "$DESIGN_FILE" ]] && grep -q "$_RE_COV" "$DESIGN_FILE" 2>/dev/null; then
      # Coverage tracking OFF but the doc carries a stale WHOLE-LINE marker from a prior
      # tracked run: with no upsert to refresh it, a leftover DEGRADED/UNKNOWN would make
      # the reader reject the PASS we may stamp below (contradictory writer/reader state).
      # Provenance is off ⇒ no coverage gate ⇒ strip the stale marker line so both agree.
      _dr_atomic_sed "/$_RE_COV/d" "$DESIGN_FILE"
    fi
    record_coverage_finalize

    # Not confirmed FULL 3/3 → withhold PASS, keep pending tokens ARMED (do not prune)
    # so the pre-implementation gate keeps blocking, and finish without marking passed.
    # mark_review_complete sets active:false → the caller stops re-invoking.
    if [[ "$_cov_block" == true ]]; then
      # Downgrade any stale PASS (from a prior FULL run) to PENDING so the withheld
      # verdict is HONEST — the reader already rejects PASS-beside-DEGRADED, but don't
      # leave the physical contradiction in the doc.
      if [[ -f "$DESIGN_FILE" ]] && grep -q "$_RE_PASS" "$DESIGN_FILE" 2>/dev/null; then
        _dr_atomic_sed "s|$_RE_PASS|<!-- design-reviewed: PENDING -->|" "$DESIGN_FILE"
      fi
      log_warning "  COVERAGE NOT CONFIRMED FULL (status=${_cov_status_now:-unset} count=${_cov_count_now:-unset}) — PASS withheld (#355); review stays PENDING."
      log_warning "  Pending review tokens left ARMED — implementation stays gated on partial coverage."
      log_warning "  Fix the reviewer CLIs (which agy codex grok) and re-run, or create skip-design-review.local to proceed knowingly."
      update_state_field "early_stopped" "\"degraded_coverage\""
      mark_review_complete "degraded_coverage"
      exit 1
    fi

    # Confirmed FULL 3/3 → authorize. The FULL 3/3 coverage marker is already durable
    # above, so stamp PASS now (then prune the pending tokens below).
    if [[ -f "$DESIGN_FILE" ]]; then
      if ! grep -q "$_RE_PASS" "$DESIGN_FILE" 2>/dev/null; then
        if grep -q "$_RE_PEND" "$DESIGN_FILE" 2>/dev/null; then
          _dr_atomic_sed "s|$_RE_PEND|<!-- design-reviewed: PASS -->|" "$DESIGN_FILE"
        else
          printf '\n<!-- design-reviewed: PASS -->\n' >> "$DESIGN_FILE"
        fi
        log_info "Gate marker written to: $DESIGN_FILE"
      fi
    else
      log_error "Design file not found: $DESIGN_FILE"
      mark_review_complete "error_no_design_file"
      exit 1
    fi

    # ADR-D: prune ONLY the tokens snapshotted at loop start (physical-abspath
    # keyed → never cross-clears a divergent branch; re-armed tokens survive).
    # This inline rm inside the trusted loop is invisible to the marker-forge
    # guard (which sees only the top-level `bash -p …run-design-review-loop.sh` call);
    # a Claude tool-call rm of a token stays blocked. Replaces the old whole-file
    # `rm` of the single CWD-relative marker (divergence 4).
    if [[ "${#_MARKER_SNAP[@]}" -gt 0 ]]; then
      rm -f "${_MARKER_SNAP[@]}"
    fi
    if [[ "$_MARKER_RESOLVE_OK" == true ]]; then
      log_info "Design review state cleaned up (${#_MARKER_SNAP[@]} marker token(s) pruned)."
    else
      log_warning "PASS recorded, but the marker dir was unresolved at loop start — NO tokens were pruned; drain manually if the gate keeps blocking."
    fi
    mark_review_complete "passed"
    exit 0
  fi

  # ── Not converged ─────────────────────────────────────────────────
  log_info "Not converged: $PROGRESS_STATUS"

  if [[ "$AUTO_MODE" == "true" ]]; then
    # In auto mode, exit after one iteration so the calling skill can:
    # 1. Fix issues in the spec
    # 2. Run Claude validation (requires codebase access)
    # 3. Re-invoke this script for the next iteration
    # Blindly continuing would fail: claude.json is cleaned at iteration
    # start and the script can't produce it without codebase tools.
    log_info "Auto mode: Iteration complete. Exiting for skill to handle fixes + Claude validation."
    log_info "  Fix $HIGH_COUNT high + $MEDIUM_COUNT medium issues, then re-invoke."
    increment_iteration
    exit 1
  else
    log_info "Address the issues, then re-run:"
    log_info "  High:   $HIGH_COUNT (must fix)"
    log_info "  Medium: $MEDIUM_COUNT (should fix)"
    log_info "  Low:    $LOW_COUNT (optional)"
    increment_iteration
    break
  fi
done

log_info ""
log_info "Review loop exited. State: cat $STATE_FILE"
