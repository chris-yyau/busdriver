# Issue #885: brainstorming ultra-oracle wrapper root resolution

**Revision 4.**
- **Revision 2** answered run `595d5b8a` (1 HIGH, 1 MEDIUM, 4 LOW). It moved the design text into a prompt file, shortened the resolver, and added gate-budget tests. All three were approved by the operator as in-scope.
- **Revision 3** answered run `35f4c110` (0 HIGH, 5 MEDIUM, 8 LOW). It added:
  - the cleanup residual and how to recover it;
  - the Bash-tool timeout and backgrounding contract;
  - one cwd-independent prompt path;
  - clarified `surface=error` and Retry handling.
- **This revision** answers run `72881cbe` (0 HIGH, 1 MEDIUM, 6 LOW). It adds:
  - the exact writing-plans substitutions;
  - a `$HOME` anchor outside a repo;
  - the corrected classifier reason and a test that pins it;
  - the prompt file mode;
  - an `out=` line;
  - scoped wording and citations.

## Problem

An explicit "consult the oracle" at brainstorming Step 5.6 fails immediately:

```
bash: …/.claude/plugins/cache/busdriver/busdriver/current/scripts/ultra-oracle-consult-run.sh: No such file or directory
```

The block still exits 0, so the failure only shows up as `oracle_status=error`.

Fixing that path is not enough on its own. Each Step 5.6 block also inlines the full design as a heredoc inside a single Bash command.

Every Bash command goes through `hooks/gate-scripts/lib/marker_check.py`:
- `pre-implementation-gate.sh:263` invokes it.
- Its walk budget is 4000 tokens (`_HELPER_MAX_TOKENS`, `marker_check.py:1895`).
- A command over budget is refused `BLOCK_UNSCANNABLE` (`pre-implementation-gate.sh:418`).

The arbiter measured this twice. A realistic design (revisions 1 and 2 of this doc) pasted into the **current** Path A block scores `BLOCK_MARKER_SCRIPT|lease_slot.py`. The trigger is contextual: the heredoc payload is re-read cumulatively. No single prose token causes it; for example `tests/test-*.sh` alone scores `OK|`. A larger design is refused `BLOCK_UNSCANNABLE` instead.

Council hit the same class of failure and fixed it by moving prompts into files (#813, `skills/council/SKILL.md` (i)). With only the root fix, an explicit consult would just move from "No such file" to a gate refusal.

## Root cause

Both blocks set `WRAP="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/busdriver/busdriver/current}}/scripts/…"`. On a normal install that always fails, for three reasons:

1. **`CLAUDE_PLUGIN_ROOT` is not exported to Bash-tool commands.** Claude Code instead substitutes the literal path inline in skill Markdown, and only for the exact `${CLAUDE_PLUGIN_ROOT}` token (plugins reference, "Where each variable resolves"). The nested `${CLAUDE_PLUGIN_ROOT:-…}` spelling is not that token, so the fallback ran.
2. **`BUSDRIVER_PLUGIN_ROOT` is normally unset.**
3. **The cache is versioned, and nothing creates `current`.** On um the cache holds `2.1.22 2.2.10 2.2.2 2.2.3 2.2.7`. `installed_plugins.json` has busdriver `installPath` = `…/2.2.10` and `gitCommitSha` = `f67be922…`.

A missing wrapper produces empty stdout, and `[ -n "$oracle_status" ] || oracle_status="error"` turns that into a quiet `error` with exit 0.

## Approach

### 1. File-based prompt transport (the design text never enters a Bash command)

This follows the council Step 4b pattern. The design is written with the **Write tool**. The Bash fences only resolve the wrapper and invoke it, so their scan cost is **constant** and does not depend on the design's length or wording.

Flow (the same for both paths):

1. **Prepare fence** (one Bash call; identical text for Path A and Path B):
   - Computes the prompt path and removes any stale prompt left by an abandoned earlier run.
   - Resolves the wrapper. A failure here is loud, and no design text has been written yet.
   - Creates the state dir.
   - Prints `pf=<absolute prompt path>` and `surface=<enabled|disabled|error>` (from `--surface-check brainstorming`).
2. **Decide:**
   - `surface=error`, or any value that is not one of the three tokens → `oracle_status=error` on **both** paths. Stop without writing; apply the Fail-CLOSED handling.
   - Path A (explicit trigger) continues on `enabled` or `disabled`.
   - Path B continues only on `enabled`. On `disabled` → `oracle_status=skipped:disabled`, proceed to Step 6, nothing written.
3. **Write** the critique instruction and the full approved design to the printed `pf=` path, verbatim, with the Write tool. The path is a Write argument only. It is never retyped into shell source.
4. **Consult fence** (Path A's, or Path B's, which adds `--surface brainstorming` as today's consult-time TOCTOU re-gate):
   - Installs the cleanup trap **first**.
   - Re-computes the same absolute path and re-resolves the wrapper.
   - Requires a non-empty prompt file.
   - Runs the wrapper and prints `oracle_status=<token>` and `out=<absolute verdict path>`. The old blocks never printed the status, so the model could not see the value to branch on. On `ok`, Read the `out=` file.

**Prompt path.** `PF` is `<state dir>/ultra-oracle/critique-prompt.txt`, where `<state dir>` is:
- `$BUSDRIVER_STATE_DIR` used verbatim when it is absolute. Only this half has precedent: `skills/ultraoracle/SKILL.md:69-71` uses the value verbatim.
- Otherwise, that value or `.claude`, joined onto `git rev-parse --show-toplevel`, or onto `$HOME` outside a git repo. The join is new behaviour in brainstorming.

Every fence computes it the same way, so the printed `pf=`, the Write target, the `[ -s ]` check and the trap all name the **same absolute file**, from any cwd. That holds outside a repo too, because the fallback anchor is `$HOME`, not the cwd.

Anchoring at the repo root also matches the gate's own rule. `pre-implementation-gate.sh:1013-1016` exempts Write/Edit under `$STATE_DIR/` *relative to the repo root*, so the Write is not blocked even when another doc has a pending review. An absolute out-of-repo `BUSDRIVER_STATE_DIR` gives up that exemption. That is the operator's choice, and the Write is then gated like any other.

**Basename.** `critique-prompt.txt` stays clear of `check-design-document.sh:112`. That hook arms a repo-wide design-review token for any basename matching `^(PLAN|DESIGN|ARCHITECTURE)…\.md$` (case-insensitive). The old name `design-critique-prompt.md`, if written with the Write tool, would match.

`OUT` keeps its name, `design-critique.md`. The adapter subprocess writes it (not the Write tool and not a shell redirect), so neither hook sees it. `.claude/ultra-oracle/` is already gitignored.

### 2. Shared lines (byte-identical in every fence)

Path lines (3), in all three fences:

```bash
S="${BUSDRIVER_STATE_DIR:-.claude}"
[ "${S#/}" != "$S" ] || S="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/$S"
PF="$S/ultra-oracle/critique-prompt.txt"
```

Resolver lines (6), in all three fences:

```bash
: "${CLAUDE_PLUGIN_ROOT=}"
R="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"
C="$HOME/.claude/plugins/cache/busdriver/busdriver"
[ -n "$R" ] || R="$C/$(ls "$C/" 2>/dev/null | awk -F. '/^[0-9]+[.][0-9]+[.][0-9]+$/ { if (!n || $1>a || ($1==a && ($2>b || ($2==b && $3>c)))) { a=$1; b=$2; c=$3; n=1; v=$0 } } END { if (n) print v }')" || :
WRAP="${R%/}/scripts/ultra-oracle-consult-run.sh"
[ -f "$WRAP" ] || { echo "brainstorming: ultra-oracle wrapper not found: $WRAP — set BUSDRIVER_PLUGIN_ROOT" >&2; exit 1; }
```

| Rung | Source | Notes |
|------|--------|-------|
| 1 | `BUSDRIVER_PLUGIN_ROOT` | Operator override, with the same precedence as council and litmus. If the override names a root **without** the wrapper, the fence fails loudly. It does not fall back to the cache, because an explicit override states intent. |
| 2 | bare `${CLAUDE_PLUGIN_ROOT}` | Claude Code inlines this to the running plugin's exact install path. A harness that does not substitute reads the env var, if it is set. |
| 3 | newest pure `X.Y.Z` entry under the cache | Council Step 4b (b)'s 2-stage `ls \| awk` pick, already verified there under bash and zsh. Prereleases and `current` are ignored, and versions compare numerically. `ls "$C/"` lists through a symlinked cache dir, and `[ -f ]` follows a symlinked version dir. This fixes revision 1's `find -type d` defect. |
| fail | wrapper file absent | **One** diagnostic for every failure. An empty pick leaves `R="$C/"`, so `WRAP` can never collapse to `/scripts/…`, and the message names the exact path that was tried. |

Shell-option notes (no in-fence comments needed):
- `: "${CLAUDE_PLUGIN_ROOT=}"` keeps the bare reference from tripping `set -u`. It is not the bare token, so Claude never inlines it.
- The trailing `|| :` on the `ls | awk` line, and the `|| echo "$HOME"` inside the path substitution, keep `errexit`+`pipefail` from silently aborting. Control reaches the loud diagnostics instead.
- Every construct behaves the same in bash and zsh (#296). There is no variable named `status`, no capture groups, no `case` globs, and no function definitions (#813 (g)).

Accepted limits. These are documented in the SKILL prose, not the fences, to keep the scan budget:
- **Rung 3 is a heuristic.** It can disagree with the version a consumer actually loaded, for example after a downgrade leaves a newer dir behind, or with scoped installs. Council has the same limit. The fix is `BUSDRIVER_PLUGIN_ROOT`, which the diagnostic names.
- **A regular file named like `9.9.9` in the cache** would win the pick and then fail loudly. It never silently runs the wrong wrapper.

### 3. The fences

The prepare fence is shared by both paths. It also serves as the **cleanup command**: it removes the prompt before doing anything else, so it works even when resolution fails.

```bash
<path lines, 3>
rm -f "$PF"
<resolver lines, 6>
mkdir -p "${PF%/*}" || exit 1
printf 'pf=%s\nsurface=%s\n' "$PF" "$(bash "$WRAP" --surface-check brainstorming)"
```

The Path A consult fence:

```bash
<path lines, 3>
OUT="$S/ultra-oracle/design-critique.md"
trap 'rm -f "$PF"' EXIT INT TERM
<resolver lines, 6>
[ -s "$PF" ] || { echo "brainstorming: prompt file missing or empty: $PF — run prepare and Write it first" >&2; exit 1; }
oracle_status=$(bash "$WRAP" --mode blocking --slug "ultra oracle design critique" --prompt-file "$PF" --out "$OUT")
[ -n "$oracle_status" ] || oracle_status="error"
printf 'oracle_status=%s\nout=%s\n' "$oracle_status" "$OUT"
```

The Path B consult fence is identical except for its call: `bash "$WRAP" --surface brainstorming --mode blocking …`.

**Ordering.**
- In the consult fences, the trap comes **before** the resolver and the `[ -s ]` check. Every exit, including a resolver failure, deletes the written design.
- In the prepare fence, `rm` comes before the resolver, and nothing else is written before resolution succeeds.

Tests pin both orderings statically. They prove "never invoked" with a stub invocation log, not by checking that `PF` is absent.

**Why re-compute and re-resolve in each fence?** Carrying a printed path back into shell source creates an execution point (council Step 4b, "Only the suffix crosses over"). Re-computing is deterministic, and the 9 shared lines are budget-tested in every fence. A static test asserts that the three copies are byte-identical.

### 4. Lifecycle, timeout, and retry contract (SKILL prose)

**Cleanup residual (stated, like council (j)).** The consult fence's trap covers the consult itself. It cannot cover the gap between the Write and the consult call. In that gap the design sits on disk in the gitignored state dir. The file has the Write tool's default mode (umask, typically 0644). That is the same mode today's heredoc file gets, but the window now spans tool turns. Council's stranded prompt instead sits in a 0700 `mktemp` dir. Three cases leave the design on disk:
- the consult call is refused by a gate. Example: a design review pending elsewhere. Every fence classifies as file-modifying under `cmdword.is_file_mod`: all three because of the resolver's `ls | awk` stage, and prepare also because of its bare `rm`. The Write, by contrast, is exempt;
- the session is cancelled;
- Path B is mis-followed (writing on `disabled`).

Rule: **if a prompt was written and no `oracle_status=` line came back, run the prepare fence again and stop.** It removes the prompt first. If that call is refused too, tell the user the exact `pf=` path so they can delete it.

As a backstop, the next prepare run removes any stale prompt. Closing the gap fully would need a single writer that owns the whole lifecycle, which reintroduces the in-command design text this fix removes.

**Bash-tool timeout (caller contract, mirrors council Step 4.5 / #477).** The consult blocks for the whole ChatGPT Pro consult. Invoke the consult call with an explicit `timeout` of at least `ultra_oracle_timeout_cap + 90s + LAUNCH_WAIT_SECONDS`:
- at the default cap: ≥ 1005 s, i.e. `timeout: 1100000` ms;
- at the 3600 s ceiling: `timeout: 3710000` ms.

If the harness caps the tool timeout lower and **backgrounds** the call, wait on that task until it finishes (with the harness's own output-wait). Branch **only** on a tool result that contains an `oracle_status=` line. A backgrounded consult is still running, not failed. **Never Retry while an earlier consult task is still running**: Retry's prepare step deletes the prompt that the earlier consult may still be reading. If the harness kills the call instead of backgrounding it, treat that as `error` and run the cleanup rule above.

**Fail CLOSED.** Add: *"a fence exiting non-zero with a `brainstorming:` diagnostic on stderr, before any `oracle_status=` line, counts as `error`."* This covers both the wrapper-not-found and the prompt-missing diagnostics. Surface the message verbatim with the existing Retry / skip-once / abort prompt.

**Retry means prepare → Write → consult again.** The trap deletes the prompt after every attempt, so re-running only the consult fence hits "prompt file missing".

**Other prose edits:**
- Replace the "write the design via a single-quoted heredoc" instruction with the flow above, plus its reasons (scan budget, contextual re-read of the payload). Add: **do not inline the design back into a fence.**
- **Remove** the two `# empty stdout (e.g. missing wrapper) → fail closed` comments. A missing wrapper is now caught earlier by `[ -f "$WRAP" ]`. The `[ -n "$oracle_status" ] || …` guard line itself stays.
- Keep the Data boundary, latency, zsh/`oracle_status` and wrapper paragraphs.

### 5. writing-plans (the "Paths" bullet, a consequence of the transport change)

`skills/writing-plans/SKILL.md:34` suggests prompt/out names `plan-advisory-$$.*`. The Write tool cannot expand `$$`. Also, a `.md` prompt whose name starts with `plan` would arm a design-review token if it were written with the Write tool.

writing-plans reuses the brainstorming fences by copying them. Replace the "Paths" bullet with an exact substitution list:
- Choose a 6-character random alphanumeric `<tag>` once per run. It is inert as shell source and keeps runs session-unique.
- In the copied **prepare** fence and the copied **consult** fence, change `critique-prompt.txt` on the `PF=` line to `plan-advisory-<tag>-prompt.txt`.
- In the copied **consult** fence, change the `OUT=` basename `design-critique.md` to `plan-advisory-<tag>.md`. Only the consult fence has an `OUT=` line.
- In both copies, change the surface name `brainstorming` (in `--surface-check` and `--surface`) to `writingPlans`. This is the key that `ultra_oracle_surface_enabled` reads as `.ultraOracle.writingPlans.enabled`. Also change the `--slug` text to a plan-advisory slug.
- The Write target is the `pf=` line printed by the copied prepare fence. It already carries the tag.
- The byte-identity requirement applies only to brainstorming's own three fences. These copies differ from them by exactly the substitutions above.

Everything else (status branching, non-blocking result) stays as writing-plans already defines it.

## Non-goals

- No change to `scripts/ultra-oracle-consult-run.sh`, `scripts/lib/ultra-oracle*.sh`, the status tokens, or the Path A/B opt-in semantics.
- No change to `skills/council/SKILL.md` or `skills/ultraoracle/SKILL.md`.
- No change to `hooks/gate-scripts/**` or `scripts/hooks/**`, so no `.gate-integrity.lock` regen.
- A design review pending elsewhere in the repo still blocks the fences, because they classify as file-modifying (§4). That is pre-existing ADR 0017 behavior. The residual and its recovery are stated in §4.
- An absolute `BUSDRIVER_STATE_DIR` is fixed **for the prompt and verdict paths only**. Two other readers still assume a relative state dir, and both are pre-existing behaviour in the out-of-scope wrapper libraries:
  - the wrapper's USER-config reader (`scripts/lib/resolve-cli.sh:1135-1136`);
  - the opt-out marker lookup (`scripts/lib/ultra-oracle.sh:881-884`).

  A follow-up ticket is not opened here, because the batch has not authorized one. It is offered to the supervisor instead.
- Brainstorming keeps one fixed prompt name, the same concurrency ceiling as today.

## Tests

New `tests/test-brainstorming-oracle-wrapper-root.sh`, picked up by the `tests/test-*.sh` glob in `scripts/ci/run-shell-tests.sh`.

**Extraction.** It extracts the **actual** fences from `skills/brainstorming/SKILL.md` by needle:
- prepare: contains `--surface-check`
- consult A: contains `--prompt-file` and not `--surface brainstorming`
- consult B: contains `--surface brainstorming --mode`

**Setup.**
- Each fence runs inside a temp git repo. A subdirectory is used as cwd in some cases.
- `HOME` points at a fake home.
- `CLAUDE_PLUGIN_ROOT`, `BUSDRIVER_PLUGIN_ROOT` and `BUSDRIVER_STATE_DIR` are unset unless a case sets them.
- Stub wrappers print `enabled` for `--surface-check` and `ok-<label>` otherwise. They append `<label> <args>` to an **invocation log outside the state dir**.
- The real oracle is never called.

| # | Case | Expected |
|---|------|----------|
| 1 | cache dirs `2.2.3`, `2.2.10`, `2.3.0-rc1`, `current` (all with stubs) | all three fences pick `2.2.10`; consult A prints `oracle_status=ok-2.2.10` |
| 2 | bare token textually replaced with an alt root `claude-root` (simulates Claude inlining) | `claude-root` wins over the newer cache |
| 3 | `BUSDRIVER_PLUGIN_ROOT=override-root` + inlined `claude-root` + cache | `override-root` wins |
| 4 | `CLAUDE_PLUGIN_ROOT` **exported**, token not replaced + cache | env root wins |
| 5 | `BUSDRIVER_PLUGIN_ROOT` → root without the wrapper, valid cache | rc ≠ 0; stderr `wrapper not found: <override path>`; log empty (no fallback) |
| 6 | newest cache dir has no `scripts/` | rc ≠ 0; full missing path in stderr; log empty |
| 7 | no cache dir; and separately, only `2.3.0-rc1` + `current` | rc ≠ 0; `wrapper not found`; log empty |
| 8 | symlinked cache dir and a symlinked version dir | resolves through both |
| 9 | consult A **and** B with a pre-written `PF`, case 6 setup | `PF` gone afterwards **and** log empty (trap ran, wrapper never invoked) |
| 10 | consult A **and** B with no `PF`, and with a **zero-byte** `PF` | rc ≠ 0; `prompt file missing or empty`; log empty |
| 11 | prepare, then consult B: success | prepare prints `pf=<repo>/.claude/ultra-oracle/critique-prompt.txt` and `surface=enabled`; log shows `--surface brainstorming`; `PF` gone afterwards |
| 12 | **path agreement**, three variants: (a) prepare from the repo root, consult from a subdirectory; (b) an **absolute** `BUSDRIVER_STATE_DIR`; (c) **outside any git repo**, prepare and consult from two different non-repo cwds | the printed `pf=` is exactly the file the consult reads (it succeeds with the prompt written only at the printed path); in (c) `pf=` is under `$HOME/.claude/ultra-oracle/`; no `//` in the path; consult prints an `out=` sibling of `pf=` |
| 13 | **cleanup**: an abandoned `PF` plus case 6 setup, then the prepare fence | rc ≠ 0 (resolution fails), `PF` removed, log empty |
| 14 | **blocking**: stub sleeps 2 s and records whether `PF` exists while it runs | consult prints `oracle_status=` only after the stub returns; `PF` existed during the call and is gone after |
| 15 | cases 1, 4, 7 with `set -euo pipefail` prepended | same results; failures still carry the diagnostic |
| 16 | cases 1, 6, 7 under **zsh** when installed | same results; missing zsh under `GITHUB_ACTIONS=true` is a FAIL (#821 convention) |
| 17 | **gate budget**: each fence as pasted, through `python3 -I hooks/gate-scripts/lib/marker_check.py` (payload shape as in `tests/test-marker-glob-specificity.sh`) | `OK\|`; still `OK\|` with **20 comment lines of padding** prepended (#813 headroom convention). The measured margin is recorded in a comment; if it is under 20, shrink the fence, never the assertion |
| 18 | static, brainstorming | no `busdriver/current`; no `${CLAUDE_PLUGIN_ROOT:-`; bare `${CLAUDE_PLUGIN_ROOT}` exactly 3 times; path and resolver lines byte-identical across the 3 fences; no `<<` heredoc in any Step 5.6 fence; trap precedes the resolver in both consult fences; `rm -f "$PF"` precedes the resolver and `[ -f "$WRAP" ]` precedes `mkdir` in prepare; prompt basename does not match `^(plan\|design\|architecture).*\.md$` (i); no `# empty stdout (e.g. missing wrapper)` comment remains |
| 18b | **classifier pin**: import `hooks/gate-scripts/lib/cmdword.py` as the gate does, and run `is_file_mod` on each extracted fence | `True` for all three. This pins the §4 residual analysis, so a classifier change shows up here rather than silently invalidating it |
| 19 | static, writing-plans | no `plan-advisory-$$`; the Paths bullet names `plan-advisory-<tag>-prompt.txt` (`.txt`), `plan-advisory-<tag>.md`, both the prepare and consult fences, and `writingPlans` as the surface name |

**Regression proof**, recorded in the PR:
- Case 1 run against `origin/main`'s SKILL.md resolves to the nonexistent `…/current` wrapper.
- `origin/main`'s Path A block with this doc pasted in scores `BLOCK_MARKER_SCRIPT` from `marker_check.py`, quoted verbatim. The new fences carry no design text.

## Files

- `skills/brainstorming/SKILL.md`: Step 5.6 fences and prose
- `skills/writing-plans/SKILL.md`: the "Paths" bullet becomes the §5 substitution list
- `tests/test-brainstorming-oracle-wrapper-root.sh`: new

## Verification

- `bash tests/test-brainstorming-oracle-wrapper-root.sh`, plus the regression proof
- `bash tests/test-ultra-oracle.sh` and `bash tests/test-marker-glob-specificity.sh` (contracts unchanged)
- `shellcheck tests/test-brainstorming-oracle-wrapper-root.sh`
- `node scripts/ci/validate-skills.js` and `node scripts/ci/validate-no-personal-paths.js`
- **Real install on um, through the live PreToolUse gate, with nothing transmitted:**
  1. Run the prepare fence verbatim through the agent's Bash tool, with the real `HOME`. Expect: not blocked; `pf=<repo>/.claude/ultra-oracle/critique-prompt.txt`; `surface=enabled` (um's USER config enables the surface); the wrapper resolves to `…/busdriver/busdriver/2.2.10/…`, matching `installed_plugins.json` `installPath`.
  2. Write a one-line, non-sensitive prompt to the printed path with the Write tool. Run the Path B consult fence verbatim through the Bash tool with `BUSDRIVER_PLUGIN_ROOT` (tool env only) pointing at a temp root that holds a stub wrapper. Expect: not blocked; `oracle_status=<stub token>`; the prompt file is gone.
  - Together these show the real gate accepts the fences and the Write without sending anything to ChatGPT. A real consult is not run: it would transmit, and um currently lacks `CHROME_PATH`.
- Litmus at each commit through the normal pre-commit gate; deep litmus at `gh pr create`

## Key decisions

| Decision | Chosen | Rejected and why | Revisit if |
|----------|--------|------------------|------------|
| Prompt transport | Write tool → file (council #813 pattern), with a stated Write→consult residual and a cleanup rule | heredoc in the fence: scan cost grows with the design, and the payload is re-read into a refusal | the classifier stops charging heredoc payloads |
| Prompt path | one absolute path computed identically in every fence (repo root, `$HOME` outside a repo, or an absolute override) | `$PWD`-relative (drifts with cwd, and breaks on an absolute override); carrying the printed path into shell (execution point) | — |
| Resolver sharing | identical lines in each fence, plus an identity test | carrying `WRAP` across calls (execution point); a shared script (it would have to be located first) | a harness exports the plugin root to Bash |
| Version pick | council's `ls \| awk` | revision 1's 5-stage `find` pipeline (budget cost; misses a symlinked cache) | — |
| Diagnostics | one `wrapper not found: <path>` | two messages | — |
| Path B gating | model branches on `surface=` from prepare; the consult re-gates with `--surface`; mis-following is covered by the cleanup rule | writing first and gating later | — |
| Cleanup command | reuse prepare (it removes the prompt first) | a fourth fence (more budget-tested text for the same `rm`) | — |
| Long consult | council's #477 timeout formula; wait on a backgrounded task; never Retry while one is still running | relying on the tool default (~120 s), which kills or backgrounds mid-consult | — |

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
