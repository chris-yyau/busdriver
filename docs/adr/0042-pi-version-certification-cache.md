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
Results: 119 passed, 0 failed, 0 skipped
```

That run is **on this change set**, re-measured after #696 review rounds 7–10, which
walked the anchor check off a shell-lexer ladder and then closed what the literal
match still left open. Round 7 found its comment-exclusion filter could not fire at
all; round 8 showed the regex anchor alone still counted `if true; then # if [[ … ]]`;
round 9 showed the whitespace-based comment stripper that replaced it still counted
`:;#`, where bash opens a comment directly after a control operator. The check no
longer parses shell in any form: the anchor is a **literal line start**, matched after
trimming surrounding whitespace. Round 10 then showed that a line which *starts*
correctly can still neuter the gate by appending code — `…]]; then :; fi; if false;
then` — so what may FOLLOW the literal is now constrained too: nothing at all for the
gate, and only a double-quoted literal for the constant, whose value must stay free to
change on every certified bump and so is pinned by shape rather than by value. Round
11 then showed that "a quoted value" was too loose a shape: it accepts
`BUSDRIVER_PI_PROBED_VERSION="$(pi --version)"`, which makes the pin dynamically equal
whatever is installed and silently defeats the entire gate. The value must now be a
static version literal — digits, dots and the characters real versions use — which
rejects command substitution, backticks, parameter expansion, escapes and an empty
value without knowing any shell grammar, because none of those are version characters.
Loosen any of these constraints and its fixtures fail, which is what makes them proofs;
three positive controls pin that real version strings (including pre-release and build
metadata) still pass, so the shape cannot quietly become one that rejects everything.
Round 12 closed the last seam in that design: a malformed site was being *skipped*
rather than counted, so a valid pin could coexist with a later
`BUSDRIVER_PI_PROBED_VERSION="$(pi --version)"` — uniqueness saw one site while bash
used the last assignment. Every line that starts with the anchor now counts as a site,
and shape is asserted separately, so shadowing fails on the count and malformation
fails on the shape.

Round 8 also corrected an overclaim about the ADR 0034 check: its container fixtures
prefixed only the FIRST line of the golden block, leaving the substring intact, and so
"proved" a detection that does not occur. A container that re-prefixes EVERY line is
not a byte-identical copy and is not counted. That is now asserted in its true
direction — see Known limitations.

It covers all four guards now shipping: the comment-site ritual check (one real-file
assertion + two negative fixtures), the per-anchor uniqueness check (two real-file
assertions + fourteen negative fixtures + three positive controls), the ADR 0034
golden-block check (one real-file
assertion + one control + six negative fixtures + two residual-direction assertions,
and no Markdown parsing of any kind), and the `_pi_setup_fail` message check (one
real-file assertion + two negative fixtures). Without `BUSDRIVER_PI_LIVE=1` the same
tree reports `118 passed, 0 failed, 1 skipped`; the skip is the live containment check.

The count is quoted as a reproducibility check, so it must come from the tree
being shipped, re-measured on every change that touches this suite — getting
that right the first time around this ADR took four attempts (84 → 85 → 87 →
90, each number carried forward from an earlier run instead of re-measured,
each time caught by review running the suite rather than reading the claim).
That history is why this record is re-measured on every touch rather than
copied forward: 90 was correct for the tree ADR 0042 originally shipped, 98 was
correct for the #692 follow-up's first commit, 102 after the first round of PR
review fixes, and 107 for the tree that still carried the CommonMark fence
parser — all stale for the tree shipping now — **119 = shipped now** (live; `118`
without `BUSDRIVER_PI_LIVE=1`).

**The CommonMark parser is gone.** Three rounds of #696 review walked a hand-written
fence/container state machine through tilde runs, info strings, indentation, block
quotes, list markers and lazy continuations, and each round found another construct it
mishandled — in both directions: a fenced decoy accepted, and real prose hidden. That
ladder has no last rung, and a parser that looks thorough while missing a construct is
precisely what made ritual guards v1–v3 vacuous. The check now holds a verbatim
golden copy of the ritual block and requires that exact block to appear exactly
once, anywhere in the file. It does not look at the marker phrase on its own — a
paraphrase that keeps the phrase but changes the instruction is simply absent, and
fails at zero. A decoy cannot
hide in a code block, because a fence preserves the block byte-for-byte and so makes
the count two and FAILS. The cost is that
the ADR may not quote its own ritual sentence in an example — deliberate, and the
fail-closed direction.

## Known limitations of the ritual guard

Stated plainly rather than discovered later:

- **Negation bypass.** Both order-comparing checks (comment-site and
  `_pi_setup_fail`) compare order of concepts, so a comment reading
  *"do NOT bump this constant yet. First run `BUSDRIVER_PI_LIVE=1 …`, then bump
  it"* is accepted (`seen=1 bad=0`, reproduced). It catches the drift that
  actually occurs — comments edited into the wrong order — not an author
  deliberately writing a negated instruction.
- **Per-anchor uniqueness, not full attribution (#692 follow-up).**
  `_ritual_anchor_check` (dispatch.sh) and the new `_adr_check` (docs/adr/0034)
  now assert each code anchor / prose marker is unique (`found != 1` fails
  closed) plus presence of a correctly-ordered ritual mention nearby. That
  closes the pure count-floor gap: a deleted site can no longer be masked by
  an incidental mention elsewhere in the whole file. It does **not** prove the
  covering comment is that anchor's *own* comment — an unrelated,
  correctly-ordered comment within the lookback window still satisfies
  presence. Two review rounds tried full attribution (context windows,
  prior-anchor clamps, decoy-word disambiguation) and each found a new
  misattribution to exploit; it was abandoned for the same "no completion
  point over free text" reason the negation bypass above is accepted, not
  chased. Comment exclusion is carried by matching a **literal line start** rather
  than a regex, with no comment handling at all: the anchor must be the first thing
  on the line once leading whitespace is stripped. Rounds 6–9 each found another
  shell spelling that hid the gate text in a comment while still matching a regex —
  a trailing `# if [[ … ]]`, an `if true; then # …` whose executable prefix itself
  begins with `if`, and `:;#`, where bash opens a comment straight after a control
  operator with no whitespace. Recognising comments needs a shell lexer and that
  ladder has no last rung, which is the same conclusion the ADR 0034 check reached
  about Markdown; requiring the line to *begin* with the literal ends it, because a
  commented copy begins with `#` and a smuggled one begins with the code before the
  `#`. A round-7 skip-commented-lines filter and a round-8 comment stripper were both
  removed on the way to this. What may FOLLOW the literal is constrained as well
  (round 10), because a line that starts correctly can still neuter the gate by
  appending code (`…]]; then :; fi; if false; then`): nothing may follow the gate, and
  only a static version literal may follow the constant — pinned by shape, not value,
  so the certified-bump ritual keeps working. Round 11 tightened that shape: "any
  quoted value" accepted `"$(pi --version)"`, which would have made the pin equal the
  installed version and defeated the gate entirely. Round 12 then made a malformed
  site COUNT as a site rather than be skipped, so a valid pin shadowed by a later
  dynamic assignment fails on uniqueness instead of passing. What remains is that it proves the line's *text* and
  uniqueness, not that it is executable shell: with the real gate deleted, a heredoc
  body holding that exact line would still be counted. Proving executability needs
  that same shell parser — declined for the same reason.
- **`docs/adr/0034`'s fourth ritual statement is now guarded** by `_adr_check`,
  which holds a **verbatim golden copy** of the ritual block and requires it to
  appear in the document **exactly once**. There is no Markdown parsing of any
  kind — no fence, container, indentation or block-boundary logic — because four
  rounds of review showed every such state machine had another construct it
  mishandled, in both directions. Counting exact occurrences makes containers
  unnecessary: a BYTE-IDENTICAL copy anywhere — inside a fence or bare — is simply a
  second occurrence and fails, and a document whose real block was replaced by a
  paraphrased example fails at zero. **A container that re-prefixes every line** (a
  real block quote, or an indented code block) is *not* byte-identical and is
  therefore not counted — round 8 corrected an earlier claim to the contrary, whose
  fixtures had prefixed only the first line. That is out of scope rather than a hole:
  deletion still fails at zero, drift still fails, and a re-prefixed quotation
  standing beside an intact real block leaves the correct instruction in place. It also rejects the loosenings
  a pattern match would admit — `BUSDRIVER_PI_LIVE_DISABLED` for
  `BUSDRIVER_PI_LIVE=1`, or `xBUSDRIVER_PI_PROBED_VERSION_OLD` for the constant.
  The cost is deliberate: the ADR may not quote its own ritual sentence in an
  example, and any legitimate rewording must update the golden literal in the
  same commit — which is the point, since silent rewording is the drift this
  guard exists to catch. This check **inherits the negation-bypass
  limitation** above, and #696 review round 5 demonstrated it concretely: the golden
  block is matched as a substring, so prefixing it with `DO NOT ` still satisfies the
  check. The golden literal pins the wording of the statement itself; it says nothing
  about text surrounding it. Closing that would require deciding whether neighbouring
  prose negates the instruction — the unbounded attribution problem gap 1 is WONTFIX
  for. Same accepted residual, same reason: the threat model is accidental drift, not
  an author deliberately negating their own repo's instruction.

None of these makes the guards vacuous. The comment-site check rejects the verbatim
historical wording and refuses to borrow the bump concept from an adjacent code line;
the `_pi_setup_fail` message check rejects verify-then-bump ordering and refuses to
read the message's own interpolated `${BUSDRIVER_PI_PROBED_VERSION}` as an instruction
to change it. All four of those two checks' negative fixtures ship and run on
every invocation. They are the boundary of what the guards claim.

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
