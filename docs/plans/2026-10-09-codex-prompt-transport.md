# Codex prompt transport above 128 KiB (#928, transport only)

> **For agentic workers:** small change: one function in `scripts/lib/resolve-cli.sh`, one new shell test. Execute inline; no subagent fan-out.

**Goal:** A Codex review prompt of any size reaches the reviewer byte-for-byte on BOTH `_execute_codex` arms (codex-companion `--prompt-file`, and the direct `codex exec -` fallback). If the prompt cannot be written completely, the review fails closed BEFORE any reviewer starts: no prefix is ever reviewed, no PASS is produced, and the private prompt file is removed.

**Scope:** transport only. Refs #928; does NOT close it. The second half of #928 (cross-mode `infra_failure` retirement / commit-block `--force` rule) is out of scope and stays open on the issue. No change to retries, budgets, SAST, enrichment, prompt bounds, provider policy, or `_bd_emit_chunked` itself.

---

## Evidence (measured 2026-10-09 on `6b4368a`, Linux)

- **Companion arm** (`resolve-cli.sh:3322`): `/usr/bin/printf '%s' "$1" > "$_ECX_PROMPT_FILE"` hands the whole prompt to one `execve` argument. Linux caps one argument at `MAX_ARG_STRLEN` = 131072 B regardless of `ARG_MAX` → `Argument list too long` → "failed to write codex prompt to temp file" → `infra_failure` (observed on #885's 120 KB staged diff once SAST/context were added, and on PR #926).
- **Direct arm** (`resolve-cli.sh:3516`): `/usr/bin/printf '%s' "$1" | … codex exec -s read-only -`. Same E2BIG, but here it is **worse than an infra failure**: the producer dies, the pipeline's status is codex's, and codex reviews an EMPTY stdin. Reproduced with a stub codex and a 200,000-byte prompt: stderr `line 3516: /usr/bin/printf: Argument list too long`, stub received **0 bytes**, `_execute_codex` returned **rc 0 with the stub's PASS**. A false PASS on the gate of record.
- `_bd_emit_chunked` (`resolve-cli.sh:1301`) already writes a string byte-exactly in ≤30000-character pieces through `_bd_run_clean /usr/bin/printf`, stopping and returning 1 at the first failed piece. It backs the agy arms and is covered by `tests/test-agy-stream-transport.sh` (u16: write failure ⇒ non-zero even with `return` shadowed).

## Decisions

**D1. One staged file for both arms.** Move the `mktemp` + write block out from under the `companion && node` condition so it runs for every dispatch, and write with `_bd_emit_chunked "$1" >| "$_ECX_PROMPT_FILE"`. The `>|` (house convention, as in `ultra-oracle.sh` and `dispatch.sh`) matters because the file already exists from `mktemp`: under a caller's `set -C`, a plain `>` would refuse it. That would newly break the direct arm, which never wrote a file before. The existing failure branch (`rm -f`, "failed to write codex prompt to temp file", `_ECX_RC=1` → `_bd_exit_as 1` before the retry loop) is kept unchanged, so a failed or partial write denies dispatch on both arms.
- *Why not `builtin printf` (the issue's suggestion):* `printf` is shadowable via an imported `BASH_FUNC_printf%%`/function, and `builtin` itself is shadowable as a function in the parent (#803's threat model); this file deliberately avoids both on dispatch paths. `_bd_emit_chunked` reuses the existing absolute, env-scrubbed writer.
- *Why not a size compare after the write:* the status of every chunk is already checked, and a `wc -c` comparison would be a second guard whose fail branch cannot be made to fire independently in a test. Not added.

**D2. Direct arm reads the staged file, not a pipe.** Replace `/usr/bin/printf '%s' "$1" | … codex exec … -` with `… codex exec … - < "$_ECX_PROMPT_FILE"`. A pipe producer can fail after the reviewer has read a prefix (the false PASS above); a redirect from a file that was completely written before the loop cannot. Each retry reopens the file, so every attempt sees the full prompt. A regular file on fd 0 has no O_NONBLOCK/EAGAIN concern. Comment at 3306–3315 updated accordingly.

**D3. Cleanup unchanged.** All existing `rm -f "$_ECX_PROMPT_FILE"` sites (3 refusal branches in the loop, the failure and success exits) are already guarded by `-n "$_ECX_PROMPT_FILE"`, so they now cover the direct arm too. New behaviour: if `mktemp` fails, the direct arm also refuses (previously it needed no file). That is fail-closed and only reachable when `$TMPDIR` is unusable.

## Tests — `tests/test-codex-prompt-transport.sh` (new; picked up by the full-glob shard)

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

   A positive control in the same setup without the `ulimit` must create and then remove exactly the one prompt file, and reach the reviewer. That proves the empty-dir assertion can see a file.
6. **Retry re-reads the whole file (direct arm):** the stub's first call exits 0 with empty output, which counts as a flake, so it is retried with `LITMUS_CODEX_RETRY_DELAY=0`. The second call returns PASS. Assert two calls, and that BOTH captures equal the expected 200,000 B digest.

Plus the existing regressions that touch `_execute_codex`: `test-codex-retry-budget.sh`, `test-codex-broker-teardown.sh`, `test-trusted-review-cli.sh`, `test-litmus-mode-transition.sh`, `test-blueprint-nonzero-salvage.sh`, `test-agy-stream-transport.sh`; plus ShellCheck on the new test.

## Residuals (named, not fixed here)

- Fail-closed detection relies on `/usr/bin/printf` exiting non-zero on a write error. Verified on GNU coreutils by case 5. BSD/macOS printf is not verified here (CI is Linux).
- Other `/usr/bin/printf '%s' "$_ECX_OUTPUT"` sites carry the reviewer's OUTPUT, not the prompt, and are out of this transport-only scope.
- #928 part 2 (`infra_failure` retirement) remains open.
- A runner killed by SIGKILL mid-review leaves its 0600 prompt file in `$TMPDIR`. That was already true for the companion arm and is now also true for the direct arm. It is a private file in the operator's own TMPDIR, there is no trap to add on a `kill -9`, and nothing changes in the threat model.
- Not changed, deliberately: the `mktemp -t codex-prompt` spelling. GNU rejects it, so the plain-`mktemp` fallback names the file, which is harmless and unchanged behaviour.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
