#!/bin/bash
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Iteration history management for litmus review convergence
# Tracks issues found across iterations so the LLM can converge

# Store iteration history alongside review state in .claude/ (safe from /tmp symlink attacks)
ITERATION_HISTORY_FILE="$STATE_DIR/litmus-iteration-history.local.jsonl"

# Append current iteration's issues to history
# Usage: append_iteration_history <iteration_number> <json_output>
append_iteration_history() {
  local iteration="$1"
  local json_output="$2"

  # Extract issues array and add iteration metadata
  local entry
  entry=$(echo "$json_output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
entry = {
    'iteration': int(sys.argv[1]),
    'status': data.get('status', 'UNKNOWN'),
    'issues': data.get('issues', [])
}
print(json.dumps(entry))
" "$iteration" 2>/dev/null) || return 1

  echo "$entry" >> "$ITERATION_HISTORY_FILE"
}

# Load iteration history formatted for prompt injection
# Returns empty string if no history exists
load_iteration_history() {
  if [ ! -f "$ITERATION_HISTORY_FILE" ] || [ ! -s "$ITERATION_HISTORY_FILE" ]; then
    echo ""
    return 0
  fi

  python3 -c "
import sys, json

lines = open(sys.argv[1]).read().strip().split('\n')
if not lines or lines == ['']:
    sys.exit(0)

print('PREVIOUS ITERATION HISTORY:')
print('The following issues were found in previous review iterations.')
print('Issues that have been fixed should NOT be re-reported.')
print('')

for line in lines:
    try:
        entry = json.loads(line)
        iteration = entry['iteration']
        status = entry['status']
        issues = entry['issues']
        print(f'--- Iteration {iteration} (status: {status}) ---')
        if issues:
            for issue in issues:
                sev = issue.get('severity', '?')
                f = issue.get('file', '?')
                ln = issue.get('line', '?')
                desc = issue.get('description', '?')
                print(f'  [{sev}] {f}:{ln} - {desc}')
        else:
            print('  No issues found.')
        print('')
    except:
        continue
" "$ITERATION_HISTORY_FILE" 2>/dev/null
}

# Shared Python snippet for fingerprinting blocking issues.
# Used by both compute_issue_fingerprint and is_stalled.
#
# IMPORTANT: this heredoc is single-quoted in bash, so the body is passed to
# python3 verbatim — no shell escape processing. That means we CANNOT use the
# `f"{i[\"file\"]}..."` style (the `\"` inside a single-quoted bash heredoc
# survives as a literal backslash + quote, which Python rejects as a syntax
# error inside an f-string expression). String concatenation lets Python use
# its own double-quote literals without any escape gymnastics. This bug
# previously left both compute_issue_fingerprint and is_stalled silently
# returning "unknown" / empty, so stall detection never fired — issue #105's
# mock-CLI harness exposed it.
_FINGERPRINT_PY='
import sys, json, hashlib
issues = json.load(sys.stdin)
if isinstance(issues, dict):
    issues = issues.get("issues", [])
blocking = sorted(
    str(i.get("file", "")) + ":" + str(i.get("severity", "")) + ":" + str(i.get("description", "") or "")[:50]
    for i in issues
    if i.get("severity") in ("high", "medium")
)
print(hashlib.md5("|".join(blocking).encode()).hexdigest() if blocking else "empty")
'

# Compute a fingerprint of the current blocking issue set
# Used for stall detection: if fingerprint matches previous iteration, loop is stuck
compute_issue_fingerprint() {
  local json_output="$1"
  echo "$json_output" | python3 -c "$_FINGERPRINT_PY" 2>/dev/null || echo "unknown"
}

# Check if current issue set matches the previous iteration (stall detection)
# Returns 0 (true) if stalled, 1 (false) if progressing
is_stalled() {
  local current_fingerprint="$1"
  [ ! -f "$ITERATION_HISTORY_FILE" ] && return 1
  local prev_fingerprint
  # Extract issues array from the last JSONL entry, then fingerprint
  prev_fingerprint=$(tail -1 "$ITERATION_HISTORY_FILE" 2>/dev/null | python3 -c "$_FINGERPRINT_PY" 2>/dev/null) || return 1
  [ "$current_fingerprint" = "$prev_fingerprint" ]
}

# Clear iteration history (called on PASS or init)
clear_iteration_history() {
  rm -f "$ITERATION_HISTORY_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cross-run PR review history (#811)
#
# The file above is per-LOOP-RUN: init-review-loop.sh clears it on every init and
# run-review-loop.sh clears it on PASS. In commit mode that is right — the staged
# diff is discarded at commit time, so nothing carries over. In PR mode it is not:
# the diff is base...HEAD, so a re-triggered `gh pr create` reviews a SUPERSET of
# what the previous run already reviewed, with no memory of it. Measured on one
# branch: 17 PR passes, 66,296 diff-lines re-read, pass 17 re-deriving everything
# passes 1–16 established (issue #811).
#
# This store is the memory. It is deliberately NOT a coverage reduction — the
# reviewer still reads the whole base...HEAD diff every pass. It only stops the
# reviewer from re-deriving verdicts it already reached, which is what makes a
# pass expensive in reasoning even when the diff is cheap to read. Narrowing what
# PR mode READS (the other direction floated in #811) needs a non-forgeable anchor
# and is not attempted here.
#
# Anchoring is by commit SHA, checked with `git merge-base --is-ancestor`, and it
# is what keeps a stale entry from ever being shown:
#   - not an ancestor of HEAD → the commit is gone from this branch (rebase,
#     force-push, reset, a different branch entirely) → dropped.
#   - an ancestor of the PR base → already merged, belongs to a previous PR →
#     dropped.
# Both filters fail SAFE: an unresolvable SHA drops out and the reviewer simply
# starts cold, which is exactly today's behaviour.
#
# Stall detection is NOT moved here on purpose. is_stalled compares against the
# per-run file; pointing it at this one would let iteration 1 of a fresh run stall
# against the last run's FAIL and refuse to review at all.
# Anchored at the repo top, not the CWD. $STATE_DIR is relative, and unlike the
# per-run file — created and cleared inside one run, so a relative path is at
# least self-consistent — this store is only useful if every run of a branch
# finds the SAME file. A run launched from a subdirectory would otherwise open
# its own empty store and start cold, silently. Same construction as
# run-review-loop.sh's PR_STATE_DIR.
_PR_HISTORY_TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
PR_HISTORY_FILE="$_PR_HISTORY_TOP/$STATE_DIR/litmus-pr-history.local.jsonl"

# The store is a plain gitignored file, so both ends check that it still IS one
# before touching it. A symlink planted at that path (committed, or dropped by
# anything with write access to $STATE_DIR) would otherwise turn the append into
# a write to an arbitrary user-writable target, and the read into an injection
# channel straight into the reviewer's prompt. Absent is fine — that is the
# first-run case. Anything present that is not a regular file is refused, which
# costs at most a cold review.
#
# It is enforced with O_NOFOLLOW on the open itself, not a `[ -L ]` test before
# it: a test-then-open is two operations, and anything that can plant the symlink
# can plant it in between. Residual, and deliberately not chased here: O_NOFOLLOW
# refuses a symlinked FINAL component only, so a symlinked $STATE_DIR still
# redirects — which is true of every gate marker in this tree, not this file.

# Append one completed PR-mode verdict, stamped with the commit it reviewed.
# Called on BOTH PASS and FAIL (a clean verdict for an ancestor commit is useful
# context too). Never fatal: this is advisory context, so a failure to record it
# must not fail the review.
#
# <reviewed_head_sha> is the commit resolved BEFORE the review started, passed in
# by the caller. Resolving HEAD here instead would stamp the verdict onto a commit
# that landed mid-review, and the next pass would read it as a completed review of
# code nobody reviewed. Missing or malformed → record nothing.
# Usage: append_pr_history <json_output> <reviewed_head_sha>
append_pr_history() {
  local json_output="$1"
  local head_sha="${2:-}"
  case "$head_sha" in
    *[!0-9a-f]* | "") return 0 ;;
  esac
  [ "${#head_sha}" -eq 40 ] || return 0
  mkdir -p "$_PR_HISTORY_TOP/$STATE_DIR" 2>/dev/null || return 0
  printf '%s' "$json_output" | python3 -c '
import json, os, stat, sys

path, head_sha = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
record = json.dumps({
    "head_sha": head_sha,
    "status": data.get("status", "UNKNOWN"),
    "issues": data.get("issues", []),
}) + "\n"
try:
    # O_NOFOLLOW refuses a symlink at the path; O_APPEND keeps a concurrent
    # reviewer'"'"'s record from interleaving with this one. O_NONBLOCK and the
    # S_ISREG check together cover the non-symlink shapes: a FIFO planted at the
    # path would otherwise make this open BLOCK until someone reads it, hanging
    # the review inside the store meant to speed it up.
    fd = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK,
        0o600,
    )
except OSError:
    sys.exit(0)
with os.fdopen(fd, "w") as fh:
    if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
        sys.exit(0)
    fh.write(record)
' "$PR_HISTORY_FILE" "$head_sha" 2>/dev/null || return 0
}

# Render the branch's prior verdicts for prompt injection.
# Usage: load_pr_history <pr_base_ref>
# Emits nothing when no entry survives the ancestry filters.
load_pr_history() {
  local base_ref="${1:-}"
  [ -s "$PR_HISTORY_FILE" ] || { echo ""; return 0; }
  python3 - "$PR_HISTORY_FILE" "$base_ref" "${LITMUS_PR_HISTORY_MAX:-20}" <<'PY' 2>/dev/null || echo ""
import functools, json, os, stat, subprocess, sys

path, base_ref = sys.argv[1], sys.argv[2]
try:
    max_entries = max(1, int(sys.argv[3]))
except ValueError:
    max_entries = 20

# Only the tail is considered — the file is append-only and never pruned, but a
# verdict old enough to have scrolled past this window is old enough to be noise.
# The byte window is what actually bounds this: seeking to it keeps both memory
# and runtime constant no matter how large the store grows, which a read()-then-
# slice would not.
SCAN_LINES = 200
TAIL_BYTES = 512 * 1024

@functools.lru_cache(maxsize=None)
def is_ancestor(sha, ref):
    """True / False / None, where None means git could not answer at all.

    The three cases must stay distinct. `--is-ancestor` answers with 0 and 1;
    anything else (128 — a ref that no longer resolves, a corrupt object) is an
    ERROR, and collapsing it to False would read "the base could not be resolved"
    as "not merged yet" and inject verdicts that may belong to a previous PR.
    """
    rc = subprocess.run(
        ["git", "merge-base", "--is-ancestor", sha, ref],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    return True if rc == 0 else (False if rc == 1 else None)

try:
    # O_NOFOLLOW / O_NONBLOCK / S_ISREG for the same reasons as the append: a
    # symlinked store would make this read an injection channel straight into the
    # reviewer's prompt, and a FIFO would hang the review before it started.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
            sys.exit(0)
        size = fh.seek(0, os.SEEK_END)
        fh.seek(max(0, size - TAIL_BYTES))
        chunk = fh.read()
except OSError:
    sys.exit(0)
if size > TAIL_BYTES:
    # The window almost certainly starts mid-record; drop that partial line.
    _, _, chunk = chunk.partition(b"\n")
lines = chunk.decode("utf-8", "replace").strip().split("\n")[-SCAN_LINES:]

HEX = set("0123456789abcdef")
kept = []
for line in lines:
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    sha = str(entry.get("head_sha") or "")
    # Strict hex: the value reaches git as argv, so it cannot inject a command,
    # but a `-`-leading string would be read as a flag. Reject anything odd.
    if len(sha) != 40 or not set(sha) <= HEX:
        continue
    # Both filters demand a definite answer; an unanswerable one drops the entry
    # and the pass starts cold, which is exactly the pre-#811 behaviour.
    if is_ancestor(sha, "HEAD") is not True:
        continue
    if base_ref and is_ancestor(sha, base_ref) is not False:
        continue
    kept.append(entry)

kept = kept[-max_entries:]
if not kept:
    sys.exit(0)

print("PREVIOUS REVIEW VERDICTS FOR THIS BRANCH (from earlier review runs):")
print("Each block is one completed review of a commit that is still on this branch.")
print("Line numbers may have shifted since — re-verify against the diff above rather")
print("than trusting them. Do NOT re-report a finding the diff shows is already fixed.")
print("Do NOT skip a lens because an earlier verdict was clean: this pass covers a")
print("larger diff than any of the passes below.")
print("")
# Every field below is free-form text a reviewer wrote about a diff, so it can
# echo whatever that diff contained — and unlike a per-run history it persists for
# the branch's lifetime and is re-injected on every later pass. Clamp each field
# so a single poisoned finding cannot dominate the prompt it lands in. This is a
# blast-radius limit, not sanitization: the reviewer already reads the diff this
# text came from, so the content itself is not new to it.
def clip(value, limit):
    text = str(value).replace("\n", " ").replace("\r", " ")
    return text if len(text) <= limit else text[:limit] + "…"

for entry in kept:
    print("--- commit {} (status: {}) ---".format(
        entry["head_sha"][:8], clip(entry.get("status", "UNKNOWN"), 16)))
    issues = entry.get("issues") or []
    if issues:
        for issue in issues:
            print("  [{}] {}:{} - {}".format(
                clip(issue.get("severity", "?"), 16),
                clip(issue.get("file", "?"), 200),
                clip(issue.get("line", "?"), 16),
                clip(issue.get("description", "?"), 500)))
    else:
        print("  No issues found.")
    print("")
PY
}
