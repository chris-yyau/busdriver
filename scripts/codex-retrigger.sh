#!/usr/bin/env bash
# scripts/codex-retrigger.sh — one-shot-per-(PR,HEAD) `@codex review` re-trigger.
#
# WHY: Codex (`chatgpt-codex-connector`) only re-reviews a PR on a *push*. On a
# pr-grind WAIT-round where HEAD is unchanged (no fix to ship) and Codex is the
# SOLE stale ack blocker, no event makes Codex re-evaluate and emit a fresh clean
# signal: it posts COMMENTED reviews (0 reactions) rather than a Tier-F 👍, and
# its thread resolutions predate the last push (Tier-A.2 fails CLOSED, #186/#189).
# The ack ledger (scripts/ack-ledger.sh) therefore reads Codex `stale` forever,
# pr-grind exhausts `--max-wait`, and bails. Posting a manual `@codex review`
# re-triggers Codex (it re-reviews the current HEAD and emits a fresh 👍 → Tier-F
# ack, OR new findings → worker triages next round). This helper does that
# automatically, AT MOST ONCE per HEAD, so the gate becomes convergent instead of
# dead-ending. Same class of dead-end as PR #217's content-identity carry-forward
# (ack-freshness gating with no recovery path) — applied to Codex's reaction tier.
#
# SCOPE — this helper is pure MECHANISM. It posts the comment at most once per
# (PR, HEAD) and writes a marker. The POLICY (Codex is the sole stale blocker, the
# round is a wait-round, HEAD is unchanged, CI is green, no unresolved actionable
# threads) is evaluated by the CALLER (pr-grind dispatcher / worker) from its
# RESULT_* context; this script trusts the caller's decision to invoke and only
# guards against spam (one-shot marker) and operator opt-out.
#
# CONTRACT — fail-SAFE: a failed re-trigger must NEVER stale the gate.
#   Usage:  codex-retrigger.sh <pr-number> <head-sha> [owner/repo]
#   Exit 2 ONLY on missing required args (a wiring bug; surfaced by tests).
#   Exit 0 on every OPERATIONAL path — opt-out, bad input, marker present, gh
#   missing, post failure — so a caller that forgets `|| true` still cannot block
#   merge. Wired call sites SHOULD nevertheless append `|| true` for defence.
#   The marker is written ONLY after a CONFIRMED successful post, so a transient
#   `gh` failure is retried on the next wait-round (still bounded by `--max-wait`).
#
# Opt-out:  PR_GRIND_CODEX_RETRIGGER=0           (default ON; any non-"0" => on)
# Phrase:   PR_GRIND_CODEX_RETRIGGER_PHRASE      (default "@codex review"; for
#                                                 forks whose Codex connector uses
#                                                 a different trigger phrase)
# Marker:   ${BUSDRIVER_STATE_DIR:-.claude}/.pr-grind-codex-retriggered-pr<PR>-<HEAD8>.local
#           Per-(PR,HEAD) so concurrent grinds on different PRs never race on a
#           shared marker, and a new push (new HEAD) is eligible again. Gitignored
#           via `.claude/*.local`.
set -u

PR="${1:-}"
HEAD_SHA="${2:-}"
REPO="${3:-}"

if [ -z "$PR" ] || [ -z "$HEAD_SHA" ]; then
    echo "usage: codex-retrigger.sh <pr-number> <head-sha> [owner/repo]" >&2
    exit 2
fi

# Operator opt-out: default ON. Only the explicit value "0" disables it.
if [ "${PR_GRIND_CODEX_RETRIGGER:-1}" = "0" ]; then
    echo "ℹ️  codex-retrigger: disabled via PR_GRIND_CODEX_RETRIGGER=0; skipping." >&2
    exit 0
fi

# Sanitize inputs before any path / CLI use (argument-injection guard, consistent
# with ack-ledger.sh and augment-equiv-acks.sh). PR must be digits; HEAD must be
# hex, 7–64 chars (SHA-1 or SHA-256, short or full). Bad input is a benign skip
# (exit 0) — never stale the gate over a malformed signal.
case "$PR" in ''|*[!0-9]*) echo "ℹ️  codex-retrigger: non-numeric PR '$PR'; skipping." >&2; exit 0 ;; esac
case "$HEAD_SHA" in *[!0-9A-Fa-f]*) echo "ℹ️  codex-retrigger: non-hex HEAD '$HEAD_SHA'; skipping." >&2; exit 0 ;; esac
{ [ "${#HEAD_SHA}" -ge 7 ] && [ "${#HEAD_SHA}" -le 64 ]; } || {
    echo "ℹ️  codex-retrigger: HEAD length out of range (7–64); skipping." >&2; exit 0
}

HEAD8="${HEAD_SHA:0:8}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
MARKER="${STATE_DIR}/.pr-grind-codex-retriggered-pr${PR}-${HEAD8}.local"

# One-shot per (PR, HEAD), fast path: if we already re-triggered this exact HEAD
# this grind, do nothing (clear message; avoids a needless gh lookup). The atomic
# claim below is the authoritative race-safe gate — this is just the common case.
if [ -e "$MARKER" ]; then
    echo "ℹ️  codex-retrigger: already re-triggered PR #$PR @ $HEAD8 (marker present); skipping." >&2
    exit 0
fi

# No gh => cannot post. Skip safely BEFORE claiming the marker, so we never leave a
# claim that would block a later round where gh is available. `--max-wait` still
# bounds the wait (no new unbounded wait introduced).
command -v gh >/dev/null 2>&1 || {
    echo "ℹ️  codex-retrigger: gh not available; skipping (gate continues; --max-wait bounds the wait)." >&2
    exit 0
}

PHRASE="${PR_GRIND_CODEX_RETRIGGER_PHRASE:-@codex review}"
[ -n "$PHRASE" ] || PHRASE="@codex review"

# Atomic pre-claim — closes the check-then-post-then-write TOCTOU. Two concurrent
# grinds on the same (PR,HEAD) could both pass the fast-path check above and both
# post. `set -o noclobber` turns `: > "$MARKER"` into an O_CREAT|O_EXCL create the
# kernel grants to exactly ONE racer; the loser's redirect fails and it skips. We
# claim BEFORE posting, then RELEASE (rm) the claim if the post fails, so a later
# wait-round can retry — preserving the fail-SAFE retry semantics.
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Arm the release trap BEFORE the claim, so there is NO create→arm window in which a
# signal would exit (default action) and orphan the empty marker. Notes:
#  - The INT/TERM handler MUST exit — a bash signal handler that RETURNS resumes
#    execution after the interrupted command, which would release the claim and then
#    fall through to the post anyway (and let a concurrent run also claim+post).
#  - The EXIT handler covers normal early exits (e.g. the post-failure path's exit 0).
#  - Armed before the claim, the handler may `rm` a marker we do not yet own — but it
#    only ever runs `rm -f "$MARKER"` (idempotent, no error if absent), and the ONLY
#    way another run's marker exists here is the documented concurrent-same-PR
#    degenerate case (bounded: that run simply re-claims next round). On the
#    claim-FAILURE path below we DISARM first, so a normal "already claimed" skip
#    never deletes the owner's marker.
# All three are disarmed after a confirmed post (below), at which point the marker is
# the durable one-shot record. SIGKILL (kill -9) is the single uncoverable case —
# see ADR 0005 Known limitations; recover by removing the marker or pushing a commit.
trap 'rm -f "$MARKER" 2>/dev/null' EXIT
trap 'rm -f "$MARKER" 2>/dev/null; exit 130' INT TERM
if ! ( set -o noclobber; : > "$MARKER" ) 2>/dev/null; then
    trap - EXIT INT TERM   # not ours — disarm so we never delete the owner's marker
    echo "ℹ️  codex-retrigger: another run already claimed PR #$PR @ $HEAD8; skipping." >&2
    exit 0
fi
chmod 600 "$MARKER" 2>/dev/null || true

# Post once (we hold the claim). `-R owner/repo` is added only when a repo arg was
# supplied; otherwise gh infers the repo from the current working directory.
if [ -n "$REPO" ]; then
    gh pr comment "$PR" -R "$REPO" --body "$PHRASE" >/dev/null 2>&1
else
    gh pr comment "$PR" --body "$PHRASE" >/dev/null 2>&1
fi
post_rc=$?

if [ "$post_rc" -ne 0 ]; then
    # Fail-SAFE: the EXIT trap releases the claim so the NEXT wait-round retries the
    # post. Never propagate the failure — a failed re-trigger must not stale the gate.
    echo "⚠️  codex-retrigger: '$PHRASE' post failed (gh rc=$post_rc); released claim, will retry next wait-round." >&2
    exit 0
fi

# Confirmed posted: DISARM the release trap FIRST — before the (best-effort,
# non-fatal) forensic-content write — so an INT/TERM arriving during that write
# cannot remove a marker whose post already succeeded. The empty claimed marker
# already enforces the one-shot; the content is only forensic. Never block the gate
# over marker I/O.
trap - EXIT INT TERM
printf 'pr=%s head=%s phrase=%s\n' "$PR" "$HEAD_SHA" "$PHRASE" > "$MARKER" 2>/dev/null || true
echo "✅ codex-retrigger: posted '$PHRASE' on PR #$PR @ $HEAD8 (one-shot)." >&2
exit 0
