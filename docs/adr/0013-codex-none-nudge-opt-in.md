# ADR 0013 — Opt-in one-shot Codex nudge when Codex never auto-triggers (`none`)

## Status

Accepted (2026-07-09). **Revised 2026-07-11** — history AUTO-DETECTION of
Codex-active repos replaces the opt-in file as the DEFAULT nudge trigger; the file
demotes to a force-on cold-start override. This is a deliberate default-policy
inversion (see **Revision (2026-07-11)** below), not a clarification. Issues #320
(auto-detect + missing-Codex warning), #327 (retrigger-marker GC).

## Context

ADR 0005 added `scripts/codex-retrigger.sh`: a one-shot-per-(PR,HEAD) `@codex
review` re-trigger that breaks the Codex-`stale`-on-unchanged-HEAD wait-round
dead-end. It fires **only** when Codex is `stale` — engaged on an older SHA and
didn't re-ack HEAD after a push — AND is the sole ack blocker on a wait-round. It
does **not** fire when Codex is `none`: Codex never engaged on the PR at all.

Observed on PR #297 (2026-07-08): the GitHub Codex bot (`chatgpt-codex-connector`)
and Cursor Bugbot — both of which normally auto-review every PR on this repo —
silently produced no review on either commit (no check, no review, no comment).
`cubic` on the same PR explicitly posted "monthly review limit reached." The likely
shared cause is **usage-quota exhaustion** for the billing cycle; a dropped
auto-review webhook is the other possibility. Either way, a `none` Codex is
non-gating today, so pr-grind proceeds without a Codex-bot review.

The existing **Codex first-engagement grace** (COMPLETION block, `skills/pr-grind/
SKILL.md`) already handles the `none` case with a *bounded re-poll* that *falls
through to non-gating `none`* — but it never **nudges**. So a repo that expects
Codex to review, where Codex silently no-ops on a fresh PR, converges and merges
without ever asking Codex to look.

## Why a blanket "nudge on `none`" is wrong

- `none` legitimately means "Codex does not operate on this PR" and is correctly
  non-gating today. Nudging **every** `none` would force `@codex review` onto every
  PR on every repo — including repos where Codex is not meant to review —
  converting a non-gating signal into a gating wait that can hang.
- `stale` is safe to retrigger because it PROVES Codex is installed and reviewing
  this PR. `none` proves nothing — not-installed, quota-exhausted, and
  dropped-webhook are indistinguishable from the GitHub API.
- **A nudge cannot cure quota exhaustion.** Posting `@codex review` to a
  quota-exhausted bot silently no-ops; if pr-grind then *waited* for the review it
  would burn its budget and bail. The nudge only helps the "webhook dropped, quota
  available" case — so it MUST degrade gracefully in every other case.

## Decision

Add an **opt-in, one-shot, bounded** `@codex review` nudge for the `none` case,
gated on a per-repo opt-in file and delegated to the existing ADR 0005 mechanism.

**Policy wrapper (`scripts/codex-nudge-if-expected.sh`, new):** checks for the
per-repo opt-in file `<main-repo-root>/.claude/pr-grind-codex-expected.local`
(gitignored, same pattern as `pr-grind-auto-admin-solo.local`; resolved at the MAIN
repo root because worktree `.local` files are not copied into worktrees). ABSENT →
no-op, exit 0 (today's behavior: a `none` Codex is never nudged). PRESENT →
delegate to `codex-retrigger.sh`, which owns the one-shot marker, fail-safe post,
global opt-out (`PR_GRIND_CODEX_RETRIGGER=0`), and phrase override. This preserves
ADR 0005's split: the helper is pure MECHANISM; the opt-in is caller POLICY.

**Call site (`skills/pr-grind/SKILL.md`, COMPLETION first-engagement grace):**
invoke the wrapper ONCE, inside the existing `CODEX_DONE == none && CODEX_GRACE > 0`
branch, **before** the bounded re-poll (`sleep` + refresh). COMPLETION is reached
only post-convergence (CI green, all registered bots acked, all threads resolved),
so the nudge fires **after CI has settled** — it never races normal auto-trigger
latency. The existing bounded re-poll then observes the result; if Codex still does
not engage within the grace, the block falls through to non-gating `none` exactly as
before. `|| true` at the call site keeps a failed nudge from ever staling the gate.
The call runs in a subshell that `cd`s into `$WORKTREE_DIR` first — identical to the
LOOP's stale-retrigger call site — so (a) the wrapper's CWD-derived opt-in root is
the PR's own repo, not a drifted checkout's (per-repo consent), and (b) the delegated
codex-retrigger marker lands in the same worktree `.claude/` the stale path uses,
preserving the single shared one-shot marker.

**Shared one-shot marker.** The wrapper delegates to `codex-retrigger.sh` with no
new marker, so the `none` and `stale` paths share the same per-(PR,HEAD) marker:
**at most one `@codex review` is posted per HEAD across both paths combined.**

## Guards / safety

- **Opt-in required.** Absent the file, behavior is byte-for-byte today's — a
  `none` Codex is never nudged. No repo is forced into Codex review.
- **Bounded, never hangs.** The nudge reuses the *existing* bounded grace re-poll;
  it adds no new wait. Quota-exhausted / uninstalled / still-silent Codex all
  degrade to non-gating `none` — the merge is never blocked waiting for a review
  that will not arrive. (An opt-in operator who wants the nudge to have more time to
  land raises `PR_GRIND_CODEX_GRACE_SECS`, default 480 — see the revision below.)

  **Revision 2026-07-19 (#420) — the grace was ~15x too short.** The default was a
  single blind `sleep 20`. Measured `@codex review` → Codex-review latency on this
  repo: 3m37s (#412), 4m58s (#419), 6m36s (#409), 7m27s (#390). The re-poll therefore
  always observed `none` and fell through, merging *seconds* before the review landed
  — #419 merged 5s after its own nudge and the review arrived 5min later, on a closed
  PR. The blind sleep is now a **bounded poll**: deadline `PR_GRIND_CODEX_GRACE_SECS`
  (default 480s) polled every `PR_GRIND_CODEX_POLL_SECS` (default 30s), breaking the
  instant Codex engages. A fast Codex now costs ~30s instead of 20s-and-a-miss; a slow
  one is actually caught. `=0` still disables the wait; still never an unbounded hang.
  This is precisely the action ADR 0002's own revisit trigger prescribed for this
  symptom ("raise the default `PR_GRIND_CODEX_GRACE_SECS`").

  **Not changed:** the `codex-nudge-premerge.sh` hook still posts and exits 0 with no
  wait. It is non-gating by contract (ADR 0013 / the hook header) and a PreToolUse
  hook must not block a merge for minutes. It remains the backstop for merge paths
  that skip pr-grind entirely — on those, the review genuinely lands post-merge.
- **One nudge per (PR, HEAD), logged.** Enforced by the shared codex-retrigger
  marker; codex-retrigger logs the post to stderr (`✅ codex-retrigger: posted …`).
- **Merge authority unchanged.** Required status checks + litmus still gate. The
  nudge only creates the *opportunity* for a fresh Codex signal; if Codex engages
  and finds real issues, FRESH_ACKS reads `stale` and the merge correctly blocks —
  that is the desired outcome, not a regression.
- **Fail-safe.** The wrapper exits 0 on every operational path (not opted in, bad
  args → except missing-args exit 2, a wiring bug; delegate skip/fail). A failed
  nudge never stales the gate.
- **Global kill switch still wins.** `PR_GRIND_CODEX_RETRIGGER=0` disables both the
  `stale` retrigger and the `none` nudge (the wrapper delegates through it).

## Alternatives

- **Extend `codex-retrigger.sh` itself to accept the `none`+opt-in path.** Rejected:
  it would push repo-level POLICY (the opt-in) into the pure-MECHANISM helper,
  breaking ADR 0005's split and coupling the `stale` path to the opt-in file. A thin
  wrapper keeps the helper unchanged and independently tested.
- **Nudge on `none` during the LOOP (like the `stale` retrigger).** Rejected: on a
  repo with registered bots the loop waits on those bots, not on Codex; `none` Codex
  is non-gating there. The only place a `none`-only Codex (e.g. a Codex-only repo)
  needs handling is COMPLETION, where the first-engagement grace already lives. The
  issue also requires firing "after CI settles" — COMPLETION is exactly that point.
- **Longer / looping re-poll after the nudge.** ~~Rejected as default: an unbounded or
  multi-round wait for a possibly-quota-dead bot is the hang the design forbids. The
  single bounded grace + `PR_GRIND_CODEX_GRACE_SECS` knob covers operators who want
  a longer window.~~
  **SUPERSEDED 2026-07-19 (#420) — this alternative was adopted.** The rejection
  conflated *looping* with *unbounded*; the objection was always to the hang, not the
  loop. A poll on a fixed deadline (480s, 30s interval, early-exit on engagement, each
  sleep clamped to the remaining time) is strictly MORE bounded than what it replaced,
  because it also caps the case the single sleep handled worst — Codex answering at
  4min against a 20s window. The quota-dead bot still falls through non-gating at the
  deadline. Rejecting the loop as default is what left the 20s default in place and
  produced the merges in the revision above. The "operators who want a longer window
  can raise the knob" clause was the load-bearing error: nobody raises a knob whose
  default silently misses, and the default is what every repo actually runs.
- **Generalize to other auto-advisory bots (Cursor Bugbot `bugbot run`) now.**
  Deferred: Codex already has the retrigger machinery and the observed failure. The
  opt-in + bounded-fallback contract generalizes cleanly if a second bot warrants it
  (revisit trigger below).

## Consequences

- A repo that opts in and whose Codex silently didn't auto-trigger now gets exactly
  one `@codex review` at COMPLETION; if quota/webhook allows, Codex reviews and the
  bounded grace picks up its ack (or findings). Otherwise the PR still converges to
  non-gating `none` — no behavior change from today for the degraded cases.
- No repo without the opt-in file sees any change.
- New per-repo opt-in file `.claude/pr-grind-codex-expected.local` (gitignored).
- Covered by `tests/test-codex-nudge-if-expected.sh` (7 cases, `gh` stubbed):
  not-opted-in no-op, opted-in one post + marker, one-shot through the shared marker,
  global opt-out pass-through, fail-safe (post failure → exit 0, no marker),
  unresolvable-main-root fail-safe (no CWD-relative fallback → no nudge), and usage
  error. `codex-retrigger.sh` itself remains covered by `tests/test-codex-retrigger.sh`.

## Revisit trigger

- ~~A repo reports nudge-comment noise → tighten (e.g. require the opt-in AND a prior
  successful Codex review on the repo before nudging) or lengthen the one-shot scope.~~
  **Superseded/reframed by the 2026-07-11 revision:** the revision reuses this trigger's
  *prior-review signal* but WIDENS rather than tightens — it drops the opt-in requirement
  and makes history auto-detection the default trigger. If auto-detect ever causes
  nudge-comment noise, tighten it (raise the window bar, or require ≥K recent
  reviews/reactions, not just ≥1).
- A second auto-advisory bot (Cursor Bugbot, etc.) exhibits the same silent-`none`
  failure → generalize the wrapper to a bot+phrase table under the same opt-in +
  bounded-fallback contract.
- Codex gains a reliable first-engagement signal that the grace can wait on
  deterministically → reassess whether the nudge is still needed.

## Revision (2026-07-11) — auto-detect replaces the opt-in file as the default trigger

**Context.** The opt-in file `pr-grind-codex-expected.local` was trivial to never set,
which silently no-ops the whole nudge (issue #320, observed on PR #319: Codex normally
reviews this repo but silently didn't auto-trigger, and the PR merged with no signal that
a normally-participating reviewer was absent).

**Decision.**
- **Default trigger inverts** from the opt-in file to **history auto-detection**: a new
  detector `scripts/codex-active-repo.sh <owner/repo>` makes ONE bounded GraphQL call over
  the last `PR_GRIND_CODEX_ACTIVE_WINDOW` (default 10, clamped 1..100) recently-updated
  CLOSED-or-MERGED PRs and returns ACTIVE iff Codex authored any review OR left any
  reaction. Reviews AND reactions because a CLEAN Codex leaves only a Tier-F 👍 reaction
  and posts NO review (ADR 0002 / `ack-ledger.sh:291`) — reviews-only would miss exactly
  the healthy repos. Logins are matched bare OR `[bot]`-suffixed (mirrors
  `ack-ledger.sh:292,312-314`). Fail-SAFE → inactive with a stderr diagnostic on any
  gh/jq/query failure; the kill switch `PR_GRIND_CODEX_RETRIGGER=0` short-circuits it with
  no network call.
- **The opt-in file demotes to a force-ON cold-start override** — still honored (a new repo
  where Codex is expected but has no history yet), but no longer the sole enabler. There is
  **no** force-off marker; the off switch remains `PR_GRIND_CODEX_RETRIGGER=0`.
- **The active bit is passed POSITIONALLY** into `codex-nudge-if-expected.sh` (arg #4), never
  as an env var — an env signal is injectable by a committed `.claude/settings.json` env
  block, the exact #325 / ADR 0016 gate-env threat, and this is a force-nudge signal.
- **Missing-Codex warning (#320 secondary ask):** at COMPLETION, if a historically-active
  Codex is still `none` after the bounded grace, pr-grind prints a non-gating `⚠️` warning
  ("…has engaged on recent PRs… but did not engage on this PR…") instead of merging
  silently. History-keyed on the detector result (already forced to 0 by the kill switch),
  so a force-on cold-start repo with no history correctly gets no warning, and "engaged"
  (not "reviewed") reflects the reaction-inclusive signal. Detection is decoupled from the
  grace branch, so `PR_GRIND_CODEX_GRACE_SECS=0` still disables the wait+nudge but leaves
  the warning intact.
- **Retrigger-marker GC (bundles #327):** because auto-detect fires the nudge on more PRs,
  it writes more of codex-retrigger's per-(PR,HEAD) idempotency markers. `scripts/codex-
  retrigger-gc.sh <pr>` prunes a merged PR's markers, resolving the state dir the SAME
  CWD-relative way `codex-retrigger.sh:69` writes it (a TRUE mirror, NOT MAIN_ROOT-anchored)
  and invoked from `$WORKTREE_DIR` after `MERGE_STATE==MERGED` in BOTH pr-grind merge blocks
  (the auto-admin block removes no worktree, so a MAIN_ROOT-anchored GC would have leaked
  there). See ADR 0005 Known-limitations.

**Consequences (superseding the original).**
- The original Consequence "No repo without the opt-in file sees any change" is **RETIRED** —
  a repo with recent Codex reviews/reactions now gets one `none`-nudge + a possible warning
  with no file. Likewise the Guard "Absent the file, behavior is byte-for-byte today's" holds
  only for repos with NO Codex history (or with the kill switch set) and on detection failure.
- The bounded/never-hangs, non-gating-merge, one-shot-per-HEAD, and global-kill-switch
  properties are all UNCHANGED. Merge authority is unchanged.
- New coverage: `tests/test-codex-active-repo.sh`, `tests/test-codex-retrigger-gc.sh`,
  `tests/test-pr-grind-codex-wiring.sh`; `tests/test-codex-nudge-if-expected.sh` extended for
  the force-on/auto-detect/kill-switch matrix. All three new tests added to
  `.github/workflows/tests.yml` (explicit list, not glob discovery).
- **False-positive ceiling:** a repo that drops Codex may still auto-nudge until the last N
  closed/merged PRs no longer include a Codex review/reaction, then self-corrects. Bounded
  and kill-switchable. Reaction-content filtering (👀 vs 👍) is deferred — any connector
  reaction proves activity.

---

## Revision 2026-07-14 — deterministic PreToolUse backstop (the nudge was prose)

**Context.** The auto-detect nudge above still lived ONLY as an agent-executed bash
block in `skills/pr-grind/SKILL.md`'s COMPLETION section. That block runs only if the
grinding agent executes it verbatim, from the right CWD, with `CLAUDE_PLUGIN_ROOT` set.
The one deterministic enforcement — `pre-merge-gate.sh` — checks a pr-grind-clean marker
+ green CI and NEVER verifies the nudge ran. So the nudge silently no-opped on every
merge path that reaches "clean" without that block: the gate's **bootstrap-merge bypass**
(gate-modifying PRs, e.g. #336), skip-pr-grind bypasses, worktree `--admin` squashes, and
any run where the agent shortcut to the marker. Verified empirically: of PRs #335–#342,
only #335 (normally ground, no gate-infra changes) got a nudge; the gate-refactor and
ultra-oracle merges got none, despite `codex-active-repo.sh` reporting the repo active.

**Decision.** Fire the nudge from a NON-GATING PreToolUse hook on the merge command —
`hooks/gate-scripts/codex-nudge-premerge.sh` — the one deterministic point that is
post-CI-settle AND pre-merge. It reuses the whole existing chain
(`codex-active-repo.sh` → `codex-nudge-if-expected.sh` → `codex-retrigger.sh`) and adds
only (1) the deterministic firing point and (2) the `none`-GUARD the wrapper lacks (a
fully-paginated single-PR REST check of reviews + reactions: nudge ONLY when Codex has
zero engagement on the PR, so we never re-poke an already-engaged Codex on every merge).

**Why a separate hook, not folding into `pre-merge-gate.sh`.** The gate is fail-CLOSED and
security-critical; adding a network side-effect (a review-request comment) to it raises its
blast radius. The nudge hook is purely additive and **can never block a merge** — it emits
nothing to stdout and always exits 0. FAIL-SAFE = SKIP (the inverse of the gates): on any
parse/query error it exits 0 WITHOUT posting, so it never spams a spurious `@codex review`
on an unresolved PR/repo.

**Consequences.**
- The SKILL COMPLETION nudge block is UNCHANGED and now redundant-but-harmless: both paths
  share `codex-retrigger.sh`'s per-(PR,HEAD) one-shot marker, so at most one `@codex review`
  per HEAD fires across the prose path AND the hook. On the paths the prose misses, the hook
  is now the sole (and reliable) trigger.
- Runs under `lib/sanitized-gate.sh` (ADR 0016 env containment) like the gates. Kill switch
  `PR_GRIND_CODEX_RETRIGGER=0` short-circuits it before any network work. Rather than
  reconstruct gh's repo/PR/host resolution from the command string, the hook fires ONLY when
  the merge provably targets THIS repo: (a) the scoped parser SKIPS any per-command override
  it can't neutralize — a `-R`/`--repo` flag (global or after `merge`), an inline
  `GH_REPO=`/`GH_HOST=` assignment, or a non-numeric positional (branch / PR URL); and (b) it
  DELEGATES resolution to gh (`gh pr view [<num>] --json number,headRefOid,url`) in the
  merge's cwd + env, then REQUIRES the resolved `host/owner/repo` to EQUAL the cwd repo's
  `origin` (github.com only). Any divergence — a cross-repo/cross-host URL — fails the
  equality check and skips; a `GH_REPO=`/`GH_HOST=` assignment anywhere in the command is
  rejected by (a).

  **Revision 2026-07-19 (#416).** Those two vars were previously re-imported through the
  `env -i` line to be DETECTED (set ⇒ skip). That made the hook the one registration in
  `hooks/hooks.json` importing repo-controlled env beyond `PATH`/`HOME`/`CLAUDE_PLUGIN_ROOT`
  — and `GH_HOST` in particular steers a CREDENTIALED outbound `gh` request to an arbitrary
  host, since a committed `.claude/settings.json` `env` block is repo-injectable (ADR 0016).
  Detection is not worth that surface for a non-gating nudge. `GH_REPO`, `GH_HOST`, and
  `BUSDRIVER_STATE_DIR` (which misdirected the delegate's one-shot dedup marker, and which
  the hook's force-on lookup already ignored in favour of a hardcoded `.claude`) are no
  longer imported; the hook instead **pins** `GH_HOST=github.com` and clears `GH_REPO` at the
  top, so no repo-controlled value reaches any `gh` invocation. Only
  `PR_GRIND_CODEX_RETRIGGER` — the documented kill switch, which can only DISABLE — remains.
  Residual, accepted: the merge shell may still carry an inherited `GH_REPO` the hook can no
  longer see, so a merge landing on repo B can earn a nudge on the cwd repo's own PR. That is
  a possibly-wrong-PR comment inside a repo already trusted enough to run agents in — bounded
  by the per-(PR,HEAD) dedup and by the hook being non-gating — traded for the guarantee that
  the outbound write is never re-routed. Regression: `tests/test-codex-nudge-premerge.sh`
  cases 12 / 12b.

  Because the fire path is gated on target == cwd
  repo, the force-on marker (checked at the delegate's exact location — the git-common-dir
  main root under `.claude`, valid from a linked worktree) and the delegate's one-shot dedup
  marker are always the target repo's own — repo A's consent never nudges repo B.
  `PR_GRIND_CODEX_RETRIGGER`/`BUSDRIVER_STATE_DIR` are likewise re-imported (a disabled nudge
  is not a merge/review bypass, so it is safe, unlike the gates). Finally, the hook fires ONLY
  on the tightest CANONICAL shape — a SINGLE `gh pr merge`, optionally prefixed by a bare `cd`
  joined with `&&` (the only form `gh_pr` captures into `target_dir`, so `REPO_DIR` stays
  correct). ANYTHING else in the invocation is un-analyzable and skipped: an env-assignment
  prefix (`GIT_DIR=`, `GH_REPO=`, anything — any can redirect git/gh), a `;`-joined or
  otherwise-uncaptured `cd`, a `gh pr <non-merge>` prefix (`checkout` re-points the branch a
  targetless merge resolves), `source`/`git`/`export`/`echo`/arbitrary commands, shell
  expansion, or a second chained merge. The SKILL-prose nudge still covers everything the
  hook conservatively skips.
- Timing caveat (unchanged, pre-existing): the nudge triggers Codex but does NOT block the
  merge on Codex's response — same best-effort "poke" semantics as the original design.
- New coverage: `tests/test-codex-nudge-premerge.sh` (none+active posts once; already-engaged
  / kill-switch / non-merge post nothing; always silent + exit 0). Auto-discovered by the
  full-glob `scripts/ci/run-shell-tests.sh` (`tests/test-*.sh`) — no explicit registration.

**Accepted limits (independently reviewed 2026-07-15 — inherent, not bugs).** Litmus
(Codex, adversarial) surfaced two theoretical concerns that an independent second reviewer
confirmed are structural properties of a non-gating, out-of-process, static PreToolUse
hook — not defects, and not worth code changes. They are documented here and in the hook
header so they are not re-raised as bugs:
1. **Fires on merge-INTENT, decoupled from the pre-merge gate's verdict.** The one-shot
   dedup is per-`(PR,HEAD)` (`codex-retrigger.sh`), so firing on an attempt the gate later
   blocks still did its job — Codex was asked about *this* code state; a same-HEAD retry
   needs no re-nudge, new commits earn a fresh one. Gating on the `pr-grind-clean` marker
   instead would duplicate the gate's admission logic (drift risk) **and** re-exclude the
   bootstrap-bypass PRs this hook exists to cover — a strictly worse trade.
2. **Cannot see the executing shell's aliases / `gh()` functions / PATH.** A PreToolUse
   hook is a separate pre-exec process reading only the payload; `sanitized-gate` fixes
   PATH for the hook's *own* `gh`/`git` calls only. The literal-`gh`-token guard already
   skips wrapper/decoy forms; the residual (a real `gh` alias keeping the literal
   `gh pr merge N` shape) is bounded to a deduped, possibly-early nudge — never a blocked
   merge (non-gating), never a comment flood. No PreToolUse-time fix exists.

---

## Revision 2026-07-17 — loosen the hook to a MERGE-FIRST rule (the "canonical shape" was too strict)

**Context.** The 2026-07-14 backstop above fired ONLY on the tightest canonical shape (a
single `gh pr merge <literal>`, optionally one `cd … &&` prefix). But pr-grind's real merge
is a MULTI-LINE Bash tool call — `gh pr merge … --squash --delete-branch || true` followed by a
`for` retry loop, `$(gh pr view …)`, `if`, `cd`, `git worktree remove`, and both paths embed
`gh pr merge` inside comments. That shape tripped every one of the old parser's bans (`;`, `|`,
`||`, `$`, env-assignments, extra segments), so the deterministic backstop **always skipped the
standard merge** — verified empirically: of 15 recent merged PRs only 2 got nudged, both
hand-typed canonical merges. The SKILL prose (COMPLETION `CODEX_DONE==none`) carried the normal
path; bypass merges (skip-pr-grind, bootstrap) got no nudge at all — the gap this hook exists to close.

**Decision (council-reviewed, 5-voice + Skeptic; hardened through adversarial Codex review).**
The single-canonical-command shape was a proxy for the wrong invariant. `codex-nudge-premerge.sh`
now parses via a standalone `lib/nudge_parse.py` (a FILE, not an inline `python3 -c "…"`, so no bash
double-quote layer can corrupt backslashes/backticks) that:
1. **Strips shell comments first** — the real block embeds `gh pr merge` in comments (a naive
   substring count sees ≥3). Comment detection is Bash-faithful: `#` starts a comment only at a word
   boundary (start / whitespace / a `;&|()<>` metachar), an unquoted `\X` escapes its char, and line
   continuations are removed first. Merges are then counted by COMMAND-WORD (not substring); exactly
   ONE is required, with a clean merge segment (no `-R`/`--repo`, no `$`/backtick, one NUMERIC PR or none).
2. **Enforces MERGE-FIRST.** Nothing may execute before the merge except pure non-sensitive
   assignments and a single captured `cd &&` prefix; ANY real command word before the merge → skip.
   This is **complete by construction** — we do NOT denylist re-targeting commands (a denylist can
   never be complete: `printf > .git/config`, `cp evil .git/config`, `sed -i`, `pushd`, an interpreter
   one-liner, a `$(git remote set-url …)` substitution, `then GH_REPO=…`, … all re-point origin). By
   requiring the merge to be first we sidestep the whole enumeration. Concurrency joins (`&`/`|`) that
   involve the merge, and sensitive env-assignments / re-targeter substitutions before it, also skip.
3. The hook fires at PreToolUse (before ANY command runs), so its own `gh pr view` always resolves the
   pristine cwd origin.

**Why merge-first, not "allow benign pre-merge commands".** The pr-grind DEFAULT block is merge-first
(only `NO_WORKTREE=<0|1>` precedes the merge), as are skip-pr-grind and bootstrap-gate bypass merges —
so the hook nudges exactly the paths the SKILL prose misses. The `--admin-on-approver-gap` block writes
its bypass-log `jq` BEFORE the merge (audit-before-privileged-action) and is therefore NOT merge-first;
the hook skips it and the SKILL-prose COMPLETION nudge covers it. That path is currently inert on this
repo anyway (`main` has no required-review rule → no approver gap), so the coverage split costs nothing
today while keeping the parser complete and adversarially closed.

**Consequences.**
- The backstop now fires on the real multi-line DEFAULT merge and on bypass-path merges — not just
  hand-typed canonical ones. The admin approver-gap path is covered by the SKILL prose.
- **Hard invariant unchanged:** the hook always posts to the CWD repo's PR (inherited-env skip +
  merge-segment inline-env/`-R` skip + `gh pr view` == cwd-origin equality). It NEVER posts to a
  different repo, and being non-gating it NEVER blocks a merge. The residual the merge-first rule can't
  see (a `gh` alias / shell function / PATH the separate hook process can't observe) is bounded to a
  deduped, possibly-spurious nudge on the cwd repo's OWN PR — the accepted-limit class documented above.
- No SKILL edit is needed: the DEFAULT block already uses a literal `<PR_NUMBER>` operand and is
  merge-first.
- New coverage in `tests/test-codex-nudge-premerge.sh` (cases 14–33, 49 total): real default block
  nudges once (commented `gh pr merge` decoys not counted); real admin block skips (audit-before-merge);
  inline/`export`/reserved-hidden/`GIT_CONFIG_*` sensitive assigns, second-merge, `cd`/`pushd`/`gh`/`git`/
  `source`/substitution re-targeters before the merge, `&`/`|` concurrency involving the merge, backslash
  continuation- and escaped-space-hidden `cd`, and `$`-operand all skip; a combinatorial prefix×reserved×
  retargeter sweep confirms none nudge; post-merge sensitive assigns / pipes still nudge (position-aware).
