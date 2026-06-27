#!/bin/bash
# Main litmus review loop script
# Reads state, runs review, parses results, updates state, handles iteration logic

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) so
# repo-root joins like "$REPO_TOP/$STATE_DIR" resolve to the configured state dir.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
# Re-export the sanitized value so the helper libs this script sources
# (validation.sh, log-metrics.sh, iteration-history.sh, …) — each of which
# re-reads BUSDRIVER_STATE_DIR — inherit the constrained value rather than a raw
# traversal/absolute one reaching their marker/path joins.
export BUSDRIVER_STATE_DIR="$STATE_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$STATE_DIR/litmus-state.md"

# write_terminal_status: persist terminal_status field to $STATE_FILE before exit-1.
# Backward-compatible — interactive /litmus callers see no behavior change.
# Pre-condition: $STATE_FILE is set. If the file or its parent dir is missing
# (early-exit / setup-error paths), create them before writing.
write_terminal_status() {
    local status="$1"
    case "$status" in
        review_findings|stall|max_iterations|infra_failure|setup_error) ;;
        *) printf 'write_terminal_status: invalid %s\n' "$status" >&2; return 1 ;;
    esac
    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
    local tmp="${STATE_FILE}.tmp.$$"
    if grep -q '^terminal_status:' "$STATE_FILE"; then
        # Update existing field in-place (works on macOS BSD sed and GNU sed)
        sed -E "s/^terminal_status:.*/terminal_status: \"${status}\"/" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    elif grep -q '^---$' "$STATE_FILE"; then
        # Insert before the closing --- so frontmatter readers (get_yaml_value)
        # can parse the field. Uses the second occurrence of ^---$ as the insert point.
        # If count never reaches 2 (unclosed/single---- frontmatter from a prior crash),
        # fall back to the else-branch wrapping so the field is never silently dropped.
        local _inserted=0
        awk -v val="terminal_status: \"${status}\"" '
            /^---$/ { count++ }
            count == 2 && /^---$/ { print val; inserted=1 }
            { print }
            END { exit (inserted ? 0 : 1) }
        ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE" && _inserted=1 || true
        if [[ "$_inserted" -eq 0 ]]; then
            { printf -- '---\nterminal_status: "%s"\n---\n' "$status"; cat "$STATE_FILE"; } > "$tmp" \
                && mv "$tmp" "$STATE_FILE"
        fi
    else
        # No frontmatter — wrap the file content in frontmatter and add field.
        { printf -- '---\nterminal_status: "%s"\n---\n' "$status"; cat "$STATE_FILE"; } > "$tmp" \
            && mv "$tmp" "$STATE_FILE"
    fi
}

# Load metrics persistence
# shellcheck source=lib/log-metrics.sh
source "$SCRIPT_DIR/lib/log-metrics.sh"

# ── PR-mode dual-voice artifact contract ──────────────────────────────
# Both artifacts gate `gh pr create` in PR mode and are protected in
# pre-implementation-gate.sh MARKER_FILES. The backstop verdict has a writer
# subcommand (--write-backstop-verdict); the Codex-lead verdict is written ONLY
# inline on an actual Codex PASS (no subcommand — see write_codex_lead_verdict);
# --write-pr-marker emits the final marker once BOTH artifacts verify. Keep this
# contract in sync with pre-pr-gate.sh and post-pr-consume-marker.sh. See ADR 0006.
#
# Repo-root anchored (no cwd drift): the pre-PR gate resolves the worktree top
# via `git -C "${TARGET_DIR:-.}" rev-parse --show-toplevel` and reads
# "$REPO_DIR/$STATE_DIR/...". If litmus runs from a subdirectory and writes a
# relative "./.claude/...", the gate would never find the artifacts. Anchor all
# PR artifacts + the marker to "$PR_REPO_TOP/$STATE_DIR" so both sides agree.
PR_REPO_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
PR_STATE_DIR="$PR_REPO_TOP/$STATE_DIR"
PR_BACKSTOP_VERDICT_FILE="$PR_STATE_DIR/pr-backstop-verdict.local.json"
PR_CODEX_LEAD_FILE="$PR_STATE_DIR/pr-codex-lead.local.json"
PR_REVIEW_MARKER_FILE="$PR_STATE_DIR/pr-review-passed.local"
PR_BACKSTOP_MAX_AGE="${LITMUS_PR_BACKSTOP_MAX_AGE:-3600}"

# compute_pr_diff_hash <base-ref>
# FAIL-CLOSED sha256 of the PR diff (base...HEAD). Byte-identical to the existing
# pre-pr-gate.sh / pr-review-passed.local computation (plain `git diff` +
# `printf '%s'` capture) so the trusted writer and the gate verifier agree.
# Echoes the 64-hex hash on stdout; returns nonzero with NO output if the
# base/merge-base is missing or the diff is empty (never emit a hash for a
# missing base — that would fail open).
# Follow-up (deferred, ADR 0006): add deterministic `-c color.ui=never
# -c diff.external= -c core.quotePath=false` flags here AND in pre-pr-gate.sh +
# tests together, to neutralize hostile/unusual operator git config.
compute_pr_diff_hash() {
  local base="$1" mb diff
  [ -z "$base" ] && return 1
  mb=$(git merge-base "$base" HEAD 2>/dev/null) || return 1
  [ -z "$mb" ] && return 1
  diff=$(git diff "${mb}...HEAD" 2>/dev/null) || return 1
  [ -z "$diff" ] && return 1
  printf '%s' "$diff" | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}

# resolve_pr_base_branch: the origin-qualified base branch for PR mode, matching
# the resolution used elsewhere in this script and in init-review-loop.sh.
resolve_pr_base_branch() {
  local b="${LITMUS_PR_BASE:-}"
  [ -z "$b" ] && b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||' || echo "origin/main")
  [[ -n "${LITMUS_PR_BASE:-}" && "$b" != origin/* ]] && b="origin/${b}"
  printf '%s' "$b"
}

# read_artifact_field <file> <jq-path>  — small JSON field reader (jq → python3).
_read_artifact_field() {
  local f="$1" path="$2"
  [ -f "$f" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    # -e: empty/false output → nonzero exit (fail-closed on a missing field).
    # -r: RAW output — a string field like .status prints as `PASS` (UNQUOTED),
    # so the `[ "$status" = "PASS" ]` check below matches. Do NOT drop -r, or
    # strings come back as `"PASS"` and every artifact is wrongly rejected.
    jq -er "$path // empty" "$f" 2>/dev/null
  else
    python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for k in sys.argv[2].strip(".").split("."):
        d=d[k]
    print(d)
except Exception:
    sys.exit(1)' "$f" "$path" 2>/dev/null
  fi
}

# verify_pr_artifact <file> <expected_diff_hash> — fail-closed freshness/PASS check.
# Returns 0 only if the artifact exists, parses, status==PASS, diff_hash matches
# the expected current hash, and ts is within PR_BACKSTOP_MAX_AGE.
verify_pr_artifact() {
  local f="$1" expected="$2" status hash ts now age
  [ -f "$f" ] || return 1
  status=$(_read_artifact_field "$f" ".status") || return 1
  [ "$status" = "PASS" ] || return 1
  hash=$(_read_artifact_field "$f" ".diff_hash") || return 1
  [ "$hash" = "$expected" ] || return 1
  ts=$(_read_artifact_field "$f" ".ts") || return 1
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  age=$(( now - ts ))
  [ "$age" -ge 0 ] && [ "$age" -le "$PR_BACKSTOP_MAX_AGE" ] || return 1
  return 0
}

# write_codex_lead_verdict <reviewed_diff_hash>: trusted writer for
# pr-codex-lead.local.json. Records the Codex lead's clean PASS bound to the diff
# hash the lead ACTUALLY reviewed (captured BEFORE the review ran — see
# PR_REVIEWED_DIFF_HASH), NOT a hash re-derived at write time. The review takes
# minutes; if HEAD or the PR base moves in that window, binding to the reviewed
# hash keeps the artifact tied to what Codex saw, and the gate (which re-derives
# at gate time) then correctly rejects the now-stale state. Atomic mktemp+mv.
# Returns nonzero on a missing/empty hash (fail-closed — no unbound artifact).
# Only ever called inline on an actual Codex PASS — there is deliberately NO
# standalone subcommand, so a PASS lead artifact cannot be forged without a review.
write_codex_lead_verdict() {
  local hash="$1" now tmp
  [ -n "$hash" ] || return 1
  now=$(date +%s)
  mkdir -p "$PR_STATE_DIR" || return 1
  tmp=$(mktemp "${PR_STATE_DIR}/.pr-codex-lead.XXXXXX") || return 1
  printf '{"status":"PASS","model":"codex","diff_hash":"%s","ts":%s}\n' "$hash" "$now" > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$PR_CODEX_LEAD_FILE" || { rm -f "$tmp"; return 1; }
  return 0
}

# --write-pr-marker: Final PR gate marker writer (dual-voice enforced).
# Called by Claude ONLY after BOTH deep-review voices have produced fresh,
# diff-bound PASS artifacts:
#   • pr-codex-lead.local.json       — the Codex xhigh lead's clean verdict
#   • pr-backstop-verdict.local.json — the read-only Opus security/bugs backstop
# This is the ONLY legitimate path to write pr-review-passed.local because the
# PreToolUse hook blocks direct writes/redirects to marker files (and to both
# artifacts). The hook doesn't inspect what runs inside scripts, so this writer
# bypasses it — and in exchange it FAILS CLOSED unless BOTH artifacts are fresh
# PASS with a diff_hash matching the current base...HEAD. A backstop PASS alone,
# a stale/forged artifact, or a skipped Codex lead all leave the gate unsatisfied.
if [[ "${1:-}" == "--write-pr-marker" ]]; then
  DIFF_HASH=$(compute_pr_diff_hash "$(resolve_pr_base_branch)") || {
    echo "❌ Cannot compute PR diff hash (missing base / empty diff) — refusing to write marker" >&2
    write_terminal_status setup_error
    exit 1
  }
  if ! verify_pr_artifact "$PR_CODEX_LEAD_FILE" "$DIFF_HASH"; then
    echo "❌ Codex lead artifact missing/stale/FAIL — refusing PR marker" >&2
    echo "   Need fresh status:PASS in $PR_CODEX_LEAD_FILE with diff_hash ${DIFF_HASH:0:12}..." >&2
    echo "   Re-run the Codex deep review (PR mode) before writing the marker." >&2
    write_terminal_status setup_error
    exit 1
  fi
  if ! verify_pr_artifact "$PR_BACKSTOP_VERDICT_FILE" "$DIFF_HASH"; then
    echo "❌ Security backstop artifact missing/stale/FAIL — refusing PR marker" >&2
    echo "   Need fresh status:PASS in $PR_BACKSTOP_VERDICT_FILE with diff_hash ${DIFF_HASH:0:12}..." >&2
    echo "   Dispatch the read-only pr-security-backstop agent and persist its verdict via" >&2
    echo "   run-review-loop.sh --write-backstop-verdict before writing the marker." >&2
    write_terminal_status setup_error
    exit 1
  fi
  mkdir -p "$PR_STATE_DIR"
  # Marker content = current diff hash. echo (one trailing newline) is
  # byte-identical to the prior writer and to the FAST/short-circuit writers;
  # the gate strips the trailing newline via $() on read.
  echo "$DIFF_HASH" > "$PR_REVIEW_MARKER_FILE"
  echo "✅ PR review marker written — both voices PASS (hash: ${DIFF_HASH:0:12}...)"
  exit 0
fi

# NOTE: there is deliberately NO `--write-codex-lead-verdict` subcommand. The
# Codex-lead PASS artifact is written ONLY inline by write_codex_lead_verdict on
# an actual Codex PASS (PR-mode review path below). A standalone subcommand would
# let a status:PASS lead artifact be forged for the current diff without any
# Codex review having run — which --write-pr-marker would then accept as proof of
# the lead voice. Tests seed a lead artifact by writing the JSON directly.

# --write-backstop-verdict: strict, fail-closed writer for the read-only
# security/bugs backstop verdict artifact (pr-backstop-verdict.local.json).
#
# Claude dispatches the read-only pr-security-backstop agent over the SAME
# base...HEAD diff it gives the Codex lead, then pipes the agent's verdict —
# augmented with `model` and the `reviewed_diff_hash` Claude computed for the
# diff it injected — to this writer on stdin:
#   {"status","model","reviewed_diff_hash",
#    "issues":[{file,line,severity,confidence,category,description[,suggestion]}]}
#
# This writer is the SOLE producer of the artifact. It:
#   • re-derives the CURRENT diff_hash + ts itself (caller never supplies them);
#   • fails closed (nonzero, no write) on a stale review (reviewed_diff_hash !=
#     current → a commit landed mid-review), malformed JSON, unknown/missing
#     fields, missing/out-of-range confidence, or bad/empty severity|category;
#   • recomputes status from issues — any `high` ⇒ FAIL; an explicit caller FAIL
#     is NEVER overridden to PASS;
#   • writes atomically (mktemp + mv) so the gate never sees a partial artifact.
if [[ "${1:-}" == "--write-backstop-verdict" ]]; then
  # Read the agent verdict JSON from stdin up-front (git work below does not touch
  # stdin) so the strict validator can take its PROGRAM on argv and the PAYLOAD on
  # stdin without the two colliding.
  PAYLOAD=$(cat)
  CURRENT_HASH=$(compute_pr_diff_hash "$(resolve_pr_base_branch)") || {
    echo "❌ Cannot compute PR diff hash (missing base / empty diff) — refusing backstop verdict" >&2
    exit 1
  }
  # Defense-in-depth: the backstop verdict may only be persisted AFTER a genuine
  # Codex-lead PASS for THIS exact diff. The Codex-lead artifact is written ONLY
  # inline by this script on a real codex run (there is no forge-able subcommand),
  # so requiring it here ties the backstop write to a real review context and
  # blocks a backstop-ONLY forge (write a PASS backstop with no review at all).
  #
  # TCB boundary (accepted residual, ADR 0006): the backstop is a Claude-dispatched
  # read-only subagent, so this writer must take its verdict on stdin and cannot
  # cryptographically prove the agent ran — a trusted dispatcher could still
  # fabricate the agent's findings after a real Codex pass. That residual is
  # inherent to "Claude is the trusted dispatcher" and is accepted by design; this
  # precondition shrinks the surface to "requires a real Codex lead pass first."
  if ! verify_pr_artifact "$PR_CODEX_LEAD_FILE" "$CURRENT_HASH"; then
    echo "❌ No fresh Codex-lead PASS for the current diff — run the PR review (Step 1)" >&2
    echo "   before persisting the backstop verdict. The lead artifact is written only" >&2
    echo "   by a real Codex pass, so the backstop cannot be recorded without one." >&2
    exit 1
  fi
  NOW_TS=$(date +%s)
  mkdir -p "$PR_STATE_DIR"
  # Oversize diff → fail closed (never silent-truncate a too-large diff into a
  # PASS). LITMUS_PR_BACKSTOP_MAX_DIFF caps the byte size of the diff handed to
  # the backstop; 0 (default) = no cap. When exceeded, refuse the verdict and
  # tell the operator to split the PR (mirrors Codex's large-diff handling).
  MAX_DIFF="${LITMUS_PR_BACKSTOP_MAX_DIFF:-0}"
  case "$MAX_DIFF" in ''|*[!0-9]*) MAX_DIFF=0 ;; esac
  if [ "$MAX_DIFF" -gt 0 ]; then
    _OVR_MB=$(git merge-base "$(resolve_pr_base_branch)" HEAD 2>/dev/null || true)
    DIFF_BYTES=$(git diff "${_OVR_MB}...HEAD" 2>/dev/null | wc -c | tr -d ' ')
    if [ "${DIFF_BYTES:-0}" -gt "$MAX_DIFF" ]; then
      echo "❌ PR diff ${DIFF_BYTES}B exceeds LITMUS_PR_BACKSTOP_MAX_DIFF=${MAX_DIFF}B — fail-closed" >&2
      echo "   Split the PR into smaller reviewable changes (no silent truncation)." >&2
      printf '{"ts":"%s","event":"pr-backstop-oversize","gate":"pre-pr","diff_bytes":%s,"max":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${DIFF_BYTES:-0}" "$MAX_DIFF" >> "$PR_STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
      exit 1
    fi
  fi
  SCHEMA_FILE="$SCRIPT_DIR/../schemas/pr-backstop-verdict.schema.json"
  TMP_VERDICT=$(mktemp "${PR_STATE_DIR}/.pr-backstop-verdict.XXXXXX") || {
    echo "❌ Cannot create temp file for backstop verdict" >&2
    exit 1
  }
  # Strict validator (net-new — does NOT reuse the fail-open validation.sh).
  # Emits the final artifact JSON on success; exits nonzero on any violation.
  # Reads the severity/category enums + required fields from the committed schema
  # when readable, else falls back to strict embedded defaults (fail-safe).
  # The program is delivered via -c (argv) and the payload via stdin — they must
  # not collide (a `python3 - <<HEREDOC` would make the heredoc the program AND
  # consume stdin, leaving json.load(stdin) empty → every payload falsely rejected).
  BACKSTOP_VALIDATOR_PY=$(cat <<'PYEOF'
import json, sys

current_hash, now_ts, schema_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def reject(msg):
    sys.stderr.write("backstop verdict rejected: %s\n" % msg)
    sys.exit(1)

# Strict defaults — kept in lockstep with pr-backstop-verdict.schema.json.
SEVERITY_ENUM = ["high", "medium", "low"]
CATEGORY_ENUM = ["security", "bug"]
REQUIRED_ISSUE = ["file", "line", "severity", "confidence", "category", "description"]
ALLOWED_ISSUE = REQUIRED_ISSUE + ["suggestion"]
try:
    with open(schema_path) as fh:
        sch = json.load(fh)
    items = sch["properties"]["issues"]["items"]
    SEVERITY_ENUM = items["properties"]["severity"]["enum"]
    CATEGORY_ENUM = items["properties"]["category"]["enum"]
    REQUIRED_ISSUE = items["required"]
    ALLOWED_ISSUE = list(items["properties"].keys())
except Exception:
    pass  # fail-safe: strict embedded defaults already set

try:
    payload = json.load(sys.stdin)
except Exception as e:
    reject("stdin is not valid JSON (%s)" % e)
if not isinstance(payload, dict):
    reject("top-level payload must be a JSON object")

# The caller may ONLY supply these — diff_hash/ts are writer-derived, never
# accepted from stdin. Any other top-level field is a contract violation.
ALLOWED_TOP = {"status", "model", "issues", "reviewed_diff_hash"}
extra = set(payload.keys()) - ALLOWED_TOP
if extra:
    reject("unknown top-level field(s): %s" % ", ".join(sorted(extra)))

reviewed = payload.get("reviewed_diff_hash")
if not isinstance(reviewed, str) or not reviewed:
    reject("missing reviewed_diff_hash")
if reviewed != current_hash:
    reject("stale review: reviewed_diff_hash != current base...HEAD (a commit landed mid-review; re-run)")

status_in = payload.get("status")
if status_in not in ("PASS", "FAIL"):
    reject("status must be PASS or FAIL")

model = payload.get("model")
if not isinstance(model, str) or not model.strip():
    reject("missing model")

issues = payload.get("issues")
if not isinstance(issues, list):
    reject("issues must be an array")

clean = []
any_high = False
for i, it in enumerate(issues):
    if not isinstance(it, dict):
        reject("issue[%d] must be an object" % i)
    for k in it:
        if k not in ALLOWED_ISSUE:
            reject("issue[%d] has unknown field %r" % (i, k))
    for k in REQUIRED_ISSUE:
        if k not in it:
            reject("issue[%d] missing required field %r" % (i, k))
    sev = it["severity"]
    if sev not in SEVERITY_ENUM:
        reject("issue[%d] bad/empty severity %r" % (i, sev))
    cat = it["category"]
    if cat not in CATEGORY_ENUM:
        reject("issue[%d] bad/empty category %r" % (i, cat))
    conf = it["confidence"]
    if isinstance(conf, bool) or not isinstance(conf, int) or conf < 0 or conf > 100:
        reject("issue[%d] confidence must be int 0..100" % i)
    line = it["line"]
    if isinstance(line, bool) or not isinstance(line, int) or line < 0:
        reject("issue[%d] line must be int >= 0" % i)
    if not isinstance(it["file"], str) or not it["file"]:
        reject("issue[%d] file must be a non-empty string" % i)
    if not isinstance(it["description"], str) or not it["description"]:
        reject("issue[%d] description must be a non-empty string" % i)
    out = {
        "file": it["file"], "line": line, "severity": sev,
        "confidence": conf, "category": cat, "description": it["description"],
    }
    if "suggestion" in it:
        if not isinstance(it["suggestion"], str):
            reject("issue[%d] suggestion must be a string" % i)
        out["suggestion"] = it["suggestion"]
    if sev == "high":
        any_high = True
    clean.append(out)

# Recompute status: any high ⇒ FAIL; an explicit caller FAIL is never upgraded.
final_status = "FAIL" if (status_in == "FAIL" or any_high) else "PASS"

artifact = {
    "status": final_status,
    "model": model.strip(),
    "diff_hash": current_hash,
    "ts": now_ts,
    "issues": clean,
}
sys.stdout.write(json.dumps(artifact, separators=(",", ":")) + "\n")
PYEOF
)
  if ! printf '%s' "$PAYLOAD" | python3 -c "$BACKSTOP_VALIDATOR_PY" "$CURRENT_HASH" "$NOW_TS" "$SCHEMA_FILE" >"$TMP_VERDICT"; then
    rm -f "$TMP_VERDICT"
    echo "❌ Backstop verdict rejected (fail-closed) — artifact NOT written" >&2
    exit 1
  fi
  chmod 600 "$TMP_VERDICT" 2>/dev/null || true
  mv -f "$TMP_VERDICT" "$PR_BACKSTOP_VERDICT_FILE"
  FINAL_STATUS=$(_read_artifact_field "$PR_BACKSTOP_VERDICT_FILE" ".status" || echo "?")
  echo "✅ Backstop verdict written: status=$FINAL_STATUS (hash: ${CURRENT_HASH:0:12}...)"
  exit 0
fi

# --auto-pr-review: Self-contained PR review triggered by the pre-PR gate.
# Combines: init (force) → CLI review → marker write in one invocation.
# Uses LITMUS_PR_FAST=1 so the marker is written on CLI PASS without
# requiring the 6-agent deep review (which needs Claude's Agent tool).
# The gate's block message tells Claude to run this single command.
if [[ "${1:-}" == "--auto-pr-review" ]]; then
  export LITMUS_MODE=pr
  export LITMUS_PR_FAST=1
  echo "🔍 Auto-triggering PR litmus review..."
  echo ""
  bash "$SCRIPT_DIR/init-review-loop.sh" --force || {
    echo "❌ Failed to initialize PR review" >&2
    write_terminal_status setup_error
    exit 1
  }
  # Re-exec as normal review (picks up PR mode from state file + LITMUS_PR_FAST=1)
  exec bash "$SCRIPT_DIR/run-review-loop.sh"
fi

# Source validation library
# shellcheck source=lib/validation.sh
source "$SCRIPT_DIR/lib/validation.sh"

# Source iteration history library
# shellcheck source=lib/iteration-history.sh
source "$SCRIPT_DIR/lib/iteration-history.sh"

# Determine review mode from state file or env var
REVIEW_MODE="${LITMUS_MODE:-commit}"

# Validate prerequisites
echo "🔍 Validating prerequisites..."
validate_git_repo || { write_terminal_status setup_error; exit 1; }

# Resolve review CLI (fail-closed on missing/unsupported binary)
RESOLVED_CLI=$(validate_review_cli 2>/dev/null) || {
  validate_review_cli >&2
  write_terminal_status setup_error
  exit 1
}

echo "   Review CLI: $RESOLVED_CLI"

validate_state_file "$STATE_FILE" || { write_terminal_status setup_error; exit 1; }

# Check for changes based on review mode
# Also read review_mode from state file if set (overrides env var)
if [ -f "$STATE_FILE" ]; then
  STATE_MODE=$(get_yaml_value "review_mode" "$STATE_FILE" 2>/dev/null || echo "")
  [ -n "$STATE_MODE" ] && [ "$STATE_MODE" != "null" ] && REVIEW_MODE="$STATE_MODE"
fi

if [ "$REVIEW_MODE" = "pr" ]; then
  # PR mode lead is PINNED to Codex (cross-model gate: an Anthropic-family
  # backstop checks an OpenAI-family lead). Reject ANY non-codex lead — not just
  # builtin/none but also droid/agy/grok — so a degraded or misconfigured route
  # fails closed rather than silently shipping a weaker lead. (A resolve-cli.sh
  # route like [codex,droid] would otherwise resolve to droid when codex is
  # missing.) The opt-in benchmark (LITMUS_PR_BENCHMARK) dispatches agy/grok
  # SEPARATELY and never changes this gating lead.
  if [ "$RESOLVED_CLI" != "codex" ]; then
    echo "❌ Error: PR review requires the Codex lead reviewer" >&2
    echo "" >&2
    echo "   Resolved review CLI is '$RESOLVED_CLI' — PR mode pins the lead to codex" >&2
    echo "   for cross-model safety; a non-codex lead is inconclusive (fail-closed)." >&2
    echo "   Install/configure codex (BUSDRIVER_REVIEW_CLI=codex, or auto with codex available)." >&2
    write_terminal_status setup_error
    exit 1
  fi
  # Close the silent-droid escalation inside _execute_codex: a FAILED Codex must
  # fall to builtin (already rejected above) — never silently to droid — so the
  # gating lead is Codex or the gate is inconclusive/fail-closed.
  export LITMUS_CODEX_DROID_FALLBACK_DISABLED=1

  # PR mode is the cross-model gate of record with NO droid net (disabled just
  # above) — retrying is the only recovery. Raise codex's retry budget to 5
  # (backoff ≈ 15.5 min, which also outwaits OpenAI's per-5min rate-limit window)
  # vs the default 3 used by the pre-commit path. `:-5` respects an operator
  # override exported in the parent shell.
  export LITMUS_CODEX_RETRIES="${LITMUS_CODEX_RETRIES:-5}"

  # PR mode: check for branch diff against base
  PR_BASE_BRANCH="${LITMUS_PR_BASE:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||' || echo "origin/main")}"
  # Auto-prefix origin/ if user provided a branch name without remote prefix
  # (e.g. LITMUS_PR_BASE=main → origin/main, LITMUS_PR_BASE=feature/foo → origin/feature/foo)
  if [[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE_BRANCH" != origin/* ]]; then
    PR_BASE_BRANCH="origin/${PR_BASE_BRANCH}"
  fi
  if git diff --quiet "${PR_BASE_BRANCH}...HEAD" 2>/dev/null; then
    echo "❌ No changes between ${PR_BASE_BRANCH} and HEAD" >&2
    write_terminal_status setup_error
    exit 1
  fi
else
  # Commit mode: handle 'none' (must be after PR mode guard above)
  if [ "$RESOLVED_CLI" = "none" ]; then
    echo "⚠️  BUSDRIVER_REVIEW_CLI=none — review gate disabled" >&2
    echo "   Commits will pass without code review." >&2
    echo "" >&2
    mkdir -p "$STATE_DIR"
    echo "SKIPPED-NONE-$(date +%s)" > "$STATE_DIR/litmus-passed.local"
    printf '{"ts":"%s","event":"review-skipped-none","gate":"pre-commit"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    clear_iteration_history
    rm -f "$STATE_FILE" 2>/dev/null
    exit 0
  fi

  # Commit mode: check for staged changes
  # Detect merge in progress — merge resolutions have all files staged
  # as part of the merge state, making git diff --cached appear empty
  # when conflicts are resolved by keeping our code.
  if git rev-parse MERGE_HEAD >/dev/null 2>&1; then
    if git diff --cached --quiet 2>/dev/null; then
      # Merge keeps our already-reviewed code unchanged — auto-pass
      echo "ℹ️  Merge commit detected with no changes relative to HEAD"
      echo "   Resolution keeps already-reviewed code — auto-passing review"
      echo ""
      mkdir -p "$STATE_DIR"
      echo "PASS-MERGE-$(date +%s)" > "$STATE_DIR/litmus-passed.local"
      clear_iteration_history
      rm -f "$STATE_FILE" 2>/dev/null
      exit 0
    fi
    echo "ℹ️  Merge commit detected — reviewing merge resolution changes"
    # Fall through to review the changes introduced by the merge
  else
    if git diff --cached --quiet 2>/dev/null; then
      if ! has_uncommitted_changes; then
        error_no_changes
        write_terminal_status setup_error
        exit 1
      fi
      echo "⚠️  No staged changes found. Stage files first: git add <files>" >&2
      write_terminal_status setup_error
      exit 1
    fi
  fi
fi

echo "✅ Prerequisites validated"
echo ""

# Read state from file
echo "📖 Reading state..."
ITERATION=$(get_yaml_value "iteration" "$STATE_FILE")
MAX_ITER=$(get_yaml_value "max_iterations" "$STATE_FILE")
ACTIVE=$(get_yaml_value "active" "$STATE_FILE")
COMPLETION_PROMISE=$(get_yaml_value "completion_promise" "$STATE_FILE")

# Validate state values
if [ -z "$ITERATION" ] || [ -z "$MAX_ITER" ]; then
  echo "❌ Error: Invalid state file - missing iteration or max_iterations" >&2
  write_terminal_status setup_error
  exit 1
fi

echo "   Loop iteration: $ITERATION / $MAX_ITER"
echo ""

# Check if loop is active
if [ "$ACTIVE" != "true" ]; then
  echo "ℹ️  Review loop is not active"
  echo "   Status: Completed or stopped"
  exit 0
fi

# Check iteration limit
if [ "$ITERATION" -gt "$MAX_ITER" ]; then
  echo "❌ Max iterations ($MAX_ITER) reached" >&2
  echo "" >&2
  echo "   The review loop has hit the maximum iteration limit." >&2
  echo "   This usually indicates:" >&2
  echo "   - Complex changes requiring design discussion" >&2
  echo "   - Fixes introducing new issues" >&2
  echo "   - Changes too large (>300 lines)" >&2
  echo "" >&2
  echo "   Options:" >&2
  echo "   1. Review remaining issues manually" >&2
  echo "   2. Break changes into smaller commits" >&2
  echo "   3. Reset counter to continue (advanced)" >&2
  echo "" >&2
  echo "   See references/troubleshooting.md for guidance" >&2
  set_yaml_value "active" "false" "$STATE_FILE"
  write_terminal_status max_iterations
  exit 1
fi

# Extract prompt from state file (content after frontmatter)
echo "📝 Loading review prompt..."
PROMPT=$(sed -n '/^---$/,/^---$/!p' "$STATE_FILE" | sed '1d')

# Source auto-generated file exclusion (hardcoded defaults + .claude/review-exclude)
# shellcheck source=lib/exclude-generated.sh
source "$SCRIPT_DIR/lib/exclude-generated.sh"

# Source SAST, smart context, docs context, and markdown checker
# shellcheck source=lib/sast-runner.sh
source "$SCRIPT_DIR/lib/sast-runner.sh"
# shellcheck source=lib/smart-context.sh
source "$SCRIPT_DIR/lib/smart-context.sh"
# shellcheck source=lib/docs-context.sh
source "$SCRIPT_DIR/lib/docs-context.sh"
# shellcheck source=lib/markdown-checker.sh
source "$SCRIPT_DIR/lib/markdown-checker.sh"

# Capture diff for scope control (excluding auto-generated files)
if [ "$REVIEW_MODE" = "pr" ]; then
  echo "📋 Capturing branch diff (${PR_BASE_BRANCH}...HEAD)..."
  ALL_STAGED_FILES=$(git diff --name-only "${PR_BASE_BRANCH}...HEAD")
  STAGED_DIFF=$(git diff --no-color "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
  # Capture the gate-binding diff hash NOW, before the (minutes-long) Codex review,
  # so the Codex-lead artifact binds to the diff the lead actually reviews. Using a
  # hash re-derived after the review would drift if HEAD/base moved mid-review.
  # compute_pr_diff_hash (no exclusions) matches the gate's binding token exactly.
  PR_REVIEWED_DIFF_HASH=$(compute_pr_diff_hash "$PR_BASE_BRANCH" 2>/dev/null || true)
  FILTERED_FILES=$(git diff --name-only "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
else
  echo "📋 Capturing staged changes..."
  ALL_STAGED_FILES=$(git diff --cached --name-only)
  STAGED_DIFF=$(git diff --cached --no-color -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
  FILTERED_FILES=$(git diff --cached --name-only -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
fi

# Detect what was excluded
EXCLUDED_FILES=""
if [ -n "$ALL_STAGED_FILES" ] && [ -n "$FILTERED_FILES" ]; then
  EXCLUDED_FILES=$(comm -23 <(echo "$ALL_STAGED_FILES" | sort) <(echo "$FILTERED_FILES" | sort))
elif [ -n "$ALL_STAGED_FILES" ]; then
  EXCLUDED_FILES="$ALL_STAGED_FILES"
fi

if [ -n "$EXCLUDED_FILES" ]; then
  EXCLUDED_COUNT=$(echo "$EXCLUDED_FILES" | wc -l | tr -d ' ')
  echo "   Excluded $EXCLUDED_COUNT auto-generated file(s):"
  echo "$EXCLUDED_FILES" | while IFS= read -r f; do echo "     - $f"; done
fi

# If all staged files were excluded, auto-pass
if [ -z "$STAGED_DIFF" ]; then
  if [ -n "$ALL_STAGED_FILES" ]; then
    echo ""
    echo "✅ All changed files are excluded from review — skipping review"
    echo ""
    if [ "$REVIEW_MODE" = "pr" ]; then
      # PR mode: the pre-PR gate rejects the commit marker (ADR 0006), so emit a
      # DISTINCT diff-bound + age-bound marker the gate's fast-bypass branch honors.
      # NOT PASS-FAST (that means "codex lead ran, backstop skipped"); here NO
      # reviewer ran — the whole diff was excluded from review.
      if [ -z "$PR_REVIEWED_DIFF_HASH" ]; then
        echo "❌ excluded-only PR: no reviewed diff hash — refusing marker" >&2
        write_terminal_status setup_error
        exit 1
      fi
      # #252: a fail-closed gate must not let an unreviewed policy file certify
      # that nothing needs review. If this PR itself modifies the exclusion list
      # ($STATE_DIR/review-exclude is in the RAW changed set), refuse the
      # auto-pass and surface as a setup error (no reviewer ran, so the
      # auto-continue loop has nothing to fix — re-running would re-hit this
      # same structural refusal). Use $STATE_DIR (not a hardcoded .claude) so
      # the guard tracks exclude-generated.sh's actual policy-file location
      # when BUSDRIVER_STATE_DIR is customized. Normalize STATE_DIR to git's
      # canonical form first — the line-10 sanitizer still admits './.claude',
      # '.claude/', and '.claude//', which the filesystem resolves but git's
      # --name-only output never emits, so an un-normalized pattern would miss.
      # Collapse slash runs, drop every './' segment (leading and internal),
      # then strip a trailing slash — loop substitutions so repeated/nested
      # forms ('.//.claude', '././.claude') all reduce to git's canonical path.
      _norm_state_dir=$(printf '%s' "$STATE_DIR" \
        | sed -e ':a' -e 's#//#/#g' -e 'ta' \
              -e 's#/\./#/#g' \
              -e ':b' -e 's#^\./##' -e 'tb' \
              -e 's#/$##')
      if echo "$ALL_STAGED_FILES" | grep -qxF "$_norm_state_dir/review-exclude"; then
        echo "❌ excluded-only PR modifies $_norm_state_dir/review-exclude — refusing auto-pass; review required" >&2
        write_terminal_status setup_error
        exit 1
      fi
      mkdir -p "$PR_STATE_DIR"
      printf 'PASS-EXCLUDED-%s-%s\n' "$PR_REVIEWED_DIFF_HASH" "$(date +%s)" > "$PR_REVIEW_MARKER_FILE"
      printf '{"ts":"%s","event":"pr-excluded-only-autopass","gate":"pre-pr","diff_hash":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR_REVIEWED_DIFF_HASH" >> "$PR_STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    else
      # Commit mode: pre-commit gate accepts marker existence without hash
      # verification due to TOCTOU constraints.
      mkdir -p "$STATE_DIR"
      echo "PASS-$(date +%s)" > "$STATE_DIR/litmus-passed.local"
    fi
    # Clean up state file and iteration history
    clear_iteration_history
    rm -f "$STATE_FILE" 2>/dev/null
    exit 0
  fi
  echo "❌ No staged changes to review" >&2
  echo "   Stage your changes first: git add <files>" >&2
  write_terminal_status setup_error
  exit 1
fi
STAGED_FILE_COUNT=$(echo "$FILTERED_FILES" | wc -l | tr -d ' ')
STAGED_DIFF_LINES=$(echo "$STAGED_DIFF" | wc -l | tr -d ' ')
# Weighted line count: additions cost 1x, deletions cost 0.25x
# Rationale: deleted code needs minimal review ("is the delete correct?")
# while new code needs deep analysis for bugs, security, and correctness.
# Use git diff --numstat for reliable counting (avoids grep -c exit code issues
# and edge cases like lines starting with ++ or --)
ADDITION_LINES=0
DELETION_LINES=0
while IFS=$'\t' read -r added removed _file; do
  [ "$added" = "-" ] && added=0   # binary files
  [ "$removed" = "-" ] && removed=0
  ADDITION_LINES=$((ADDITION_LINES + added))
  DELETION_LINES=$((DELETION_LINES + removed))
done < <(if [ "$REVIEW_MODE" = "pr" ]; then git diff --numstat "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null; else git diff --cached --numstat -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null; fi)
WEIGHTED_LINES=$(( ADDITION_LINES + DELETION_LINES / 4 ))
echo "   Staged files: $STAGED_FILE_COUNT"
echo "   Diff lines: $STAGED_DIFF_LINES (added: $ADDITION_LINES, removed: $DELETION_LINES, weighted: $WEIGHTED_LINES)"

# Check if diff is too large for a single review (commit mode only)
# PR mode skips the size check — PR diffs are inherently larger (aggregate of
# all commits) and blocking review on the largest diffs defeats the purpose of
# the safety net. The REVIEW_TIMEOUT (default 30min, configurable via LITMUS_TIMEOUT) handles runaway reviews.
# Council decision 2026-03-21: per-commit and PR size checks serve different
# purposes — fix independently. PR size check was structurally broken.
#
# Per-commit thresholds:
#   Primary metric: weighted lines (additions + deletions/4)
#   Safety ceiling: total raw lines > 2000 regardless of weighting
#   Single-file diffs get a higher threshold since they can't be split further
#   Override: LITMUS_MAX_WEIGHTED_LINES env var (per-project tuning)
if [ "$REVIEW_MODE" = "pr" ]; then
  # PR mode: soft warning only — large PR diffs may be slow or hit context limits,
  # but blocking them defeats the safety net. The REVIEW_TIMEOUT (default 30min) handles
  # truly runaway reviews. Warn so the user knows to expect a longer wait.
  if [ "$WEIGHTED_LINES" -gt 2000 ]; then
    echo ""
    echo "⚠️  Large PR diff ($WEIGHTED_LINES weighted lines) — review may be slow or hit context limits"
    echo "   Consider splitting into smaller PRs if review times out (${REVIEW_TIMEOUT:-600}s limit)"
  fi
else
  # Commit mode: hard size gate with env var override
  MAX_WEIGHTED_LINES="${LITMUS_MAX_WEIGHTED_LINES:-800}"
  # Validate env var is numeric — fall back to default if not
  case "$MAX_WEIGHTED_LINES" in
    ''|*[!0-9]*) echo "⚠️  LITMUS_MAX_WEIGHTED_LINES='$MAX_WEIGHTED_LINES' is not numeric, using default 800"; MAX_WEIGHTED_LINES=800 ;;
  esac
  MAX_WEIGHTED_LINES_SINGLE_FILE=2000
  MAX_TOTAL_LINES_CEILING=2000
  MAX_STAGED_FILES="${LITMUS_MAX_STAGED_FILES:-8}"
  EFFECTIVE_MAX=$MAX_WEIGHTED_LINES
  if [ "$STAGED_FILE_COUNT" -eq 1 ]; then
    EFFECTIVE_MAX=$MAX_WEIGHTED_LINES_SINGLE_FILE
  fi
  TOO_LARGE=false
  TOO_LARGE_REASON=""
  if [ "$WEIGHTED_LINES" -gt "$EFFECTIVE_MAX" ]; then
    TOO_LARGE=true
    TOO_LARGE_REASON="weighted lines ($WEIGHTED_LINES) > $EFFECTIVE_MAX"
  elif [ "$((ADDITION_LINES + DELETION_LINES))" -gt "$MAX_TOTAL_LINES_CEILING" ]; then
    TOO_LARGE=true
    TOO_LARGE_REASON="total changed lines ($((ADDITION_LINES + DELETION_LINES))) > $MAX_TOTAL_LINES_CEILING ceiling"
  else
    # Count only files with additions for file threshold — deletion-only files
    # have near-zero review complexity and shouldn't trigger splitting
    FILES_WITH_ADDITIONS=0
    while IFS=$'\t' read -r added _removed _file; do
      [ "$added" = "-" ] && added=0
      [ "$added" -gt 0 ] 2>/dev/null && FILES_WITH_ADDITIONS=$((FILES_WITH_ADDITIONS + 1))
    done < <(git diff --cached --numstat -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null)
    if [ "$FILES_WITH_ADDITIONS" -gt "$MAX_STAGED_FILES" ]; then
      TOO_LARGE=true
      TOO_LARGE_REASON="files with additions ($FILES_WITH_ADDITIONS) > $MAX_STAGED_FILES (total: $STAGED_FILE_COUNT)"
    fi
  fi
  if [ "$TOO_LARGE" = true ]; then
    echo ""
    echo "⚠️  Diff too large for single review ($TOO_LARGE_REASON)"
    echo "   Thresholds: weighted >$EFFECTIVE_MAX OR total >$MAX_TOTAL_LINES_CEILING OR files >$MAX_STAGED_FILES"
    echo "   Override: LITMUS_MAX_WEIGHTED_LINES=$((WEIGHTED_LINES + 100)) or LITMUS_MAX_STAGED_FILES=$((STAGED_FILE_COUNT + 2)) to raise"
    echo ""
    # Run suggest-split helper to show grouping advice (only useful for multi-file diffs)
    if [ "$STAGED_FILE_COUNT" -gt 1 ]; then
      bash "$SCRIPT_DIR/suggest-split.sh"
      echo ""
    fi
    echo "EXIT_CODE=2 (TOO_LARGE: split into smaller commits before reviewing)"
    exit 2
  fi
fi

# Run SAST scan on changed files (deterministic, runs before LLM)
echo ""
echo "🔒 Running static analysis..."
SAST_FINDINGS_RAW=$(run_sast_scan "$FILTERED_FILES")

# Filter SAST findings to only lines within diff hunks (± 3 line margin).
# Pre-existing findings in untouched lines are noise, not signal.
# Uses git diff --unified=0 to get exact hunk ranges.
DIFF_FOR_FILTER=""
if [ "$REVIEW_MODE" = "pr" ]; then
  DIFF_FOR_FILTER=$(git diff --unified=0 "${PR_BASE_BRANCH}...HEAD" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null || true)
else
  DIFF_FOR_FILTER=$(git diff --cached --unified=0 -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null || true)
fi
SAST_FINDINGS=$(printf '%s\n---DIFF---\n%s' "$SAST_FINDINGS_RAW" "$DIFF_FOR_FILTER" | python3 -c "
import sys, json, re

content = sys.stdin.read()
parts = content.split('---DIFF---\n', 1)
findings_raw = parts[0].strip()
diff_text = parts[1] if len(parts) > 1 else ''

try:
    findings = json.loads(findings_raw)
except (json.JSONDecodeError, ValueError):
    sys.exit(1)  # fail so shell fallback preserves raw findings

if not findings or not diff_text:
    print(json.dumps(findings)); sys.exit(0)

# Parse diff hunks: extract (file, start, end) ranges
HUNK_MARGIN = 3
hunks = {}  # file -> list of (start, end) tuples
current_file = None
for line in diff_text.split('\n'):
    if line.startswith('+++ b/'):
        current_file = line[6:]
        hunks.setdefault(current_file, [])  # register file even if no @@ hunks (binary)
    elif line.startswith('@@') and current_file:
        # Parse @@ -old +new,count @@ format
        m = re.search(r'\+(\d+)(?:,(\d+))?', line)
        if m:
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) else 1
            end = start + max(count - 1, 0)
            hunks.setdefault(current_file, []).append((start - HUNK_MARGIN, end + HUNK_MARGIN))

# Filter: keep findings whose file+line falls within a hunk range
filtered = []
for f in findings:
    fpath = f.get('file', '')
    fline = f.get('line', 0)
    if fpath not in hunks:
        # File mentioned in findings but not in diff at all — drop
        # BUT: if file appears in diff as binary (no @@ hunks), keep all findings
        continue
    if not hunks[fpath]:
        # Binary diff or no hunks parsed — keep all findings for this file
        filtered.append(f)
    elif fline == 0 or any(start <= fline <= end for start, end in hunks[fpath]):
        # Preserve file-level findings (line 0) — e.g. trufflehog secrets
        filtered.append(f)

print(json.dumps(filtered))
" 2>/dev/null) || SAST_FINDINGS="$SAST_FINDINGS_RAW"
SAST_COUNT=$(echo "$SAST_FINDINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# Run markdown checks if .md files are staged
MARKDOWN_FINDINGS=$(run_markdown_checks "$FILTERED_FILES")
MD_COUNT=$(echo "$MARKDOWN_FINDINGS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# ── Short-circuit gate (commit mode only) ────────────────────────────
# Skip Codex CLI review when ALL conditions hold:
#   - REVIEW_MODE = commit (PR mode always needs full review)
#   - Weighted diff < LITMUS_SHORTCIRCUIT_MAX_LINES (default 10)
#   - SAST findings = 0 (gitleaks, semgrep, shellcheck, trufflehog all clean)
#   - Markdown findings = 0
#   - No changed files match sensitive-path pattern
# Fail-closed: ANY condition failing falls through to normal Codex review.
# Disable entirely with LITMUS_SHORTCIRCUIT_DISABLED=1.
if [ "$REVIEW_MODE" = "commit" ] && [ "${LITMUS_SHORTCIRCUIT_DISABLED:-0}" != "1" ]; then
  SC_MAX_LINES="${LITMUS_SHORTCIRCUIT_MAX_LINES:-10}"
  case "$SC_MAX_LINES" in
    ''|*[!0-9]*) SC_MAX_LINES=10 ;;
  esac

  # Sensitive-path pattern: paths where even tiny changes can have outsized
  # blast radius (workflows, secrets, crypto material, lockfiles, env files, IaC).
  # Extensible via LITMUS_SHORTCIRCUIT_EXTRA_SENSITIVE (regex appended with |).
  # Notes:
  #   - \.env (bare) matches .env, .env.local, .envrc, etc.
  #   - (^|/)secrets?/ matches relative paths (secrets/foo.yml, src/secrets/...)
  SC_SENSITIVE_PATTERN='(^|/)(\.github/|\.env|Dockerfile|docker-compose|\.key$|\.pem$|\.p12$|package-lock\.json$|pnpm-lock\.yaml$|yarn\.lock$|Cargo\.lock$|go\.sum$|uv\.lock$|Pipfile\.lock$|Gemfile\.lock$|composer\.lock$|\.tf$|migrations?/|secrets?/)'
  if [ -n "${LITMUS_SHORTCIRCUIT_EXTRA_SENSITIVE:-}" ]; then
    SC_SENSITIVE_PATTERN="${SC_SENSITIVE_PATTERN}|${LITMUS_SHORTCIRCUIT_EXTRA_SENSITIVE}"
  fi

  # Fail-closed on regex errors: grep -E exit 0 = match, 1 = no match (expected),
  # 2 = invalid regex (treat as "unable to verify" → skip short-circuit).
  SC_HAS_SENSITIVE=""
  SC_REGEX_OK=true
  if [ -n "$FILTERED_FILES" ]; then
    set +e
    SC_HAS_SENSITIVE=$(printf '%s\n' "$FILTERED_FILES" | grep -E "$SC_SENSITIVE_PATTERN")
    SC_GREP_EXIT=$?
    set -e
    if [ "$SC_GREP_EXIT" -eq 2 ]; then
      echo "⚠️  Short-circuit: invalid regex in LITMUS_SHORTCIRCUIT_EXTRA_SENSITIVE — falling through to full review"
      SC_REGEX_OK=false
    fi
  fi

  if [ "$SC_REGEX_OK" = true ] \
      && [ "$WEIGHTED_LINES" -lt "$SC_MAX_LINES" ] \
      && [ "$SAST_COUNT" -eq 0 ] \
      && [ "$MD_COUNT" -eq 0 ] \
      && [ -z "$SC_HAS_SENSITIVE" ]; then
    echo ""
    echo "⚡ Short-circuit PASS — skipping Codex CLI review"
    echo "   Diff: $WEIGHTED_LINES weighted lines (< $SC_MAX_LINES threshold)"
    echo "   SAST: 0 findings | Markdown: 0 findings | Sensitive paths: none"
    echo ""

    # Log metric (same schema as normal review — cli labeled as short-circuit)
    log_review_metrics "PASS" "0" "$ITERATION" "$REVIEW_MODE" "short-circuit" '{"status":"PASS","issues":[],"short_circuit":true}'

    # Write commit marker (same format as normal PASS)
    mkdir -p "$STATE_DIR"
    git diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1 > "$STATE_DIR/litmus-passed.local"

    # Audit trail — distinct event, separate from skip-bypass
    printf '{"ts":"%s","event":"short-circuit-pass","gate":"pre-commit","weighted_lines":%d}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WEIGHTED_LINES" >> "$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true

    # Cleanup
    clear_iteration_history
    rm -f "$STATE_FILE" 2>/dev/null

    echo "Next steps:"
    echo "   1. Commit: git commit -m 'Your message'"
    echo ""
    exit 0
  fi
fi

# Collect smart context (callers, importers of changed code)
echo ""
echo "🔎 Collecting cross-file context..."
SMART_CONTEXT_OUTPUT=$(collect_smart_context "$STAGED_DIFF" "$FILTERED_FILES" || true)

# Collect docs context (doc files referencing changed code + extracted symbols)
DOCS_CONTEXT_OUTPUT=$(collect_docs_context "$FILTERED_FILES" "$STAGED_DIFF" || true)

# Load previous changelog for context continuity
PREV_CHANGELOG=$("$SCRIPT_DIR/load_changelog.sh" 2>/dev/null || echo "")

# Load iteration history for convergence
ITER_HISTORY=$(load_iteration_history)

# Substitute all placeholders into the prompt
FINAL_PROMPT="${PROMPT/\{\{PREV_CHANGELOG\}\}/$PREV_CHANGELOG}"
FINAL_PROMPT="${FINAL_PROMPT/\{\{STAGED_DIFF\}\}/$STAGED_DIFF}"
FINAL_PROMPT="${FINAL_PROMPT/\{\{ITERATION_HISTORY\}\}/$ITER_HISTORY}"

# Inject SAST pre-check results
SAST_PRECHECK_TEXT=""
if [ "$SAST_COUNT" -gt 0 ]; then
  SAST_PRECHECK_TEXT="## SAST Pre-Check Results (deterministic — these are confirmed findings)
The following issues were found by static analysis tools. These are NOT hallucinations — they are real findings from automated scanners. Include them in your output as-is.
$(echo "$SAST_FINDINGS" | python3 -c "
import sys, json
for f in json.load(sys.stdin):
    print(f'- [{f[\"severity\"].upper()}] {f[\"file\"]}:{f[\"line\"]} — {f[\"description\"]}')
")"
fi
FINAL_PROMPT="${FINAL_PROMPT/\{\{SAST_PRECHECK\}\}/$SAST_PRECHECK_TEXT}"

# Budget cap for enrichment context (prevent prompt bloat)
MAX_ENRICHMENT_LINES="${LITMUS_MAX_ENRICHMENT_LINES:-100}"
case "$MAX_ENRICHMENT_LINES" in
  ''|*[!0-9]*) echo "⚠️  LITMUS_MAX_ENRICHMENT_LINES='$MAX_ENRICHMENT_LINES' is not numeric, using default 100" >&2; MAX_ENRICHMENT_LINES=100 ;;
esac
if [ -n "$SMART_CONTEXT_OUTPUT" ]; then
  SMART_CONTEXT_OUTPUT=$(echo "$SMART_CONTEXT_OUTPUT" | head -n "$MAX_ENRICHMENT_LINES")
fi
if [ -n "$DOCS_CONTEXT_OUTPUT" ]; then
  DOCS_CONTEXT_OUTPUT=$(echo "$DOCS_CONTEXT_OUTPUT" | head -n "$MAX_ENRICHMENT_LINES")
fi

# Inject smart context
FINAL_PROMPT="${FINAL_PROMPT/\{\{SMART_CONTEXT\}\}/$SMART_CONTEXT_OUTPUT}"

# Inject docs context
FINAL_PROMPT="${FINAL_PROMPT/\{\{DOCS_CONTEXT\}\}/$DOCS_CONTEXT_OUTPUT}"

# Inject PR commit history (PR mode only). init-review-loop.sh emits only the
# {{HISTORY_CONTEXT}} placeholder; the runtime computes/caps/substitutes it here
# (mirroring the SMART_CONTEXT pattern) so the HISTORY lens reads injected data
# and the agent never runs git itself. Capped by MAX_ENRICHMENT_LINES. In commit
# mode the placeholder is absent, so this substitution is a harmless no-op.
HISTORY_CONTEXT_OUTPUT=""
if [ "$REVIEW_MODE" = "pr" ]; then
  _HIST_MERGE_BASE=$(git merge-base "${PR_BASE_BRANCH}" HEAD 2>/dev/null || true)
  if [ -n "$_HIST_MERGE_BASE" ]; then
    HISTORY_CONTEXT_OUTPUT=$(git log --oneline --stat "${_HIST_MERGE_BASE}..HEAD" 2>/dev/null \
      | head -n "$MAX_ENRICHMENT_LINES" || true)
  fi
fi
FINAL_PROMPT="${FINAL_PROMPT/\{\{HISTORY_CONTEXT\}\}/$HISTORY_CONTEXT_OUTPUT}"

# Run review via resolved CLI
echo "🔬 Running $RESOLVED_CLI review (loop attempt $ITERATION/$MAX_ITER)..."
echo ""

REVIEW_TIMEOUT="${LITMUS_TIMEOUT:-1200}"  # 20 minutes default, configurable via env var
set +e
REVIEW_OUTPUT=$(execute_review "$RESOLVED_CLI" "$FINAL_PROMPT" "$REVIEW_TIMEOUT")
REVIEW_EXIT=$?
set -e

if [ "$REVIEW_EXIT" -eq 3 ] && [ "$REVIEW_OUTPUT" = "BUILTIN_FALLBACK" ]; then
  # Builtin fallback — write prompt to temp file for SKILL agent dispatch
  BUILTIN_PROMPT_FILE=$(mktemp -t busdriver-review-XXXXXX)
  chmod 600 "$BUILTIN_PROMPT_FILE"
  printf '%s' "$FINAL_PROMPT" > "$BUILTIN_PROMPT_FILE"
  mkdir -p "$STATE_DIR"
  echo "$BUILTIN_PROMPT_FILE" > "$STATE_DIR/builtin-review-prompt-path.local"
  echo "ℹ️  No external review CLI available — using built-in agent review" >&2
  echo "   Prompt saved to $BUILTIN_PROMPT_FILE" >&2
  echo "   The litmus skill will dispatch the code-reviewer agent." >&2
  clear_iteration_history
  rm -f "$STATE_FILE" 2>/dev/null
  exit 3
elif [ "$REVIEW_EXIT" -eq 124 ]; then
  echo "❌ Error: $RESOLVED_CLI review timed out after ${REVIEW_TIMEOUT}s" >&2
  echo "" >&2
  echo "   The review took too long. This usually means the diff is too complex." >&2
  echo "   Try splitting into smaller commits." >&2
  echo "" >&2
  bash "$SCRIPT_DIR/suggest-split.sh" >&2
  write_terminal_status infra_failure
  exit 124
elif [ "$REVIEW_EXIT" -ne 0 ]; then
  echo "❌ Error: $RESOLVED_CLI review failed (exit code $REVIEW_EXIT)" >&2
  echo "" >&2
  echo "   Output:" >&2
  echo "$REVIEW_OUTPUT" >&2
  write_terminal_status infra_failure
  exit 1
fi

echo "✅ Review completed"
echo ""

# Parse result
echo "📊 Parsing results..."
echo ""
echo "   Debug: Saving raw $RESOLVED_CLI output..."
_RAW_OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/litmus-raw-output.XXXXXX")
echo "$REVIEW_OUTPUT" > "$_RAW_OUTPUT_FILE"
echo "   Saved to: $_RAW_OUTPUT_FILE (CLI: $RESOLVED_CLI)"
echo ""

# Extract JSON from output using shared robust parser
# Handles reasoning mode, interleaved exec outputs, unmatched braces in code
# Resolve extractor — prefer plugin location, fall back to marketplace, then legacy
EXTRACTOR=""
for _candidate in \
    "${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/skills/blueprint-review/scripts/lib/extract_review_json.py" \
    "$HOME/.claude/plugins/marketplaces/busdriver/skills/blueprint-review/scripts/lib/extract_review_json.py" \
    "$HOME/.claude/skills/blueprint-review/scripts/lib/extract_review_json.py"; do
    if [ -f "$_candidate" ]; then
        EXTRACTOR="$_candidate"
        break
    fi
done
set +e
if [ -n "$EXTRACTOR" ]; then
    JSON_OUTPUT=$(echo "$REVIEW_OUTPUT" | python3 "$EXTRACTOR" -)
    EXTRACT_EXIT=$?
else
    echo "   ⚠️  JSON extractor not found, falling back to narrative parser" >&2
    JSON_OUTPUT=""
    EXTRACT_EXIT=1
fi
set -e

# If Python extraction failed, try parsing narrative output
if [ -z "$JSON_OUTPUT" ]; then
  echo "   No JSON found, attempting to parse narrative output..." >&2
  # Telemetry: track how often the narrative fallback is triggered
  mkdir -p "$STATE_DIR"
  printf '{"ts":"%s","event":"narrative-fallback-triggered","cli":"%s","iteration":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RESOLVED_CLI" "$ITERATION" \
    >> "$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
  set +e
  JSON_OUTPUT=$(echo "$REVIEW_OUTPUT" | python3 "$SCRIPT_DIR/lib/parse-narrative.py" 2>&1)
  PARSE_EXIT=$?
  set -e

  if [ $PARSE_EXIT -ne 0 ] || [ -z "$JSON_OUTPUT" ]; then
    echo "⚠️  Warning: Could not parse review output" >&2
    echo "" >&2
    echo "   Codex returned narrative feedback that couldn't be parsed." >&2
    echo "   Review output:" >&2
    echo "$REVIEW_OUTPUT" >&2
    echo "" >&2
    echo "   See references/troubleshooting.md for handling narrative output" >&2
    write_terminal_status infra_failure
    exit 1
  fi

  echo "   ✓ Successfully parsed narrative to JSON" >&2
fi

# Validate JSON syntax and schema structure
validate_json "$JSON_OUTPUT" || { write_terminal_status infra_failure; exit 1; }
validate_review_schema "$JSON_OUTPUT" || { write_terminal_status infra_failure; exit 1; }

# Extract status
REVIEW_STATUS=$(echo "$JSON_OUTPUT" | jq -r '.status')
ISSUE_COUNT=$(echo "$JSON_OUTPUT" | jq -r '.issues | length')

echo "   LLM status: $REVIEW_STATUS"
echo "   LLM issues found: $ISSUE_COUNT"
echo ""

# Merge SAST + markdown + LLM findings
MERGER="$SCRIPT_DIR/lib/merge-findings.py"
# Always run merger: it handles iteration-aware severity relaxation (after iteration 2,
# only HIGH blocks) even when there are no SAST/markdown findings to merge.
if [ -f "$MERGER" ]; then
  echo "📊 Merging SAST + markdown + LLM findings..."
  # Use stdin instead of argv to avoid ARG_MAX limits on large SAST output
  # Pass iteration number so merge-findings can relax severity rules after iteration 2
  MERGED_OUTPUT=$(printf '%s\n%s\n%s\n' "$SAST_FINDINGS" "$MARKDOWN_FINDINGS" "$JSON_OUTPUT" | LITMUS_ITERATION="$ITERATION" python3 "$MERGER" 2>/dev/null) || MERGED_OUTPUT=""
  if [ -n "$MERGED_OUTPUT" ]; then
    JSON_OUTPUT="$MERGED_OUTPUT"
    REVIEW_STATUS=$(echo "$JSON_OUTPUT" | jq -r '.status')
    ISSUE_COUNT=$(echo "$JSON_OUTPUT" | jq -r '.issues | length')
    echo "   Merged status: $REVIEW_STATUS ($ISSUE_COUNT total issues)"
    echo ""
  else
    # Merger failed — fail-closed, don't silently pass
    echo "⚠️  Findings merger failed — fail-closed" >&2
    REVIEW_STATUS="FAIL"
  fi
fi

# Log metrics for persistent trend analysis
log_review_metrics "$REVIEW_STATUS" "$ISSUE_COUNT" "$ITERATION" "$REVIEW_MODE" "$RESOLVED_CLI" "$JSON_OUTPUT"

# Check for completion promise
if [ "$COMPLETION_PROMISE" != "null" ] && [ -n "$COMPLETION_PROMISE" ]; then
  if echo "$REVIEW_OUTPUT" | grep -q "<promise>$COMPLETION_PROMISE</promise>"; then
    echo "✅ Completion promise detected: $COMPLETION_PROMISE"
    echo ""

    # Clear iteration history and clean up temporary files
    clear_iteration_history
    echo "🧹 Cleaning up temporary files..."
    rm -f "$STATE_FILE" 2>/dev/null
    rm -f "${_RAW_OUTPUT_FILE:-}" 2>/dev/null

    echo "🎉 Review loop completed successfully!"
    exit 0
  fi
fi

# Update state file
set_yaml_value "iteration" "$((ITERATION + 1))" "$STATE_FILE"
set_yaml_value "review_status" "\"$REVIEW_STATUS\"" "$STATE_FILE"

# Save last result (escape quotes for YAML)
ESCAPED_JSON=$(echo "$JSON_OUTPUT" | sed 's/"/\\"/g')
set_yaml_value "last_result" "\"$ESCAPED_JSON\"" "$STATE_FILE"

# Display results
if [ "$REVIEW_STATUS" = "PASS" ]; then
  echo "✅ PASS - No issues found (or only low severity)"
  echo ""

  # Clear iteration history on success
  clear_iteration_history

  # Write review-passed marker for the appropriate gate
  mkdir -p "$STATE_DIR"
  if [ "$REVIEW_MODE" = "pr" ]; then
    # PR mode: the gate marker is NOT written here on the default path. After this
    # Codex lead PASS, Claude must run the read-only Security/Bugs backstop
    # (Step 2), persist its verdict via --write-backstop-verdict, then call
    # --write-pr-marker — which requires BOTH the Codex-lead AND backstop PASS
    # artifacts (diff-bound). Writing the marker here would short-circuit the
    # backstop. We DO record the Codex lead's clean verdict so --write-pr-marker
    # can verify the lead voice independently of the backstop.
    if [ "${LITMUS_PR_FAST:-0}" = "1" ]; then
      # Audited fast bypass: skips the multi-agent backstop and writes a DISTINCT,
      # diff-bound fast marker — "PASS-FAST-<diff_hash>-<epoch>", NOT a bare hash.
      # Binds to PR_REVIEWED_DIFF_HASH (captured BEFORE the review) so the marker
      # ties to the diff Codex actually reviewed (same TOCTOU reasoning as the lead
      # artifact). The gate accepts this ONLY via its explicit fast-bypass branch
      # (matching diff_hash AND within max-age), never the normal dual-artifact
      # path, so a preserved fast marker (a failed `gh pr create` keeps markers)
      # cannot later authorize a changed diff.
      if [ -z "$PR_REVIEWED_DIFF_HASH" ]; then
        echo "❌ LITMUS_PR_FAST: no reviewed diff hash — refusing fast marker" >&2
        write_terminal_status setup_error
        exit 1
      fi
      mkdir -p "$PR_STATE_DIR"
      printf 'PASS-FAST-%s-%s\n' "$PR_REVIEWED_DIFF_HASH" "$(date +%s)" > "$PR_REVIEW_MARKER_FILE"
      printf '{"ts":"%s","event":"pr-fast-bypass","gate":"pre-pr","diff_hash":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR_REVIEWED_DIFF_HASH" >> "$PR_STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
      echo "   ⚠️  LITMUS_PR_FAST=1 — skipped multi-agent backstop (audited fast bypass, logged)"
    else
      if write_codex_lead_verdict "$PR_REVIEWED_DIFF_HASH"; then
        echo "   ✅ Codex lead PASS recorded (pr-codex-lead.local.json)."
        echo "   ℹ️  Claude Security/Bugs backstop pending — dispatch the read-only"
        echo "       pr-security-backstop agent, then run --write-backstop-verdict and"
        echo "       --write-pr-marker (the marker requires BOTH voices PASS)."
      else
        echo "❌ Could not record Codex lead verdict (missing base / empty diff)" >&2
        write_terminal_status setup_error
        exit 1
      fi
    fi
  else
    # Commit mode: write commit marker for pre-commit gate
    git diff --cached 2>/dev/null | (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1 > "$STATE_DIR/litmus-passed.local"
  fi

  # Clean up temporary files
  echo "🧹 Cleaning up temporary files..."
  rm -f "$STATE_FILE" 2>/dev/null
  rm -f "${_RAW_OUTPUT_FILE:-}" 2>/dev/null
  echo "   ✓ Removed state file"
  echo "   ✓ Cleaned up temp files"
  echo "   ✓ Cleared iteration history"
  echo ""

  echo "Next steps:"
  echo "   1. Run tests: npm test (or appropriate test command)"
  echo "   2. Commit: git commit -m 'Your message'"
  echo "   3. (Optional) Save changelog: bash scripts/save_changelog.sh"
  echo ""
  exit 0
else
  # Stall detection: if blocking issue set is identical to previous iteration,
  # the loop is stuck and further iterations won't help (Critic P-1 fix).
  # Does NOT auto-pass — reports stall and exits non-zero for caller to decide.
  CURRENT_FINGERPRINT=$(compute_issue_fingerprint "$JSON_OUTPUT")
  if is_stalled "$CURRENT_FINGERPRINT"; then
    echo "⚠️  STALL DETECTED - Same blocking issues as previous iteration"
    echo "   The review loop is not converging. Remaining issues may be false positives"
    echo "   or require manual judgment."
    echo ""
    echo "Stalled issues:"
    echo "$JSON_OUTPUT" | jq -r '.issues[] | "  [\(.severity)] \(.file):\(.line) - \(.description)"'
    echo ""
    echo "Options:"
    echo "   1. Fix the issues above and re-run"
    echo "   2. Run: touch $(git rev-parse --show-toplevel 2>/dev/null || echo '.')/$STATE_DIR/skip-litmus.local"
    echo ""
    rm -f "${_RAW_OUTPUT_FILE:-}" 2>/dev/null
    write_terminal_status stall
    exit 1
  fi

  echo "❌ FAIL - Issues found that need fixing"
  echo ""

  # Save this iteration's issues for next pass
  append_iteration_history "$ITERATION" "$JSON_OUTPUT"

  echo "Issues:"
  echo "$JSON_OUTPUT" | jq -r '.issues[] | "  [\(.severity)] \(.file):\(.line) - \(.description)"'
  echo ""
  echo "Next steps:"
  echo "   1. Fix the issues listed above"
  echo "   2. Stage changes: git add <files>"
  echo "   3. Run review again: bash scripts/run-review-loop.sh"
  echo "   4. Loop continues automatically until PASS"
  echo ""
  rm -f "${_RAW_OUTPUT_FILE:-}" 2>/dev/null
  write_terminal_status review_findings
  exit 1
fi
