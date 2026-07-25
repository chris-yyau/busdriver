# ADR 0027 — Review-once-at-create bots: a stranded clean review downgrades to `none`, not `stale`

## Status

**Accepted (2026-07-25).** From issue #489 (evidence: Dive-And-Dev/jikdak PR #270,
2026-07-24). Decision: **direction 2, fail-CLOSED** — reclassify a *stranded,
clean, one-and-done* review from a known review-once bot as **non-gating `none`**,
implemented as a new login-gated Case 4 in `scripts/ack-ledger.sh`'s downgrade
block. Scoped to **`devin-ai-integration` only**, and released **only** when the
review body exactly matches a known Devin clean template (an anchored whitelist,
not a substring/denylist). Direction 1 (carry the clean review forward as a
HEAD-ack SHA) and direction 3 (release only at `--max-wait` via the ADR 0012
downgrade) were rejected — see Alternatives.

**Design iteration (litmus PR-mode review).** Three earlier drafts released on
body *content* heuristics — a clean-phrase substring, then substring + an
actionable-marker denylist, then a body-blind structural release. Adversarial
review correctly rejected each as fail-OPEN: a finding placed only in the COMMENTED
summary (no thread, no CHANGES_REQUESTED) would slip through — a substring matches
"No issues found. Critical: SQL injection", and no denylist enumerates all finding
phrasings. The accepted design inverts this to a fail-CLOSED **anchored whitelist**:
the normalized body must *equal* a known clean template, so any extra prose leaves
residual text and keeps the review `stale`. Cursor was dropped: its exact clean
string is unconfirmed, and fail-closed means an unknown template stays `stale`
rather than being guessed into `none`.

## Context

pr-grind's ack ledger assumes every registered gating bot **re-reviews each new
push**. That is false for **`devin-ai-integration`** and **`cursor` (Bugbot)**:
both review **only the PR-create commit** and do **not** re-review later commits.

The moment pr-grind pushes a fix-round commit (the common case), a review-once
bot's clean review is pinned to the pre-fix SHA:

- Tier B misses (`commit_id` != HEAD).
- No HEAD-scoped `skipped` check-run to key Case 3 on. Devin registers no
  check-run at all; cursor's Bugbot check-run *is* a clean-only Tier-D ack, but it
  stays anchored to the reviewed (pre-fix) commit, so on a fix-round push it no
  longer matches HEAD — neither yields the `skipped`-on-HEAD artifact Case 3 needs.
- Case 2 needs a `## PR Overview` marker the bot's `No Issues Found` body lacks.

So it fell through the entire downgrade block to `echo stale`, and Invariant 2
(all registered bots must ack HEAD before `clean`) blocked **permanently** on a
bot that will never re-post. The gate could not self-converge: every fix-round PR
was forced into a `--max-wait` bail or a manual `skip-pr-grind.local` bypass —
silently pushing operators toward the bypass and eroding the gate.

Verified against the live ack-ledger source before deciding: the stranding is a
fall-through to the terminal `stale`, not a mis-fire of an existing case.

## Decision

Add **Case 4** to the `ever_approved == 0` downgrade block, login-gated to
`devin-ai-integration`. When Devin's last review is a COMMENTED `/reviews` entry
with no body-SHA reference **and** its normalized body exactly matches a known
Devin clean template, downgrade to `none` (never a HEAD-ack SHA — Devin never
reviewed HEAD's diff).

**Normalization + anchored match.** The body is lowercased, a *specific* ASCII
markdown set (`* _ ` `` ` `` `#`) is removed, and whitespace is collapsed/trimmed;
the result must match an **anchored** `^…$` regex for a known Devin clean template
(`^(✅ ?)?(devin review:? )?no issues? found[.!]*$`). The `$` anchor is load-bearing:
it rejects *any* trailing content, so a finding in the summary keeps the review
`stale`. Normalization deliberately does **not** strip the complement of `[a-z0-9]`
— an earlier `tr -c 'a-z0-9' ' '` draft replaced every non-ASCII byte with a space,
so a body-only finding in a non-Latin script ("No issues found. 存在严重漏洞")
collapsed onto the whitelist and failed OPEN (caught in review). The anchored regex
never strips non-ASCII, so CJK/Cyrillic/emoji trailing text all break the match.

**Amendment (issue #496, 2026-07-26) — the whitelist must cover the *shipped*
template, not a minimal paraphrase.** As first written the regex matched only the
one-sentence `no issues found` form. Devin's actual clean review is two sentences
plus a machine-generated HTML badge block, so the anchored `$` rejected every real
review and Case 4 was **inert** — the #489 deadlock persisted unchanged. Two narrow
widenings, both preserving `^…$`: (a) strip the badge, delimited on **both** sides
by its stable `<!-- devin-review-badge-begin/end -->` markers — deliberately *not*
`begin.*$`, which would swallow a finding appended after the badge and fail OPEN —
and gated on **exactly one** begin/end pair, because sed BRE has no lazy quantifier
so `begin.*end` across *two* badge blocks spans first-begin to last-end and would
delete a finding between them (a second fail-OPEN, caught in review; with a single
pair greedy and non-greedy coincide, and every other marker count skips the strip
so the residual HTML keeps the review `stale`); (b) admit the template's second sentence ("devin review analyzed this pr and found
no bugs or issues to report") as an optional exact alternation. Prose outside the
badge markers is untouched, so a summary finding still leaves residual text and
still stays `stale` (tests 7d/7e/7f). The lesson generalizes: a fail-closed whitelist
validated only against a hand-written sample is indistinguishable from a disabled
one — tests 7d/7e pin the **verbatim shipped body**, badge HTML included, so a
future template refresh fails loudly instead of silently going inert again.

**Follow-up amendment (P1, Codex + cubic on #498, 2026-07-26) — counting marker
pairs is not the same as validating the payload.** The exactly-one-pair guard
above proves the strip can't span *across* two badge blocks, but it says nothing
about *what* sits inside a single pair — a finding placed there (e.g. `<!--
devin-review-badge-begin -->Critical: unsanitized input enables SQL
injection.<!-- devin-review-badge-end -->`) would be discarded right along with
the markers, the same fail-open class one layer deeper. The strip now also
requires the between-markers content to be **markup only** — a sequence of
`<…>` tags separated by whitespace, nothing else. That is the whole distinction
that matters: the badge is markup, a finding is prose. Prose leaves a non-tag
token, fails the check, skips the strip, and the residual markers+text keep `$`
from matching, so the review stays `stale`. Pinned by test 7g
(finding-inside-a-single-marker-pair), verified to fail without the check.

A first draft pinned the exact devin.ai badge shape instead (anchor to
`app.devin.ai/review/…` wrapping a `<picture>` with `<source>`/`<img>` on
`static.devin.ai/assets/…`, fixed attribute order). Rejected: that re-creates the
defect this whole amendment exists to fix — an over-narrow pattern that goes inert
the moment Devin refreshes its badge markup, this time failing silently to `stale`
forever. Markup-vs-prose closes the identical fail-open and survives a refresh.
Findings smuggled into an attribute value (`alt="critical: …"`) are out of scope by
construction: they were stripped under every prior design too, and an alt attribute
is not a channel any bot posts findings through.

**Defense in depth.** Devin's findings also arrive through channels gated *above*
Case 4 — inline threads (Tier A → `stale`) and CHANGES_REQUESTED (`ever_approved >
0`, never enters the block) — so the whitelist is the last of three independent
gates, not the only one.

Enforced by tests 6–11 in `tests/test-ack-ledger-devin.sh`: clean template →
`none`; body-only finding → `stale`; thread → `stale`; CHANGES_REQUESTED →
`stale`; cursor (not whitelisted) → `stale`; other bot with a matching body →
`stale`.

Key properties:

- **`none`, not a HEAD-ack SHA.** Devin never reviewed HEAD's diff, so we do **not**
  fabricate an approval. `none` records "non-gating for HEAD." Required status
  checks + litmus + Codex remain the merge authority (the standing pr-grind
  Invariant: AI acks are bounded-wait advisory, checks gate).
- **Login-gated + fail-CLOSED.** Scoped to `devin-ai-integration` (whose review-once
  behavior and clean template are confirmed). A merely-slow gating bot, cursor, or
  any body that does not match the template all stay `stale`. Unknown ⇒ block.
- **Whitelist is last of three gates.** A finding surfaces as an inline thread
  (Tier A → `stale`) or CHANGES_REQUESTED (`ever_approved > 0`, never enters the
  block); the anchored body whitelist backstops the residual COMMENTED-summary
  channel. No single-point release.

## Residual risk (accepted, minimal)

The whitelist releases only a body that normalizes *exactly* to a known clean
template, so a body-only finding cannot pass. The residual is the mirror image — a
**false-negative**: a genuinely-clean Devin review whose body uses an
*unrecognized* clean phrasing stays `stale` (the pre-fix deadlock persists for that
PR until the template is added or the operator uses the ADR 0012 opt-in). This is
the safe direction to err, and new templates are cheap to add once observed.

## Alternatives

- **Direction 1 — carry the clean review forward as a HEAD-ack SHA.** Rejected:
  fail-OPEN. It claims an approval on a diff the bot never saw, and a bodyless
  carried-forward ack would carry `n_total == 0` and trip Invariant 3's
  ADR-0001 D/E exemption accounting. Content-identity carry-forward only applies
  to message-only force-pushes where the diff is identical; a fix commit changes
  the diff, so it does not qualify.
- **Direction 3 — release only via the ADR 0012 downgrade at `--max-wait`.**
  Rejected as the *default* path: it requires the per-repo opt-in file and burns
  the full wait budget before releasing a bot that was never going to re-post.
  ADR 0012 remains the correct mechanism for bots that *lack* a Case-3/Case-4
  structural downgrade; it is not removed.

## Consequences

- Fix-round PRs on repos with Devin self-converge without an opt-in when Devin's
  clean review matches the template — the common case that was previously a
  guaranteed bail/bypass.
- The two `[update-merge]` notes in `skills/pr-grind/SKILL.md` are updated: the
  Devin merge-commit stranding is now handled by Case 4 for the recognized clean
  case; the ADR 0012 opt-in guidance is scoped to *other* bots (incl. cursor,
  which is not whitelisted here) lacking a structural downgrade.
- Cursor remains unhandled by Case 4 by design (unconfirmed template); it relies on
  its own Tier-D check-run path or the ADR 0012 opt-in.

## Revisit trigger

- Devin begins re-reviewing later pushes (then it no longer needs Case 4 and should
  be removed).
- A genuinely-clean Devin body with an unrecognized phrasing is observed stranding
  `stale` — add that normalized template to the whitelist (fired once already:
  issue #496; capture the verbatim body in a test alongside it).
- Cursor's exact clean-body string is confirmed and its review-once behavior
  verified — add it (login + template) under the same fail-closed pattern.
