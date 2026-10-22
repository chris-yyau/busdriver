# Issue #975: per-run prompt and verdict isolation for brainstorming's oracle consult

**Status: APPROVED (amended).** The §5 amendment (§5a) passed blueprint review with FULL 3/3 coverage (iteration 5, run `357a7b4f`; 0 high, 0 medium, 7 low). Two earlier arbiter verdicts on that run were not recorded because the arbiters used tools outside the approved Read/Grep/Glob boundary; the recorded verdict is from a third, restricted arbitration. Its confirmed lows are addressed in §4, §5, §5a and row 32. The revision before the amendment passed with FULL 3/3 coverage in run `9fe12b9b`. Earlier iteration-5 runs `a00e4f76` and `c25b8843` lacked Grok coverage and are not the approving run; iteration 4 FAILed with 0 high. This revision implements the scope Chris accepted on 2026-10-19 (quoted in "Accepted scope"). It does **not** carry forward approval of any earlier revision. Earlier revisions were never approved; their review findings and their disposition are listed at the end.

Issue: https://github.com/chris-yyau/busdriver/issues/975 (greptile on PR #911; the same race re-raised by Codex and CodeRabbit on PR #911 HEAD `d55775ef`). Builds on the #885 file transport (`docs/plans/2026-09-30-issue-885-oracle-wrapper-root.md`); that design is not reopened.

## Accepted scope

The issue's own worker note names the trade-off this design has to settle: "A per-run name would close the concurrent-session race but drop that backstop … Choosing between the two needs a design decision beyond #885's scope."

Proposal put to Chris (Slack `C0C64DU9DA9`, thread `1792171618.243849`, message `1792377111.046509`):

> #975 已分清原始需求與設計額外加上的要求。每個 run 獨立 prompt／結果、正常交錯執行與 retry 隔離，可以先做；目前卡住的是崩潰後自動清理殘檔
>
> 我建議先交付隔離修復，正常結束仍清理自己的 run；崩潰殘檔改為明確提示，由操作員處理，暫不新增會掃描其他 run 的清理器
>
> 這會改變清理行為，風險是未處理的 prompt／critique 明文可能一直留在磁碟。你接受這個範圍嗎？若不接受，就保留自動清理要求繼續設計

Chris Yau (`U0BQSFED2JE`, message `1792377131.714249`): 接受 ("accept").

What this design therefore delivers:
- **Isolation.** Each run gets its own prompt and verdict files. Normal interleaving and retry of runs, including concurrent runs within one agent, cannot delete, transmit or mix another run's files.
- **Own-run cleanup.** A run that ends normally removes its own files.
- **Crash residue is surfaced, not collected.** Files left by a crashed or abandoned run stay on disk. Every later prepare reports them, and the operator removes them. **No cleaner scans or removes another run's files.**
- **No regression** of the #885 transport, including large-prompt attachment and the original-path `--file` contract.

The retention change is the only behaviour change Chris accepted. Its risk, as stated in the proposal: an unhandled prompt or critique can stay on disk in plaintext indefinitely.

## Problem

Step 5.6 in `skills/brainstorming/SKILL.md` uses two fixed paths under `<state dir>/ultra-oracle/`: the prompt `critique-prompt.txt` and the verdict `design-critique.md` (plus the adapter's `design-critique.md.err`). When runs A and B overlap in one state dir:

1. **Deletion.** B's prepare runs `rm -f "$PF"` after A Wrote its design; A's consult fails "prompt file missing".
2. **Cross-transmission.** B Writes its design before A's consult runs; A sends **B's design** to ChatGPT Pro, then A's trap deletes B's prompt. A data-boundary breach.
3. **Mixed verdicts.** Both consults write `design-critique.md`; A can Read B's critique as its own.
4. **Stale verdict, narrow.** The adapter clears `$out`, `.rc`, `.rc.partial`, `.err` and `.hint` before every dispatch (`scripts/lib/ultra-oracle.sh:874`) and truncates `$out` on timeout (`:1492`). A previous verdict survives only a consult that exits before reaching the adapter, or a non-zero exit that leaves a partial.

The #911 tool-turn gap (Write and consult are separate tool calls) makes 1 and 2 easy to hit.

## Root cause

The fixed name doubles as the abandoned-run backstop: a later prepare removes a prompt stranded by an aborted run. It cannot tell "stranded by a dead run" from "written a moment ago by a live run", so the backstop is also the cross-run delete.

## Today's lifecycle

| Artifact (blocking mode) | Removed today by | After this design |
|---|---|---|
| prompt `critique-prompt.txt` (design bytes) | consult trap; **any** later prepare in the state dir | consult trap; this run's cleanup fence. A crashed run's copy stays and is reported (§4) |
| verdict `design-critique.md` (critique quoting the design) | the adapter's startup clear at the next consult by any run | this run's cleanup fence. A crashed run's copy stays and is reported |
| `design-critique.md.err` (oracle stdout: may hold a partial critique and page text) | adapter on success; the startup clear at the next consult | as the verdict |
| `design-critique.md.sv.XXXXXX` (salvage temp, `ultra-oracle.sh:167`) | adapter (rename or rm) | as today, plus this run's cleanup fence; a leftover is reported |
| `$TMPDIR/tmp.XXXX/pf` (adapter's prompt snapshot) | adapter `rm -rf` right after reading | unchanged |
| oracle's own session store `~/.oracle/sessions/<slug>/` (0700) | not removed by busdriver | unchanged; out of #975's scope |

`.hint`, `.rc`, `.rc.partial` and `.dispatch.err` are written only in background mode, which Step 5.6 does not use.

## Approach

### 1. Run tag

Each run is named by one random **run tag** `T`: 64 bits from `/dev/urandom`, 16 lowercase hex digits. The prepare fence draws it and prints it (`run=`). Every later fence of the same run carries that value, pasted in place of the inert placeholder `RUN_TAG`:

```bash
T="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')" || T=
```
(prepare; the `|| T=` keeps `errexit`+`pipefail` from aborting silently on a failed `od`, so the validation line below emits its loud `run tag` diagnostic instead, per the fence contract at `SKILL.md:225`)

```bash
T=RUN_TAG
```
(consult A, consult B, cleanup; the model replaces `RUN_TAG` with the `run=` value printed by **this run's** prepare)

Every fence then validates it before forming any path:

```bash
[[ "$T" =~ ^[0-9a-f]{16}$ ]] || { echo "brainstorming: run tag missing or malformed" >&2; exit 1; }
```

The in-fence diagnostic is deliberately short: every word in a fence counts against the gate classifier's budget, which case 17 pins with 20 prepended pad lines. Its remedy sits in the Step 5.6 prose beside the fences:
- **from prepare,** the diagnostic means no tag could be drawn from `/dev/urandom`, so the remedy is Retry;
- **from consult or cleanup,** it means the pasted value is not a tag, so the remedy is to paste the `run=` value printed by this run's prepare.

No capture group, no `case` glob, no function (#296, #813 (g)). A value that passes contains only hex digits, so no `/`, `.`, whitespace, quote, `$` or backtick reaches a path.

**Why the name carries only the tag.** Earlier revisions also put the session id, owner pid and owner process start time into the name. Those parts existed for the cross-run collector, which the accepted scope removes. The round-3 review also found that they were fragile (a fence with a different `/proc` view derives a different name) and widened the data boundary (the basename is sent to ChatGPT Pro when the prompt is attached as a file). Without them:
- **No environment dependence.** The name does not read `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `$PPID` or `/proc`. Every harness where today's flow works gets the same names in prepare, consult and cleanup. The per-call-parent compatibility question and the env-trust residual of earlier revisions no longer apply.
- **Uniqueness.** Two runs share names only if they draw the same 64-bit tag. Within one agent, across subagents, and across sessions sharing a state dir, freshly drawn tags give every run distinct files.
- **Data boundary.** Only the random tag reaches ChatGPT Pro in the attachment basename, in place of today's fixed `critique-prompt.txt`.

**Carrying the tag.** The tag crosses tool turns as a value the model pastes, as writing-plans' tag already does:
- **Placeholder left in, or a non-hex value:** every fence exits with the `run tag` diagnostic and touches nothing.
- **A wrong but well-formed value that matches no run:** the consult fails "prompt file missing" (a loud `error`), and the cleanup removes nothing. The real run's files stay and are reported by later prepares (§4).
- **Lost to compaction:** the same as above. The run's files stay and are reported.
- **Known limitation, not a guarantee.** A fence given **another run's** `run=` value acts as that run. The consult sends that run's prompt, its trap removes that run's prompt, and the cleanup fence removes that run's files. This is exactly what pasting that run's `pf=` path would do. Nothing in this design binds a tag to the run that drew it, and this design does **not** claim that selecting another valid run is impossible.
  - **What narrows it.** A tag is printed only into the conversation of the run that drew it. The SKILL rule is to paste only the value printed by this run's own prepare. Normal interleaving and retry never do otherwise.
  - **Compared with today.** Every run shares one name, so every overlapping run hits every other one.
  - **Stronger binding** needs a trusted run association across tool calls that the model cannot select. None was established in the harness interfaces examined (`agent_id` is stable per agent; `tool_use_id` is per call). This is the revisit trigger, not part of #975.

### 2. Paths

| | Before | After |
|---|---|---|
| prompt `PF` | `<S>/ultra-oracle/critique-prompt.txt` | `<S>/ultra-oracle/critique-prompt-<T>.txt` |
| verdict `OUT` | `<S>/ultra-oracle/design-critique.md` | `<S>/ultra-oracle/critique-<T>.md` |
| adapter stdout | `…/design-critique.md.err` | `<OUT>.err` |
| adapter salvage temp | `…/design-critique.md.sv.XXXXXX` | `<OUT>.sv.XXXXXX` |

`<S>` is computed exactly as today: absolute `BUSDRIVER_STATE_DIR` verbatim, else the repo-root anchor, else `$HOME`. So the pre-implementation gate's state-dir Write exemption and its "parent exists" precondition are unchanged. Files stay flat in the existing gitignored directory. No basename matches the design-doc detector `^(PLAN|DESIGN|ARCHITECTURE)…\.md$`.

The **5 path lines**, which follow each fence's tag line, byte-identical across all four fences:

```bash
S="${BUSDRIVER_STATE_DIR:-.claude}"
[ "${S#/}" != "$S" ] || S="$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME")/$S"
[[ "$T" =~ ^[0-9a-f]{16}$ ]] || { echo "brainstorming: run tag missing or malformed" >&2; exit 1; }
PF="$S/ultra-oracle/critique-prompt-$T.txt"
OUT="$S/ultra-oracle/critique-$T.md"
```

The **run-files removal line**, used by the cleanup fence. It runs in bash so the `.sv.*` pattern expands with `nullglob` in both bash- and zsh-run fences:

```bash
bash -c 'shopt -s nullglob; rm -f -- "$1" "$2" "$2.err" "$2".sv.*' _ "$PF" "$OUT"
```

**Large prompts and transport: unchanged.** The consult passes `--prompt-file "$PF"` to the wrapper exactly as today. The adapter's inline cap, its attachment of the **original** prompt path via `--file` for larger prompts (`ultra-oracle.sh:1107-1127`), and the `--browser-attachments` default are untouched. Nothing forces inline delivery, makes a private copy, or limits prompt size.

### 3. Fence shapes

Four fences. Each starts with its **tag line** (prepare's generator, or `T=RUN_TAG`), then the **5 path lines**. The three fences that run the wrapper (prepare, consult A, consult B) then have the **6 resolver lines** (starting at `: "${CLAUDE_PLUGIN_ROOT=}"`), a second byte-identical block. In the two consult fences one per-fence line, the trap, sits between the two blocks; prepare has none. They are separate blocks, not one contiguous prefix.

- **Prepare.** Order: tag line → path lines → resolver → wrapper check → `mkdir -p` → residue notice (2 lines, §4) → `printf 'pf=%s\nsurface=%s\nrun=%s\n' "$PF" "$(bash "$WRAP" --surface-check brainstorming)" "$T"`.
  - Today's `rm -f "$PF"` line is **removed**. With a fresh 64-bit tag there is no earlier file of this name to remove, and prepare must never remove a file it did not create.
  - Prepare creates no file, only the directory. So the Path B `disabled` sentence at `SKILL.md:210` ("proceed to Step 6 with nothing written") stays true and unchanged.
- **Consult A / B.** Tag line → path lines → `trap 'rm -f "$PF"' EXIT INT TERM` → resolver → wrapper check → `[ -s "$PF" ]` → wrapper call → `printf 'oracle_status=%s\nout=%s\n' …`. Unchanged apart from the tag and path lines.
- **Cleanup (new, 4th fence).** Tag line → path lines → the run-files removal line `|| { echo "brainstorming: cannot remove run files: $PF $OUT $OUT.err $OUT.sv.*" >&2; exit 1; }`. No resolver, no wrapper, no surface check, no `mkdir`.

### 4. Lifecycle, Fail-CLOSED and crash residue

| Moment | This run's files |
|---|---|
| Prepare | new tag; reports other runs' files (residue notice) |
| Write | own PF at the printed `pf=` |
| Write-to-consult gap | own PF on disk (umask mode, gitignored dir): the #911 residual, now unreadable, undeletable and untransmittable by other runs that use their own tags |
| Consult | trap removes own PF on every trappable exit; the adapter writes own OUT, OUT.err on failure, OUT.sv.* during salvage |
| Verdict Read | on `ok`, the model Reads the printed `out=` |
| Retry | cleanup fence (current tag), then prepare (new tag) → Write → consult |
| **End of Step 5.6** | run the **cleanup fence** once, with the current tag |

**When to run the cleanup fence.** Once per prepared attempt, after its last consult decision:
- on `ok`, after the verdict is Read and folded in;
- on `skipped:disabled` and `skipped:user`, immediately, before proceeding (those statuses offer no choice; a consult-time Path B re-gate can return `skipped:disabled` after the Write);
- on `skipped:unavailable`, `timeout` or `error`, once the user's choice is skip-once or abort; on Retry, before the new prepare;
- after a Write whose consult never returned an `oracle_status=` line because the consult call was refused by a gate or never started. This replaces today's "run the prepare fence again and stop" rule, because prepare no longer removes anything.

**Never while a consult is still running.** A consult the harness backgrounded is still running, not failed (`SKILL.md:294`). Neither the cleanup fence nor Retry may run until that consult task, the harness-visible foreground Bash call, has finished or been killed by the harness. That ends the **fence**. It does **not** prove that oracle has stopped reading or writing: a detached oracle worker can outlive it (late reads and writes below).
- **Why.** The cleanup fence removes this run's PF and OUT. For a large prompt the adapter attaches the **original** PF path via `--file` (`ultra-oracle.sh:1107-1108`), and oracle reads it later. A cleanup during the consult could delete a prompt the consult still needs, and an OUT before the adapter writes it.
- **The `SKILL.md:294` sentence** "Never Retry while an earlier consult task is still running: Retry's prepare step deletes the prompt it may still be reading" is rewritten. It now names the cleanup fence, covers both cleanup and Retry, and gives the original-path reason (needle 18m; the old sentence is gone).
- **A consult the harness killed** counts as `error` and is cleaned up as above. Killing it ends only the foreground fence. Like today's trap, which already removes PF when the consult fence exits, this run's own cleanup can then remove PF or OUT while a detached oracle worker still uses them. Such a worker may still read the original PF path, or write OUT afterwards. That is the existing behaviour described below. This design does not detect or wait for it, and it gives no guarantee that oracle has gone quiet.

On Path B `disabled` at prepare, nothing was written, so no cleanup is needed (§3).

**Fail-CLOSED exception**, stated next to the existing bullet in the SKILL. The cleanup fence is not a consult:
- **Any** non-zero exit of the cleanup fence never sets `oracle_status`, never offers Retry / skip-once / abort, and never blocks Step 6. That includes its `run tag` diagnostic and `cannot remove run files`. The model relays the stderr line, with its paths, to the user and continues. If the user has already chosen Retry, a failed cleanup does not cancel it: the model continues with that Retry's new prepare.
- Consult-fence branching is unchanged: a consult fence that exits non-zero with a `brainstorming:` diagnostic and no `oracle_status=` line is still `error`.
- Prepare's non-zero exits still count as `error`. A prepare that **exits 0** is successful even when its stderr carries the residue notice. The model branches on `surface=` as usual and relays the notice to the user.

**Gate refusal fallback** (carried over from today's rule; every fence classifies as file-modifying, so a design review pending elsewhere can make the gate refuse it):
- If the cleanup fence is refused, tell the user this run's file names under `<S>/ultra-oracle/`: `critique-prompt-<T>.txt`, `critique-<T>.md`, `critique-<T>.md.err`, any `critique-<T>.md.sv.*`.
- Say that they stay until the operator removes them.
- Do not retry the refused call in another form.

**Crash residue: reported, never collected.** A run that crashes, is cancelled, or loses its tag leaves whatever it wrote: PF, OUT, OUT.err, an `.sv.*` temp. Its own fences can no longer run, and **no other run removes another run's files**. Every prepare reports them instead, with these two lines placed after `mkdir -p`:

```bash
N="$(find "${PF%/*}" -maxdepth 1 -type f \( -name 'critique-prompt-*.txt' -o -name 'critique-*.md' -o -name 'critique-*.md.*' -o -name 'critique-prompt.txt' -o -name 'design-critique.md*' \) ! -name "*$T*" 2>/dev/null | wc -l | tr -d ' ')" || N=0
[ "${N:-0}" -eq 0 ] || printf '%s\n' "brainstorming: $N oracle prompt/critique file(s) from other runs are in ${PF%/*} and are never removed automatically — they belong to runs still in progress or to runs that crashed or were abandoned; list: ls -lt $(printf '%q' "${PF%/*}") ; delete only files of runs you know have ended" >&2
```

- **What it counts.** Every regular file in `<S>/ultra-oracle/` that holds design or critique bytes from another run: prompts, verdicts, `.err`, `.sv.*`. It also counts the legacy fixed-name pair, which nothing removes after this change (Non-goals). The unit is one file.
- **What it excludes.** This run's own names, writing-plans' `plan-advisory-*`, directories and anything outside the directory.
- **It reads only, and never fails prepare.** It removes nothing. The `|| N=0` guard keeps `errexit`+`pipefail` from aborting prepare on a failed `find` (`SKILL.md:225`), for example an entry that vanishes mid-walk while another run cleans up. After such a failure the count may be incomplete (a partial walk, or 0). That is a reporting gap only, not a prepare failure, and the next prepare counts again.
- **No live/dead claim.** It does not say which files belong to a live run. A run paused in the Write-to-consult gap is live for any length of time, and no signal in this design proves otherwise. The notice says so, and the SKILL's operator section repeats it: delete only files of runs you know have ended.
- **The SKILL's operator section** documents the names (`critique-prompt-<tag>.txt`, `critique-<tag>.md`, `.md.err`, `.md.sv.*`; one tag per run), the listing command, the legacy pair, and the plaintext-at-rest risk Chris accepted.

**Late reads and writes by a consult that outlived its fence (existing behaviour, not fixed here).** Oracle runs a detached worker for local Pro browser consults. A cap or timeout kill of the foreground does not stop it (oracle docs: a caller "timeout, request cancellation, or transport closure does not cancel the detached worker"). That worker may still read the original PF path, and write `--write-output` (OUT), after the consult fence, or even the cleanup fence, has finished.
- **Today** that late file lands on the shared `design-critique.md` and is cleared at the next consult.
- **With per-run names** it lands on this run's `critique-<T>.md` and stays. The residue notice reports it.
- **What #975 does not change:** this design does not stop that worker, and it does not prove when oracle has stopped reading or writing. There is no quiescence guarantee. The worker's own lifetime is unchanged from today.
  - This run's own trap and cleanup fence can remove PF or OUT while the worker still uses them, as today's trap already can for PF.
  - Because no run removes another run's files, this design adds no **cross-run** way to delete files a live worker uses.

### 5. writing-plans (consistency)

`skills/writing-plans/SKILL.md:34` copies brainstorming's prepare fence and the consult fence for the active path, with substitutions. It now also copies the **cleanup fence** as a third copied fence. The bullet is updated (amended in §5a: the copies keep brainstorming's run tag):

- (a) **amended:** the copies keep the run tag. The tag is the `run=` value the copied prepare fence prints, drawn from `/dev/urandom` exactly as in brainstorming; the model pastes it over `RUN_TAG` in the consult and cleanup copies. Pasting only this run's printed value is a procedural rule, as in brainstorming (§1); the `[[` check is a format check only (§5a). (Before this amendment: a model-chosen 6-character `<tag>`.)
- (b) replace the whole line `PF="$S/ultra-oracle/critique-prompt-$T.txt"` with `PF="$S/ultra-oracle/plan-advisory-$T-prompt.txt"` in all three copies.
- (c) replace the whole line `OUT="$S/ultra-oracle/critique-$T.md"` with `OUT="$S/ultra-oracle/plan-advisory-$T.md"` in all three copies. Every copy now carries `OUT=`; "only the consult fence has an `OUT=` line" is deleted.
- (d) its wording changes from "in both copies" to "in the prepare and consult copies" (surface name `writingPlans`, slug). The cleanup copy has neither. (e) unchanged (the Write target is the copied prepare's `pf=`).
- (f) **amended:** delete from the prepare copy only the two residue-notice lines (`N="$(find …` and `[ "${N:-0}" -eq 0 ] …`). They count brainstorming's names only. The tag line (`T="$(od …` or `T=RUN_TAG`) and the `[[ "$T" =~` line stay in all three copies.
- (g) **withdrawn:** the prepare copy keeps its `printf 'pf=%s\nsurface=%s\nrun=%s\n' …` line; (d) changes only its surface name, so it prints `run=`.
- **Clean up per run** now runs the **copied cleanup fence**, with only this run's own `run=` pasted. It recomputes `PF` and `OUT` itself from the substituted lines, so it works in the fresh shell every Bash call gets (`writing-plans/SKILL.md:227`), including on an abort before any consult printed `out=`. It removes the prompt, out, `out.err` and any `out.sv.*`. Today's sentence names only the prompt and out (pre-existing gap, round-3 low).
  - When to run it: after branching on `oracle_status=`, and on every abort path after the Write. Never while a backgrounded consult is still running (§4).
  - Any non-zero exit of a copied fence (`run tag`, `cannot remove run files`, or another `brainstorming:` diagnostic) prints no `oracle_status=`. An empty status is already non-blocking (`writing-plans/SKILL.md:36`), so the line is relayed to the user and **never pauses plan-writing**. For the cleanup copy that is the same exception as brainstorming's cleanup fence (§4).
- **Backstop sentence** becomes: neither surface has a cross-run backstop; both rely on per-run cleanup, and leftovers stay until the operator removes them. brainstorming's residue notice does not count `plan-advisory-*`; the operator lists them with `ls -lt <S>/ultra-oracle`.
- **"Three fences" sentence.** `writing-plans/SKILL.md:34` says "The byte-identity rule applies only to brainstorming's own three fences". It becomes "… brainstorming's own four fences; these three copies differ by exactly the substitutions above".

**Resulting check, pinned to whole lines** (not substrings, since `$PF` contains `$P`):
- every copy keeps its tag line and the `[[ "$T" =~` line verbatim; the prepare copy keeps `run=%s` and has no `N="$(find` line;
- `$PF` and `$OUT` remain, with the `plan-advisory-$T` basenames;
- the cleanup copy keeps the run-files removal line and its `|| { …cannot remove run files… }` diagnostic verbatim;
- the "four fences" sentence is present and "three fences" is gone (needle 19b).

The byte-identity rule applies only to brainstorming's own four fences.

### 5a. Amendment: the writing-plans copies keep the run tag

- **Context.** PR #987 review (CodeRabbit and cubic) found that the copies' model-chosen tag can repeat across concurrent plan-writing runs in one checkout. Equal tags give equal `PF`/`OUT`. The tag weakness predates #975: the old cleanup sentence already deleted the tagged prompt and out. But this design's copied cleanup fence also removes `OUT.err` and `OUT.sv.*`, so a repeated tag exposes **more** of another run's files to deletion. That widening is introduced by #975. It breaks the accepted promise that normal runs never delete another run's files, and a non-blocking advisory does not make that safe. No collision was reproduced; the finding is from source.
- **Decision.** The copies keep brainstorming's tag mechanism: the `/dev/urandom` draw in the prepare copy, the printed `run=`, the pasted `RUN_TAG`, and the `[[ "$T" =~ ^[0-9a-f]{16}$ ]]` check in every copy. Only the basenames change ((b), (c)). Each run's own cleanup copy then names files only its own 64-bit tag can produce. Before removing anything, it refuses a missing or unpasted tag, and any value that is not 16 lowercase hex digits (such as the pre-amendment 6-character shape), with the `run tag` diagnostic. That is a format check: as in brainstorming (§1), it cannot tell a drawn tag from a 16-hex value the model invents. Pasting only this run's printed `run=` is the procedural rule that keeps cleanup per-run.
- **Why this is a correction, not new scope.** It does not change acceptance. It enforces the accepted own-run cleanup in the copied fences. It reuses the reviewed brainstorming mechanism unchanged. It adds no cross-run deletion and no new collector. Opt-in, surface, transport and the #885 `--file` contract are untouched. Crash residue keeps the accepted behaviour: it stays on disk, brainstorming's notice does not count `plan-advisory-*`, and the operator lists it with `ls -lt`.
- **Alternatives rejected.**
  - Keep the 6-character tag and trim the cleanup copy back to prompt and out. That removes only the widening. It keeps the pre-existing cross-run deletion and leaves this run's own `.err`/`.sv.*` behind.
  - An ownership file or lock beside the pair. That is new state and new failure modes for what the tag already does.
- **Residual (same as brainstorming, §1).** A wrong but valid pasted tag acts as that run. Two independent draws coincide with probability 2^-64.
- **Consequences.** Each copy is two lines longer than before (the tag line and the `[[` line stay), and the prepare copy prints `run=` again. They must stay inside the classifier budget, which case 32 checks with 20 pad lines. Follow-up #990 (filed for the model-chosen tag) is fully covered by this amendment.

## Non-goals

- No change to opt-in/surface semantics, wrapper resolution order, status tokens, the timeout contract, the #885 transport (inline cap, original-path `--file`, attachment mode), or consult-fence Fail-CLOSED branching. The Fail-CLOSED additions are the cleanup-fence exception and the "prepare exit 0 with a notice is success" rule (§4).
- **No cross-run cleaner** of any kind: no collector, no age rule, no liveness proof, no SessionEnd hook.
- No sweep or migration of the legacy `critique-prompt.txt` / `design-critique.md*`. Today the adapter's startup clear removes `design-critique.md` and `.md.err` at the next consult; after this change nothing does. The residue notice counts them, and the operator section names them as a one-time migration leftover.
- No change to `hooks/`, `hooks/gate-scripts/` or `scripts/hooks/` (no lockfile regen), to oracle or to the harness.
- writing-plans' tag scheme changes only as §5a requires: the copies keep brainstorming's run tag. No other change to the advisory. Giving writing-plans its own verbatim fences is a possible follow-up, filed only if dots agrees.
- The consult trap's INT/TERM continuing to print `oracle_status` (round-3 low) is today's behaviour and stays a separate follow-up.

## Other residuals

- **Write-to-consult gap.** The design file sits in the state dir with umask mode across tool turns, as today. Other runs using their own tags can no longer read, delete or transmit it.
- **Wrong valid tag.** §1, known limitation.
- **Late Oracle writes.** §4, existing behaviour.
- **Oracle session store and adapter `$TMPDIR` snapshot.** Unchanged (lifecycle table).
- **Oracle's write-output permission fallback.** On EACCES/EPERM, oracle writes the answer to `<stem>.fallback<ext>` in its working directory, outside `<S>/ultra-oracle/`. This is existing oracle behaviour, unchanged and not reported by the notice.

## Tests

### Shell: `tests/test-brainstorming-oracle-wrapper-root.sh`, extended in place

The harness extracts the four fences verbatim. Today it requires exactly 3 fences, found by the needles `--surface-check`, `--surface brainstorming --mode` and `--prompt-file`; it now requires exactly 4. The cleanup fence's needle is the run-files removal line in a fence with neither `--prompt-file` nor `--surface-check`. Each step pastes the `run=` value from its own prepare into `T=RUN_TAG`. Interleaved cases use distinct design bytes α and β (different lengths, a non-ASCII byte, a trailing newline; compared with `cmp`). Where a case needs a predictable tag, a PATH-stubbed `od` fixes it.

| # | Case | Expect |
|---|---|---|
| 1–16 except 13/13b | existing cases, paths re-derived from the run tag | unchanged verdicts |
| 13 / 13b | stale own prompt removed by prepare; `cannot remove stale prompt` | **removed**: prepare no longer removes anything |
| 12a–c | path agreement | `out=` is `${pf%/*}/critique-<T>.md`; `run=` is 16 hex |
| 15 | existing `set -euo pipefail` prepare case, extended: PATH-stubbed `find` exiting 1, then PATH-stubbed `od` exiting 1 | `find`: prepare exits 0 with `pf=`/`surface=`/`run=`; `od`: the `run tag` diagnostic, nothing created |
| 17 | classifier budget (requirement **unchanged**) | all 4 fences `OK|`, bare and with 20 pad lines; the case's comment records the re-measured padded-line margin for all 4 fences (it now quotes the old 3-fence figures) |
| 18f | prepare order (**rewritten**: today pins `rm` < resolver) | resolver < wrapper check < `mkdir` < notice < `printf`; prepare has no `rm` |
| 18g | basenames | carry `T`; clear the detector regex |
| 18j | `is_file_mod` (**extended** from 3 fences to 4) | true for all 4 fences, including cleanup, whose `rm` sits only inside the `bash -c` operand |
| 18k / 18l | shared blocks (**rewritten**: today 18l pins 3 path lines) | 5 path lines identical across all 4 fences, each preceded by its tag line; 6 resolver lines identical across the 3 wrapper fences |
| 20 | **interleaved A/B**: A prep → A Write α → B prep → B Write β → A consult → B consult (stub writes `verdict:<prompt body>` to `--out`) | A's capture `cmp`-equals α, B's β; distinct `out=`; each OUT holds its own verdict; B's prepare left α intact |
| 20b | **two runs in one agent**: identical environment, interleaved as in 20 | distinct `run=` and names; same results as 20 |
| 21 | **retry and cleanup of A cannot touch B**: B prep → B Write β (left un-consulted, so live) plus a B OUT/OUT.err fixture; A prep → Write α′ → consult → cleanup → (retry) prep → Write → consult → cleanup | B's PF, OUT and OUT.err byte-identical after every A step; A has no files after each cleanup |
| 22 | **aborted gap**: A Writes α and is abandoned; B prep → Write β → consult → cleanup | α intact and never sent; B's prepare notice counts α's file; A's cleanup with A's tag removes it |
| 22b | **lost tag**: consult and cleanup with `T=RUN_TAG`, `T=xyz`, an 8-hex value, a well-formed unmatched 16-hex value | first three: `run tag` diagnostic, nothing touched, no wrapper call; fourth: consult `error` (prompt file missing), cleanup removes nothing |
| 23 | **overlap + cancellation**: A consult in the background on a stub that signals ready and holds its call open until the test releases it; B runs fully during it; A's shell gets TERM, then the release | A still in flight with its PF present at TERM; the stub records `released` (a cap expiry fails the case); A's PF existed during its call, gone after; B ok with its own bytes; B untouched |
| 24 | **no environment dependence**: `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` set, unset, or different between prepare and consult (per-call parent shape) | the same names in every fence; consult ok |
| 25 | failed consult (stub exits 1 after writing stdout) | OUT.err exists; A's cleanup removes it; B's OUT.err byte-identical |
| 25b | **kill during salvage**: stub leaves `OUT.sv.Ab12Cd` and is killed | A's cleanup removes it; before that, another run's prepare counts it |
| 26 | zsh: 20, 21, 25b and 29 under zsh | same |
| 27 | **blocked consult**: Write, no consult, cleanup fence | own PF gone; B untouched |
| 28 | **cleanup Fail-CLOSED exception**: cleanup with OUT as a non-empty directory; cleanup with a malformed tag | exit 1 with `cannot remove run files` / `run tag`; SKILL needles show both map to no `oracle_status` |
| 29 | **residue notice**: other runs' `critique-prompt-<x>.txt`, `critique-<x>.md`, `.md.err`, `.md.sv.Ab12Cd`, the legacy `critique-prompt.txt` and `design-critique.md.err`; plus `plan-advisory-*`, a directory named `critique-<y>.md`, and a `critique-*` symlink | prepare exits 0, prints `pf=`/`surface=`/`run=`, stderr notice with `6`; **every file byte-identical and present afterwards**; the plan-advisory files, directory and symlink are not counted and untouched |
| 29b | **no residue** | no notice line |
| 30 | **late write after cleanup**: the stub's detached writer waits for a release the test sends only after A's cleanup fence returned | nothing written before the release; the writer records `released` (a cap expiry fails the case); the file stays; the next prepare's notice counts it; no fence removes it |
| 31 | **large prompt**: PF above the adapter's inline cap | the adapter receives the original `critique-prompt-<T>.txt` path (stub records `--file`); no copy is made under `<S>` |
| 32 (**amended, §5a**) | **writing-plans copies, two concurrent runs and a crashed one**: the prepare/consult B/cleanup copies built by (b), (c), (d), (f); under bash and zsh, runs A and B each run the prepare copy in one state dir, then the test writes A's and B's four `plan-advisory-<tag>` files (prompt, out, `.err`, `.sv.1`) at the paths their tags give, and a crashed run C's four files are present; then A's cleanup copy (A's `run=` pasted) runs in a fresh shell from a cwd holding a stray `.err` and a `x.sv.1` file; then the cleanup copy with a model-chosen 6-character tag (the pre-amendment shape) and with `RUN_TAG` unpasted | the copies keep the tag and `[[` lines, the prepare copy drops only the notice lines and prints a 16-hex `run=`, and A's and B's tags differ; all copies classify `OK|` bare and with 20 pad lines; A's four `plan-advisory-<A>` files are gone, while B's and C's four each are byte-identical and present; the cwd files survive; both bad tags exit 1 with `run tag` and remove nothing; B's own cleanup then removes B's files, and C's crash residue stays; a failing removal (OUT as a non-empty directory) exits 1 with `cannot remove run files` |
| 18m (**rewritten**) / 19b | prose needles | `RUN_TAG`; the cleanup fence rule (incl. Retry, the immediate `skipped:disabled`/`skipped:user` case, and the no-status Write case); "never while a consult is still running" and the rewritten `SKILL.md:294` sentence; the Fail-CLOSED exception (any cleanup exit; a failed cleanup keeps an already chosen Retry); the prepare-notice-is-success rule; the gate-refusal fallback with the four names; the operator section (names, listing, legacy pair, plaintext risk, "delete only files of runs you know have ended"); the paste-only-your-own-`run=` rule and the wrong-tag limitation; the run-tag remedy prose (prepare: no tag drawn from `/dev/urandom`, Retry; consult/cleanup: paste this run's `run=`); the in-fence diagnostic is exactly `brainstorming: run tag missing or malformed` with no trailing remedy text. Gone (whole phrases, so each stale `:206`–`:303` sentence listed under Files is pinned): "run the prepare fence again", "Retry's prepare step deletes the prompt", "fixed-name stale-prompt backstop", "doubles as the cleanup command", "removes any stale prompt", "stale-prompt-removal", "same 9 lines", "In the prepare fence `rm` precedes", "The next prepare run removes a stale prompt", "Retry means prepare → Write → consult again". writing-plans: the exact (b)/(c) lines, the amended (a) and (f), no model-chosen 6-character tag and no `(g)` printf replacement, the copied cleanup fence and its never-pause rule, the new backstop sentence, the "four fences" sentence, the pinned negative checks from §5 |

The wrong-tag limitation (§1) is documented, not asserted as a guarantee. No case claims that another run's valid tag is refused.

## Files

- `skills/brainstorming/SKILL.md`, Step 5.6:
  - the 4 fences with their tag lines and the `RUN_TAG` instruction;
  - prompt path, basenames and shared blocks prose;
  - the flow, the cleanup rule (incl. Retry and the no-status Write case), and the replacement of the "run the prepare fence again" rule;
  - the Fail-CLOSED exception and the prepare-notice rule;
  - the gate-refusal fallback;
  - the residue notice, the operator section, the wrong-tag limitation, and the late-write note;
  - **stale prose that contradicts the new fences, each rewritten:**
    - `:206` flow step 1 ("removes any stale prompt left by an abandoned earlier run"), now "prints `run=`";
    - `:214`/`:216` the prompt path and basename paragraphs (fixed `critique-prompt.txt`; "`OUT` keeps its name, `design-critique.md`");
    - `:218` and `:290` "the same 9 lines" / "the 9 shared lines": now the 5 path lines plus the 6 resolver lines;
    - `:227` "it doubles as the cleanup command — it removes the prompt before doing anything else": prepare removes nothing, so the cleanup fence is named instead;
    - `:288` "In the prepare fence `rm` precedes the resolver";
    - `:292` the cleanup-residual paragraph ("run the prepare fence again and stop", "The next prepare run removes a stale prompt as a backstop"), replaced by the §4 cleanup rule and residue notice;
    - `:301` "stale-prompt-removal diagnostics": now "run tag diagnostics";
    - `:303` "Retry means prepare → Write → consult again": now "cleanup → prepare → Write → consult".
- `skills/writing-plans/SKILL.md`: the Paths bullet (§5).
- `tests/test-brainstorming-oracle-wrapper-root.sh`
- this design doc

No new script.

## Verification

- `bash tests/test-brainstorming-oracle-wrapper-root.sh` passes, including the zsh rows.
- Related suites: `tests/test-ultra-oracle.sh`, any test that greps writing-plans or brainstorming, `npm run validate`, `npm test`, `shellcheck` on the test.
- Litmus before each commit, then the pre-PR litmus, then pr-grind.

## Review findings and their disposition

Earlier revisions were reviewed in runs `28daf09d` (iteration 1), `da19ec81` (iteration 2), `511ac080` (iteration 3) and `e4602473` (iteration 4). The evidence is archived in `docs/reviews/issue-975-brainstorming-run-isolation/round{1,2,3}-*-evidence/` and `attempts/001-511ac080/`. All four verdicts were FAIL, and none of those revisions was approved. "Moot under accepted scope" means the finding concerned a component this revision removes because Chris accepted the no-cross-run-cleaner scope. Removing a component does not show that the finding was wrong.

### Iteration 3 (run `511ac080`)

| Finding | Disposition |
|---|---|
| HIGH: live consult child after owner death; the collector deletes files a live process uses (B1, case 44) | **Moot under accepted scope.** No collector and no cross-run deletion (Non-goals). Not claimed: that Oracle has stopped when a fence ends. The existing late-write path is stated in §4 |
| HIGH: wrong but well-formed tag reaches another run (B2, case 22b row 4) | **Stated as a known limitation (§1), not a guarantee.** The old row 4 ("another live run's valid tag", required to be refused) is removed from the acceptance table; it was added in an earlier draft, and no approval of it was established. The other values stay, and the new fourth value is a well-formed tag matching **no** run (22b) |
| MEDIUM: D-R pending, contradictory clauses; legacy names lose their backstop | **Resolved by Chris's acceptance** (Accepted scope). Legacy pair now counted by the notice (§4) |
| MEDIUM: claim suffix vs claim rule | Moot under accepted scope (no claims) |
| MEDIUM: proven-dead records neither deleted nor counted without D1 | Moot under accepted scope; every other run's file is counted (§4) |
| MEDIUM: key-parse grammar for artifacts and `.sv.*` alphabet | **Addressed without parsing:** the notice matches by name prefix and excludes only this run's tag; `.sv.Ab12Cd` is counted (case 29) |
| MEDIUM: notice listing could lead an operator to delete a live run's files | **Addressed in wording:** the notice and operator section say the files may belong to runs in progress and to delete only files of runs known to have ended. No live/dead claim is made (§4) |
| MEDIUM: per-call-parent harness turns consults into errors | **Resolved:** the name no longer reads `CLAUDE_PID`/`$PPID` (§1, case 24) |
| MEDIUM: `/proc` view differences change `G` in the filename | **Resolved:** no generation in the name (§1) |
| LOW: writing-plans cleanup sentence omits `.err`/`.sv.*`; §7 prepare-removal claim | **Addressed:** full-set cleanup sentence; prepare has no removal line (§5) |
| LOW: cases 13/13b vacuous | **Removed:** prepare no longer removes anything |
| LOW: "no process" vs unreadable stat | Moot under accepted scope |
| LOW: trap INT/TERM still prints `oracle_status` | Unchanged existing behaviour; separate follow-up (Non-goals) |
| LOW: macOS collection needs its own liveness rule | Moot under accepted scope |
| LOW: notice count mixes units | **Addressed:** one unit, files (§4) |
| LOW: "field 22" wording | Moot (no `/proc` parsing) |
| LOW: `P` read before validation | Moot (no `P`) |
| LOW: basename sends session id/pid/starttime to ChatGPT Pro | **Resolved:** only the random tag is in the name (§1) |
| Deferred mediums in `follow-up-issues.md` (`.reap` claim recovery; proven-dead not counted) | Moot under accepted scope; no follow-up needed unless a collector is proposed again |

### Iteration 5, run `c25b8843` (not recorded)

Reviewers: Agy PASS (0 issues), Codex FAIL (1 medium), Grok ERROR (exit 124 at the 1200 s reviewer budget; no signal). The c25 arbiter verdict is **NON-ACCEPTABLE**: the arbiter broke its Read-only evidence restriction with one Bash call. The verdict is **UNRECORDED**. It is preserved, not counted, in `docs/reviews/issue-975-brainstorming-run-isolation/run-c25b8843-evidence/`. The finding below is acted on from Codex's report and the cited source mechanism, not from an accepted verdict.

| Finding | Disposition |
|---|---|
| MEDIUM (Codex): the long in-fence run-tag diagnostic breaks case 17's classifier headroom. A padded fence reaches `BLOCK_MARKER_SCRIPT` via the class-expansion reserve (`marker_check.py` `_HELPER_CLASS_RESERVE`) and the fail-closed `_bracket_prefix_hit` | **Addressed:** the in-fence diagnostic is shortened to `brainstorming: run tag missing or malformed`; its remedy moved to adjacent prose (§1) and is pinned by 18m. Case 17 is unchanged (all 4 fences, 20 pad lines); its margin comment is re-measured at implementation |

### Iteration 4 (run `e4602473`)

| Finding | Disposition |
|---|---|
| MEDIUM: writing-plans cleanup is a bare removal line with unset `PF`/`OUT` in a fresh shell | **Addressed:** writing-plans copies the cleanup fence as a third fence, which recomputes its paths; its exit never pauses plan-writing (§5, case 32) |
| MEDIUM: unguarded `find`/`od` pipelines under `errexit`+`pipefail` | **Addressed:** `|| N=0` and `|| T=` (§1, §4, case 15) |
| MEDIUM: backgrounded-consult guard (`SKILL.md:294`) not carried over; cleanup could delete a prompt oracle reads later | **Addressed:** "never while a consult is still running" for cleanup and Retry, and the `:294` sentence rewritten (§4, needle 18m) |
| LOW: `skipped:disabled`/`skipped:user` offer no choice | **Addressed:** cleanup runs immediately for those two (§4) |
| LOW: §3 per-fence-line wording | **Addressed** (§3) |
| LOW: "1–16 unchanged" inaccurate | **Addressed:** 13/13b removed; 18f, 18l, 18m marked rewritten (Tests) |
| LOW: no extraction needle for the 4th fence; 18j covers 3 fences | **Addressed:** needle named; 18j extended to 4 fences (Tests) |
| LOW: writing-plans "three fences" sentence; 22b disposition wording | **Addressed** (§5; iteration-3 table) |
| LOW: brace style in `"$2.err"` | No change: the arbiter found it not a defect |

### Iterations 1 and 2 (runs `28daf09d`, `da19ec81`)

| Finding | Disposition |
|---|---|
| OUT.err omitted | addressed: cleanup and notice include `.err` and `.sv.*` |
| SessionEnd 1.5 s plugin budget; hook `cwd` handling | moot: no hook |
| `--continue` / bare `--resume` session id; Bash caveat | moot: the name does not use the session id |
| cleanup vs Fail-CLOSED | addressed: dedicated cleanup fence and exception (§4) |
| writing-plans tokens and substitution burden | addressed: exact lines and pinned checks (§5); own fences remain a possible follow-up |
| "11 byte-identical lines" | addressed: separate blocks, stated per test (§3) |
| test 21 B's PF live | kept (case 21) |
| `export` advice; "undocumented" claim | moot: no env-derived identity |
| hazard 4 overstated | kept as restated (Problem 4) |
| silent retention on macOS / failed self-probe | superseded: nothing is collected anywhere, and every other run's file is reported |
| Linux `lstart` fallback; generation primitive | moot: no generation |
| cleanup removes the record when an artifact fails | moot: no owner record |
| `.sv.*` never removed | addressed: cleanup removal line (§2), case 25b |
| subagents share the key | addressed: a fresh tag per run, case 20b; a wrong pasted tag is the §1 limitation |
| hidden `/proc` entries; `/proc` visibility under sandboxed Bash | moot: no `/proc` read |
| orphaned consult children | moot as a collector hazard (no collector); the late-write behaviour is stated in §4 |
| key parse; UUID parse; claim `mv` stderr; owner temp name | moot: no records |
| D-R frequency | resolved by Chris's acceptance |
| cleanup/prepare diagnostics unclassified | addressed: §4 exception and prepare-notice rule |
| cross-host collision; uniqueness claim | addressed: 64-bit tag, scoped claim (§1) |
| legacy files and listing | addressed: counted and named (§4, Non-goals) |
| SKILL.md:210 Path B sentence | unchanged and still true: prepare writes no file (§3) |
| refusal fallback dropped | carried over with the four names (§4) |

## Key decisions

- **Context:** the fixed name is both the abandoned-run backstop and the cross-run hazard. The issue named the choice between the two as a design decision, and Chris accepted isolation with operator-handled crash residue.
- **Decision:**
  - a 64-bit random run tag, carried by the model, as the only per-run part of the name;
  - own-run cleanup through the trap and a new cleanup fence;
  - no cross-run cleaner;
  - every later prepare reports other runs' files;
  - the wrong-tag case stated as a limitation, not a guarantee.
- **Alternatives:**
  - a proof-of-death collector (iteration 3; needs a stop proof for live consult children, not established);
  - own-run cleanup with a SessionEnd hook (1.5 s budget, misses crashes);
  - TTL or age rules (remove paused live runs);
  - `flock` or a keeper process (no holder across turns / fails when it dies early);
  - an env-derived identity (fragile across `/proc` views and per-call parents, and leaks identifiers to the oracle).
- **Consequences:**
  - crashed runs' plaintext design and critique copies stay until the operator deletes them (accepted risk);
  - a wrong pasted valid tag acts as that run;
  - a consult worker that outlives its fence can leave a late verdict, which is reported.
- **Revisit trigger:**
  - a harness-provided, model-unselectable run association across tool calls (would bind the tag);
  - a typed, generation-bound release signal from oracle that all readers and writers have stopped (would make a safe cross-run cleaner possible);
  - a request to bound crash-residue retention again.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
