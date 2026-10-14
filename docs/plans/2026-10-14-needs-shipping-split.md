# Split needs-shipping.py's selftest out and flatten walk/parse/resolve (#952) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lower the CodeScene findings on `scripts/needs-shipping.py` (#952) with no change in what the classifier prints, exits or raises.

**Architecture:** The classifier stays one file at run time. The ~195 lines of assertion rows (`selftest_structured` through `selftest`) move verbatim into `tests/needs-shipping-selftest.py`, which loads the classifier by absolute path. Inside the classifier, three helpers are extracted: `para_tokens` from `parse`, `lookup` from `resolve`, and `entry_level` plus `file_targets` from `walk`. Every statement keeps its order, so every `clock.remaining()` check, every `Incomplete(...)` and the order between them stay where they are.

**Tech Stack:** Python 3.9 stdlib (`/usr/bin/python3 -I`, measured 3.9.6), bash harness `tests/test-needs-shipping.sh` with its stub `gh`.

**Global Constraints:**
- **Behaviour is frozen.** stdout lines, exit codes, stderr, every `Incomplete("…")` message text, and the position of every `clock.remaining()` call relative to the work around it are unchanged. The 2026-10-12 plan documents the deadline overrun bound as "at most one candidate's resolves"; a helper must not move a check across a loop boundary.
- **Single file at run time (decision A, user-approved 2026-10-14).** The classifier loads no other file. Production runs it as `/usr/bin/python3 -I`, which drops the script directory from `sys.path`; a sibling module would need a load-by-path or a `sys.path` insert, and the second lets a planted `json.py` shadow stdlib. Loading in the other direction, a test loading the classifier, is fine.
- **`--selftest` is removed from the classifier.** It is reachable from `main()` only by loading the test file, which the constraint above forbids. Its only live caller is `tests/test-needs-shipping.sh:645-646`, which switches to the new file and still requires the exact stdout `needs_shipping_selftest_ok`. Mentions in `docs/plans/` and `docs/specs/` are history and stay. This reverses the earlier "keep `--selftest`" sentence in the #952 discussion; say so in the PR body.
- **Assertion rows are moved byte-for-byte.** No row is edited, added or removed. The test file brings the classifier's names into scope with one `globals().update`, so the rows keep their bare names.
- **Sed pins.** `tests/test-needs-shipping.sh` rewrites `^GH_TIMEOUT = 120 ` (line 202) and `^WALK_DEADLINE = 600 ` (line 561) in a copy of the classifier. Neither line moves or changes.
- Regression net, baselined at `origin/main` `79851778` in this worktree: selftest prints `needs_shipping_selftest_ok`; `tests/test-needs-shipping.sh` 267 passed, 0 failed; `tests/test-shipping-kick.sh` 116 passed, 0 failed. All three must hold unchanged at the end.
- Conventional Commits. Each commit ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

**Known residual, not addressed:** the extracted helpers take many arguments (`file_targets` takes 8), so CodeScene may trade complexity findings for argument-count findings, as it already reports for `candidate_targets` and `take`. CodeScene is advisory. No state object is introduced for it. The file stays above CodeScene's 600-line limit (about 760 lines); clearing that needs a second module, which decision A rejected.

---

## File Structure

- Create `tests/needs-shipping-selftest.py`: loader header plus the moved rows. Hyphenated, so pytest never collects it; it runs only through `tests/test-needs-shipping.sh`, which CI's `tests/test-*.sh` glob already covers.
- Modify `scripts/needs-shipping.py`: delete lines 735-930 (the selftest block and the two blank lines after it), the `--selftest` branch in `main()` (lines 939-941) and the usage line 19; extract the helpers in `resolve` (362-392), `parse` (437-470) and `walk` (579-634).
- Modify `tests/test-needs-shipping.sh:645-646`: run the new file.

---

### Task 1: Move the selftest into tests/

**Files:**
- Create: `tests/needs-shipping-selftest.py`
- Modify: `scripts/needs-shipping.py:19`, `:735-930`, `:939-941`
- Modify: `tests/test-needs-shipping.sh:645-646`

**Interfaces:**
- Consumes: every module-level name of `scripts/needs-shipping.py` the rows use (`parse`, `resolve`, `Incomplete`, `Clock`, `MAX_TOKENS`, `SYMLINK`, `DROPPED`, `OUTSIDE`, `ROOT`, `INCOMPLETE`, ...).
- Produces: `/usr/bin/python3 -I tests/needs-shipping-selftest.py` prints `needs_shipping_selftest_ok` and exits 0, or raises `AssertionError`.

- [ ] **Write the header** of `tests/needs-shipping-selftest.py`:

```python
#!/usr/bin/env python3
"""needs-shipping-selftest.py — assertion rows for scripts/needs-shipping.py (#952).

Usage:
    /usr/bin/python3 -I tests/needs-shipping-selftest.py    prints needs_shipping_selftest_ok

Loads the classifier by absolute path; the classifier never loads this file, so it stays one
file under `python3 -I`. Run by tests/test-needs-shipping.sh. Kept Python 3.9-compatible.
"""
import importlib.util
import os
import re
import time

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "scripts", "needs-shipping.py")
_SPEC = importlib.util.spec_from_file_location("needs_shipping", _PATH)
_NS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_NS)
globals().update({k: v for k, v in vars(_NS).items() if not k.startswith("__")})  # the rows use the classifier's bare names


```

- [ ] **Append the rows verbatim:** from `def selftest_structured():` through `    print("needs_shipping_selftest_ok")` of the classifier at `origin/main`, then this footer:

```python


if __name__ == "__main__":
    selftest()
```

Run (copies the block without retyping it):

```bash
cd /Volumes/Work/Projects/busdriver-952
awk '/^def selftest_structured\(\):/{on=1} on{print} /^    print\("needs_shipping_selftest_ok"\)/{exit}' scripts/needs-shipping.py >> tests/needs-shipping-selftest.py
printf '\n\nif __name__ == "__main__":\n    selftest()\n' >> tests/needs-shipping-selftest.py
```

- [ ] **Delete the block from the classifier**, from `def selftest_structured():` through the two blank lines after `print("needs_shipping_selftest_ok")`, so `ARG_PATTERNS = ...` follows `classify()`'s `return` with two blank lines as before. Delete usage line 19 (`    needs-shipping.py --selftest`). In `main()`, delete:

```python
    if argv == ["--selftest"]:
        selftest()
        return 0
```

`time` stays imported (used by `Clock`); `re` stays (used throughout). `random` was imported only inside `selftest()` and moves with it.

- [ ] **Switch the caller** in `tests/test-needs-shipping.sh:645-646` to:

```bash
out=$("$PY" -I tests/needs-shipping-selftest.py 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = needs_shipping_selftest_ok ]; then pass "selftest under $PY"; else fail "selftest under $PY ($out)"; fi
```

The suite `cd`s to the repo root at line 12, so the relative path resolves.

- [ ] **Verify the rows moved unchanged:**

```bash
cd /Volumes/Work/Projects/busdriver-952
diff <(git show origin/main:scripts/needs-shipping.py | awk '/^def selftest_structured\(\):/{on=1} on{print} /^    print\("needs_shipping_selftest_ok"\)/{exit}') \
     <(awk '/^def selftest_structured\(\):/{on=1} on{print} /^    print\("needs_shipping_selftest_ok"\)/{exit}' tests/needs-shipping-selftest.py) && echo ROWS_IDENTICAL
grep -c 'selftest' scripts/needs-shipping.py || [ "$?" -eq 1 ]
```

Expected: `ROWS_IDENTICAL`, then `0`.

- [ ] **Run:** `/usr/bin/python3 -I tests/needs-shipping-selftest.py` → `needs_shipping_selftest_ok`. `/usr/bin/python3 -I scripts/needs-shipping.py --selftest; echo $?` → the usage error line and `1` (it is now an invalid argument list, which fails closed).

- [ ] **Prove the moved test can fail:** in `scripts/needs-shipping.py`, change `FM_RUN_KEYS = ("hooks", "mcpServers",` to `FM_RUN_KEYS = ("mcpServers",`, run `/usr/bin/python3 -I tests/needs-shipping-selftest.py`, expect an `AssertionError` naming a `hooks: x` fixture, then revert and confirm `git diff --stat scripts/needs-shipping.py` shows only this task's deletions.

- [ ] **Run the suites:** `bash tests/test-needs-shipping.sh 2>&1 | tail -1` → `needs-shipping: 267 passed, 0 failed`. `bash tests/test-shipping-kick.sh 2>&1 | tail -1` → `shipping-kick: 116 passed, 0 failed`.

- [ ] **Commit** (litmus runs at the commit gate):

```bash
git -C /Volumes/Work/Projects/busdriver-952 add tests/needs-shipping-selftest.py scripts/needs-shipping.py tests/test-needs-shipping.sh
git -C /Volumes/Work/Projects/busdriver-952 commit -m "refactor(needs-shipping): move the selftest rows into tests/ (#952)"
```

---

### Task 2: Extract helpers in resolve, parse and walk

**Files:**
- Modify: `scripts/needs-shipping.py` — `resolve` (362-392), `parse` (437-470), `walk` (579-634); line numbers are before Task 1's deletions, which are all below line 735, so they still hold.

**Interfaces:**
- Consumes: `tree_map`, `suffix_index`, `agent_config`, `tree_trips`, `instruction_file`, `reader`, `markdown_trips`, `parse`, `candidate_targets`, `take`, `Fetcher`, `code_spans`, `token_text`, `candidates` — all unchanged.
- Produces (module-private, no caller outside the file): `lookup(tmap, prefix, live)`, `para_tokens(para, budget, toks, limit) -> int`, `entry_level(tmaps, exact) -> list`, `file_targets(tmap, names, path, rd, toks, clock, exact, cover)` generator. `resolve`, `parse` and `walk` keep their signatures and docstrings.

- [ ] **`resolve`: extract the per-component lookup.** Insert above `def resolve`:

```python
def lookup(tmap, prefix, live):
    """The tree entry at `prefix`; DROPPED for a symlink outside the live set, Incomplete inside it."""
    entry = tmap.get(prefix)
    if entry and entry[1] == SYMLINK:
        # keep-simple(UPGRADE: resolve link targets if an opted-in repo needs symlinks)
        if live:
            raise Incomplete("symlink")
        return DROPPED
    return entry

```

and in `resolve`, replace

```python
        entry = tmap.get(prefix)
        if entry and entry[1] == SYMLINK:
            # keep-simple(UPGRADE: resolve link targets if an opted-in repo needs symlinks)
            if live:
                raise Incomplete("symlink")
            return Res(DROPPED, False, None, [])
```

with

```python
        entry = lookup(tmap, prefix, live)
        if entry is DROPPED:
            return Res(DROPPED, False, None, [])
```

`DROPPED` is a sentinel compared by identity everywhere (`res.path is DROPPED`), and `tmap` values are tuples or absent, so `entry is DROPPED` only matches the symlink branch.

- [ ] **`parse`: extract the paragraph pass.** Insert above `def parse`:

```python
def para_tokens(para, budget, toks, limit):
    """Append the tokens of one paragraph to `toks` (#936 §4); return the token-text budget left."""
    pairs = [code_spans(ln) for ln in para]
    joined = "\n".join(para)
    plain = all(ok for _, ok in pairs) and not any(u in joined for u in SPAN_UNSAFE)
    for ln, (spans, _) in zip(para, pairs):
        s = 0  # spans are sorted and disjoint, and k only grows, so one forward index suffices
        for k, ch in enumerate(ln):
            prev = ln[k - 1] if k else ""
            if ch != "@" or (prev.isascii() and prev.isalnum()):
                continue
            quoted = prev in ("\"", "'") and ln[k - 2:k - 1] != "\\"
            while s < len(spans) and spans[s][1] <= k:
                s += 1
            in_span = plain and s < len(spans) and spans[s][0] < k
            word = token_text(ln, k + 1, budget)
            budget -= len(word)
            if budget < 0:
                raise Incomplete("token text over budget")
            if len(toks) >= limit:
                raise Incomplete("token limit")
            toks.append((candidates(word), in_span, quoted))
    return budget

```

and replace `parse`'s loop body after `continue` (from `pairs = [code_spans(ln) for ln in para]` through the `toks.append(...)` line) with:

```python
        budget = para_tokens(para, budget, toks, limit)
```

keeping the following `para = []` and `return toks`. The moved lines are the old ones dedented by four spaces; nothing else changes.

- [ ] **`walk`: extract the first level and the per-file candidate loop.** Insert above `def walk`:

```python
def entry_level(tmaps, exact):
    """The walk's first level: (rev, path, reader) for each agent-config instruction blob (#936 §5)."""
    level = []
    for rev, tmap in tmaps.items():
        for path, (kind, mode, _sha, _size) in tmap.items():
            if not agent_config(path):
                continue
            if mode == SYMLINK:
                raise Incomplete("symlinked agent-config path")
            if kind == "commit":  # a submodule's instruction files are not in this tree to walk
                raise Incomplete("gitlink at an agent-config path")
            tree_trips(kind, path)
            if kind == "blob" and instruction_file(path):
                exact.add(path)
                level.append((rev, path, reader(path)))
    return level


def file_targets(tmap, names, path, rd, toks, clock, exact, cover):
    """Blob paths imported by one parsed file at `path`, recording every candidate in the sets (#936 §5).
    A generator: the caller handles each target before the next candidate is resolved."""
    for cands, in_span, quoted in toks:
        live = rd != "claude" or not (in_span or quoted)
        for c in cands:
            clock.remaining()  # per candidate: by-name matches can fan one out to many resolves
            for res in candidate_targets(tmap, names, path, c, live, rd):
                clock.remaining()
                target = take(tmap, res, live, exact, cover)
                if target is not None:
                    yield target

```

Then `walk` becomes:

```python
def walk(repo, revs, clock):
    """Exact and cover path sets reached through imports from agent-config entries at `revs`
    (#936 §5). Raises Incomplete when the walk cannot finish."""
    tmaps = {}
    for rev in revs:
        tmaps[rev] = tree_map(repo, rev, clock)
    names = suffix_index(set().union(*tmaps.values()))
    exact, cover = set(), set()
    level = entry_level(tmaps, exact)
    visited = set(level)
    if len(visited) > MAX_STATES:
        raise Incomplete("visited-state limit")
    fetcher, parsed, ntok = Fetcher(repo, clock), {}, 0
    for depth in range(MAX_DEPTH + 1):
        if not level:
            break
        texts = fetcher.fetch({tmaps[rev][p][2]: tmaps[rev][p][3] for rev, p, _ in level})
        nxt = []
        for rev, path, rd in level:
            clock.remaining()  # the deadline also bounds parsing and traversal, not only gh calls
            sha = tmaps[rev][path][2]
            if depth == 0:  # per path, not per sha: shell_scope depends on where the text sits (#950)
                markdown_trips(path, texts[sha])
            if sha not in parsed:
                parsed[sha] = parse(texts[sha], MAX_TOKENS - ntok)  # one budget for the whole walk
                ntok += len(parsed[sha])
            for target in file_targets(tmaps[rev], names, path, rd, parsed[sha], clock, exact, cover):
                key = (rev, target, rd)
                if key in visited:
                    continue
                if depth == MAX_DEPTH:
                    raise Incomplete("import chain deeper than 5")
                visited.add(key)
                if len(visited) > MAX_STATES:
                    raise Incomplete("visited-state limit")
                nxt.append(key)
        level = nxt
    clock.remaining()
    return exact, cover
```

Why the order is unchanged: the old loop skipped `target is None` and `key in visited` with one `continue`; `file_targets` drops the `None`s and the caller keeps the `visited` test. Because `file_targets` is a generator, the caller's `visited`, depth and state-limit checks for one target run before the generator resolves the next candidate, exactly as in the inline loop, so the same `Incomplete` is raised at the same point. Python 3.9 generators propagate `Incomplete` from `clock.remaining()`, `candidate_targets` and `take` to the caller unchanged.

- [ ] **Run:** `/usr/bin/python3 -I tests/needs-shipping-selftest.py` → `needs_shipping_selftest_ok`; `bash tests/test-needs-shipping.sh 2>&1 | tail -1` → `needs-shipping: 267 passed, 0 failed`; `bash tests/test-shipping-kick.sh 2>&1 | tail -1` → `shipping-kick: 116 passed, 0 failed`.

- [ ] **Check the pins and messages survived:**

```bash
cd /Volumes/Work/Projects/busdriver-952
grep -c '^GH_TIMEOUT = 120 \|^WALK_DEADLINE = 600 ' scripts/needs-shipping.py
diff <(git show origin/main:scripts/needs-shipping.py | grep -o 'Incomplete("[^"]*")' | sort) \
     <(grep -o 'Incomplete("[^"]*")' scripts/needs-shipping.py | sort) && echo MESSAGES_IDENTICAL
diff <(git show origin/main:scripts/needs-shipping.py | awk '/^def selftest_structured/{exit} {print}' | grep -c 'clock.remaining()') \
     <(grep -c 'clock.remaining()' scripts/needs-shipping.py) && echo CLOCK_CALLS_IDENTICAL
wc -l scripts/needs-shipping.py
```

Expected: `2`, `MESSAGES_IDENTICAL`, `CLOCK_CALLS_IDENTICAL`, and about 770 lines.

- [ ] **Commit:**

```bash
git -C /Volumes/Work/Projects/busdriver-952 add scripts/needs-shipping.py
git -C /Volumes/Work/Projects/busdriver-952 commit -m "refactor(needs-shipping): extract helpers from walk, parse and resolve (#952)"
```

---

### Task 3: PR

- [ ] Push `refactor/952-needs-shipping-split`, then (separate call) `cd /Volumes/Work/Projects/busdriver-952 && gh pr create ...` once litmus PR mode passes. Body: what moved and why the file stays single, the `--selftest` removal and its one caller, the three green suites with counts, `ROWS_IDENTICAL` / `MESSAGES_IDENTICAL`, the argument-count and 600-line residuals, and `Closes #952`. Note #927 (module mean complexity) is likely improved but not re-measured locally. Ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

---

## Sanity check

- #952 suggested shape: selftest to a test file (Task 1); per-file candidate loop in `walk`, paragraph pass in `parse`, per-component lookup in `resolve` (Task 2); separate import-walk module — rejected by decision A, residual stated.
- Regression net unchanged: same assertion rows (byte-diffed), same 267 and 116 shell cases.
- Names: `lookup`, `para_tokens`, `entry_level`, `file_targets` are each defined once and used once; no collision with existing module names (`grep -n '^def lookup\|^def para_tokens\|^def entry_level\|^def file_targets'` must print nothing before Task 2).

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
