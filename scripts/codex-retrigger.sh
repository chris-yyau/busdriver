#!/usr/bin/env bash
# scripts/codex-retrigger.sh — bounded, paced `@codex review` re-trigger per (PR,HEAD).
#
# WHY: Codex (`chatgpt-codex-connector`) only re-reviews a PR on a *push*. On a
# pr-grind WAIT-round where HEAD is unchanged (no fix to ship) and Codex is the
# SOLE stale ack blocker, no event makes Codex re-evaluate and emit a fresh clean
# signal: it posts COMMENTED reviews (0 reactions) rather than a Tier-F 👍 or a
# Tier-G clean-verdict comment (#690), and
# its thread resolutions predate the last push (Tier-A.2 fails CLOSED, #186/#189).
# The ack ledger (scripts/ack-ledger.sh) therefore reads Codex `stale` forever,
# pr-grind exhausts `--max-wait`, and bails. Posting a manual `@codex review`
# re-triggers Codex (it re-reviews the current HEAD and emits a fresh 👍 → Tier-F
# ack, OR new findings → worker triages next round). This helper does that
# automatically, so the gate becomes convergent instead of dead-ending. Same class
# of dead-end as PR #217's content-identity carry-forward (ack-freshness gating
# with no recovery path) — applied to Codex's reaction tier.
#
# WHY BOUNDED-N RATHER THAN ONE-SHOT (#673). ADR 0005 shipped this as one-shot per
# (PR, HEAD) and named its rationale explicitly and only ANTI-SPAM ("prevents
# re-trigger spam across consecutive wait-rounds on one HEAD") — never a safety
# boundary. That made a single dropped or ignored nudge terminal for the whole PR,
# and #673 measured how much rides on it: after the FIRST fix round, the Codex ack
# tiers can no longer clear on their own. `ack-ledger.sh`'s outdated short-circuit
# (:500-508) fires forever once any Codex thread goes outdated, and its ALL-OR-STALE
# freshness proof (:558-594) is re-broken by every push, because a thread disposed
# in round N never gains a newer resolver comment afterwards. Both were reproduced
# against PR #670 and each is independently sufficient. So from round 2 onward a
# fresh CODEX-AUTHORED verdict on HEAD is the only exit, and this nudge is the only
# thing that asks for one — a single-use mechanism holding up a gate it is
# structurally required to clear. (#690 widened what counts as that verdict: a
# clean review can arrive as an issue COMMENT naming the reviewed SHA rather than
# as a 👍, and Tier G now reads it. That closed a dead-end the nudge could NOT
# solve — three landed nudges on PR #688 all answered in comment form — but it did
# not remove the need for the nudge, which is still what makes Codex re-review an
# unchanged HEAD at all.) It is now N attempts (default 3) spaced by a cooldown: still bounded, so
# ADR 0005's anti-spam intent holds, but a dropped nudge is recoverable without an
# operator. Set PR_GRIND_CODEX_RETRIGGER_MAX=1 to restore the exact old behavior.
#
# SCOPE — this helper is pure MECHANISM. It posts the comment at most N times per
# (PR, HEAD), paced, and writes a marker per attempt. The POLICY (Codex is the sole
# stale blocker, the round is a wait-round, HEAD is unchanged, CI is green, no
# unresolved actionable threads) is evaluated by the CALLER (pr-grind dispatcher /
# worker) from its RESULT_* context; this script trusts the caller's decision to
# invoke and only guards against spam (attempt budget + cooldown) and operator opt-out.
#
# CONTRACT — fail-SAFE: a failed re-trigger must NEVER stale the gate.
#   Usage:  codex-retrigger.sh <pr-number> <head-sha> [owner/repo]
#           codex-retrigger.sh --await-cooldown <pr-number> <head-sha> [wait-rounds-remaining]
#   Exit 2 ONLY on missing required args (a wiring bug; surfaced by tests).
#   Exit 0 on every OPERATIONAL path — opt-out, bad input, budget spent, cooling
#   down, gh missing, post failure — so a caller that forgets `|| true` still cannot
#   block merge. Wired call sites SHOULD nevertheless append `|| true` for defence.
#   A marker is written ONLY after a CONFIRMED successful post, so a transient
#   `gh` failure is retried on the next wait-round WITHOUT spending an attempt or
#   starting a cooldown (still bounded by `--max-wait`).
#   AMENDED (#677): that release is no longer unconditional. While a `gh pr comment`
#   call is IN FLIGHT — and through a successful one — the claim is KEPT rather than
#   freeing a slot whose nudge GitHub already accepted. Only a KNOWN non-zero rc
#   releases, so the retry semantics above are unchanged. See the trap block below.
#
#   --await-cooldown (#679) — optional leading flag. The dispatcher wait-round
#   loop calls `codex-retrigger.sh --await-cooldown <pr> <head> [wait-rounds-remaining]`
#   AFTER the post attempt, when further wait rounds remain (`MAX_WAIT - wait_round`).
#   That call never posts: if a marker is hot and remaining > 0 it SLEEPS out the
#   cooldown so the NEXT wait-round can spend attempt 2..N. Time pacing therefore
#   lives in the dispatcher loop (which can afford a multi-minute sleep), not in the
#   worker's Bash tool call (default tool ceiling ~120s < default COOLDOWN 180s).
#   A single await sleep is capped at AWAIT_SLEEP_CAP so it always fits the caller's
#   own Bash tool ceiling; a COOLDOWN longer than the cap is paid down across
#   successive wait-rounds rather than killed mid-sleep. See AWAIT_SLEEP_CAP below.
#   The ordinary post path (no flag) keeps skip-when-hot so the worker→dispatcher
#   mirror still dedupes. Hooks / `none`-path never pass the flag.
#
# Opt-out:  PR_GRIND_CODEX_RETRIGGER=0           (default ON; any non-"0" => on)
# Phrase:   PR_GRIND_CODEX_RETRIGGER_PHRASE      (default "@codex review"; for
#                                                 forks whose Codex connector uses
#                                                 a different trigger phrase)
#           NOT forwarded through the sanitized `env -i` hook invocations in
#           hooks/hooks.json, unlike MAX and COOLDOWN — so it governs direct
#           invocations only, not the pre-merge / pre-create hook paths. That
#           asymmetry is deliberate (PR #676). `env -i` is ADR 0016's (#325)
#           deny-by-default boundary and a committed `.claude/settings.json` `env`
#           block is repo-controlled, so every forwarded name is a value a hostile
#           repo picks. MAX and COOLDOWN are clamped to a range, bounding the damage
#           to a few extra nudges; PHRASE is UNCLAMPED and becomes the BODY of a
#           comment posted with the operator's `gh` credentials — and that body is
#           read by the AI reviewer whose ack gates the merge. Repo-controlled text →
#           operator credentials → an LLM reviewer's input is the shape this repo
#           refuses ("authenticate consent by location, not by content"). If a real
#           operator needs a different phrase on the hook paths, give it a `.local`
#           file, never an env var. Pinned by
#           `__tests__/codex-nudge-env-allowlist.test.ts` so re-adding it fails.
# Budget:   PR_GRIND_CODEX_RETRIGGER_MAX         (default 3; attempts per (PR,HEAD).
#                                                 1 restores ADR 0005 one-shot.)
# Pacing:   PR_GRIND_CODEX_RETRIGGER_COOLDOWN    (default 180s between attempts; 0
#                                                 disables pacing. Without pacing,
#                                                 consecutive wait-rounds seconds
#                                                 apart would burn the whole budget
#                                                 before Codex could plausibly answer
#                                                 — re-creating the dead end AND
#                                                 spamming the PR, losing on both
#                                                 axes at once.)
#           MAX is an integer in [1,10] (0 would be a second, silently-spelled off
#           switch competing with PR_GRIND_CODEX_RETRIGGER=0; the ceiling bounds the
#           slot-scan loop and the spam budget). COOLDOWN is an integer in [0,86400].
#           Anything outside those ranges falls back to the default — a malformed or
#           fat-fingered knob must never widen the budget OR stale the gate.
#
# COUPLING WITH THE DISPATCHER'S WAIT BUDGET (#673 / #676 / #679) — the two knobs
# above are NOT independent of the caller's `--max-wait`. Reachability has two
# halves, and both must hold:
#
#   (1) ROUND BUDGET — each attempt after the first needs a wait-round that can
#       host it. Shipped defaults must satisfy `MAX <= default --max-wait` so the
#       full attempt budget fits inside the round budget. Pinned by case 18.
#
#   (2) TIME PACING — COOLDOWN is genuine wait-time for Codex (~3 min observed).
#       Pre-#679 the helper only *skipped* while hot, so eight fast wait-rounds
#       could exhaust `--max-wait` before COOLDOWN elapsed and leave attempts 2..N
#       unreachable while case 18's old 480s typical still looked green. #679 closes
#       that by having the dispatcher call `--await-cooldown` with live remaining
#       wait rounds after each wait-round post attempt: while remaining > 0 and the
#       cooldown is hot, it SLEEPS so the next wait-round can spend. The ordinary
#       post path keeps skip-when-hot (mirror dedupe; no sleep inside the worker
#       Bash tool). Each await sleep is bounded by AWAIT_SLEEP_CAP so it fits the
#       caller's Bash tool ceiling; a COOLDOWN above the cap therefore needs
#       `ceil(COOLDOWN / AWAIT_SLEEP_CAP)` wait-rounds per attempt rather than one,
#       which is the coupling to re-check when raising the cooldown (ADR 0005
#       Revisit). Full-budget reachability still requires enough wait rounds left
#       when Codex becomes sole-stale — `MAX <= default --max-wait` is necessary for
#       the defaults when that happens early, not a guarantee after other bots have
#       already burned the wait budget.
#
# The shipped defaults remain MAX=3, COOLDOWN=180 (180s still meets or exceeds the
# observed Codex turnaround on PR #676). When Codex answers faster, ADR 0005 already
# settled the cost — Codex de-dupes, so an early re-nudge is one extra comment, never
# a correctness problem. A future change to MAX or to the dispatcher's default
# `--max-wait` must keep `MAX <= --max-wait`; see case 18 and ADR 0005's Revisit list.
# Markers:  ${BUSDRIVER_STATE_DIR:-.claude}/.pr-grind-codex-retriggered-pr<PR>-<HEAD8>.local
#           for attempt 1, and `...-<HEAD8>-<n>.local` for attempts n >= 2.
#           Attempt 1 deliberately keeps ADR 0005's exact filename, so a marker left
#           by an older plugin version reads as "attempt 1 already spent" rather than
#           silently granting a fresh budget, and `codex-retrigger-gc.sh`'s
#           `...-pr<PR>-*.local` prune glob already covers every slot unchanged.
#           Per-(PR,HEAD) so concurrent grinds on different PRs never race on a
#           shared marker, and a new push (new HEAD) is eligible again. Gitignored
#           via `.claude/*.local`.
#           ONE MARKER PER ATTEMPT, never a mutable counter: the claim below is an
#           O_CREAT|O_EXCL create, which the kernel grants to exactly one racer. A
#           count in a single rewritten file would need read-modify-write and would
#           race two concurrent grinds into a double-post (repo prior art: the
#           design-marker token directory).
set -u

AWAIT_COOLDOWN=0
if [ "${1:-}" = "--await-cooldown" ]; then
    AWAIT_COOLDOWN=1
    shift
fi

PR="${1:-}"
HEAD_SHA="${2:-}"
REPO_OR_REMAINING="${3:-}"
# Post path: arg3 is owner/repo. Await path: arg3 is wait-rounds-remaining.
if [ "$AWAIT_COOLDOWN" = 1 ]; then
    REPO=""
    WAIT_ROUNDS_REMAINING="$REPO_OR_REMAINING"
else
    REPO="$REPO_OR_REMAINING"
    WAIT_ROUNDS_REMAINING=""
fi

if [ -z "$PR" ] || [ -z "$HEAD_SHA" ]; then
    echo "usage: codex-retrigger.sh <pr-number> <head-sha> [owner/repo]" >&2
    echo "       codex-retrigger.sh --await-cooldown <pr-number> <head-sha> [wait-rounds-remaining]" >&2
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
MARKER_BASE="${STATE_DIR}/.pr-grind-codex-retriggered-pr${PR}-${HEAD8}"

# Attempt n's marker. n=1 keeps ADR 0005's exact filename (backward compatibility —
# see the Markers note in the header); n>=2 gets an `-n` slot suffix.
marker_for() {
    if [ "$1" = "1" ]; then printf '%s.local\n' "$MARKER_BASE"
    else printf '%s-%s.local\n' "$MARKER_BASE" "$1"; fi
}

# Read an integer knob ($1) against a default ($2) and an inclusive range [$3,$4],
# falling back to the default on ANY value outside it (empty, non-digit, too small,
# too large). Fail-SAFE in the spam direction: a typo'd budget must never widen it,
# and must never stale the gate by erroring out.
#
# The minimums differ on purpose. MAX floors at 1: zero attempts would be a second,
# silently-spelled off switch competing with PR_GRIND_CODEX_RETRIGGER=0. COOLDOWN
# floors at 0, because "no pacing" is a real operator choice (and the only way to
# exercise the budget without waiting out a real clock) — so 0 must survive the
# validator rather than being read as malformed and bounced to the default.
#
# The CEILINGS are load-bearing, not tidiness. MAX drives the slot-scan loop below,
# so an accidental `PR_GRIND_CODEX_RETRIGGER_MAX=999999999` (a plausible fat-finger,
# and perfectly "valid" as a positive integer) would run a billion filesystem probes
# on every wait-round and hang the merge gate — while also authorizing a nudge budget
# far past anything defensible as non-spam. 10 is already well beyond any useful
# number of nudges. COOLDOWN caps at a day for the same fat-finger reason; anything
# longer is indistinguishable from "never re-nudge", which the opt-out already spells.
read_int_knob() {
    case "$1" in ''|*[!0-9]*) printf '%s\n' "$2"; return ;; esac
    if [ "$1" -ge "$3" ] && [ "$1" -le "$4" ]; then printf '%s\n' "$1"
    else printf '%s\n' "$2"; fi
}
MAX_ATTEMPTS=$(read_int_knob "${PR_GRIND_CODEX_RETRIGGER_MAX:-}" 3 1 10)
COOLDOWN=$(read_int_knob "${PR_GRIND_CODEX_RETRIGGER_COOLDOWN:-}" 180 0 86400)

# Ceiling on a SINGLE `--await-cooldown` sleep. NOT an operator knob, deliberately:
# it is a property of the caller's runtime, not a preference. The dispatcher's await
# call is one Bash tool call, and that tool CAPS `timeout` at 600000ms
# (skills/litmus/SKILL.md). COOLDOWN accepts up to 86400s, so an unclamped
# `sleep $((COOLDOWN - age))` asks for a call the caller cannot legally issue: the
# tool kills it mid-sleep, the cooldown never clears, and attempts 2..N go
# unreachable — the very #679 defect this flag exists to close (cursor + Codex, PR
# #763). 480s keeps the required `sleep + 60s` timeout at 540s, matching the
# under-cap budget litmus already ships against the same 600s ceiling.
#
# Clamping the SLEEP rather than the KNOB is what preserves both halves: a long
# COOLDOWN stays a legitimate "nudge rarely" choice on the post path, while the await
# path pays it down ACROSS wait-rounds — each round sleeps at most the cap and exits,
# and the next round re-reads the marker age and continues. Lowering COOLDOWN's own
# ceiling to fit the tool would instead silently rewrite that operator choice.
AWAIT_SLEEP_CAP=480

# Scan the slots ONCE for the three things the decision needs: how many attempts are
# actually spent (occupancy), the LOWEST FREE slot to claim, and the NEWEST marker
# mtime to pace against.
#
# Occupancy + lowest-free, NOT highest-occupied+1. The difference is a HOLE — a slot
# whose failed post released its claim while a higher slot is occupied. That is
# reachable: a `gh pr comment` still in flight after the cooldown elapses lets a
# second run legitimately claim the next slot, and if the first post then fails and
# releases, slot n is free below an occupied n+1. Reading the highest occupied slot
# would count that hole as spent — which both silently shrinks the budget and makes
# this file's "a failed post spends no attempt" claim false (litmus MEDIUM, PR mode).
# Filling the lowest free slot instead makes the failed attempt genuinely retryable
# and keeps occupancy the single definition of "spent".
#
# GNU-first `stat`: on Linux `stat -f` is --file-system and prints block info to
# stdout (corrupting the value); `stat -c` is GNU's format flag, and BSD lacks -c so
# it falls through to -f. (Mirrors hooks/gate-scripts/post-merge-confirm-bypass.sh.)
# An unreadable mtime fails SAFE toward not posting, consistent with the never-spam
# posture — so it is recorded as a flag rather than silently skipped.
OCCUPIED=0
FIRST_FREE=0
NEWEST=0
MTIME_UNREADABLE=0
_n=1
while [ "$_n" -le "$MAX_ATTEMPTS" ]; do
    _f="$(marker_for "$_n")"
    if [ -e "$_f" ]; then
        OCCUPIED=$(( OCCUPIED + 1 ))
        _m=$(stat -c %Y "$_f" 2>/dev/null || stat -f %m "$_f" 2>/dev/null || echo "")
        case "$_m" in
            ''|*[!0-9]*) MTIME_UNREADABLE=1 ;;
            *) [ "$_m" -gt "$NEWEST" ] && NEWEST="$_m" ;;
        esac
    elif [ "$FIRST_FREE" -eq 0 ]; then
        FIRST_FREE="$_n"
    fi
    _n=$(( _n + 1 ))
done

if [ "$OCCUPIED" -ge "$MAX_ATTEMPTS" ] || [ "$FIRST_FREE" -eq 0 ]; then
    echo "ℹ️  codex-retrigger: attempt budget spent for PR #$PR @ $HEAD8 ($OCCUPIED/$MAX_ATTEMPTS); skipping." >&2
    exit 0
fi

# Pace the attempts. Without this, consecutive wait-rounds seconds apart would burn
# the whole budget before Codex could plausibly answer — restoring the #673 dead end
# AND spamming the PR, i.e. losing on both axes at once.
#
# #679 — two modes share this block:
#   post path (default): skip-when-hot (mirror dedupe; never sleep — worker Bash
#     tool ceiling ~120s is below default COOLDOWN 180s).
#   --await-cooldown: dispatcher-only; if remaining wait rounds > 0 and hot, SLEEP
#     out the cooldown then exit 0 without posting, so the next wait-round can spend.
if [ "$OCCUPIED" -ge 1 ] && [ "$COOLDOWN" -gt 0 ]; then
    _now=$(date +%s 2>/dev/null || echo "")
    if [ "$MTIME_UNREADABLE" = "1" ] || [ -z "$_now" ] || [ "$NEWEST" -eq 0 ]; then
        echo "ℹ️  codex-retrigger: cannot read attempt mtimes for PR #$PR @ $HEAD8; skipping (fail-safe: no post)." >&2
        exit 0
    fi
    _age=$(( _now - NEWEST ))
    # Clock rollback / future-dated marker → negative age. Clamp so `_need` cannot
    # exceed COOLDOWN and stall the grinder for an unbounded sleep (#679 litmus).
    [ "$_age" -lt 0 ] && _age=0
    if [ "$_age" -lt "$COOLDOWN" ]; then
        _need=$(( COOLDOWN - _age ))
        if [ "$AWAIT_COOLDOWN" = 1 ]; then
            case "$WAIT_ROUNDS_REMAINING" in
                ''|*[!0-9]*)
                    echo "ℹ️  codex-retrigger: await-cooldown: missing/non-digit wait-rounds-remaining for PR #$PR @ $HEAD8; not pacing." >&2
                    exit 0
                    ;;
            esac
            # `00` / `000` are digits but mean zero — require a numeric positive
            # via arithmetic, not a textual `0` pattern alone (#679 litmus).
            if [ "$WAIT_ROUNDS_REMAINING" -eq 0 ]; then
                echo "ℹ️  codex-retrigger: await-cooldown: no wait rounds remaining for PR #$PR @ $HEAD8; not pacing." >&2
                exit 0
            fi
            # Never ask for a sleep the caller's Bash tool cannot host (see
            # AWAIT_SLEEP_CAP). A longer remainder is paid down across wait-rounds
            # instead of being killed mid-call.
            _sleep="$_need"
            if [ "$_sleep" -gt "$AWAIT_SLEEP_CAP" ]; then
                _sleep="$AWAIT_SLEEP_CAP"
                echo "ℹ️  codex-retrigger: await-cooldown: pacing ${_sleep}s of ${_need}s remaining (per-round cap ${AWAIT_SLEEP_CAP}s, COOLDOWN=${COOLDOWN}s) for PR #$PR @ $HEAD8 (wait-rounds-remaining=$WAIT_ROUNDS_REMAINING); cooldown still hot, next wait-round continues." >&2
            else
                echo "ℹ️  codex-retrigger: await-cooldown: pacing ${_sleep}s of ${COOLDOWN}s for PR #$PR @ $HEAD8 (wait-rounds-remaining=$WAIT_ROUNDS_REMAINING)." >&2
            fi
            sleep "$_sleep" || {
                echo "ℹ️  codex-retrigger: await-cooldown sleep failed for PR #$PR @ $HEAD8; skipping (fail-safe)." >&2
                exit 0
            }
            exit 0
        fi
        echo "ℹ️  codex-retrigger: attempt $OCCUPIED/$MAX_ATTEMPTS posted ${_age}s ago for PR #$PR @ $HEAD8; cooling down (${COOLDOWN}s); skipping." >&2
        exit 0
    fi
fi

# --await-cooldown with a cool marker (or no markers / budget spent above): done.
if [ "$AWAIT_COOLDOWN" = 1 ]; then
    echo "ℹ️  codex-retrigger: await-cooldown: cooldown clear for PR #$PR @ $HEAD8; nothing to pace." >&2
    exit 0
fi

ATTEMPT=$(( OCCUPIED + 1 ))          # ordinal for messages: this is the Nth nudge
MARKER="$(marker_for "$FIRST_FREE")"  # slot to claim: lowest free, so holes refill

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
# grinds on the same (PR,HEAD) could both compute the same next ATTEMPT from the slot
# scan above and both post. `set -o noclobber` turns `: > "$MARKER"` into an
# O_CREAT|O_EXCL create the kernel grants to exactly ONE racer; the loser's redirect
# fails and it skips (it does NOT fall forward to the next slot). We claim BEFORE
# posting, then RELEASE (rm) the claim if the post fails, so a later wait-round can
# retry — preserving the fail-SAFE retry semantics. Releasing also means a failed post
# spends NO attempt and starts NO cooldown: the slot scan re-derives the same ATTEMPT
# next round, which is why the scan claims the LOWEST FREE slot rather than
# highest-occupied+1 — a released slot below an occupied one must be refillable.
#
# BE PRECISE ABOUT WHAT THIS GUARANTEES, because the one-shot version guaranteed more.
# O_EXCL only makes each SLOT single-use; it does NOT serialize the slot scan. A racer
# arriving after another has claimed slot n — but before that one finished posting —
# reads slot n as spent and legitimately proceeds to slot n+1. What actually prevents
# that is the COOLDOWN: the newly-created marker is seconds old, so the check above
# turns the second racer away. Pacing is therefore the concurrency guard here, not a
# convenience.
# RESIDUAL, accepted and bounded: with COOLDOWN=0 that protection is gone by
# construction, and concurrent grinds on one (PR,HEAD) can spend several slots at once.
# The blast radius is at most MAX_ATTEMPTS duplicate `@codex review` comments (never
# unbounded, since the slots themselves are finite and MAX is ceiling-clamped above),
# and a duplicate nudge is idempotent to Codex. COOLDOWN=0 exists for tests and
# single-runner setups; do not set it on a repo where two grinds can race.
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
# the durable record that this attempt was spent.
#
# #677 — RELEASE ONLY WHILE THE OUTCOME IS KNOWN. Unconditional release was correct
# only up to the moment `gh pr comment` is invoked. From then until its rc is read the
# outcome is INDETERMINATE: GitHub may already have accepted the comment. A signal in
# that window used to free the slot for a nudge that HAD landed, so the next round
# re-posted it. `POST_OUTCOME_UNKNOWN` gates the release on that window: it is raised
# immediately before each `gh` invocation, stays raised through a SUCCESSFUL post (the
# success path then disarms the traps outright), and is cleared only on a KNOWN
# non-zero rc. So a signal while a call is in flight keeps the claim, while every other
# exit releases it as before: pre-attempt (a claim with no post behind it must not
# spend an attempt), between the two bounded retries, and after a known failure. That trades a possibly-wasted attempt out of
# MAX_ATTEMPTS for a possibly-duplicated comment — the right direction since the budget
# is 3 (#673), and a duplicate `@codex review` is idempotent (ADR 0005 Consequences).
# The retained marker is empty (the forensic write never ran) — the same residue shape
# as the SIGKILL case, which the slot scan (existence + mtime) and the GC glob already
# tolerate.
#
# SIGKILL (kill -9) is the single
# uncoverable case — see ADR 0005 Known limitations; it now costs one attempt out of
# MAX_ATTEMPTS rather than the PR's only nudge (#673), so a later round still recovers
# on its own. Recover immediately by removing the marker or pushing a commit.
POST_OUTCOME_UNKNOWN=0
trap '[ "$POST_OUTCOME_UNKNOWN" = 1 ] || rm -f "$MARKER" 2>/dev/null' EXIT
trap '[ "$POST_OUTCOME_UNKNOWN" = 1 ] || rm -f "$MARKER" 2>/dev/null; exit 130' INT TERM
if ! ( set -o noclobber; : > "$MARKER" ) 2>/dev/null; then
    trap - EXIT INT TERM   # not ours — disarm so we never delete the owner's marker
    echo "ℹ️  codex-retrigger: another run already claimed attempt $ATTEMPT for PR #$PR @ $HEAD8; skipping." >&2
    exit 0
fi
chmod 600 "$MARKER" 2>/dev/null || true

# Post (we hold the claim). `-R owner/repo` is added only when a repo arg was
# supplied; otherwise gh infers the repo from the current working directory.
# Bounded in-process retry (2 attempts, brief backoff) before the fail-safe release:
# on an inline/admin merge the PreToolUse hook is the SOLE delivery path — there is no
# "next wait-round" behind it — so a single transient here would silently drop the
# nudge with no retry (issue #398). The per-(PR,HEAD) claim dedups across separate
# invocations; a within-call retry can at worst re-post once on a false-negative
# transient — the same bounded trade the cross-round retry already makes, and a
# duplicate `@codex review` is harmless (idempotent nudge).
# (`_try` is the within-call transport retry — distinct from $ATTEMPT, the
# across-round nudge budget. Two different loops; do not conflate them.)
#
# The argv is built ONCE, before the loop, so that nothing at all sits between
# raising POST_OUTCOME_UNKNOWN and the `gh` invocation it describes (#677, Codex
# P2 on PR #739). With the `-R` branch inline in the loop the flag was raised two
# commands early, and a signal in that gap left an empty marker for a post that
# had never started — spending an attempt, and under
# PR_GRIND_CODEX_RETRIGGER_MAX=1 suppressing the nudge for that HEAD entirely.
GH_ARGS=(pr comment "$PR" --body "$PHRASE")
[ -n "$REPO" ] && GH_ARGS=(pr comment "$PR" -R "$REPO" --body "$PHRASE")

post_rc=0
for _try in 1 2; do
    # #677 — the two POST_OUTCOME_UNKNOWN transitions, stated separately because they
    # are NOT symmetric:
    #   raised  → immediately before `gh`, and stays raised through a SUCCESSFUL post;
    #             the success path below disarms the traps outright, which is what makes
    #             a landed nudge durable.
    #   cleared → only on a KNOWN non-zero rc. So neither the success test nor the
    #             backoff between tries is covered: try 1's non-zero rc is a known
    #             failure, and a signal after it releases exactly as a signal before the
    #             loop would (fail-SAFE: a failed post spends no attempt).
    # Each transition leaves ONE command boundary that cannot be closed in shell — a
    # bash trap fires only BETWEEN commands, and neither "invoke" nor "read $? and act
    # on it" is atomic. They are now one command wide each, which is the minimum:
    #   raise→invoke  (flag up, nothing posted)  — costs one attempt of MAX_ATTEMPTS
    #   read→clear    (flag up, known failed)    — costs one attempt of MAX_ATTEMPTS
    # Both are recoverable on a later round; the alternative on either side is
    # re-posting a nudge GitHub may already have accepted.
    POST_OUTCOME_UNKNOWN=1
    gh "${GH_ARGS[@]}" >/dev/null 2>&1
    post_rc=$?
    [ "$post_rc" -eq 0 ] || POST_OUTCOME_UNKNOWN=0
    [ "$post_rc" -eq 0 ] && break
    [ "$_try" -lt 2 ] && sleep 1
done

if [ "$post_rc" -ne 0 ]; then
    # POST_OUTCOME_UNKNOWN is already 0 here — the loop clears it as each rc is read.
    # Fail-SAFE: after the bounded retries still failed, the EXIT trap releases the
    # claim so the NEXT wait-round (if any) retries. Never propagate the failure — a
    # failed re-trigger must not stale the gate.
    echo "⚠️  codex-retrigger: '$PHRASE' post failed after 2 attempts (gh rc=$post_rc); released claim, will retry next wait-round." >&2
    exit 0
fi

# Confirmed posted: DISARM the release trap FIRST — before the (best-effort,
# non-fatal) forensic-content write — so an INT/TERM arriving during that write
# cannot remove a marker whose post already succeeded. The empty claimed marker
# already spends the attempt; the content is only forensic. Never block the gate
# over marker I/O. (The write also re-stamps mtime, which is the cooldown anchor for
# the NEXT attempt — a wholly benign few-millisecond shift from the claim.)
trap - EXIT INT TERM
printf 'pr=%s head=%s phrase=%s attempt=%s/%s\n' "$PR" "$HEAD_SHA" "$PHRASE" "$ATTEMPT" "$MAX_ATTEMPTS" > "$MARKER" 2>/dev/null || true
echo "✅ codex-retrigger: posted '$PHRASE' on PR #$PR @ $HEAD8 (attempt $ATTEMPT/$MAX_ATTEMPTS)." >&2
exit 0
