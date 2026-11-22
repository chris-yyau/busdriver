#!/usr/bin/env bash
# PostToolUse hook: consume codex review marker after successful git commit
#
# Deferred consumption: PreToolUse (pre-commit-gate.sh) validates the marker
# and approves the commit, but does NOT delete it. This hook runs AFTER the
# git commit completes and consumes the marker only if the commit succeeded.
#
# Why: If consumed in PreToolUse and the commit then fails (git hooks,
# merge conflict, nothing to commit, errors), the marker is lost — forcing
# a full re-review for unchanged code.
#
# Success detection: checks for git's "[branch hash]" pattern OR absence of
# known failure patterns (handles --quiet mode). Marker is preserved only
# when tool_output contains explicit failure indicators.

set -euo pipefail
# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: plugin-root override; falls back to CLAUDE_PLUGIN_ROOT.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# shellcheck disable=SC2034  # PLUGIN_ROOT used in env-var fallback chains
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) and
# re-export so every gate writes/consumes markers from the same state dir.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'exit 0' ERR

HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip if not a Bash tool call involving git
case "$HOOK_DATA" in
    *\"Bash\"*git*) ;;
    *git*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Shared repo-dir resolver — keep marker lookup cwd-anchored, consistent with
# the pre-commit gate, so the toplevel form cd "$(git rev-parse --show-toplevel)"
# consumes its marker in the real repo instead of a junk literal path.
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"

# ── Rebase/amend detection: invalidate reviewed-commits on SHA change ──
# Rebasing or amending changes commit SHAs, making the tracking file stale.
# Only fires after confirming this is a Bash tool call (not Write/Edit with
# "git rebase" in file content). Uses the raw Bash command text.
case "$HOOK_DATA" in
    *git*rebase*|*git*commit*--amend*)
        # Anchor to the PreToolUse payload cwd via the shared resolver, NOT the
        # hook process CWD. `git rev-parse` from the process CWD can resolve to a
        # different repo than where the amend/rebase actually ran, deleting the
        # wrong repo's reviewed-commits.local. Consistent with the marker lookup
        # at the foot of this script. Empty payload cwd falls back to the process
        # CWD inside the resolver, preserving prior behavior.
        # Anchor to the authoritative PreToolUse payload cwd. A rebase/amend
        # aimed at a DIFFERENT repo via `git -C <other> …` or `cd <other> && …`
        # is a documented residual — the same wrapper-form limitation
        # resolve-repo-dir.sh notes for the pre-gates (statically parsing git's
        # full arg grammar is not a boundary worth reimplementing here). In that
        # case invalidation anchors to the payload cwd; the common in-repo
        # `git commit --amend` / `git rebase` case is exact.
        _AMEND_CWD=$(printf '%s' "$HOOK_DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd') or '')" 2>/dev/null || true)
        REPO_DIR=$(gate_repo_dir_lenient "" "$_AMEND_CWD")
        REVIEWED_FILE="$REPO_DIR/$STATE_DIR/reviewed-commits.local"
        if [[ -f "$REVIEWED_FILE" ]]; then
            rm -f "$REVIEWED_FILE"
        fi
        ;;
esac

# Narrow to git commit specifically (not rebase-only or other git commands)
case "$HOOK_DATA" in
    *\"Bash\"*git*commit*) ;;
    *git*commit*\"Bash\"*) ;;
    *) exit 0 ;;
esac

# Parse command, detect git commit, check output for success pattern,
# and extract target directory for worktree-aware marker lookup.
_GATE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
PARSE_RESULT=$(printf '%s' "$HOOK_DATA" | PYTHONPATH="$_GATE_LIB" python3 -S -c "
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a repo-
# controlled gitcmd_detect.py or shadowed stdlib (json.py) cannot run in the gate.
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
try:
    import json, re
    from gitcmd_detect import git_commit
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    if tool != 'Bash':
        sys.exit(0)
    cwd = d.get('cwd') or ''
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cmd = inp.get('command', '')

    # Extract tool output text
    out = d.get('tool_output', d.get('toolOutput', {}))
    if isinstance(out, dict):
        output_text = out.get('output', '')
    elif isinstance(out, str):
        output_text = out
    else:
        output_text = ''

    # Detect a real git commit via the shared command-word detector.
    is_commit, target_dir, _amend = git_commit(cmd)

    if not is_commit:
        sys.exit(0)

    # Detect commit success using two strategies:
    # 1. Positive: git's default '[branch hash] message' output
    # 2. Negative: absence of known failure patterns (handles --quiet)
    # A commit that produces no output and no error is still a success.
    has_success_pattern = bool(re.search(r'\[[\w/.* -]+ [a-f0-9]+\]', output_text))
    failure_patterns = [
        r'nothing to commit',
        r'nothing added to commit',
        r'no changes added to commit',
        r'Aborting commit',
        r'^error:',
        r'^fatal:',
        r'hook .* failed',
    ]
    has_failure = any(re.search(p, output_text, re.MULTILINE) for p in failure_patterns)
    succeeded = has_success_pattern or (not has_failure)

    # #1148: the commit this call created, from git's own '[branch <sha>] subject'
    # line. Exactly one distinct SHA is a name; two or more print 'many', which
    # names nothing but still withholds the reviewed stamp. Read from every
    # container a harness may use (tool_response stdout as well), as
    # precreate_parse.py does.
    def texts(obj):
        if isinstance(obj, str):
            return [obj]
        if isinstance(obj, dict):
            return [obj[k] for k in ('output', 'stdout', 'stderr') if isinstance(obj.get(k), str)]
        return []
    sha_text = '\n'.join(t for c in (d.get('tool_response'), d.get('toolResponse'),
                                     d.get('tool_output'), d.get('toolOutput'))
                         for t in texts(c))
    # The SHA is the first ' <hex>]' on a line that opens with '['. Nothing
    # before it is read, so a branch name's characters and git's localized
    # labels ('detached HEAD', '(root-commit)') cannot hide it.
    named = set(re.findall(r'^\[[^\n]*? ([0-9a-f]{4,64})\](?: |$)', sha_text, re.MULTILINE))

    print('yes' if succeeded else 'no')
    print(target_dir)
    print(cwd)
    print(named.pop() if len(named) == 1 else 'many' if named else '')
except Exception:
    pass
" 2>/dev/null || true)

COMMIT_SUCCEEDED=$(echo "$PARSE_RESULT" | head -1)
TARGET_DIR=$(echo "$PARSE_RESULT" | sed -n '2p')
HOOK_CWD=$(echo "$PARSE_RESULT" | sed -n '3p')
NAMED_SHORT=$(echo "$PARSE_RESULT" | sed -n '4p')

# Only consume if commit actually succeeded
[ "$COMMIT_SUCCEEDED" != "yes" ] && exit 0

# Resolve to git repo root (cwd-anchored, consistent with the pre-commit gate so
# the toplevel cd "$(git rev-parse --show-toplevel)" form consumes the marker in
# the real repo, not a junk literal path; handles worktrees, subdirs).
REPO_DIR=$(gate_repo_dir_lenient "$TARGET_DIR" "$HOOK_CWD")

# The harness's tool_use_id, which the pre-commit gate keys its claims by.
# "absent:" = the payload has no tool_use_id key (the colon is outside the id
# charset); empty = present but unusable, null included, or the payload did not
# parse: no claim can match it.
_TUID=$(printf '%s' "$HOOK_DATA" | python3 -I -c 'import sys,json,re; d=json.load(sys.stdin); v=d.get("tool_use_id") if isinstance(d,dict) else None; print("absent:" if isinstance(d,dict) and "tool_use_id" not in d else v if isinstance(v,str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}",v) else "")' 2>/dev/null || true)

# True when HEAD is this call's reviewed commit (#1148): the output names
# nothing or HEAD, and -- with a tool_use_id -- HEAD's only parent (none for a
# root commit; a merge never qualifies) and tree are what the pre-commit gate
# recorded for the call. The
# claim's name is a digest of the tool_use_id and those values, as written there.
# They are read from the commit object's header, so a shallow boundary (whose
# parents git hides) or a replace ref cannot pass for a root commit.
head_is_this_calls() {
    [[ -z "$NAMED_SHORT" || "$NAMED_SHA" == "$HEAD_SHA" ]] || return 1
    if [[ "$_TUID" == "absent:" ]]; then
        return 0
    fi
    [[ -n "$_TUID" && -n "$HEAD_SHA" ]] || return 1
    TUID="$_TUID" SHA="$HEAD_SHA" REPO="$REPO_DIR" CLAIM_DIR="$REPO_DIR/$STATE_DIR" python3 -I -c '
import hashlib, os, subprocess, sys
e = os.environ
p = subprocess.Popen(["git", "--no-replace-objects", "-C", e["REPO"], "cat-file", "commit", e["SHA"]],
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
tree = None
parents = []
whole = False
for line in p.stdout:  # the header only; the message is never read
    if line == b"\n":
        whole = True
        break
    k, _, v = line.rstrip(b"\n").partition(b" ")
    if k == b"tree" and tree is None:
        tree = v.decode()
    elif k == b"parent":
        parents.append(v.decode())
        if len(parents) > 1:
            break  # a merge: already disqualified
# Stopping early may end git by SIGPIPE; a whole header is what counts.
p.kill()
p.stdout.close()
p.wait()
# A merge brings in history through parents the claim does not name: never bound.
if not whole or tree is None or len(parents) > 1:
    sys.exit(1)
key = hashlib.sha256(("%s\n%s\n%s" % (e["TUID"], parents[0] if parents else "", tree)).encode()).hexdigest()
claim = os.path.join(e["CLAIM_DIR"], "commit-base-claim-%s.local" % key)
sys.exit(0 if os.path.isfile(claim) and not os.path.islink(claim) else 1)
' 2>/dev/null
}

# What the records name, and whether the reviewed stamp is written (#1148).
# Records name HEAD when the hook runs, as before. HEAD is not necessarily this
# call's commit -- another session or a late delivery moves it -- and git's
# printed "[branch <sha>]" line would say which one was, but the audited command
# writes that output and can forge it. A late delivery (this call's C, then
# another session's D on it) and a forged line (another session's C, then this
# call's D on it, printing C) leave the same history, so the printed commit only
# annotates the records ("named") and is logged as its own commit-output-mismatch
# event. It never moves a record.
#
# The stamp says "this call's review covered this commit", so it needs proof that
# HEAD is this call's commit (head_is_this_calls above). Anything else -- no
# claim, an amend (its parent is not the old HEAD), a tree other than the staged
# one, another session committing between the gate and this commit or after it,
# an output naming another commit, several, or an ambiguous prefix -- withholds
# it. The residual: another session rewriting this call's commit before delivery
# while keeping its parent and tree, i.e. the reviewed content. Without a
# tool_use_id (another harness) there is no claim: the stamp is withheld only
# when the output names another commit, several, or an ambiguous prefix.
resolve_commit_shas() {
    # --verify keeps an unborn HEAD empty instead of the literal.
    HEAD_SHA=$(git -C "$REPO_DIR" rev-parse --verify -q HEAD 2>/dev/null || true)
    NAMED_SHA=""
    if [[ "$NAMED_SHORT" =~ ^[0-9a-f]{4,64}$ ]]; then
        # --disambiguate lists every OBJECT with the prefix and never a ref, so a
        # branch or tag spelled like the abbreviation cannot answer, and a prefix a
        # later commit made ambiguous resolves to nothing: exactly one commit, or none.
        # Two candidates already prove ambiguity, so no more than two are read.
        _CAND=$(git -C "$REPO_DIR" rev-parse --disambiguate="$NAMED_SHORT" 2>/dev/null | head -n 2 || true)
        if [[ "$_CAND" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
            && [[ "$(git -C "$REPO_DIR" cat-file -t "$_CAND" 2>/dev/null || true)" == commit ]]; then
            NAMED_SHA=$_CAND
        fi
    fi
    COMMIT_SHA=$HEAD_SHA
    MISMATCH=false
    NOTE_FIELD=""
    if [[ -n "$NAMED_SHA" && "$NAMED_SHA" != "$HEAD_SHA" ]]; then
        MISMATCH=true
        NOTE_FIELD=",\"named\":\"$NAMED_SHA\""
    fi
    # Gate-miss records, one "<event> <sha> <extra JSON members>" line each. The
    # observation event is deduped on the printed commit, never the HEAD record.
    AUDIT_RECS="unreviewed-commit ${COMMIT_SHA:-unknown} $NOTE_FIELD"
    if [[ "$MISMATCH" == true ]]; then
        AUDIT_RECS+=$'\n'"commit-output-mismatch $NAMED_SHA ,\"head\":\"$HEAD_SHA\""
    fi
}

# Consume the marker — commit confirmed successful
MARKER="$REPO_DIR/$STATE_DIR/litmus-passed.local"
if [ -f "$MARKER" ]; then
    MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null || echo "")
    rm -f "$MARKER"
    resolve_commit_shas

    # SKIPPED-NONE: not reviewed at all — exclude from reviewed-commits.local
    if echo "$MARKER_CONTENT" | grep -q "^SKIPPED-NONE"; then
        # Already logged by litmus run-review-loop.sh, but duplicate here
        # so post-commit bypass-log is a complete record of every commit
        printf '{"ts":"%s","event":"review-skipped-none","gate":"post-commit","sha":"%s"%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT_SHA:-unknown}" "$NOTE_FIELD" \
            >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
        # Reset circuit breaker and exit — do not track as reviewed
        rm -f "$REPO_DIR/$STATE_DIR/.gate-block-count.local" 2>/dev/null || true
        exit 0
    fi

    # BUILTIN: self-reviewed by Claude — exclude from reviewed-commits.local
    # Rationale: The PR gate smart path (pre-pr-gate.sh) skips multi-voice
    # PR review when all commits are in reviewed-commits.local. Builtin
    # self-review should NOT qualify for this shortcut — the PR deep review
    # is the real guard against self-review gaps.
    if echo "$MARKER_CONTENT" | grep -q "^BUILTIN-"; then
        # Log for audit visibility — builtin acceptance was previously silent
        printf '{"ts":"%s","event":"builtin-review-accepted","gate":"post-commit","sha":"%s"%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT_SHA:-unknown}" "$NOTE_FIELD" \
            >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
        # Reset circuit breaker and exit — do not track as reviewed
        rm -f "$REPO_DIR/$STATE_DIR/.gate-block-count.local" 2>/dev/null || true
        exit 0
    fi

    # ── Track reviewed commit SHA for smart PR gate ───────────────────
    # Append the new commit's SHA with branch context to reviewed-commits.local
    # so the PR gate can verify all base..HEAD commits were per-commit reviewed
    # without requiring a redundant full-branch re-review.
    # Format: "branch:sha" — branch-scoped to prevent cross-branch carry-over
    # (e.g., a SHA reviewed on branch A shouldn't count on branch B after cherry-pick)
    CURRENT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "detached")
    if [[ -n "$COMMIT_SHA" && "$CURRENT_BRANCH" != "detached" ]] && head_is_this_calls; then
        mkdir -p "$REPO_DIR/$STATE_DIR"
        echo "${CURRENT_BRANCH}:${COMMIT_SHA}" >> "$REPO_DIR/$STATE_DIR/reviewed-commits.local"
    fi
else
    # ── Unreviewed commit detection ──────────────────────────────────
    # No marker found after a successful commit. This means the PreToolUse
    # gate (pre-commit-gate.sh) did not block the commit — either because
    # hooks failed to fire (intermittent Claude Code platform issue) or
    # a skip file was consumed by the gate (already logged separately).
    # Log for audit visibility so the gap is not silent.
    #
    # Suppressed when:
    #   - this exact SHA was already logged unreviewed — a commit SHA is
    #     immutable, so re-firing on the same HEAD must not double-count (#352)
    #   - the pre-commit gate left a claim file named by this call's tool_use_id
    #     (#898). Only when the payload has no tool_use_id:
    #     the NEWEST skip-review-consumed event carries "skip":"litmus" and was
    #     logged in the last 120s (pre-commit gate ran and consumed
    #     skip-litmus.local). A newer record of another kind wins over an older
    #     litmus one, so the filter runs AFTER `tail -1`. Other
    #     skip-review-consumed records (the Gate 1 design-lease claim, which is
    #     written before Gate 2 decides, and legacy lines without the field) do
    #     NOT suppress — they do not sanction a markerless commit (#895).
    #   - ~/.claude repo with only auto-generated files (gate bypasses by design)
    #
    # NOT suppressed: release/version-bump commits. They are logged honestly —
    # they genuinely were not litmus-reviewed. Every emitter-side "this is a
    # release" heuristic is forgeable (subject strings are author-controlled;
    # a filename allowlist is dodged by a code payload smuggled into an inert-
    # looking manifest — package.json preinstall, plugin.json hooks), so a
    # release exemption would reopen the audit bypass this fix exists to close
    # (#352). Release entries are trivially recognizable and filterable at
    # report time.
    _SUPPRESS=false
    resolve_commit_shas

    # #898: when the payload carries the harness's tool_use_id, the pre-commit
    # gate left a claim file named by it if it consumed the litmus skip for THIS
    # call. Log order and the time window below are only a proxy,
    # fooled by interleaved runs and stale records. An unusable id (empty
    # _TUID) suppresses nothing.
    if [ -n "$_TUID" ] && [ "$_TUID" != "absent:" ]; then
        _HASH=$(printf '%s' "$_TUID" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null || true)
        _CLAIM="$REPO_DIR/$STATE_DIR/litmus-skip-claim-$_HASH.local"
        # Kept, not consumed: a repeated delivery for the same commit must find it
        # too. The pre-commit gate prunes claims after a day.
        if [[ "$_HASH" =~ ^[0-9a-f]{64}$ ]] && [ -f "$_CLAIM" ] && [ ! -L "$_CLAIM" ]; then
            _SUPPRESS=true
        fi
    fi

    # Check if a skip was recently consumed (skip file is deleted by the gate
    # before commit runs, so we check the bypass log instead).
    # Compare timestamps to avoid stale entries suppressing real warnings.
    # Only for payloads with no tool_use_id (another harness), as before #898.
    if [ "$_TUID" = "absent:" ] && [ -f "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" ]; then
        _CUTOFF=$(date -u -v-120S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _CUTOFF=$(date -u -d '120 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _CUTOFF=""
        if [ -n "$_CUTOFF" ]; then
            # The newest of the last five lines whose top-level event is a skip
            # decides; every line is parsed as strict JSON (no NaN/Infinity), so
            # whitespace or a nested field cannot change which record that is. A
            # newer line that does not parse (half-written, oversized) may be a
            # skip record, so it clears any older pick: no suppression.
            _LAST_SKIP_TS=$(tail -5 "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" | python3 -I -c '
import json, sys
def bad(name):
    raise ValueError(name)
src = sys.stdin.buffer
ts = ""
while True:
    raw = src.readline(65537)
    if not raw:
        break
    if len(raw) > 65536:  # no skip record is that long; read past it in pieces
        while not raw.endswith(b"\n"):
            raw = src.readline(65536)
            if not raw:
                break
        ts = ""
        continue
    try:  # a blank or partial line fails here too, which clears the pick
        r = json.loads(raw.decode("utf-8"), parse_constant=bad)
    except (ValueError, RecursionError):
        ts = ""
        continue
    if isinstance(r, dict) and r.get("event") == "skip-review-consumed":
        ok = r.get("skip") == "litmus" and "tool_use_id" not in r
        ts = r.get("ts") if ok and isinstance(r.get("ts"), str) else ""
print(ts)
' 2>/dev/null || true)
            # ISO timestamps are lexicographically ordered — string compare works
            if [ -n "$_LAST_SKIP_TS" ] && [[ "$_LAST_SKIP_TS" > "$_CUTOFF" ]]; then
                _SUPPRESS=true
            fi
        fi
    fi

    # ~/.claude repo: only suppress if all staged files were auto-generated
    # (mirrors the scoped bypass in pre-commit-gate.sh)
    if [ "$REPO_DIR" = "$HOME/.claude" ]; then
        _SUPPRESS=true
    fi

    # Log the gate-miss atomically, at-most-once per SHA. A commit SHA is
    # immutable, so re-firing on the same HEAD (a no-op commit mis-scored as
    # success, or a worktree HEAD re-read) must not log it twice (#352:
    # eae6149b was logged 5x in 14 min). The "already logged?" check and the
    # append run under one exclusive fcntl.flock on the log, so concurrent
    # firings for the same HEAD cannot both pass the check and double-log
    # (a plain grep-then-append is a check-then-act race). fcntl.flock is
    # portable across macOS and Linux; python3 is already a hard dependency
    # of this hook. Prints "logged" (new record), "dup" (already present), or
    # "error" (python/flock failed -> shell fail-open fallback below).
    if [[ "$_SUPPRESS" == false ]]; then
        mkdir -p "$REPO_DIR/$STATE_DIR"
        _LOGGED=$(RECS="$AUDIT_RECS" \
            LOGFILE="$REPO_DIR/$STATE_DIR/bypass-log.jsonl" \
            python3 -I -c '
# -I (isolated): ignore PYTHON* env and do NOT prepend cwd/PYTHONPATH to
# sys.path, so a repo-controlled fcntl.py/datetime.py cannot shadow stdlib.
import os, fcntl, datetime
recs = [(r.split(" ", 2) + ["", ""])[:3] for r in os.environ["RECS"].splitlines()]
path = os.environ["LOGFILE"]
try:
    outcome = "dup"
    with open(path, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        # Dedup by immutable SHA. "unknown" (HEAD unresolvable) is NOT a stable
        # identity — never dedup it, or distinct unresolved gate-misses would
        # collapse into one lost record. One pass over the log for every needle.
        needles = {i: "\"event\":\"%s\",\"gate\":\"post-commit\",\"sha\":\"%s\"" % (ev, sha)
                   for i, (ev, sha, _x) in enumerate(recs) if sha != "unknown"}
        seen = set()
        if needles:
            f.seek(0)
            for line in f:
                seen.update(i for i, n in needles.items() if n in line)
                if len(seen) == len(needles):
                    break
        for i, (ev, sha, extra) in enumerate(recs):
            if i in seen:
                continue
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            f.write("{\"ts\":\"%s\",\"event\":\"%s\",\"gate\":\"post-commit\",\"sha\":\"%s\"%s}\n" % (ts, ev, sha, extra))
            if ev == "unreviewed-commit":
                outcome = "logged"
    # Print ONLY after the with-block flushes+closes cleanly. A close/flush
    # failure (disk full) then raises into except -> "error" alone, so the
    # shell fail-open fallback runs instead of a false "logged".
    print(outcome)
except Exception:
    print("error")
' 2>/dev/null || echo error)
        if [[ "$_LOGGED" == error ]]; then
            # Fail-open: never drop a gate-miss record. Non-atomic append (a
            # sub-PIPE_BUF line append is atomic on POSIX), no dedup — a rare
            # duplicate beats a silently missed bypass.
            while read -r _ev _sha _extra; do
                printf '{"ts":"%s","event":"%s","gate":"post-commit","sha":"%s"%s}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ev" "$_sha" "$_extra" \
                    >> "$REPO_DIR/$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
            done <<< "$AUDIT_RECS"
            _LOGGED=logged
        fi
        [[ "$_LOGGED" == logged ]] \
            && echo "⚠️  Commit ${COMMIT_SHA:0:7} was not reviewed by litmus (PreToolUse gate did not fire)." >&2
    fi
fi

# Reset circuit breaker (block counter)
rm -f "$REPO_DIR/$STATE_DIR/.gate-block-count.local" 2>/dev/null || true

exit 0
