# cmdword Substitution and Comment Reading (#1085), Part 1 of 2: Shared Shell Lexer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move marker_check's shell lexer, unchanged, into a shared `hooks/gate-scripts/lib/shell_lex.py`, so that cmdword can import it in part 2, and pin that a missing `shell_lex.py` blocks (fail-closed row B9). This is the groundwork the spec `docs/specs/2026-11-10-cmdword-subst-comment-1085-design.md` names under "shared lexer"; it changes no verdict.

**Why two parts:** the single plan for the whole spec (1,359 lines) exceeded the design reviewer's 1,800 s ceiling three times, so it is split. **Part 2** (a separate plan, written after this one merges, against the merged code) carries the rest of the spec: `<( )` / `>( )` bodies in `_subst_bodies`, spec B (extra bodies in cmdword), spec C (the third reading), spec D (the `try/except` around `is_file_mod`, row B10), the #1085 fixture and suite, and the corpus check. Nothing here depends on part 2.

**Architecture:** A script moves 16 top-level definitions out of `marker_check.py` into `shell_lex.py` (text cut and pasted, not retyped) and adds one `from shell_lex import (...)` line to `marker_check.py`, so every name it used still resolves in its own namespace. The moved code reads no global except `re` and `_SQ` (checked: an AST scan of the 16 definitions finds `_SQ` in `_ansi_c_span` and nothing else), and `shell_lex.py` defines both.

**Tech Stack:** Python 3 (stdlib only), bash, the shell test harness (`tests/test-*.sh`).

**Global Constraints:**
- No new dependencies. `shell_lex.py` imports only `re`.
- **No behaviour change.** Each moved definition must parse to the same AST as on `origin/main` (Task 1 Step 5 checks it). A marker suite that changes outcome means the move is wrong.
- **Every edit under `hooks/gate-scripts/**` needs `./scripts/gate-integrity.sh --update`** before the branch is reviewed (`.gate-integrity.lock`, #742).
- Conventional Commits; commit-message footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The litmus pre-commit gate runs on every commit.

**Deviations from the spec, decided here:**
1. The spec names the new fail-closed rows B7 and B8. Those labels are taken in `tests/test-gate-classifier-fail-closed.sh`; the new rows are **B9** (here) and **B10** (part 2).
2. B9 belongs to the spec's fail-closed section but lands here, because the import it tests is added here.
3. marker_check adds its directory with `posixpath.dirname(posixpath.abspath(__file__))`, not the spec's `os.path` spelling: marker_check imports `posixpath` and not `os` at module level, and on the POSIX hosts the gate runs on the two are the same function. The insert is unconditional, so a test that loads marker_check repeatedly (`tests/test-marker-flatten-quotes-889-oracle.sh`) gains one duplicate `sys.path` entry per load (its `sys.path.pop(0)` removes the entry marker_check inserted, leaving its own). Every duplicate is the same lib directory, so lookup is unchanged; this is accepted rather than guarded.

---

## File Structure

| File | Responsibility |
|---|---|
| `hooks/gate-scripts/lib/shell_lex.py` (new) | The shell lexer: substitution-body extraction (`_subst_bodies`), the span helpers it needs, continuation joining, escape decoding. Pure functions, compiled regexes, one cache list. No I/O. |
| `hooks/gate-scripts/lib/marker_check.py` | Loses the 16 moved definitions; imports them back under the same names. |
| `hooks/gate-scripts/lib/cmdword.py` | Comments only: `KEEP IN STEP WITH marker_check` → `shell_lex` where the partner moved. |
| `tests/test-escaped-dollar-1048.sh` | Its parity check looks a moved name up in `shell_lex.py`. |
| `tests/test-gate-classifier-fail-closed.sh` | Row B9. |
| `.gate-integrity.lock` | Regenerated. |

Other references to moved names, checked: `tests/test-marker-glob-expansion-budget-802.sh` calls `mc._join_continuations` on the loaded module (still an attribute, through the import); `tests/test-marker-1013-holes.sh` names `_subst_bodies` in a comment only. Neither changes.

---

### Task 1: Move the lexer into `shell_lex.py`

**Files:**
- Create: `hooks/gate-scripts/lib/shell_lex.py`
- Modify: `hooks/gate-scripts/lib/marker_check.py` (the 16 definitions, today in 2196–2285, 2352–2369, 2511–2976 in parts, 4648–4667; the import after line 15)
- Modify: `hooks/gate-scripts/lib/cmdword.py` (comments only)
- Modify: `tests/test-escaped-dollar-1048.sh:327-344`

**Interfaces:**
- Produces: module `shell_lex` exposing `_subst_bodies(s) -> (list[str], bool)`, `_subst_body_end(s, start, _depth=0) -> int`, `_join_continuations(s) -> str`, `_param_span(s, i, dq=False, _depth=0) -> int | None`, `_backtick_span(s, i) -> int | None`, `_heredoc_delim(s, i) -> ((delim, strip), end) | None`, `_heredoc_body_end(s, nl, delims) -> int`, `_ansi_c_span(s, i) -> int | None`, `_arith_closes(s, i) -> bool`, `_decode_escapes(text) -> str`, and data `_paren_matches`, `_ESC_RE`, `_RESERVED_AT_CMD_RE`, `_RESERVED_END_RE`, `_PARAM_PATTERN_OP_RE`, `_SPAN_MAX_DEPTH`, `_SQ`. Behaviour identical to today's marker_check definitions. Part 2 imports this module from cmdword.

- [ ] **Step 1: Move the definitions with a script (do not hand-copy)**

Run from the repo root. `marker_check.py` imports `sys` on line 13, before the anchor line, so the inserted `sys.path.insert` resolves.

```bash
python3 - <<'PY'
import ast
LIB = "hooks/gate-scripts/lib"
NAMES = ["_join_continuations", "_ansi_c_span", "_backtick_span", "_heredoc_delim",
         "_heredoc_body_end", "_RESERVED_AT_CMD_RE", "_RESERVED_END_RE", "_PARAM_PATTERN_OP_RE",
         "_SPAN_MAX_DEPTH", "_param_span", "_subst_body_end", "_paren_matches", "_arith_closes",
         "_subst_bodies", "_ESC_RE", "_decode_escapes"]
path = f"{LIB}/marker_check.py"
src = open(path).read()
lines = src.split("\n")
spans = []
for n in ast.parse(src).body:
    name = (n.name if isinstance(n, ast.FunctionDef) else
            n.targets[0].id if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) else None)
    if name in NAMES:
        start = n.lineno - 1
        while start > 0 and lines[start - 1].startswith("#"):   # the comment block that belongs to it
            start -= 1
        spans.append((start, n.end_lineno, name))
assert sorted(s[2] for s in spans) == sorted(NAMES), spans
header = '''"""Shell lexer shared by the gate classifiers (#1085).

Moved verbatim from marker_check.py, which imports every name back under the same name, so
its behaviour is unchanged. cmdword.py will import it for the substitution bodies its own
paren-counting extractor misses. One copy, because two classifiers that disagree about where a
substitution ends are a bypass in whichever one is wrong. No I/O, no side effects at import.
"""
import re

_SQ = chr(39)
'''
body = "\n\n\n".join("\n".join(lines[a:b]) for a, b, _ in spans)
open(f"{LIB}/shell_lex.py", "w").write(header + "\n\n" + body + "\n")
for a, b, _ in sorted(spans, reverse=True):
    del lines[a:b]
    # Only at the splice: drop blank lines beyond two, so no unrelated blank run changes.
    while 2 <= a < len(lines) and lines[a] == lines[a - 1] == lines[a - 2] == "":
        del lines[a]
out = "\n".join(lines)
anchor = "import fnmatch, json, posixpath, re, shlex, string\n"
assert out.count(anchor) == 1
imp = (anchor + "\n# The lexer lives in shell_lex.py, shared with cmdword (#1085). The path is added after the\n"
       "# stdlib imports above, so nothing in lib/ can shadow one of them; __file__, because the gate\n"
       "# runs this file with -I and tests load it through spec_from_file_location.\n"
       "sys.path.insert(0, posixpath.dirname(posixpath.abspath(__file__)))\n"
       "from shell_lex import (  # noqa: E402\n    " +
       ", ".join(sorted(NAMES)) + ",\n)\n")
open(path, "w").write(out.replace(anchor, imp))
print("moved", len(spans))
PY
```

Expected output: `moved 16`. Then wrap the `from shell_lex import (...)` name list at 100 columns.

- [ ] **Step 2: Read the diff**

Run: `git diff --stat; git diff hooks/gate-scripts/lib/marker_check.py | head -80`
Check by eye: each removed block is one moved definition plus its own leading comment; no unrelated comment was swept along (a comment that introduces a section rather than the definition stays in marker_check — move it back by hand if one was taken). `marker_check.py` still defines its own `_SQ` (`grep -n "^_SQ = " hooks/gate-scripts/lib/marker_check.py` prints one line; its line number moves down by the inserted import).

- [ ] **Step 3: Update the comments that name moved functions**

Run: `grep -n "KEEP IN STEP WITH" hooks/gate-scripts/lib/cmdword.py hooks/gate-scripts/lib/shell_lex.py | grep -E "_ansi_c_span|_subst_bodies|_join_continuations|_param_span|_backtick_span|_heredoc|_decode_escapes|_arith_closes|_subst_body_end"`, and look at cmdword's `_ansi_c_span` docstring (`KEEP IN STEP WITH marker_check.`). Where the named partner is a moved function, change `marker_check` to `shell_lex`. In `shell_lex.py`, a comment saying `KEEP IN STEP WITH cmdword._command_substitutions` stays as it is (still true).

- [ ] **Step 4: Point the parity test at `shell_lex.py`**

`_ansi_c_span` is one of the names `tests/test-escaped-dollar-1048.sh` compares between cmdword and marker_check, and it now lives in `shell_lex.py`. Replace

```python
trees = [ast.parse(open(sys.argv[1] + "/" + m).read()) for m in ("cmdword.py", "marker_check.py")]
```

with

```python
trees = [ast.parse(open(sys.argv[1] + "/" + m).read())
         for m in ("cmdword.py", "marker_check.py", "shell_lex.py")]
```

and replace the final comparison

```python
print(" ".join(n for n in names if node(trees[0], n) != node(trees[1], n)
               or node(trees[0], n).startswith("missing")))' "$LIB" 2>&1) && [[ -z "$out" ]]; then
```

with

```python
def theirs(name):   # marker_check, or shell_lex for what #1085 moved there
    got = node(trees[1], name)
    return node(trees[2], name) if got.startswith("missing") else got
print(" ".join(n for n in names if node(trees[0], n) != theirs(n)
               or node(trees[0], n).startswith("missing")))' "$LIB" 2>&1) && [[ -z "$out" ]]; then
```

(the shell `if out=$(python3 -I -c '…` wrapper and the `ok`/`no` lines stay unchanged; no `'` may appear in the added Python, which sits inside a single-quoted string).

- [ ] **Step 5: Prove the move changed no definition**

```bash
T="$(mktemp -d)"
git show HEAD:hooks/gate-scripts/lib/marker_check.py >"$T/mc_main.py"   # the commit before the move
python3 -I - "$T/mc_main.py" hooks/gate-scripts/lib <<'PY'
import ast, sys
NAMES = ["_join_continuations", "_ansi_c_span", "_backtick_span", "_heredoc_delim",
         "_heredoc_body_end", "_RESERVED_AT_CMD_RE", "_RESERVED_END_RE", "_PARAM_PATTERN_OP_RE",
         "_SPAN_MAX_DEPTH", "_param_span", "_subst_body_end", "_paren_matches", "_arith_closes",
         "_subst_bodies", "_ESC_RE", "_decode_escapes"]
def defs(path):
    out = {}
    for n in ast.parse(open(path).read()).body:
        name = (n.name if isinstance(n, ast.FunctionDef) else
                n.targets[0].id if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) else None)
        if name:
            out[name] = ast.dump(n)          # no line numbers: position-independent
    return out
main, lex = defs(sys.argv[1]), defs(sys.argv[2] + "/shell_lex.py")
mc_tree = ast.parse(open(sys.argv[2] + "/marker_check.py").read())
mc = defs(sys.argv[2] + "/marker_check.py")
imported = {a.name for n in mc_tree.body if isinstance(n, ast.ImportFrom) and n.module == "shell_lex"
            for a in n.names}
diff = [n for n in NAMES if lex.get(n) != main.get(n)]
left = [n for n in NAMES if n in mc]
extra = sorted(set(lex) - set(NAMES) - {"_SQ"})
unimported = sorted(set(NAMES) - imported)
bad = diff or left or extra or unimported
print("identical" if not bad else "DIFF %s still-in-marker_check %s extra %s not-imported %s"
      % (diff, left, extra, unimported))
sys.exit(1 if bad else 0)
PY
rc=$?
rm -rf "$T"
[ "$rc" -eq 0 ]
```

Expected: `identical` and exit 0. It also checks that the hand-wrapped `from shell_lex import (...)` still names all 16. It must be able to fail: `cp hooks/gate-scripts/lib/shell_lex.py "$TMPDIR/shell_lex.keep"`, change one string literal inside `_decode_escapes` in `shell_lex.py`, rerun the block above and see `DIFF ['_decode_escapes'] …` with a non-zero exit, then `mv "$TMPDIR/shell_lex.keep" hooks/gate-scripts/lib/shell_lex.py` and rerun once more: `identical`, exit 0.

- [ ] **Step 6: Run the suites that load marker_check or compare against it**

```bash
for t in tests/test-marker-*.sh tests/test-ansic-quote-1043.sh tests/test-escaped-dollar-1048.sh \
         tests/test-gate-classifier-fail-closed.sh tests/test-herestring-receiver-643.sh \
         tests/test-brainstorming-oracle-wrapper-root.sh tests/test-design-marker-worktree.sh; do
  bash "$t" >/dev/null 2>&1 && echo "pass $t" || { echo "FAIL $t"; failed=1; }
done
python3 -I hooks/gate-scripts/lib/cmdword.py >/dev/null && echo "cmdword self-check ok" || failed=1
echo "suites rc=${failed:-0}"
[ "${failed:-0}" -eq 0 ]
```

Expected: every line `pass …`, `cmdword self-check ok`, `suites rc=0`, and the block exits 0. A failing marker suite means the move changed behaviour; compare against `git show HEAD~1:hooks/gate-scripts/lib/marker_check.py` once Step 7 has committed, or `HEAD:` before it.

- [ ] **Step 7: Regenerate the lock and commit**

```bash
./scripts/gate-integrity.sh --update
git add hooks/gate-scripts/lib/shell_lex.py hooks/gate-scripts/lib/marker_check.py \
        hooks/gate-scripts/lib/cmdword.py tests/test-escaped-dollar-1048.sh .gate-integrity.lock
git commit -m "refactor(gate): move marker_check's shell lexer into shell_lex (#1085)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: B9 — a missing `shell_lex.py` blocks

**Files:**
- Modify: `tests/test-gate-classifier-fail-closed.sh` (new row B9, directly before section C)

**Interfaces:**
- Consumes: `assert_verdict <want> <command> <gate-path> <label> <failure-note>` (defined at line 67), `$ROOT`, `$WORK` (line 37), as the rows above it use them.
- Produces: one row; no new interface.

marker_check imports `shell_lex` at module level, so with the file gone the classifier exits before printing a verdict, and the gate's `BLOCK_CLASSIFIER_ERROR|exec` fallback (`pre-implementation-gate.sh` line 263) blocks. B9 pins that.

- [ ] **Step 1: Add the row**

In `tests/test-gate-classifier-fail-closed.sh`, insert directly before `echo "── C. normal operation is unchanged ──"`:

```bash
# B9 (#1085): the shared lexer is missing. marker_check imports it at module level, so it
# exits before printing a verdict and the launcher's BLOCK_CLASSIFIER_ERROR fallback blocks.
cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs9"
# Control on the SAME copied tree, lexer present: allowed -- else the BLOCK below proves nothing.
assert_verdict allow "ls -la" "$WORK/gs9/pre-implementation-gate.sh" \
    "B9 control: copied tree with shell_lex.py -> allow" "blocked with the lexer present — B9 would be vacuous"
rm -f "$WORK/gs9/lib/shell_lex.py"
assert_verdict BLOCK "ls -la" "$WORK/gs9/pre-implementation-gate.sh" \
    "shell_lex.py missing -> BLOCK" "allowed — a classifier that cannot import its lexer is a silent bypass"
```

(`allow` and `BLOCK` are the tokens `verdict` returns; section C's rows already use `assert_verdict allow`.)

- [ ] **Step 2: Prove it fires both ways**

Run: `set -o pipefail; bash tests/test-gate-classifier-fail-closed.sh | tail -6` → expected `0 failed`, exit 0, and both B9 rows among the `ok` lines (`bash tests/test-gate-classifier-fail-closed.sh | grep -E "B9|shell_lex"`). The control row is the allow outcome and the second row the block outcome, on one tree that differs only by the deleted file.

- [ ] **Step 3: Commit**

```bash
git add tests/test-gate-classifier-fail-closed.sh
git commit -m "test(gate): a missing shell_lex blocks the pre-implementation gate (#1085)" \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Lock, lint, compile**

```bash
( set -e
  ./scripts/gate-integrity.sh --check
  echo lock-ok
  shellcheck --severity=warning tests/test-gate-classifier-fail-closed.sh tests/test-escaped-dollar-1048.sh
  python3 -m py_compile hooks/gate-scripts/lib/shell_lex.py hooks/gate-scripts/lib/marker_check.py \
    hooks/gate-scripts/lib/cmdword.py
  echo compile-ok )
```

(Each command on its own line: `set -e` does not stop on a failure at the left of `&&`.)

Expected: `lock-ok`, no shellcheck output (`--severity=warning` is the threshold CI uses; both files carry pre-existing info-level notes), `compile-ok`, exit 0.

- [ ] **Step 2: Every shell suite that touches the gate**

```bash
for t in tests/test-cmdword-*.sh tests/test-impl-gate-scope-*.sh tests/test-marker-*.sh \
         tests/test-ansic-quote-1043.sh tests/test-escaped-dollar-1048.sh \
         tests/test-gate-classifier-fail-closed.sh tests/test-gate-integrity.sh \
         tests/test-node-hook-containment.sh tests/test-design-*.sh; do
  bash "$t" >/dev/null 2>&1 && echo "pass $t" || { echo "FAIL $t"; failed=1; }
done
echo "suites rc=${failed:-0}"
[ "${failed:-0}" -eq 0 ]
```

Expected: all `pass`, `suites rc=0`, and the block exits 0. Run on UM (`um-executor`) if local time is a problem; `test-impl-gate-scope-519` alone takes minutes.

- [ ] **Step 3: JS and Python suites**

```bash
set -o pipefail
npm test 2>&1 | tail -5; npm_rc=$?
scripts/test-python.sh 2>&1 | tail -5; py_rc=$?
echo "npm rc=$npm_rc python rc=$py_rc"
[ "$npm_rc" -eq 0 ] && [ "$py_rc" -eq 0 ]
```

Expected: both green, `npm rc=0 python rc=0`, and the block exits 0.

Steps 1–3 only read and check; they leave nothing to commit. If any of them fails, fix the cause in the task that owns the file, regenerate the lock there if a locked file changed, and rerun all three.

---

## Out of scope (part 2 and beyond)

- Everything the spec specifies beyond the move: `<( )` / `>( )` bodies, spec B, spec C, spec D and row B10, the #1085 fixture, the corpus check. Part 2's plan is written after this merges.
- Separate issues already identified: marker_check's own run time over the hook budget on padded inputs; an escaped backtick in a double-quoted `bash -c` program; a heredoc apostrophe followed by a redirect-only write and a later closed quote.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
