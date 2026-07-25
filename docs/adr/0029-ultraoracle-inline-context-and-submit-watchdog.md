# ADR 0029 — UltraOracle: inline context by default, and bound the pre-submission phase

## Status

**Accepted (2026-07-25).** Builds on [ADR 0020](./0020-ultraoracle-attach-running-transport.md)
(attach transport) and the #458 completed-but-hung watchdog. Amends the
`--context`-becomes-`--file` transport described in
[ADR 0007](./0007-ultraoracle-expert-witness-and-ultra-council.md) §"support for
`--prompt-file` and `--context`". Issue: **#490**.

## Date

2026-07-25

## Context

A blueprint-review ultra-oracle advisory (attach mode, oracle 0.16.1, gpt-5.5-pro)
uploaded the design doc into the ChatGPT composer and then **never sent the message**.
oracle sat there for the full `--timeout` (1800s, ~27 min observed) before failing with
`Attachments did not finish uploading before timeout`, writing no verdict. The browser
screenshot confirmed the state: file attached, compose box empty, nothing submitted.
`oracle status --browser-tabs` reported `send=yes turns=0` on a blank tab — oracle's own
status believed it had sent.

This is **not** #458. #458 was completion *detection* of a response that had finished;
here no turn was ever started. The #458 machinery is therefore structurally unable to
help: the streaming heuristic needs a `response streaming` heartbeat that never comes, and
the tab-status probe needs a `completed` tab with a non-empty `last=` preview, which a
never-submitted conversation never has. Both correctly decline, and the run rides its full
cap — re-introducing exactly the ~30-minute wall-clock stall #458 removed, by a different
route.

Two facts from the primary sources shape the fix:

1. **The upload path is the fragile part, and it is avoidable.** A prompt-only consult of
   comparable size sends in seconds on the *same* attach setup. We only take the upload
   path because `ultra_oracle_consult` unconditionally translated every `--context` into
   an oracle `--file`.
2. **The absence of a heartbeat is evidence the submission flow never completed.** In
   oracle 0.16.1 `src/browser/index.js`, `startThinkingStatusMonitor` is started strictly
   *after* `runSubmissionWithRecovery` returns. So a run log with no `ChatGPT thinking` and
   no `no thinking status detected yet` line proves that call never returned — it cannot be
   a merely slow response, because a slow response emits idle ticks. Note the flow clicks
   Send and *then* verifies the prompt committed, so this signal covers "never sent" **and**
   "sent, but post-click verification stalled"; the consequences of that are handled in the
   Decision below.

## Decision

**Two changes, both in the Layer-2 adapter `scripts/lib/ultra-oracle.sh` so every caller
(blueprint-review, council, the ultraoracle evidence pack and retrieval loop) is fixed at
once.**

### 1. Inline `--context` by default; attach only what will not fit

The prompt is now assembled *before* the transport decision. Every `--context` file is
carried **inline** in the `--prompt` text, fenced with
`--- BEGIN/END CONTEXT FILE: <path> ---`, whenever the whole set fits alongside the prompt
within `ULTRA_ORACLE_INLINE_BYTES` (default 100000 — the budget that already governed
`--prompt-file` inlining). Over budget, or if any context is not a readable regular
**text** file, the whole set falls back to `--file` exactly as before.

- **All-or-nothing** on purpose: a mixed payload still stalls on the one attachment it kept.
- **Snapshot-first, so the sizing/scan/read are TOCTOU-safe.** Each context is first copied to an
  immutable temp snapshot (bounded to `inline_cap + 1` bytes via `head -c`), and every check —
  size, the NUL binary scan — plus the inlined bytes all come from that snapshot, never a second
  live read of the path. A shell variable cannot hold a NUL byte, so the binary scan is
  unavoidably a separate read from the content read; snapshotting is what makes those separate
  reads see the *same* bytes, closing the whole class of "the file changed between the check and
  the use" races (a NUL swapped in after the scan, a file grown past the cap, a partial read).
  The `head -c` bound also caps peak memory at the budget regardless of source size, and a
  snapshot that reaches the `+1` byte proves its source is over budget → attach. `mktemp`
  failure, a non-regular/unreadable source, or any measure error all fail **closed** to attaching
  the set. Attach still passes the *original* path to `--file` (oracle reads it later, as before);
  the snapshot is purely the inlining decision + inlined content, and the temp dir is removed
  before dispatch. These callers have no concurrent writer, so the race is theoretical — but the
  snapshot closes the *content-mutation* class (a NUL swapped in after the scan, a grown/partial
  read) structurally rather than as a residual.
  - **Accepted residual (blocking-open on a swapped non-regular source).** The `[[ -f "$g" ]]`
    check and the snapshot's `< "$g"` open are separate path lookups, so an adversary who could
    replace the path with a FIFO or device between them could make the open *block* (the block is
    in the shell's redirect, before any timeout could arm, so it is not cheaply bounded in portable
    shell). This is explicitly **out of scope**: every `--context` here is a session-local file the
    same busdriver run just wrote (the design doc, `build-evidence-pack.sh` output, retrieval-loop
    evidence), with no concurrent writer and no path by which an attacker reaches them mid-consult.
    Closing it would require per-file background-read-with-timeout machinery guarding a race that
    cannot occur for these callers — a cost the threat model does not justify. Revisit only if a
    caller ever passes a `--context` path from an untrusted or externally-writable location.
- **NUL-bearing and non-regular contexts always attach.** `$(cat …)` strips NUL bytes, so
  inlining such a file would silently truncate it — a correctness bug worse than the stall.
  Detection is a whole-file NUL scan (not `grep -Iq .`, which short-circuits on the first
  text line before a later NUL, and mis-rejects a newline-only text file). **Scope:** NUL is
  the dominant binary marker and catches every artifact this plugin's callers pass (source,
  markdown, git diffs, evidence-pack files). A NUL-*free* yet non-UTF-8 file (latin-1,
  UTF-16-without-nulls) is an accepted residual — it would inline and could be transcoded to
  U+FFFD by the consumer's UTF-8 argv decode; a stricter iconv check would also reject
  legitimate non-UTF-8 text and isn't worth it for callers that only ever pass UTF-8.
- **The evidence-pack label stays truthful.** `build-evidence-pack.sh` labels a consult
  `ORACLE_REPO_ATTACHED_REVIEW` based on whether raw repo files were *sent*, not on the
  transport used to send them. Inlining sends the same content (modulo trailing newlines, which
  command substitution strips — semantically irrelevant to the review).

### 2. Bound the pre-submission phase (attach + background watched runs)

`_ultra_oracle_run_watched` now terminates the run if `ULTRA_ORACLE_SUBMIT_GRACE`
(default **300s**) elapses with no heartbeat line of any kind in the run log, and reports
**124** — the *ambiguous* hard-cap code, deliberately **not** the 125 confirmed-hung
sentinel, so salvage never fires.

That choice is what makes the imprecision in signal (2) safe. Because the trigger also
covers a post-click verification stall, the run we kill *might* hold a live turn. But the
tab-status probe has already had ~17 chances (every ~15s from `ULTRA_ORACLE_HUNG_GRACE`) to
find a `completed` tab for this session and salvage it, so a **finished** answer is
recovered well before the grace expires. What can survive to the fast-exit is a turn still
*generating* — exactly the case where a harvest would promote a partial to a verdict. So we
refuse to salvage and accept the lost advisory, which is non-gating. The issue also observed
a sibling tab holding a *different* session's completed review, a second reason not to
harvest blind here.

300s is ~3-5x the observed worst-case pre-submission cost (attach, page load, model
select, composer ready, oracle's own 45s upload budget, 45s send-button budget). It is
raisable via the env var; `0`/invalid falls back to the default, so the bound can be
loosened but not switched off.

`_ultra_oracle_diagnose_hint` gained the matching signature so the failure surfaces as an
operator action, not a bare `timeout` token.

## Alternatives considered

- **Bound the upload step specifically, with its own retry.** Rejected: not observable
  from our side. oracle's `Uploading attachment:` / `All attachments uploaded` logger lines
  are suppressed in non-verbose mode — confirmed by the issue's verbatim `.err`, which
  jumps straight from `Launching browser mode` to the error. The heartbeat-absence signal
  is the only one actually present in the log we capture.
- **Pass `--browser-attachment-timeout` to shrink oracle's own budget.** Doesn't address
  it: oracle's default attachment budget is already 45s, yet the observed run consumed
  1800s. The extra time is spent somewhere we cannot see or configure, so an
  oracle-side knob is not a bound we can rely on.
- **Fix `send=yes turns=0` / bind the harvest to the dispatched tab.** Upstream's bug and
  already mitigated on our side: per-dispatch unique slugs (#458 GAP 1) plus
  `_ultra_oracle_tab_ref`'s fail-closed "exactly one tab per session" rule mean a sibling
  tab's stale answer can never be harvested as ours. Worth reporting upstream, not worth
  re-implementing here.
- **Extend the fail-fast bound to blocking mode.** Partly resolved by the merge, not by this
  ADR's original code. ADR-0027/#481 routed **attach + blocking** consults through
  `_ultra_oracle_run_watched`, so they inherit this pre-submission bound automatically. Only
  **non-attach blocking** (cookiePath / remoteHost / copy-profile) still runs under a bare
  `_portable_timeout` — a foreground path where the operator watches the heartbeat live and can
  Ctrl-C, and with no live tab to harvest, so reproducing the watched-run machinery there buys
  little. The inline-by-default change already removes the triggering condition for those
  callers below the budget.

## Consequences

- The reported failure mode is **structurally absent** for any payload under the inline
  budget, which covers every in-tree caller's normal case (the #490 design doc was
  ~19k tokens / well under 100 KB).
- Large payloads still attach. Because `_ultra_oracle_run_watched` carries the pre-submission
  bound, every path that runs *through* it gets it: **attach + background** runs
  (blueprint-review, council — where #490 was observed) and, after the ADR-0027/#481 merge that
  wired the completed-but-hung watchdog into **attach + blocking** consults, those too. A stall
  on any of them now costs at most `ULTRA_ORACLE_SUBMIT_GRACE` (~5 min) instead of the full cap;
  a never-submitted run returns the ambiguous 124 there and #481's blocking-salvage correctly
  does not fire on it. **Only NON-attach blocking** (cookiePath / remoteHost / copy-profile) is
  uncovered: it runs under a bare `_portable_timeout` with no heartbeat analysis (no live tab to
  harvest anyway), so the ultraoracle evidence pack / retrieval loop on those transports can
  still spend the whole cap on an over-budget payload. Their protection is the inline default,
  which keeps them off the upload path entirely below the budget.
- oracle sees context as prompt text rather than as an attachment. For review-style
  consults this is the shape that already worked most reliably; models handle very long
  single prompts fine, and oracle has its own `prompt-too-large` → file-upload fallback if
  argv ever proves too small.
- One more env knob (`ULTRA_ORACLE_SUBMIT_GRACE`). `ULTRA_ORACLE_INLINE_BYTES` gains a
  second job (it now sizes the combined prompt+context payload, not just `--prompt-file`).

### Accepted residuals

Both were raised by the ultra-oracle advisory reviewing this ADR, and are accepted rather
than fixed:

- **The watchdog is coupled to oracle's heartbeat strings, and fails in the unsafe
  direction.** It matches `ChatGPT thinking` / `no thinking status detected yet`. If a
  future oracle renames them, the grep never matches and *every* watched run is killed at
  `ULTRA_ORACLE_SUBMIT_GRACE` — including healthy ones. Note the asymmetry with the #458
  heuristic, which greps the same strings but fails *safe* (recovery silently stops). The
  blast radius is bounded: this surface is non-gating, so the worst case degrades a 30-minute
  stall into a 5-minute advisory timeout — still better than the status quo it replaces —
  and the 300s default is ~10x oracle's own 30s heartbeat interval, so a submitted consult
  has many chances to be seen. Not worth a version guard until oracle actually breaks it.
- **Context file *contents* now appear in the process table.** `--prompt "<payload>"` is
  visible to same-user/root via `ps` for the consult's duration, where the pre-#490
  `--file <path>` exposed only the path. This does not extend to secrets — the same
  argv already carried `--prompt-file` content before this change, `remoteToken` is
  deliberately delivered via env for exactly this reason, and `build-evidence-pack.sh`
  excludes secret-like files with no override. What is exposed is repo text that this
  surface is in the act of sending to ChatGPT anyway, on a single-operator machine where
  same-user access is already total. Accepted, but it is a genuine widening and belongs on
  the record.

A third advisory point — "count bytes, not shell character length" — did not apply: the
budget already sums `wc -c` byte counts for both the prompt and every context.

## Revisit trigger

- oracle ships a fix that makes attachment upload reliable **and** makes `send`/`turns`
  consistent — then the inline default becomes a preference rather than a workaround.
- A consult legitimately needs >300s before submitting (e.g. a much slower attach target),
  showing up as spurious `no ChatGPT turn started` fail-fasts.
- A caller appears whose context genuinely cannot be inlined (images, PDFs, large binary
  artifacts) — that caller needs the attachment path hardened, not the budget raised.
- An oracle upgrade changes the heartbeat wording (see the first accepted residual) — the
  symptom is every watched consult failing at exactly `ULTRA_ORACLE_SUBMIT_GRACE` with the
  `no ChatGPT turn started` marker, and the fix is a version-aware pattern set, not a
  larger grace.
