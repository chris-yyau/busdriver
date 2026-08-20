# DESIGN: GateGuard consent moves from an env var to an out-of-tree operator marker (#616, unblocks #629)

**Status: REVIEWED — PASS, FULL coverage (3/3 lenses), on the reduced design.** The gate
marker at the foot of this file is the machine-readable record; this line must never
contradict it, because a reader who trusts the prose over the marker (or vice versa) gets
the opposite answer about whether implementation may proceed.

**The enrollment CLI is no longer in this document.** `scripts/gateguard-enable.js` and its
verification rows (V17, V17b, V17d, V18, and V17c's CLI half) moved to
[#712](https://github.com/chris-yyau/busdriver/issues/712). What remains is the containment
core: the wrapper's `--fail-open` contract (step 1), the two contained registrations (step 2),
the shared consent resolver (step 3), and the hook changes (step 5), plus the documentation,
test and measurement obligations those carry. Enrollment until #712 lands is a **manual
operator procedure**, specified in change-list step 4.

Why the split, in the terms the review history gives: across rounds 5-22 the containment core
converged — HIGH has been 0 for the last four rounds and every arbiter since R4 recorded the
direction as sound — while the CLI did not. Rounds 16, 17 and 18 each parked or failed on a
plan-blocking HIGH located in text written to fix the previous round, and **all three were the
same CLI feature**, `--on`'s work-tree check. Round 22's five mediums split the same way: two
(`--repo`'s residual node-startup cwd vector, and `main(argv)`'s unpinned exit/IO contract) are
CLI-only and travel to #712 with the code they describe. The three that remain — the
contained-lane cleanup contradiction, the unpinned benchmark unit, and the shared-primitive
interface question — are fixed here.

Round history, retained as context: R1 FAIL (2H/10M) · R2 FAIL (3H/10M) · R3 FAIL (6H, 5
plan-blocking) · R4 FAIL (4H/11M, 3+6 plan-blocking) · R5 FAIL (6H/11M/3L, 2+6) · R6 FAIL
(2H/11M/4L, **0**+6) · R7 FAIL (1H/17M/11L, 1+7, coverage DEGRADED) · R8 FAIL (0H/25M/6L,
**0**+14, coverage DEGRADED) · R9 FAIL (1H/15M/8L, **0**+7) · R10 FAIL (1H/10M/5L, **0**+6) ·
R11-R15 FAIL, plan-blocking mediums 1-6 · R16-R18 FAIL/PARK (1H each, all the CLI work-tree
check) · R19-R21 FAIL (0H, 2-6M) · R22 FAIL (**0H**/5M/6L). Full findings live in
`docs/reviews/gateguard-location-authenticated-optin/` and are not restated here.

**The operating rule of this document, learned the hard way: every round that converged
converged by removing something** (the truncation rule, the wrapper emit-shape change, the test
lock, the snapshot/restore, and now the CLI); every park traces to net-new machinery.
Plan-blocking mediums went 6 → 7 → 14 across R6-R8 while HIGHs went to zero, and the growth was
almost entirely inside the Verification, Tests and Measurement sections: each round of harness
detail became the next round's blockers, because prescribing how a test is wired makes
falsifiable claims about code that does not exist yet. Those sections state **what must be
observed and against which bad build**, and stop authoring the harness. That is a deletion, not
a weakening: the rule this document holds itself to — a guard whose failure branch has never
been observed is not a guard — is satisfied by naming the failure branch, which every row still
does.

**Operator decisions already taken, not reopened:**

- Option **(b)** of the
  [#616 comment of 2026-08-11](https://github.com/chris-yyau/busdriver/issues/616) —
  location-authenticated opt-in, marker keyed to the main worktree under the operator's passwd
  HOME.
- **The split above** (2026-08-20): containment core here, enrollment CLI in #712, manual
  enrollment documented in the interim. Explicitly *not* CLI-first sequencing, and explicitly
  *not* retaining the `ECC_HOOK_PROFILE=strict claude` instruction, which after step 2 no longer
  describes a real system.
- **The #612 residual is accepted** (2026-08-20) — see "What this does NOT do". It is no longer
  awaiting sign-off.
- **The hook-disabling settings class stays an ADR 0016 residual**, outside #616's scope, and is
  not widened around a specific key name this machine could not confirm — see the threat model.

---

## The problem

`scripts/hooks/gateguard-fact-force.js` is registered twice in `hooks/hooks.json`
(`:151`, `:161`) as a **blocking** PreToolUse gate. Unlike the five wrapped gate
registrations it is invoked with bare `node`, not through
`/usr/bin/env -i … hooks/gate-scripts/lib/sanitized-node.sh`, so the ADR 0016 / #325 env
channel is open on it.

**"The five wrapped gate registrations"** means, throughout: the five `hooks.json` commands
invoking `sanitized-node.sh` — `:111`, `:171`, `:201`, `:212`, `:463` — across **four**
scripts (`block-no-verify.js`, `config-protection.js`, `pre-bash-dev-server-block.js`,
`mcp-health-check.js`). Five registrations, four scripts: `mcp-health-check.js` is registered
twice — `:212` under `PreToolUse` and `:463` under **`PostToolUseFailure`** (`post:mcp-health-check`),
which is a distinct event array from `PostToolUse` (`:253`).

### The env-channel inventory is six

Asserted-and-falsified twice, so the derivation is shown rather than the conclusion asserted.
It is the union of every `process.env` read on GateGuard's live path — hook, dispatch runner,
shared flag library — plus the registration's own shell text (greps run 2026-08-19):

```
gateguard-fact-force.js :35 GATEGUARD_STATE_DIR|HOME|USERPROFILE · :434 GATEGUARD_DISABLED
                        :438 ECC_GATEGUARD · :460 CLAUDE_SESSION_ID|ECC_SESSION_ID
                        :469 CLAUDE_TRANSCRIPT_PATH · :474 CLAUDE_PROJECT_DIR
run-with-flags.js       :121-122 CLAUDE_PLUGIN_ROOT (Claude-set, deliberately re-imported)
                        :323 ...process.env (legacy spawn pass-through, not a control)
scripts/lib/hook-flags.js  :19 ECC_HOOK_PROFILE · :24 ECC_DISABLED_HOOKS · :54 ECC_DRY_RUN
```

The six that switch the gate **off**:

| # | channel | location | effect |
|---|---|---|---|
| 1 | `ECC_GATEGUARD` | `:438` | the one #616 was filed against |
| 2 | `GATEGUARD_DISABLED` | `:434` | checked first, independent |
| 3 | `GATEGUARD_STATE_DIR` | `:35` | `/dev/null` ⇒ `mkdirSync` (`:527`) fails ⇒ `allowWithStateWarning()` (`:793`) ⇒ pass-through allow |
| 4 | `ECC_DISABLED_HOOKS` | `hook-flags.js:24` | hook-level disable |
| 5 | `ECC_HOOK_PROFILE` | `hooks.json:151/161` + `hook-flags.js:19` | **skips registration entirely; `standard` is the default** |
| 6 | `ECC_DRY_RUN` | `hook-flags.js:54` → `run-with-flags.js:241-249` | `=1` echoes the payload and exits 0 without running the hook |

`:35`'s `HOME`/`USERPROFILE` belong on that list too, and the earlier taxonomy was
inconsistent to leave them off: they select the state root by exactly the mechanism channel 3
does, so a poisoned `HOME` on an uncontained invocation reaches `mkdirSync` (`:527`) →
`allowWithStateWarning()` (`:793`) → pass-through allow. Call them channel 3b. The remaining
reads (`:460`, `:469`, `:474`) are session-identity inputs, not off-switches.

**And the grep cannot see everything, which the derivation must say rather than imply.** Several
classes act *before* JavaScript runs and appear in no `process.env` read: **`PATH`** (which
node binary starts), **`NODE_OPTIONS`** (which code runs before the hook's first line), and
the **outer-shell** channels ADR 0016:21 already records — **`BASH_ENV`**, **`ENV`**, and
exported shell functions (**`BASH_FUNC_*`**), which act on the shell that runs the
registration command before `/usr/bin/env` is even reached.
None is closed by deleting a read. `PATH` and `NODE_OPTIONS` are closed by the same `env -i`
containment step 2 adopts — which is the point, and V1's sentinel observes the `NODE_OPTIONS`
case specifically. The outer-shell class is **not** closed by `env -i`, because it acts on the shell that
*invokes* it — and the honest statement splits, because an earlier draft of this paragraph got
it wrong in the dangerous direction:

- **`BASH_ENV` / `ENV`** — ADR 0016:293-303 records these as **verified not a live vector**:
  Claude Code invokes hook commands via `sh -c`, and a non-interactive POSIX `sh` sources no
  startup files. The revisit trigger is ADR 0016:323-324 (a harness that switches to `bash -c`).
- **Exported functions (`BASH_FUNC_*`) and `SHELLOPTS` are LIVE, and the earlier draft claimed
  otherwise.** That draft extended the `sh -c` argument to function import; the extension is
  false, because function import is not startup-file sourcing. Measured on this host, where
  `/bin/sh` is bash 3.2.57:

  ```
  $ /bin/bash -c 'foo(){ echo PWNED; }; export -f foo; /bin/sh -c foo'
  PWNED
  $ env SHELLOPTS=noexec /bin/sh -c 'echo EXECUTED'      # prints nothing, rc 0
  ```

  ADR 0016:21's own lever table already lists exported functions as a verified lever, so the
  draft contradicted the ADR it cited as authority. Both are ordinary `env`-block values, so
  they belong to the **plugin-wide residual class** the threat model already carries — the same
  class as a hook-disabling settings key. They are **not introduced by #616**, are identical for
  the five wrapped gates (worse there, since those are fail-CLOSED), and closing them is a
  six-registration exec-form rewrite this change does not attempt.

The inventory states this so its own boundary is explicit rather than implying `env -i` covers
everything. **`PATH` and `NODE_OPTIONS` are covered** by the containment step 2 adopts, and V1's
sentinel observes the `NODE_OPTIONS` case specifically. They are listed so the inventory is honest about its method:
the six-plus-3b table is what a `process.env` grep can enumerate, and `env -i` is what covers
the rest.

Step 5 deletes **all** the application-level reads, so after this change the hook contains
**no `process.env` reference at all** — a static, greppable invariant rather than another
enumeration to keep correct.

`ECC_HOOK_PROFILE` is the worst: evaluated in the uncontained outer shell before `env -i`
could apply, with the hook allowlisted to `strict` alone, so a committed `settings.json`
`env` block setting `standard` switches the gate off without naming any `GATEGUARD_*` var.

**This is a consent-channel choice, not a plumbing defect.** The repo has already settled
that an env var is a repo-injectable consent channel (ADR 0016 / #325; advisory-downgrade's
"**no** global env-var / global-file switch by design").

### Threat model

**Protected against:** the *passive repo-borne consent channels* — a committed
`.claude/settings.json` **`env`** block **naming any of the six consent channels this change
closes**, a tracked marker, a repo-supplied `GIT_*` variable. That is the whole of #616.

The qualifier on the `env` block is not hedging: an `env` block can also carry `BASH_FUNC_*`
or `SHELLOPTS`, which act on the shell that *invokes* the registration, before
`/usr/bin/env -i` is reached (see the inventory above, where both are measured). Those belong
to the plugin-wide residual class below — identical for the five wrapped gates — not to what
#616 closes.

**Not claimed: that a checked-out repo can do nothing at all.** Earlier rounds wrote
"anything arriving by virtue of the repo being checked out", which is broader than this change
delivers. A committed project `settings.json` may carry keys beyond `env` — a hook-disabling
key was raised in review (`disableAllHooks`; on this machine the string appears only in an
unrelated third-party plugin script, and project-scope precedence was not confirmed, so it is
reported as a *class* rather than an established mechanism). If such a key exists and project
scope wins, it switches off **every** hook — all five wrapped gates and GateGuard alike —
before any marker or `env -i` logic runs. That is a **plugin-wide** residual, equally true of
`block-no-verify` and `config-protection` today, and ADR 0016 does not record it. It is
therefore neither introduced nor closed by #616; the honest change here is to stop asserting a
guarantee this design does not provide, and to name the class as a follow-up for ADR 0016's
own threat model rather than a GateGuard-shaped exception.

**Not protected against:** an agent or process with shell access as the operator, which can
`unlink` the marker. **This is a new power, not a wash:** today the disabling
channels are session environment variables, and a `Bash` call cannot export into the next
PreToolUse process — hooks are spawned by the harness, not by the agent's shell. Accepted
because #616 is about passive injection, because GateGuard is not a boundary, and because a
shell-as-operator adversary already has strictly larger powers.

So step 5(g)'s refusal to print the revocation recipe in the block message is an
**anti-nudging** property, not access control — which is why step 4's manual enrollment and
revocation procedure may be documented in `SKILL.md` (step 6): that is operator documentation,
not the message that fires while the model is being blocked.

### Four readings of the fix that are wrong

| Proposal | Why it fails |
|---|---|
| Re-import `ECC_HOOK_PROFILE` into the containment prefix (Cubic, on #613) | Swaps one off-switch for another: `getHookProfile()` (`hook-flags.js:19`) reads it from `process.env`, GateGuard's allowlist is `strict` alone, so `ECC_HOOK_PROFILE=standard` still disables. Independently the outer `case` guard runs uncontained, before `env -i`. |
| Plain containment, no re-import | `env -i` wipes the profile, `getHookProfile()` falls back to `standard`, a `strict`-only hook never fires — a guard that cannot fire, which reads as coverage. |
| Re-import `BUSDRIVER_STATE_DIR` (Agy, R1) | Same class of channel. It is read at `advisory-downgrade-optin.sh:42`; GateGuard never reads it. The wipe is correct behaviour. |
| A per-repo **in-tree** marker (this document, R1) | Polarity inversion. `advisory-downgrade-optin.sh`'s `_repo_controlled` maps a *tracked* marker to `0`; there `0` denies a privilege (safe), here `0` would mean gate OFF — so `git add -f .claude/gateguard-enabled.local` would have **silently retired the operator's gate**. Confirmed at 0.98. Consent-check polarity is not portable between a gate that grants a privilege and one that imposes friction. |

---

## Decision

Consent moves **out of the repository namespace**, into the operator's **passwd-derived**
home, and GateGuard is contained under `env -i` like the wrapped gates.

```
<passwd-HOME>/.gateguard/enabled/<sha256(realpath(main-worktree))>
```

Contents, pinned as bytes: the main-worktree path followed by **exactly one `\n`**, UTF-8, no
BOM, nothing else. Only *existence* — as a non-symlink regular file with a 64-lowercase-hex
name, under non-symlink directories — is consulted.

**No code on the gate's consent path reads those contents** — `isEnabled()` consults existence
and type only — and the document says so rather than leaving a pinned format with no reader. The
one reader is step 4's operator LIST command, which is exactly the human-audit use the pin
exists for; #712's `--list` replaces it with orphan reporting proper. The pin survives for two reasons and they
are both stated so a reviewer does not have to guess: the contents are the **human audit
record** (which repo a hash belongs to, answerable with `cat`), and #712's `--list` orphan check
parses them, so a writer landing now and a reader landing later must already agree. Two writers
exist under this change — step 4's manual procedure and step 7's driver-lane fixture — and both
write the same bytes by construction, because both derive them from
`resolveIdentity().realpath`. The **capped 4 KiB marker read** that earlier rounds specified in
`gateguard-consent.js` is **deleted**: with `--list` gone it had no call site, and a guard whose
failure branch cannot fire is not a guard. It ships with #712, which is what reads contents.

**`<passwd-HOME>` is `os.userInfo().homedir`, never `process.env.HOME`.** Node resolves that
through `getpwuid(3)`; measured, `HOME=/tmp/evilhome node -e 'os.userInfo().homedir'` prints
`/Users/<operator>` (the real passwd home) while `process.env.HOME` prints `/tmp/evilhome`.

### Why out-of-tree dissolves the round-1 defect rather than patching it

There is no "marker is repo-controlled" case left to adjudicate, so there is no polarity to
get backwards. **A pull request against a gated repository is a set of files tracked by that
repository; it cannot create, delete or modify anything under the operator's passwd home.**
(Scoped deliberately — a dotfiles-as-worktree home is a residual, below.)

- `_repo_controlled`, and the index/HEAD/gitlink checks, are not cloned at all — R1's
  "near-clone of a 129-line security-sensitive script" does not arise.
- No env-derived path input is read, `BUSDRIVER_STATE_DIR` included.
- A `git add -f` of any in-tree `gateguard-enabled.local` has no effect: nothing reads it.

### Why passwd HOME, not `$HOME`

R4 had the resolver *read* `$HOME`, inheriting safety from the wrapper's passwd re-derivation
(`sanitized-node.sh:56-70`). Two findings killed it, as two faces of one defect: a poisoned
`HOME` pointing at a real directory holding a marker resolved **enabled** (the bound did not
bind), and on the contained path the wrapper *overwrites* `HOME`, so a temp-`HOME` fixture
was invisible and the contained rows were unreachable.

Reading passwd directly removes both: one resolution rule, identical contained and
uncontained; no inherited trust to bound; no fixture split. State roots at the same place, so
the gate has exactly one "which home?" answer.

### Fail direction

Marker absent, passwd home underivable, repo unresolvable, git missing, consent check
erroring ⇒ **gate OFF** (allow, exit 0, no `permissionDecision` on stdout).

Literal fail-*open*, correct **only** because of what GateGuard is: it guards no boundary, it
improves output quality, its default today is already off. The property protected is the
inverse of a security gate's — not "a repo must not switch this ON" but **"a repo must not
switch the operator's chosen gate OFF"**, for the passive channels the threat model names.

Forcing the gate *on* requires writing the operator's passwd home, which a PR cannot do, and
would only add friction. The OFF-side residuals are enumerated in "What this does NOT do".

**This does not generalize.** It licenses an off-by-default, fail-open marker for GateGuard
*because* GateGuard is not a boundary. Do not cite it for `block-no-verify`,
`config-protection`, `pre-bash-dev-server-block`, or `mcp-health-check`.

---

## Change list

### 1. `hooks/gate-scripts/lib/sanitized-node.sh` — a `--fail-open` **contract**

`sanitized-node.sh` is fail-CLOSED by construction: `:193` appends `--fail-closed`
unconditionally, and `_block` (`:85-89`) writes `{"decision":"block"}` to **stdout** before
exiting 2 at **eight** call sites (`:101 :107 :120 :147 :163 :167 :171 :198`). Adopting it
unchanged would hard-block every Edit/Write/Bash of operators who never enrolled, on a
missing node, an unresolvable plugin root, or one oversized payload. A flag that only remaps
the runner-rc arm does not help: `|| exit 0` rewrites the exit status while the block JSON
still ships, and the harness consumes the stdout decision.

The fix is a disposition variable and a disposition-aware `_block`, covering all eight sites
by construction:

```sh
# Top of file, after `set -euo pipefail`. Assignment and shift ONLY.
_disposition="closed"; _disp_word="CLOSED"
if [[ "${1:-}" == "--fail-open" ]]; then _disposition="open"; _disp_word="OPEN"; shift; fi
```

```sh
_block() {
    # The disposition word is appended HERE. SEVEN of the eight call sites
    # currently end with the closed-failure suffix (grep: :102 :107 :120 :147
    # :163 :171 :198; :167 already carries none) and would otherwise announce a
    # closed failure while the tool call proceeds. All seven lose the suffix.
    printf '%s — failing %s\n' "$1" "$_disp_word" >&2
    [[ "$_disposition" == "open" ]] && exit 0   # no stdout: "no opinion"
    printf '{"decision":"block","reason":"%s"}\n' "$2"
    exit 2
}

# AFTER the definition — placing this beside the parser calls _block before bash
# has defined it (command-not-found, 127, silent under `|| exit 0`).
# Arity, not a leading-token re-check: `--fail-open A B C --fail-open` would
# otherwise pass and reach the runner through the verbatim "$@" at :193.
# EMPTINESS too: `--fail-open "" "" "..."` satisfies arity with three args, and the
# existing empty-hookId/scriptPath guard at :162-165 would then _block in the OPEN
# disposition -- a malformed registration silently allowing. Round-15 finding 2.
if [[ $# -ne 3 ]] || [[ -z "$1" || -z "$2" || -z "$3" ]] \
   || [[ "$1" == --* || "$2" == --* || "$3" == --* ]]; then
    _disposition="closed"; _disp_word="CLOSED"
    _block "sanitized-node: malformed argument list" \
           "malformed blocking-gate registration; cannot confirm gate decision"
fi
```

and at `:193`, append `--fail-closed` only in the closed disposition. `--fail-open` is
**never forwarded to the runner** — `run-with-flags.js` has no reader for it; the runner's
fail-open behaviour is exactly the absence of `--fail-closed`. The token stays in the
`hooks.json` command string, which is what #629 keys on.

`_block`'s **output shape is unchanged** — the bare top-level `{"decision":"block"}` it emits
today. Round 12 proposed also emitting PreToolUse's modern
`hookSpecificOutput.permissionDecision` object; **that is withdrawn**, on two grounds. It
introduced a defect in a shared security wrapper (the draft interpolated a variable it never
assigned, which under `set -euo pipefail` at `:33` aborts before any stdout and, with
`|| exit 0`, becomes a silent allow — the exact outcome the forced-closed path exists to
prevent). And the underlying concern is weak: five in-tree shell gates block with the legacy
shape plus exit 0 today, and `pre-implementation-gate.sh` blocked tool calls during these very
reviews, so the mechanism is demonstrated, not assumed. Changing the emit shape of a wrapper
five security gates depend on is out of scope for #616; if the legacy key is ever retired,
that is one change for all six consumers, not a GateGuard-shaped exception.

The wrapper's header (`:2-32`) and its `:83-84`, `:151-156`, `:175-191` comment blocks assert
an unconditional fail-closed contract that this makes conditional; they are rewritten here.
The rewritten text must not contain the literal `failing CLOSED` — V6 greps for a count of
zero, and a comment mentioning the old string would fail its own guard.

**The risk is stated, not minimised:** a wrapper five security gates depend on now has two
dispositions, and getting it wrong means a gate that silently stops blocking. V6 bounds it.
Rejected alternatives: a GateGuard-specific copy of the wrapper reinstates R1's "third copy
drifting" finding on a 129-line security script; accepting fail-closed for GateGuard
hard-blocks operators who never enrolled.

### 2. `hooks/hooks.json` `:151` and `:161` — both GateGuard registrations

Drop the outer `case` guard and the `"strict"` argument; adopt the containment prefix:

```
/usr/bin/env -i PATH=/usr/bin:/bin CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" CLAUDE_HOOK_EVENT_NAME="$CLAUDE_HOOK_EVENT_NAME" bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-node.sh" --fail-open "pre:edit-write:gateguard-fact-force" "scripts/hooks/gateguard-fact-force.js" "minimal,standard,strict" || exit 0
```

(and the identical shape with `"pre:bash:gateguard-fact-force"` for the `Bash` matcher).

- **The CSV names every valid profile.** `hook-flags.js:12` defines
  `VALID_PROFILES = {minimal, standard, strict}` and `getHookProfile()` maps any unrecognised
  value back to `standard`, so all three makes `ECC_HOOK_PROFILE` non-disabling for every
  possible value.
- **`HOME` is not forwarded.** The wrapped gates pass `HOME="$HOME"` and the wrapper
  overwrites it from passwd anyway; forwarding implies a trust that is not there.
- **`|| exit 0` replaces `|| exit 2`.** GateGuard denies with exit 0 + a `permissionDecision`,
  so this cannot suppress a deny; it neutralises infra non-zeros only.
- **No `timeout` is set.** Round 9 added `"timeout": 10`; round 10 removes it. A harness
  timeout is enforced **outside** `sanitized-node.sh`, so neither the `--fail-open`
  disposition nor `|| exit 0` governs what a kill resolves to — the design would be asserting
  a disposition it does not control, and no row could observe it. The wrapped gate
  registrations set no timeout either (only `:203`'s config-protection does, at 30), so
  inheriting the harness default is both the smaller change and the sibling-consistent one.
  If a timeout is wanted later it is a follow-up with its own disposition question. (The
  placement rule stands for whoever adds one: `scripts/ci/validate-hooks.js:78-81` validates
  `timeout` on hook objects only, so a matcher-group placement passes `npm run validate`
  silently and is ignored.)
- Both `description` fields are rewritten (they currently call the case guard and the
  `"strict"` arg "deliberately redundant"; this deletes both).

### 3. New `scripts/lib/gateguard-consent.js` — one routine

R4 specified a standalone shell resolver and drew six findings about it: an undefined
`pluginRoot` at the JS call site, two independent producers of the identity, `sha256sum`
absent on macOS, an enumerated `GIT_*` unset list that missed five variables, the executable
bit, and re-entering the repo cwd. **The resolver script is deleted from the design.**
Consent is computed in-process by a module the hook `require`s, and every one of those findings
is answered by the component not existing. #712's CLI `require`s the same module, which is what
keeps helper and gate on one identity routine and one home derivation.

```js
homeDir()                    // os.userInfo().homedir, validated absolute — called at use time
gateguardRoot()              // <passwd-HOME>/.gateguard
enabledDir()                 // <passwd-HOME>/.gateguard/enabled
gitEnv()                     // factory: the five-key positively-constructed child environment
assertDirNoFollow(dir)       // lstat ONE component; throws unless a real, non-symlink directory
ensureDirNoFollow(dir, mode) // three-way create: see the state machine below; never `recursive`
anyMarkerPresent()           // 'present' | 'absent' | 'unreadable' — no-spawn fast path
mainWorktree(cwd)            // first `worktree ` record of `git worktree list --porcelain -z`
resolveIdentity(cwd)         // { mainWorktree, realpath, hash, markerPath } — one resolution
markerPath(cwd)              // convenience wrapper over resolveIdentity(cwd).markerPath
isEnabled(cwd)               // { enabled, status: 'enabled'|'absent'|'error', cause? }; never throws
```

**`ensureDirNoFollow(dir, mode)` is a three-way `lstat` state machine, not an assertion followed
by a create.** The distinction is not stylistic — "assert then `mkdir`" dead-ends on **both** live
branches, which is how an earlier draft of this section specified it:

1. **ENOENT** ⇒ non-recursive `mkdirSync(dir, {mode})`, then `assertDirNoFollow(dir)` — the
   re-check loses a create-versus-symlink race rather than trusting the create.
2. **A real, non-symlink directory** ⇒ do nothing and proceed. **Never `mkdirSync` after a
   successful assertion**: `<root>` already exists on any machine that has run GateGuard (state
   files have always lived there), so an unconditional create throws EEXIST on the dominant path.
3. **A symlink or non-directory** ⇒ refuse. The caller does not write into the target.

It creates **one component**, never `recursive` across an unvalidated one — a `recursive` create
runs *before* any refusal could fire and would follow a pre-existing `.gateguard` symlink into
its target. A caller preparing `<root>/enabled` calls it twice, outermost first.

**It also validates the PARENT before creating into it, and that is not merely defensive.**
"Call me outermost-first" as a caller contract fails silently when broken: `ensureDirNoFollow('<root>/enabled')` against a symlinked `<root>` would `lstat` `enabled` (ENOENT), `mkdir`
straight through the link, then assert the result — which *is* a real directory, inside the
link's target. The guard would pass while the write landed somewhere else. **The passwd home
itself is exempt from that parent check**, and the exemption is load-bearing: on hosts whose
passwd home is a symlink (`/home/u -> /mnt/u`) an unconditional check would refuse to create
`<root>` at all, so every state write would fail and every gated call of an enrolled operator
would land on `allowWithStateWarning()`. The home is the trust *anchor* this design
authenticates by, not a boundary it defends; what must never be followed is a symlink at or
below `<root>`. It does **not**
repair the mode of a directory it did not create; `mode` applies to creation only.

**Which primitives are exported, and which are deliberately not — round 22 asked, and the answer
changed with the split.** The question was whether three security-relevant primitives with
multiple call sites belonged in the declared interface, since the document rejects the
wrapper-copy alternative precisely over "a third copy drifting". Post-split:

- **The capped marker read is gone** — no reader remains here (see the Decision section). It
  ships with #712.
- **The no-follow directory primitives are exported**, because they genuinely have multiple
  callers. `assertDirNoFollow()` serves `isEnabled()`'s three-component check and
  `ensureDirNoFollow()`'s own post-create re-check. `ensureDirNoFollow()` has **three**: step
  5(b)'s `saveState()`, step 4's manual enrollment, and step 7's driver-lane plant. Step 7's
  contained lane reaches it indirectly — it enrolls by running step 4's command rather than
  planting a marker of its own. **Every marker and state write in this change goes through this
  one routine**, which is the property worth having rather than the count; the contained lane's
  own bare `mkdir` is a race claim on `<root>`, not a write into it. Round 11 left the gate's
  check and the resolver's
  asymmetric with no explanation; one shared routine is what makes them the same rule rather than
  implementations that agree today. #712's helper is the next caller.
- **The git environment is exported as a factory, `gitEnv()`, and it must not be a module-scope
  constant.** A constant would evaluate `HOME: homeDir()` — and therefore `os.userInfo()` — at
  `require()` time, which breaks the module two ways. `homeDir()` throws unless the value is an
  absolute string, so an underivable passwd home would throw **during `require()`** instead of
  resolving to `isEnabled()`'s `{status:'error'}` with its stderr line; 5(h) already traces where
  that goes — `run-with-flags.js:280-284` catches the failed require, falls through to the legacy
  spawn path, and a hook exporting `run()` with no `main()` becomes a **pass-through allow**, the
  design's own totality argument bypassed by its own constant. It would also defeat the
  substitution seam: the in-process lane patches the `os` module object before requiring, and a
  cached `HOME` survives across cases. So module scope holds only the four immutable literals
  (`PATH`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `LC_ALL`); `gitEnv()` adds `HOME` at call
  time, inside `isEnabled()`'s error boundary. V16 pins the returned object's five keys, so a
  drifting copy is observable rather than asserted against, and #712's work-tree probe imports
  the factory rather than retyping it.

`isEnabled()` **always returns the structured result, never a bare boolean**, because a boolean
cannot carry the distinction the diagnostic below depends on: `absent` must stay silent while
`error` (an unreadable ancestor, or a resolution failure after a marker was seen) must be
reported. The hook maps anything but `enabled` to OFF and writes the stderr line on `error` —
5(c) places that write. Ownership of the write is the caller's, which keeps the module free of
output. It is **read-only on the consent path**: nothing `isEnabled()` touches creates anything,
and `assertDirNoFollow()` only inspects. `ensureDirNoFollow()` is the one creating primitive, and
it is never reached from `isEnabled()` — only from `saveState()` and from step 4.

- **`homeDir()`** is `os.userInfo().homedir` — `process.env.HOME`/`USERPROFILE` are read
  nowhere in this module. **`os.homedir()` is forbidden here and the difference is the whole
  point**: on POSIX it returns `$HOME` when set and only falls back to the passwd entry
  otherwise, so it is exactly the injectable channel this design removes. The repo's dominant
  idiom is the worse form still — 14 sites under `scripts/` use
  `process.env.HOME || os.homedir()` (grep 2026-08-20) — so an
  implementer reaching for the house pattern lands on the defect. Neither V15 nor V16 can
  catch it on their own (the wrapper exports a passwd-derived `HOME` before node starts, so
  the two agree on the contained path, and `os.homedir()` contains no `process.env` token),
  which is why V16 also greps for the literal `os.homedir(` and V15 carries an in-process
  half. It throws unless the value is a string and `path.isAbsolute`: a
  passwd entry with an empty or relative `pw_dir` returns happily, and
  `path.join('', '.gateguard')` is the *relative* `.gateguard`, which resolves against whatever
  cwd the process happens to hold — `/` under the wrapper's `cd /`, but `<repo>/.gateguard` for
  any uncontained caller, which is simultaneously the contained/uncontained split this decision
  removes and an in-repository marker, the polarity trap the table above rejects.
- **`os.userInfo` is called at use time, never destructured or cached at module load.** That
  is what lets a test substitute a temp home by patching the `os` module object before
  requiring — a test-side substitution of a stdlib call, not a seam the hook exposes.
- **`anyMarkerPresent()` is a marker predicate, not a directory predicate**, and it returns
  **exactly one of three strings — `'present'`, `'absent'`, `'unreadable'` — never a boolean.**
  One union, used everywhere; the mapping into `isEnabled()`'s taxonomy happens in `isEnabled()`
  and nowhere else.
  - `'present'` — `<root>` and `<root>/enabled` each `lstat` as real, non-symlink directories
    **and** `readdirSync` yields ≥1 entry matching `/^[0-9a-f]{64}$/` that `lstat`s as a real
    file. This is the only outcome that proceeds to `resolveIdentity()` and the `git` spawn.
  - `'absent'` — either `<root>` or `<root>/enabled` is **missing (ENOENT)**, or both are
    readable and hold no valid marker. ENOENT belongs here and not in `'unreadable'`: `<root>`
    present with `enabled/` absent is the dominant state on every machine that has ever run
    GateGuard, since state files predate markers. Ordinary and silent.
  - `'unreadable'` — an EACCES/ELOOP/not-a-directory ancestor, **or** hex-named entries exist and
    *every* one is type-invalid (a symlink, directory or other non-regular type). A hex-named
    entry of the wrong type does not count as a marker, but it is also not nothing: the operator
    enrolled something this process cannot use, and they should learn that rather than be
    silently ungated.

  `isEnabled()` maps `'present'` onward, `'absent'` to `status: 'absent'` (silent), and
  `'unreadable'` to `status: 'error'` — gate OFF plus the single stderr line. **`'absent'` and
  `'unreadable'` both skip the `git` spawn**; that is what makes this the fast path. A boolean
  would collapse "the operator has enrolled nothing" into "the operator enrolled something and
  this process cannot see it", which is the fault-into-noise defect the taxonomy exists to
  prevent — in the direction that loses the fault. A *directory* predicate would leave an empty
  `enabled/` spawning `git` forever after the last marker is removed, and removal leaves
  `enabled/` in place under both step 4's manual revoke and #712's `--off`.
  It is **machine-global by design** — a per-repo fast path would need the hash, which needs
  the spawn it exists to avoid. So the no-spawn state is "zero markers anywhere"; one marker
  for any repo puts every session on the spawn-then-miss path. Step 8 budgets both.
  An orphaned marker counts as present: the hot path does no path validation.
- **`mainWorktree(cwd)`** runs `execFileSync('git', ['worktree','list','--porcelain','-z'], …)`
  with `{ cwd, encoding:'utf8', timeout:2000, maxBuffer:1<<20, stdio:['ignore','pipe','pipe'] }`
  — stderr is **piped, not discarded**, because the status taxonomy below classifies on it
  and `env: gitEnv()`, the **positively constructed** five-key environment — exactly
  `{ PATH:'/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin', HOME:homeDir(),
  GIT_CONFIG_GLOBAL:'/dev/null', GIT_CONFIG_SYSTEM:'/dev/null', LC_ALL:'C' }`, with `HOME`
  resolved **at call time** for the reasons the factory bullet above gives.
  `LC_ALL=C` is there because the `absent`-vs-`error` classifier matches git's English
  `not a git repository` on stderr; today that holds only accidentally, because the whitelist
  happens to omit locale variables, and an accident is not a contract. Every `GIT_*` discovery,
  config and exec variable is absent because it was never copied — absence by construction,
  not by enumeration, which is what R4's incomplete unset list argued for.
  `GIT_CONFIG_GLOBAL`/`SYSTEM` are pinned rather than unset, matching `sanitized-node.sh:53-54`
  and diverging deliberately from `advisory-downgrade-optin.sh:38-40` (which unsets them —
  inside a contained child that would re-enable `~/.gitconfig`); a comment names the
  divergence.
- **Path handling uses `--porcelain -z` and copies `design-clear.sh`.** Rounds 9-10 got this
  wrong twice — first claiming a decode-if-quoted helper existed to reuse, then copying
  `enable-advisory-downgrade.py`'s plain-`--porcelain`-plus-refuse-quoted shape. The arbiter
  settled it against primary sources: `git-worktree(1)` scopes C-quoting to the **lock
  reason** ("any 'unusual' characters in the lock reason … are escaped and the entire reason
  is quoted"), and the git **2.36.0** release notes introduce `-z` *because*
  `git worktree list --porcelain` "did not c-quote pathnames … correctly". So the `worktree`
  record is **not** C-quoted, a `worktree "` refusal is a guard whose failure branch can never
  fire, and the copied "needs git 2.40+" floor is off by two minor versions.

  So: `git worktree list --porcelain -z`, NUL-delimited fields, first `worktree ` record —
  exactly what `scripts/design-clear.sh:300-309` already does unconditionally, which also
  settles the version floor question in-tree. The refusal branch and the control-byte residual
  are both deleted; `-z` handles a newline in a path rather than declaring it unhandled — **and a
  row now exercises it**, which an earlier draft explicitly declined to do. The in-process lane
  creates a worktree whose path contains a literal newline, asserts the resolved
  `mainWorktree` still contains it (no truncation at the framing boundary), and round-trips
  enrolment so `isEnabled()` returns `enabled` for it. Sabotage-verified: changing the parser to
  split on `\n` instead of `\0` fails that row (and three others). The primary sources — git
  2.36.0 introduced `-z` for exactly this, `git-worktree(1)` scopes C-quoting to the lock reason
  — and `design-clear.sh:300-309`'s unconditional use of the same flag remain the *reason* for
  the choice; the row is what makes a regression in it observable rather than argued. The recorded marker contents keep the pinned byte
  format (realpath + exactly one `\n`) for the human-audit and #712 reasons the Decision
  section gives. **No code on the gate's consent path reads them** — `isEnabled()` consults
  existence and type only — so no newline-stripping rule is needed there; step 4's LIST
  command is the one reader, and it strips exactly one trailing newline, which is why the
  format is pinned to exactly one.
- **`--porcelain` first record, not `git rev-parse --show-toplevel`**: this repo develops in
  linked worktrees under `.claude/worktrees/`, and `--show-toplevel` would key each worktree
  to a different identity. Verified: from the linked worktree, the first record is
  `/Volumes/Work/Projects/busdriver`.
- **Re-entering the repo cwd is deliberate.** `sanitized-node.sh:111-121` does `cd /` to stop
  a repo-dropped `.tool-versions`/`.nvmrc`/`package.json`/mise file steering a version-manager
  **node** shim. A `git` child on a fixed trusted PATH is not that: git reads repo-local
  `.git/config`, which is not a tracked file a PR can write, and global/system config are
  pinned at `/dev/null`.
- **`markerPath()`** digests `fs.realpathSync(mainWorktree)` — the **realpath**, not the raw
  porcelain value, and the marker's *contents* record that same realpath so the two agree
  (round 16 flagged the two as ambiguous). It is hashed as the **UTF-8 encoding of that
  string**, no trailing newline: `createHash('sha256').update(p, 'utf8')`. "Raw bytes" was
  loose wording for the same thing given the `encoding:'utf8'` probe — stated exactly here
  because a writer and a reader that disagree produce a marker the gate cannot find.
- **`isEnabled()` `lstat`s without following** at all three components, and **never throws**:
  spawn error, non-zero status, signal, timeout, no `worktree ` record, `realpath` failure,
  `os.userInfo()` failure or an unusable `homedir` all resolve to a result whose `enabled` is
  `false`, with the `status` distinguishing them per the taxonomy below.

  Totality is load-bearing, but **not** for the reason R5-R6 gave. `failOpenExitCode()`
  (`run-with-flags.js:116-118`) is `process.argv.includes('--fail-closed') ? 2 : 0`, so after
  step 2 GateGuard is the open disposition and a throw exits **0**, not 2. The real reasons:
  an uncaught throw skips the erroring-OFF diagnostic below, skips the `rawInput` echo
  (changing the allow shape), and crashes any test that calls `run()` directly.
  **Do not re-add `--fail-closed` to GateGuard to make an older sentence true** — that
  recreates the unenrolled oversized-payload hard block steps 1 and 5(e) exist to remove.
- **The status taxonomy, and which values are silent.** Three OFF outcomes, not two:
  - `absent` — **`<root>` or `<root>/enabled` missing (ENOENT)**, no marker inside it, the
    payload `cwd` not absolute, or a `cwd` that resolves but is not a git repository. All are
    *expected not-applicable* outcomes and all are **silent**. ENOENT is called out because
    `<root>` present with `enabled/` absent is the dominant state on every machine that has
    ever run GateGuard (state files have always lived there; markers are new), and folding it
    into `error` would emit a line on every gated call for every unenrolled operator — the
    same fault-into-noise defect the "not a repository" case above was moved out of.
  - `error` — reserved for a genuine fault: `<root>` or `<root>/enabled` present but
    **unreadable (EACCES) or type-wrong** (symlink, not a directory), a `git` spawn failure or
    timeout, a `realpath` failure, an underivable passwd home. **This is the only status that
    produces a stderr line.**

  **The classifier is implementable from what the probe returns, which round 13's pinned
  options did not allow.** `stdio: ['ignore','pipe','ignore']` discards git's stderr, leaving
  no way to separate "not a repository" from any other failure. So the probe pipes stderr —
  `stdio: ['ignore','pipe','pipe']` — and classifies on what `execFileSync` gives: a thrown
  error with `status === 128` **and** git's stderr matching `not a git repository` ⇒ `absent`;
  any other non-zero, a signal, a timeout (`ETIMEDOUT`), or a spawn error (`ENOENT`/`EACCES`)
  ⇒ `error`. The stderr is read for classification only and never echoed.
  - `enabled` — the marker for **this** repository is present and valid.

  **One case the taxonomy previously left to inference, now stated:** the fast path is
  machine-global, so `anyMarkerPresent()` can return `'present'` on the strength of a marker
  belonging to a *different* repository. If this repository's own computed marker path then
  turns out to be a symlink, a directory or any other non-regular entry, that is **`error`**,
  not a silent `absent` — the operator enrolled something at that exact path and this process
  cannot use it, which is precisely the fault the `unreadable` reasoning above exists to
  surface. Reading it as `absent` would silently un-gate an enrolled repository. (The
  implementation already does this; what was missing was the taxonomy saying so, which is how a
  future reader would have justified changing it.)

  Two outcomes an earlier draft left derivable-by-elimination rather than stated, because
  each is a common path a reader should not have to infer: **`<root>` or `<root>/enabled`
  missing (ENOENT) is `absent`**, not `error` — it is the dominant state on every machine
  that has ever run GateGuard, and calling it a fault would emit a line on every gated call
  for every unenrolled operator. And **a marker set that exists but holds no marker for this
  repository — the per-repo hash miss — is `absent` too**: the operator has enrolled
  *something*, just not this repo, which is the ordinary many-repos-one-machine case.

  `isEnabled()` itself produces no output and creates nothing: it returns
  `{ enabled, status, cause? }` and the **caller** decides. The hook writes the single stderr line
  on `error`, placed in 5(c)'s ordering block. That keeps the consent path testable, and it is why
  the return is structured rather than boolean — #712's CLI reports the same field in its own
  words without the module growing an output channel.
  Note this is a *stderr* diagnostic, not a `permissionDecisionReason`: it names no
  `GATEGUARD_*`, no marker path and no helper command, so it does not reopen 5(g).

### 4. Enrollment — a manual operator procedure until #712

Step 6 deletes `ECC_HOOK_PROFILE=strict claude` (`SKILL.md:105-109`), today's only documented
way to turn GateGuard on. Without an enrollment path the change is a silent capability removal,
so one is documented here. It is **manual and operator-executed**, and it is temporary: #712
replaces it with `scripts/gateguard-enable.js`.

Three dispositions were available and the other two were rejected. Keeping the strict-profile
instruction would document a system that no longer exists — after step 2 there is no `case`
guard and no `strict` argument, so the instruction would enable nothing while reading as though
it did, which is the "guard that cannot fire" defect pointed at documentation. Sequencing the
CLI first would make the settled containment core wait on the component that did not converge.
So: document the manual path, and let the helper replace it.

**The procedure adds no code and no file.** Each mode is a single `node` invocation over
primitives step 3 already ships, which is what keeps it from reintroducing the helper's surface:

```bash
# ENROLL. Prints the marker path it wrote.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js"),f=require("fs"),i=g.resolveIdentity(process.argv[2]);g.ensureDirNoFollow(g.gateguardRoot(),0o700);g.ensureDirNoFollow(g.enabledDir(),0o700);f.writeFileSync(i.markerPath,i.realpath+"\n",{flag:"wx",mode:0o600});console.log("enrolled "+i.mainWorktree+"\n  marker "+i.markerPath)' "<PLUGIN_ROOT>" "/path/to/repo"

# REVOKE. Validates ancestors first — see the no-follow note below.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js");g.assertDirNoFollow(g.gateguardRoot());g.assertDirNoFollow(g.enabledDir());require("fs").unlinkSync(g.markerPath(process.argv[2]))' "<PLUGIN_ROOT>" "/path/to/repo"

# LIST every enrolment on this machine, with the repo path each marker records. The only
# mode that can find an ORPHAN — a marker whose recorded repo no longer exists. STATUS
# cannot: it answers for one repo path, and an orphan's path is precisely what stopped
# resolving. Not `ls ~/.gateguard/enabled/` either — see the `cd /` note below.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js"),f=require("fs"),pa=require("path");const none=()=>{console.log("  (nothing enrolled on this machine)");process.exit(0)};let d;try{d=g.enabledDir()}catch(e){console.error("cannot resolve passwd home: "+e.message);process.exit(1)}console.log(d);const bail=e=>{if(e.code==="ENOENT")none();console.error("  cannot read the enabled directory ("+(e.code||e.message)+") — GateGuard treats this as ERROR and stays OFF; check ownership/permissions, and that neither it nor its parent is a file or symlink");process.exit(1)};let es;try{g.assertDirNoFollow(g.gateguardRoot());g.assertDirNoFollow(d);es=f.readdirSync(d)}catch(e){bail(e)}const ms=es.filter(n=>/^[0-9a-f]{64}$/.test(n));if(!ms.length)none();const buf=Buffer.alloc(4096);for(const n of ms){const p=pa.join(d,n);let st;try{st=f.lstatSync(p)}catch(e){console.log("  "+n+"  <unreadable: "+e.code+">");continue}if(!st.isFile()){console.log("  "+n+"  <INVALID: not a regular file>");continue}let r;try{const fd=f.openSync(p,"r");try{r=buf.slice(0,f.readSync(fd,buf,0,4096,0)).toString("utf8").replace(/\n$/,"")}finally{f.closeSync(fd)}}catch(e){console.log("  "+n+"  <unreadable: "+e.code+">");continue}console.log("  "+n+"  "+r+(f.existsSync(r)?"":"   <-- ORPHAN"))}' "<PLUGIN_ROOT>"

# STATUS (read-only) — one repo. Reports that repo's consent state; cannot enumerate.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js");console.log(JSON.stringify(g.isEnabled(process.argv[2])))' "<PLUGIN_ROOT>" "/path/to/repo"
```

- **No value crosses the shell, and that is the point, not a convenience.** An earlier draft split
  this into a probe that printed the path and a `printf`/`mkdir` pair the operator pasted it into.
  That is not byte-safe for the path class step 3 deliberately made supportable: `--porcelain -z`
  was adopted so **a newline in a path** is handled rather than declared unhandled, yet two
  `console.log` lines cannot carry one, and single-quoting the value into `printf` breaks on an
  apostrophe — neither exotic on macOS. Resolving and writing inside one process keeps the path a
  JavaScript string end to end.
- **`cd / &&` is load-bearing, and it closes what passing the repo as an argument only
  half-closed.** Round 22 found (conf 0.80) that argument-passing still leaves node *starting* in
  whatever cwd the operator occupies, which may be the repo — the exact vector
  `sanitized-node.sh:72-81` exists to close, since a repo-dropped
  `.tool-versions`/`.nvmrc`/`package.json`/mise file can steer a version-manager shim and select
  which node executes. **The destination is `/`, copying `sanitized-node.sh:120` exactly, and it
  must not be `~`.** An earlier draft wrote `cd ~`, which is wrong on this design's own terms: the
  tilde expands from the shell's `$HOME`, the precise channel this change removes, so the one
  command whose job is to stay off `$HOME` would have consulted it to choose where to stand. `/`
  depends on nothing. Either way the cwd plays no part in locating the marker — that comes from
  `os.userInfo()` inside the process — and the two roles must stay unconflated in `SKILL.md` too.
  The same defect in a worse place killed an earlier `mkdir -p ~/.gateguard`, which would have
  created and permissioned a tree the gate never consults.
- **Both operands are quoted** so a plugin root or repo path containing spaces survives the shell,
  and neither is `eval`ed or re-split inside node.
- **`<PLUGIN_ROOT>` is written out, not substituted.** Substitution is braced-only
  (`scripts/lib/install/apply.js:62` splits on the literal `${CLAUDE_PLUGIN_ROOT}`, and
  `docs/plans/2026-06-04-pr-grind-lock-aware-filter.md:118-119` records the verified rule that it
  "is inline-substituted into markdown at load time — not a bash env var"), and even braced,
  ADR 0015:31-35 records a real incident where it collapsed to `/scripts/…` inside a Bash-tool
  child. This is an operator action in the operator's own terminal, where the variable is not set
  at all. `SKILL.md` therefore gives the plain-terminal derivation beside the command — the
  plugin root is two levels above the `SKILL.md` the operator is reading:
  `cd "$(dirname "<path to skills/gateguard/SKILL.md>")/../.." && pwd`.
- **One identity producer, still.** Path and contents both come from a single `resolveIdentity()`
  call in the shared module — the same call the gate makes. Nothing here re-implements the hash,
  which is what killed R4's shell resolver (`sha256sum` is absent on macOS, and two producers of
  one identity is the finding underneath that).
- **Revocation validates ancestors too, and that is not symmetry for its own sake.**
  `unlinkSync` does not follow a symlink at the FINAL component, so the marker itself is
  safe — but it does traverse a symlinked ANCESTOR. With a redirected `.gateguard` or
  `enabled/`, an unguarded revoke would unlink a same-named file *outside* the GateGuard
  tree: a delete, at a path chosen by whoever planted the link. Enrollment is guarded
  because it writes; revocation must be guarded because it deletes. `--off` in #712 carries
  the same two calls for the same reason.
- **The writer side is no-follow bounded, and it is bounded by the same primitives the gate
  uses.** Both directories go through `ensureDirNoFollow()`, which refuses a symlink or
  non-directory rather than creating through it, and the marker is written `{flag:'wx'}` —
  `O_CREAT|O_EXCL`, which fails on **anything** already at that path, a symlink included. So the
  procedure cannot chmod or write through a redirected ancestor. This is a narrower and truer
  claim than the earlier draft's, which asserted that reader-side type refusal bounded the
  procedure: it does not. Reader-side refusal prevents a **false enrollment** — `isEnabled()`
  `lstat`s all three components without following, so a mis-created marker resolves to gate OFF
  and the operator sees it on their next gated call. It says nothing about where a `mkdir -p` or
  a shell redirection already wrote. Both halves are needed and they are different halves.
- **What the manual path gives up, stated rather than glossed:** no `0755 → 0700` mode repair of a
  pre-existing `.gateguard` (`ensureDirNoFollow` sets `mode` only on directories it creates); no
  EEXIST re-`lstat`, so re-enrolling an already-enrolled repo, or a non-regular entry at the
  marker path, surfaces as a raw `EEXIST` rather than a diagnosis; no corrupt-contents detection;
  and no *automated* orphan reporting — step 4's LIST command finds an orphan by hand, but
  nothing prunes it. All of these ship properly with #712, which is what the helper is *for*.
- **This is byte-for-byte the write step 7's driver-lane fixture performs** — `resolveIdentity()`,
  then `realpath + '\n'` at `markerPath` — and now genuinely so, since neither crosses a shell.
  That is why **no verification row is added for the recipe**: the fixture already exercises the
  identical write, and a row asserting "the documented command works" would be new harness prose
  in the section that has generated every regression in this document.
- **POSIX-only, and `SKILL.md` says so beside the command.** After step 2 the registrations are
  `/usr/bin/env -i … bash …`, which cannot start on native Windows, so a marker created there
  would be stored and inert. `SKILL.md` also states the **git ≥ 2.36** floor beside the command —
  an operator on older git gets a resolution failure, and the reason belongs where they will
  look, not only in a residual bullet.

**The dotfiles-as-worktree topology is a documented residual here, not a warned-about one.**
Earlier rounds put a best-effort work-tree warning on `--on`; with no `--on` in this change there
is nowhere for it to print, so the residual below says "documented only" and the warning ships
with #712. Three consecutive rounds produced a plan-blocking HIGH trying to make that check
*decide* something — `isWithinRoot()`'s fail-closed `false` read as "proceed"; a refusal on
`rev-parse --is-inside-work-tree`'s exit 128, which is the ordinary answer for a non-repo home;
a probe from `homeDir()`, which git discovery cannot see past because it walks upward only. That
history travels to #712 as a do-not-retry list rather than being re-derived there.

### 5. `scripts/hooks/gateguard-fact-force.js`

**(a) Delete every `process.env` read** — the six sites enumerated above, `:469`'s
`CLAUDE_TRANSCRIPT_PATH` included (it sits inside the `transcript_path` tier that 5(f)
*keeps*, so a tier-list reading leaves it). Under `env -i` they are moot, but a dormant read
on a blocking gate is a live off-switch the moment anything invokes the hook uncontained, and
it reads as a supported control. The invariant replacing the enumeration: **no `process.env`
reference remains in the file.**

**(b) State roots at the passwd home, via two named functions.**

```js
function stateDir()         { return gateguardRoot(); }   // use-time, never module-load
function getStateFile(data) {                             // KEEPS the activeStateFile memo
  if (activeStateFile === undefined) {                    // undefined = not yet computed
    const key = resolveSessionKey(data);
    activeStateFile = key ? path.join(stateDir(), `state-${key}.json`) : null;
  }
  return activeStateFile;
}
```

The memo is not optional. `loadState()` (`:487`) and `saveState()` (`:524`) call
`getStateFile()` with **no argument**, relying on the module-level `activeStateFile` (`:36`)
that `run()` primes at `:814-815`. Without the memo — and with 5(f) deleting the
`process.cwd()` tier — both resolve `null`, an **enrolled** gate can neither load nor save,
and every call lands on `allowWithStateWarning()`: enabled, warning on stderr, allowing
everything.

**The module-level initialiser at `:36` changes from `null` to `undefined` as part of this
step.** It is `let activeStateFile = null` today, which under the new sentinel would read as
"computed, no usable key" on first load and strand any caller that requires the hook without
going through `run()` — which is exactly what step 7's in-process lane does.

`activeStateFile` uses `undefined` for "not computed" and `null` for "no usable key" — two
distinct states, which is why it is not a single falsy sentinel. `run()` resets it to
`undefined` before the first `getStateFile(data)`; a `null` means 5(f) has already returned
allow, but both callers still guard rather than assume.

`stateDir()` is a **directory**, and `saveState()` prepares it with a single
`ensureDirNoFollow(gateguardRoot(), 0o700)` — step 3's three-way state machine, which creates on
ENOENT, proceeds untouched on a real non-symlink directory, and refuses a symlink or
non-directory. It replaces `:523-527`'s `mkdirSync(..., {recursive:true})`.

**It must be that state machine and not "assert, then create", which is how an earlier draft read
and which dead-ends on both live branches.** A bare assertion throws ENOENT on a fresh machine
and on every CI runner, where `<root>` does not exist yet; an unconditional non-recursive create
throws EEXIST on the dominant path, since `<root>` already exists on any machine that has run
GateGuard. Either throw lands in `saveState()`'s catch (`:569-577`), which returns false, so
`markChecked()` reports failure and the call falls to `allowWithStateWarning()` (`:793`) — an
enabled-looking gate that warns on stderr and allows every call, which is the exact outcome this
whole step exists to prevent. V17c observes the ordinary pre-existing-root path for that reason,
not only the symlink refusal.

Round 11 left the gate's check and the resolver's asymmetric with no explanation; sharing one
routine is what makes them the same rule rather than two implementations that agree today.
Creating is not repairing: `mode` applies only to a directory the call creates, so the gate still
never `chmod`s the operator's home.
The directory is the one the current code already uses whenever `$HOME` is
honest, so **nothing is orphaned and no migration is needed**; markers live in `enabled/`
beside the state files. The atomic temp file is created mode `0o600` before the rename.
**`mode` is masked by the process umask**, so `0o600`/`0o700` are ceilings and not guarantees
— an earlier "regardless of umask" claim was simply false. **Nothing in this change repairs a
mode**, and no step should be read as doing so: `ensureDirNoFollow()` applies `mode` only to a
directory it creates, step 4's enrollment calls exactly that and adds no `chmod`, and the gate
never chmods the operator's home. Mode *repair* of a pre-existing loose `.gateguard` is #712's
helper, and step 4 lists its absence among what the interim procedure gives up. An earlier draft
of this paragraph described step 4 as setting `umask 077` and `chmod`ing both directories; that
described a superseded two-step shell recipe, and following it would have reintroduced the
`~`-expanding preamble step 4 exists to avoid.

**(c) `isGateGuardDisabled()` → `isGateGuardEnabled(cwd)`.** The positive name matters: the
absent-marker default must read as OFF at the call site.

- Parse the payload first, then call it with `data.cwd` (the existing order — the disabled
  check at `:810` already follows the parse at `:801-806`).
- Require `typeof data.cwd === 'string' && path.isAbsolute(data.cwd)`, else OFF — the house
  rule `config-protection.js:83-93` already establishes.
- **Nothing touches the state directory before this passes, and the not-enabled branch
  `return`s.** This is a concrete edit, not an assertion about existing behaviour: today
  `:814-816` runs `activeStateFile = null; getStateFile(data);` and then falls straight through
  into the tool dispatch. **The change inserts the enablement call and its `return rawInput;`
  immediately before that pair — in the exact form the ordering block below gives — and changes
  `= null` to `= undefined`** per the sentinel above. Without the explicit return the payload
  reaches the
  Edit/Write/MultiEdit/Bash dispatch, which calls `isChecked()` → `loadState()` →
  `getStateFile()` **argument-less** (`:486`, `:523`); after 5(f) deletes the `:474`
  fingerprint that resolves `null`, which reaches `saveState()`'s unguarded `tmpFile`
  construction at `:552`, throws into its catch, returns false from `markChecked()`, and lands
  every call on `allowWithStateWarning()` (`:793`) — an enabled-looking gate that warns and
  allows. Round 18 flagged that 5(b) *asserted* this return while no step *placed* it; this is
  where it is placed.
- **Ordering, stated once as code so nothing here is left to be derived.** In `run()`, exactly:

  ```js
  activeStateFile = undefined;                    // (1) reset FIRST
  const consent = isGateGuardEnabled(data && data.cwd); // (2) structured result, not a boolean
  //    `data &&` is not defensive noise: JSON.parse('null') parses successfully to null, so
  //    a literal `null` payload would throw on `data.cwd` before any guard could run.
  if (consent.status === 'error') process.stderr.write(<the single diagnostic line> + '\n');
  if (!consent.enabled) return rawInput;          // (3)
  if (!getStateFile(data)) return rawInput;       // (4)
  ```

  **`isGateGuardEnabled` is a rename of `isGateGuardDisabled`, not a boolean wrapper over
  `isEnabled().enabled`** — it returns step 3's `{ enabled, status, cause? }` unchanged. Round 18
  flagged that 5(b) *asserted* a return no step *placed*; a boolean wrapper here would repeat that
  defect one round later at the same call site, because it satisfies every prose line while
  silently dropping the stderr write **V4 asserts**, so V4 would fail against a build that
  implemented the prose exactly. The write is placed above rather than described.
  Per 5(g) and V9 the line names no `ECC_`/`GATEGUARD_` variable, no marker path and no helper
  command — it is a stderr diagnostic, never a `permissionDecisionReason`. **That is enforced,
  not assumed:** the `cause` values are built from raw fs/exec messages, which embed the marker
  path and can be multi-line, so the write passes them through a sanitizer that collapses
  whitespace, replaces any `.gateguard` path and any 64-hex token, and caps the length. A
  diagnostic that promises "one line, no marker path" while interpolating an unbounded error
  string is the same defect as a comment asserting what the next statement violates.
  The reset comes **first** so neither guard can read a memo left by a previous `require`-scope
  call, which is reachable in step 7's in-process lane where the module is loaded once and `run()`
  called repeatedly. An earlier draft put the reset after the guards, which in that lane made the
  second guard test a stale path and land on `allowWithStateWarning()`.
- **The null-session-key path gets its own placed return, for the same reason.** An enabled
  session whose payload carries no usable key must not reach the state layer either: the change
  inserts `if (!getStateFile(data)) return rawInput;` immediately after the enablement return
  above. 5(f) states the rule ("nothing usable ⇒ allow, without touching state"); this is the
  statement that implements it. Without it the argument-less callers at `:486`/`:523` take the
  identical `null` → `tmpFile` → `allowWithStateWarning()` route — the same defect, reached by
  a different door.
- The not-enabled branch returns `rawInput` — today's allow shape (`resolveHookResult`,
  `run-with-flags.js:74-77,:92`, turns it into `{stdout: raw, exitCode: 0}`). No step changes
  it.

**(d) Consent is keyed on the payload `cwd`, the gate acts on `file_path` — declared, not
incidental.** Stated as the mechanism gives it, not as a session-wide property: consent is
re-evaluated **per call** from `data.cwd`, nothing latches an enrolled identity to the session
key, so the gate applies to **every gated call whose payload `cwd` resolves to an enrolled
main worktree** — including edits to files outside that repo, and *excluding* calls in the
same session whose `cwd` has moved to an unenrolled repo. Per-call re-evaluation is the
property worth keeping: revocation takes effect on the next tool call rather than at the next
session.

**State keys stay session-only, and none of the three shapes is reliably repository-distinct.**
File-path keys are *usually* repo-distinct because payload paths are usually absolute — but not
by construction: `:823-833` and `:846-856` take `tool_input.file_path` as given, and
`config-protection.js:78-93` shows a relative payload path is a deliberately-handled shape
under this very wrapper, where `cd /` would make `src/app.ts` collide across repos. Together
with `ROUTINE_BASH_SESSION_KEY`
(`'__bash_session__'`, `:45`) and `'__destructive__' + sha256(command)` (`:871`) are not — so
in a session touching two enrolled repos, the first routine Bash command and each distinct
destructive command are gated **once across both**. Pre-existing behaviour, unchanged here,
recorded because 5(d) newly makes consent per-repository, which invites the assumption that
state is too. Repo-scoping those two keys is a follow-up.

Keying consent to `file_path` was rejected:
`file_path` is absent on Bash payloads, and on the MultiEdit variants whose target is carried
only per-edit — the branch at `:840-850` reads `tool_input.file_path`/`filePath` *and* falls
back to a per-edit `file_path`/`filePath`, which is what #615 exists
for, so a file-keyed check would stop gating exactly the payloads the gate was last fixed to
catch.

**(e) `run(rawInput, context = {})`, and #612 is a declared residual.**

R5 tried to preserve #612 by denying inside the hook on a truncated payload. That cannot
work: the deny precedes the parse, so no target exists and `markChecked()` cannot run —
GateGuard's first-touch model depends on the deny being recorded, so the retry truncates and
denies forever. **There is no truncation rule.** `run` **adopts** a two-argument shape — the
current signature at `:802` is `function run(rawInput)`, one parameter, while
`run-with-flags.js:300-306` already passes a second argument the hook ignores. Declaring it
with a `context = {}` default matches the caller and keeps one-argument callers working;
nothing consults `context.truncated`.

The consequence, recorded rather than hidden: dropping `--fail-closed` makes
`enforceTruncation()` (`:195-206`) a no-op for GateGuard, so a `>MAX_STDIN` payload parses as
an error and is allowed — #612's bypass returning **for GateGuard only**. Accepted for the
same reason the whole disposition is; the wrapped gates keep `--fail-closed` and are
unaffected.

**(f) `resolveSessionKey()` becomes payload-only.** Under `env -i` + `cd /` the current
five-tier chain collapses — env tiers wiped, `process.cwd()` literally `/` — so session-less
payloads would share one machine-wide state file.

- Keep, in order: `data.session_id`, `data.sessionId`, `data.session.id`,
  `data.transcript_path`/`transcriptPath` — the last **only when `path.isAbsolute`**, the same
  guard 5(c) puts on `data.cwd` and for the same reason: the tier hashes
  `path.resolve(transcriptPath)`, so under the wrapper's `cd /` a *relative* transcript path
  resolves against `/` and two sessions sharing that relative path collide on one state file,
  the exact collision V12 asserts against. A non-absolute value falls through to "nothing
  usable". **Payload fields only** — `:469`'s
  `|| process.env.CLAUDE_TRANSCRIPT_PATH` is deleted.
- Delete the `CLAUDE_SESSION_ID`/`ECC_SESSION_ID` tiers (`:460`) and the
  `CLAUDE_PROJECT_DIR || process.cwd()` fingerprint (`:474`).
- **Nothing usable ⇒ allow, without touching state** — never a shared file.
- **Every accepted key is hashed**, not character-substituted. `sanitizeSessionKey`
  (`:441-452`) returns `raw.replace(/[^a-zA-Z0-9_-]/g,'_')` for values ≤64 chars, which is
  non-injective — `a/b` and `a?b` both become `a_b`, so two sessions can share a state file.
  It already falls back to `hashSessionKey('sid', raw)` for longer values; this change takes
  that branch always. One line, and it is what makes "two sessions do not observe each other's
  state" true rather than usually-true. It does **not** make the map injective in general: the
  function `String()`-coerces and `.trim()`s first, so `'a'` and `' a '` still collide. That is
  deliberate normalisation of a transport artefact, not a defect, and it is stated here so the
  V12 claim is read as "differs by a folded character" rather than "differs at all".

**(g) Delete `withRecoveryHint()`** (`:758-764`) and its use in `denyResult()` (`:786`).
Settled by the 2026-08-13 ultimate-council, unanimous against the going-in position. The
block message conflates two instructions to two parties: a *compliance* hint telling the
constrained party how to **satisfy** the gate, and a *revocation* hint telling it how to
**turn the gate off**. Only the second is the defect. **Do not replace it with the marker path
or an `rm` recipe** — that is strictly worse, a persistent out-of-band switch where the env
hint was session advice the model could not apply. stderr was also rejected: its human-only
property is path-conditional and a solo operator never reads it.

The signature becomes **`denyResult(reason)`** — no options object. Four call sites (grep
2026-08-19):

| site | today | after |
|---|---|---|
| `:833` | `denyResult(toolName === 'Edit' ? editGateMsg(filePath) : writeGateMsg(filePath))` | unchanged |
| `:856` | `denyResult(editGateMsg(filePath))` | unchanged |
| `:875` | `denyResult(destructiveBashMsg(), { includeRecoveryHint: false })` | drops the options |
| `:884` | `denyResult(routineBashMsg(), { hookIds: [BASH_HOOK_ID] })` | drops the options |

All four message builders already end "Present the facts, then retry the same operation.",
which is what makes the compliance half survive the deletion. Four names are orphaned and
deleted, and they belong to two different steps — sequence them accordingly:
`EDIT_WRITE_HOOK_ID` (`:46`) and `BASH_HOOK_ID` (`:47`) fall out of **this** step's deletion of
`withRecoveryHint()` and the `hookIds` option; `ECC_DISABLE_VALUES` (`:48`) and
`normalizeEnvValue()` (`:429-431`) fall out of **5(a)**'s deletion of `isGateGuardDisabled()`,
their only consumer.

**(h) The module-scope prune IIFE becomes a called function.**
`(function pruneStaleFiles(){ … fs.readdirSync(STATE_DIR) … })()` at `:601-621` runs at
**`require()` time**, before `run()`. Deleting the `STATE_DIR` const without touching it is a
`ReferenceError` at module load; `run-with-flags.js:280-284` catches the failed `require()`
and falls through to the legacy spawn path, which for a hook exporting `run()` with no
`main()` is a pass-through allow — a gate that cannot fire. Repointing it at
`gateguardRoot()` instead reads the state directory on **every** gated call before any
enrollment check.

So: `function pruneStaleFiles(dir)`, called from `saveState()` immediately after its
`ensureDirNoFollow(stateDir(), 0o700)` — 5(b) replaces the old `mkdirSync` there, so the
anchor is the ensure call — reached only when the gate is enabled and a state write occurs, i.e. on a deny via
`markChecked()` **and** on the ≥60 s heartbeat refresh in `isChecked()` (`:591-596`). The
unenrolled path performs no directory read at all.

**A second module-load hazard, bounded and declared:** step 5 makes the hook `require` a new
file. A missing or broken `gateguard-consent.js` throws at `require()` and takes the same
silent-allow path; the wrapper's `:170-173` existence check covers only the hook script named
in the registration, not its requires. This is a **plugin-integrity** residual, not
repo-injectable — both files ship with the plugin — the same class ADR 0016 already accepts
for the wrapped gates.

**(i) Rewrite `allowWithStateWarning()`'s stderr** (`:793-797`), which currently says "Check
`GATEGUARD_STATE_DIR` or filesystem permissions" — naming a variable this change deletes, on
a surface no deny-message assertion inspects.

### 6. Documentation sweep

Every surface that still advertises the deleted switches or the old contract:

- **`skills/gateguard/SKILL.md:103-232`.** `:103-208` argues *against* this change wholesale
  ("Not env-contained, on purpose"; "Do not 'harden' this into `sanitized-node.sh`"; "do not
  delete the `strict` argument"). `:105-109` is the enable instruction. `:206-208` is the
  disable recipe — deleting it from code and leaving it here is not deleting it, since the
  model reads this file directly. `:222-232` is the `#612`/`--fail-closed` bullet, which says
  the runner overrides truncation to exit 2 "for `--fail-closed` dispatches (both GateGuard
  registrations)" and that an oversized Write "is refused outright"; after step 2 neither
  sentence describes a real system, and the replacement states the residual (allowed
  unchecked; split the write). `:210-221` stays, with refreshed line references.
- **`scripts/hooks/run-with-flags.js:193-194`**, whose `enforceTruncation` comment states
  "both live gate registrations wrap the runner with `|| exit 2`". After step 2 they do not.
- **`hooks/hooks.json`** — both `description` fields (step 2).
- **`hooks/gate-scripts/lib/sanitized-node.sh`** — header and comment blocks (step 1).
- **`tests/test-gate-env-containment.sh:286`**, whose assertion text describes the wrapper's
  behaviour in terms this change makes incomplete. The assertion itself still passes (V7); the
  wording is refreshed so it does not read as certifying something no longer universal.
- **`skills/gateguard/SKILL.md`** also states the **git ≥ 2.36** requirement and the POSIX-only
  limitation next to the enrollment command — an operator on older git gets a resolution
  failure, and the reason belongs where they will look, not only in a residual bullet.
- **`docs/adr/0016-gate-env-containment.md`** — the ADR this document cites as authority
  throughout. Its unconditional fail-closed claims (`:126-149`, including the `|| exit 2`
  requirement at `:130-133`) and its containment inventory (`:240-246`: "Four node gate hooks
  are now CONTAINED", and the claim that the remaining node hooks "make no allow/block
  decision") are both falsified by a fifth contained script that decides and registers with
  `|| exit 0`. The amendment records the conditional disposition, the rule that **only a
  non-boundary gate may pass `--fail-open`**, GateGuard's registration shape, and the residual
  that for a fail-open consumer every wrapper launch failure resolves to allow. Its
  `CLAUDE_PLUGIN_ROOT` residual paragraph (`:209-216`) is **not** amended — its acceptance
  argument rests on non-injectability, not on failing closed, and this change does not disturb
  it.

**The replacement `SKILL.md` states the bounded claim verbatim, not a broad one:** *"a gated
repository cannot switch GateGuard off through a committed `settings.json` `env` block naming
any of the six consent channels this change closes, a tracked in-tree marker, or a repo-supplied
`GIT_*` variable."* The qualifier is load-bearing and was added after the unqualified form was
shown to overclaim: an `env` block can also carry `BASH_FUNC_*` or `SHELLOPTS`, which act on the
invoking shell before `env -i` is reached (see the inventory above). Those are a plugin-wide
residual identical for the five wrapped gates, not something #616 closes, and a skill sentence
implying otherwise is the same defect this step exists to fix, pointed the other way. It does **not** say a repo can
do nothing at all — the hook-disabling class in the threat model is a live plugin-wide
residual, and a skill sentence claiming more than the change delivers is the same defect this
step exists to fix, pointed the other way.

Beyond that, the replacement text states: contained like the wrapped gates; off by default;
enabled per-repo by an out-of-tree marker; the marker location; **step 4's manual enrollment, LIST and STATUS
commands verbatim**, marked as temporary and naming #712 as its replacement; **revocation
DESCRIBED but not scripted** — see below; and the
threat model, so "a repo cannot switch this off" and "a shell can" are written down once.

**`SKILL.md` gets no runnable revocation command — and the scope of what that buys is stated
exactly, because two successive drafts overclaimed it.** The first said `SKILL.md` carries the
enrollment and revocation procedure "verbatim", justified as *operator* documentation. That was
wrong on this design's own terms: `SKILL.md` is loaded into the model's context when the skill
is invoked, so the audience is the party the gate constrains, and "operator documentation, not
the block message" is not a boundary when the operator's documentation is also the model's
reading material.

The second draft removed the paste-ready `unlinkSync` and claimed that *preserved* 5(g)'s
anti-nudging property. It does not. A model can act on the surrounding prose as easily as on a
command; omitting the runnable form lowers salience and nothing more. Claiming otherwise would
be asserting a guarantee this change does not deliver — the defect this document has had to fix
in four other places.

**What is actually true, and it is narrower:** 5(g)'s property is scoped to the **block
message** — the text that fires while the model is being denied. That surface carries no
revocation recipe, no marker path and no `GATEGUARD_*` name, and V9 greps for exactly that.
`SKILL.md` describing revocation is *accepted*, not defended, because the threat model already
grants that a shell-as-operator process can remove the marker, which is strictly more powerful
than reading a sentence. The executable form lives here and in #712's `--off`.

The manual procedure is the *only* enable instruction the file carries after this change.
`:105-109`'s `ECC_HOOK_PROFILE=strict claude` is deleted rather than retained, because after
step 2 there is no `case` guard and no `strict` argument for it to act on: retaining it would
leave the file documenting an enable path that enables nothing, which is the same defect as a
guard that cannot fire.

### 7. Tests

Three lanes. This section states what each lane is **for** and the two contracts that are
design decisions rather than harness detail; how each row is wired is implementation.

- **In-process (`__tests__/gateguard-consent.test.ts`, new).** Imports
  `scripts/lib/gateguard-consent.js` directly, with `os.userInfo` patched in the test process.
  This is the only lane that attributes coverage to the new file: `vitest.config.ts` has
  `coverage.include: ['scripts/**/*.js']` and `codecov.yml` an 80 %/5 % patch target on the
  `javascript` flag scoped to `scripts/`, while the shell lane is uninstrumented and the
  driver lane runs in a `spawnSync` child. Without it the PR ships a new file at 0 % patch
  coverage. The same gap applies to `gateguard-fact-force.js` itself — it is in the
  `coverage.include` denominator while every branch this change touches runs in that child —
  so the in-process suite also drives `run()` directly (importing the hook, `os.userInfo`
  patched) for the enablement, session-key and state-path branches. Whether the Codecov patch
  status is a *required* check was not confirmed; the suite exists because uncovered new code
  is worth covering, not because a check demands it. It owns everything that needs neither the
  wrapper nor a payload: the `homeDir()` guards, the `anyMarkerPresent()` predicate across all
  three of its return values, `ensureDirNoFollow()`'s three branches and `assertDirNoFollow()`'s
  refusals against a planted symlink and non-directory under a temp home, `gitEnv()`'s returned
  key set, and module load surviving an `os.userInfo` that throws.
- **Driver (`__tests__/gateguard-multiedit.test.ts`, existing).** It currently forces every
  deny with `GATEGUARD_STATE_DIR`/`GATEGUARD_DISABLED`/`ECC_GATEGUARD` (`:41`) and its
  payloads carry no `cwd` (`:61-70`) — all four levers deleted by 5(a)/5(c), so without a new
  fixture the eight #615 deny assertions silently flip to allow.

  **Contract (design decision): the lane is hermetic, and the patch lives in the CHILD.**
  `:37-42` spawns `spawnSync('node', ['-e', DRIVER, HOOK], …)` — a separate process — so a
  patch applied in the vitest parent could never reach the hook. Naming the shape exactly, so
  an implementer cannot land the fixture in the operator's real home:
  - `spawnSync('node', ['-e', DRIVER, HOOK, tempHome], …)`, and **inside** the DRIVER text,
    before `require(process.argv[1])`:
    `os.userInfo = () => ({ ...real(), homedir: process.argv[2] })`, with an assert that
    `argv[2]` is absolute.
  - The **parent** plants the marker through the module, with `os.userInfo` patched in the *test*
    process to `tempHome`: `require('scripts/lib/gateguard-consent.js')`, then
    `const identity = resolveIdentity(repo)`, then **`ensureDirNoFollow(gateguardRoot(), 0o700)`
    and `ensureDirNoFollow(enabledDir(), 0o700)`**, then write `identity.realpath + '\n'` to
    `identity.markerPath` with `{flag:'wx', mode:0o600}`. **The two creates are not optional and
    an earlier draft omitted them**: a `mkdtemp` home contains no `.gateguard`, so a bare
    `writeFileSync` throws ENOENT and the fixture never plants anything. **The contents are the
    realpath, not the `mkdtemp` path** — on macOS `mkdtemp` returns `/var/folders/…` while its
    realpath is `/private/var/folders/…`, so writing the raw path would record a value #712's
    `--list` is specified to report as corrupt. Two processes, one rule, no hand-rolled hash.
  - **This is byte-for-byte the write step 4's manual procedure performs** — the same four calls
    in the same order, which is why step 4 adds no verification row of its own: the operator's
    command and this fixture resolve the same identity through the same module and write the same
    bytes to the same computed path. The fixture does it under a temp home; the operator does it
    under their real one. If the two ever diverge, this bullet is the thing that has to change.
  - Payloads gain `cwd` naming a `mkdtemp` git repo, and the `env:` object at `:41` drops
    `GATEGUARD_STATE_DIR`, `GATEGUARD_DISABLED` and `ECC_GATEGUARD`.

  Do not weaken the first-touch, retry, MultiEdit, subagent or alias assertions.
- **Contained (`tests/test-gateguard-containment.sh`, new).** Runs the real `hooks.json`
  invocation from a poisoned outer shell, modelled on `tests/test-gate-env-containment.sh:111-133`.
  It is the only lane that validates the wrapper boundary.

  **Contract (design decision), part one: it enrols a per-run THROWAWAY repository, never the
  checkout it is running inside.** Enrolment is durable consent, so enrolling the operator's own
  repo means a `SIGKILL` mid-run leaves a live enrolment behind — a consent change the suite
  never asked for, and it falsifies "a killed run just leaves `<root>` behind". Step 8 already
  requires per-run throwaway identities for the same hazard and the driver lane already uses a
  `mkdtemp` repo; all three lanes follow one rule.

  **Part two:** the lane has no home seam and does not need one, so it runs
  against the operator's real passwd home — but under the rule below it **only ever writes into
  a `<root>` it created itself**, and afterwards removes **exactly the entries it created, by
  name**, then the directories it created **only if they are empty**. It is never a whole-tree
  removal; that wording is deleted wherever it survived, because a concurrent enrollment landing
  mid-run must not be destroyed. Nothing pre-existing is modified, so there are no mode snapshots
  to restore and no prune of the operator's `state-*.json` to justify. (Round 10 justified that prune as "exactly what production already
  does"; it is not — the module-scope IIFE runs only at module load, and the `case` guard at
  `hooks.json:151/161` means it **never loads in the default profile**, so on a non-`strict`
  machine this suite would have been the first thing ever to delete those files. The rule below
  removes the question rather than answering it.) Nothing in this lane plants a symlink or a
  foreign type under `<root>`; those refusals belong to the in-process lane, against a temp
  home.

  `scripts/ci/run-shell-tests.sh` globs `tests/test-*.sh`, so this runs in CI — and its
  `SKIP_ALLOWED=()` is **empty by policy**, with the comment "Everything else — every
  gate/security suite included — must run to completion; an unexpected SKIP fails the job…
  Keep this list minimal and justify each entry" (`:95-102`). Round 11 proposed adding this
  suite to that allowlist. **That is withdrawn**: a gate suite is precisely what the policy
  names, and buying a green CI by exempting the new gate's own coverage is the wrong direction
  for this repo.
  So the suite does **not** SKIP. An underivable, empty or non-absolute
  `os.userInfo().homedir` is a hard **FAIL** with the reason on stderr — that condition means
  the design's cornerstone does not hold on this host, which is a result worth failing on, not
  one to skip past. The suite emits a positive completion line so a silent early exit cannot
  masquerade as a pass.

  **The rule that settles this, after four rounds of trying to bound the damage: the lane
  never touches a pre-existing `<passwd-HOME>/.gateguard`.** Rounds 12-15 tried
  accept-and-declare, then a snapshot/restore, then a lock. The lock was the worst of them —
  no production writer takes it (`saveState()` `:523-527` and the prune `:601-621` write
  unlocked, as does step 4's manual `printf`), so it would read as mutual exclusion and provide
  none; and a
  snapshot/restore across a concurrent real session would *reinstate* files that session had
  legitimately removed. The remaining honest option is not to bound the mutation but to avoid
  it:

  - **`<root>` absent before the run** (always true on a CI runner, and on any machine that
    has never run GateGuard in `strict`): the suite first claims `<root>` with a non-recursive `mkdir -m 700` — the explicit mode
    matters, because the claim precedes enrollment, so enrollment sees `<root>` as
    pre-existing and correctly declines to repair its mode; a umask-dependent bare `mkdir`
    would leave 0755 for the run, and permanently if the run is killed — **EEXIST means a real session raced it, so fall to the marker-free
    branch**. That `mkdir` is the *race claim*, not the enrollment. It then **enrolls by running
    step 4's enrollment command verbatim**, which keeps one identity producer and no shell-side
    hash (`sha256sum` is absent on macOS); `ensureDirNoFollow` finds the just-claimed `<root>`
    present and proceeds. It exercises every contained row, then **removes exactly the entries it
    created, by name**: its fixture marker and its own `state-*.json`, then `enabled/` and
    `<root>` if and only if they are empty. Impact: nil; the step-5(h) prune has nothing of the
    operator's to find.

    **Not a whole-tree removal.** The atomic `mkdir` closes the race *before* creation but not
    during the run: an operator who enrolls while the suite is working would have their brand
    new marker deleted by an `rm -rf <root>`. Removing by name leaves a concurrent enrollment
    untouched, and the "only if empty" condition means the suite silently declines to remove a
    root that acquired someone else's content — the same trade as everywhere else here, where
    losing coverage beats losing the operator's data.

    **There is no sentinel and no `<root>`-level sweep.** An earlier draft wrote a
    `.fixture-<token>` file so a later run could `rm -rf` a tree left behind by a `SIGKILL`ed
    one. That is a data-loss path, not a recovery: after the kill the operator legitimately
    enrolls into that same `<root>`, and the next run's sweep deletes their real marker and
    state. The recovery it buys is worth less than the failure it introduces. A killed run
    therefore leaves `<root>` behind and every later local run takes the marker-free branch —
    degraded *local* coverage, which CI does not share (a runner's home is fresh).

    **What a killed run leaves, and how to clear it.** This paragraph has been rewritten rather
    than patched again: three successive edits each fixed one sentence and left the neighbouring
    ones contradicting it, which is its own lesson about accreted prose.

    The facts, once:

    - `SIGKILL` does not run the `EXIT` trap. So the run leaves behind **all** of: `<root>`,
      its `enabled/`, the fixture marker inside it, the run's `state-*.json`, **and** the
      `mktemp` fixture repository the marker points at.
    - Because the fixture repository survives too, the marker's recorded path still resolves.
      **LIST therefore reports that marker as healthy, not as an ORPHAN** — its orphan test is
      "the recorded path no longer exists", and that is FALSE here. Nothing flags this
      automatically; that is the whole difficulty.
    - Identify it by the distinctive component in the recorded path:
      `gateguard-containment-fixture-<run token>`, which the suite puts there for exactly this
      purpose. **Do not** use "it is under the system temp directory" — the enrolment contract
      accepts any absolute git repository, so an operator may legitimately enrol a checkout
      under `/tmp`, and a location-only rule would tell them to revoke their own consent.
    - Clear it the same way the suite itself cleans up: **remove by name** — that marker, then
      the run's `state-*.json`, then `enabled/` and `<root>` only if empty. A plain `rm` of a
      non-empty directory fails, and `rm -rf <root>` is precisely the whole-tree removal this
      section rejects: it would destroy an enrolment the operator made *after* the crash.

    Until it is cleared, every later local run takes the marker-free branch — degraded *local*
    coverage, which CI does not share, since a runner's home is fresh. Lost coverage is
    recoverable; a lost enrolment is not, and that asymmetry is why this recovery is deliberately
    manual rather than swept.
  - **`<root>` present**: the suite does **not** write into it, does **not** enroll, and does
    **not** trigger the prune. It runs the contained rows that need no marker — the
    registration-shape and static rows, marker-absent allow, the wrapper-disposition rows —
    and prints a loud, unmissable line naming the enrolled rows it did not exercise and why.

  It is not a SKIP: the file runs to completion and exits 0, so `run-shell-tests.sh`'s empty
  `SKIP_ALLOWED` policy is respected rather than amended.

  **CI is the authoritative lane for the enrolled rows, and that is asserted rather than
  assumed.** The second branch is the common case locally — step 5(b) notes `<root>` already
  exists on any machine that has run GateGuard — so without a guarantee the enrolled contained
  rows could silently never run anywhere. A GitHub runner is a fresh home, so the first branch
  is what CI takes; the suite prints which mode it ran (`full` / `marker-free`), and under
  `CI=true` a `marker-free` run is a **failure**, not a notice. A degraded CI run therefore
  cannot pass quietly, and the operator's own machine is never the thing that pays.

  Fixture names and session ids still carry a per-run unique token, so two concurrent runs
  cannot collide. **There is no crash-recovery sweep at all** — earlier drafts specified one
  (matching markers by content, since a marker filename is a hash and cannot carry a prefix),
  and it is gone with the sentinel that anchored it: any sweep powerful enough to reclaim a
  killed run's tree is also powerful enough to delete an enrollment the operator made
  afterwards. A killed run leaves `<root>` behind and later local runs take the marker-free
  branch, which is visible in the mode line the suite prints. Clearing it is the remove-by-name
  procedure above — **not** "one `rm`": the `EXIT` trap does not run on `SIGKILL`, so `<root>`
  still holds the run's fixture marker and state files, a plain `rm` of a non-empty directory
  fails, and `rm -rf` is the whole-tree removal this section rejects.

**`tests/test-node-hook-containment.sh` is not touched** — see sequencing.

### 8. Measurement obligation

Step 2 deletes the `case` guard, so in the default profile node now starts for every Edit,
Write, MultiEdit and Bash where today a shell `case` starts nothing. What is measured is
**containment + consent**, not consent alone: the wrapper also runs a passwd lookup and
`node --check "$runner"` per candidate (`sanitized-node.sh:141-145`), so each gated call pays
bash startup plus at least two node starts.

- **Sampling contract**, since a p95 blocks the merge: 100 measured invocations per state
  after 10 discarded warm-ups, p95 taken as the 95th-percentile order statistic of those 100,
  reported with min/median/max and the raw sample count. One run per state on an otherwise
  idle machine; no outlier discarding.
- **The measured unit is pinned as tightly as the budget, because an unpinned unit lets a
  passing number describe a cheaper path than the one operators pay for.** Every sample is:
  the **`pre:edit-write:gateguard-fact-force`** registration (not the `Bash` one), driven with
  an **Edit** payload, invoked exactly as `hooks.json` invokes it — the full
  `/usr/bin/env -i … bash sanitized-node.sh … node …` chain, timed end to end from the outer
  shell, since the wrapper's bash startup and its `node --check` per candidate
  (`sanitized-node.sh:141-145`) are part of what step 2 newly makes every gated call pay.
  Same registration and same payload in all three states, so the numbers are comparable.
  **Each sample carries a fresh `session_id`, and the state file it writes is removed after the
  sample, outside the timed interval.** The fresh id is what keeps state (iii) on the
  *first-touch* path — the deny, the only path that reaches `markChecked()` → `saveState()` →
  `pruneStaleFiles()`; reusing one id would make samples 2-100 repeat touches, excluding both
  writes and reporting the enrolled experience as cheaper than it is. But fresh ids **without**
  the removal make the number order-dependent rather than a property of the code path: the prune
  only unlinks files older than `2 × SESSION_TIMEOUT_MS` (30 min at `:39`, threshold at `:611`),
  so none of the 100 files a run writes is ever eligible, and each sample's `pruneStaleFiles()`
  would `readdir` and `stat` a strictly larger directory than the one before it, inside the timed
  interval. Removing each sample's own file restores identical preconditions, so what is reported
  is **cold-session first touch** — named here because it is a choice: state-directory *growth*
  is deliberately **outside** the measured unit, and a long-lived real session updates one file
  rather than accumulating them. If within-session cost ever needs a number it is a second
  measurement with its own budget, not a reinterpretation of this one.
- **Three states.** (i) zero markers anywhere ⇒ no `git` spawn; (ii) a marker for another repo
  ⇒ spawn and hash miss; (iii) this repo enrolled ⇒ spawn and hit.
- **Budget, and it blocks the change.** State (i) p95 **≤ 250 ms**, state (ii) p95
  **≤ 400 ms**, and state (iii) p95 **≤ 400 ms**. Round 12 left (iii) unbudgeted as "an
  enrolled operator has opted into the gate's cost"; that is wrong on this design's own
  mechanics — `anyMarkerPresent()` is machine-global, so (iii) is the *only* state an enrolled
  operator is ever in, and leaving it uncapped exempts the entire enrolled experience from
  measurement. (ii) and (iii) share a budget because they do the same work: the `git` probe
  dominates and the hash compare is free.
- **Who pays it, and why that is acceptable.** The baseline is sub-millisecond — a shell
  `case` that never starts node — so this is not a small regression, and it lands on
  **unenrolled** operators who get no benefit from GateGuard at all. The budget is not
  "cheap"; it is "below the threshold where a per-tool-call delay is perceptible against the
  tool call it precedes", which for an Edit/Write/Bash round trip through the harness is
  where 250 ms sits. The reason unenrolled operators must pay anything is structural: the
  channel being closed (`ECC_HOOK_PROFILE`) is read in the outer shell, so the gate cannot
  decide whether it is enabled without first being contained. Trading a measurable
  unenrolled-path cost for closing a repo-injectable off-switch is the whole of this design;
  it is stated here so the trade is explicit rather than buried in a threshold.
- **The measurement runs on a fresh home, and that is a hard precondition rather than a
  preference.** The measured unit is deliberately the real `hooks.json` chain, so there is no
  `os.userInfo` seam: consent resolves against the real `<passwd-HOME>/.gateguard/`, and
  producing states (ii) and (iii) means planting markers and writing state files there. Step 7
  spent rounds 12-15 arriving at the rule for exactly this hazard, and an earlier draft of this
  section claimed to inherit it while actually keeping only half — hard-failing state (i) on a
  non-empty `enabled/` but letting (ii) and (iii) plant into whatever tree was already there.
  **Step 7's rule is the stronger one — never touch a pre-existing `<root>` — and it applies here
  unchanged**, for a reason specific to this section: state (iii) drives 100 first-touch denies,
  each reaching `pruneStaleFiles()`, and **that prune is ownership-blind** (`:601-621` — it
  unlinks every `state-*.json` past the age threshold, with no notion of whose it is). Removing
  the measurement's own files by name afterwards cannot restore an operator's state files the
  prune deleted during the run. Name-scoped cleanup is not a sufficient control when the code
  under measurement deletes by age.
  - **`<root>` absent before the run is required for all three states**, not only state (i). If
    it exists, the measurement does not run on that machine — it does not enroll, does not clear,
    and does not "annotate" a number taken anyway. Clearing real enrollments to manufacture
    state (i) would destroy operator consent under cover of a documented procedure.
  - The authoritative lane is therefore a **fresh home** — a CI runner, container or disposable
    account — the same structure step 7 uses for its enrolled contained rows, and for the same
    reason: the operator's own machine must never be the thing that pays.
  - On that fresh home: fixture markers are planted through `resolveIdentity()` under **per-run
    throwaway repo identities**, so every filename is unique to the run; afterwards the
    measurement removes exactly those names and its own `state-*.json` files, then the
    directories it created only if empty. **Never `rm -rf <root>`.**
  - The listing of `<passwd-HOME>/.gateguard/enabled/` before and after each state's run stays,
    but only as an *attribution* check — it proves a state-(ii) number was not reported as
    state (i). It is not the mutation control; the absent-`<root>` precondition is.
- The published figures, the method, and the pre-change baseline (the current registration,
  which in the default profile is a shell `case`) go in the PR body.
- **There is no in-process caching mitigation, and round 9's was inert.** It proposed a
  process-lifetime `cwd → main-worktree` memo. `run-with-flags.js:300-306` invokes `run()`
  exactly **once per process**, and every gated call is a fresh
  `sanitized-node.sh → node → runner` chain, so such a memo would be written and never read.
  A cache that survived the process would have to live on disk, which is a consent-adjacent
  file this design will not add (revocation must be immediate). So state (ii) has **no**
  mitigation short of the re-scope below — if it misses its budget, that is the decision.
- **If state (i) misses its budget the mitigation is a re-scope, not a workaround.** A cheap
  outer shell pre-guard is unavailable: any shell-side `$HOME` read is the repo-injectable
  channel this change closes. The wrapper's `--check` validation may not be weakened — it is a
  security control of the wrapped gates. The honest options are narrowing to the `Bash`
  registration or closing #616 as won't-fix with the bypass documented. That is the operator's
  call; the measurement is what makes it available.

---

## Verification

Each row names an observation that must be **seen**, and the bad build it must be seen
failing against. Which lane implements a row, and how, is implementation — except where the
lane is itself the point, in which case it is named.

**The numbering has gaps and they are deliberate.** V17, V17b, V17d and V18 moved to #712 with
the enrollment CLI, and V17c kept only its `saveState()` clause. Surviving rows are **not
renumbered**: prose throughout this document cites rows by number, and renumbering to close
cosmetic gaps would silently redirect every one of those references.

| # | Observation | Must be observed failing against |
|---|---|---|
| V1 | Enrolled repo, absolute payload `cwd`, first-touch Edit, fresh `session_id`, with all six channels injected (`ECC_HOOK_PROFILE=standard`, `ECC_DISABLED_HOOKS=<both ids>`, `GATEGUARD_DISABLED=1`, `ECC_GATEGUARD=off`, `GATEGUARD_STATE_DIR=/dev/null`, `ECC_DRY_RUN=1`) plus every `GIT_*` discovery/config variable, **plus `NODE_OPTIONS=--require=<probe>`** that touches a sentinel — on **both** registrations, **contained** ⇒ exit 0, a `deny` decision on stdout, and **the sentinel not created** | the pre-change tree for the six application channels. `NODE_OPTIONS` needs its own failing build — the *post*-change registration with the `/usr/bin/env -i` prefix removed — since against the pre-change registration `ECC_HOOK_PROFILE=standard` empties the `case` arm and nothing launches. **`PATH` is deliberately not probed this way**: `sanitized-node.sh:42-48` rebuilds `PATH` from fixed absolute dirs and `:134-144` selects node from that list, so an outer fake `node` cannot run even without `env -i` — a sentinel row for it would be a guard whose failure branch does not exist. `PATH` stays in the inventory as a channel `env -i` closes, without a row claiming to observe it |
| V2 | Marker absent ⇒ exit 0, no `permissionDecision` (payload echoed — today's allow shape) | a build that inverts the fail direction |
| V3 | Valid marker but no absolute payload `cwd`, process cwd `/` ⇒ allow | an implementation keying consent on `process.cwd()`, which under the wrapper is `/` |
| V4 | **With a marker present** (so the fast path does not short-circuit): an unreadable `cwd` and a spawn error each ⇒ allow, status `error`, no throw escapes `run()`, **and** the stderr line appears. A **non-repository `cwd`** ⇒ allow, status `absent`, **and stderr silent** — it is a not-applicable outcome, not a fault (§3's taxonomy). With **no** marker anywhere ⇒ allow and silent. **And the module loads even when the passwd home is underivable** — with `os.userInfo` patched to throw, `require()` of `gateguard-consent.js` still succeeds and `isEnabled()` returns `{status:'error'}`, **writing nothing**; the stderr line is observed separately, from the hook: `run()` on that same patched process emits exactly one line. Two observations, because they belong to two components — §3 pins the module as output-free and 5(c) places the write | an implementation without step 3's totality; a fast-path short-circuit that passes the row without running the probe; a build whose stderr write is a described behaviour rather than the placed line in 5(c)'s ordering block; a module that writes the line itself, which would satisfy a naive reading while breaking §3's invariant; and a module-scope `HOME: homeDir()` constant, which throws at `require()` time into `run-with-flags.js:280-284`'s silent-allow fallthrough |
| V5 | `git add -f` an in-tree `.claude/gateguard-enabled.local` with the out-of-tree marker present ⇒ gate fires; remove the out-of-tree marker with that file still committed ⇒ gate OFF | the round-1 design, where the in-tree file was the off-switch |
| V6b | **`hooks/gate-scripts/lib/sanitized-node.sh` AND the new `tests/test-gateguard-containment.sh` are both named in a *required* ShellCheck step** in `tests.yml`. The wrapper is the load-bearing half: `hooks/gate-scripts/*.sh` is a NON-recursive glob that never reached `lib/`, and the `scripts/hooks` pass ends `\|\| true`, so the script five blocking gates depend on was linted by no required step at all. A row naming only the test suite would let a build drop the wrapper and still pass | a new gate suite that lints nowhere, or only in a step whose failure is swallowed |
| V6 | Exactly the two GateGuard hook ids carry `--fail-open`, the wrapper and `\|\| exit 0`; no other registration contains `--fail-open`; `grep -c 'failing CLOSED' <wrapper>` is 0. A wrapper launch failure ⇒ wrapped gates block, GateGuard allows. A malformed argument list — duplicated leading flag, trailing flag, misspelled flag, **and an empty hookId or scriptPath** (`--fail-open "" "" "…"`, which satisfies arity) — blocks in the closed disposition, whichever registration it is on | a `--fail-open` that leaks to a wrapped gate; a `_block` that still prints block JSON in the open disposition; a malformed-argument check placed above `_block`'s definition; a leading-only duplicate check |
| V7 | The wrapped gates still exit 2 with `_block` JSON on a launch failure, and still exit 2 on a truncated payload; `tests/test-gate-env-containment.sh`, `tests/test-node-hook-containment.sh` **and `tests/test-run-with-flags-blocking.sh`** (which also drives the wrapper) pass unchanged | a wrapper change that regresses the four other contained scripts |
| V8 | The profile CSV in both registrations, split on `,`, equals `VALID_PROFILES` (`hook-flags.js:12`). And **uncontained** — the only shape where the CSV is load-bearing, since `env -i` wipes the variable — `ECC_HOOK_PROFILE=minimal` with a marker still denies | round 2's `"standard,strict"`, where `minimal` disables on any uncontained invocation |
| V9 | Deny text contains no `ECC_` name, no `GATEGUARD_` name and no `.gateguard` substring, **and** still contains "Present the facts, then retry the same operation." | the pre-change `withRecoveryHint()`, and a build that swaps the env recipe for the marker path |
| V10 | A marker keyed to the **main** worktree resolves enabled from both the main checkout and a linked worktree; one keyed to a linked worktree resolves OFF from both. Enrolling a `--separate-git-dir` repo records what the marker actually names | a resolver using `git rev-parse --show-toplevel` |
| V11 | An enrolled session denies the first touch and **allows** the retry, with no state-warning text on stderr | a `getStateFile` that drops the `activeStateFile` memo, which makes an enabled gate warn and allow every call |
| V12 | Two concurrent sessions with distinct `session_id`s do not observe each other's state, **including ids that differ only in a character `sanitizeSessionKey` would fold** (`a/b` vs `a?b`); a payload with no `session_id` and no `transcript_path` is allowed and writes no state | the `process.cwd()` key collapsing to `/` under the wrapper, and the non-injective `:441-452` substitution |
| V13b | **`absent` and `unreadable` each perform ZERO `git` spawns** — observed by counting invocations, not inferred from the step-8 budget, which cannot distinguish "no spawn" from "a fast spawn". This is the property that makes `anyMarkerPresent()` a fast path at all | an implementation that resolves the identity before consulting the marker set, which spawns `git` on every gated call of every unenrolled operator |
| V13 | An unenrolled gated call performs **no `readdirSync` of `<root>`** — `lstat(<root>)` is required by the fast path and permitted, and `<root>/enabled` is the one directory the fast path may enumerate. Observed in both marker states. An enrolled session that writes state still removes a `state-*.json` older than `2 × SESSION_TIMEOUT_MS` | the module-scope prune IIFE, which reads at `require()` time on every invocation — and, if the const is merely deleted, throws at module load into a silent allow |
| V14 | An enrolled session editing a path outside the enrolled repo is still gated; a **Bash** payload is still gated; and a MultiEdit payload carrying its target **only per-edit** (no top-level `file_path`) is still gated. Note a top-level `file_path` MultiEdit is *not* the negative control — `:840-850` reads it — so the falsifiable shape is the per-edit-only one | a `file_path`-keyed consent check, which stops gating exactly the #615 shapes |
| V15 | No `hooks.json` command reaches `gateguard-fact-force.js` outside the wrapper. **In-process**, with `os.userInfo` patched to a temp home **and** `process.env.HOME` pointed at a *different* directory holding a planted 64-hex marker: `homeDir()` follows the patched `os.userInfo`, not `$HOME`, so `isEnabled()` is OFF for a repo enrolled only under the poisoned tree and ON for one enrolled under the patched home. Both halves run against temp directories — **nothing in this lane writes into the operator's real home**, which is a standing constraint on the in-process lane, not one V17 carried away with it | the pre-change bare-`node` registrations; round 4's `$HOME`-reading resolver; and an `os.homedir()` implementation, which the contained path alone cannot distinguish because the wrapper exports a passwd-derived `HOME` before node starts |
| V16 | **The `git` child is observed RECEIVING the environment, not merely offered one** — the spawn's options object is captured and its `env` compared against `gitEnv()`'s return. Asserting only what the factory returns is satisfiable by a build that defines a correct `gitEnv()` and then omits `env:` from the `execFileSync` call, inheriting the parent environment while containing no `process.env` token for any grep to find; V1 cannot catch it either, because its contained invocation has already had the hostile `GIT_*` variables stripped by `env -i`. Also: `process.env` appears nowhere in `gateguard-fact-force.js` or `gateguard-consent.js`, **and neither contains the literal `os.homedir(`**; `GATEGUARD_STATE_DIR`, `GATEGUARD_DISABLED` and `ECC_GATEGUARD` appear in neither those files nor `SKILL.md`; `BUSDRIVER_STATE_DIR` appears in none of them; and `SKILL.md` contains no `ECC_HOOK_PROFILE=strict` enable instruction. `gitEnv()`'s **returned object** has exactly the five specified keys, `LC_ALL: 'C'` among them, and its `HOME` tracks a mid-run change to the patched `os.userInfo` — the property a module-scope constant would fail | the pre-change file's six `process.env` sites; the surviving `allowWithStateWarning()` string; the repo's dominant `process.env.HOME \|\| os.homedir()` idiom; and an implementation that omits `env:` entirely, inheriting the parent environment while writing no `process.env` anywhere |
| V17c | `saveState()` prepares `<root>` through step 3's `ensureDirNoFollow()` — never `mkdirSync(..., {recursive:true})` — and **all three branches of the state machine are observed**, under a temp home: (a) `<root>` **absent** ⇒ created and the state write succeeds — asserted as **created and usable by its owner**, deliberately NOT as "exactly `0700`", because 5(b) concedes `mode` is a ceiling masked by the process umask and an exact-mode row would contradict it. (Measured: under `umask 0700` a `mkdir` requesting `0700` yields mode `077`, stripping the owner's own permissions; the state write then fails and the call lands on `allowWithStateWarning()` — gate off, warning on stderr. That is a **declared residual**, listed in "What this does NOT do": an exotic umask disables GateGuard loudly rather than silently, which for a non-boundary gate is the acceptable direction, and the gate deliberately never `chmod`s the operator's home to paper over it); (b) `<root>` an **ordinary pre-existing directory** ⇒ the state write succeeds with no EEXIST; (c) `<root>` a **symlink** ⇒ refused, nothing written into the target. (b) is the row that matters most and the one an earlier draft had no coverage for: it is the dominant real-machine state, and an "assert then create" implementation passes (c) while failing (b) silently into `allowWithStateWarning()`. (V17, V17b, V17d and V18, and this row's CLI half, moved to #712 with the helper. This clause stayed because it verifies 5(b), which this change still ships — the split is deliberate, not a leftover) | the current `:523-527`, which is exactly the `recursive` shape 5(b) forbids; an "assert then `mkdirSync`" build, which throws ENOENT on (a) and EEXIST on (b), both landing on `allowWithStateWarning()` (`:793`); and a build that states the contract without exercising it |
| V3b | **The payload `cwd` contract is pinned, not assumed — and this row is OPERATOR-PERFORMED, not a CI lane.** Capture a real PreToolUse payload from each of the four gated tools (Edit, Write, MultiEdit, Bash) and confirm each carries an absolute `cwd`; the evidence goes in the PR body. It is classified this way because no automated lane can produce a *live harness* payload — a fixture asserting what the fixture itself wrote would be a guard that cannot fail, which is the defect this document keeps having to remove. What the automated lanes DO cover is the consequence, and the citations are exact because an earlier draft's were not: **V3** pins that a payload without an absolute `cwd` allows, and the in-process taxonomy row pins that such a payload classifies `absent` (so it stays silent). **V4 does not cover this case** — its silent-`absent` row is the *non-repository* `cwd`, which is a different input reaching the same classification by a different route. The whole consent path keys on it, and §3's taxonomy makes a missing `cwd` a *silent* `absent` — so a harness change that stopped sending it would disable every enrolled gate with no signal anywhere. The repo already treats payload `cwd` as established (`config-protection.js:83-93`, `pre-implementation-gate.sh`, `freeze-guard.sh`), which is why this is a pin rather than a redesign | a build where the field is assumed; and the silent-`absent` classification, which is correct for a genuinely repo-less call and indistinguishable from a harness regression |
| V19 | A `>MAX_STDIN` payload to an enrolled GateGuard registration ⇒ exit 0, no deny — the **declared, accepted** #612 residual, recorded so it is not forgotten | a build that leaves `--fail-closed` on GateGuard, hard-blocking unenrolled operators |
| V20 | All three lanes green: **`npm run test:coverage`** (not bare `npm test` — `package.json` defines that as `vitest run` with no coverage, and the in-process lane's whole stated justification is patch coverage, so the criterion has to name the command that measures it) **and** `bash scripts/ci/run-shell-tests.sh` for the contained lane. The resulting patch coverage for `scripts/lib/gateguard-consent.js` and the touched branches of `scripts/hooks/gateguard-fact-force.js` goes in the PR body. A `<passwd-HOME>/.gateguard` that existed before the run still holds **the same marker set and the same modes**. One that did **not** exist is left absent *unless the contained lane declined to remove it* — §7 removes its own entries by name and the directories only if empty, so a concurrent enrollment landing mid-run legitimately leaves `<root>` behind. That is the designed outcome, not a leak: the alternative is a whole-tree removal that destroys the concurrent enrollment. The observable post-condition is therefore "no marker and no state file this run did not create", which holds in both cases. The post-condition is deliberately *not* "byte-identical": on a live enrolled machine the operator's own session rewrites `state-*.json` on its ≥60 s heartbeat (`:591-596`), so byte-equality is unobservable — and under the rule above the suite never writes into a pre-existing `<root>` anyway, so markers and modes are the properties that carry the guarantee | the un-migrated driver fixture, where all eight #615 denies flip to allow; a contained suite that enrolls without restoring; a suite that lets step 5(h)'s prune delete the operator's state; and a completion criterion that names only `npm test`, which never executes the shell lane |

---

## Sequencing, and the #629 coupling

`tests/test-node-hook-containment.sh` guard #4 (`:122-133`) asserts every member of its
`CONTAINED` array is still found by the source-level `discover_exit2()` grep (`:93-98`:
`process.exit(2)`, `exitCode: 2`, `? 0 : 2`). `gateguard-fact-force.js` contains none of those
tokens — it denies via `exitCode: 0` + `permissionDecision` — so adding it turns guard #4
**red**, while leaving it out means guard #1 never covers it. Verified by running the grep the
guard runs; grok's R3 remedy of adding GateGuard to `CONTAINED` is not adopted on that
evidence.

1. This document → blueprint-review.
2. **#616 does not touch that suite.** Its own tests cover the wrapping; the containment
   suite stays as green as it is today (V7).
3. **#629 replaces `discover_exit2()` and guard #4** with registration-derived detection keyed
   on an **anchored tuple** — a leading `/usr/bin/env -i`, the exact `sanitized-node.sh`
   reference, the disposition (`--fail-open` present, or absent meaning the closed default
   `:193` supplies), and the matching outer tail (`|| exit 0` for a fail-open consumer,
   `|| exit 2` for a fail-closed one). Anchoring matters: a bare "mentions the wrapper" test
   would match a registration that names it without launching under containment, and the
   disposition alone says nothing about what the outer shell does with a non-zero. Absence of
   the flag means the
   closed default. Not on a `--fail-closed` token: it appears in `hooks.json` today only at
   `:151`/`:161` — GateGuard's own bare-`node` registrations — which step 2 deletes, while the
   wrapped gates never carry it (`sanitized-node.sh:193` appends it). After this change the
   token is in no registration at all. GateGuard then classifies as a *contained, fail-open*
   hook, a third category the current binary array cannot express, which is why #629 owns the
   suite change and #616 does not.

---

## What this does NOT do

- **It does not make GateGuard always-on.** That was option (a) — deny on first touch of every
  file in ordinary sessions, an operator-experience change not asked for.
- **It changes strict-profile behaviour.** A session launched `ECC_HOOK_PROFILE=strict claude`
  loses GateGuard until the repo is enrolled. Stated because a gate that stops firing is
  indistinguishable from one that is working.
- **It reopens #612 for GateGuard — accepted by the operator on 2026-08-20, no longer awaiting
  sign-off.** A `>MAX_STDIN` payload is allowed unchecked, because both registrations drop
  `--fail-closed`. Everything else here follows from the settled option (b); this did not —
  #612 was a shipped fix, and un-shipping it for the enrolled case was a scope call the
  2026-08-11 comment did not cover, so it was raised separately and granted.

  It is taken because the alternatives are worse and there is no third: keeping `--fail-closed`
  hard-blocks every Edit/Write/Bash of operators who **never enrolled** the moment one
  oversized payload appears (the inversion round 3 caught), and the in-hook truncation deny
  provably cannot work — the deny precedes the parse, so `markChecked()` never runs and the
  retry loops forever (round 6). What is lost is bounded: an oversized Write skips a *quality*
  prompt on a gate that is explicitly not a boundary, for an operator who opted in. What is
  kept is that no unenrolled operator is ever hard-blocked by infrastructure.

  **Decided, not deferred.** An earlier draft marked this "flagged for sign-off", which left the
  blueprint decision-incomplete — a plan that defers its own scope call is not implementable.
  The decision is: **accept the residual**, and the operator confirmed it on 2026-08-20. It is
  recorded in this section so a reader meets it, restated in the PR body so it is visible at
  merge, and reversible in one token per registration plus V19's inversion. The wrapped gates
  are unaffected either way. V19 observes it; `SKILL.md` tells the operator to split the write.
- **A repository on a foreign-owned volume resolves `error`, and the usual remedy is
  unavailable by construction.** Step 3 pins `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` to
  `/dev/null` so a poisoned `~/.gitconfig` cannot steer the probe — but those are also the only
  scopes where `safe.directory` can live, and git ignores it from repo-local config precisely
  because that would defeat the ownership check. So an enrolled repo whose worktree is owned by
  another uid makes `git worktree list` fail, the gate goes OFF, and the operator's standard
  fix cannot be applied to this probe. Not fixed with `-c safe.directory`: that would disable a
  real security control inside a design whose whole subject is not weakening controls for
  convenience. The remedy is ownership of the checkout. Rare on a single-operator machine, and
  it fails to OFF with the step-3 diagnostic, which is the safe direction for a non-boundary
  gate.
- **An exotic umask can disable the gate, loudly.** `mkdir`'s `mode` is masked by the process
  umask, so under `umask 0700` a directory requested at `0700` is created `077` — the owner
  loses access to their own state root, `saveState()` fails, and every gated call of an enrolled
  operator lands on `allowWithStateWarning()`: gate off, warning on stderr. The gate does not
  `chmod` its way out of this, because repairing modes under the operator's home is the one
  thing 5(b) refuses to do. Rare, loud, and in the safe direction for a non-boundary gate; the
  remedy is the operator's umask. V17c therefore asserts the root is created **and usable**,
  not that it is exactly `0700`.
- **Consent resolution is total and fails to OFF.** Any condition breaking the `git` probe —
  git absent, an unreadable cwd, the 2 s timeout, no passwd entry — disables the gate. The
  erroring-OFF diagnostic (V4) makes that *diagnosable* by someone reading stderr; it does not
  make it noticed. Silent for the unenrolled by design.
- **It is POSIX-only, and today's registrations are not.** `gateguard-fact-force.js:17` claims
  "Cross-platform (Windows, macOS, Linux)", and the bare-`node` registrations can fire there
  today. After step 2 they are `/usr/bin/env -i … bash sanitized-node.sh … || exit 0`, which
  does not start on native Windows — and `|| exit 0` then allows. The five wrapped gate
  registrations are already POSIX-only in exactly the same way, so this aligns GateGuard with
  its siblings rather than introducing a new gap; a Windows launcher is out of scope for #616.
  Step 5 strikes the "Cross-platform" line from `:17`.
- **Revocation is repo-global and persistent; there is no session-local pause.** The deleted
  `ECC_GATEGUARD` / `GATEGUARD_DISABLED` / `ECC_DISABLED_HOOKS` levers were per-session by
  construction — start one session with the variable set and other sessions were unaffected.
  A marker is per-repo and durable, so removing it disables GateGuard for **every** concurrent
  session and every linked worktree of that repo until it is recreated. Consent is
  re-evaluated per call (5(d)), so the effect is immediate rather than at the next session
  start — which is the right trade for revocation and the wrong one for "quiet this session
  only". A session-local pause is a named follow-up, not part of this change.
- **Wrapper failures split into two classes, and only one of them allows.** Round 9 lumped
  them together, contradicting step 1.
  *Launch and infrastructure failures* — unresolvable `CLAUDE_PLUGIN_ROOT` (`:101`), missing
  runner (`:107`), failed `cd /` (`:120`), no compatible node (`:147`), a traversal-rejected
  hook path (`:167`), missing hook script (`:171`), any runner exit outside `{0,2}` (`:198`)
  — run in the **open** disposition and resolve to **allow**. That is step 1's intended trade:
  the alternative hard-blocks operators who never enrolled.
  **They are effectively silent, and this document no longer claims otherwise.** Each writes
  a stderr line, but 5(g) rejected stderr as a channel precisely because "a solo operator
  never reads that stream", and the same is true here — carrying both claims was an internal
  contradiction. The stderr lines are best-effort diagnostics for someone already debugging,
  not a guarantee that a disabled gate announces itself. The same qualification applies to
  step 3's erroring-OFF diagnostic: it makes the fault *recoverable* once someone looks, not
  *noticed*.
  *A malformed argument list* (`:163` and the new arity/emptiness check) is **not** in that class: step 1
  forces `_disposition="closed"` there, so it prints block JSON and exits 2 whatever the
  registration asked for. A malformed registration is a bug in code that ships with the
  plugin, not an operator-environment condition, and it must be loud.
  One consequence of that split is worth stating plainly: because the GateGuard registrations
  end `|| exit 0`, the forced-closed path exits 0 at the shell while its `{"decision":"block"}`
  still reaches stdout — so the harness blocks on the stdout decision, not on the status. The
  block takes effect; the exit code does not carry it.
- **Consent is not protected against a process with shell access** — see the threat model,
  which states plainly that this is a new power, not a wash.
- **A dotfiles-as-worktree home is a residual, documented but not detected and not prevented.**
  Earlier rounds attached a best-effort work-tree notice to `--on`; with the enrollment CLI in
  #712 there is no `--on` here, so under this change the topology is **documented only** — no
  code detects it. The warning ships with #712. The analysis: if the passwd home is itself a
  working tree, `~/.gateguard` is reachable by a merged change to *that* repo. An untracked
  marker can only be *added* by such a commit — friction, the safe direction. But once a marker
  is **tracked** by that dotfiles repo, a merged change can delete or replace it, which switches
  GateGuard OFF: the exact polarity this design exists to prevent, reappearing in a topology the
  marker location did not anticipate. What bounds it: the topology is not reachable from a PR
  against a *gated* repository, which is #616's threat model. Even in #712 the notice will be a
  notice and not a control — it will not refuse, and it cannot see a `~/.gateguard` that is
  itself a repository, because git discovery walks upward only. Closing the topology properly is
  a further follow-up, named in #712.
- **With a separate git dir or inside a submodule, the first porcelain record is the
  administrative directory, not the checkout.** Git derives it from the common git dir with a
  trailing `/.git` stripped (in git's own `get_main_worktree()` — that function is git's, it
  exists nowhere in this repository); under `git init --separate-git-dir`, and in a submodule
  whose common dir is `<super>/.git/modules/<name>`, there is no suffix to strip. Consent
  still resolves **consistently** — one routine computes both the enrolled and the checked
  identity — so the gate fires correctly; what bends is that the identity is not
  `realpath(checkout)`, the recorded marker contents name an administrative path, and relocation
  does not revoke when the gitdir stays put.
  Two in-tree treatments exist and neither is adopted wholesale: `design-clear.sh:310-313`
  tests `[ ! -e "$_MAIN_WT/.git" ]` and falls back to the **checkout** (`$SELF_ROOT`), and
  `enable-advisory-downgrade.py:167-175` distinguishes the case with
  `rev-parse --is-inside-work-tree` on the first record. Adopting `design-clear.sh`'s shape
  here would key a separate-gitdir repo to the *current* checkout, which for a linked worktree
  is not the main one — reintroducing exactly the per-worktree identity split V10 exists to
  prevent. So this is recorded as a residual, with the follow-up named: the correct fix is
  `enable-advisory-downgrade.py`'s discrimination, not `design-clear.sh`'s fallback. V10
  records what the marker actually names.
- **It requires git ≥ 2.36 for `worktree list --porcelain -z`.** That is a real floor, and it
  is the floor `scripts/design-clear.sh` already imposes unconditionally, so #616 introduces
  no new one. `enable-advisory-downgrade.py:160-165`'s in-tree claim that `-z` needs 2.40+ is
  wrong (the git 2.36.0 release notes introduce it); that file is a separate follow-up, not a
  #616 change.
- **Relocating an enrolled repo silently revokes consent, and under this change the orphan is
  neither reported nor conveniently removable.** Since `anyMarkerPresent()` is machine-global,
  one orphan keeps the whole machine off the no-spawn fast path. Orphan *reporting* arrives with
  #712's `--list`, and an `--off-hash`/`--prune-orphans` mode is named there as a further
  follow-up; until then the operator's recourse is step 4's **LIST** command, which resolves the enabled
  directory **through the module** and marks any entry whose recorded path no longer exists, then
  `rm` of that filename. Two things it is deliberately not: not `ls ~/.gateguard/enabled/`, since
  `~` expands from `$HOME`, which this design establishes may name a different tree from the
  passwd-derived one the gate consults — that instruction can show an empty directory while the
  real orphan keeps the machine off the fast path; and not STATUS, which answers for one repo
  path and so cannot find a marker whose repo no longer resolves. LIST is the only mode that
  reads marker contents, which is the human-audit purpose the byte format is pinned for. Recorded as a real ergonomic gap of the interim manual
  procedure, not glossed as reporting the change does not ship. Content-addressing the repo
  instead was rejected: a fresh clone would inherit consent the operator never gave it there.
- **State-file accumulation is bounded, and the claim rounds 4-5 made here was wrong.** They
  recorded that dead-session files are never revisited; in fact the prune at `:601-621`
  already unlinks every `state-*.json` older than `2 × SESSION_TIMEOUT_MS`. Step 5(h) changes
  *when* it runs, not *what* it removes. An operator who enrolls, accumulates and then revokes
  leaves the last batch until the next enrollment — a handful of small JSON files.
- **It does touch `sanitized-node.sh`.** Round 2 claimed the change edits "GateGuard's two
  lines and nothing else"; false, given `:193`'s unconditional append. It still does not touch
  the four other contained scripts (V7). The narrower original claim stands: the wrapper has
  **no** trusted-var allowlist — the re-import is written per-registration in `hooks.json` —
  so no "shared allowlist contract change" is required, which is the premise this issue was
  filed under and is wrong.
- It does not land #629.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
