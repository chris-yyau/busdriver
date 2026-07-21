# ADR 0022 — Design-review marker: the forge-proof content-bound trust anchor is not buildable (item 3 wontfix)

## Status

Accepted (2026-07-21). Closes item 3 of issue `#347` (the deferred-hardening tail of
issue `#346`, design `docs/plans/2026-07-13-task2-worktree-design-marker.md` §2/§3/§9) as an
**accepted residual, not a bug** — a *preventive* content-bound anchor is impossible
under this repo's threat model. Items 4–6 and the CodeScene advisory remain open on
issue `#347`.

## Context

Issue #347 item 3 asks for a "forge-proof content-bound trust anchor": a **signed
verdict bound to the reviewed content** so that the block decision cannot be forged and
so that content changing after review is caught. The design doc deferred it (§3): "the
loop's decision to prune/PASS is still gated only by the review it runs, as today. …
This PR neither closed nor widened the deferred content-anchor hole."

Since #346, the shipped architecture is:

- **Existence-keyed tokens (ADR-C).** For new tokens, the pending classifier
  (`_classify_tokens`) treats token existence as "pending" and never opens the doc.
  The separate legacy compatibility path (`_classify_legacy`, PASS-keyed) still reads
  the doc to check for a `<!-- design-reviewed: PASS -->` marker. A forged marker
  therefore cannot clear a token on the new-token block path — already a
  strengthening — but can still clear a legacy marker as before.
- **Trusted-loop-only prune (ADR-D).** A token is retired ONLY by the review loop's
  inline snapshot-guarded `rm` (`run-design-review-loop.sh:1418`) on a confirmed
  FULL PASS, or a manual operator `rm`.
- **Fail-closed pre-arm + cd resolution (ADR 0021, items 1&2).** Every
  Write/Edit/MultiEdit of a design doc re-arms fail-closed; a confidently-resolvable
  Bash `cd` anchors the arm/read on the write's real repo.

## Decision

**WONTFIX item 3 as a preventive control.** A forge-proof, content-bound *signed
verdict* cannot exist in this system, for three independent reasons:

1. **Same-UID ⇒ no unforgeable key.** A signed verdict needs a signing key. Every trust
   boundary in the design-marker system is local, same-UID, same-filesystem: the prune
   is an inline `rm` in a local shell script the agent runs. Any key the review loop can
   read to *sign* a verdict, a misbehaving same-UID agent can read to *forge* one. This
   is the **identical** argument this repo already settled twice:
   - `gate_marker_remove` was never shipped — "same-UID software cannot prove 'human'"
     (design §6).
   - The arm-failure sentinel was rejected as theater — it "writes to the same failing
     FS as the token" (ADR 0021, Alternatives).
   A signing key is the same class of theater: it certifies a boundary it cannot hold.

2. **No placement of a content-hash check yields a *forge-proof* anchor; the one that
   helps at all is the advisory detector, already scoped out.** A digest comparison can
   live in the reader (block path) or in the trusted loop (prune path):
   - **Reader-side** — verifying current content against a recorded verdict on the hot
     block path reintroduces exactly the doc-read that ADR-C *deliberately removed* to
     kill the lost-rearm race (keystone test `i`: the loop writes PASS before it prunes,
     so any surviving post-snapshot token that re-reads the doc would classify the
     now-PASS doc "reviewed" and fail open). Existence-keying is what makes the loose-refs
     analogy hold; a reader-side content check breaks it. Dead end.
   - **Loop-side** — the loop re-hashes the reviewed bytes (before it stamps PASS) and
     skips its snapshot-guarded prune on a mismatch, preserving the doc-read-free block
     path. This *does* catch one narrow case the shipped design misses: a concurrent edit
     **during the review window** `[review-start, prune]` that itself **failed to arm** a
     replacement token (a Bash-redirect / misresolved-`cd` arming miss from reason 3) —
     no new-nonce token exists to survive the prune, so only a digest mismatch would
     withhold it. It is therefore a **buildable partial safeguard**, not nothing. But it
     is **not what item 3 asks for**: (a) it is *cooperative*, not forge-proof — the
     same-UID adversary of reason 1 can patch out the check or `rm` the token, so it
     certifies nothing against the actor item 3 names; (b) it covers only the in-review
     window, and the same arming miss one moment *after* the prune is invisible to it —
     that residual is closed completely by fixing arming (reason 3), not partially by a
     prune-time digest; and (c) unlike the truly warn-only detector in Alternatives
     (which never withholds anything — it only warns after the fact), this loop-side
     check *does* withhold the prune on a mismatch. But that preventive effect is still
     bounded by (a) and (b) above — a same-UID-forgeable check whose window is limited
     to the review period — so it is a narrower, buildable variant of the same advisory
     idea the maintainer deliberately scoped OUT of this decision, not a promotion to a
     forge-proof anchor. So the loop-side check is a deferred optional nicety —
     item 3's asked-for property remains unreachable (reason 1).

3. **The residual it targets is an *arming* gap, closed by arming, not by an anchor.**
   After items 1&2, the only way content drifts without re-arming is a narrow set of
   arming misses — Bash-redirect design-doc creation, a relative `cd`/ambient `CDPATH`,
   or a hostile `cd` shell-function/alias (ADR 0021 accepted residuals). A content-bound
   anchor does not fix arming; **better arming does.** Spending the complexity on a
   crypto anchor instead of on closing an arming residual optimizes the wrong layer.

**Existence-keying (ADR-C) + fail-closed arming (items 1&2) is therefore the terminal
trust boundary for this gate**, not a way-station to a signed anchor. The gate is
cooperative-mis-fire protection for a solo operator, not a sandbox against a
key-extracting adversary; a boundary that assumes the latter would be under-enforcing by
pretending to a guarantee it cannot make.

## Why this does not weaken the gate

- Nothing changes in code. The new-token block path stays existence-keyed and
  doc-read-free; the legacy compatibility path retains its existing reviewed-document
  check. The only trust delta remains the #346 strengthening (the new-token reader no
  longer consults the editable PASS comment).
- The forge surface item 3 named — the editable PASS comment — is **already** neutralized
  on the block path by existence-keying. What item 3 additionally wanted (binding the
  *loop's PASS decision* to content) is unreachable without an unforgeable key, which
  same-UID precludes.

## Alternatives considered

- **Signed/HMAC verdict over `sha256(content)`.** Rejected — key is same-UID readable
  (reason 1); it is forgeable by the exact adversary it targets.
- **Advisory (warn-only) drift detector** — record `sha256(reviewed content)` on PASS,
  warn at SessionStart if a trusted doc later diverged. Buildable and honest (detection,
  not prevention — matching `design-clear.sh`), but the maintainer scoped this ADR to the
  decision only; deferred as an optional future nicety, NOT a security control. If built,
  it must never touch the block path (that would re-trip reason 2).
- **Server/push-anchored verdict** (a signature the agent cannot mint locally). Rejected
  — the design-marker system is deliberately local-first for a solo public repo; there is
  no server surface in this path to anchor to, and inventing one is out of proportion to a
  cooperative-mis-fire gate.

## Consequences

- Issue #347 item 3 is closed as an accepted residual. Items 4 (payload-cwd allowlist),
  5 (divergent-branch collision drain), 6 (SessionStart subdir-legacy auto-import), and
  the CodeScene advisory remain open.
- The design doc's "DEFERRED — forge-proof trust anchor" language (§2/§3/§9) is now
  resolved-as-wontfix by this ADR rather than pending.

## Revisit trigger

- The design-marker trust boundary stops being same-UID/local (e.g. a review verdict
  becomes anchored to a server- or push-signed signal the local agent cannot mint) — then
  an unforgeable content binding becomes possible and item 3 should be reopened against
  that anchor.
- Evidence accumulates that post-review content drift through an *arming* gap is a real,
  recurring fail-open — then close it in the arming layer (extend pre-arm to
  Bash-redirect design-doc writes), not with a content anchor.
