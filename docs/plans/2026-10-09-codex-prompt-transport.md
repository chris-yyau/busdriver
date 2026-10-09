# Codex prompt transport above 128 KiB (#928, transport only)

> **For agentic workers:** small change: one function in `scripts/lib/resolve-cli.sh` (`_execute_codex`, including D4's per-attempt unlinked staging on the direct arm and its `_ECX_STAGE_FAILED` flag), the litmus runner's ownership of the staged prompt file (D3 amendment), one new shell test, and new assertions in two existing suites (`tests/test-litmus-mode-transition.sh`, `tests/test-codex-broker-teardown.sh`). Execute inline; no subagent fan-out.

**Goal:** A Codex review prompt of any size reaches the reviewer byte-for-byte on BOTH `_execute_codex` arms (codex-companion `--prompt-file`, and the direct `codex exec -` fallback). If the prompt cannot be written completely, the review fails closed BEFORE any reviewer starts: no prefix is ever reviewed, no PASS is produced, and the private prompt file is removed.

**Scope:** transport only. Refs #928; does NOT close it. The second half of #928 (cross-mode `infra_failure` retirement / commit-block `--force` rule) is out of scope and stays open on the issue. No change to retries, budgets, SAST, enrichment, prompt bounds, provider policy, or `_bd_emit_chunked` itself. One exception is included: cleanup of the prompt file this change introduces (D3 amendment, D4). That covers the runner's ownership of the file and its unlinking. It does not touch watchdog timeouts or policy.

---

## Evidence (measured 2026-10-09 on `6b4368a`, Linux)

- **Companion arm** (`resolve-cli.sh:3322`): `/usr/bin/printf '%s' "$1" > "$_ECX_PROMPT_FILE"` hands the whole prompt to one `execve` argument. Linux caps one argument at `MAX_ARG_STRLEN` = 131072 B regardless of `ARG_MAX` → `Argument list too long` → "failed to write codex prompt to temp file" → `infra_failure` (observed on #885's 120 KB staged diff once SAST/context were added, and on PR #926).
- **Direct arm** (`resolve-cli.sh:3516`): `/usr/bin/printf '%s' "$1" | … codex exec -s read-only -`. Same E2BIG: the producer dies and codex reviews an EMPTY stdin. Reproduced WITHOUT `pipefail` with a stub codex and a 200,000-byte prompt: stderr `line 3516: /usr/bin/printf: Argument list too long`, stub received **0 bytes**, `_execute_codex` returned **rc 0 with the stub's PASS**, because the pipeline's status is codex's. Both real callers (`skills/litmus/scripts/run-review-loop.sh`, `skills/blueprint-review/scripts/run-design-review-loop.sh`) run under `set -o pipefail`, so on the gate of record the producer's failure makes every attempt non-zero and the review ends as an infra failure / fallback, not a false PASS. The latent false PASS is reachable only by a caller without `pipefail`; either way the reviewer is dispatched on an empty prompt.
- `_bd_emit_chunked` (`resolve-cli.sh:1301`) already writes a string byte-exactly in ≤30000-character pieces through `_bd_run_clean /usr/bin/printf`, stopping and returning 1 at the first failed piece. It backs the agy arms and is covered by `tests/test-agy-stream-transport.sh` (u16: write failure ⇒ non-zero even with `return` shadowed).

## Decisions

> **Reading order.** D1–D3 are the original decisions, kept as written for the record. Review amendments supersede parts of them:
> - **D1:** staging before the attempt loop now applies to the **companion arm only**. The direct arm stages once per attempt (D4).
> - **D2:** the direct arm's reading from a staged file on a *named path* is replaced by D4's unlinked inode. The no-pipe rationale still holds.
> - **D3:** its direct-arm cleanup is replaced by D4. Its runner-ownership amendment now matters for the companion arm.
>
> Where they differ, D4 is current for the direct arm.

**D1. One staged file for both arms.** Move the `mktemp` + write block out from under the `companion && node` condition so it runs for every dispatch, and write with `_bd_emit_chunked "$1" >| "$_ECX_PROMPT_FILE"`. The `>|` (house convention, as in `ultra-oracle.sh` and `dispatch.sh`) matters because the file already exists from `mktemp`: under a caller's `set -C`, a plain `>` would refuse it. That would newly break the direct arm, which never wrote a file before. The existing failure branch (`rm -f`, "failed to write codex prompt to temp file", `_ECX_RC=1` → `_bd_exit_as 1` before the retry loop) is kept unchanged, so a failed or partial write denies dispatch on both arms.
- *Why not `builtin printf` (the issue's suggestion):* `printf` is shadowable via an imported `BASH_FUNC_printf%%`/function, and `builtin` itself is shadowable as a function in the parent (#803's threat model); this file deliberately avoids both on dispatch paths. `_bd_emit_chunked` reuses the existing absolute, env-scrubbed writer.
- *Why not a size compare after the write:* the status of every chunk is already checked, and a `wc -c` comparison would be a second guard whose fail branch cannot be made to fire independently in a test. Not added.

**D2. Direct arm reads the staged file, not a pipe.** Replace `/usr/bin/printf '%s' "$1" | … codex exec … -` with `… codex exec … - < "$_ECX_PROMPT_FILE"`. A pipe producer can fail after the reviewer has read a prefix (the latent false PASS above, absent `pipefail`); a redirect from a file that was completely written before the loop cannot. Each retry reopens the file, so every attempt sees the full prompt. A regular file on fd 0 has no O_NONBLOCK/EAGAIN concern. Comment at 3306–3315 updated accordingly.

**D3. Cleanup unchanged.** All existing `rm -f "$_ECX_PROMPT_FILE"` sites (3 refusal branches in the loop, the failure and success exits) are already guarded by `-n "$_ECX_PROMPT_FILE"`, so they now cover the direct arm too. New behaviour: if `mktemp` fails, the direct arm also refuses (previously it needed no file). That is fail-closed and only reachable when `$TMPDIR` is unusable.

*Amended during PR #930 review (Codex P2):* "unchanged" covered only `_execute_codex`'s own removals. An interrupted litmus review (TERM/INT/HUP) never reaches them, and staging the file on the direct arm would newly leak the prompt there. So the litmus runner now owns the path, using the same pattern as `_BD_BROKER_HANDOFF`:
- **Runner (`run-review-loop.sh`).** It mktemps `_BD_CODEX_PROMPT_FILE`, refuses to dispatch if that fails (so `_execute_codex` never falls back to a file the watchdog cannot see), passes it to `_orphan_watch_start`, and unlinks it in the watchdog's EXIT trap and in `_orphan_watch_stop`.
- **`_execute_codex`.** It writes to that path only if the path is absolute, a regular file, not a symlink, and owned by the user. Otherwise it falls back to mktemp.

Verified against the extracted watchdog: TERM, INT, HUP and KILL to the parent all removed the prompt, while the pre-fix watchdog left it behind. That holds once the watchdog is armed: a SIGKILL between the runner's mktemp and `_orphan_watch_start` leaves the file, but still empty, because the prompt is written only by the dispatched review. The caller without a watchdog, blueprint-review, keeps `_execute_codex`'s own removals only, which matches the broker hand-off's existing scope. #931 reported this, and for the direct arm it is fixed by D4 below. This changes no timeouts, caps, or gate policy.

**D4. Direct arm stages on an unlinked inode, once per attempt.** *Added during PR #930 review. The parent rejected the #931 deferral: the direct-arm cancellation leak was introduced by this PR, so it must be fixed here.* The runner-owned path covers litmus only. blueprint-review also reaches `_execute_codex`, through `execute_review` (`run-design-review-loop.sh:974/1054/1136`), but runs with no watchdog, so an interrupted direct-arm review there left the full prompt in TMPDIR. `dispatch.sh` runs `codex exec` itself and never reaches `_execute_codex`. Before this PR that arm had no file at all.

- **The pre-loop staged file is companion-only again**, as it was before this PR. It sits back under its original condition, `_bd803_cc_a` set and `_resolve_trusted_cli_bin node` succeeding, which is the same test as the per-attempt arm gate. `--prompt-file` needs a path.
- **Each direct-arm attempt** runs in this order:
  1. `mktemp`.
  2. In a group redirection `{ …; } 5<"$f" 4>|"$f"`, open a read fd (5) and a write fd (4) on the file. This is the same scoped-fd form the lib already uses for the review-lib pin. It is not `exec`, and it is bash-3.2 safe because the fd numbers are fixed. The group uses scoped redirections like the review-lib pin (`resolve-cli.sh:280`), but not that pin's tail: the pin ends `|| { /bin/rm -f "$staged"; exit 1; }`, and `_execute_codex` must never `exit`. Here the group is written `{ …; } 5<"$f" 4>|"$f" || :`. Its status carries no information: the flag below is the only staging verdict, and the dispatch's `|| _ECX_EXIT_CODE=$?` stays inside the body.
  3. **Unlink the path first, and check it.** Run `/bin/rm -f "$f"`, then require `[[ ! -e "$f" && ! -L "$f" ]]`. If the name survives, write nothing and treat it as a staging failure.
  4. Write the prompt with `_bd_emit_chunked "$1" >&4` and check its status.
  5. Only on success, dispatch codex with `<&5 4>&- 5<&-`. The read fd has its own offset, still at 0, so codex reads exactly the bytes written.
  6. After the group, run a belt-and-braces `/bin/rm -f "$f"`. This covers a failed group open, where the body never ran. After a successful step 3, this `rm` could in principle remove a file that another process later created under the same name. That needs a collision on mktemp's random characters, and a sticky `/tmp` stops it from touching another user's file, so the residual is accepted.
- **Staging failure** (mktemp, the group's open, the unlink check, or the write) is tracked by a dedicated flag:
  - **The flag.** `_ECX_STAGE_FAILED`: set to 1 before each staging attempt, and cleared only after the write succeeds.
  - **On failure.** Codex is not dispatched and nothing is retried. The attempt is marked done (`_ECX_DONE=1`) **after** the group, by testing the flag there. A failed group open never runs the body, so a mark placed inside the body would let the loop retry.
  - **After the loop.** Nothing moves. The current post-loop order is: the #901 broker reap (`resolve-cli.sh:3598-3614`), then the standalone empty-output promotion (`:3620-3622`), then the `if exit_code -ne 0 … else …` chain (`:3626`). The promotion stays exactly where it is and still runs for every outcome. The only change is a new **first arm on the chain at `:3626`**: `if [[ $_ECX_STAGE_FAILED -eq 1 ]] … elif [[ $_ECX_EXIT_CODE -ne 0 ]] … else … fi`. A staging failure leaves `_ECX_EXIT_CODE` 0 with empty output, so the promotion sets it to 1, which is harmless because the chain tests the flag first. Every non-staging outcome reaches the `elif` and `else` exactly as today, so a clean exit with empty output still falls back (rc 3) and never returns a blank PASS. The reap still runs first, so a companion-to-direct switch still reaps a broker the companion started. The new arm is not a standalone `if` in front of the chain. `_execute_codex` has no `return` (#803), and `_bd_exit_as` only sets status, so a standalone `if` would fall through into the chain, whose `elif` would print `BUILTIN_FALLBACK` and exit 3. The branch removes any file and returns 1 with the "failed to write codex prompt to temp file" message. It never returns 3 or `BUILTIN_FALLBACK`, which matches the pre-loop refusal of the companion arm.
  - **One message, on purpose.** Every per-attempt staging failure (mktemp, open, unlink check, write) reports "failed to write codex prompt to temp file", because the post-loop branch is a single branch reading a single flag. The companion arm's pre-loop path is unchanged and still says "failed to create temp file for codex prompt" when its mktemp fails. Either message means the same thing to an operator: TMPDIR is unusable. The stderr assertions in cases 10–12 match the write message.
- **No stale output:** both `_ECX_OUTPUT` and `_ECX_EXIT_CODE` reset on **every** attempt that runs. The current code resets only the exit code. Without this, an attempt that dispatches nothing could be judged on the previous attempt's output. Placement: `_ECX_OUTPUT=""` goes next to the existing `_ECX_EXIT_CODE=0`, inside `if [[ $_ECX_DONE -eq 0 ]]` (`resolve-cli.sh:3419`), which is **after** the budget gate. It must not move to the loop top. When the budget gate ends the loop, the previous attempt's status and output must survive (the ordering rule is the comment at `:3381-3382`), because the post-loop "codex output (exit N)" diagnostic prints them (`:3631-3635`).
- **What that guarantees:** the prompt never exists under a path name. The only named window is an *empty* mktemp file, between `mktemp` and the group's open. Neither caller (litmus, blueprint-review) leaks prompt content on any signal, KILL included.
- **Retries:** each attempt restages from `$1`, which is still in memory, so every attempt gets the whole prompt.
- **Litmus runner-owned file:** it is still used by the companion arm. On the direct arm it goes unused and the runner removes it. The runner's refusal when it cannot create the file is kept: a failed `mktemp` means TMPDIR is unusable, and the direct arm's own `mktemp` would fail as well.
- **Why not a trap:** `_execute_codex` runs in the caller's shell, where a trap would clobber the caller's traps. Under litmus and blueprint-review it runs inside background subshells that are simply killed.
- **Arm switches mid-review** (node installed or removed between attempts). The per-attempt node check stays, and two guards are added so that a switch either way stays fail-closed and leaves no named prompt. `_ECX_PROMPT_FILE` is reset to `""` before the pre-loop block and is assigned only when this call fully stages the companion file; a failed write exits before the loop. So a non-empty value means the file was staged in this call. A runner-owned file that was never written does not count.
  - **Direct → companion:** the companion branch refuses when `_ECX_PROMPT_FILE` is empty. This check comes first in the branch, ahead of the node re-check at `resolve-cli.sh:3432-3433`, so its stderr line can't be confused with the three existing refusals (`:3434/3450/3460`). It prints `busdriver: no staged codex prompt file for companion dispatch (arm switched mid-review) — refusing companion dispatch.` and then sets `_ECX_STAGE_FAILED=1; _ECX_DONE=1`. Unlike those three refusals, it does **not** take the fallback route (`_ECX_EXIT_CODE=1` → `BUILTIN_FALLBACK`, rc 3, `:3643-3646`). A missing staged prompt is a staging failure, so it goes through the flag-first arm and returns 1, the same as every other staging failure. No reviewer is started on a missing prompt. It never passes `--prompt-file ""`, which the companion would treat as absent before reading inherited stdin.
  - **Companion → direct:** each direct attempt begins by removing any named companion file and checking `[[ ! -e … && ! -L … ]]` the same way as step 3. `_ECX_PROMPT_FILE` is cleared only after that check passes. If the name survives, `_ECX_PROMPT_FILE` stays set, so the post-loop `rm` tries again, and `_ECX_STAGE_FAILED=1` is set: a staging failure, so the companion file never coexists with a direct review. If node comes back later, the companion branch refuses by the first guard.
- **Flag hygiene:** `_ECX_STAGE_FAILED=0` and `_ECX_STAGE_FILE=""` are set at function entry, next to `_ECX_RC=0`. The `_ECX_*` variables are globals in the caller's shell, and blueprint-review calls repeatedly, so a stale value from an earlier call must not leak. The `_ECX_STAGE_FAILED` reset is load-bearing: a companion-arm call never stages per attempt, so a stale 1 left by an earlier direct-arm failure would make the flag-first arm throw away a real PASS (case 15). The `_ECX_STAGE_FILE` reset is defensive only. Nothing reads it except direct staging, which assigns it fresh on every attempt, so no test claims to prove it. `_ECX_STAGE_FILE` holds the per-attempt path, and like the rest it is a global (no `local`).
- **Stale comments updated with the code** (located by text; the line numbers are from `7c2c016`):
  - the transport block beginning "Pre-buffer the prompt to a file for BOTH arms" (`resolve-cli.sh:3310-3325`);
  - the `_BD_CODEX_PROMPT_FILE` ownership comment (`:2827-2830`).

  Both are rewritten to describe a named file on the companion arm only, and an unlinked per-attempt inode on the direct arm.
- **mktemp:** the per-attempt call uses the pre-loop spelling, `/usr/bin/mktemp -t codex-prompt` with a fallback to plain `/usr/bin/mktemp`, called directly in `_execute_codex`'s shell. A failure is caught with the same `[[ -z $f || ! -f $f ]]` check the pre-loop path uses, before entering the group, which avoids a stray bash open error ahead of the canonical message.
- **Budget:** per-attempt staging is timed (`_ECX_STAGE_DT`) and charged to the attempt before dispatch, exactly as the broker snapshot is. A charge of 2 s or more really ate into the window, so only `_ECX_REMAINING` shrinks (floored at 1 s), and a timeout of that truncated attempt is classified as budget exhaustion. A 1 s charge is `date`'s whole-second resolution, so `_ECX_DURATION` and `_ECX_REMAINING` shrink together and `_ECX_START` moves forward by the same second (both floored at 1 s): the full-window timeout test still holds and a later retry does not count that second twice. Staging therefore never extends the budget; measured staging cost (iteration-2 arbiter) is ~0.14 s for 200 KB and ~1.4 s for 2 MB. Companion staging still runs once before the loop, ahead of `_ECX_START`, as it did before this PR. Case 17 pins the direct-arm charge.
- **Not changed:** the companion arm under non-litmus callers. It needs a named file and behaves exactly as before this PR, so it is a pre-existing residual, not one this PR introduced.

## Tests — `tests/test-codex-prompt-transport.sh` (a rewrite of the existing suite; picked up by the full-glob shard)

The file is already on HEAD and encodes the pre-D4 direct arm. Its header says the direct arm reads fd 0 from a named file, and `delivered()` hardcodes one private-TMPDIR entry during every review. The rewrite updates the header and parameterizes `delivered()` (see below). The direct arm's in-flight expectation becomes 0.

**Harness.** Each case runs `_execute_codex` in an `env -i` child, with a stub reviewer that records each call and captures the bytes it received.
- **Pinning the arm.** Only `_bd803_bash_staged_lib --print-trusted-companion` is shimmed (`_bd803_bash_pt_lib` delegates to it, so one shim covers both the pre-loop and the `--review` re-checks).
  - Direct arm: return non-zero, the same shim as `test-codex-retry-budget.sh`.
  - Companion arm: print a stub `.mjs` that copies `--prompt-file`, with `_bd_codex_broker` stubbed to `absent`. The companion cases SKIP when no trusted node resolves.
- **Getting the prompt in byte-exactly.** A 200 KB prompt cannot travel in the `bash -c` text (that hits the same E2BIG), and `$(cat f)` strips trailing newlines. So:
  - The test shell writes each prompt to `$W/prompt` with `builtin printf '%s'`. That same file is the expected-digest oracle, so the code under test is never used to compute the expectation.
  - Only the file's PATH crosses into the child. The child reads it back with `p=$(cat "$PF"; printf x); p=${p%x}` (the sentinel keeps trailing newlines), then calls `_execute_codex "$p" "$DUR"`.
- **Locale.** `LC_ALL` is passed explicitly through `env -i`: `C.UTF-8` for case 3 and `C` elsewhere. Byte-exactness is required in both, and case 3 is the one that makes `${s:i:n}` slice by character.

For BOTH arms:
1. **Above 128 KiB:** 200,000 B ASCII → rc 0, exactly one reviewer call, captured sha256 == expected. Also the regression proof: the direct case fails on `6b4368a`, where it captures 0 bytes and returns PASS.
2. **Below 128 KiB:** 1,000 B → identical bytes (no small-prompt regression).
3. **Multibyte across the chunk boundary:** 29,999 ASCII + `é漢😀` repeated past 150 KB, under `LC_ALL=C.UTF-8` → identical bytes.
4. **Format-hostile content:** a leading `-n`/`--`, `%s %d %%`, `\n \\ \x41` literals, and a trailing `\n\n` → identical bytes, so the trailing newlines are preserved.
5. **Write failure fails closed.** In the child, in this order:
   - Pre-stage the review lib (`_bd803_ensure_staged_lib`, whose `bd803-lib.*` copy lives in the outer TMPDIR).
   - Point `TMPDIR` at a fresh, empty, private directory that only the prompt `mktemp` uses.
   - Run `ulimit -f 64` (bash counts 1024-byte blocks, so 65,536 B).
   - Call `_execute_codex` with a 200,000 B prompt. The third 30,000-character chunk crosses the limit, and SIGXFSZ kills its writer mid-file, so this is a REAL partial write.

   Assert:
   - rc ≠ 0.
   - Zero reviewer calls.
   - No `PASS` and no `BUILTIN_FALLBACK` on stdout.
   - stderr names "failed to write codex prompt".
   - The private TMPDIR is EMPTY. This check does not depend on the file name, which matters because GNU `mktemp -t codex-prompt` is rejected ("too few X's") and the fallback names the file `tmp.*`.

   Positive controls prove the empty-dir assertion can see a file. On the companion arm, the same setup without the `ulimit` must stage exactly one named prompt file that the reviewer sees (count 1), then remove it. The direct arm never names its prompt under D4, so its control is the negative control at `3b888ef`: there the same direct-arm run shows a count of 1 during the review.
6. **Retry re-reads the whole file (direct arm):** the stub's first call exits 0 with empty output, which counts as a flake, so it is retried with `LITMUS_CODEX_RETRY_DELAY=0`. The second call returns PASS. Assert two calls, and that BOTH captures equal the expected 200,000 B digest.
7. **`set -C`:** the caller's noclobber setting does not refuse the staged file, on both arms.
8. **Runner-owned file:**
   - Companion arm: the supplied `_BD_CODEX_PROMPT_FILE` is the staged file, and it is removed afterwards.
   - Direct arm (D4): it stays unused and empty. The test records the owned file's inode before the run. During the review and afterwards, the private TMPDIR holds exactly one entry, the owned file, with that same inode and 0 bytes. The reviewer's capture still equals the expected digest, so the prompt reached the reviewer through some other route than that file.

**Assertion layered on cases 1–8, not a separate case (D4): no named prompt during a direct review.** The stub reviewer counts the private TMPDIR's entries while it runs. On the direct arm the count is 0 in cases 1–4, 6 and 7, and 1 in case 8, where the one entry is the empty owned file. The companion arm counts 1, its staged file, which is expected. *Negative control:* at `3b888ef` the direct arm counts 1 in case 1.

Direct arm only (cases 9–12; numbered on from case 8, since the earlier case 9 became the layered assertion above):

9. **Cancellation (D4, #931):** this case covers a non-litmus caller. The companion arm is excluded on purpose: under non-litmus callers it keeps its named file, a pre-existing residual (see Residuals).
    - Setup: `_execute_codex` runs in a `setsid` child with no watchdog, and the stub reviewer sleeps.
    - Action: wait until the stub has appended its line to `$W/calls`, polling with a bounded wait so a stub that never starts fails the case instead of hanging. That line is written after staging has finished, so it is the barrier. Then send `kill -TERM -- -$pgid`. Without the barrier, a TERM that lands between mktemp and the unlink leaves the empty mktemp file behind, and the empty-TMPDIR assertion would fail now and then.
    - Assert: the private TMPDIR is empty.
    - *Negative control:* `3b888ef` leaves the prompt file behind.
10. **Staging fails on a retry (D4, direct arm):** the stub's first call exits 0 with empty output, which counts as a flake, and runs `chmod 000` on the private TMPDIR, so the second attempt's `mktemp` fails.
    - Assert: rc 1, exactly one reviewer call, no `PASS` or `BUILTIN_FALLBACK` on stdout, and stderr names "failed to write codex prompt".
    - Restore the permissions afterwards. SKIP under uid 0, where `chmod 000` does not stop `mktemp`, the same guard as case 11.
    - This exercises the staging-failure flag as the first post-loop arm, and "no retry after a staging failure".
    - It does **not** detect whether the per-attempt `_ECX_OUTPUT` reset is present: the flag check fires before any output is judged. That reset only affects diagnostics, and it is covered by code inspection only. The open and unlink refusals have their own cases, 11 and 12.

**Injecting the open and unlink failures (cases 11–12).** `_execute_codex` calls `/usr/bin/mktemp` and `/bin/rm` by absolute path, so a PATH shim cannot intercept them. Bash outside POSIX mode accepts function names that contain slashes, and `resolve-cli.sh` does no `unset -f` sweep. So the child defines `/usr/bin/mktemp() { … }` or `/bin/rm() { … }` after sourcing, the same way it already shims `_bd803_bash_staged_lib` and `_bd_codex_broker` (`tests/test-codex-prompt-transport.sh:70-81`). There is no PATH shim. Each shim appends to a call log in `$W`, and passes anything it does not handle on to the real binary with `command /usr/bin/mktemp "$@"` or `command /bin/rm "$@"` (`command` skips function lookup). The iteration-3 arbiter checked the mechanism in this environment: with `/usr/bin/mktemp(){ printf %s <unreadable path>; }`, the group `{ …; } 5<"$f"` fails with rc 1 and its body never runs.

11. **Group open fails (D4, direct arm).**
    - Setup: the test pre-creates a mode-000 file in the private TMPDIR. The `/usr/bin/mktemp` shim prints that path and logs the call, so the mktemp check passes and the group's `5<"$f"` open fails. SKIP under uid 0, where mode 000 does not refuse the open. CI runs as non-root.
    - Assert:
      - rc 1 and zero reviewer calls;
      - exactly one mktemp shim call, which proves "no retry": a done mark placed inside the body would never run, and the loop would stage again;
      - no `PASS` or `BUILTIN_FALLBACK` on stdout, and stderr names "failed to write codex prompt";
      - the private TMPDIR is empty afterwards, removed by the belt-and-braces `rm` after the group.
    - *Negative control (run once during implementation, recorded in the PR):* moving the done mark into the group body makes the mktemp shim count exceed 1.
12. **Unlink check fails (D4, direct arm).**
    - Setup: a `/bin/rm` shim. Its first call whose target is inside the private TMPDIR is a no-op that leaves a sentinel, so the staged name survives step 3. Every later call records the target's size (`stat -c %s`) in the log, then delegates to the real `rm`.
    - Assert:
      - rc 1 and zero reviewer calls;
      - the sentinel exists, so the shim actually intercepted the unlink;
      - the size recorded by the belt-and-braces `rm` is 0, so the writer never ran;
      - no `PASS` or `BUILTIN_FALLBACK` on stdout, and stderr names "failed to write codex prompt";
      - the private TMPDIR is empty afterwards.
    - *Negative control (run once during implementation, recorded in the PR):* with the `[[ ! -e "$f" && ! -L "$f" ]]` check deleted, the writer runs and codex is dispatched, so there is one reviewer call and the recorded size is 200,000.

Without the shims, either case fails rather than passing vacuously: the real mktemp and rm let staging succeed, and the reviewer is called once.

Arm switches, repeat calls and the empty-output guard (cases 13–16). Every case above pins one arm per `env -i` child and makes one call per child, so none of them reaches the arm-switch guards, the entry-time flag reset, or the unchanged empty-output promotion.

**How the arm is switched (cases 13–15).** Flipping the `--print-trusted-companion` shim does nothing here. The per-attempt arm gate is `[[ -n ${_bd803_cc_a:-} ]] && _resolve_trusted_cli_bin node` (`resolve-cli.sh:3425`). `_bd803_cc_a` is computed once before the loop (`:3287-3296`) and re-probed only inside the companion branch (`:3443-3447`).
- So these cases use the companion pin throughout, which keeps `_bd803_cc_a` set, and toggle **node availability** instead.
- After sourcing, the child copies `_resolve_trusted_cli_bin` to `_orig_rtcb` (via `declare -f`) and redefines it. The new version returns 1 for `node` while a marker file `$W/no-node` exists, and delegates every other call to `_orig_rtcb`.
- The marker is read on every call, so it covers both the pre-loop staging decision and the per-attempt gate. A stub that creates or removes the marker on its first (flake) call therefore switches the arm for attempt 2.
- All three cases SKIP without a trusted node, the same gate as the suite's `ARMS` list (`tests/test-codex-prompt-transport.sh:86-91`).

13. **Direct → companion between attempts.** `$W/no-node` exists at the start. No companion file is staged before the loop, and attempt 1 takes the direct arm. The direct stub's first call is the usual flake (exit 0, empty output) and removes the marker. Attempt 2 then enters the companion branch with `_ECX_PROMPT_FILE` empty.
    - Assert: rc 1, exactly one reviewer call, and no companion call.
    - Assert: stderr carries the "arm switched mid-review" line, and not the "unresolved after dual re-check" line.
    - Assert: stderr names "failed to write codex prompt", and stdout carries no `PASS` and no `BUILTIN_FALLBACK`.
    - Assert: the private TMPDIR is empty.
    - *Negative control (run once during implementation, recorded in the PR):* with the guard deleted, the companion is invoked with `--prompt-file ""`.
14. **Companion → direct between attempts.** There is no marker at the start, so the companion file is staged before the loop and attempt 1 takes the companion arm. The companion stub's first call is the flake and creates the marker. Attempt 2 takes the direct arm.
    - Assert: rc 0 with the direct stub's PASS. The direct stub's in-flight count is 0, so the companion file was already gone, and its capture equals the expected digest.
    - Assert: the private TMPDIR is empty afterwards.
    - *Negative control (run once during implementation, recorded in the PR):* with the guard deleted, the direct stub's in-flight count is 1.
15. **A second, companion-arm call in the same shell after a direct staging failure.** One child does the following:
    - It creates `$W/no-node` and runs `chmod 000` on the private TMPDIR. The first call then takes the direct arm, and its first attempt's `mktemp` fails. Assert rc 1 and zero reviewer calls.
    - It restores the permissions, removes the marker, and makes a second `_execute_codex` call with a fresh prompt, which takes the companion arm.
    - Assert: the second call returns rc 0 with the companion stub's PASS. Exactly one companion read happens, its capture equals the expected digest, and stderr does not name "failed to write codex prompt".
    - This proves the entry-time `_ECX_STAGE_FAILED` reset: the companion arm never stages per attempt, so without the reset the stale 1 from the first call would reach the flag-first arm.
    - *Negative control (run once during implementation, recorded in the PR):* with the reset deleted, the second call returns 1 with "failed to write codex prompt" even though the companion returned PASS.
    - SKIP under uid 0, like case 10.
16. **Empty output still falls back (regression for the post-loop placement).** On the direct arm, every attempt returns exit 0 with empty output, with `LITMUS_CODEX_RETRIES=1` and `LITMUS_CODEX_RETRY_DELAY=0`.
    - Assert: rc 3 and `BUILTIN_FALLBACK` on stdout, never rc 0. This pins that the empty-output promotion still runs for every non-staging outcome.
17. **Staging is charged to the budget (direct arm).** `_bd_emit_chunked` is wrapped to sleep 2 s before writing, and `_portable_timeout` is wrapped to log the allowance it receives, with a 60 s budget.
    - Assert: rc 0 and a logged allowance of at most 58 s, never the full 60 s.

The harness helper `delivered()` takes the expected in-flight count and post-run residue as parameters: direct 0 and empty; companion 1 and empty; case 8 on the direct arm, 1 and only the empty owned file. Cases 9–14 assert an empty residue directly.

**Runner-owned prompt cleanup (D3 amendment): permanent tests in the existing suites.** Until now, only the one-off signal experiment proved this cleanup.
- `tests/test-litmus-mode-transition.sh`, in the existing SIGKILL residue check (~line 2613):
  - The check already counts `litmus-review-out-*` with `_outfiles`. A **separate** counter, `_promptfiles`, counts `litmus-review-prompt-*` with its own glob. Appending a second pattern to `_outfiles`'s `set --` would be blind: whenever no output file exists, `$1` is the literal pattern and it echoes 0 regardless.
  - The runner mktemps the prompt file unconditionally (`run-review-loop.sh:3788`), so the file really exists on this kill path.
  - Like `_outfiles`, the new counter is snapshotted before `RUN` and asserted `post -le pre`, with the same 25 × 0.2 s retry loop. It does not assert an absolute 0, because the temp dir is shared (the comment at `:2612`).
- `tests/test-codex-broker-teardown.sh`: its `_orphan_watch_start` calls (~455/458) gain a populated fourth argument (a non-empty prompt file).
  - It asserts the file is removed when the watched parent is signalled. That proves only the watchdog's EXIT trap: the existing fixture extracts `_orphan_watch_start` alone (`:441`), and its parent ends with `kill -9 $$` (`:496`), so `_orphan_watch_stop` never runs there.
  - A **separate block** covers the stop path. It extracts both functions with two portable ranges, `sed -n -e '/^_orphan_watch_start()/,/^}/p' -e '/^_orphan_watch_stop()/,/^}/p'`; `\|` alternation is GNU-only. As the existing fixture does, it first checks that the extract defines `_orphan_watch_stop` (`grep -q … || return 9`). It then sets `_BD_CODEX_PROMPT_FILE` to a non-empty temp file, and calls `_orphan_watch_stop`. It asserts the file is gone and the variable is empty.
- *Negative control:* with the D3 lines reverted (the prior `2d6f77b` runner), these new assertions fail.

Plus the existing regressions that touch `_execute_codex`: `test-codex-retry-budget.sh`, `test-codex-broker-teardown.sh`, `test-trusted-review-cli.sh`, `test-litmus-mode-transition.sh`, `test-blueprint-nonzero-salvage.sh`, `test-agy-stream-transport.sh`; plus ShellCheck on the new test.

## Residuals (named, not fixed here)

- Fail-closed detection relies on `/usr/bin/printf` exiting non-zero on a write error. Verified on GNU coreutils by case 5. BSD/macOS printf is not verified here (CI is Linux).
- Other `/usr/bin/printf '%s' "$_ECX_OUTPUT"` sites carry the reviewer's OUTPUT, not the prompt, and are out of this transport-only scope.
- #928 part 2 (`infra_failure` retirement) remains open.
- *(As originally written:)* a runner killed by SIGKILL mid-review leaves its 0600 prompt file in `$TMPDIR`. *(Amended, see D3:)* for the litmus runner this is now covered. The watchdog outlives a killed runner and unlinks the runner-owned prompt on TERM, INT, HUP and KILL alike. *(Amended again, see D4:)* the direct arm no longer has a named prompt file under any caller. What remains is pre-existing: the companion arm under blueprint-review (its only non-litmus caller; `dispatch.sh` never reaches `_execute_codex`), or under a litmus watchdog that is itself killed, leaves a private 0600 file in the operator's own TMPDIR, exactly as it did before this PR.
- Not changed, deliberately: the `mktemp -t codex-prompt` spelling. GNU rejects it, so the plain-`mktemp` fallback names the file, which is harmless and unchanged behaviour.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
