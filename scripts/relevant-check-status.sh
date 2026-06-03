#!/usr/bin/env bash
# scripts/relevant-check-status.sh — canonical lock-aware check-status filter.
#
# Single source of truth for "which `gh pr checks` failures/pendings count"
# across the four surfaces that previously each embedded the logic (issue #154):
#   - hooks/gate-scripts/pre-merge-gate.sh      (count logic extracted from here)
#   - skills/pr-grind/SKILL.md  Step 1 Phase 2.5
#   - skills/pr-grind/SKILL.md  Completion verify-checks-green
#   - agents/pr-grinder.md      worker Phase 2.5
# Filter edits now touch one file instead of four kept in lockstep.
#
# The count-computation logic is preserved unchanged from
# hooks/gate-scripts/pre-merge-gate.sh:44-103 (PR #155 lock-aware allowlist).
# Row emission (stdout lines 2..N) is ADDED so callers can display the failing
# checks without re-deriving the allowlist themselves.
#
# CONTRACT
#   stdin : raw `gh pr checks <PR>` text. Rows are TAB-separated:
#           <name>\t<status>\t<elapsed>\t<link>. Lines without a tab (gh error
#           text) are discarded — they must not inflate `kept`.
#   $1    : repo-root DIRECTORY — used to locate <dir>/.github/required-checks.lock.
#           MUST be the checkout root, NOT the repo name. Passing a bare name
#           (e.g. "busdriver") resolves the lock at ./busdriver/.github/... which
#           does not exist, silently falling back to mode=all. Defaults to ".".
#   $2    : advisory pattern (optional). Resolution order: $2 >
#           $RELEVANT_CHECK_ADVISORY_PATTERN > "CodeScene". An EMPTY value is
#           reset to "CodeScene" — an empty regex matches every row, which would
#           filter out all checks (kept=0) and trip a spurious bootstrap block.
#
# OUTPUT (stdout)
#   line 1     : "<failed> <pending> <mode> <kept>"  (space-separated;
#                mode ∈ {required, all}). Identical SHAPE to the original
#                function, so the gate's `read -r FAILED PENDING MODE KEPT
#                <<<"$COUNTS"` is unchanged (no arity break, no version skew).
#   lines 2..N : the kept-and-failed `gh pr checks` rows, VERBATIM (one per
#                line), emitted only when failed>0. `read … <<<` consumes only
#                line 1, so these never corrupt the gate parse; pr-grind reads
#                them with `tail -n +2` for its failing-checks display and the
#                worker's RESULT_REMAINING fold. No external check name reaches
#                line 1 → no tab/newline/control-word injection of the counts.
#
# FAIL-CLOSED
#   The script ALWAYS exits 0. On any internal error (python3 absent or crash,
#   malformed parser output) it emits the conservative blocking line "1 0 all 0"
#   (failed=1 ⇒ blocks; kept=0 ⇒ trips the gate's KEPT>0 bootstrap guard) plus a
#   one-line stderr diagnostic naming the cause (so a missing python3 is not an
#   opaque "1 check failing"). Callers still wrap defensively:
#     COUNTS=$(printf '%s\n' "$CHECKS_RAW" | bash "$SCRIPT" "$REPO_DIR" 2>/dev/null \
#              || printf '1 0 all 0\n')
#
# SELF-RESOLVER (dogfood-safety)
#   When invoked from inside a busdriver checkout, re-exec the working-tree copy
#   of this script instead of whatever the caller resolved (typically the cached
#   plugin copy). This lets an in-flight fix to this file be dogfooded rather
#   than shadowed by the stale cache — the same forward-fix the ack-ledger.sh
#   self-resolver provides (modeled on it; see ack-ledger PR #79/#140 history).
#   Disable with BUSDRIVER_DISABLE_RELEVANT_CHECK_SELF_RESOLVE=1. Detection is a
#   no-op (falls through to this script's body) when any predicate fails: CWD is
#   not a busdriver checkout, git/remote unavailable, the working-tree copy is
#   missing, or the self-path already IS that copy (the -ef inode test guards
#   against infinite re-exec on symlinked checkouts). Correctness of the lock
#   lookup does NOT depend on the resolver — it depends on the explicit $1
#   repo-dir argument; the resolver is path-routing only.

if [ "${BUSDRIVER_DISABLE_RELEVANT_CHECK_SELF_RESOLVE:-0}" != "1" ] && \
   _self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) && \
   _git_root=$(git rev-parse --show-toplevel 2>/dev/null) && \
   _remote=$(git -C "$_git_root" remote get-url origin 2>/dev/null) && \
   printf '%s' "$_remote" | grep -qE '(^|[@/])github\.com[:/]chris-yyau/busdriver(\.git)?$' && \
   [ -d "$_git_root/scripts" ] && \
   [ -f "$_git_root/scripts/relevant-check-status.sh" ] && \
   ! [ "$_self_dir" -ef "$_git_root/scripts" ]; then
  exec bash "$_git_root/scripts/relevant-check-status.sh" "$@"
fi
unset _self_dir _git_root _remote

REPO_DIR="${1:-.}"

# Advisory pattern: $2 > env > default; empty resets to default (empty regex
# would match every row → kept=0 → spurious bootstrap block).
ADVISORY_PATTERN="${2:-${RELEVANT_CHECK_ADVISORY_PATTERN:-CodeScene}}"
[ -z "$ADVISORY_PATTERN" ] && ADVISORY_PATTERN="CodeScene"

# Conservative blocking line for every failure path. failed=1 ⇒ block;
# kept=0 ⇒ trips the gate's KEPT>0 bootstrap guard.
_fail_closed() { printf '1 0 all 0\n'; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "relevant-check-status: python3 not found — emitting conservative block" >&2
  _fail_closed
  exit 0
fi

# Count-computation logic preserved verbatim from pre-merge-gate.sh:49-101.
# Single quotes are intentional (python body, no shell expansion).
# shellcheck disable=SC2016
_out=$(python3 -c '
import sys, os, json, re
repo_dir = sys.argv[1]
adv_pat_src = sys.argv[2]
lock = os.path.join(repo_dir, ".github", "required-checks.lock")
required = None
if os.path.isfile(lock):
    try:
        with open(lock) as f:
            d = json.load(f)
        names = [r.get("name", "") for r in d.get("required", []) if r.get("name")]
        names = [n.strip() for n in names if n.strip()]
        if names:
            required = set(names)
    except Exception:
        required = None

advisory_pat = re.compile(adv_pat_src, re.I)
mode = "required" if required is not None else "all"

def _status(line):
    parts = line.split("\t")
    return parts[1].strip().lower() if len(parts) > 1 else ""

lines = [ln.rstrip("\n") for ln in sys.stdin if ln.strip()]
lines = [ln for ln in lines if "\t" in ln]
if required is not None:
    kept = [ln for ln in lines if ln.split("\t", 1)[0].strip() in required]
else:
    kept = [ln for ln in lines if not advisory_pat.search(ln.split("\t", 1)[0])]
failed_rows = [ln for ln in kept if _status(ln) in ("fail", "failure")]
pending = sum(1 for ln in kept if _status(ln) in ("pending", "queued", "in_progress", "expected"))
# line 1: counts (4 fields, identical to the original). lines 2..N: failing rows.
print(f"{len(failed_rows)} {pending} {mode} {len(kept)}")
for ln in failed_rows:
    print(ln)
' "$REPO_DIR" "$ADVISORY_PATTERN" 2>/dev/null) || {
  echo "relevant-check-status: parser failed — emitting conservative block" >&2
  _fail_closed
  exit 0
}

# Defensive: a python exit-0 with an empty/garbled line 1 → fail-closed.
_first=$(printf '%s\n' "$_out" | head -n1)
if [[ "$_first" =~ ^[0-9]+\ [0-9]+\ (required|all)\ [0-9]+$ ]]; then
  printf '%s\n' "$_out"
else
  echo "relevant-check-status: malformed parser output — emitting conservative block" >&2
  _fail_closed
fi
exit 0
