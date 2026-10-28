# Gate classifiers: an outer quote's `$` is the inner program's text (#1051)

> **For agentic workers:** small change. One condition in `_requote_ansi_c`, kept in step in `hooks/gate-scripts/lib/marker_check.py` and `hooks/gate-scripts/lib/cmdword.py`, plus docstrings, rows in `tests/test-escaped-dollar-1048.sh`, and a regenerated `.gate-integrity.lock`. Execute inline; no subagent fan-out.

**Goal:** #1048's shape and #1043's shape no longer fail open when they sit inside a program handed to another shell (`bash -c '…'`, `sh -c '…'`, `dash -c '…'`, `bash <<< '…'`, nested `-c`). This holds in both gates: the helper guard (`marker_check.py`) and the design gate (`cmdword.is_file_mod`). The invariant is that a quoted program is classified as its own text would be at top level.

**Scope:** `_requote_ansi_c` in both modules, the docstrings and comments that describe it, and the test rows. Out of scope:
- the first reading (the blind `$'`/`$"` → quote strip);
- `_ansi_c_differs`, `_exec_payloads` and the recursion;
- any budget or timeout;
- every other quote walker.

Closes #1051.

---

## Evidence (measured on `54d6d0f7`, classifiers called directly as the tests do; every "runs" was executed under bash 5.2.21 in a scratch tree)

`H` is the helper path; `src/` is a scratch directory. "TOP" is the program alone, and the other columns wrap it with `shlex.quote`.

| Program | runs under bash -c | main TOP | main `bash -c` / `sh -c` / `dash -c` / `bash <<<` | candidate, all four |
|---|---|---|---|---|
| `echo "\$"; python3 H; echo "\$"` | yes | BLOCK | OK / OK / OK / BLOCK | BLOCK |
| `echo $'it\'s'; python3 H; echo '\$'` | yes (bash only) | BLOCK | OK / OK / OK / BLOCK | BLOCK |
| `echo "\$"; rm -rf src; echo "\$"` (cmdword) | yes | True | False / False / False / False | True |
| `echo $'it\'s'; rm -rf src; echo '\$'` (cmdword) | yes (bash only) | True | False ×4 | True |

Rows 2 and 4 are new: they are #1043's shape nested, a fail-open on main that the issue did not name.

**Why.** The second reading (#1043, widened by #1048) respells `$'…'` and `$"` OUTSIDE quotes. Inside a quoted span it drops the `$` before a quote, exactly as the first reading's blind strip does. To the outer shell that `$` is a literal byte of the quoted text. When the text is a program for another shell, it is that program's syntax:
- `"\$"` loses its `$` and becomes `"\"`, which runs the string on past the payload (#1048);
- `$'it\'s'` loses the opener that makes its `\'` data (#1043).

`_exec_payloads` re-enters the program at `_depth + 1`, but by then the bytes are already gone.

## Decisions

**D1. Inside quotes, the second reading keeps the `$`.** In both `_requote_ansi_c` copies:

```
if ch == "$" and s[i + 1:i + 2] in (_SQ, _DQ) and not q:
    j = (_ansi_c_span(s, i) if s[i + 1] == _SQ and not _dollar_run_is_even(s, i + 1) else None)
```

Outside quotes nothing changes. Escaped `\$` never reaches this branch, because the backslash branch consumes it with its escaper.

Inside quotes the `$` is now copied through. That is bash's own reading:
- inside `'…'` every byte is literal;
- inside `"…"` a `$` before the closing `"` is literal.

So for the outer layer the output is closer to bash than before. A program extracted from that span reaches the depth-1 scan with its bytes intact. There `_norm_for_scan` applies whichever reading is active to the program's own top level.

The first reading is untouched, so main's verdicts all survive. It stays the over-read of heredoc bodies that the `_ansi_c_reading` comment records. The two readings remain a union, so D1 can only change a verdict where the second reading now finds something.

**D2. The verdicts that move from allow to block are all inherited from top level, and they are pinned.** Measured over the corpus and fuzz below, every command whose verdict moves from main's OK (or False) to block is one whose program alone already blocks at top level on main. On main these were OK when nested only because the same `$` loss that hid the payloads also mangled these programs into something that parsed clean.

Two named shapes:
- `printf '%s\n' $'\''echo H'` (and its `rm` twin), nested under any `-c`. `bash -n` rejects the program ("unexpected EOF while looking for matching `''"), so bash runs nothing, and TOP blocks it on main for that reason. Under dash it parses, because dash 0.5.12 has no `$'…'`, and only prints.
- cmdword `echo $'it\'s'; echo rm src; echo '\$'`, nested. TOP returns True on main under the FIRST reading alone (measured with `_ansi_c_differs` forced False). This is a cmdword `_command_substitutions` residual of #1043. No change to the second reading can clear it, because either reading blocking blocks.

**This revises #1051's filed acceptance** ("the three litmus over-block shapes stay OK"). The operator approved the revision on 2026-10-28. The inheritance is accepted because "stay OK nested" asks the nested reading to be more permissive than top level, which is the bug class this closes. Each inherited shape is pinned with its TOP row beside it, asserting both block, so the reason is visible in the test.

**D3. Rejected alternatives** (each measured or refuted during PR #1050):
- *Keep the `$` only when escaped (`_escaped_at`).* This drops the unescaped `$` of `$'it\'s'` but keeps the escaped one of `'\$'`. That breaks the cancellation the nested program parsed by and produces a NEW over-block: `bash -c` of `echo $'it\'s'; echo H; echo '\$'`, where TOP is OK (litmus, 1048 round 2). D1 has no such row.
- *D1 plus ANSI-C spans in cmdword `_command_substitutions`.* This would clear the cmdword TOP residual in D2, but it over-blocked `dash -c` programs and failed a pinned #1043 row (a write that sits only in a comment, which then read as a file mod). That is separate work on a separate walker; see Consequences.
- *Interpreter-aware readings (ANSI-C rules only for bash).* `sh -c` is dash on this host and bash on macOS. The gate cannot know the interpreter from the command text, so a loosened reading for `sh` would be scoped by host-controlled input. Literal `dash -c` would buy back one shape that is a bash syntax error at top level, at the cost of interpreter plumbing through `_exec_payloads` in both modules.
- *Re-extract each payload from the original text.* This needs a second outer-layer parser to map shlex tokens back to source spans. D1 achieves the same thing by not corrupting the bytes in the first place.

## Tests

In `tests/test-escaped-dollar-1048.sh`, replacing the "Residual, tracked in #1051" comment. Every block row is first executed under bash and must really run the stub helper or really delete `src/`. Every allow row must not.

- **Nested payloads must block** (marker_check):
  - #1048's shape under `bash -c`, `sh -c`, `dash -c`, `bash <<<`, and `sh -c` inside `bash -c`;
  - #1043's shape `echo $'it\'s'; python3 H; echo '\$'` under `bash -c`.
- **Nested writes are file mods** (cmdword): the same shapes with `rm -rf src`.
- **Nested reads stay OK:**
  - `bash -c` of `echo $'it\'s'; echo H; echo '\$'` (marker_check);
  - `bash -c` / `sh -c` of `echo "\$"; echo H; echo "\$"` (marker_check);
  - `bash -c` of `echo "\$"; ls src; echo "\$"` (cmdword).
- **Inherited from top level** (new section): for each D2 shape, the TOP row and the nested row, both asserted to block, both asserted not to run. The comment says that TOP already blocks on main and why.

Regression suites:
- every suite that drives `marker_check.py` or `is_file_mod` stays green against a baseline recorded on `54d6d0f7` before the change, including `test-ansic-quote-1043.sh` (27/27 on the spike);
- `tests/test-gate-integrity.sh` passes after `./scripts/gate-integrity.sh --update`.

## Verdict changes against main (spike on a copy of the lib with D1 applied)

- Corpus of 6 programs × 7 wrappers (TOP, `bash`/`sh`/`dash -c` single-quoted, `bash -c` double-quoted, `bash <<'E'`, `bash <<<`), in both gates:
  - every row bash runs now blocks;
  - every changed allow-row is inherited (D2);
  - there are no other changes.
- Differential fuzz, 1500 commands, seed 7. Wrappers are `shlex.quote`'d `bash`/`sh`/`dash`/`bash -e -c`, `eval`, `bash <<<`, `sh -c` inside `bash -c`, and `$( )`. Results:
  - 0 fail-opens;
  - 10 commands that run the helper move from OK to BLOCK;
  - 22 print-only commands move from OK to BLOCK, every one inherited.
- Re-run with a cmdword twin before review of the code.

## Consequences

- #1051 closes. The nested #1043 shape (rows 2 and 4) closes with it.
- Inherited over-blocks, all fail-closed:
  - a nested program that is a bash syntax error built on `$'\''` (dash would print it);
  - cmdword's top-level `$'it\'s'` residual, now also reached nested.
- The cmdword residual is its own issue, filed only with operator approval. It must not re-propose the `_command_substitutions` change above without answering the `dash -c` and #1043 comment-row findings.
- Not addressed: the double-quoted `bash -c "…"` spelling of the dash shape reads OK while TOP blocks. Bash cannot run that program, so this is no fail-open.
- **Revisit trigger:** a real script refused by an inherited shape, or a parity test between the top-level and nested verdicts across both gates.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
