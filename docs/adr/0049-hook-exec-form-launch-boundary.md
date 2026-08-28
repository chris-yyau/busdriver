# ADR 0049 — Exec-form launch boundary for the contained gates

**Status:** Accepted (2026-08-28)
**Issue:** #713 · **Residual tracker:** #777
**Relates to:** ADR 0016 (gate env containment) — *named residual closed, ADR not amended*;
ADR 0044 (docs-only carve-out) — *kept, not retired*; ADR 0005 / 0013 / 0024 (Codex nudge).

## Context

ADR 0016 contained every gate under `/usr/bin/env -i` so that a committed
`.claude/settings.json` `env` block — repo-controlled input — could not reach a gate's
process. It named one class as out of scope (`0016:210-228`): state that affects the
**outer shell**, before containment starts.

That residual is live. Claude Code runs a **shell-form** command hook via `/bin/sh -c
<string>` and merges the committed `env` block into that shell's environment. Where
`/bin/sh` is bash (macOS ships 3.2.57), `SHELLOPTS=noexec` makes the shell **parse the hook
command and exit 0 without executing it**. Everything in the registration is downstream of
that decision: `env -i`, the wrapper, the gate, and the trailing `|| exit 2`. `env -i`
sanitizes the child it launches; it cannot sanitize the parent deciding whether that child
runs at all. There is no hardened shell string — the outer shell decides before any text in
the string is interpreted — so no prefix, quoting or ordering could have defended it.

Measured on the operator host (macOS, `claude` 2.1.248), in a throwaway scratch project:

| Probe | Result |
|---|---|
| exec-form `/usr/bin/env -i … /bin/bash` under committed `SHELLOPTS=noexec` | **runs**; a shell-form sibling in the same settings file is **silenced** (clean A/B in one run) |
| stdin JSON to an exec-form hook | arrives intact (695 bytes); `env -i` scrubs `HOME`/`BASH_ENV`/`SHELLOPTS` as designed |
| exit 2 · legacy `{"decision":"block"}` · `permissionDecision: deny` · `ask` | all **honoured** under exec form; `ask` is neither a silent allow nor a silent deny |
| `SHELLOPTS=xtrace` + `PS4='$(cmd)'` in a committed `env` block | **executes `cmd`** through a shell-form launch; **never runs** under exec form |
| `exit 1` | **does not block** — only exit 2 does |
| bare `/usr/bin/env` (no operands) | **exits 0 and prints the environment** — why `command` is no longer `env` |
| `contained-launch.sh` with no operands | **exits 2, empty stdout** (R7 closed) |
| `contained-launch.sh closed … <missing wrapper>` | **exits 2** (R8 closed); the same under `open` exits 0, as its rows always did |
| `#!/bin/bash` vs `#!/bin/bash -p` under `BASH_FUNC_*` + `SHELLOPTS=xtrace` + `BASH_ENV` | plain: function imported, xtrace on, BASH_ENV sourced. `-p`: **none of the three** |
| committed `"disableAllHooks": true` | **silences every hook, exec form included** |

Read from the shipped 2.1.248 bundle: exec form is a direct argv spawn (`vt` is built only
when `args` is present; the shell branch is reached only otherwise); `${CLAUDE_PLUGIN_ROOT}`
is substituted into `command` and into **each** `args` element; a backgrounded (`async`)
hook returns `status: 0` with no decision — an ALLOW.

## Decision

Move **17 of the 19 contained registrations** in `hooks/hooks.json` from shell form to
**exec form** (`command` + `args`), spawned as a direct argv with no shell between Claude
Code and the plugin's own first hop. This is the whole change: the wrappers, the gates and the 31
advisory registrations are untouched.

**Two registrations are deliberately NOT migrated** — `codex-nudge-premerge.sh` and
`codex-nudge-precreate.sh`. They POST `@codex review` comments, and the operator kill switch
`PR_GRIND_CODEX_RETRIGGER=0` is what suppresses that. Exec form cannot forward it: only
documented path placeholders are substituted, so a `${PR_GRIND_CODEX_RETRIGGER:-}` capture
would ship as a literal string, and `env -i` would then strip the real value. The hook also
runs its delegate (`codex-nudge-if-expected.sh` → `codex-retrigger.sh`) as a **child of the
`env -i` process**, so the delegate would read the switch as unset too — measured, not
inferred. Migrating them would therefore have silently re-enabled an **outbound** side effect
for an operator who had turned it off. Both are non-gating (one always exits 0, the other is
PostToolUse), so an outer-shell `SHELLOPTS=noexec` silencing them skips a nudge rather than
bypassing a gate. They are pinned **verbatim** in CI, not by grammar: a substring-keyed
exemption would be the same self-selecting hole the population count exists to close.

**Be precise about what that costs, because "only a skipped nudge" is not the whole truth.**
The outer shell is not merely a silencing channel — it is a code-execution one:
`SHELLOPTS=xtrace` together with a command-substituting `PS4` makes bash run arbitrary
commands *before* it runs the hook (measured both ways; the same probe fires nothing under
exec form). Every shell-form registration carries that channel. What makes the exemption
acceptable is not that a nudge is harmless but that the **marginal** exposure is zero: 31
advisory registrations were already shell form and untouched by this change, so the channel
has 31 other carriers whether or not these two migrate. See residual **R10** — the class is
narrowed to the gates, not eliminated from the plugin.

```jsonc
"command": "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/contained-launch.sh",
"args": ["closed", "PATH=/usr/bin:/bin", "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}",
         "/bin/bash", "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-gate.sh",
         "careful-guard.sh"]
```

`bash` becomes `/bin/bash` (absolute), removing the PATH lookup `env` performed.

**`command` is the plugin's own first hop, not `/usr/bin/env`.** `contained-launch.sh`
(`#!/bin/bash -p`) applies `env -i` itself and exists to make the failure modes that were
first shipped as accepted residuals fail CLOSED instead:

- **With no arguments — or with a tail that lost its program — it exits 2 and prints
  nothing.** The bare-`command` case is the shape a client takes when it drops `args`
  entirely; the partial case matters just as much, because `env -i NAME=value` with no
  utility after the assignments does not fail, it applies them, **prints the environment and
  exits 0**. A tail of only assignments, and a non-absolute program (which the sterile child
  would resolve by PATH lookup), and a program given **no operands at all** are all refused.
  That last one is the sharpest: every registration passes the wrapper path after
  `/bin/bash`, so a tail truncated to end exactly there leaves bash with no script — and a
  bash with no script and a non-tty stdin **reads its source from stdin**, which here is the
  hook payload. Naming bare `/usr/bin/env` as `command`
  meant an args-dropping client ran `env` with no operands: an allow on every gate plus a
  per-event environment dump. That was **R7**.
- **Its first argument is the launch-failure disposition** (`closed`, or `open` for the two
  GateGuard rows that carried `|| exit 0` before this change). Any status that is not a
  decision — 127 for a missing wrapper, 126 for a non-executable one, 1 for a wrapper that
  refused its own arguments — resolves to that disposition, which is what the shell-form
  `|| exit 2` tail used to do and is now **declared per registration rather than inferred
  from a string**. That was **R8**. CI pins the disposition against the wrapper's own
  `--fail-open` flag, so the two spellings cannot disagree.

**Why a bash first hop is admissible when the design originally rejected one.** The
objection was that bash imports exported shell functions from the environment — a
`BASH_FUNC_exec%%` overrides the `exec` BUILTIN — and honours SHELLOPTS, BASH_ENV and ENV,
every one of them settable from a committed `env` block. That is true of `#!/bin/bash`. It
is **not** true under `-p`: privileged mode ignores SHELLOPTS/BASHOPTS, skips BASH_ENV and
ENV, and refuses to import functions. Measured in both directions — a plain `#!/bin/bash`
under the hostile environ reports `function` / `xtrace on` / `BASH_ENV sourced`; the same
script with `-p` reports none of the three. The launcher uses builtins and absolute paths
only, so no PATH lookup happens in it. Loader variables stay residual **R2**, unchanged:
`/bin/bash` is SIP-protected exactly as `/usr/bin/env` was, so the first-hop exposure is the
same binary class it always was. `-p` is pinned statically *and* behaviourally in CI.

### What could not be transcribed, and why each is safe

Exec form substitutes only documented path placeholders; `$HOME` and friends would pass
through as literal text. Each dropped value was dispositioned rather than assumed:

| Dropped | Why it is safe |
|---|---|
| `HOME="$HOME"` (17 rows) | Provable no-op. Both wrappers re-derive `HOME` from the password database in a sterile `env -i` child and `export` over whatever was passed (`sanitized-gate.sh:105-118`), or `unset HOME`. The forwarded value never reached a gate. |
| `CLAUDE_HOOK_EVENT_NAME` (7 rows) | **The platform never sets it** — zero occurrences in the 2.1.248 bundle, and a live probe showed it unset on both PreToolUse and PostToolUse. It has always forwarded the empty string. Every consumer reads it as `env.X \|\| <default>`, so empty and unset are identical. Passing a literal event key would have *newly enabled* `mcp-health-check.js`'s `handlePostToolUseFailure` branch (`:720-723`), which is unreachable today — a behaviour change beyond this ADR's scope. Left dropped; enabling that branch is separate work. |
| `XDG_CONFIG_HOME`, `BUSDRIVER_ORIG_HOME` (1 row) | Residual **R3**, accepted. Behaviour is unchanged for any operator whose session `HOME` equals their passwd home and whose `XDG_CONFIG_HOME` is unset or `$HOME/.config`. ADR 0044's carve-out is **kept**. |
| `PR_GRIND_CODEX_RETRIGGER` (1 row: `pre-merge-gate.sh`) | Residual **R9**, narrowed. The two rows where this knob has an **outbound** effect are the nudges, and they are not migrated (above), so `@codex review` comments stay suppressed. What is lost is the one remaining reader: `pre-merge-gate.sh`'s `codex_none_warning`, the ADR 0024 missing-Codex advisory. It is **read-only — it posts nothing** (verified: neither `codex-premerge-warn.sh` nor `codex-active-repo.sh` contains a write call), so an operator with `=0` now gets its bounded `gh` read and its warning at merge time instead of the promised "zero network, zero output". Advisory noise, not an outbound action. |
| `\|\| exit 2` / `\|\| exit 0` tails (7 rows) | **Replaced, not lost — R8 is closed.** Exec form has no shell to interpret a tail, so for one round a launch failure *before* the wrapper starts was fail-open. `contained-launch.sh` now performs the same conversion from a declared per-registration disposition, and does it for the 12 `sanitized-gate.sh` rows as well — those never carried a tail, so their launch failures were fail-open before #713 too. |

## Consequences

**Closed, for the gates.** ADR 0016's named outer-shell residual, for the shell-option and
exported-function class: `SHELLOPTS`, `BASH_ENV`, `ENV`, `PS4` and `BASH_FUNC_*` set in a
committed `env` block can no longer reach a contained **gate** — neither to silence it nor to
execute code ahead of it. ADR 0016 is **not amended** — this closes a residual it named.
It closes it for the 17 gates only; see **R10** for what the plugin still carries.

**Also closed, in a later round (Hermes CLOSE_R7_AND_R8):** the two launch-failure residuals
this ADR first shipped as accepted — **R7** (an args-ignoring client) and **R8** (a wrapper
that never starts). Both now fail CLOSED through `contained-launch.sh`. See the Decision
above and the residual list below; the revisit trigger for them is spent.

**Residuals — named, tracked in #777, not closed.**

- **R1 — `disableAllHooks: true`.** A committed project settings file silences every hook,
  exec form included (measured). Not closable inside a plugin: no hook runs to defend
  itself. Mitigation is out-of-repo only — global `core.hooksPath`, branch protection.
  **#713 is therefore not "fully fixed".**
- **R2 — loader variables against the first hop.** `/usr/bin/env` is SIP-protected on macOS
  (dyld strips `DYLD_*`); on Linux `LD_PRELOAD` applies before `-i` can run. Unchanged by
  this ADR — the same binary was already the first hop.
- **R3 — undeclared divergent `HOME`/`XDG_CONFIG_HOME`.** Accepted. ADR 0044's carve-out is
  kept and **not** amended.
- **R7 — CLOSED.** A client that accepts `command` but ignores `args` used to run bare
  `/usr/bin/env`: exit 0 **and the environment printed** — an allow on every contained gate
  plus a per-event confidentiality leak. `command` is now `contained-launch.sh`, which in
  that shape exits 2 with an empty stdout. There is still no plugin-manifest version gate
  (`requiredMinimumVersion` is enforced only from managed policy settings, so it is optional
  org hardening rather than a shipped control) — but the degradation is no longer an allow,
  so the missing gate is no longer load-bearing. The two shell-form nudges were never
  affected: their whole command is one string. The PARTIAL loss shape counts too and was
  found in implementation review, not design: `env -i NAME=value` with no utility applies the
  assignments, prints the environment and exits 0, so a tail truncated after the disposition
  would have reproduced the whole residual inside the hop meant to close it. Worse, a tail
  truncated one element later — ending exactly at `/bin/bash` — was **arbitrary code
  execution**: bash with no script operand reads stdin, and stdin is the hook payload. A
  payload containing `$(touch …)` created the file, and bash then exited 0, so the gate
  allowed as well. Both refused now, along with a non-absolute program, and an exhaustive
  prefix sweep over a real registration argv keeps them refused.
- **R8 — CLOSED.** A missing or unreadable wrapper makes bash exit 127, which does not
  block, and the wrapper's own fail-closed paths cannot run when the wrapper never starts.
  The `|| exit 2` tail that used to convert that into a block cannot exist in exec form.
  The launcher's per-registration disposition restores it — and does so for the 12
  `sanitized-gate.sh` rows too, which never carried a tail at all, so a launch failure there
  was fail-open before #713 as well. It also subsumes the separate finding that
  `sanitized-gate.sh`'s own refusal paths `exit 1`, which does not block: 1 is not a
  decision, so it now resolves to the declared disposition. Pinned by an INVERTED assertion
  at `tests/test-gate-env-containment.sh`, with a control row proving raw bash without the
  launcher is still fail-open, so the row cannot pass vacuously.
- **R10 — the outer-shell channel still exists for the 33 shell-form registrations.**
  31 advisory hooks (never contained, out of scope for ADR 0016) plus the 2 nudge
  exemptions. `SHELLOPTS=xtrace` with a command-substituting `PS4` executes arbitrary
  commands from a committed `env` block through any of them — verified. This is
  **pre-existing and unchanged in magnitude** by #713: the same 31 carriers existed before,
  so the exemptions add no new exposure, and the 17 gates that could be silenced this way
  no longer can. It is named here because ADR 0049 must not read as "the class is gone" —
  it is narrowed to the surfaces that were never gates. Closing it means migrating the
  advisory registrations too, which is a separate change with a separate blast radius.
- **R9 — the merge gate's missing-Codex advisory no longer honours
  `PR_GRIND_CODEX_RETRIGGER`.** Scoped down to exactly that. R9 was first drafted as a
  bounded no-op ("the delegate honours it too"); the implementation reviewer challenged
  that, and the challenge was right — the delegate runs as a child of the `env -i` process
  and reads the switch as unset. Rather than accept the resulting **outbound** effect, the
  two registrations that actually post were left in shell form (see Decision). What remains
  is `pre-merge-gate.sh`'s read-only `codex_none_warning`: an operator with `=0` gets a
  bounded `gh` read and a visible warning at merge time. Nothing is posted, and merge
  authority is untouched. **Do not restate this as "the operator keeps the kill switch"
  unqualified** — the switch reaches the two nudges and no longer reaches the advisory.

**Enforcement.** `scripts/ci/validate-hooks.js` pins the launch form fail-closed: `command`
must be `contained-launch.sh` and is explicitly refused if it is bare `/usr/bin/env` again,
`args[0]` must be a known disposition that agrees with the wrapper's `--fail-open` flag (with
the `open` population pinned at 2), `args[1] == "PATH=/usr/bin:/bin"`, an assignment allowlist
(`CLAUDE_PLUGIN_ROOT`, `CODEX_WARN_OUTER_BUDGET`), a `${CLAUDE_PLUGIN_ROOT}`-rooted wrapper
operand, no `|| exit` tail, and no `async: true`. Detection by substring plus pinned
population counts — **19 contained, of which 17 exec form and 2 shell-form exemptions** —
because detection alone is self-selecting: a mutation that removes the wrapper reference
also removes the row from the population the grammar guards, and a total-only count would
let a real gate be swapped into the exemption set. The two exemptions are matched against a
**frozen literal command string**, which subsumes the grammar: it pins every forwarded knob
and refuses a one-character drift.

The roster is pinned by **identity, not count**: each contained registration is recorded as
`<event>|<matcher>|<full operand tail>` and the sorted list compared to a literal. Counts say
how many contained gates exist, never *which* — so a gate swapped for a duplicate of another,
moved to an event it never fires on, re-pointed at a matcher it never sees, narrowed from
`standard,strict` to `strict`, aimed at a different runner script, or flipped to
`--fail-open` all preserve 17/2 and silently disable a gate. Each of those is a mutation in
the suite below.

Assignment **values** are pinned, not only names — `CLAUDE_PLUGIN_ROOT=/not-the-plugin`
would otherwise satisfy every count and grammar check while the wrapper's own refusal path
exits 1, which does not block — and `CODEX_WARN_OUTER_BUDGET` must equal the registration's
own `timeout` (ADR 0024 keeps them co-located; nothing enforced it until now). The wrapper
operand is pinned in full rather than by prefix, so a near-miss such as
`…/sanitized-node.sh.disabled` cannot be counted-but-unlaunchable.

CI also **runs the first hop**, rather than reading it: `contained-launch.sh` is executed
with no arguments on every validation and must exit 2 with an empty stdout, its shebang must
be `#!/bin/bash -p`, and it must still print its own refusal message under an imported
`printf` function — three checks because the R7 defence lives in that script, not in
`hooks.json`, and a matrix that only mutates the JSON would leave the actual defence unproven.

`tests/test-validate-hooks-launch-form.sh` drives **36 named mutations** against copies of the
document and asserts the validator rejects each, with a green control so the suite cannot
pass by rejecting everything: launch form (shell-form revert, dropped `-i`, reordered `-i`,
empty `args`, `args` collapsed to one joined string, widened `PATH`, `async: true`, a
smuggled `|| exit 2` tail), assignments (`SHELLOPTS=noexec` injected, `CLAUDE_PLUGIN_ROOT`
repointed, a duplicated assignment with a divergent value, the budget dropped, the timeout
drifted), the wrapper operand (`.disabled` suffix, unrooted path, bare `bash`), and the
population counts (a gate deleted, a gate given the exemption's own command string, a nudge
migrated to exec form, a nudge drifted by one element, a nudge deleted), and the roster
(gate swapped, event moved, matcher re-pointed, profiles narrowed, runner swapped,
disposition flipped to `--fail-open`, a timeout zeroed, a timeout and its advisory budget
lowered together), the first hop (`command` reverted to bare `/usr/bin/env`, `command`
repointed elsewhere, the disposition dropped, an unknown disposition, a closed gate flipped
open, an open row flipped closed, and a *tandem swap* that keeps both populations intact),
and the launcher script itself — restored from a byte-exact backup on every exit path —
(no-arg path weakened to exit 0, made to print the environment, privileged mode dropped from
the shebang). It then drives the launcher directly: named partial-argv shapes
(disposition only, disposition plus assignments, a relative program), and an **exhaustive
prefix sweep** that takes a real registration argv out of `hooks.json` and feeds the launcher
every proper prefix of it, requiring exit 2, an empty stdout, and no execution of a payload
whose command substitution would fire if anything interpreted it as shell source. The sweep
is what caught the prefix ending at `/bin/bash`; the hand-written list had missed it. Positive
controls follow every sweep, so a launcher that blocked everything could not pass. It then runs an
**exhaustive sweep** — every single-element deletion and duplication of one registration's
argv — because a hand-picked list only catches holes someone already imagined. The sweep
earned its place immediately: it found that dropping the `CLAUDE_PLUGIN_ROOT=` assignment
satisfied every rule while leaving the wrapper unable to resolve its gate (exit 1, which
does not block), and that a duplicated assignment passed whenever both copies happened to
agree. Both are now refused, as are the operands *after* the wrapper — pinning the launch
form but not its arguments left the same shape of hole, since deleting a trailing gate name
keeps the row counted and the wrapper merely exits 1. Hand-run mutations proved the pins
once; this file is what keeps them proven.
`tests/test-hook-exec-form-713.sh` asserts the 17/2 split independently, including that both
nudges still forward `PR_GRIND_CODEX_RETRIGGER` — the property whose loss the exemption
exists to prevent.

**Revisit trigger.** *Spent for R7 and R8 — both are closed above.* Remaining: Claude Code
gaining a manifest-level minimum-version gate (would let the plugin refuse an old client
outright rather than merely failing closed under one); refusing loader/shell-behaviour keys from repository-controlled `env` (retires R6
upstream); or an exec-form launcher that fails closed on a missing operand (retires R8).

## Alternatives considered

- **A capture-first-hop** (`/usr/bin/python3 -I` reading the session environ, allowlisting,
  then `execve`) would have given exact parity on the five dropped values. Rejected: the
  first hop must itself be immune to the channel being contained. `/usr/bin/python3` on
  macOS is a Command Line Tools stub whose absence turns a silent fail-open into a live
  gate-loss mode, a Homebrew `python3` is `DYLD_*`-injectable from the very settings block
  under containment, and it adds a new trusted script to the boundary.
- **Native `${user_config.KEY}`** for the dropped operator values. Rejected: it is
  substituted only in a plugin context, and this repo supports 10 install targets — the
  `claude`/`claude-project` adapters materialize `hooks.json` with `${CLAUDE_PLUGIN_ROOT}`
  pre-substituted *by the installer* (`scripts/lib/install/apply.js:90-115`), which is
  itself proof those destinations load as ordinary non-plugin hooks. The placeholders would
  ship as literal strings there, making the kill switch inert on a whole class of installs.
- **Restoring the `|| exit 2` tail inside the sterile child** — i.e.
  `… /bin/bash -c '<wrapper> "$@" || exit 2' bash <args>`. This is NOT a return to shell
  form: the outer `/bin/sh` is still gone, and `env -i` has already stripped `SHELLOPTS`,
  `BASH_ENV`, `ENV` and `BASH_FUNC_*` before this bash starts, so the string is parsed by a
  clean shell the committed `env` block cannot reach. It would close **R8** outright.
  **Superseded.** Authorized in a later round (Hermes CLOSE_R7_AND_R8) and then NOT taken in
  this form: `exec` replaces the process, so the `|| exit 2` never runs and a missing wrapper
  still exits 127 — measured. The non-exec spelling works, but putting the conversion in
  `contained-launch.sh` is better than either: it needs no shell string in `args`, it makes
  the disposition an explicit per-registration field CI can pin against the wrapper's own
  flag, and the same hop closes R7.
- **A hook-plane old-client detector.** Rejected: a script-spawned child always `execve`s
  its argv, so it cannot observe a client ignoring `args`; and the detector would itself be
  shell-form, hence silenced by the very `SHELLOPTS=noexec` it existed to catch.
