---
name: gateguard
description: Fact-forcing gate that blocks Edit/Write/Bash (including MultiEdit) and demands concrete investigation (importers, data schemas, user instruction) before allowing the action. Measurably improves output quality by +2.25 points vs ungated agents.
metadata:
  origin: community
---

# GateGuard — Fact-Forcing Pre-Action Gate

A PreToolUse hook that forces Claude to investigate before editing. Instead of self-evaluation ("are you sure?"), it demands concrete facts. The act of investigation creates awareness that self-evaluation never did.

## When to Activate

- Working on any codebase where file edits affect multiple modules
- Projects with data files that have specific schemas or date formats
- Teams where AI-generated code must match existing patterns
- Any workflow where Claude tends to guess instead of investigating

## Core Concept

LLM self-evaluation doesn't work. Ask "did you violate any policies?" and the answer is always "no." This is verified experimentally.

But asking "list every file that imports this module" forces the LLM to run Grep and Read. The investigation itself creates context that changes the output.

**Three-stage gate:**

```
1. DENY  — block the first Edit/Write/Bash attempt
2. FORCE — tell the model exactly which facts to gather
3. ALLOW — permit retry after facts are presented
```

No competitor does all three. Most stop at deny.

## Evidence

Two independent A/B tests, identical agents, same task:

| Task | Gated | Ungated | Gap |
| --- | --- | --- | --- |
| Analytics module | 8.0/10 | 6.5/10 | +1.5 |
| Webhook validator | 10.0/10 | 7.0/10 | +3.0 |
| **Average** | **9.0** | **6.75** | **+2.25** |

Both agents produce code that runs and passes tests. The difference is design depth.

## Gate Types

### Edit / MultiEdit Gate (first edit per file)

MultiEdit is handled identically — the batch's target file is gated on first
touch, reading `tool_input.file_path` and `tool_input.filePath` (where a real
MultiEdit payload carries it) and falling back to any per-edit `file_path` or
`filePath`. The code is the authority.

```
Before editing {file_path}, present these facts:

1. List ALL files that import/require this file (use Grep)
2. List the public functions/classes affected by this change
3. If this file reads/writes data files, show field names, structure,
   and date format (use redacted or synthetic values, not raw production data)
4. Quote the user's current instruction verbatim
```

### Write Gate (first new file creation)

```
Before creating {file_path}, present these facts:

1. Name the file(s) and line(s) that will call this new file
2. Confirm no existing file serves the same purpose (use Glob)
3. If this file reads/writes data files, show field names, structure,
   and date format (use redacted or synthetic values, not raw production data)
4. Quote the user's current instruction verbatim
```

### Destructive Bash Gate (every destructive command)

Triggers on: `rm -rf`, `git reset --hard`, `git push --force`, `drop table`, etc.

```
1. List all files/data this command will modify or delete
2. Write a one-line rollback procedure
3. Quote the user's current instruction verbatim
```

### Routine Bash Gate (once per session)

```
1. The current user request in one sentence
2. What this specific command verifies or produces
```

## Quick Start

### Option A: Use the ECC hook (zero install)

The hook at `scripts/hooks/gateguard-fact-force.js` **is registered** in
`hooks/hooks.json` as two PreToolUse entries — `pre:edit-write:gateguard-fact-force`
(matcher `Write|Edit|MultiEdit`) and `pre:bash:gateguard-fact-force` (matcher `Bash`).

Both registrations are **contained** exactly like the five wrapped security gates
(#616, ADR 0016): `/usr/bin/env -i … bash hooks/gate-scripts/lib/sanitized-node.sh
--fail-open <hookId> scripts/hooks/gateguard-fact-force.js "minimal,standard,strict"
|| exit 0`. There is no `case` guard and no `strict`-only argument any more, and the
hook contains **no `process.env` reference at all**.

**GateGuard is OFF by default and enabled per repository by an out-of-tree marker:**

```
<passwd-HOME>/.gateguard/enabled/<sha256(realpath(main-worktree))>
```

`<passwd-HOME>` is the home in your **passwd entry** (`os.userInfo().homedir`), not
`$HOME`. Consent deliberately lives outside the repository namespace: a pull request
against a gated repository is a set of files tracked by that repository, and it cannot
create, delete or modify anything under your passwd home.

**What this buys, stated exactly:** a gated repository cannot switch GateGuard off through a
committed `settings.json` `env` block **naming any of the six consent channels #616 closes or
`HOME`**, a tracked in-tree marker, or a repo-supplied `GIT_*` variable. The qualifier matters:
an `env` block can also carry `SHELLOPTS`, which acts on the shell that *invokes* the
registration, before `/usr/bin/env -i` is ever reached. Measured on this host,
`env SHELLOPTS=noexec /bin/sh -c 'echo EXECUTED'` prints nothing and exits 0 — the registration
is parsed and none of it runs, so no decision is emitted. That is a **plugin-wide** residual —
identical for the five wrapped security gates, and worse there, since a fail-CLOSED gate that
never runs cannot block — recorded in ADR 0016:21 and neither introduced nor closed by #616.
Exported shell functions (`BASH_FUNC_*`) are *not* in this class for these registrations —
though not for the reason an earlier draft of this file gave. It claimed a function can shadow
only a bare command name; that is false, since bash accepts a slash-containing function name and
it does shadow the absolute path when defined in-process. What protects these registrations is
the **import** boundary, which is the only channel a settings-borne `env` block has: bash
refuses to import a function whose name contains a slash. Measured on both shells here —
`env 'BASH_FUNC_/usr/bin/env%%=() { echo PWNED; }' /bin/sh -c '/usr/bin/env …'` prints
``error importing function definition for `/usr/bin/env` `` and runs the real binary, on bash
3.2.57 and 5.3.15 alike. A bash that ever permitted such an import would reopen this. It does **not** mean a checked-out repo can do nothing at
all — a committed project `settings.json` may carry keys beyond `env`, and a key that
disables hooks wholesale would defeat all five wrapped gates identically, before any
marker or `env -i` logic runs. That is a plugin-wide residual for ADR 0016's own threat
model, neither introduced nor closed here. Nor is it protected against a process with
shell access as you, which can simply delete the marker.

#### Enrolling a repository (manual — temporary, see #712)

The enrollment helper is issue #712. Until it lands, enrol by hand. `<PLUGIN_ROOT>` is the
installed plugin directory — two levels above this file:
`cd "$(dirname "<path to this SKILL.md>")/../.." && pwd`.

```bash
# ENROLL. Prints the marker path it wrote.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js"),f=require("fs"),i=g.resolveIdentity(process.argv[2]);g.ensureDirNoFollow(g.gateguardRoot(),0o700);g.ensureDirNoFollow(g.enabledDir(),0o700);f.writeFileSync(i.markerPath,i.realpath+"\n",{flag:"wx",mode:0o600});console.log("enrolled "+i.mainWorktree+"\n  marker "+i.markerPath)' "<PLUGIN_ROOT>" "/path/to/repo"

# REVOKE — deliberately NOT given here as a runnable command. See the note below.

# LIST every enrolment on this machine, with the repo path each marker records.
# The only way to find an ORPHAN: a marker whose recorded path no longer exists (the repo
# moved or was deleted). Do NOT substitute `ls ~/.gateguard/enabled/` — `~` is $HOME, which
# may name a different tree from the passwd-derived one the gate consults.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js"),f=require("fs"),pa=require("path");const none=()=>{console.log("  (nothing enrolled on this machine)");process.exit(0)};let d;try{d=g.enabledDir()}catch(e){console.error("cannot resolve passwd home: "+e.message);process.exit(1)}console.log(d);const bail=e=>{if(e.code==="ENOENT")none();console.error("  cannot read the enabled directory ("+(e.code||e.message)+") — GateGuard treats this as ERROR and stays OFF; check ownership/permissions, and that neither it nor its parent is a file or symlink");process.exit(1)};let es;try{g.assertDirNoFollow(g.gateguardRoot());g.assertDirNoFollow(d);es=f.readdirSync(d)}catch(e){bail(e)}const ms=es.filter(n=>/^[0-9a-f]{64}$/.test(n));if(!ms.length)none();const buf=Buffer.alloc(4096);for(const n of ms){const p=pa.join(d,n);let st;try{st=f.lstatSync(p)}catch(e){console.log("  "+n+"  <unreadable: "+e.code+">");continue}if(!st.isFile()){console.log("  "+n+"  <INVALID: not a regular file>");continue}let r;try{const fd=f.openSync(p,"r");try{r=buf.slice(0,f.readSync(fd,buf,0,4096,0)).toString("utf8").replace(/\n$/,"")}finally{f.closeSync(fd)}}catch(e){console.log("  "+n+"  <unreadable: "+e.code+">");continue}console.log("  "+n+"  "+JSON.stringify(r)+(f.existsSync(r)?"":"   <-- ORPHAN"))}' "<PLUGIN_ROOT>"

# STATUS (read-only) — for ONE repo. It reports that repo's consent state; it does not
# list enrolments, so it cannot find an orphan. Use LIST above for that.
cd / && node -e 'const g=require(process.argv[1]+"/scripts/lib/gateguard-consent.js");console.log(JSON.stringify(g.isEnabled(process.argv[2])))' "<PLUGIN_ROOT>" "/path/to/repo"
```

**Revoking.** LIST prints the enabled directory on its **first line**, then **exactly one line
per enrolment**: the 64-character marker name followed by the recorded repository path, shown
JSON-quoted. The quoting is not decoration — the resolver deliberately supports paths containing
newlines (that is why it uses `--porcelain -z`), so printing one raw would split a single
enrolment across several lines and could emit terminal control characters. Quoted, one enrolment
is always one line. The file to
delete is that directory joined with the marker name on the row whose recorded repository is the
one you want to disable — LIST does not print the joined path itself.

Before deleting, confirm that **the directory LIST printed on its first line** and its parent
are real directories rather than symlinks — `rm` does not follow a symlink at the final
component but *does* traverse a symlinked ancestor, so a redirected ancestor turns the deletion
into "unlink some unrelated file". **Check the path LIST printed, not `~/.gateguard`:** `~`
expands from `$HOME`, which this design establishes may name a different tree from the
passwd-derived one the gate actually consults — validating the `~` tree while deleting from the
passwd tree checks the wrong ancestors entirely. (LIST resolves that directory through the
module and refuses outright if either component is a symlink, so if it printed a path, that
much is already established.) #712's `--off` does all of this in one step.

**What that costs, stated without overclaiming.** This file is loaded into the model's context
when the skill is invoked, so any revocation instruction here — a paste-ready command *or* this
prose — is reachable by the party the gate constrains. Writing it as prose lowers the salience;
it does **not** restore 5(g)'s property, and an earlier draft of this note claimed it did. That
claim was wrong in the same way the note itself warns about.

The property 5(g) actually protects is narrower and it is intact: **the block message** — the
text that fires while the model is being denied — carries no revocation recipe, no marker path
and no `GATEGUARD_*` name, and a verification row greps for exactly that. That surface is where
a nudge would land at the moment it matters.

Everything beyond that is accepted, not defended: the threat model states plainly that a
process with shell access as the operator can remove the marker, and treats that as strictly
larger than anything this documentation grants. Nothing here is access control, and this file
does not pretend otherwise.

- **`cd /` is load-bearing.** It is the node *startup* directory and has nothing to do
  with where the marker goes. Starting node inside the target repo lets a repo-dropped
  `.tool-versions`/`.nvmrc`/`package.json`/mise file steer a version-manager shim and
  choose which node runs — the same vector `sanitized-node.sh:72-81` closes. Do **not**
  substitute `cd ~`: the tilde expands from `$HOME`, the exact channel this design removes.
- **Requires git ≥ 2.36** for `worktree list --porcelain -z`. Older git produces a
  resolution failure and the gate stays off.
- **POSIX-only.** The registrations start with `/usr/bin/env -i … bash …`, which does not
  run on native Windows; a marker created there would be stored and inert.
- The marker is keyed to the **main worktree**, so every linked worktree of the same
  repository shares one enrolment. Its contents are the recorded realpath, for human audit:
  the gate's consent path never reads them (existence and type only); the LIST command above
  is the one reader. Only *existence*, as a non-symlink regular file under
  non-symlink directories, is consulted.
- Revocation is **repo-global and durable**: it takes effect on the next tool call, in
  every concurrent session and worktree. There is no session-local pause. Relocating an
  enrolled repository silently revokes consent and strands the marker; LIST flags it as an
  ORPHAN, and automated pruning arrives with #712.

#### Fail direction

Marker absent, passwd home underivable, repo unresolvable, git missing, consent check
erroring ⇒ **gate OFF** (allow, exit 0, no decision on stdout). That is literal
fail-*open*, and it is correct **only** because of what GateGuard is: it guards no
boundary, it improves output quality, and its default is already off. The property being
protected is the inverse of a security gate's — not "a repo must not switch this ON" but
"a repo must not switch the operator's chosen gate OFF".

**This does not generalize.** `--fail-open` is licensed for GateGuard *because* GateGuard
is not a boundary. Do not cite it for `block-no-verify`, `config-protection`,
`pre-bash-dev-server-block`, or `mcp-health-check` — those keep the closed disposition.

What it denies, precisely (it is narrower than the three-stage summary above suggests):

- `Edit`/`Write` — the **first touch of each file** only. Paths under Claude's
  own settings are exempt (`isClaudeSettingsPath`).
- `MultiEdit` — the **first touch of the batch's target file**, same as
  `Edit`/`Write`. The branch reads `tool_input.file_path` and `tool_input.filePath`
  (where a real MultiEdit payload carries it) and falls back to any per-edit
  `file_path` or `filePath` for harness variants that nest it there. Before #615
  it read the per-edit field *only*, so the loop body never executed and every
  MultiEdit fell through to allow — `__tests__/gateguard-multiedit.test.ts` locks
  the fix in.
- `Bash` — destructive commands (`rm -rf`, `git reset --hard`, force-push, `drop
  table`, …) are gated **once per distinct command string**, not every time: the
  hook keys state on a SHA-256 of the exact command
  (`gateguard-fact-force.js:876-879`), so re-running a byte-identical destructive
  command later in the session is allowed straight through. Any command that
  differs by even one character is a new key and gates again. (This contradicts
  the "every destructive command" heading inherited from upstream above — the
  code is the authority.) The first *routine* command of a session is also gated
  once, with a shorter two-fact prompt.

**Env-contained since #616 — the paragraph that used to sit here argued the opposite,
and it was right at the time.** For the record, because a future reader will otherwise
re-derive it: the pre-#616 position was that GateGuard should NOT be routed through
`sanitized-node.sh`, on two grounds. (1) GateGuard guards no boundary, so a repo that
disables it only degrades its own results — unlike `block-no-verify` or
`config-protection`, where disabling grants a real bypass. (2) Containment would have made
the gate unable to fire at all: `env -i` wipes `ECC_HOOK_PROFILE`, `getHookProfile()` falls
back to `standard` (`scripts/lib/hook-flags.js:19`), and `standard` was not in the entries'
declared `strict` list — so `isHookEnabled()` would return false on **every** invocation.

Reason (2) was a real mechanism, and #616 removes it rather than overriding it: the
registrations now declare **`"minimal,standard,strict"`**, so no value of the profile
variable — including the `standard` that `env -i` induces — can disable the hook. With that
gone, reason (1) no longer buys anything: it justified accepting a repo-injectable
off-switch, and the switch is what #616 exists to close. Consent moved out of the
environment entirely instead.

The warning attached to the old position still stands, and is worth keeping precisely
because this change had to satisfy it: **do not route a `strict`-only hook through the
wrapper without widening its profile list first — you would ship a guard that can never
fire, which is worse than no guard because it reads as coverage.**

**Why the profile CSV names every profile.** The registrations pass
`"minimal,standard,strict"` to the runner. `hook-flags.js:12` defines
`VALID_PROFILES = {minimal, standard, strict}` and `getHookProfile()` maps any
unrecognised value back to `standard`, so listing all three makes `ECC_HOOK_PROFILE`
**non-disabling for every possible value** — which is the point: it was the worst of the
six off-switches, evaluated in the uncontained outer shell before `env -i` could apply.

The old shape was a shell `case` guard that skipped the OFF profiles plus a `"strict"`-only
argument. Both are deleted. That guard ran *uncontained*, so a committed `settings.json`
`env` block setting `standard` switched the gate off without naming any `GATEGUARD_*`
variable — issue #616. Do not reintroduce a shell-side profile test: the shell cannot
reproduce `hook-flags.js:19`'s `String(...).trim().toLowerCase()`, and successive review
rounds found a fresh divergence each time one was patched (`STRICT` fails a case-sensitive
compare, `" strict "` an untrimmed one, NBSP-padded `strict` survives JS `.trim()` but not
shell `IFS` splitting).

**There is no environment off-switch, by design.** Two GateGuard-specific disable
variables, a GateGuard state-directory override, `ECC_DISABLED_HOOKS`, `ECC_HOOK_PROFILE`
and `ECC_DRY_RUN` were the six channels #616 closed — the first three are deliberately not
spelled out here, because V16 greps this file for them and a doc that names a retired
switch is how a retired switch gets tried. `env -i` also closes `PATH` and `NODE_OPTIONS`,
which act
before JavaScript runs and no `process.env` grep can see. If GateGuard is blocking setup or
repair work, revoke the marker for that repository (above) — that is the only switch, and
it is deliberately out-of-band rather than something a session can set.

**What the gate actually enforces — read this before trusting the three-stage
model above.** It denies the FIRST touch of each file (and each destructive
command), then allows the retry. `markChecked()` runs *before* the denial is
returned, so the state file records "this target was gated once", **not** "the
facts were presented". The hook has no way to verify that you actually answered —
a retry that presents nothing is allowed just the same. Its value is forcing the
investigation *pause* on first touch, not proving the investigation happened.

One further behaviour, in the runner rather than the registration — know it
before you read a block message:

- **A payload over 1 MiB is ALLOWED UNCHECKED, not blocked** (#612 residual, reopened for
  GateGuard by #616). `run-with-flags.js` caps stdin at `MAX_STDIN = 1024 * 1024`; past
  that the JSON arrives truncated and GateGuard hits its parse-error path, which returns
  the input unchanged. `enforceTruncation()` used to override that to exit 2, but only for
  `--fail-closed` dispatches — and GateGuard is now `--fail-open`, so the override no
  longer applies to it. **The five wrapped gates keep `--fail-closed` and are unaffected.**

  This was a deliberate scope call, not an oversight. Keeping `--fail-closed` would
  hard-block every `Edit`/`Write`/`Bash` of operators who **never enrolled** the moment one
  oversized payload appeared, and denying inside the hook provably cannot work — the deny
  precedes the parse, so `markChecked()` never runs and the retry loops forever. What is
  lost is bounded: an oversized `Write` skips a *quality* prompt on a gate that is
  explicitly not a boundary, for an operator who opted in. Split the write if you want it
  gated.


### Option B: Full package with config

```bash
pip install gateguard-ai
gateguard init
```

This adds `.gateguard.yml` for per-project configuration (custom messages, ignore paths, gate toggles).

## Anti-Patterns

- **Don't use self-evaluation instead.** "Are you sure?" always gets "yes." This is experimentally verified.
- **Don't skip the data schema check.** Both A/B test agents assumed ISO-8601 dates when real data used `%Y/%m/%d %H:%M`. Checking data structure (with redacted values) prevents this entire class of bugs.
- **Don't gate every single Bash command.** Routine bash gates once per session. Destructive bash gates every time. This balance avoids slowdown while catching real risks.

## Best Practices

- Let the gate fire naturally. Don't try to pre-answer the gate questions — the investigation itself is what improves quality.
- Customize gate messages for your domain. If your project has specific conventions, add them to the gate prompts.
- Use `.gateguard.yml` to ignore paths like `.venv/`, `node_modules/`, `.git/`.

## Related Skills

- `safety-guard` — Runtime safety checks (complementary, not overlapping)
- `code-reviewer` — Post-edit review (GateGuard is pre-edit investigation)
