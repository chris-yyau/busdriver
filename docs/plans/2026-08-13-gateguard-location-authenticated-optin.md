# DESIGN: GateGuard consent moves from an env var to an out-of-tree operator marker (#616, unblocks #629)

**Status: PARKED — do NOT implement from this document as written.**
Blueprint-review round 1 FAIL (2 high / 10 medium); round 2 FAIL (3 high / 10 medium);
round 3 FAIL (6 high — 5 plan-blocking — / 7 medium / 3 low, coverage FULL 3/3). Round 3 was
run after the three round-2 blockers were answered in the **header only**; the body below is
still the round-2 design, and that is most of what round 3 found. It also found that
**resolution 1 below is aimed at the wrong component** (see its correction note) and that
**step 1 inverts the fail direction** — a new defect, not a leftover.

What is durable and reusable from this round: the five-channel inventory, resolution 2
(containment belongs at the launch condition), resolution 3 (drop the revocation hint), and
the three round-3 findings recorded under **Round 3** below. Round 4 is a rewrite of the
change list, not another header pass. See the three #616 comments of 2026-08-11/13.

**The scope grew while resolving them.** The env-channel inventory is **five**, not one, and
one of them (`ECC_HOOK_PROFILE`) disables the gate *by default*. A build that closes only
`ECC_GATEGUARD` and calls #616 done is a confidence regression, not a fix.
**Issues:** closes #616, unblocks #629
**Review artifacts:** `docs/reviews/gateguard-location-authenticated-optin/`
(`claude.json` = round-2 arbiter verdict, FULL 3/3 coverage, `executed_model: opus`).

### Resolutions — the three round-2 blockers, and how each was settled

Round 2 removed round 1's inverted fail-direction, but surfaced that **#616 is not a
two-line registration change**. Containment breaks more of GateGuard than the consent
channel. Round 2 recorded the three below as needing an operator call. **All three are now
resolved, and none of them was a product decision — each was an empirical question.**
**Round 3 refuted that for blocker 1**: two of the three hold, blocker 1's answer does not.

| # | round-2 blocker | resolution |
|---|---|---|
| 1 | resolver contract vs test-fixture contract | **STILL OPEN.** The "dissolved by decision 2" answer below targets the wrong component — see the correction note under it |
| 2 | scope escalation: may #616 rework the state-dir model? | **Not separable.** Containment must move to the launch condition (ADR 0016). It is in scope by necessity |
| 3 | recovery hint becomes a model-executable off-switch | **Drop the revocation hint.** Keep compliance. Neither stderr nor a marker path |

**The full env-channel inventory (five, verified).** Round 2 knew of two; three more surfaced:

| channel | location | note |
|---|---|---|
| `ECC_GATEGUARD` | `:438` | the one #616 was filed against |
| `GATEGUARD_DISABLED` | `:434` | checked **first**, independent |
| `GATEGUARD_STATE_DIR` | `:35` | module-load `const`; blocker 2's channel |
| `ECC_DISABLED_HOOKS` | `run-with-flags.js` | hook-level disable |
| `ECC_HOOK_PROFILE` | `hooks.json:151/161` | **skips registration entirely; `standard` is the default** |

The last is the worst: it is evaluated in the uncontained outer shell before `env -i` could
apply, and the hook's allowlist is `strict` alone — so a committed `settings.json` setting
the profile to `standard` switches the gate off without naming any `GATEGUARD_*` variable.
V1 and V9 already pin three of the five; extend both to cover all five.

The original round-2 statements of each blocker are retained verbatim below as the record of
what was actually wrong, each followed by its resolution.

1. **The resolver contract and the test fixture contract are mutually exclusive** (0.97).
   Step 2 requires HOME be re-derived from passwd and *never* read from the environment;
   step 7's fixture needs a temp HOME. A resolver that never reads `$HOME` cannot see one —
   on the contained path *or* under vitest. So every deny-expecting assertion in
   `__tests__/gateguard-multiedit.test.ts` flips to allow (silently unguarding the #615
   regression) unless tests write the operator's real `~/.gateguard`. The obvious escape —
   a `GATEGUARD_HOME` test override — reopens the exact env consent channel #616 closes.
   **RESOLVED — a fixture strategy that needs none, and blocker 2 already pays for it.**
   The dilemma is an artifact of `:35` being a **module-load `const`**: with the state dir
   fixed at require time from the environment, there is no seam to inject a home directory,
   so the only escapes are an env override or writing the operator's real `~/.gateguard`.
   But blocker 2 *requires* replacing that constant (it is itself an env off-switch). Once it
   is a **use-time resolver** rather than a require-time constant:
   - production calls it with no argument and derives HOME from passwd (`getent`/`dscl`,
     mirroring `sanitized-node.sh:59-67`);
   - tests call it with an explicit temp directory **as a parameter**.

   No `GATEGUARD_HOME`, no env channel, no writing to the operator's real home, no carve-out
   to document. Note the sibling suites are *not* a template here:
   `tests/test-gate-env-containment.sh:21/88/107` snapshots `REAL_HOME`, poisons `HOME`, and
   asserts the poison is **ignored** — those tests never need a temp HOME to *work*, so they
   never hit this. GateGuard's fixture is different because it must **create** a marker at the
   resolved location.

   > **Round-3 correction — the paragraph above answers the wrong component.** The consent
   > marker is not read by `gateguard-fact-force.js:35`. It is read by the **shell** resolver
   > this design introduces at step 2 (`scripts/gateguard-optin.sh`), whose pinned contract is
   > "print exactly `1` or `0`" and which **takes no home parameter** — by construction, since
   > step 2 requires it derive HOME from `getent`/`dscl` and never from the environment.
   > `:35`'s `STATE_DIR` is GateGuard's *session state* directory, a different thing; making it
   > a use-time resolver closes blocker 2's env channel and does nothing for blocker 1.
   > So all 8 deny assertions in `__tests__/gateguard-multiedit.test.ts` still flip to allow.
   > The real question is unchanged and unanswered: **what seam lets a test point the shell
   > resolver at a temp home without giving production one?** Candidates not yet evaluated —
   > an explicit positional argument on the resolver (production passes none), or testing the
   > resolver directly in the shell suite and stubbing it at the JS boundary. Note the JS-side
   > `:35` fix is still required for blocker 2; it is simply not this.

2. **A second env off-switch survives on the uncontained path** (0.95).
   `gateguard-fact-force.js:35` reads `GATEGUARD_STATE_DIR || HOME || USERPROFILE` at module
   load. With a valid marker but an uncontained invocation, `GATEGUARD_STATE_DIR=/dev/null`
   makes the `mkdirSync` at `:527` fail, `run()` returns `allowWithStateWarning()` (`:793`),
   and the runner maps that to a pass-through allow. The design asserts the no-dormant-read
   invariant one paragraph before violating it. Fixing it means reworking the hook's state
   location, not deleting a read — and under `env -i` + `cd /` the fallbacks collapse
   (`resolveSessionKey()` loses every env fallback; `process.cwd()` is literally `/`), so
   session-less payloads share one machine-wide state file.
   **RESOLVED — not separable; the rework is in scope by necessity.** Splitting it out would
   leave #616 closing one of five channels while the repo believes the gate is contained —
   strictly worse than not shipping. ADR 0016 already settles where the fix belongs:
   *"a per-script scrub cannot be trusted … containment has to happen above the scripts."*
   GateGuard is currently the one node gate launching bare `node` rather than
   `/usr/bin/env -i` + `sanitized-node.sh`, and `ECC_HOOK_PROFILE` is evaluated in that
   uncontained outer shell before any scrub could apply. So the containment move is the
   primary change, not an escalation from it — and the state-dir rework falls out of it,
   because `:35`'s module-load read is one of the channels being closed.

   The `env -i` + `cd /` collapse this blocker describes (`resolveSessionKey()` losing every
   env fallback, `process.cwd()` becoming `/`) is real and remains a design obligation of the
   rework: session-less payloads must not share one machine-wide state file. Round 3 must
   specify the replacement session key, not merely delete the env read.

3. **The recovery hint becomes a model-executable, persistent off-switch** (0.90).
   `withRecoveryHint()` is appended by `denyResult()` (`:786`) into
   `permissionDecisionReason` — text the **model** reads on every deny. Today's hint
   (`ECC_GATEGUARD=off`) is session-env advice the model cannot apply to a running session,
   so it is effectively addressed to the human. Step 6's replacement is a single `rm` the
   model can run immediately, and it revokes consent for **every future session** in that
   repo. That hands the model exactly the switch this design exists to deny it. (It is also
   unimplementable as written: the pinned `1`/`0` resolver contract cannot supply the HOME
   or hash to interpolate.)
   **RESOLVED — drop the revocation hint. Keep the compliance hint. Not stderr, not a path.**
   Settled by an ultimate-council (5 voices + UltraOracle + Mythos Witness), unanimous against
   the going-in position, which was "route it to stderr".

   The block message conflates **two** instructions to two different parties: a *compliance*
   hint (~`:750`, "present the facts, then retry the same operation") telling the constrained
   party how to **satisfy** the gate, and a *revocation* hint (`:758` → `:786`) telling it how
   to **turn the gate off**. Only the second is the defect. The model's recovery path is
   satisfying the gate, so "a gate that blocks with no recovery path is an operator support
   burden" does not apply to the model at all.

   **Why not stderr, despite a clean measurement.** A probe with a positive control confirmed
   that on the exit-0 JSON-decision path — GateGuard's exact path — hook stderr does not reach
   the model while stdout `hookSpecificOutput.additionalContext` does. True, reproducible, and
   still the wrong basis: the property is **path-conditional** (the exit-2 contract feeds
   stderr back to the model, so one refactor silently inverts it), and for a solo operator
   nobody reads that stream, so routing is dropping with extra complexity.

   **And hint text is not the boundary anyway** — `skills/gateguard/SKILL.md:207` already
   publishes `ECC_GATEGUARD=off` (or `GATEGUARD_DISABLED=1`) to the model. Sanitizing `:763`
   while that ships is cosmetic. Drop the hint because a blocked model should not be *coached
   toward revocation at the moment of friction*, not because it hides anything. **Delete the
   `SKILL.md:207` recipe in the same change**, or the removal is theatre. V8 already pins the
   deny output; extend it to assert no marker path and no `GATEGUARD_*` name either.

   *Exploratory, deliberately not adopted here:* an operator channel via the synchronous
   top-level `systemMessage` field (UltraOracle's proposal — unverified locally, wants the same
   positive-control probe), and a bypass-grant lease built on `lease_slot.py`'s existing
   `min_age` anti-self-bypass floor. Note the polarity: lease the **negative bypass grant**,
   never the positive enablement — a lease on consent fails open when it expires.

Everything below is the round-2 design. Its direction was confirmed sound by the arbiter; its
contracts were not.

### Round 3 (FAIL) — what a round 4 has to fix

Round 3 reviewed the header-only revision above. Coverage FULL 3/3; 6 high (5 plan-blocking),
7 medium (2 plan-blocking), 3 low; 6 issues deferred to
`docs/reviews/gateguard-location-authenticated-optin/follow-up-issues.md`.

**Findings the arbiter confirmed against the codebase:**

| # | finding | where |
|---|---|---|
| 1 | **Step 1 inverts the fail direction.** It adopts `sanitized-node.sh` while deleting the shell `case` guard whose documented purpose is preventing exactly this (`skills/gateguard/SKILL.md:171-176`). Node-not-found, the `\|\| exit 2` launch failure, and `enforceTruncation` (`run-with-flags.js:195-206`) then hard-block every Edit/Write/Bash in **marker-absent** sessions — the precise inverse of this document's stated fail-open direction. Same class as round 1's polarity error, in a new place | step 1 |
| 2 | Step 6 still recreates the revocation hint that resolution 3 orders deleted (`:758-764` → `:776-790`), and `skills/gateguard/SKILL.md:206-208` is still live | step 6 |
| 3 | No change-list step replaces the state dir or the session key — resolution 2's obligation is stated in the header and absent from the body | steps 1-8 |
| 4 | Consent is keyed to `data.cwd` while the gate acts on `file_path` — an undeclared scope change | step 2 |
| 5 | `ECC_HOOK_PROFILE=minimal` silently stops disabling the gate | step 1 |
| 6 | Blocker 1's fixture problem is unresolved (see the correction note above) | step 7 |

**Not adopted, on evidence:** grok's remedy of adding GateGuard to the `CONTAINED` list in
`tests/test-node-hook-containment.sh` would turn guard #4 red — verified by running the grep
the guard runs. The `#629`-sequencing paragraph below stands as written.

**Still to fold in from the header:** the five-channel inventory (V1/V9 pin three), the
launch-condition containment move as the primary change, `:35` as a use-time resolver
(blocker 2 only), the `SKILL.md:207` deletion, and a replacement session key for the
`env -i` + `cd /` collapse.

**Operator decision already taken:** option **(b)** of the
[#616 comment of 2026-08-11](https://github.com/chris-yyau/busdriver/issues/616) —
"location-authenticated opt-in". This document specifies it. It does not re-open that choice.

> **Iteration-1 correction, recorded because it was the whole point of reviewing.**
> Round 1 proposed a per-repo marker at `<main-root>/.claude/gateguard-enabled.local`,
> validated by cloning `scripts/advisory-downgrade-optin.sh`'s `_repo_controlled` check, and
> claimed "even the DoS is closed". That was **backwards**. That check maps a tracked marker
> to `0`, and for advisory-downgrade `0` means *deny the privilege* (safe) while for GateGuard
> `0` means *gate OFF*. So a PR running `git add -f .claude/gateguard-enabled.local` would have
> made the resolver print `0` and **silently retired the operator's gate** — manufacturing
> precisely the off-switch #616 exists to remove. Codex rated it high, Grok medium, the arbiter
> confirmed at 0.98. The polarity of a consent check is not portable between a gate that grants
> a privilege and a gate that imposes friction; iteration 2 removes the shared polarity rather
> than re-tuning it.

---

## Context

`scripts/hooks/gateguard-fact-force.js` is registered twice in `hooks/hooks.json`
(lines 151, 161) as a **blocking** PreToolUse gate. Unlike the five security gates it is
invoked with bare `node`, not through `/usr/bin/env -i … hooks/gate-scripts/lib/sanitized-node.sh`,
so the ADR 0016 / #325 env channel is open on it: `GATEGUARD_DISABLED`, `ECC_GATEGUARD`,
`ECC_DISABLED_HOOKS` and `ECC_HOOK_PROFILE` are all readable from a committed
`.claude/settings.json` `env` block.

Four readings of the fix are wrong. Each is recorded because the next person will propose one:

| Proposal | Why it fails |
|---|---|
| Re-import `ECC_HOOK_PROFILE` into the containment prefix (Cubic, on #613) | Swaps one off-switch for another. `getHookProfile()` (`scripts/lib/hook-flags.js:19`) reads it from `process.env`, GateGuard's allowlist is `strict` alone, so a committed `env` block setting `ECC_HOOK_PROFILE=standard` still switches it off. Independently the outer `case "${ECC_HOOK_PROFILE:-standard}"` guard runs in the **uncontained** shell, before `env -i` applies. |
| Plain containment, no re-import | `env -i` wipes the profile, `getHookProfile()` falls back to `standard`, and a hook allowlisted to `strict` never fires — a guard that cannot fire, which reads as coverage. |
| Re-import `BUSDRIVER_STATE_DIR` (Agy, round 1, its only HIGH) | Reintroduces the same class of channel. The variable is read from the environment at `advisory-downgrade-optin.sh:42`; a hostile repo setting `BUSDRIVER_STATE_DIR=nonexistent` gets an env off-switch on the gate whose purpose is to have none. The wipe is correct behaviour. This design **pins** the location instead of reading any env var. |
| A per-repo in-tree marker (this document, iteration 1) | The inversion quoted above. |

The bypass is **not a plumbing defect. It is a consent-channel choice.** This repo has already
settled that an env var is a repo-injectable consent channel (ADR 0016 / #325; the
advisory-downgrade decision's "**no** global env-var / global-file switch by design").

## Decision

Consent moves **out of the repository namespace entirely**, into the operator's
passwd-derived HOME, and GateGuard is contained under `env -i` like the other blocking gates.

Enablement marker:

```
<passwd-HOME>/.gateguard/enabled/<sha256(realpath(main-worktree))>
```

The file's *content* is the plaintext main-worktree path, for human audit and for
`--list` output. Only its *existence* is consulted.

### Why out-of-tree dissolves the round-1 defect rather than patching it

There is no longer a "marker is repo-controlled" case to adjudicate, so there is no polarity
to get backwards. A PR is a set of tracked files; it cannot create, delete, or modify anything
under the operator's passwd HOME. `sanitized-node.sh:56-70` already re-derives HOME from
`getent`/`dscl` rather than the inherited value, precisely so a poisoned `HOME` cannot steer
the wrapper — this design reuses that established root, and the same re-derivation is what
makes the marker unreachable from the repo.

Consequences that follow, each replacing a round-1 mechanism rather than adding to it:

- **`_repo_controlled` is not cloned at all.** Neither are the index/HEAD/gitlink checks. The
  round-1 "near-clone of a 129-line security-sensitive script" — and its maintainability
  finding about a third copy drifting from `resolve-repo-dir.sh` — simply does not arise.
  The resolver keeps only what it still needs: main-worktree resolution and a file test.
- **`BUSDRIVER_STATE_DIR` is not read.** The location is pinned. An uncontained future
  invocation cannot be steered by it either.
- **A `git add -f` of any in-tree file named `gateguard-enabled.local` has no effect
  whatsoever** — nothing reads that path. This is asserted, not assumed (V7).

### Fail direction, stated precisely

Marker absent, HOME underivable, repo unresolvable, resolver missing or erroring
⇒ **gate OFF** (allow, exit 0).

That is fail-*open* in the literal sense, and it is correct **only** because of what GateGuard
is: it guards no boundary, it improves output quality. Its default today is already off.

The property protected here is the inverse of a security gate's: not "a repo must not switch
this ON without consent" but **"a repo must not switch the operator's chosen gate OFF"**.
Out-of-tree consent achieves that directly.

The residual is **DoS-shaped, not bypass-shaped** — and this time the mechanism supports the
claim: forcing the gate *on* requires writing the operator's HOME, which a PR cannot do; and
were it somehow written, a more aggressive fact-forcing prompt is friction, not a bypass.

**This reasoning does not generalize.** It licenses an off-by-default, fail-open marker for
GateGuard *because* GateGuard is not a boundary. Do not cite this document for
`block-no-verify`, `config-protection`, `pre-bash-dev-server-block`, or `mcp-health-check`.

## Change list

1. **`hooks/hooks.json` lines 151, 161.** Drop the outer `case` guard and the `"strict"`
   profile argument; adopt the containment prefix the five security gates use, passing
   `"standard,strict"` so the wiped profile cannot retire the gate:

   ```
   /usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" \
     CLAUDE_HOOK_EVENT_NAME="$CLAUDE_HOOK_EVENT_NAME" \
     bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-node.sh" \
     "pre:edit-write:gateguard-fact-force" "scripts/hooks/gateguard-fact-force.js" \
     "standard,strict" || exit 2
   ```

   `|| exit 2` is retained: it is what makes the registration legible to #629's
   registration-derived discovery. **`BUSDRIVER_STATE_DIR` is deliberately not forwarded.**
   Both entries' `description` fields (`:154`, `:164`) currently say "The case guard and the
   `strict` arg are deliberately redundant" — both are rewritten, since step 1 deletes both.

2. **New resolver `scripts/gateguard-optin.sh`.** Prints exactly `1` or `0`; always exits 0.
   Not a clone of `advisory-downgrade-optin.sh` — it shares only the main-worktree resolution:

   - Derive HOME from `getent`/`dscl` (mirroring `sanitized-node.sh:56-70`), **never** from
     the inherited value. Underivable ⇒ `0`.
   - Neutralize repo-supplied git-environment injection: unset the *discovery* variables
     `GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
     GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE`.
     **Do not** carry `advisory-downgrade-optin.sh:38-40`'s treatment of `GIT_CONFIG*`
     verbatim: that line *unsets* `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`, which inside a
     `sanitized-node.sh` child would re-enable `~/.gitconfig` for our own `git` calls and
     undo the deliberate neutralization at `sanitized-node.sh:53-54`. Instead
     `export GIT_CONFIG_GLOBAL=/dev/null; export GIT_CONFIG_SYSTEM=/dev/null`, with a comment
     naming the divergence so the "keep in sync" relationship stays legible.
   - Resolve the **main worktree** as the first `git worktree list --porcelain` entry — *not*
     `git rev-parse --show-toplevel`. This repo develops in linked worktrees under
     `.claude/worktrees/` (this very review runs from one), and `--show-toplevel` would key
     each worktree to a different identity. Unresolvable ⇒ `0`.
   - `realpath` it, sha256 it, test for a **non-symlink regular file** at
     `<HOME>/.gateguard/enabled/<hash>`. Present ⇒ `1`, else `0`.
   - `STATE_DIR` and every other env-derived path input: **not read.**

3. **New helper `scripts/gateguard-enable.sh`** — `--on` / `--off` / `--status` / `--list`,
   operating on the current repo's main worktree. This is not polish: step 1 deletes
   `ECC_HOOK_PROFILE=strict claude`, the only documented way to turn GateGuard on today
   (`skills/gateguard/SKILL.md:105-109`), so without an enrollment path the change is a
   silent capability removal for strict-profile users. The helper prints the resolved
   main-worktree path and hash so enrollment is auditable.

4. **`scripts/hooks/gateguard-fact-force.js`.** Replace `isGateGuardDisabled()`'s two
   `process.env` reads (`:434` `GATEGUARD_DISABLED`, `:438` `ECC_GATEGUARD`) with a
   positively-named `isGateGuardEnabled(cwd)`. Renaming the predicate positive matters: the
   absent-marker default must read as OFF at the call site.

   **The JS↔resolver contract is specified here, not left to the implementer** — round 1
   left every axis open and the arbiter rated that a medium on its own:

   - Parse the payload **first**, then call `isGateGuardEnabled(data.cwd)`. (`isGateGuardDisabled()`
     is called at `:810`, after the parse at `:801-806`, so this ordering already holds.)
   - Require `typeof data.cwd === 'string' && path.isAbsolute(data.cwd)`, else OFF —
     the house rule `config-protection.js:83-93` already establishes, for the same reason.
   - Resolver path `path.join(pluginRoot, 'scripts/gateguard-optin.sh')`, **absolute**: a
     relative path is ENOENT from the wrapper's `cd /`.
   - Invoke shell-free (`execFileSync`) with `{ cwd: data.cwd, timeout: <bounded> }`.
   - Accept **only** an exact `1` after trim.
   - **Total by construction:** wrap in try/catch and treat spawn error, non-zero status,
     signal, timeout, and any other stdout as OFF. This is load-bearing, not defensive
     habit: `sanitized-node.sh:193` appends `--fail-closed`, `run-with-flags.js`
     `failOpenExitCode()` (`:117`) turns a thrown `run()` into **exit 2**, and the runner
     catches at `:288-300`. So an uncaught throw in the consent check would hard-**block**
     the user's tool call — the exact opposite of this document's stated fail direction.

5. **Delete the env off-switches outright**, not merely stop consulting them. Under `env -i`
   they are moot, but a dormant `process.env` read on a blocking gate is a live off-switch
   the moment anything invokes the hook uncontained, and it reads as a supported control.

6. **Retire every surface that still advertises the deleted switches.** Round 1 scoped this
   to `skills/gateguard/SKILL.md:103-158` and missed three:
   - `withRecoveryHint()` (`gateguard-fact-force.js:758-764`) appends "run this session with
     `ECC_GATEGUARD=off` or add `<hookId>` to `ECC_DISABLED_HOOKS`" to **every deny the model
     sees**. Under `env -i` that is an instruction for an action that silently does nothing.
     Replace with "remove `<HOME>/.gateguard/enabled/<hash>`" (or `gateguard-enable.sh --off`).
   - `skills/gateguard/SKILL.md:103-208` in full — including the `ECC_HOOK_PROFILE=strict claude`
     enable instruction (`:105-109`), the three switches repeated at `:207-208`, and the entire
     "shell guard skips; it never enables" rationale (`:160-204`) that step 1 invalidates. Its
     current text also instructs *against* this change ("Do not 'harden' this into
     `sanitized-node.sh` …") — correct against plain containment, wrong against this design,
     and a booby-trap if left.
   - Both `hooks.json` descriptions (step 1).

7. **`__tests__/gateguard-multiedit.test.ts`.** It passes `GATEGUARD_STATE_DIR`,
   `GATEGUARD_DISABLED: '0'`, `ECC_GATEGUARD: '1'` on every invocation (`:41`) and its payloads
   carry no `cwd` (`:61-70`). Under this design all eight deny-expecting assertions flip to
   allow, silently unguarding the #615 MultiEdit regression this suite exists to lock in. New
   fixture contract: a temp git repo, an enabled marker in a temp HOME, that repo's absolute
   path as `payload.cwd`, the deleted env switches removed, plus a marker-absent allow case —
   without weakening the first-touch, retry, MultiEdit, or subagent assertions. Note that
   `GATEGUARD_STATE_DIR` isolation is unavailable on the contained path, so contained
   integration tests isolate by `session_id`.

## Verification

Each row names an observation that must be **seen**, not merely written — a guard whose
failure branch has never been observed is not a guard.

| # | Assertion | Must be observed failing against |
|---|---|---|
| V1 | Contained registration + absolute payload `cwd` at an enabled fixture repo + first-touch Edit payload + fresh `session_id`, with `ECC_HOOK_PROFILE=standard`, `ECC_DISABLED_HOOKS`, `GATEGUARD_DISABLED=1` all injected ⇒ **process exit 0** AND stdout parses to `hookSpecificOutput.permissionDecision === "deny"` | the pre-change tree, where any one of the three switches it off |
| V2 | Marker absent ⇒ exit 0 with **no** deny decision (payload echoed back) | a build that inverts the fail direction |
| V3 | Marker present, resolver run with cwd `/` (the wrapper's `cd /`) ⇒ **test fails**, pinning the payload-cwd requirement | an implementation using `process.cwd()` |
| V4 | Resolver deleted / non-executable / timing out ⇒ tool call still **allowed**, never blocked | an implementation without the try/catch of step 4 |
| V5 | `git add -f` an in-tree `.claude/gateguard-enabled.local`, marker enabled out-of-tree ⇒ gate **still fires** | the iteration-1 design, where this was the off-switch |
| V6 | Marker keyed to the main worktree ⇒ resolves `1` from **both** the main checkout and a linked worktree; a marker keyed to a linked worktree ⇒ `0` | a resolver using `git rev-parse --show-toplevel` |
| V7 | `BUSDRIVER_STATE_DIR=/nonexistent` injected at session level ⇒ contained gate still fires (injection wiped/ignored) | a build that forwards or reads it — this is the **inverse** of Agy's round-1 V7, which would have pinned the defect |
| V8 | Deny output contains no `ECC_` env-var instruction | the pre-change `withRecoveryHint()` |
| V9 | Strict profile + no marker ⇒ OFF; standard profile + marker ⇒ ON — neither relying on the deleted env vars | the pre-change tree, where the profile is the switch |
| V10 | `npm test` green, `__tests__/gateguard-multiedit.test.ts` included | the un-migrated fixture (all eight denies flip to allow) |
| V11 | The other four contained gates unaffected | `test-gate-env-containment.sh`, `test-node-hook-containment.sh` |

V4, V5 and V7 are the three that would have shipped broken from iteration 1.

## Sequencing, and the #629 coupling

Round 1 called step 3 "green on arrival". That was wrong, and no reviewer caught it — the
arbiter did. `tests/test-node-hook-containment.sh` guard #4 (`:122-133`) asserts that every
member of its `CONTAINED` array is still found by the **source-level** `discover_exit2()` grep
(`:93-98`: `process.exit(2)`, `exitCode: 2`, `? 0 : 2`). `gateguard-fact-force.js` contains
none of those tokens — it denies via `exitCode: 0` + `permissionDecision`. So adding it to
`CONTAINED` turns guard #4 **red**, while leaving it out means guard #1 never covers it.

Therefore, explicitly:

1. This document → blueprint-review.
2. **#616 does not touch `tests/test-node-hook-containment.sh`.** Its own new tests (V1-V11)
   cover the wrapping. The containment suite stays exactly as green as it is today.
3. **#629 replaces both `discover_exit2()` and guard #4** with registration-derived detection
   (`|| exit 2` / `--fail-closed` in `hooks.json`), which is what makes a
   permissionDecision-blocking hook classifiable at all — and only then adds GateGuard.

That ordering is what keeps both PRs green at every point. It is a change from round 1's
claim that the two are cleanly separable: they are sequential, and #629 owns the suite change.

## What this does NOT do

- **It does not make GateGuard always-on.** That was option (a) — it would deny on first touch
  of every file in ordinary sessions, an operator-experience change not asked for.
- **It does change strict-profile behaviour**, and the loss would otherwise be silent. A
  session launched `ECC_HOOK_PROFILE=strict claude` loses GateGuard until enrolled via
  step 3's helper. Stated here because a gate that stops firing is indistinguishable from a
  gate that is working.
- It does not touch the four other contained gates or `sanitized-node.sh`. #616's body claimed
  this needs a "shared allowlist contract change"; its own comment thread corrected that — the
  wrapper has **no** trusted-var allowlist, the re-import is written per-registration in
  `hooks.json`, so this edits GateGuard's two lines and nothing else.
- It does not land #629.
