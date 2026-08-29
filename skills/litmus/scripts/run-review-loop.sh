#!/bin/bash
# Main litmus review loop script
# Reads state, runs review, parses results, updates state, handles iteration logic

set -euo pipefail
# #576: neutralise `refs/replace` for EVERY git call in this process, not just the
# annotated ones. A replacement object can substitute the commit or tree that
# `git diff` resolves, so a crafted refs/replace entry could make the reviewer read
# fabricated history while the real content is what gets committed. Annotating call
# sites one at a time left merge-base resolution, name-only/numstat classification and
# the short-circuit path scan still honouring replacements — the env var covers them
# all, and the explicit --no-replace-objects on the canonical hash stays as
# documentation of the invariant.
export GIT_NO_REPLACE_OBJECTS=1


STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) so
# repo-root joins like "$REPO_TOP/$STATE_DIR" resolve to the configured state dir.
case "$STATE_DIR" in ""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
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
# clear_terminal_status: drop the field at the START of a run, so its presence means
# "THIS run ended" rather than "some run once ended". A resumed loop (status=FAIL,
# operator fixed the findings, ran this script again) otherwise carries the previous
# iteration's terminal_status for the whole of the next review — and a reader that
# treats the field as proof of a finished run would classify a LIVE review as stale.
# No-op when the file or the field is absent.
clear_terminal_status() {
    [[ -f "$STATE_FILE" ]] || return 0
    # Only an ACTIVE loop is ours to touch. An inactive state file (e.g. a completed
    # max_iterations run) belongs to whoever reads it next; this script exits without
    # reviewing in that case, so mutating it would be a side effect of a no-op run.
    # Guarding here — rather than at the call site — is what lets the call sit before
    # the setup steps, which is the whole point: the window this closes is the one
    # BETWEEN deciding to run and the field being cleared.
    # Read `active` through get_yaml_value — the SAME reader the rest of this script
    # uses. An independently stricter parse here made the two disagree about one file:
    # get_yaml_value takes the FIRST declaration, so on a file with `active: true`
    # followed by `active: false` the loop below proceeds on true while a
    # last-declaration parse here saw false and declined to clear — leaving a stale
    # terminal_status in place for the whole run, which is precisely what this function
    # exists to prevent. Agreeing with the consumer matters more than being strict
    # alone; a file with contradictory declarations is refused outright by the
    # dispatcher's own classification, which is where that call belongs.
    local _cts_active
    _cts_active=$(get_yaml_value "active" "$STATE_FILE" 2>/dev/null || echo "")
    [ "$_cts_active" = "true" ] || return 0
    grep -q '^terminal_status:' "$STATE_FILE" || return 0
    # mktemp, not "${STATE_FILE}.tmp.$$": a predictable temp path can be pre-created as
    # a symlink, and then the redirect writes through it and the mv installs it AS the
    # state file. mktemp refuses an existing path and creates with a private mode.
    # Never propagate a non-zero return to the caller: the bare call site below is
    # `clear_terminal_status` with no `||`, and under `set -e` (already on by the time
    # this runs, well after the lock is held) a non-zero return here would abort the
    # whole script — silently, with no diagnostic, and with terminal_status left
    # uncleared. That is the exact wedged-state condition this change exists to
    # remove. mktemp failing is reported and treated as "leave the field in place"
    # rather than fatal; `grep -v` finding nothing to keep (every line in the file
    # matched `^terminal_status:`, which `grep -v` reports as exit 1) is treated as
    # "nothing to write back", not an error.
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") || {
        echo "⚠️  clear_terminal_status: mktemp failed in $(dirname "$STATE_FILE"); leaving terminal_status in place" >&2
        return 0
    }
    # `set -e` is suspended only for the `if` CONDITION, not for its body — so an
    # unguarded `mv` here would abort the run on failure (read-only dir, cross-device
    # rename, a directory installed at STATE_FILE), which is the exact fatal-abort this
    # function promises never to do. Guard it like the mktemp above: report, keep the
    # field, carry on.
    # Every command on these paths is guarded, `rm -f` included: `rm -f` still fails on
    # an unlink it is not permitted to make (an unwritable directory, an immutable
    # flag), and an unguarded failure here aborts under `set -e` exactly as an
    # unguarded `mv` would — for a temp file whose loss is not worth a dead review.
    if grep -v '^terminal_status:' "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE" || {
            echo "⚠️  clear_terminal_status: mv into $STATE_FILE failed; leaving terminal_status in place" >&2
            rm -f "$tmp" || true
        }
    else
        rm -f "$tmp" || true
    fi
    return 0
}

write_terminal_status() {
    local status="$1"
    case "$status" in
        review_findings|stall|max_iterations|infra_failure|setup_error|too_large) ;;
        *) printf 'write_terminal_status: invalid %s\n' "$status" >&2; return 1 ;;
    esac
    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || touch "$STATE_FILE"
    # Same mktemp reasoning as clear_terminal_status above: a predictable
    # "${STATE_FILE}.tmp.$$" can be pre-created as a symlink, and every branch below
    # ends in `mv "$tmp" "$STATE_FILE"`. Pre-existing pattern, fixed here rather than
    # left as the one writer still carrying it.
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") || return 1
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

# Take the review lock for the lifetime of this run — BEFORE every subcommand branch,
# not just the review path. All of them write litmus-state.md: --auto-pr-review runs
# `init-review-loop.sh --force`, and --write-pr-marker and --run-backstop each call
# write_terminal_status on failure. Acquiring after any one of them would let that
# branch mutate the state file out from under a review that already owns the lock, and
# fail only once the damage was done. "Every writer takes the lock" has to mean every
# entry point, or it means nothing.
#
# This lock is also the only thing that lets another reader distinguish "a review is in
# flight" from "a review died". Released via the EXIT trap on every path.
#
# `|| _LOCK_RC=$?`, not a bare call: this script runs under `set -e`, so a bare
# `review_lock_acquire` returning non-zero aborts here and the diagnostics below never
# print. The refusal would still happen — silently, with no way for the operator to
# learn that a concurrent review is the reason.
# shellcheck source=lib/review-lock.sh
source "$SCRIPT_DIR/lib/review-lock.sh"
_LOCK_RC=0
review_lock_acquire || _LOCK_RC=$?
if [ "$_LOCK_RC" = "2" ]; then
  echo "❌ Cannot use the litmus state directory: $STATE_DIR" >&2
  echo "   The lock could not be created: $(review_lock_path)" >&2
  echo "   Inspect that path — a file or directory may already occupy it, a stale" >&2
  echo "   symlink may point at an unreadable target, or the directory may reject" >&2
  echo "   symlink creation." >&2
  exit 1
fi
if [ "$_LOCK_RC" != "0" ]; then
  echo "❌ Another litmus review holds the review lock in $STATE_DIR" >&2
  echo "   Owner: pid $(review_lock_owner) ($(review_lock_owner_state))" >&2
  echo "   Lock:  $(review_lock_path)" >&2
  echo "" >&2
  echo "   If the owner is running, wait — two reviews share one state file." >&2
  echo "   If it is NOT running, that review was killed; the lock is an orphan." >&2
  echo "   Remove it yourself: rm -f $(review_lock_path)" >&2
  echo "   (Reclaiming it automatically cannot be made race-free in shell; see" >&2
  echo "    lib/review-lock.sh for why a human does it.)" >&2
  exit 1
fi
# Neutralise any INHERITED value before the trap can act on it. The trap unlinks
# this path on every exit path, including ones taken long before the capture block
# sets it, so an exported _INDEX_SNAPSHOT would turn the cleanup into a delete of
# an attacker-chosen writable file. Env is repo-injectable (#325 / ADR 0016).
_INDEX_SNAPSHOT=""
# Same blanking, same reason, for the exclusion snapshots the trap also unlinks: they
# are created mid-run, and `source "$EXCL_LOGIC_SOURCE"` or the sentinel append can
# exit under `set -e` before the in-flow cleanup, leaking private temp files.
EXCL_POLICY_PINNED_TMP=""
EXCL_LOGIC_PINNED_TMP=""
trap 'review_lock_release; rm -f "${_INDEX_SNAPSHOT:-}" "${EXCL_POLICY_PINNED_TMP:-}" "${EXCL_LOGIC_PINNED_TMP:-}" 2>/dev/null || true' EXIT
# Children that take the lock themselves — init-review-loop.sh, invoked directly below
# and again from the loop — must see this lock as theirs, not deadlock against it.
review_lock_export_owner

# Load metrics persistence
# shellcheck source=lib/log-metrics.sh
source "$SCRIPT_DIR/lib/log-metrics.sh"

# Load single-pass prompt renderer (bash ≥5.2 `&`-in-replacement fix + injected
# values can't shadow later placeholders, #393)
# shellcheck source=lib/inject.sh
source "$SCRIPT_DIR/lib/inject.sh"

# ── PR-mode dual-voice artifact contract ──────────────────────────────
# Both artifacts gate `gh pr create` in PR mode and are protected in
# pre-implementation-gate.sh MARKER_FILES. The backstop verdict is written ONLY
# by --run-backstop (a captured `claude -p` dispatch → the internal
# _persist_backstop_verdict writer; no public writer subcommand — this removes the
# honest-path retype forge, #350, though a Bash-holding dispatcher can still forge:
# accepted ADR 0006 residual); the Codex-lead verdict is written ONLY inline on an
# actual Codex PASS (no subcommand — see write_codex_lead_verdict);
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
# #438: pin the diff to a deterministic form so an operator's git config cannot
# make the writer's bytes diverge from the gate's (irreproducible false block).
#   -c color.ui=never       — no ANSI color codes in the diff body
#   -c core.quotePath=false — stable non-ASCII path rendering
#   --no-ext-diff           — ignore a diff.external driver. NOT `-c diff.external=`:
#     an empty external command makes git try to exec "" and `external diff died`
#     → EMPTY diff → wrong hash. --no-ext-diff is the flag that disables it.
#   --no-textconv           — ignore a .gitattributes `diff.<driver>.textconv`
#     filter, which --no-ext-diff does NOT cover and which can otherwise rewrite
#     or fail the hashed bytes.
# Must stay byte-identical to pre-pr-gate.sh's CURRENT_HASH computation (same formula).
compute_pr_diff_hash() {
  # $2 (optional) pins the branch tip: #576 — resolving HEAD afresh here while the
  # caller reviewed a specific commit lets the marker describe a different snapshot.
  local base="$1" tip="${2:-HEAD}" mb diff
  [[ -z "$base" ]] && return 1
  mb=$(git merge-base "$base" "$tip" 2>/dev/null) || return 1
  [[ -z "$mb" ]] && return 1
  # --full-index: a binary change is distinguished ONLY by its `index` line, which is a
  # 7-char abbreviation by default — two distinct blobs sharing a chosen prefix would
  # reuse the same reviewed-diff binding. MUST stay byte-identical to the pre-PR gate's
  # own hash (hooks/gate-scripts/pre-pr-gate.sh), which is the PR-mode analogue of the
  # commit-mode four-site coupling: change one without the other and every PR marker
  # stops matching.
  diff=$(git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --full-index "${mb}...${tip}" 2>/dev/null) || return 1
  [[ -z "$diff" ]] && return 1
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
    echo "   Run the captured read-only backstop and persist its verdict via" >&2
    echo "   run-review-loop.sh --run-backstop before writing the marker." >&2
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

# _persist_backstop_verdict: strict, fail-closed writer for the read-only
# security/bugs backstop verdict artifact (pr-backstop-verdict.local.json).
#
# INTERNAL — there is deliberately NO `--write-backstop-verdict` subcommand. It is
# invoked ONLY from --run-backstop, which pipes it a CAPTURED `claude -p` stdout
# verdict. Removing the public subcommand deletes the EASIEST forge (a documented
# command that took hand-typed PASS JSON) and removes the honest-path retype the
# permission classifier refused. It is NOT a hard boundary: an orchestrator with
# Bash can still `source` this file and call the function directly (accepted ADR 0006
# trusted-dispatcher residual — see the --run-backstop header). Best-effort, not proof.
#
# Reads the verdict JSON on stdin:
#   {"status","model","reviewed_diff_hash",
#    "issues":[{file,line,severity,confidence,category,description[,suggestion]}]}
#
# This is the SOLE producer of the artifact. It:
#   • re-derives the CURRENT diff_hash + ts itself (caller never supplies them);
#   • fails closed (nonzero, no write) on a stale review (reviewed_diff_hash !=
#     current → a commit landed mid-review), malformed JSON, unknown/missing
#     fields, missing/out-of-range confidence, or bad/empty severity|category;
#   • recomputes status from issues — any `high` ⇒ FAIL; an explicit caller FAIL
#     is NEVER overridden to PASS;
#   • writes atomically (mktemp + mv) so the gate never sees a partial artifact.
_persist_backstop_verdict() {
  # Read the agent verdict JSON from stdin up-front (git work below does not touch
  # stdin) so the strict validator can take its PROGRAM on argv and the PAYLOAD on
  # stdin without the two colliding.
  PAYLOAD=$(cat)
  CURRENT_HASH=$(compute_pr_diff_hash "$(resolve_pr_base_branch)") || {
    echo "❌ Cannot compute PR diff hash (missing base / empty diff) — refusing backstop verdict" >&2
    return 1
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
    return 1
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
      return 1
    fi
  fi
  SCHEMA_FILE="$SCRIPT_DIR/../schemas/pr-backstop-verdict.schema.json"
  TMP_VERDICT=$(mktemp "${PR_STATE_DIR}/.pr-backstop-verdict.XXXXXX") || {
    echo "❌ Cannot create temp file for backstop verdict" >&2
    return 1
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
    return 1
  fi
  chmod 600 "$TMP_VERDICT" 2>/dev/null || true
  mv -f "$TMP_VERDICT" "$PR_BACKSTOP_VERDICT_FILE"
  FINAL_STATUS=$(_read_artifact_field "$PR_BACKSTOP_VERDICT_FILE" ".status" || echo "?")
  echo "✅ Backstop verdict written: status=$FINAL_STATUS (hash: ${CURRENT_HASH:0:12}...)"
  return 0
}

# --run-backstop: dispatch the read-only security/bugs backstop as a CAPTURED
# subprocess and persist its verdict WITHOUT the orchestrating model retyping it.
#
# What this fixes (the real #350 pain): on the HONEST path, the backstop verdict
# used to be produced by the model retyping the agent's final message into a public
# --write-backstop-verdict writer — a step the permission classifier correctly
# refused as "the model marking its own required check", which FORCED bypasses. The
# Codex lead never had this problem because this script captures its stdout directly.
# --run-backstop makes the backstop symmetric: it runs `claude -p` and pipes the
# captured stdout to the writer, so a faithful run needs no retype and no bypass.
#
# What this does NOT do (accepted residual — ADR 0006, "Claude is the trusted
# dispatcher"): it does not make forgery impossible. The orchestrator has Bash and
# controls the environment, so it can always fabricate a verdict — source this file
# and call _persist_backstop_verdict directly, stub `claude`/`codex` on PATH, or
# inject via a project CLAUDE.md. This is inherent to "Claude is the trusted
# dispatcher" and applies EQUALLY to the Codex lead. Removing the public writer
# subcommand, pinning the agent path, and confining the subprocess RAISE THE BAR for
# casual forgery and remove the honest-path bypass pressure; they are not a security
# boundary against a hostile dispatcher, which is out of scope for this solo repo.
#
# Read-only confinement (defense-in-depth, best-effort): --tools "Read,Grep,Glob"
# limits the tools that EXIST in the session so Bash/Write/Edit are unavailable
# (--allowedTools only auto-APPROVES); --permission-mode dontAsk denies anything else;
# --setting-sources user + --strict-mcp-config drop the reviewed branch's settings/MCP
# (project CLAUDE.md discovery remains — see the injection note at the dispatch).
# --model opus preserves the cross-model property (Anthropic backstop vs OpenAI lead).
# Fail-closed on any dispatch/parse failure: no artifact ⇒ gate stays blocked.
# No env override for the binary (no CLAUDE_BIN) — no substitution surface beyond
# the lead's own PATH lookup.
if [[ "${1:-}" == "--run-backstop" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "❌ backstop: 'claude' not found on PATH — cannot run the independent backstop (fail-closed)" >&2
    exit 1
  fi
  # Confinement capability guard (fail-CLOSED). Two flags are load-bearing:
  #   --tools           restricts the AVAILABLE toolset (mutation tools cannot exist)
  #   --setting-sources isolates settings so the REVIEWED branch's own .claude/
  #                     settings.json + hooks are NOT loaded into the backstop
  #                     session (a hostile PR could otherwise register a hook that
  #                     runs commands during the read-only review).
  # Refuse to dispatch on a claude too old for either flag rather than run unconfined.
  _claude_help=$(claude --help 2>&1 || true)
  if ! grep -q -- '--tools' <<<"$_claude_help" || ! grep -q -- '--setting-sources' <<<"$_claude_help"; then
    echo "❌ backstop: this claude lacks --tools/--setting-sources — cannot confine the read-only backstop (fail-closed)" >&2
    exit 1
  fi
  # Resolve the agent definition from THIS script's own location (BASH_SOURCE-derived
  # SCRIPT_DIR), NEVER a caller-controlled env var. CLAUDE_PLUGIN_ROOT is set by the
  # orchestrator and could point at a forged pr-security-backstop.md whose appended
  # system prompt instructs the genuine subprocess to return PASS — an injected-prompt
  # forge. This script lives at <plugin>/skills/litmus/scripts/; the agent at
  # <plugin>/agents/. Trusting SCRIPT_DIR is consistent with trusting this script at all.
  AGENT_FILE="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)/agents/pr-security-backstop.md"
  if [[ ! -f "$AGENT_FILE" ]]; then
    echo "❌ backstop: agent definition not found: $AGENT_FILE (fail-closed)" >&2
    exit 1
  fi
  PR_BASE=$(resolve_pr_base_branch)
  REVIEWED_DIFF_HASH=$(compute_pr_diff_hash "$PR_BASE") || {
    echo "❌ backstop: cannot compute PR diff hash (missing base / empty diff) — fail-closed" >&2
    exit 1
  }
  # Skip the expensive dispatch if the writer's precondition (a fresh Codex-lead
  # PASS for THIS exact diff) cannot be met — the writer would reject anyway.
  if ! verify_pr_artifact "$PR_CODEX_LEAD_FILE" "$REVIEWED_DIFF_HASH"; then
    echo "❌ backstop: no fresh Codex-lead PASS for the current diff — run Step 1 first (fail-closed)" >&2
    exit 1
  fi
  MERGE_BASE=$(git merge-base "$PR_BASE" HEAD 2>/dev/null) || {
    echo "❌ backstop: cannot resolve merge-base against $PR_BASE — fail-closed" >&2
    exit 1
  }
  # Capture the review material (this script, not the agent, runs git). The agent
  # has no Bash and reviews only what we inject.
  # #438 follow-up: pin the same deterministic flags used for the gate-binding
  # hash (compute_pr_diff_hash / pre-pr-gate.sh) so a hostile diff.external or
  # textconv driver can't corrupt the material actually reviewed — without
  # --no-ext-diff --no-textconv here, the backstop could still exit on a
  # garbled/empty diff even after the hash-divergence bug is fixed.
  DIFF=$(git -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv "${MERGE_BASE}...HEAD" 2>/dev/null)
  NAMES=$(git diff "${MERGE_BASE}...HEAD" --name-only 2>/dev/null)
  # `|| true`: under `set -o pipefail`, head closing the pipe early can leave
  # git log killed by SIGPIPE (nonzero) and abort the script — the substitution
  # has already captured head's 200 lines, so swallow the pipeline's exit code.
  HISTORY=$(git log --oneline --stat "${MERGE_BASE}..HEAD" 2>/dev/null | head -n 200) || true
  # Oversize diff → fail closed BEFORE dispatch (mirrors --write-backstop-verdict,
  # same env var + semantics): never hand the CLI a diff so large it would silently
  # truncate the review into a PASS. 0 (default) = no cap.
  MAX_DIFF="${LITMUS_PR_BACKSTOP_MAX_DIFF:-0}"
  case "$MAX_DIFF" in ''|*[!0-9]*) MAX_DIFF=0 ;; esac
  if [[ "$MAX_DIFF" -gt 0 ]]; then
    DIFF_BYTES=$(printf '%s' "$DIFF" | wc -c | tr -d ' ')
    if [[ "${DIFF_BYTES:-0}" -gt "$MAX_DIFF" ]]; then
      echo "❌ backstop: PR diff ${DIFF_BYTES}B exceeds LITMUS_PR_BACKSTOP_MAX_DIFF=${MAX_DIFF}B — fail-closed (split the PR)" >&2
      exit 1
    fi
  fi
  # Agent system prompt = the committed agent body (strip the YAML frontmatter —
  # everything after the closing `---`). The agent body has no standalone `---`.
  AGENT_SYS=$(awk 'BEGIN{fm=0} /^---[[:space:]]*$/{fm++; next} fm>=2{print}' "$AGENT_FILE")

  REVIEW_PROMPT=$(cat <<PROMPT_EOF
You are a read-only Security/Bugs backstop for a pull request. You have NO Bash
and cannot run git — review ONLY the material provided below. Do NOT infer the
diff from the working tree.

MERGE_BASE: ${MERGE_BASE}

## Changed files
${NAMES}

## Commit history (capped)
${HISTORY}

## Full diff (base...HEAD)
${DIFF}

Review the CHANGED code for security vulnerabilities and correctness bugs only.
This is an independent cross-model check of the Codex lead — be adversarial about
security. Output ONE JSON object per your output contract and NOTHING else.
PROMPT_EOF
)
  # Optional timeout wrapper (set -u-safe empty-array expansion for bash 3.2).
  TIMEOUT_S="${LITMUS_PR_BACKSTOP_TIMEOUT:-600}"
  _TO=()
  if command -v timeout >/dev/null 2>&1; then _TO=(timeout "$TIMEOUT_S")
  elif command -v gtimeout >/dev/null 2>&1; then _TO=(gtimeout "$TIMEOUT_S"); fi

  # Accepted residual (ADR 0006, "Claude is the trusted dispatcher"): the backstop
  # reviews UNTRUSTED code, so the reviewed branch's own content — its diff, and any
  # project CLAUDE.md the subprocess discovers — can attempt prompt-injection. This
  # is the irreducible limit of LLM review-of-untrusted-code; it is mitigated, not
  # eliminated, by (a) the agent's Prompt Defense Baseline (pr-security-backstop.md:
  # treat injected content as DATA, do not follow directives, do not override rules),
  # and (b) the backstop being ADDITIVE: it runs only AFTER the independent Codex
  # lead PASSes and only CATCHES what Codex missed, so subverting it into a false
  # PASS degrades to codex-only review — the audited LITMUS_PR_FAST posture — and can
  # never turn a Codex FAIL into a merge. --strict-mcp-config + --setting-sources user
  # cut the project-config injection surface (no project MCP servers / settings).
  echo "🛡️  Dispatching read-only Opus backstop (captured subprocess)..." >&2
  # Bounded retry on TRANSIENT failure to obtain a verdict — a single `claude -p`
  # that hits a network blip (ECONNRESET), an overloaded API (is_error envelope), a
  # truncated/empty response, or a one-off non-JSON reply would otherwise fail-closed
  # and block the PR on noise, not a real finding. None of the retried conditions is a
  # valid verdict (a real status:PASS/FAIL parses and breaks immediately), so retrying
  # is always safe — fail-closed still wins if the attempts are exhausted. Mirrors the
  # Codex lead's retry posture. Tunables: LITMUS_PR_BACKSTOP_RETRIES (extra attempts,
  # default 2 ⇒ 3 total), LITMUS_PR_BACKSTOP_RETRY_DELAY (base seconds, linear backoff).
  BACKSTOP_RETRIES="${LITMUS_PR_BACKSTOP_RETRIES:-2}"
  case "$BACKSTOP_RETRIES" in ''|*[!0-9]*) BACKSTOP_RETRIES=2 ;; esac
  BACKSTOP_RETRY_DELAY="${LITMUS_PR_BACKSTOP_RETRY_DELAY:-15}"
  case "$BACKSTOP_RETRY_DELAY" in ''|*[!0-9]*) BACKSTOP_RETRY_DELAY=15 ;; esac
  # Cap the string LENGTH before any arithmetic: a huge digit string (e.g. 2^63+)
  # would wrap NEGATIVE in the base-10 conversion and slip past the -gt ceilings,
  # and a negative delay later trips `sleep` under set -e. ≤9 digits is far below
  # any real need and cannot overflow; a longer value snaps straight to its ceiling.
  # (`if`, not `&&`: a false `[[ ]]` returns 1 and would trip set -e.)
  if [[ "${#BACKSTOP_RETRIES}" -gt 9 ]]; then BACKSTOP_RETRIES=5; fi
  if [[ "${#BACKSTOP_RETRY_DELAY}" -gt 9 ]]; then BACKSTOP_RETRY_DELAY=120; fi
  # Force base-10: a digits-only value like `08` is octal-invalid to $((...)) and
  # would abort under set -e (delay) or skip retries (count). 10# normalizes it.
  BACKSTOP_RETRIES=$((10#$BACKSTOP_RETRIES))
  BACKSTOP_RETRY_DELAY=$((10#$BACKSTOP_RETRY_DELAY))
  # Clamp to sane ceilings: each retry is a PAID Opus dispatch, so an oversized
  # value (mistaken or injected) must not fan out into unbounded spend, and the
  # bounded product keeps the linear-backoff arithmetic well clear of overflow.
  if [[ "$BACKSTOP_RETRIES" -gt 5 ]]; then BACKSTOP_RETRIES=5; fi
  if [[ "$BACKSTOP_RETRY_DELAY" -gt 120 ]]; then BACKSTOP_RETRY_DELAY=120; fi

  PAYLOAD=""
  _bs_attempt=0
  while : ; do
    set +e
    ENVELOPE=$(printf '%s' "$REVIEW_PROMPT" | "${_TO[@]+"${_TO[@]}"}" claude -p \
      --model opus \
      --tools "Read,Grep,Glob" \
      --allowedTools "Read,Grep,Glob" \
      --permission-mode dontAsk \
      --setting-sources user \
      --strict-mcp-config \
      --append-system-prompt "$AGENT_SYS" \
      --output-format json 2>/dev/null)
    RC=$?
    set -e

    # Extract the agent's verdict text from the --output-format json envelope, then
    # reshape to EXACTLY {status, issues, model, reviewed_diff_hash} for the strict
    # writer (which rejects unknown top-level fields). model = the model we
    # dispatched (opus). Distinct exit codes drive per-mode diagnostics + retry.
    _PARSE_RC=0
    if [[ "$RC" -eq 0 && -n "$ENVELOPE" ]]; then
      set +e
      # shellcheck disable=SC2016  # python template is a literal; values via argv
      PAYLOAD=$(printf '%s' "$ENVELOPE" | python3 -c '
import json, sys, re
try:
    # strict=False so a control character INSIDE a JSON string value (e.g. the CLI
    # embedding a raw newline/tab in the result text) does not fail the whole parse;
    # structural validation is unaffected, and the strict writer still gates status.
    env = json.loads(sys.stdin.read(), strict=False)
except Exception:
    sys.exit(2)
if isinstance(env, dict) and env.get("is_error"):
    sys.exit(3)
text = env.get("result") if isinstance(env, dict) else None
if not isinstance(text, str) or not text.strip():
    sys.exit(4)
text = text.strip()
# Strip a ```json ... ``` fence if the model wrapped the object.
if text.startswith("```"):
    text = re.sub(r"^```[A-Za-z0-9]*\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
try:
    v = json.loads(text, strict=False)
except Exception:
    sys.exit(5)
if not isinstance(v, dict):
    sys.exit(6)
# Faithful passthrough — do NOT launder. We must not default a missing `issues`
# to [] or drop unknown fields here, or an incomplete/tampered verdict would be
# reshaped into a clean one before the strict writer validates it. Pass the
# agent object through verbatim (only stamping the authoritative model +
# reviewed_diff_hash) so the writer sees — and fail-closed rejects — a missing
# issues array or any unexpected top-level field.
out = dict(v)
out["model"] = sys.argv[1]
out["reviewed_diff_hash"] = sys.argv[2]
print(json.dumps(out))
' "opus" "$REVIEWED_DIFF_HASH")
      _PARSE_RC=$?
      set -e
    else
      _PARSE_RC=90  # dispatch failure (rc!=0 or empty output) — never reached parser
    fi

    # A syntactically valid verdict object was captured → stop retrying. The writer
    # below is TERMINAL: only TRANSIENT dispatch/parse failures are retried here.
    [[ "$_PARSE_RC" -eq 0 && -n "$PAYLOAD" ]] && break

    case "$_PARSE_RC" in
      90) _bs_reason="dispatch failed (rc=$RC) or empty output" ;;
      2)  _bs_reason="the CLI envelope was not valid JSON" ;;
      3)  _bs_reason="the CLI returned an API/runtime error (is_error, e.g. ECONNRESET/overloaded)" ;;
      4)  _bs_reason="the agent returned no result text" ;;
      5)  _bs_reason="the agent verdict was not valid JSON" ;;
      6)  _bs_reason="the agent verdict was not a JSON object" ;;
      *)  _bs_reason="unexpected parser failure (rc=$_PARSE_RC)" ;;
    esac

    if [[ "$_bs_attempt" -lt "$BACKSTOP_RETRIES" ]]; then
      _bs_attempt=$((_bs_attempt + 1))
      _bs_delay=$((BACKSTOP_RETRY_DELAY * _bs_attempt))
      echo "⚠️  backstop: ${_bs_reason} — retry ${_bs_attempt}/${BACKSTOP_RETRIES} in ${_bs_delay}s (fail-closed if exhausted)" >&2
      sleep "$_bs_delay"
      continue
    fi
    echo "❌ backstop: ${_bs_reason} — no verdict written after $((BACKSTOP_RETRIES + 1)) attempt(s) (fail-closed)" >&2
    exit 1
  done
  # Hand the CAPTURED verdict to the internal trusted writer — same strict
  # validation, TOCTOU bind, and atomic write, but the model never retyped it. The
  # writer re-derives diff_hash/ts and recomputes status (any high ⇒ FAIL), so a
  # malformed payload cannot smuggle a PASS. This is TERMINAL, deliberately NOT
  # retried: the writer returns nonzero for schema rejection AND for causes a
  # re-dispatch cannot fix — stale diff_hash (TOCTOU), a missing Codex-lead, an
  # oversize diff, or an atomic-write error — so looping would only burn paid Opus
  # calls. The retry loop above already handles the transient DISPATCH failures.
  # (#350: the public writer subcommand that let a Bash-holding dispatcher forge a
  # PASS stays removed; the trusted-dispatcher fabrication is the accepted ADR 0006
  # residual.)
  printf '%s' "$PAYLOAD" | _persist_backstop_verdict
  exit $?
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

# Drop any terminal_status the PREVIOUS iteration left behind, BEFORE the setup steps
# below (CLI resolution, git and diff checks, state validation). Those are quick but not
# instant, and until the field is gone a resumed live review still advertises the last
# run's outcome — so a concurrent reader treating terminal_status as proof of a finished
# run would classify THIS run as stale and force-reset it. Clearing here makes the field
# mean "this run ended" for the whole lifetime of the run. No-op unless the loop is
# active; see clear_terminal_status.
#
# Every exit path below either records a fresh terminal_status or deletes the state file
# outright, so an active file with NO terminal_status now says exactly one thing: a
# review is in flight, or was killed before it could record its outcome.
clear_terminal_status


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

  # Same reasoning for the reasoning tier: the PR lead is the gate of record, so
  # it declares its own tier instead of inheriting whatever `~/.codex/config.toml`
  # happens to say this week (it said `high` on 2026-07-27, while this gate's
  # message claimed xhigh — the drift that motivated this pin). Explicit here and
  # nowhere else: the pre-commit path still rides the CLI default.
  #
  # FORCED, NOT `:-xhigh`. An ambient value is repo-injectable — a committed
  # `.claude/settings.json` `env` block sets session env (#325 / ADR 0016), so a
  # reviewed fork could export LITMUS_CODEX_EFFORT=minimal and weaken the very
  # reviewer that gates it. The artifact under review must never get to choose how
  # hard its reviewer thinks. Operators change the tier by editing this line.
  export LITMUS_CODEX_EFFORT=xhigh

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

# #576: the pinned comparison base for commit mode (set in the capture block below).
# Declared here so PR mode and every downstream `--cached` read can name it safely;
# empty means "unpinned", which is correct for PR mode (it diffs base...HEAD).
# #576: resolve the comparison base ONCE, here, BEFORE anything reads it.
#
# Order is load-bearing. The exclusion policy and logic are materialised from a commit,
# and the marker hash is taken against a commit; if those are resolved independently,
# HEAD moving in between lets exclusions from commit A filter a review whose marker
# binds commit B — a broad policy from A hides staged paths from the review, and the
# marker is still accepted against B. One resolution, passed to every consumer.
#
# Unborn HEAD (no commits yet) has no base to pin: the array stays empty, which is also
# the correct state for PR mode, where the diff is base...HEAD rather than --cached.
_HEAD_BASE=()
_HEAD_SHA=""
# PR-mode endpoints. Declared (and BLANKED) here for two reasons: these are plain shell
# variables, so an exported value would otherwise be inherited and could choose the
# review base before this script computes it; and the pin has to be READ after it is
# WRITTEN — an earlier revision froze _PR_BASE_REF near the mode guard, hundreds of
# lines before _PR_BASE_SHA was resolved, so it silently kept the mutable branch name
# and the pin never took effect.
_PR_BASE_SHA=""
_PR_BASE_REF=""
_PR_TIP=""
if _HEAD_SHA=$(git rev-parse --verify HEAD 2>/dev/null); then
  _HEAD_BASE=("$_HEAD_SHA")
else
  _HEAD_SHA=""
fi

# Source auto-generated file exclusion (hardcoded defaults + .claude/review-exclude)
#
# #576 item 3: VERIFY BEFORE USE. exclude-generated.sh decides what the reviewer is
# never shown, so it is an integrity input, not a utility — and the check has to
# happen HERE, before the source, not later at the excluded-only marker write. Checking
# afterwards is checking the wrong instant: tampered logic would already have shaped
# REVIEW_EXCLUDE_ARGS and hidden content from the reviewer, and restoring the file
# before the later check would let it pass. Same check-vs-use ordering
# dispatcher-commit-block.sh uses, from the shared guard so there is one copy.
#
# On failure we do NOT refuse the review — we review with NO exclusions. That is the
# safer failure and the one without a lockout: refusing would make any busdriver
# self-review that touches exclude-generated.sh unreviewable (the file is in-worktree
# only during self-review; everywhere else it is trusted plugin code and the guard
# returns immediately). "Cannot trust the exclusion list" ⇒ "exclude nothing" hides
# no content by construction, and it also makes the excluded-only auto-pass branch
# below unreachable, since STAGED_DIFF can no longer be emptied by exclusions.
# shellcheck source=../../../scripts/lib/exclusion-integrity.sh
if ! source "$SCRIPT_DIR/../../../scripts/lib/exclusion-integrity.sh" 2>/dev/null; then
  echo "⚠️  Could not load the exclusion-integrity guard — reviewing with NO exclusions" >&2
  REVIEW_EXCLUDE_ARGS=()
else
  _excl_worktree=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  # WHICH commit the exclusion inputs must match is mode-dependent, and getting it
  # wrong is a self-review bypass.
  #
  # Commit mode: the pinned HEAD. The patterns are already-committed history, and the
  # staged diff is what is under review.
  #
  # PR mode: the MERGE BASE, never the branch's own HEAD. The branch is the artifact
  # under review, so validating its policy against its own tip only proves the PR is
  # self-consistent — a PR that commits `*` into .claude/review-exclude would be
  # "clean" and would then hide the rest of its own diff from the reviewer. The
  # question is whether these patterns were reviewed BEFORE this branch, which is the
  # merge base. An unresolvable base is not a licence to trust the branch's copy:
  # leave it empty and let the guard refuse, which degrades to reviewing everything.
  if [ "$REVIEW_MODE" = "pr" ]; then
    # Against the PINNED commit, not the mutable HEAD ref: resolving the base from HEAD
    # while the reviewed artifact is _HEAD_SHA lets a concurrent HEAD move source the
    # exclusion inputs from a different history than the one under review — the same
    # check-versus-use split this block exists to close.
    # Pin the BASE ref too. Pinning only the tip leaves PR_BASE_BRANCH a mutable ref that
    # the exclusion anchor, the reviewer diff and the marker hash each resolve
    # independently: an A->B->A base transition lets the reviewer inspect B's diff while
    # the marker hashes A, and the gate at A then accepts that mismatched review.
    _PR_BASE_SHA=$(git rev-parse --verify "$(resolve_pr_base_branch)" 2>/dev/null || echo "")
    if [ -n "$_PR_BASE_SHA" ]; then
      _excl_base=$(git merge-base "$_PR_BASE_SHA" "${_HEAD_SHA:-HEAD}" 2>/dev/null || echo "")
    else
      _excl_base=""
    fi
  else
    _excl_base="${_HEAD_SHA:-HEAD}"
  fi
  # BOTH inputs, both before use. The policy (which patterns) and the logic (which
  # parses them) each decide what the reviewer never sees, so verifying only one leaves
  # the other as an unguarded lever.
  if [ -z "$_excl_base" ]; then
    echo "⚠️  Could not resolve a reviewed base for the exclusion inputs — reviewing with NO exclusions" >&2
    REVIEW_EXCLUDE_ARGS=()
  elif ! verify_exclusion_policy "$_excl_worktree" "$STATE_DIR" "$_excl_base"; then
    echo "⚠️  Exclusion policy failed its integrity check — reviewing with NO exclusions" >&2
    echo "    $EXCL_LOGIC_ERROR" >&2
    REVIEW_EXCLUDE_ARGS=()
  elif ! verify_exclusion_logic "$_excl_worktree" "$SCRIPT_DIR" "$_excl_base"; then
    echo "⚠️  Exclusion logic failed its integrity check — reviewing with NO exclusions" >&2
    echo "    $EXCL_LOGIC_ERROR" >&2
    REVIEW_EXCLUDE_ARGS=()
  else
    # Source the path the guard VALIDATED, never the un-collapsed original (PR #280).
    # For an in-worktree logic file that path is a temp file holding HEAD's committed
    # bytes, so nothing can swap it between verification and use.
    # Point the parser at the COMMITTED policy bytes the guard just materialised, so
    # the patterns actually applied are the ones that were verified. Assigned here (not
    # exported) immediately before the source, so any ambient value is overwritten.
    _BUSDRIVER_PINNED_REVIEW_EXCLUDE="${EXCL_POLICY_SOURCE:-}"
    # PROVE the parser honoured the pin; do not assume it. The logic is materialised
    # from the anchor commit, and in PR mode that is the MERGE BASE — a version that
    # predates this override and therefore reads the branch's LIVE policy instead. A PR
    # could then commit a wildcard exclusion, hide its own diff, and reach the
    # excluded-only auto-pass even though the safe base policy was pinned correctly.
    #
    # Append a sentinel pattern to the pinned copy and look for it in the built args: it
    # can only appear if the parser actually read the pinned file. Absent ⇒ this logic
    # does not support pinning ⇒ its patterns came from an unverified source ⇒ use none.
    # The sentinel itself is inert (it excludes a path name nothing can have).
    # UNPREDICTABLE, not merely unique. This challenge is checked against output from a
    # parser that may be reading the attacker-controlled live policy, so a guessable
    # value is forgeable: $$ is observable and $RANDOM is 15 bits, so a PR could list
    # candidate probe patterns alongside a wildcard exclusion and have one of them
    # match, "proving" a pin that never happened and keeping its malicious exclusions.
    # 128 bits from /dev/urandom makes that infeasible; no randomness means no proof,
    # which is a refusal.
    _excl_probe_rand=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo "")
    _excl_probe="__busdriver_pin_probe_${_excl_probe_rand}"
    if [ ${#_excl_probe_rand} -lt 32 ]; then
      # DO NOT SOURCE. Clearing the pin and carrying on was a fail-open: logic predating
      # the override would reload the attacker-controlled LIVE policy, and the emptied
      # EXCL_POLICY_SOURCE simultaneously disabled the sentinel check that would have
      # caught it. Without a challenge there is no way to prove the pin held, so the
      # only safe move is to not run that parser at all.
      echo "⚠️  No usable randomness for the exclusion pin probe — reviewing with NO exclusions" >&2
      REVIEW_EXCLUDE_ARGS=()
      _BUSDRIVER_PINNED_REVIEW_EXCLUDE=""
    elif [ -n "${_BUSDRIVER_PINNED_REVIEW_EXCLUDE:-}" ]; then
      # LEADING newline: a policy whose last line has no trailing newline would
      # otherwise have the sentinel concatenated onto that final pattern, so neither
      # caller sees a standalone :(exclude)<probe> and both conclude the pin was
      # ignored — the producer would disable every exclusion and the dispatcher would
      # reject a perfectly valid PASS-EXCLUDED marker. The extra blank line is inert;
      # the parser skips empty lines.
      printf '\n%s\n' "$_excl_probe" >> "$_BUSDRIVER_PINNED_REVIEW_EXCLUDE"
    fi
    if [ ${#_excl_probe_rand} -ge 32 ]; then
      # shellcheck source=lib/exclude-generated.sh
      source "$EXCL_LOGIC_SOURCE"
    fi
    _BUSDRIVER_PINNED_REVIEW_EXCLUDE=""
    # EXACT match, and the same comparison the strip below uses. A substring test
    # accepted an element merely CONTAINING the probe — an older parser reading the live
    # policy could return a suffix-bearing argument that satisfied the check, survived a
    # strip that removes only exact matches, and left the attacker-controlled live
    # exclusions in force.
    _excl_probe_seen=no
    for _excl_arg in ${REVIEW_EXCLUDE_ARGS[@]+"${REVIEW_EXCLUDE_ARGS[@]}"}; do
      [ "$_excl_arg" = ":(exclude)$_excl_probe" ] && _excl_probe_seen=yes && break
    done
    if [ ${#_excl_probe_rand} -lt 32 ]; then
      : # already handled above: nothing was sourced, exclusions are empty
    elif [ -n "${EXCL_POLICY_SOURCE:-}" ] && [ "$_excl_probe_seen" != yes ]; then
      echo "⚠️  The exclusion parser at the review anchor does not support a pinned policy" >&2
      echo "    (it would read the live, unverified one) — reviewing with NO exclusions" >&2
      REVIEW_EXCLUDE_ARGS=()
    else
      # STRIP the sentinel. Leaving it in place turns it into a live
      # `:(exclude)__busdriver_pin_probe_<pid>_<random>` pathspec, and the name is
      # derivable — a file staged under it would be dropped from the reviewer's diff
      # while the full-snapshot marker still authorised it. It has done its job the
      # moment we observed it.
      _excl_kept=()
      for _excl_arg in ${REVIEW_EXCLUDE_ARGS[@]+"${REVIEW_EXCLUDE_ARGS[@]}"}; do
        [ "$_excl_arg" = ":(exclude)$_excl_probe" ] && continue
        _excl_kept+=("$_excl_arg")
      done
      REVIEW_EXCLUDE_ARGS=(${_excl_kept[@]+"${_excl_kept[@]}"})
    fi
  fi
  # Unconditional: verify_exclusion_policy can succeed (leaving a pinned temp) and
  # verify_exclusion_logic then fail, and the source itself can fail — both paths
  # previously leaked the policy snapshot. Cleaning here covers every branch above.
  [ -n "${EXCL_LOGIC_PINNED_TMP:-}" ] && rm -f "$EXCL_LOGIC_PINNED_TMP"
  [ -n "${EXCL_POLICY_PINNED_TMP:-}" ] && rm -f "$EXCL_POLICY_PINNED_TMP"
  EXCL_LOGIC_PINNED_TMP=""
  EXCL_POLICY_PINNED_TMP=""
fi

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
  # #576: the PINNED tip, not the mutable HEAD ref — otherwise exclusions anchored on
  # the merge base can mix with material from a different commit, and an A->B->A
  # transition lets a review of one snapshot authorise another.
  _PR_TIP="${_HEAD_SHA:-HEAD}"
  # Now that the exclusion block has resolved _PR_BASE_SHA, freeze the base ref here —
  # at the point of first use, and after the origin/ normalisation.
  #
  # There is NO fallback to the branch name. Falling back to a mutable ref is the same
  # bug in a quieter costume: the file list, the reviewer diff and the marker hash each
  # resolve it separately, so a ref that appears or moves between those calls reopens
  # the review-to-marker gap on exactly the path where something already went wrong.
  # An unpinnable base is a refusal.
  if [ -z "$_PR_BASE_SHA" ]; then
    _PR_BASE_SHA=$(git rev-parse --verify "$PR_BASE_BRANCH" 2>/dev/null || echo "")
  fi
  if [ -z "$_PR_BASE_SHA" ]; then
    echo "❌ Could not resolve $PR_BASE_BRANCH to a commit — refusing to review against a moving base." >&2
    echo "   Fetch the base branch (git fetch origin) and re-run." >&2
    write_terminal_status setup_error
    exit 1
  fi
  _PR_BASE_REF="$_PR_BASE_SHA"
  ALL_STAGED_FILES=$(git diff --name-only "${_PR_BASE_REF}...${_PR_TIP}")
  # #438 follow-up: same deterministic pin as compute_pr_diff_hash — a hostile
  # diff.external/textconv config must not be able to corrupt the material the
  # reviewer actually reads.
  # --text for the same reason as commit mode: --no-textconv does NOT defeat a committed
  # `.gitattributes` `-diff` rule, so a PR adding `*.sh -diff` reduces its own changed
  # source to an opaque "Binary files differ" line while the marker stays valid.
  # Same two guards commit mode carries, for the same reasons --text creates: measure by
  # STREAMING first (a genuine binary rendered as text would otherwise be fully resident
  # in a shell variable before any size check), then verify the capture is faithful
  # (command substitution silently drops NUL bytes, so the reviewer could be shown
  # something other than what PR_REVIEWED_DIFF_HASH binds).
  if ! _staged_diff_bytes=$(git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --text "${_PR_BASE_REF}...${_PR_TIP}" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null | wc -c | tr -d ' '); then
    echo "❌ Could not measure the branch diff — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  fi
  _staged_diff_max="${LITMUS_MAX_DIFF_BYTES:-10485760}"
  case "$_staged_diff_max" in
    ''|*[!0-9]*) _staged_diff_max=10485760 ;;
    ??????????????????*) _staged_diff_max=10485760 ;;
  esac
  if [ "${_staged_diff_bytes:-0}" -gt "$_staged_diff_max" ]; then
    echo "❌ Branch diff is ${_staged_diff_bytes} bytes with binary content rendered as text (cap ${_staged_diff_max})." >&2
    echo "   Split the PR, or exclude the large binary via $STATE_DIR/review-exclude." >&2
    echo "   Override with LITMUS_MAX_DIFF_BYTES." >&2
    exit 2
  fi
  STAGED_DIFF=$(git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --text "${_PR_BASE_REF}...${_PR_TIP}" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
  _captured_bytes=$(printf '%s' "$STAGED_DIFF" | wc -c | tr -d ' ')
  if [ "$(( ${_staged_diff_bytes:-0} - ${_captured_bytes:-0} ))" -gt 1 ]; then
    echo "❌ The branch diff lost bytes on capture (${_staged_diff_bytes} rendered, ${_captured_bytes} captured)." >&2
    echo "   NUL bytes cannot be represented in the review prompt, so the reviewer would not" >&2
    echo "   see what the marker authorises. Exclude the binary, or split the PR." >&2
    write_terminal_status setup_error
    exit 1
  fi
  # Capture the gate-binding diff hash NOW, before the (minutes-long) Codex review,
  # so the Codex-lead artifact binds to the diff the lead actually reviews. Using a
  # hash re-derived after the review would drift if HEAD/base moved mid-review.
  # compute_pr_diff_hash (no exclusions) matches the gate's binding token exactly.
  PR_REVIEWED_DIFF_HASH=$(compute_pr_diff_hash "$_PR_BASE_REF" "$_PR_TIP" 2>/dev/null || true)
  FILTERED_FILES=$(git diff --name-only "${_PR_BASE_REF}...${_PR_TIP}" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}")
else
  echo "📋 Capturing staged changes..."
  # #576: take ONE atomic snapshot of the index and derive BOTH the reviewer's material
  # and the gate-binding hash from it.
  #
  # Why a snapshot and not two reads. The marker must name what the reviewer saw. Two
  # separate `git diff --cached` calls cannot guarantee that: an index that moves
  # between them hands the reviewer diff A while the marker records diff B, which is
  # the unreviewed-diff authorization this whole change exists to close. Bracketing the
  # capture with a before/after hash was the obvious patch and it is NOT sufficient
  # either — an A -> B -> A index change leaves both hashes equal to A while
  # STAGED_DIFF was taken from B, so a PASS for B mints a marker authorizing A.
  #
  # Copying the index file removes the race instead of narrowing it: git writes the
  # index atomically (write to index.lock, then rename), so `cp` observes exactly one
  # complete version, and every read below is pinned to it via GIT_INDEX_FILE. The
  # reviewer's filtered diff and the marker's full-diff hash are then two projections
  # of the SAME bytes, by construction rather than by timing.
  _INDEX_SNAPSHOT=$(mktemp -t busdriver-index-XXXXXX) || {
    echo "❌ Could not create an index snapshot — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  }
  # Pin the comparison BASE as well. `git diff --cached` is index-vs-HEAD, and each
  # invocation re-resolves HEAD, so a snapshot of only the index still lets an A->B->A
  # HEAD transition make the hash and the reviewed material describe different changes.
  # Naming the commit explicitly makes every read below compare the same two endpoints.
  # It stays byte-identical to the gate's implicit form while HEAD is unchanged — and if
  # HEAD did move before the commit, the gate's recomputation simply differs and blocks,
  # which is the correct fail-closed outcome. Unborn HEAD (no commits yet) has no base
  # to pin, so the operand is omitted there.
  if ! cp "$(git rev-parse --git-path index)" "$_INDEX_SNAPSHOT" 2>/dev/null; then
    rm -f "$_INDEX_SNAPSHOT"
    echo "❌ Could not snapshot the git index — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  fi

  # Pick the hash utility ONCE, by availability. `(sha256sum || shasum)` in a single
  # pipe is a fail-OPEN: if sha256sum consumes part of stdin and then dies, shasum
  # hashes only the unread REMAINDER and the pipeline still reports success with a
  # valid-looking digest for a truncated stream. pre-commit-gate.sh selects by
  # availability for exactly this reason (CodeRabbit, PR #577); the minter must match.
  if command -v sha256sum >/dev/null 2>&1; then
    _REVIEW_HASH_CMD=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    _REVIEW_HASH_CMD=(shasum -a 256)
  else
    rm -f "$_INDEX_SNAPSHOT"
    echo "❌ No SHA-256 utility (sha256sum/shasum) — cannot bind a review marker" >&2
    write_terminal_status setup_error
    exit 1
  fi

  # THE CANONICAL MARKER-HASH FORM — byte-identical to pre-commit-gate.sh (which
  # documents why each flag is load-bearing) and to the three sites in
  # dispatcher-commit-block.sh. Asserted by tests/test-litmus-marker-binding.sh.
  if ! REVIEWED_DIFF_HASH=$(GIT_INDEX_FILE="$_INDEX_SNAPSHOT" git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} 2>/dev/null | "${_REVIEW_HASH_CMD[@]}" | cut -d' ' -f1); then
    rm -f "$_INDEX_SNAPSHOT"
    echo "❌ Could not hash the staged diff — refusing to mint a review marker" >&2
    write_terminal_status setup_error
    exit 1
  fi
  if ! ALL_STAGED_FILES=$(GIT_INDEX_FILE="$_INDEX_SNAPSHOT" git diff --cached --name-only ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"}); then
    echo "❌ Could not list staged files from the index snapshot — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  fi
  # Pinned exactly like the marker hash. Pinning only the marker would be worse than
  # useless: a diff.external/textconv driver emitting empty or constant output would
  # hide staged content from the REVIEWER while the marker still bound the real index,
  # so the gate would certify content nobody read.
  # `--text` is NOT cosmetic here. `--no-textconv` does not neutralize a `.gitattributes`
  # `-diff` (binary) rule, and a committed `*.sh -diff` renders every staged shell script
  # as "Binary files a/x and b/x differ" — the reviewer receives NO source at all, while
  # the marker (bound via --full-index blob SHAs) stays perfectly valid and the gate
  # accepts it. Same blinding class as the textconv collapse, different lever. `--text`
  # forces the textual rendering back. Measured: with `*.sh -diff` the diff shows only
  # the Binary line; with --text the full hunk returns.
  # --text makes a GENUINE binary render as a full textual patch, so the reviewer's
  # diff is no longer bounded by "Binary files differ". Measure it by STREAMING into
  # `wc -c` first — a shell variable would already hold the whole thing by the time the
  # existing size gate (which counts numstat lines, and scores binaries as zero) got a
  # look. Over the cap is TOO_LARGE (exit 2), the documented split path, not a silent
  # truncation: cutting the diff would hide content from the reviewer while the marker
  # still bound all of it, which is the blinding this change exists to stop.
  # Guard the measurement itself: under `set -euo pipefail` a bare assignment whose
  # pipeline fails would abort the script before write_terminal_status ever ran,
  # leaving the state file stuck at PENDING with no machine-readable terminal status
  # for automated callers to read.
  if ! _staged_diff_bytes=$(GIT_INDEX_FILE="$_INDEX_SNAPSHOT" git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --text --no-color ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null | wc -c | tr -d ' '); then
    echo "❌ Could not measure the staged diff — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  fi
  _staged_diff_max="${LITMUS_MAX_DIFF_BYTES:-10485760}"
  # Digit-only is not enough: a value beyond the shell's integer range makes the
  # `-gt` test an "integer expression expected" ERROR, and because that test is an `if`
  # condition the failure is swallowed and the cap is skipped entirely — the whole diff
  # then lands in STAGED_DIFF. Bound the length so the comparison can never overflow.
  case "$_staged_diff_max" in
    ''|*[!0-9]*) _staged_diff_max=10485760 ;;
    ??????????????????*) _staged_diff_max=10485760 ;;
  esac
  if [ "${_staged_diff_bytes:-0}" -gt "$_staged_diff_max" ]; then
    echo "❌ Staged diff is ${_staged_diff_bytes} bytes with binary content rendered as text (cap ${_staged_diff_max})." >&2
    echo "   Split the commit, or exclude the large binary via $STATE_DIR/review-exclude." >&2
    echo "   Override with LITMUS_MAX_DIFF_BYTES." >&2
    # Exit 2 deliberately writes NO terminal_status: per the skill's documented
    # contract, TOO_LARGE is the one failure exit that does not set it (the other
    # size ceilings below behave identically). Callers key off exit 2 here.
    exit 2
  fi
  if ! STAGED_DIFF=$(GIT_INDEX_FILE="$_INDEX_SNAPSHOT" git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --text --no-color ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} -- :/ "${REVIEW_EXCLUDE_ARGS[@]}"); then
    echo "❌ Could not capture the staged diff from the index snapshot — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  fi
  # Prove the capture is FAITHFUL. Bash command substitution silently drops NUL bytes,
  # and --text can put NULs in the stream, so the reviewer could receive a quietly
  # different rendering from the one the marker authorises — a diff that reads clean
  # while the committed blob is not. We already measured the true byte length by
  # streaming, so compare it against what actually landed in the variable and refuse on
  # any shortfall beyond the single trailing newline `$( )` always strips.
  _captured_bytes=$(printf '%s' "$STAGED_DIFF" | wc -c | tr -d ' ')
  if [ "$(( ${_staged_diff_bytes:-0} - ${_captured_bytes:-0} ))" -gt 1 ]; then
    echo "❌ The staged diff lost bytes on capture (${_staged_diff_bytes} rendered, ${_captured_bytes} captured)." >&2
    echo "   NUL bytes in binary content cannot be represented in the review prompt, so the" >&2
    echo "   reviewer would not see what the marker authorises. Exclude the binary via" >&2
    echo "   $STATE_DIR/review-exclude, or split the commit." >&2
    write_terminal_status setup_error
    exit 1
  fi
  if ! FILTERED_FILES=$(GIT_INDEX_FILE="$_INDEX_SNAPSHOT" git diff --cached --name-only ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} -- :/ "${REVIEW_EXCLUDE_ARGS[@]}"); then
    echo "❌ Could not list reviewable files from the index snapshot — refusing to review" >&2
    write_terminal_status setup_error
    exit 1
  fi
  # EXPORT it for the rest of the run rather than deleting it here. Everything
  # downstream — the size calculation, SAST/markdown file lists, DIFF_FOR_FILTER, and
  # above all the short-circuit path classification — also reads the index, and reading
  # those from the LIVE index reopens the same hole one level down: an A->B->A change
  # would let the short-circuit classify B as passive prose while the marker names A,
  # handing active code from A a no-review PASS. One exported snapshot pins every
  # `git diff --cached` in this process to the bytes that were actually reviewed.
  # (Worktree-reading scanners still see live files; an index snapshot cannot fix that,
  # and the marker binds the index, which is what the gate re-derives.) The EXIT trap
  # removes it on every path.
  export GIT_INDEX_FILE="$_INDEX_SNAPSHOT"
  if [ -z "$REVIEWED_DIFF_HASH" ]; then
    echo "❌ Empty staged-diff hash — refusing to mint a review marker" >&2
    write_terminal_status setup_error
    exit 1
  fi
fi

# #576: every commit-mode marker write goes through this. Fail CLOSED — a marker
# with no reviewed-diff binding is the bearer token #545 set out to abolish, so an
# uncaptured or malformed hash must refuse the marker, never fall back to a fresh
# `git diff --cached` (that fallback IS the bug).
require_reviewed_diff_hash() {
  if [[ ! "${REVIEWED_DIFF_HASH:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "❌ no reviewed staged-diff hash was captured — refusing to write a review marker" >&2
    write_terminal_status setup_error
    exit 1
  fi
}

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
      # same structural refusal). Resolve the policy file's canonical
      # repo-relative path via git itself rather than hand-normalizing
      # $STATE_DIR: git normalizes the `--` pathspec exactly the way it
      # normalizes `git diff --name-only` output, so the two are guaranteed
      # consistent for ANY sanitizer-permitted form ('.', 'foo/.', './/x',
      # trailing slash, './.claude'). $STATE_DIR (not a hardcoded .claude)
      # keeps the guard aligned with exclude-generated.sh's actual location
      # when BUSDRIVER_STATE_DIR is customized.
      _exclude_target=$(git -C "$PR_REPO_TOP" ls-files --full-name -- "$STATE_DIR/review-exclude" 2>/dev/null | head -n1)
      if [ -n "$_exclude_target" ] && echo "$ALL_STAGED_FILES" | grep -qxF "$_exclude_target"; then
        echo "❌ excluded-only PR modifies $_exclude_target — refusing auto-pass; review required" >&2
        write_terminal_status setup_error
        exit 1
      fi
      mkdir -p "$PR_STATE_DIR"
      printf 'PASS-EXCLUDED-%s-%s\n' "$PR_REVIEWED_DIFF_HASH" "$(date +%s)" > "$PR_REVIEW_MARKER_FILE"
      printf '{"ts":"%s","event":"pr-excluded-only-autopass","gate":"pre-pr","diff_hash":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR_REVIEWED_DIFF_HASH" >> "$PR_STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    else
      # Commit mode: emit the SAME diff-bound + age-bound shape PR mode uses
      # above — PASS-EXCLUDED-<diff_hash>-<epoch>.
      #
      # This used to be epoch-only, on the stated grounds that "pre-commit gate
      # accepts marker existence without hash verification due to TOCTOU
      # constraints". That rationale is gone: the pre-commit gate now binds
      # every marker to the staged diff (#545), and an epoch-only marker was
      # the one remaining bearer token — obtain it for an excluded-only diff A,
      # then commit unrelated diff B within the window. The hash closes that
      # without relying on any predicate the gated repo can influence.
      #
      # The hash covers the FULL staged diff (not the post-exclusion one), which
      # is what the gate recomputes; keep this expression identical to the two
      # marker writes below and to write-review-marker.sh.
      #
      # #252 parity, strengthened: a fail-closed gate must not let an UNREVIEWED
      # policy file certify that nothing needs review. Commit mode had no guard
      # at all, so a widened review-exclude could mint a marker asserting its own
      # diff was unreviewable.
      #
      # Checking only the STAGED set (or only `git ls-files`, which sees tracked
      # paths) is not enough, and hash-binding the marker does not save us: an
      # UNTRACKED review-exclude containing `*` empties STAGED_DIFF for arbitrary
      # staged source, and the marker minted here would then be correctly bound
      # to that very diff — a legitimate-looking marker for content no reviewer
      # ever saw. So require the policy to match HEAD exactly.
      # `git status --porcelain -uall --ignored` reports every divergence in one
      # shot — staged add/modify/delete (including `git rm --cached`, which
      # `git diff HEAD` misses because the worktree copy still matches HEAD),
      # unstaged edits, and untracked (`??`). Any output at all ⇒ the policy in
      # force is not the committed one ⇒ refuse. Same invariant
      # dispatcher-commit-block.sh STEP 1 enforces for the same marker.
      #
      # --ignored is required, not belt-and-braces: without it a review-exclude
      # hidden by a repo-committed .gitignore rule produces NO porcelain output,
      # while exclude-generated.sh reads the file regardless. That silent file
      # containing `*` suppresses arbitrary staged source, and the marker minted
      # below would be correctly hash-bound to code no reviewer saw.
      _policy_rel="$STATE_DIR/review-exclude"
      _policy_state=$(git status --porcelain --untracked-files=all --ignored -- "$_policy_rel" 2>/dev/null) || _policy_state="?"
      if [ -n "$_policy_state" ]; then
        echo "❌ excluded-only commit: $_policy_rel diverges from HEAD (staged, unstaged, or untracked) — refusing auto-pass; review required" >&2
        write_terminal_status setup_error
        exit 1
      fi
      # ...and the porcelain check alone is not sufficient, because it validates
      # the wrong bytes when a path COMPONENT is untrusted:
      #   symlink — git tracks a symlink's target STRING, not the target's
      #             content, so `.claude` → /elsewhere reports clean while
      #             exclude-generated.sh follows the link and reads whatever
      #             /elsewhere/review-exclude currently holds.
      #   gitlink — a committed submodule is a directory, not a symlink, so a
      #             `-L` test never fires, and `git status -- <path-inside>` does
      #             not descend into it. Divergent bytes read straight through.
      # Same reasoning and same rejection as dispatcher-commit-block.sh STEP 1
      # (PR #280 / #281); walk every prefix and refuse on the first untrusted one.
      _policy_untrusted=""
      _policy_prefix=""
      IFS=/ read -r -a _policy_segs <<< "$_policy_rel"
      for _policy_seg in "${_policy_segs[@]}"; do
        [ -z "$_policy_seg" ] || [ "$_policy_seg" = "." ] && continue
        _policy_prefix="${_policy_prefix:+$_policy_prefix/}$_policy_seg"
        if [ -L "$_policy_prefix" ]; then
          _policy_untrusted="$_policy_prefix (symlink)"; break
        fi
        # A gitlink is the sole index entry whose path EQUALS the prefix; for an
        # ordinary directory ls-files lists descendants instead, so match exactly.
        _policy_mode=$(git ls-files --stage -- "$_policy_prefix" 2>/dev/null \
          | awk -v p="$_policy_prefix" '{ split($0, a, "\t"); if (a[2] == p) m=$1 } END { print m }')
        if [ "$_policy_mode" = "160000" ]; then
          _policy_untrusted="$_policy_prefix (gitlink/submodule)"; break
        fi
      done
      if [ -n "$_policy_untrusted" ]; then
        echo "❌ excluded-only commit: path component $_policy_untrusted is not trustworthy — refusing auto-pass; review required" >&2
        write_terminal_status setup_error
        exit 1
      fi
      # The exclusion LOGIC was verified BEFORE it was sourced (see the guard above
      # the exclude-generated.sh source). Re-checking here would be checking the wrong
      # instant anyway: by now REVIEW_EXCLUDE_ARGS has already shaped STAGED_DIFF. If
      # that verification had failed there would be no exclusions at all, so this
      # excluded-only branch would be unreachable.
      mkdir -p "$STATE_DIR"
      _excluded_epoch=$(date +%s)
      # #576: the reviewed snapshot, not a fresh diff taken after the policy and
      # logic checks above ran.
      require_reviewed_diff_hash
      printf 'PASS-EXCLUDED-%s-%s\n' "$REVIEWED_DIFF_HASH" "$_excluded_epoch" > "$STATE_DIR/litmus-passed.local"
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
done < <(if [ "$REVIEW_MODE" = "pr" ]; then git diff --numstat "${_PR_BASE_REF}...${_PR_TIP}" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null; else git diff --cached --numstat ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null; fi)
WEIGHTED_LINES=$(( ADDITION_LINES + DELETION_LINES / 4 ))
echo "   Staged files: $STAGED_FILE_COUNT"
echo "   Diff lines: $STAGED_DIFF_LINES (added: $ADDITION_LINES, removed: $DELETION_LINES, weighted: $WEIGHTED_LINES)"

# Check if diff is too large for a single review (commit mode only)
# PR mode skips the size check — PR diffs are inherently larger (aggregate of
# all commits) and blocking review on the largest diffs defeats the purpose of
# the safety net. The REVIEW_TIMEOUT (default 540s — see LITMUS_TIMEOUT below)
# handles runaway reviews. It is now UNDER the harness Bash cap of 600s (#368),
# so a blocking caller normally outlives the review instead of being killed
# mid-run — but the reviewer timer starts only after setup, so expensive
# setup/cleanup can still eat the ~60s headroom and let the 600s harness cap
# fire first.
# Council decision 2026-03-21: per-commit and PR size checks serve different
# purposes — fix independently. PR size check was structurally broken.
#
# Per-commit thresholds:
#   Primary metric: weighted lines (additions + deletions/4)
#   Safety ceiling: total raw lines > 2000 regardless of weighting
#   Single-file diffs get a higher threshold since they can't be split further
#   Override: LITMUS_MAX_WEIGHTED_LINES / LITMUS_MAX_WEIGHTED_LINES_SINGLE_FILE /
#             LITMUS_MAX_TOTAL_LINES / LITMUS_MAX_STAGED_FILES env vars
#             (per-project tuning)
if [ "$REVIEW_MODE" = "pr" ]; then
  # PR mode: soft warning only — large PR diffs may be slow or hit context limits,
  # but blocking them defeats the safety net. The REVIEW_TIMEOUT (default 540s below)
  # handles truly runaway reviews. Warn so the user knows to expect a longer wait —
  # 540s is under the 600s harness Bash cap (#368), so a blocking caller normally
  # won't be killed mid-review — but the reviewer timer starts only after setup,
  # so expensive setup/cleanup can still eat the ~60s headroom on a very large diff.
  if [ "$WEIGHTED_LINES" -gt 2000 ]; then
    echo ""
    echo "⚠️  Large PR diff ($WEIGHTED_LINES weighted lines) — review may be slow or hit context limits"
    # Use the SAME default as the REVIEW_TIMEOUT assignment below. This warning runs
    # ~270 lines BEFORE that assignment, so REVIEW_TIMEOUT is still unset here — keep
    # this `:-540` fallback in lockstep with the REVIEW_TIMEOUT assignment below, or the
    # gate tells the operator the wrong number about its own timeout.
    echo "   Consider splitting into smaller PRs if review times out (${LITMUS_TIMEOUT:-540}s limit)"
  fi
else
  # Commit mode: hard size gate with env var override
  MAX_WEIGHTED_LINES="${LITMUS_MAX_WEIGHTED_LINES:-800}"
  # #523 review: the single-file ceiling used to be a bare literal with no
  # override at all, so raising LITMUS_MAX_WEIGHTED_LINES (which only affects
  # the multi-file default) could never clear a large single-file diff — the
  # doc claim that "each of the three [triggers] is an independent trigger
  # with its own override" was false for this case. Give it the same knob.
  MAX_WEIGHTED_LINES_SINGLE_FILE="${LITMUS_MAX_WEIGHTED_LINES_SINGLE_FILE:-2000}"
  # #514: a merge commit's diff-vs-HEAD is by definition everything the merge
  # brings in, so it cannot be subdivided — and neither sibling override reaches
  # this trigger. Without an override the only exit is skip-litmus.local, which
  # skips the whole commit including the conflict resolutions (the one genuinely
  # new part of a merge). Give the ceiling the same knob its siblings have.
  MAX_TOTAL_LINES_CEILING="${LITMUS_MAX_TOTAL_LINES:-2000}"
  MAX_STAGED_FILES="${LITMUS_MAX_STAGED_FILES:-8}"
  # Validate env vars are numeric — fall back to default if not. This is not
  # cosmetic: a non-numeric value makes the `[ -gt ]` comparisons below error
  # INSIDE their `if` condition, which evaluates false (and `set -e` does not
  # fire in a condition context), so the threshold silently fails OPEN.
  case "$MAX_WEIGHTED_LINES" in
    ''|*[!0-9]*) echo "⚠️  LITMUS_MAX_WEIGHTED_LINES='$MAX_WEIGHTED_LINES' is not numeric, using default 800"; MAX_WEIGHTED_LINES=800 ;;
  esac
  case "$MAX_WEIGHTED_LINES_SINGLE_FILE" in
    ''|*[!0-9]*) echo "⚠️  LITMUS_MAX_WEIGHTED_LINES_SINGLE_FILE='$MAX_WEIGHTED_LINES_SINGLE_FILE' is not numeric, using default 2000"; MAX_WEIGHTED_LINES_SINGLE_FILE=2000 ;;
  esac
  case "$MAX_TOTAL_LINES_CEILING" in
    ''|*[!0-9]*) echo "⚠️  LITMUS_MAX_TOTAL_LINES='$MAX_TOTAL_LINES_CEILING' is not numeric, using default 2000"; MAX_TOTAL_LINES_CEILING=2000 ;;
  esac
  case "$MAX_STAGED_FILES" in
    ''|*[!0-9]*) echo "⚠️  LITMUS_MAX_STAGED_FILES='$MAX_STAGED_FILES' is not numeric, using default 8"; MAX_STAGED_FILES=8 ;;
  esac
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
    done < <(git diff --cached --numstat ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null)
    if [ "$FILES_WITH_ADDITIONS" -gt "$MAX_STAGED_FILES" ]; then
      TOO_LARGE=true
      TOO_LARGE_REASON="files with additions ($FILES_WITH_ADDITIONS) > $MAX_STAGED_FILES (total: $STAGED_FILE_COUNT)"
    fi
  fi
  if [ "$TOO_LARGE" = true ]; then
    echo ""
    echo "⚠️  Diff too large for single review ($TOO_LARGE_REASON)"
    echo "   Thresholds: weighted >$EFFECTIVE_MAX OR total >$MAX_TOTAL_LINES_CEILING OR files >$MAX_STAGED_FILES"
    if [ "$STAGED_FILE_COUNT" -eq 1 ]; then
      echo "   Override to raise: LITMUS_MAX_WEIGHTED_LINES_SINGLE_FILE=$((WEIGHTED_LINES + 100))"
    else
      echo "   Override to raise: LITMUS_MAX_WEIGHTED_LINES=$((WEIGHTED_LINES + 100))"
    fi
    echo "                      LITMUS_MAX_TOTAL_LINES=$((ADDITION_LINES + DELETION_LINES + 100))"
    echo "                      LITMUS_MAX_STAGED_FILES=$((STAGED_FILE_COUNT + 2))"
    echo ""
    # Record the outcome BEFORE the advisory helper below. This script runs under
    # `set -e`, so a suggest-split.sh failure would exit right here — leaving the one
    # non-PASS path that used to record no terminal_status still recording none, and
    # wedging every later reader on a run that is demonstrably finished. The status is
    # the load-bearing part; the split advice is not.
    write_terminal_status too_large
    # Run suggest-split helper to show grouping advice (only useful for multi-file diffs)
    if [ "$STAGED_FILE_COUNT" -gt 1 ]; then
      bash "$SCRIPT_DIR/suggest-split.sh" || true
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
  # #576: the SAME pinned endpoints as the reviewer diff and the marker hash. This
  # decides which findings count as in-diff, so filtering against a moved ref can drop
  # real findings from a review that is bound to a different snapshot.
  DIFF_FOR_FILTER=$(git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --no-ext-diff --no-textconv --text --unified=0 "${_PR_BASE_REF}...${_PR_TIP}" -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null || true)
else
  # #576: same pin — this drives which findings are kept as in-diff.
  # Same pin and the same --text reasoning as STAGED_DIFF; this drives which findings
  # are kept as in-diff, so a blinded rendering here silently drops real findings.
  DIFF_FOR_FILTER=$(git --no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --text --unified=0 ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} -- :/ "${REVIEW_EXCLUDE_ARGS[@]}" 2>/dev/null || true)
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
#   - EVERY changed path is passive prose (SC_PASSIVE_PATTERN, #415)
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

  # Passive-path allowlist (#415). The weighted-line threshold alone was not a
  # safety predicate: deletions weigh 1/4, so a 39-line pure deletion scored 9
  # and took the fast path — removing an auth guard outright was CHEAPER to slip
  # through unreviewed than inverting it. Size is now a secondary bound; the
  # primary one is WHAT changed. Only prose takes the fast path. Everything not
  # on this allowlist — source, config, workflows, and this repo's operational
  # markdown (skills/, agents/, commands/, rules/, CLAUDE.md) — goes to full
  # Codex review regardless of edit direction or size.
  #
  # Deliberately NOT "any deletion means full review": that would send every
  # docs cleanup through Codex and there would be no fast path left.
  # Fail-CLOSED by construction — an unrecognized path fails to match and blocks.
  # The standard-doc names are anchored to the REPO ROOT (^NAME), NOT (^|/)NAME.
  # This repo carries skills/<name>/README.md, and a README documenting an
  # operational skill is not the same artifact as the root README — matching the
  # name at any depth would have handed every one of them the fast path.
  SC_PASSIVE_PATTERN='^(README|CHANGELOG|CONTRIBUTING|SECURITY|CODE_OF_CONDUCT|AUTHORS|NOTICE|LICENSE)(\.(md|markdown|txt|rst))?$|^docs/.+\.(md|markdown|txt|rst)$'
  # Classify the FULL staged path set. This intentionally lists every changed
  # path with NO review-exclusion filter and NO rename coalescing, so nothing can
  # vanish from the fast-path predicate:
  #   * A generated/excluded path (lockfile, etc.) is a non-prose path here and
  #     must force full review — it does not get dropped the way it is dropped
  #     from the review DIFF. (FILTERED_FILES is filtered and MUST NOT be reused.)
  #   * `--no-renames` splits a detected rename into its delete + add, so
  #     `git mv src/auth.ts docs/auth.md` cannot present as a lone passive
  #     destination and launder the active source onto the fast path (plain
  #     `--name-only` reports only the destination — verified against real
  #     history).
  # #576: pinned base — the short-circuit decides whether ANY reviewer runs, so it
  # must classify the same two endpoints the marker names.
  SC_PATHS=$(git diff --cached --name-only --no-renames ${_HEAD_BASE[@]+"${_HEAD_BASE[@]}"} 2>/dev/null || true)

  if [[ -n "$SC_PATHS" ]]; then
    set +e
    SC_HAS_ACTIVE=$(printf '%s\n' "$SC_PATHS" | grep -Ev "$SC_PASSIVE_PATTERN")
    SC_ACTIVE_EXIT=$?
    set -e
    # grep -Ev: 0 = an active path was found, 1 = every path is passive,
    # >=2 = the classification itself failed. Only 1 may take the fast path;
    # a failed classifier is "unknown", which is not "safe".
    if [[ "$SC_ACTIVE_EXIT" -ge 2 ]]; then
      echo "⚠️  Short-circuit: path classification failed — falling through to full review"
      SC_HAS_ACTIVE="(classification failed)"
    fi
  else
    # An empty list is "could not verify what changed", not "nothing risky
    # changed" — an empty staged set exits earlier, so reaching here is a fault.
    SC_HAS_ACTIVE="(no file list)"
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
    if [[ "$SC_GREP_EXIT" -eq 2 ]]; then
      echo "⚠️  Short-circuit: invalid regex in LITMUS_SHORTCIRCUIT_EXTRA_SENSITIVE — falling through to full review"
      SC_REGEX_OK=false
    fi
  fi

  if [[ "$SC_REGEX_OK" = true ]] \
      && [[ -z "$SC_HAS_ACTIVE" ]] \
      && [[ "$WEIGHTED_LINES" -lt "$SC_MAX_LINES" ]] \
      && [[ "$SAST_COUNT" -eq 0 ]] \
      && [[ "$MD_COUNT" -eq 0 ]] \
      && [[ -z "$SC_HAS_SENSITIVE" ]]; then
    echo ""
    echo "⚡ Short-circuit PASS — skipping Codex CLI review"
    echo "   Diff: $WEIGHTED_LINES weighted lines (< $SC_MAX_LINES threshold)"
    echo "   Paths: passive prose only | SAST: 0 findings | Markdown: 0 findings | Sensitive paths: none"
    echo ""

    # Log metric (same schema as normal review — cli labeled as short-circuit)
    log_review_metrics "PASS" "0" "$ITERATION" "$REVIEW_MODE" "short-circuit" '{"status":"PASS","issues":[],"short_circuit":true}'

    # Write commit marker (same format as normal PASS)
    # #576: the reviewed snapshot — the short-circuit classified THOSE paths.
    mkdir -p "$STATE_DIR"
    require_reviewed_diff_hash
    printf '%s\n' "$REVIEWED_DIFF_HASH" > "$STATE_DIR/litmus-passed.local"

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

# All placeholder values are computed first, then spliced in a single pass by
# render_prompt (below) — see lib/inject.sh for why one-at-a-time substitution
# corrupted the reviewer's copy (#393).

# Build SAST pre-check results
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

# Compute PR commit history (PR mode only). init-review-loop.sh emits only the
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
# Splice every value into the template in one forward pass. Single pass (not
# seven ${var/}/inject calls) so an injected value that itself contains a
# placeholder token — e.g. a staged diff of this very file — cannot be re-read as
# a later placeholder. Absent placeholders (e.g. {{HISTORY_CONTEXT}} in commit
# mode) are ignored. See lib/inject.sh (#393).
FINAL_PROMPT=$(render_prompt "$PROMPT" \
  '{{PREV_CHANGELOG}}'    "$PREV_CHANGELOG" \
  '{{STAGED_DIFF}}'       "$STAGED_DIFF" \
  '{{ITERATION_HISTORY}}' "$ITER_HISTORY" \
  '{{SAST_PRECHECK}}'     "$SAST_PRECHECK_TEXT" \
  '{{SMART_CONTEXT}}'     "$SMART_CONTEXT_OUTPUT" \
  '{{DOCS_CONTEXT}}'      "$DOCS_CONTEXT_OUTPUT" \
  '{{HISTORY_CONTEXT}}'   "$HISTORY_CONTEXT_OUTPUT")

# Run review via resolved CLI
echo "🔬 Running $RESOLVED_CLI review (loop attempt $ITERATION/$MAX_ITER)..."
echo ""

REVIEW_TIMEOUT="${LITMUS_TIMEOUT:-540}"  # 9 min default — UNDER the 600s harness Bash cap so a
                                          # blocking caller normally outlives the review on a clean
                                          # single attempt (see #368). Configurable via env var;
                                          # raising it to 600 or above reintroduces the kill-mid-review
                                          # / orphaned-PENDING failure (setup/cleanup run inside the
                                          # same 600s harness budget, so 600 exactly leaves no headroom
                                          # either). NOTE: on the codex path, _execute_codex
                                          # (scripts/lib/resolve-cli.sh) gives EVERY retry attempt this
                                          # same full duration, not a shared/decrementing one — a quick
                                          # transient failure + backoff + a near-full-duration retry can
                                          # still exceed the 600s cap without raising this value.
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
  # Arm the handoff EXCLUSIVELY. `set -o noclobber` makes the redirection O_EXCL, so
  # it fails rather than overwrites if the path already exists — and O_EXCL refuses to
  # follow a symlink, which also closes the /tmp sidecar hijack (a predictable path
  # next to a visible mktemp name, pre-created as a symlink by another local user, so
  # this process writes through it). `umask 077` makes the files private from the
  # instant they exist; a chmod AFTER the redirect leaves a world-readable window, and
  # a chmod BEFORE it does nothing at all because the file is not there yet.
  #
  # Refusing on an existing pointer is the fix for the overlap the per-run keying alone
  # could not close: run A exits 3, its reviewer starts, run B overwrites the pointer,
  # and reviewer A's writer then consumes run B's hash — certifying diff B though
  # reviewer A saw diff A. An un-consumed handoff now blocks the second arming instead
  # of silently replacing the first. Stale handoff after an abandoned builtin review:
  # delete the two files the message names.
  # PR mode does NOT arm this handoff. The handoff exists to mint the COMMIT marker
  # (litmus-passed.local), and a PR-mode hash describes base...HEAD, not the staged
  # index — the commit gate could never validate it, so writing one would produce a
  # marker that is either unusable or, worse, mistaken for a staged-diff binding.
  # PR mode already treats a builtin (non-Codex) lead as fail-closed, so the correct
  # outcome here is no handoff at all: the marker writer then refuses, which is the
  # documented behaviour. This also replaces the earlier fix for naming the commit-mode
  # variable unconditionally, which aborted PR mode on an unbound variable under `set -u`.
  if [ "$REVIEW_MODE" = "pr" ]; then
    echo "❌ PR mode: no external reviewer succeeded, and a builtin lead is not accepted." >&2
    echo "   PR mode is fail-closed on a non-Codex lead, so there is no marker to write." >&2
    # NOT exit 3: that code's contract tells the caller to dispatch the builtin reviewer
    # and then the marker writer — which would either fail confusingly or mint a
    # commit-mode marker from a base...HEAD hash the commit gate can never validate.
    # Report an honest terminal state instead, and leave no active state behind for
    # init-review-loop.sh to trip over.
    clear_iteration_history
    rm -f "$STATE_FILE" 2>/dev/null
    write_terminal_status infra_failure
    exit 1
  fi
  _handoff_hash="${REVIEWED_DIFF_HASH:-}"
  if [ -z "$_handoff_hash" ]; then
    echo "❌ No reviewed-diff hash captured for the builtin handoff — refusing to arm it." >&2
    rm -f "$BUILTIN_PROMPT_FILE" 2>/dev/null || true
    write_terminal_status setup_error
    exit 1
  fi
  # Chain the two writes EXPLICITLY. `if ! ( ... )` puts the subshell in a condition
  # context, which suspends `set -e` inside it — so without these `||`s a failed
  # pointer write would fall through, the sidecar write would succeed, and the subshell
  # would report success while the FIRST review still owned the pointer: reviewer A
  # paired with hash B, the very thing this exclusivity exists to prevent. The
  # symmetric case matters too — if the sidecar fails we must not leave a freshly
  # created authority pointer behind, so unlink it before failing.
  if ! ( umask 077; set -o noclobber
         echo "$BUILTIN_PROMPT_FILE" > "$STATE_DIR/builtin-review-prompt-path.local" || exit 1
         printf '%s\n' "$_handoff_hash" > "$STATE_DIR/builtin-review-${BUILTIN_PROMPT_FILE##*/}.hash" || {
             rm -f "$STATE_DIR/builtin-review-prompt-path.local"; exit 1; } ) 2>/dev/null; then
    echo "❌ A builtin review handoff is already armed and unconsumed — refusing to overwrite it." >&2
    echo "   Another builtin review is in flight, or a previous one was abandoned." >&2
    echo "   Do NOT delete it by hand while a review may still be running: that reviewer" >&2
    echo "   would then mint its marker against THIS run's diff. Confirm no builtin review" >&2
    echo "   is in flight first, then remove $STATE_DIR/builtin-review-prompt-path.local" >&2
    echo "   and its $STATE_DIR/builtin-review-*.hash sidecar." >&2
    rm -f "$BUILTIN_PROMPT_FILE" 2>/dev/null || true
    write_terminal_status setup_error
    exit 1
  fi
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
    # Codex lead PASS, Claude must run the captured read-only Security/Bugs backstop
    # (Step 2) via --run-backstop, then call
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
        echo "   ℹ️  Claude Security/Bugs backstop pending — run --run-backstop (captured"
        echo "       read-only dispatch), then --write-pr-marker (requires BOTH voices PASS)."
      else
        echo "❌ Could not record Codex lead verdict (missing base / empty diff)" >&2
        write_terminal_status setup_error
        exit 1
      fi
    fi
  else
    # Commit mode: write commit marker for pre-commit gate.
    # #576: the hash captured BEFORE the review, not a fresh one taken now —
    # "now" can be many minutes after the reviewer saw the diff.
    require_reviewed_diff_hash
    printf '%s\n' "$REVIEWED_DIFF_HASH" > "$STATE_DIR/litmus-passed.local"
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
