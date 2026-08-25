# Issue #745: careful-guard recursive-rm argv at command-word indexes

<!-- design-reviewed: PASS -->

## Problem

`unsafe()` gates each segment with `_command_word_in(RM_SET)` (#585 / #741) but the token loop after the gate still treats every later `rm`-spelling token as a candidate command word. Operand spellings such as `rm -- build rm -rf` and `rm build rm -rf` over-warn.

## Root cause

`_command_word_in(chunks, names) -> bool` proves an `rm` command word exists somewhere in the segment; it does not report **which token indexes** hold command position. The rm scanner reuses the boolean and then scans all tokens.

## Approach (minimal)

1. **Keep** the landed `_iter_command_word_hits` generator; fix the top-level `find -exec {}` branch to `yield (toks, None)` when `_find_selects` matches (generator contract). `_command_word_in` stays `for _ in _iter_command_word_hits(...): return True` / `return False`.
2. **Rewrite `unsafe()`** — delete the per-segment `gate_ok` / second `shlex.split` / all-token loop. Control flow: `for chunk in chunks` → `for toks, j in _iter_command_word_hits([chunk], RM_SET)` → if `j is None`: all-token fallback on `list(toks)`; else reuse the existing argv builder at `j` (`_expansion_fields` + `zip(stripped_rest, raw_rest)` → `recursive_targets`, same as current lines ~1854–1878).
3. **Fixtures** in `tests/test-careful-guard-truncate-context.sh`: add the seven issue #745 rows; **rewrite** line 1227 `>& rm grep -rf /etc` from ask→allow and update its PINNED comment; update `test-careful-guard-truncation.sh:140-143` comment for the `echo then rm` pin flip.

## Non-goals

- No `--`-only operand skipping (symptom patch).
- No changes to `has_truncate`, `has_sql_client`, or `_rebinds` beyond sharing the generator.
- No change to `recursive_targets()` or `is_safe()` semantics.

## Regression matrix (from issue #745)

| Command | Expected |
|---------|----------|
| `rm -- build rm -rf` | allow |
| `rm build rm -rf` | allow |
| `rm -rf /etc` | ask |
| `sudo rm -rf /etc` | ask |
| `>& out.log rm -rf /etc` | ask |
| `find . -exec rm -rf {} \;` | ask |
| `echo /etc \| xargs rm -rf` | ask |

## Pin flips (same change)

| Command | Before | After |
|---------|--------|-------|
| `echo then rm -rf /etc` | ask | allow |
| `>& rm grep -rf /etc` | ask | allow |

## Files

- `hooks/gate-scripts/careful-guard.sh` — generator + `unsafe()` loop
- `tests/test-careful-guard-truncate-context.sh` — regression fixtures (#745)

## Verification

- `bash tests/test-careful-guard-truncate-context.sh`
- `bash tests/test-careful-guard-truncation.sh` and `bash tests/test-careful-guard-differential.sh` (no unintended divergence)
- `bash scripts/ci/run-shell-tests.sh` (full shell suite)
- Litmus: staged commit via normal pre-commit gate

<!-- design-review-coverage: FULL 3/3  -->
