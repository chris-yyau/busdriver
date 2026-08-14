# ADR 0039 — Marker record stream: per-kind budgets with an explicit overflow record

**Status:** Accepted
**Date:** 2026-08-14

## Context

`marker_ops.py classify` streams one record per pending design-review finding —
four NUL-terminated fields, `(kind, source_path, doc_path, reason)` — to three
consumers: `pre-implementation-gate.sh` and `pre-commit-gate.sh` (through
`gate_render_pending_records`), and `scripts/design-clear.sh`.

Two of those consumers do more than list. They **screen**: `design-clear.sh`
refuses a by-name release all-or-nothing when the doc's record set contains a
non-token or unvalidated marker, and the renderer suppresses a hint that the
screen would refuse. Both screens compare the records they were handed. A record
that never got emitted is, to them, a record that does not exist.

That is the whole of PR #670. Its seven fix rounds were one defect from seven
angles — an anomalous marker for a document becoming invisible to a consumer
screening the set it was given:

| round | anomaly that hid | fix |
|---|---|---|
| 1 | legacy marker, different path spelling | canonicalize the legacy `doc_path` |
| 2 | legacy marker buried by ≥20 tokens | emit legacy before tokens |
| 3 | malformed token buried by ≥20 healthy siblings | emit anomalies first, defer valid tokens |
| 5 | `//`-spelled key mismatch | collapse `//` on both sides (this change) |
| 6 | tokens starved by ≥20 legacy entries | per-kind budgets, legacy uncapped |
| 7 | token count undercounted by the render window | count over the full stream (this change) |
| 7 | uncapped legacy = unbounded consumer work | this ADR |

Round 6 left the budget asymmetric — `_CAPS = {"token": 20}`, legacy uncapped —
because a shared budget cannot satisfy both invariants at once, and each of the
two orderings breaks one of them. Uncapping legacy satisfied both, and bought an
unbounded stream: `design-clear.sh` reads every record into bash arrays.

So the design has been oscillating between two failure modes:

- **cap legacy** → a record can go missing, and the screen passes blind;
- **uncap legacy** → every consumer processes an unbounded set.

Each satisfies one constraint by giving up the other.

## Decision

Keep per-kind budgets, and make truncation **knowable** rather than silent.

1. **`_CAPS = {"token": K, "legacy": L}`** with `K = 20` (a working ceiling, hit
   routinely — token count grows one per edit) and `L = 500` (a backstop against
   a generated file, not a working limit — the legacy union is the `- ` lines of
   a file the operator wrote).

2. **When a budget truncates a kind, the classifier says so**: one extra record
   closes the stream — `kind = "overflow"`, empty `doc_path`, `reason =
   "<kind>-overflow"`. It is exempt from `_CAPS` by construction: it is the
   signal that a cap was hit, so a cap must never be able to drop it. Emitted
   last (it can displace nothing) and only on the success path (an exit-2 run is
   already fail-CLOSED for every consumer).

3. **Consumers act on the signal, asymmetrically by kind**, because the two
   truncations mean different things:

   - `token-overflow` **under-reports**. Clearing stays exact — one named token —
     so a short listing never over-deletes. `design-clear.sh` drains what was
     listed, says more were pending, and the operator re-runs. Refusing instead
     would refuse in #665's own motivating scenario (a 23-token doc), which is
     the doomed-control failure this whole line of work exists to remove.
   - `legacy-overflow` is **not** safe that way: the missing record may be the
     one the screen exists to find. Both name-based selectors are refused —
     `--all-for-doc` and the plain `<doc-path>` form, whose ">1 match" refusal is
     the same screen wearing a different hat. Index release stays available (it
     never claimed that screen), as does the listing, which says why.

4. **Truncation is no longer inferred.** `design-clear.sh` previously deduced it
   from "I counted exactly the cap". That both false-positives on a complete set
   that lands on the cap exactly, and cannot see records dropped before they ever
   reach the emitter — `_classify_tokens` stops *buffering* valid tokens at `K`,
   so those drops were invisible to the emitter entirely. `note_overflow()` makes
   that path declare itself.

## Alternatives

**Leave legacy uncapped (the PR #670 state).** Correct on safety, unbounded on
cost. The cost is real but modest today; the reason to move is that it makes the
safety property depend on the operator never generating that file, which is not
a property the code can hold.

**Cap legacy with no signal.** The silent partial screen — strictly the worse of
the two oscillation states, since it fails in the direction that releases a
review requirement.

**Make the gate re-classify with a higher budget when it needs a complete set.**
A second classifier mode, on a fail-CLOSED security path, for a case that has
never occurred. Rejected as more surface than the problem.

**Refuse on ANY overflow.** One branch, no per-kind reasoning — and it re-breaks
#665: a 23-token doc trips `token-overflow` on the run that is supposed to drain
it. The asymmetry is not incidental; it is the decision.

## Consequences

- The record stream gains a fourth kind. Both renderers already have a branch
  for a record with an empty `doc_path` ("not clearable here"), so an unpatched
  reader degrades to listing it rather than misreading it.
- A pathological legacy file now costs consumers `O(L)`, not `O(file)`, and
  `_classify_legacy` stops opening docs the moment it overflows.
- An operator who genuinely holds >500 pending legacy entries loses by-name
  release until they trim the file. That is the fail-closed cost, and it is
  visible and self-describing rather than silent.
- `gate_render_pending_records` counting the full stream (not the rendered
  window) is bounded by `L + K` rather than by the file, which is what makes
  that fix affordable on the latency-sensitive gate path.

## Revisit trigger

- A legitimate legacy list approaches `L` — raise it; the value is a reversible
  backstop, not a boundary.
- A consumer is added that needs a complete set for something other than the
  same-document screen — the overflow record is per-kind, not per-consumer, and
  a second consumer with different needs may want a per-kind emitted count too.
- The legacy list-file marker format is retired outright, at which point the
  legacy budget and this half of the protocol go with it.
