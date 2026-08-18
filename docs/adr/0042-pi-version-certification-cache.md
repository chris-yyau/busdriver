# ADR 0042 — keep the manual pi certification bump

**Status:** Accepted (2026-08-17) — ships with the code change it describes.
**Amends:** ADR 0034 (pi in-tree read lane). The version gate and the
bump-then-verify order are unchanged and reaffirmed. This change corrects two
comments that described the ritual in an order that cannot work.

## Context

pi upgraded 0.84.1 → 0.84.2 on its own and the lane went completely offline until
someone tried to use it — the gate refuses any pi whose version is not the probed
constant. That block is correct and stays.

Clearing it costs a source edit, a live certification, a commit and a PR, on every
pi release. This ADR answers whether that cost should be automated away, and
fixes a defect found while asking.

**The ritual was stated three times in `dispatch.sh`, and two statements misled:**

| Site | Said | Correct? |
|------|------|----------|
| Comment above the `BUSDRIVER_PI_PROBED_VERSION` assignment | "re-run the live test, **then** bump this constant" | **No** — deadlocks |
| `BLOCK, not warn` comment in the pi preflight | "On a mismatch, re-run `BUSDRIVER_PI_LIVE=1 …`" | **Incomplete** — omits the bump |
| `_pi_setup_fail` message and the comment above it | bump → test → revert on fail | Yes |

The live probe dispatches through the working-tree `dispatch.sh` itself, so the
gate refuses the new pi before the write-denial check can reach it. Verify-then-
bump cannot work — the third site says so explicitly, while the first instructed
exactly that order.

(Precisely: pi *is* executed before the compare — the preflight runs
`pi --version` to obtain the value it compares. What the gate blocks is the
dispatch that the certification actually exercises. "The test can't run" is the
operative fact; "pi never runs" would be wrong.)

## Decision

**Keep the manual, tracked bump**, and **pin the ritual with a test** rather than
with more prose.

1. **`tests/test-pi-dispatch-arm.sh` asserts the order mechanically, and ships
   its own proof.** Every ritual comment must name the bump *before* the live
   test. The check compares **order of concepts** in the comment window, not
   literal sentences, so it survives rewording; it reads **comment lines only**,
   so an adjacent code line cannot satisfy a concept; and it discovers sites by
   `BUSDRIVER_PI_LIVE` alone, so a command wrapped across lines is still seen.

   **Two fixtures run on every invocation** and are the real deliverable:
   one feeds it the *verbatim* pre-0042 wording of both drifted sites and
   requires rejection; the other feeds it a comment that omits the bump next to a
   code line that mentions the constant, and requires rejection. If the guard
   ever stops being able to fail, those fixtures fail first.

   That shape was reached by failing three times, and the failures are the
   argument for it. Version one keyed on the literal
   `BUSDRIVER_PI_PROBED_VERSION` — the drifted text says *"then bump this
   constant"*, so the name never appears and the guard stayed green against the
   exact wording that caused the outage. Version two lost the outage site
   entirely, because the corrected comment wrapped the command across two lines
   and the discovery grep matched single lines. Version three let the adjacent
   `if [[ … != "$BUSDRIVER_PI_PROBED_VERSION" ]]` satisfy the bump concept, making
   the third site vacuous. **Each of the three was declared "verified in both
   directions" on a hand-run control that lived only in a transcript**, and each
   was caught by review executing the checker instead of reading it.

   The lesson generalises past this guard: a proof that does not ship is not a
   proof, it is a claim. **A guard that cannot fire is worse than no guard** — it
   certifies safety it never checked.
2. The two drifted comments are corrected to state bump-then-verify.

Point 1 is the load-bearing half. Design review made the argument better than the
first draft did: correcting comment drift by writing more comments leaves nothing
to stop the next drift, and this repo's own canon is to **enforce invariants with
a test, never prose**. The first three drafts of this ADR violated that rule
while citing it.

Cited sites are named by greppable content rather than line number, since this
change shifts the lines: the comment above the `BUSDRIVER_PI_PROBED_VERSION`
assignment, the `BLOCK, not warn` comment in the pi preflight, and the
`_pi_setup_fail` message containing `IN THIS ORDER`.

Two alternatives were designed and reviewed away. Their reasoning is recorded
because both will be proposed again.

## Rejected: a host-local certification cache

Record certified versions in `$HOME/.claude/busdriver-pi-certified`, so a bump
needs no source edit and no PR.

**Rejected on one ground: it moves the record out of review.** The bump is a
working-tree edit that becomes a merged commit — it appears in `git diff`, is
reverted by `git checkout`, is read by a reviewer, and travels only with its
branch. A line in `$HOME` survives a clean tree, applies to every checkout and
worktree on the host, and no reviewer ever sees it. An early draft of this ADR
claimed "no new power is granted" because a Bash-holding session could edit the
constant anyway. That equivalence is false, and its falseness is the decision:
**for this gate the ceremony is the audit trail, not incidental friction.**

Two arguments that an earlier draft used here are **withdrawn**, because they do
not discriminate between the cache and the ritual being kept:

- *"It is circular."* It is not. Writing a candidate version to the cache, then
  running the live test, then removing it on failure mirrors bump-then-verify
  exactly and needs no new bypass primitive. Recorded explicitly so a future
  proposal is not refuted with a bad argument.
- *"A bare version string omits the resolved binary and the invocation policy."*
  True, and equally true of the constant this ADR keeps. It is a real limitation
  of version-keyed certification in general, not a reason to prefer one store.

A genuine remaining objection, narrower than the above: the cache read would sit
in the pi preflight, where the lane already treats command resolution as
adversarial, and it would be awkward to test offline — the sterile child derives
its home from `id -un` and wipes the environment. That is an implementation cost,
not a disqualification.

## Rejected: a `certify-pi-version.sh` helper

Keep the tracked bump but wrap the three-step ritual in one command. Rejected on
one ground that the retained ritual does **not** share:

**It writes untrusted input into an executable gate script.** The helper would
take the *upgraded* pi's `--version` stdout and write it into a top-level quoted
assignment that is evaluated on every dispatch of every CLI. A release printing
`0.84.3"; <anything>; x="` escapes the assignment. The threat model is precisely
the untrusted upgrade the gate exists to guard against, so the convenience
wrapper would hand it a write primitive into its own guard. A human typing three
characters from a version string does not create that sink.

Its other reviewed defects — an unguarded window between bump and verdict, and a
clean-baseline precondition — are **not** rejection grounds here, because the
manual ritual has the same window by construction (the constant is bumped before
a live test that runs for minutes). They are reasons the helper would need
careful engineering, not reasons to prefer typing.

The deciding judgment is proportionality: a convenience wrapper for a rare event
would need input validation, trap handling, and a git-state precondition, all to
guard a boundary that works correctly today.

## Certification record for 0.84.2

This change set carries the 0.84.1 → 0.84.2 bump, certified by the ritual above
on 2026-08-17 before the constant was committed:

```text
BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
OK:   pi dispatched successfully and could not write under --tools read
      (allowlist enforces, not just advises)
Results: 90 passed, 0 failed, 0 skipped
```

That run is **on this change set**, re-measured after the final review round —
it covers both guards: the comment-site ritual check (one real-file assertion +
two negative fixtures) and the `_pi_setup_fail` message check (one real-file
assertion + two negative fixtures). Without `BUSDRIVER_PI_LIVE=1` the same tree
reports `89 passed, 0 failed, 1 skipped`; the skip is the live containment check.

The count is quoted as a reproducibility check, so it must come from the tree
being shipped — and getting that right took four attempts. Drafts quoted `84`
(the pre-block figure), `85` (real-file check, but *without* the negative
fixtures this ADR calls the real deliverable), and `87` (both, but predating the
`_pi_setup_fail` message guard added in the last review round). Each time the
number was carried forward from an earlier run instead of re-measured, and each
time review caught it by running the suite rather than reading the claim: 84 =
before the block, 85 = partial, 87 = comment guard only, **90 = shipped**. Four
stale counts in one document is itself the argument for quoting only figures
re-measured on the tree being shipped.

## Known limitations of the ritual guard

Stated plainly rather than discovered later:

- **Negation bypass.** Both checks compare order of concepts, so a comment reading
  *"do NOT bump this constant yet. First run `BUSDRIVER_PI_LIVE=1 …`, then bump
  it"* is accepted (`seen=1 bad=0`, reproduced). It catches the drift that
  actually occurs — comments edited into the wrong order — not an author
  deliberately writing a negated instruction.
- **Count, not per-site anchoring.** The floor is `seen >= 2`, so an added
  incidental `BUSDRIVER_PI_LIVE` comment could mask the deletion of a real site.
- **A fourth statement of the ritual is unguarded**, in `docs/adr/0034`. It is
  currently correct — which is more evidence for this ADR's thesis than against
  it, since nothing would catch it drifting.

None of these makes the guards vacuous. The comment-site check rejects the verbatim
historical wording and refuses to borrow the bump concept from an adjacent code line;
the `_pi_setup_fail` message check rejects verify-then-bump ordering and refuses to
read the message's own interpolated `${BUSDRIVER_PI_PROBED_VERSION}` as an instruction
to change it. All four negative fixtures ship and run on every invocation. They are the
boundary of what the guards claim.

**Calibrate what that proves:** write denial at the dispatch CWD under the
production invocation, on this version, on this host. It is not semantic proof of
the `--no-*` flags — the suite deliberately deleted a vacuous assertion for those
(its negative controls could not be produced), and ADR 0034 already records that
residual.

Recorded here because design review found it missing, and it proves the point:
while the bump sat uncommitted, the gate accepted 0.84.2 in this checkout on
nothing but an operator's word. The commit is what turns that into evidence.

## Consequences

- A pi upgrade still takes the lane offline until certified, and still costs a
  commit and a PR. **Unchanged by design** — that is the reviewable record.
- One correct ritual, stated consistently, instead of three statements of which
  two misled.
- The friction is now documented as intentional rather than as an oversight to be
  optimized away.

## Revisit trigger

- If pi releases often enough that the PR-per-bump becomes genuinely painful,
  revisit — but any proposal must answer the auditability ground above, which is
  the only one that survived review.
- If a pi release ever FAILS the live certification, stop and read the diff in
  pi's tool handling before touching the constant. That is the signal ADR 0034
  exists to produce and it must not be papered over.
