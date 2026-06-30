#!/usr/bin/env bash
# run-retrieval-loop.sh — ADR 0007 Phase 5 thin two-round wrapper. Round 1: ask the
# Oracle (given a repo inventory) what files/searches it needs. Retrieve them read-only
# via retrieve-evidence.sh. Round 2: send the retrieved evidence back and validate the
# ORACLE_RETRIEVAL_REVIEW. Live dispatch is gated behind the USER-config, default-OFF
# ultraOracle.blueprintReview.enabled flag. Fail-CLOSED on every error.
set -euo pipefail
umask 077   # question copy, prompts, and Oracle round1/round2 JSON are operator-only on disk
_RL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="$(cd "$_RL_DIR/../../.." && pwd)/scripts/lib"
# shellcheck source=/dev/null
source "$_LIB/ultra-oracle.sh"
# shellcheck source=/dev/null
source "$_LIB/ultra-oracle-config.sh"
# evidence-safety gates — so Round-1 INPUTS (inventory + question) route through the same
# single-sourced secret boundary as the retrieval step (not just the retrieved output).
# shellcheck source=/dev/null
source "$_RL_DIR/lib/evidence-safety.sh"

QUESTION_FILE=""; OUT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    # Guard $2 presence BEFORE reading it: under `set -u`, a bare `--question-file` with no
    # value would abort with an unbound-variable error and SKIP the promised typed token.
    --question-file) [ $# -ge 2 ] || { echo "error: --question-file needs a value" >&2; printf 'error'; exit 2; }; QUESTION_FILE="$2"; shift 2;;
    --out-dir)       [ $# -ge 2 ] || { echo "error: --out-dir needs a value" >&2; printf 'error'; exit 2; }; OUT_DIR="$2"; shift 2;;
    *) echo "error: unknown arg '$1'" >&2; printf 'error'; exit 2;;
  esac
done
[[ -n "$OUT_DIR" ]] || { echo "error: --out-dir required" >&2; printf 'error'; exit 2; }

# Gate: default-OFF. No live dispatch unless the operator opted in (USER config only).
# Checked FIRST so a disabled run with no --question-file still cleanly skips (Step 5).
if ! ultra_oracle_surface_enabled blueprintReview; then printf 'skipped:disabled'; exit 0; fi

# Fail CLOSED before the first BILLED consult: require a present, readable, NON-EMPTY
# question. The consult's own guard only checks the prompt (which always carries
# the inventory header), so an empty question would otherwise reach a paid Round-1 call.
# -f (regular file) is REQUIRED, not just -r/-s: a directory satisfies -r and -s, and the
# later `cat "$QUESTION_FILE" 2>/dev/null || true` would suppress its read failure, letting
# an empty original question reach a paid Round-1 consult.
[[ -n "$QUESTION_FILE" && -f "$QUESTION_FILE" && -r "$QUESTION_FILE" && -s "$QUESTION_FILE" ]] || { echo "error: --question-file required/regular-file/readable/non-empty" >&2; printf 'error'; exit 2; }

# Fresh-dir + symlink guard (same posture as retrieve-evidence.sh): a pre-existing OUT_DIR
# may contain planted symlinks (e.g. inventory.txt -> /etc/...) that the fixed-name `>`
# writes below would FOLLOW and overwrite. Plain `mkdir` (NO -p) rejects an existing dir;
# canonicalizing the parent resolves a symlinked parent before the containment-free write.
_od="$OUT_DIR"; while [ "$_od" != "/" ] && [ "${_od%/}" != "$_od" ]; do _od="${_od%/}"; done
_odp="${_od%/*}"; [ "$_odp" = "$_od" ] && _odp="."
_op="$(cd "$_odp" 2>/dev/null && pwd -P)" || { echo "error: --out-dir parent missing" >&2; printf 'error'; exit 1; }
OUT_DIR="$_op/${_od##*/}"
# Reject a `.`/`..` basename: `safe/..` would resolve OUT_DIR to the parent and the
# fixed-name redirects below could then write outside the intended fresh dir.
case "${_od##*/}" in .|..) echo "error: --out-dir basename must not be . or .." >&2; printf 'error'; exit 1;; esac
mkdir "$OUT_DIR" 2>/dev/null || { echo "error: out-dir exists or cannot be created — pass a fresh path" >&2; printf 'error'; exit 1; }
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_ROOT" ]] || { printf 'error'; exit 1; }
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"   # canonicalize for is_secret_like

# Gate the QUESTION before the first BILLED dispatch: a secret-like question file (by name
# or content) must never be transmitted to ChatGPT Pro. Mirrors build-evidence-pack.sh.
q_canon="$(contained_path "$QUESTION_FILE" 2>/dev/null || printf '%s' "$QUESTION_FILE")"
if is_secret_like "$q_canon"; then echo "error: --question-file looks secret-like — refusing" >&2; printf 'error'; exit 2; fi

# --- Round 1: inventory -> request ---
# Inventory routes through emit_nonsecret_z so a secret-like TRACKED path name (.env.local,
# secrets/…) is never shown to the Oracle — same posture as build-evidence-pack.sh.
inv="$OUT_DIR/inventory.txt"
git -C "$GIT_ROOT" ls-files -z 2>/dev/null | emit_nonsecret_z | head -n 2000 > "$inv" || true
r1prompt="$OUT_DIR/round1-prompt.txt"
{ echo "You are a repo-grounded expert witness. Given this file inventory and the"
  echo "question below, return ONLY JSON: {needed_files:[{path,reason}], search_queries:[{query,reason}], cannot_assess_yet:[...]}."
  echo "--- QUESTION ---"; cat "$QUESTION_FILE" 2>/dev/null || true
  echo "--- INVENTORY ---"; cat "$inv"; } > "$r1prompt"
r1out="$OUT_DIR/round1.json"
# errexit-safe capture: ultra_oracle_consult RETURNS NON-ZERO for the typed tokens
# error(1)/timeout(124)/skipped:unavailable(3). Under `set -e`, a bare st1=$(...) aborts
# the wrapper HERE — before the status-check line — so it would exit WITHOUT printing the
# typed token its own contract promises. Capture in if/else; default a lost token to error.
if st1="$(ultra_oracle_consult --prompt-file "$r1prompt" --out "$r1out" --slug "oracle retrieval round1")"; then :; else [ -n "$st1" ] || st1=error; fi
# Treat the operator opt-out tokens as intentional SKIPS (exit 0), not errors —
# ultra_oracle_consult returns skipped:user (return 0) for .claude/skip-ultra-oracle.local.
# timeout/error/skipped:unavailable stay fail-closed (non-zero).
case "$st1" in
  ok) : ;;
  skipped:user|skipped:disabled) printf '%s' "$st1"; exit 0 ;;
  *) printf '%s' "$st1"; exit 1 ;;
esac

# --- Retrieval (read-only, gated) ---
"$_RL_DIR/retrieve-evidence.sh" --request-file "$r1out" --out-dir "$OUT_DIR/evidence" || { printf 'error'; exit 1; }

# --- Round 2: send evidence -> review ---
r2prompt="$OUT_DIR/round2-prompt.txt"
# Each consult is a fresh stateless call — Round 2 MUST re-state the original question and
# the Round-1 request, or the Oracle reviews evidence with no objective and emits
# structurally-valid but ungrounded claims (defeats the two-round loop).
{ echo "Using ONLY the attached retrieved evidence, answer the ORIGINAL QUESTION below."
  echo "Return ONLY JSON with review_type \"ORACLE_RETRIEVAL_REVIEW\", claims[].evidence as"
  echo "[\"path:line\"] strings, and verdict PASS|FAIL|UNCERTAIN."
  echo "--- ORIGINAL QUESTION ---"; cat "$QUESTION_FILE" 2>/dev/null || true
  echo "--- YOUR ROUND-1 REQUEST ---"; cat "$r1out" 2>/dev/null || true
  echo "--- RETRIEVAL MANIFEST ---"; cat "$OUT_DIR/evidence/manifest.txt" 2>/dev/null || true; } > "$r2prompt"
r2out="$OUT_DIR/round2.json"
# Attach ALL retrieved evidence under files/ as context — copied source files AND the
# search-N.txt artifacts (the executor writes searches under files/ too), each already
# secret-gated (path + content) by the executor. One glob grounds both files and searches.
ctx=(); for f in "$OUT_DIR/evidence/files/"*; do [ -e "$f" ] && ctx+=(--context "$f"); done
# Fail CLOSED before billing Round 2 if retrieval produced NO evidence: a review with only
# the manifest (no source/search context) cannot be grounded — the validator would reject
# its uncited claims anyway, so spend no paid consult on it.
[ "${#ctx[@]}" -gt 0 ] || { echo "error: retrieval produced no evidence — failing closed before Round 2" >&2; printf 'error'; exit 1; }
# errexit-safe capture (same rationale as Round 1).
if st2="$(ultra_oracle_consult --prompt-file "$r2prompt" --out "$r2out" --slug "oracle retrieval round2" "${ctx[@]:-}")"; then :; else [ -n "$st2" ] || st2=error; fi
case "$st2" in
  ok) : ;;
  skipped:user|skipped:disabled) printf '%s' "$st2"; exit 0 ;;
  *) printf '%s' "$st2"; exit 1 ;;
esac

# --- Validate Round 2, fail-closed ---
if vres="$("$_RL_DIR/validate-retrieval-review.sh" --review-file "$r2out")"; then
  echo "ORACLE_RETRIEVAL_REVIEW ${vres#OK }"
else
  printf 'error'; exit 1
fi
