# Heredoc-Body Writes, Part 1 (#1093) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the design gate block the #1093 writes that hide behind a heredoc body's apostrophe at top level (member 1a) or inside an expanding body's `$( )` (member 2), plus #1101 item 4. Members 1b (unreadable `bash -c`/`eval` programs) and 3 (a UTF-8 byte delimiter), and continuation-split terminators, stay open in #1093 for later parts. Refs #1093 and #1101.

**Architecture:** Four changes. Each can only add a block, so none can turn a `main` block into an allow.
1. `shell_lex._subst_bodies` records where each top-level heredoc operator and body lies. Under cmdword only (`_cmdword_on`), it also returns the `$( )` and backtick bodies inside a body whose delimiter is unquoted, read with heredoc rules. A body that scan cannot read sets a flag and the scan goes on, and `cmdword.is_file_mod` blocks on that flag at any depth (Deviation 5).
2. cmdword reads every command a second time with its heredocs cut out (`_heredoc_free`), at every depth. A memo keeps nested texts from being re-read per pass, and it charges the scan budgets as on `main`.
3. cmdword's bash-faithful third reading (`_lex_reading`) also starts on a command that has no `#` or `$` but holds `<<`, or a newline and two `<`, and reads it heredoc-free.
4. The gate's raw redirect check also runs on the heredoc-free text. A redirect seen only there counts as an explicit modification, so the review-script exemption (F8) cannot lift it.

**Why this is part 1.** Six design-review rounds on a plan for the whole of #1093 (never committed) kept finding new lexer gaps, and round 6 found a block→allow regression in one of its changes: joining an UNQUOTED body's continuations in `_join_continuations` queued a phantom body after a `<<` that is no heredoc (`$((1<<2))`, `# <<EOF`), and the phantom joined `E\`+newline+`E` into a terminator that ended a real quoted body early. This part leaves `_join_continuations`, `_bash_ansi_c` and the depth-0-only "unreadable blocks" rule exactly as on `main`; rows J1–J3 pin the round-6 shapes.

**Tech Stack:** Python 3 (stdlib only), bash, the existing shell test harness (`tests/test-*.sh`, `scripts/ci/run-shell-tests.sh`).

**Global Constraints:**
- No new dependencies. `shell_lex.py` keeps importing only `re`.
- **Additive only.** No change may turn a `main` block into an allow: not on the fuzz (the #1085 suite's `--baseline` check), not on the local transcript corpus (Task 5 Step 4), not on any row. **Explicit blocks are monotonic too:** a command `main`'s `is_file_mod` blocks must still be blocked by this branch's `is_file_mod`, not only by the redirect check, because a redirect-only block is one the review-script exemption (F8) can lift (Deviation 7).
- **marker_check reads as on `main`.** Every behaviour change in `shell_lex` sits behind `shell_lex._cmdword_on`, which is off by default and on only while `cmdword.is_file_mod` or `cmdword.heredoc_free` runs. The edits outside the switch preserve behaviour: `_heredoc_body_end` re-expressed through `_heredoc_terminator`, and the optional `spans` argument. Task 4's `switch:` rows pin that.
- **Every edit under `hooks/gate-scripts/**` needs `./scripts/gate-integrity.sh --update`** before the branch is reviewed (`.gate-integrity.lock`, #742). If it refuses because of stale bytecode, delete `hooks/gate-scripts/lib/__pycache__/*.pyc` and rerun.
- The gate's inline classifier in `pre-implementation-gate.sh` is a single-quoted bash string. Python added there must contain **no `'` character**, comments included.
- Fixtures that prove a write **execute it under bash ≥ 5** in a scratch tree first, using the #1085 fixture's `bash5()`/`writes()`. A missing bash 5 is a FAIL, not a skip.
- Full suites run on UM through `um-run`, because a local hook refuses them on the Mac. Single named suites run locally.
- Conventional Commits; footer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The litmus pre-commit gate runs on every commit.

**Evidence.** This plan's edits were applied, as written, to an archive of `main` 6.0.5 (`d41496a`) and run under bash 5.3.20. Every figure below is from that tree's real hook or code, against the same tree unpatched.
- Rows: Task 4's suite passes 78/78, its rows through the real hook. The over-cap and cache `switch:` rows fail on the revisions that lacked their fixes.
  - All 24 BLOCK rows write, and 20 of them are allowed on `main`. Four block there too: J1 and J2 pin the round-6 regression, R47 and R48 pin round 1's.
  - All 18 ALLOW rows are read-only and allowed.
  - The 15 KNOWN_ALLOW rows write and are allowed, on `main` and here.
  - The 5 KNOWN_BLOCK rows are read-only and blocked. K7 and K9 are new here; the rest block on `main` too.
  - Deleting Task 3's `has_explicit_mod` line fails R43 and nothing else (checked on round 1's revision).
- Existing suites on that tree:
  - `test-pre-implementation-gate.sh` 126/126;
  - `test-gate-classifier-fail-closed.sh` 24/24, B11 and B12 included;
  - `test-marker-heredoc-interp-1052.sh` 63/63, 2 skipped as on `main`;
  - `test-cmdword-case-backtick-1063.sh` 31/31;
  - the #1085 fixture: rows 156/156, timing 82/82.
- Fuzz: the #1085 generator at full size (seeds 19 and 20) against `main`'s `cmdword.py` as baseline, with Deviation 7's explicit check: 38,049 commands that write, none allowed. No command `main`'s `is_file_mod` blocks went unblocked by this branch's `is_file_mod`.
- marker_check: all 3,978 corpus commands holding `<<` get the same `marker_check.py` verdict from both trees.
- Corpus: 40,014 distinct local Bash commands, classified only, gave **0 block→allow**, 0 explicit drops, 0 exceptions and 3 allow→block. All 3 are real redirect writes after an apostrophe-bearing `python3 - <<'EOF' … EOF` body that `main` missed. While a design is pending the gate blocks every redirect that does not go to `/dev/null`, so these are true positives.
- Time, through the hook: three nested `cat <<E` / `x` / `E` / `bash -c '<next level>'` programs, 30 K characters, read-only: allowed in 0.39 s on `main`, 0.63 s here (in-process 0.07 s / 0.31 s). Four levels are refused on `main` by the gate-state helper scan before the design check runs, so the row uses three. Without the memo the second pass doubled per level (2.07 s at four levels in-process, measured in an earlier revision). `: $((1)) <<E` / `$((1))` / `E` repeated to just under the cap, then `rm -rf src`: blocked in 0.13 s, because `_heredoc_substs` keeps the caller's `_arith_closes` cache. The 64 K row blocks at Deviation 2's cap, before any scan; it times the cap, not the cache. One 32 K body of `$((1))${a-$((1))}`, then `rm -rf src`: 0.32 s in-process (`main` 0.37 s). Round 1's revision took 3.16 s, because its `${…}` recursion evicted that cache. Through the hook it blocks in 0.36 s, but the gate-state helper scan refuses it first, so the hook row cannot see the cache. The guard is the `switch:` row that counts characters `_arith_closes` rebuilds on a cache miss over 400 such units: 10,000 here, 2,723,200 in round 1's revision, against a limit of three times the body.

**Deviations and decisions:**
1. **Third-reading trigger widened.** The third reading now also runs when a command with no `#` or `$` is **heredoc-shaped** (`_heredoc_shaped`): it holds `<<`, or a newline and at least two `<`. It then reads the **heredoc-free** text. The same predicate decides Deviation 2's cap.
   - **Why:** without it R13 (`bash -c 'cat <<E` / `it'\''s` / … `rm -rf src` …`'`) stays allowed. `_normalize` turns the program's newlines into ` ; `, so the base reading's `bash -c` operand never closes its heredocs.
   - **Why two `<`, not `<<`:** a program's `<<` can be spelled `<""<` (R46). Quote removal joins it for bash, so the raw command holds no contiguous `<<`. Every heredoc needs two `<` and a newline, whatever the quoting.
   - **Why the heredoc-free text:** on the raw text this reading reads top-level bodies as commands. Three read-only `python3 - <<'EOF'` commands in the corpus became blocked that way in an earlier spike.
   - **Over the cap:** a heredoc-shaped command over `_LEX_READING_MAX` blocks before any reading (Deviation 2). Round 2 found the gap this closes: R46 padded past the cap with `a`s had no contiguous `<<` for the cap to see, skipped the reading, wrote, and was allowed (`main` allows it too). A command that is not heredoc-shaped skips the reading at any length, as on `main`: C18 (`echo a…a` / `echo b`, 33 K) holds no `<`. The cost is an over-cap read-only command with a newline and two `<` now blocks. The corpus has none: its longest command is 18,755 characters.
2. **Size cap.** A depth-0 command longer than `_LEX_READING_MAX` (32,768) that is heredoc-shaped (Deviation 1) blocks before either pass runs, as #1085 part 2's Deviation 9 does for `#`/`$`. A hook past its 5 s deadline writes no decision, which the harness reads as ALLOW. The longest command in the corpus is 18,755 characters.
3. **The verdict memo charges the budgets.** Each nested verdict is memoized per (text, depth, reading) within one top-level call, so the second pass costs at most twice `main`'s per level instead of 2^depth. A hit charges the three scan budgets what the first evaluation spent, so 25 identical siblings exhaust them exactly as on `main` (row N1). A hit that would take any budget below 0 is not used: the text is evaluated again, so the budget sites themselves decide what exhaustion means. They differ: an exhausted `_scan_budget` or `_case_budget` blocks, an exhausted `_psub_budget` scans the whole command raw, and a command with no `<( )` never reads `_psub_budget` at all. The heredoc-free pass gives back what it spent, so it never starves a later sibling.
4. **A redirect seen only heredoc-free is explicit.** The F8 exemption lifts a redirect-only block when the command runs a `blueprint-review`/`litmus` script, matched anywhere in the raw text — including inside a heredoc body. Without this rule R43 (`cat <<E` / `it's` / `sh litmus/scripts/x` / `E` / `echo x > src/f` / `echo 'y'`) would be found by the new pass and exempted again. F8 matching a path in text bash never runs is pre-existing, not new: with no apostrophe in the body the raw text already shows the redirect, and `main` and this plan both exempt it (row O15). This part only stops the new pass from widening that. The F10 dispatcher exemption (`delib_gate.is_exempt`) is unchanged: it already exempts a dispatcher command wholesale, `rm` included, on `main`.
5. **A body the scan cannot read blocks, at any depth.** The expanding-body scan gives up on a `'` inside `${…}` (K7, R40) and on a `$( )` or backtick that does not close inside the body. The give-up does not end `_subst_bodies`. It sets `shell_lex._body_unread`, the scan goes on past that body's terminator, and `cmdword.is_file_mod` returns True at depth 0 when the flag is set. The flag is cleared there at the start of every top-level call.
   - **Why not `return out, False`:** that was round 1's version, and it was wrong two ways.
     - Below depth 0, `ok = False` blocks nothing: the "unreadable blocks" rule is depth-0 only, by design, and member 1b is what would change that. So R40 inside `v=$( )` (R45) was allowed and wrote.
     - Returning early also dropped the substitutions after the body, which `main` collects. In R47, `bash -c '…<K7 body>…` / `v=$(echo ${v%)}; echo x > src/f)'`, `main`'s `is_file_mod` blocks. Round 1's version did not, and the gate's F8 exemption then lifted the redirect-only block, because the body names a review script: a block→allow regression. Inside `v=$( )` it needs no F8 at all: `main` blocks R48 and round 1's version allowed it.
   - **What the flag costs:** K7's over-block now also applies inside programs and substitutions (row K9).
   - **What it gains:** `_heredoc_free` still cuts every body whose terminator was found, even after a give-up (row R44).
6. **Out of scope, tracked:**
   - #1093 members 1b and 3, and terminators or `$(` split by a continuation: rows O7–O14 pin them as known allows (`main` allows them too).
   - A review-script path inside a body exempting a redirect the raw text shows (F8, as on `main`): row O15.
   - #1101 items 1–3, the comment class: row O1.
   - #1112, a one-line program ending in a lone backslash: row O2.
   - #1113, lexer state this plan does not change: `((true);`, `$(( ( (1)) << 2 ))`, a double quote or a `${` opened on the `<<E` line: rows O3–O6. O6 is new; the PR adds it to #1113.
7. **Explicit verdicts are compared on their own.** "`main` blocks, this allows" is checked on `is_file_mod` alone, in the fuzz (Task 3 Step 3 changes the #1085 fixture's `--baseline` check) and in the corpus (Task 5 Step 4), as well as on `is_file_mod` OR the redirect check. The OR alone certified round 1's R47 regression as additive: the redirect check still found the write, but F8 lifts a redirect-only block and never an explicit one.
8. **Known over-blocks,** all read-only (rows K1, K7, K8, K9, N1):
   - **K7 and K9, new here:** any `'` inside a `${…}` in an expanding body makes the body scan give up, so a read-only `${v#'x'}` there blocks, at top level (K7) or inside a program (K9, Deviation 5). Which `'` quote is bash's call (a pattern operand's do, a default's do not), and R40 shows a guess is exploitable: `${v#'$(echo '}` hides `$(rm -rf src)`. `${FOO:-'default'}` in a body already blocks on `main`.
   - **K1, K8, N1, as on `main`:** two consecutive `v=$(cat <<E` / `it's` / `E` / `)` blocks; a UTF-8 byte delimiter inside `$( )` (member 3's decoder fixes it); 25 identical double-quoted `$( )` spending the scan budget.

---

## File Structure

- Modify `hooks/gate-scripts/lib/shell_lex.py`: `_heredoc_terminator`, `_heredoc_substs`, `_heredoc_substs_scan`; `_heredoc_body_end` through `_heredoc_terminator`; `_subst_bodies` gains `spans` and the expanding-body scan.
- Modify `hooks/gate-scripts/lib/cmdword.py`: `_heredoc_free`, `heredoc_free`, the `_is_file_mod` wrapper (the old body is renamed `_is_file_mod_text`), the verdict memo, the third-reading trigger; two stale comments.
- Modify `hooks/gate-scripts/pre-implementation-gate.sh`: imports `heredoc_free`; the redirect check also reads its text.
- Modify `tests/fixtures/cmdword_1085.py`: `gate_redirect_check()` supplies `heredoc_free`.
- Create `tests/fixtures/heredoc_1093.py`: rows through the real hook, plus in-process switch rows.
- Create `tests/test-heredoc-body-1093.sh`: builds the armed repo and runs the fixture.
- Modify `tests/test-gate-classifier-fail-closed.sh`: rows B11 (`heredoc_free` raises → BLOCK) and B12 (`heredoc_free` missing → R1 still BLOCK).
- Modify `.gate-integrity.lock`: regenerated.

---

### Task 1: `shell_lex` — spans and expanding-body substitutions

**Files:**
- Modify: `hooks/gate-scripts/lib/shell_lex.py`: `_heredoc_body_end` (`:260-276`), `_subst_bodies` (`:551-678`)

**Interfaces:**
- Produces:
  - `_subst_bodies(s, spans=None) -> (bodies, ok)`. When `spans` is a list it receives, top level only: the continuation-joined text as `spans[0]`, then `(start, end)` pairs in increasing order for each heredoc operator-and-word (`<<E`) and each body including its terminator line.
  - `_heredoc_terminator(s, k, d, strip) -> (terminator_line_start, past_terminator)`.
  - `_heredoc_substs(body, out) -> bool`.
  - `_body_unread`: a one-item list, set True by `_subst_bodies` (cmdword only) when an expanding body cannot be scanned; cleared and read by `cmdword.is_file_mod` (Task 2).

- [ ] **Step 1: the helpers, and `_heredoc_body_end` through them.** Replace the body of `_heredoc_body_end` (keep its docstring) and add the helpers directly after it:

```python
    k = nl
    for d, strip in delims:
        k = _heredoc_terminator(s, k, d, strip)[1]
    return k


# Set when cmdword's scan of an EXPANDING heredoc body gives up (#1093). The scan goes on
# past that body, and cmdword.is_file_mod blocks on the flag at any depth: bash runs the
# body, so a body the gate could not read is not one it may call clean.
_body_unread = [False]


def _heredoc_terminator(s, k, d, strip):
    # (start of the terminator line, index past it) for the body starting at s[k]; both
    # len(s) when the body never ends.
    while k < len(s):
        e = s.find('\n', k)
        nxt = len(s) if e == -1 else e + 1
        line = s[k:len(s) if e == -1 else e]
        if (line.lstrip('\t') if strip else line) == d:
            return k, nxt
        k = nxt
    return len(s), len(s)


def _heredoc_substs(b, out):
    # The `$( )` and backtick bodies in an EXPANDING heredoc body b (#1093). Quotes are text
    # there, and a backslash escapes only `$`, a backtick, a backslash or a newline. False
    # when one does not close inside the body, which bash cannot run either. The caller's
    # _arith_closes cache is kept: evicting it per body made the caller's scan quadratic.
    saved = list(_paren_matches)
    try:
        return _heredoc_substs_scan(b, out)
    finally:
        _paren_matches[0], _paren_matches[1] = saved


def _heredoc_substs_scan(b, out):
    i = 0
    while i < len(b):
        c = b[i]
        if c == chr(92):
            i += 2
        elif b.startswith("$((", i) and _arith_closes(b, i):
            i += 3                       # arithmetic: walked on, a `$( )` inside still runs
        elif c == "$" and b.startswith("{", i + 1):
            # `${v#'$(x '}`: a pattern's `'` quotes here, so the `$(` is text. Which `'` quote
            # is bash's call, so one inside `${…}` gives up; without one the inside is body.
            j = _param_span(b, i, True)
            if j is None or "'" in b[i:j] or not _heredoc_substs(b[i + 2:j - 1], out):
                return False
            i = j
        elif c == "$" and b.startswith("(", i + 1):
            j = _subst_body_end(b, i + 1)
            if j < 0:
                return False
            out.append(b[i + 2:j])
            i = j + 1
        elif c == chr(96):
            j = _backtick_span(b, i)
            if j is None:
                return False
            out.append(re.sub(r"\\([$`\\])", r"\1", b[i + 1:j - 1]))   # bash unescapes these
            i = j
        else:
            i += 1
    return True
```

`_heredoc_body_end` returns exactly what it did before: after a match the old loop's `k` equals `_heredoc_terminator(...)[1]`, and both give `len(s)` when no line matches.

The `${…}` inside recurses through `_heredoc_substs`, not `_heredoc_substs_scan`. `_paren_matches` caches one string, so scanning the slice directly evicted the body's `_arith_closes` cache once per `${…}`. A body of `$((1))${a-$((1))}` repeated to 32 K then took 3.16 s in-process, against 0.37 s on `main`. With the save it takes 0.32 s (round 1; Task 4 timing row).

- [ ] **Step 2: `_subst_bodies` records spans and reads expanding bodies.** Make five edits.

(a) Change the signature `def _subst_bodies(s):` to `def _subst_bodies(s, spans=None):`. In its leading comment, replace the last sentence (`Every heredoc body is skipped, expanding or not: this scan only ADDS coverage, so leaving a body to the existing readings is never a regression.`) with:
`# A body is data, and a $( ) in it runs only when its delimiter is unquoted: cmdword (_cmdword_on) reads those with heredoc rules (#1093); marker_check skips every body, as on main. spans: the joined text, then each top-level heredoc operator and body as (start, end).`

(b) After `s = _join_continuations(s)` and before `out, i, n = [], 0, len(s)`, add:

```python
    if spans is not None:
        spans.append(s)          # spans[0]: the joined text the spans after it index into
```

(c) Change `heredocs = []` (the initializer at line 565) to `heredocs, expands = [], []`.

(d) Replace

```python
        if not in_d and heredocs and ch == chr(10):
            i = _heredoc_body_end(s, i + 1, heredocs)
            heredocs = []
            ws = True
            continue
```

with

```python
        if not in_d and heredocs and ch == chr(10):
            k = i + 1
            for (d, strip), exp in zip(heredocs, expands):
                body_end, nxt = _heredoc_terminator(s, k, d, strip)
                if spans is not None:
                    spans.append((k, nxt))
                if exp and _cmdword_on[0] and not _heredoc_substs(s[k:body_end], out):
                    _body_unread[0] = True     # and read on: Deviation 5
                k = nxt
            i = k
            heredocs, expands = [], []
            ws = True
            continue
```

(e) In the operator branch inside `_subst_bodies` (line 603, not the one in `_subst_body_end`), replace

```python
            hd = _heredoc_delim(s, i)
            if hd:
                heredocs.append(hd[0])
                i = hd[1]
```

with

```python
            hd = _heredoc_delim(s, i)
            if hd:
                heredocs.append(hd[0])
                # Any quote or backslash in the word quotes it, and the body stays literal.
                expands.append(not any(c in s[i + 2:hd[1]] for c in "'" + chr(34) + chr(92)))
                if spans is not None:
                    spans.append((i, hd[1]))
                i = hd[1]
```

With the switch off, `_subst_bodies` returns what it did on `main` for every input, and `spans` only records.

- [ ] **Step 3: Run the lexer's existing suites.** They must pass unchanged:

```bash
failed=0
for t in tests/test-marker-heredoc-interp-1052.sh tests/test-cmdword-case-backtick-1063.sh tests/test-gate-classifier-fail-closed.sh; do
  bash "$t" >/dev/null 2>&1 || { echo "FAIL $t"; failed=1; }
done
[ "$failed" -eq 0 ]
```

Expected: exit 0. This task's own rows come in Task 4.

---

### Task 2: cmdword — heredoc-free pass, verdict memo, third-reading trigger

**Files:**
- Modify: `hooks/gate-scripts/lib/cmdword.py`: `:2545-2551` (defuser comment), `:4851-4899` (`is_file_mod`, `_is_file_mod_readings`, `_is_file_mod`), `:4953` (depth-rule comment)

**Interfaces:**
- Consumes: `shell_lex._subst_bodies(s, spans)` (Task 1).
- Produces:
  - `heredoc_free(cmd) -> str | None`: public, sets `_cmdword_on` for its call, used by the gate in Task 3.
  - `_heredoc_free(cmd) -> str | None`.

- [ ] **Step 1: the verdict memo (Deviation 3) and the heredoc shape (Deviation 1).** Directly above `def _is_file_mod_readings(cmd, _depth=0):` add the following, then two blank lines. All three budgets are defined earlier in the module.

```python
_verdict_memo = {}
_BUDGETS = (_scan_budget, _psub_budget, _case_budget)


def _heredoc_shaped(cmd):
    # Could cmd hold a heredoc? Every one needs two `<` and a newline, however quoted:
    # `<""<` is `<<` to bash once quotes are removed (#1093, plan Deviation 1).
    return "<<" in cmd or (chr(10) in cmd and cmd.count("<") >= 2)
```

In `is_file_mod`, replace

```python
    if _depth == 0:
        _lex_memo.clear()
    try:
        return _is_file_mod_readings(cmd, _depth)
```

with

```python
    if _depth == 0:
        _lex_memo.clear()
        _verdict_memo.clear()
        shell_lex._body_unread[0] = False
    # #1093: the heredoc-free pass descends into the same nested texts as the first pass.
    # One verdict per (text, depth, reading) per top-level call keeps it linear.
    key = (cmd, _depth, _lex_reading[0], _ansi_c_reading[0])
    try:                         # the lookup inside, so the finally always restores the switch
        hit = _verdict_memo.get(key) if _depth else None
        # A hit spends what the first reading spent: the budgets bound how much text a
        # command makes the gate read, and 25 copies of one body are 25 reads on main. A
        # hit that would run a budget out is evaluated instead, so the budget sites decide
        # what exhaustion means, as on main (an exhausted _psub_budget scans, not blocks).
        if hit and all(b[0] >= d for b, d in zip(_BUDGETS, hit[1])):
            for b, d in zip(_BUDGETS, hit[1]):
                b[0] -= d
            return hit[0]
        before = [b[0] for b in _BUDGETS]
        r = _is_file_mod_readings(cmd, _depth)
        if _depth:
            _verdict_memo[key] = (r, [x - b[0] for x, b in zip(before, _BUDGETS)])
            return r
        # A body the expanding-body scan could not read, at any depth (Deviation 5).
        return r or shell_lex._body_unread[0]
```

A hit never changes what exhaustion does: either it fits in every budget and charges it, or the text is evaluated again and the sites decide as on `main` (Deviation 3). The flag is read only at depth 0, after every reading, so a give-up anywhere in the call (a program, a substitution, a memoized text) blocks once.

- [ ] **Step 2: the third-reading trigger (Deviation 1).** In `_is_file_mod_readings`, replace

```python
    if "#" not in cmd and "$" not in cmd:
        return False
```

with

```python
    if "#" not in cmd and "$" not in cmd:
        if not _heredoc_shaped(cmd):
            return False
        # #1093: here only for the programs the command hands a shell, read as written (the
        # base reading turns their newlines into ` ; `). Its top-level heredoc bodies are data,
        # and this reading would read them as commands, so it reads the text without them.
        hf = _heredoc_free(cmd)
        cmd = hf if hf is not None else cmd
```

- [ ] **Step 3: the wrapper.** Rename `def _is_file_mod(cmd, _depth=0):` (line 4899) to `def _is_file_mod_text(cmd, _depth=0):`, keeping its docstring and body. Insert this directly before it:

```python
def _heredoc_free(cmd):
    """cmd with every top-level heredoc operator, word and body cut out, or None when there is
    none or shell_lex cannot read it (#1093). The tokenizer reads a body as commands, so an
    apostrophe in one paired with a later quote and hid every command between them. The
    substitutions an unquoted body runs are not lost: _lex_bodies returns them from the
    original text."""
    spans = []
    _bodies, ok = shell_lex._subst_bodies(cmd, spans)
    if not ok or len(spans) < 2:
        return None
    s, parts, k = spans[0], [], 0
    for a, b in spans[1:]:
        parts.append(s[k:a])
        k = b
    parts.append(s[k:])
    return "".join(parts)


def heredoc_free(cmd):
    # _heredoc_free as cmdword reads it, for the gate's raw redirect check (#1093).
    prev, shell_lex._cmdword_on[0] = shell_lex._cmdword_on[0], True
    try:
        return _heredoc_free(cmd)
    finally:
        shell_lex._cmdword_on[0] = prev


def _is_file_mod(cmd, _depth=0):
    # _is_file_mod_text, then the same text with its heredocs cut out (#1093). Additive: the
    # cut text is what bash runs as commands, so it can only add a block.
    if _depth == 0 and len(cmd) > _LEX_READING_MAX and _heredoc_shaped(cmd):
        # Checked FIRST, before either pass: a hook past its 5 s deadline writes no
        # decision, which the harness reads as ALLOW. Fail CLOSED (plan Deviation 2).
        return True
    if _is_file_mod_text(cmd, _depth):
        return True
    if "<<" not in cmd:
        return False
    hf = _heredoc_free(cmd)
    if hf is None or hf == cmd:
        return False
    # The second pass re-reads text the first already paid for: it may run a budget
    # out (and block), but it leaves the budgets as it found them for later siblings.
    before = [b[0] for b in _BUDGETS]
    try:
        return _is_file_mod_text(hf, _depth)
    finally:
        for b, x in zip(_BUDGETS, before):
            b[0] = x
```

Every existing caller of `_is_file_mod` (in `_is_file_mod_readings`) now reaches the wrapper; nothing else calls the renamed `_is_file_mod_text`. Confirm with `grep -n '_is_file_mod(' hooks/gate-scripts/lib/cmdword.py`: the only hits are the wrapper's own `def` and the calls in `_is_file_mod_readings`.

- [ ] **Step 4: two stale comments.** At lines 2545-2551, replace the sentence that begins `(A redirect-only write after such a body is NOT caught:` and runs to `tracked in #1093.)` with `(A write after such a body is classified by the heredoc-free pass and, for a redirect, the gate's heredoc-free redirect check -- #1093.)` At line 4953 the comment `so a give-up inside one is a stated gap, tracked in #1093.` stays: member 1b is still open.

- [ ] **Step 5: self-check.** `python3 -I hooks/gate-scripts/lib/cmdword.py` runs the file's own asserts and must exit 0.

---

### Task 3: the gate's redirect check reads the heredoc-free text

**Files:**
- Modify: `hooks/gate-scripts/pre-implementation-gate.sh:696-699`, `:793-803`
- Modify: `tests/fixtures/cmdword_1085.py:86-101` (`gate_redirect_check`)

**Interfaces:**
- Consumes: `cmdword.heredoc_free` (Task 2).

- [ ] **Step 1: import.** After the `try: from cmdword import is_file_mod / except Exception: is_file_mod = None` block, add:

```python
# #1093: the heredoc-free text for the redirect check. Missing, it is None, and the
# check then blocks every command holding a heredoc (Step 2).
try:
    from cmdword import heredoc_free
except Exception:
    heredoc_free = None
```

- [ ] **Step 2: the check.** Replace

```python
        if not is_mod:
            no_single = re.sub(r"'\''[^'\'']*'\''", "", cmd)
            safe = re.sub(r"[12]>\s*/dev/null", "", no_single)
            safe = re.sub(r"&>\s*/dev/null", "", safe)
            safe = re.sub(r">\s*/dev/null", "", safe)
            # Strip fd-to-fd redirects: 2>&1, >&2, 1>&2 (not file writes)
            safe = re.sub(r"[012]?>&[012]", "", safe)
            if re.search(r">{1,2}\s*\S", safe):
                is_mod = True
```

with the version below. It adds no `'`: the only quotes are the existing `'\''` sequences.

```python
        # #1093: also the command with its heredocs cut out. A body is data, and an
        # apostrophe in one paired with a later quote here and hid every redirect between.
        # An exception, or no heredoc_free for a command holding a heredoc, blocks; so does
        # a redirect only the cut text shows, which a review-script path written inside a
        # body must not exempt (Deviation 4): all three set has_explicit_mod.
        if not is_mod:
            texts = [cmd]
            try:
                hf = heredoc_free(cmd) if heredoc_free is not None else None
            except Exception:
                hf, has_explicit_mod, is_mod = None, True, True
            if heredoc_free is None and ("<<" in cmd or (chr(10) in cmd and cmd.count("<") >= 2)):
                is_mod = has_explicit_mod = True
            if hf is not None:
                texts.append(hf)
            for n, text in enumerate(texts):
                no_single = re.sub(r"'\''[^'\'']*'\''", "", text)
                safe = re.sub(r"[12]>\s*/dev/null", "", no_single)
                safe = re.sub(r"&>\s*/dev/null", "", safe)
                safe = re.sub(r">\s*/dev/null", "", safe)
                # Strip fd-to-fd redirects: 2>&1, >&2, 1>&2 (not file writes)
                safe = re.sub(r"[012]?>&[012]", "", safe)
                if re.search(r">{1,2}\s*\S", safe):
                    has_explicit_mod = has_explicit_mod or (n > 0 and not is_mod)
                    is_mod = True
```

The missing-helper test spells `_heredoc_shaped` out inline, because cmdword may be the module that failed to import. It runs only in a damaged installation, so being wider than strictly needed costs nothing there. The `# Check for shell redirects` comment lines above stay where they are. Then check two things: `bash -n hooks/gate-scripts/pre-implementation-gate.sh` exits 0, and Step 4's suites pass. A stray `'` would end the bash string early and fail every gate suite.

- [ ] **Step 3: the #1085 fixture supplies `heredoc_free`.** `gate_redirect_check()` cuts from the `# Check for shell redirects` line to the first `is_mod = True` and wraps it in `def check(cmd)`. The new block's first `is_mod = True` is the one after the `>{1,2}` search (neither `hf, has_explicit_mod, is_mod = None, True, True` nor `is_mod = has_explicit_mod = True` contains that string), so the cut stays as it is, and the `has_explicit_mod` line above it reads a name the cut never assigned. So make two edits: replace `ns = {"re": re}` with

```python
    sys.path.insert(0, LIB)
    from cmdword import heredoc_free
    ns = {"re": re, "heredoc_free": heredoc_free}
```

and replace `"def check(cmd):\n    is_mod = False\n"` with `"def check(cmd):\n    is_mod = has_explicit_mod = False\n"`.

Then make the fuzz's `--baseline` check compare explicit verdicts (Deviation 7). In `fuzz()`, replace

```python
                    verdict = is_file_mod(cmd) or redirect(cmd)
                    if base is not None and not verdict and (base(cmd) or redirect(cmd)):
```

with

```python
                    explicit = is_file_mod(cmd)
                    verdict = explicit or redirect(cmd)
                    # Explicit, not explicit-or-redirect: a redirect-only block is one the
                    # review-script exemption can lift, so an explicit block may not become one.
                    if base is not None and base(cmd) and not explicit:
```

The old condition is implied by the new one: `redirect(cmd)` is the same function on both sides, so "this allows, baseline-or-redirect blocks" can only mean "baseline `is_file_mod` blocks". The new condition also catches an explicit block that this branch makes redirect-only. The rest of the loop (the `regress += 1` and `no(...)` lines under it, and the `writes()` check) is unchanged.

- [ ] **Step 4: Run the #1085 suite and the gate suite.**

```bash
failed=0
for t in tests/test-cmdword-subst-comment-1085.sh tests/test-pre-implementation-gate.sh; do
  bash "$t" >/dev/null 2>&1 || { echo "FAIL $t"; failed=1; }
done
[ "$failed" -eq 0 ]
```

Expected: exit 0. A newly failing allow row is an over-block: read it against the Deviations before changing anything.

---

### Task 4: the #1093 suite

**Files:**
- Create: `tests/fixtures/heredoc_1093.py`
- Create: `tests/test-heredoc-body-1093.sh`
- Modify: `tests/test-gate-classifier-fail-closed.sh` (B11 and B12, inside the B10 block before its `rm -rf "$ARMD"`)

- [ ] **Step 1: the fixture.** Create `tests/fixtures/heredoc_1093.py`:

```python
#!/usr/bin/env python3
"""#1093 part 1 rows: writes hidden by a heredoc body must block; read-only controls must allow.

  heredoc_1093.py rows <armed-repo>

Each reproducer is first run under bash >= 5 in a scratch tree and must write (rm src/ or
create src/f). Each control must not write. Both then go through the real hook. Helpers come
from cmdword_1085.py next to this file.
"""
import os, shlex, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmdword_1085 as fx  # noqa: E402

SQ, BT = chr(39), chr(96)
q = shlex.quote
E2 = "cat <<E\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"
UNREADABLE = "cat <<E\nit's\nE\nrm -rf src\necho " + SQ
P19 = "echo x > src/f\necho " + SQ
DQ = "echo x > src/f\necho " + chr(34)
FIND = "find . -maxdepth 0 -exec bash -c "
R46 = 'bash -c "cat <""<E\nit\'s\nE\nrm -rf src\ncat <""<E2\ndon\'t\nE2"'

BLOCK = [
    ("R1 redirect after an apostrophe body", "cat <<E\nit's\nE\necho x > src/f\necho 'y'"),
    ("R2 R1 inside $( )", "v=$(cat <<E\nit's\nE\necho x > src/f\necho 'y'\n)"),
    ("R3 R1 with a comment", "cat <<E\nit's\nE\necho x > src/f # c\necho 'y'"),
    ("R4 R1 with a quoted delimiter", "cat <<'E'\nit's\nE\necho x > src/f\necho 'y'"),
    ("R10 ${v%)} closer in an expanding body", 'cat <<E\n: "$(echo ${v%)}; rm -rf src)"\nE'),
    ("R11 a second body re-closes the quote (#1101 item 4)", E2),
    ("R12 R11 inside $( )", "v=$(" + E2 + "\n)"),
    ("R13 R11 inside bash -c", "bash -c " + q(E2)),
    ("R14 R11 with a redirect", "cat <<E\nit's\nE\necho x > src/f\ncat <<E2\ndon't\nE2"),
    ("R15 redirect in a body $( ) after an apostrophe", "cat <<E\nit's $(echo x > src/f)\nE\necho 'y'"),
    ("R16 redirect in a body backtick after an apostrophe", "cat <<E\nit's `echo x > src/f`\nE\necho 'y'"),
    ("R22 R1 under <<- tab stripping", "cat <<-E\n\tit's\n\tE\necho x > src/f\necho 'y'"),
    ("R29 backtick split by a continuation after an apostrophe", "cat <<E\nit's `\\\necho x > src/f`\nE\necho 'y'"),
    ("R40 ${v#'...'} quotes a fake $( in a body", "cat <<E\necho it's ${v#'$(echo '} $(rm -rf src) ${v#')'} don't\nE"),
    ("R43 a review-script path in the body does not exempt R1",
     "cat <<E\nit's\nsh litmus/scripts/x\nE\necho x > src/f\necho 'y'"),
    ("R44 a write after a body the scan gives up on (K7's body)",
     "cat <<E\nit's ${v#'x'}\nE\necho x > src/f\necho 'y'"),
    # Design review round 1: a body give-up below depth 0, a quote-split `<<`, a lost body.
    ("R45 R40 inside $( )", "v=$(cat <<E\necho it's ${v#'$(echo '} $(rm -rf src) ${v#')'} don't\nE\n)"),
    ("R46 R13 with <\"\"< in a double-quoted program", R46),
    ("R47 a body give-up in a program, then a write main sees",
     "bash -c " + q("cat <<E\nit's ${v#'x'}\nsh litmus/scripts/x\nE\nv=$(echo ${v%)}; echo x > src/f)")),
    ("R48 R47's shape inside $( ), no review path",
     "v=$(cat <<E\nit's ${v#'x'}\nE\nv=$(echo ${v%)}; echo x > src/f)\necho 'y'\n)"),
    ("R49 R44 inside $( )", "v=$(cat <<E\nit's ${v#'x'}\nE\necho x > src/f\necho 'y'\n)"),
    # Round-6 regressions of the withdrawn unquoted-body join: a `<<` that is no heredoc.
    ("J1 $((1<<2)) before a quoted body", ": \"$(echo $((1<<2))\ncat <<'EE'\nE\\\nE\n)\nEE\nrm -rf src)\""),
    ("J2 # <<EOF before a quoted body", ": \"$(echo # <<EOF\ncat <<'EE'\nE\\\nE\n)\nEE\nrm -rf src)\""),
    ("J3 \"<<EOF \" at top level", "echo \"<<EOF \"\ncat <<'END'\nE\\\nND\nit's\nEND\nrm -rf src\ncat <<'E2'\ndon't\nE2"),
]
ALLOW = [
    ("C1 quoted-delimiter body, no write", "cat <<'E'\nit's\nE\necho 'y'"),
    ("C2 backticks in an unquoted body", 'printf "%s" "$(cat <<EOF\nUse `echo hi` and it\'s fine\nEOF\n)"'),
    ("C3 $(date) in an unquoted body", "cat <<EOF\nnow: $(date) it's\nEOF"),
    ("C4 ${v%)} in a body", "cat <<E\n${v%)} it's\nE\necho 'y'"),
    ("C5 two bodies, read-only", "cat <<A <<B\nit's\nA\ndon't\nB\necho 'ok'"),
    ("C6 <<- tab stripping, read-only", "cat <<-E\n\tit's\n\tE\necho 'y'"),
    ("C8 bash -c readable heredoc program", "bash -c " + q("echo hi; cat <<E\nit's\nE\necho ok")),
    ("C9 eval readable heredoc program", "eval " + q("cat <<E\nit's\nE\necho ok")),
    ("C10 cut body stays allowed", ': "$(echo ${v%)})"'),
    ("C11 escaped quote in $'...'", "echo $'it\\'s'"),
    ("C12 body then /dev/null", "cat <<E >/dev/null\nit's\nE\necho 'y'"),
    ("C15 quoted delimiter keeps a split terminator literal", "cat <<'EOF'\nit's\nE\\\nOF\nEOF\necho 'y'"),
    ("C16 readable program in a double-quoted $( )", ': "$(bash -c ' + q("echo hi\necho ok") + ')"'),
    ("C17 readable find -exec program", FIND + q("echo hi\necho ok") + " \\;"),
    ("C18 over-cap newline command, no heredoc", "echo " + "a" * 33000 + "\necho b"),
    ("C19 split $( in a body, read-only", "cat <<E\nit's $\\\n(date)\nE\necho 'y'"),
    ("C25 escaped $' in a body backtick is read unescaped", "cat <<E\n`echo \\$'it\\'s'`\nE"),
    ("C27 a review-script redirect is still exempt", "bash skills/litmus/scripts/none.sh > out.log"),
]
# Known allows: they write, and main allows them too. Fixing one fails its row: flip it to BLOCK.
KNOWN_ALLOW = [
    ("O1 comment apostrophe hides a redirect (#1101 item 3)", "# it's\necho x > src/f\necho 'y'"),
    ("O2 one-line program ending in a lone backslash (#1112)", "bash -c " + q("echo x > src/f; echo \\")),
    ("O3 ((true); subshells hide every later heredoc (#1113)",
     "((true); cat <<E\necho it's\nE\nrm -rf src\ncat <<E2\ndon't\nE2\n)"),
    ("O4 $(( ( (1)) << 2 )) read as a heredoc (#1113)",
     "cat <<E\nit's\nE\necho $(( ( (1)) << 2 ))\necho x > src/f\necho 'y'"),
    ("O5 a double quote opened on the <<EOF line (#1113)",
     "true <<EOF \"hello\nEOF\nworld\"\necho it's\nE\\\nOF\necho x > src/f\necho 'y'"),
    ("O6 a ${ opened on the <<E line (#1113)", "echo <<E ${v:-\nE\n}\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"),
    # #1093 members left to later parts.
    ("O7 bash -c program ending in an open quote (#1093 1b)", "bash -c " + q(UNREADABLE)),
    ("O8 bash -c redirect then an open quote (#1093 1b)", "bash -c " + q(P19)),
    ("O9 bash -c redirect then an open double quote (#1093 1b)", "bash -c " + q(DQ)),
    ("O10 O8 inside a double-quoted $( ) (#1093 1b)", ': "$(bash -c ' + q(P19) + ')"'),
    ("O11 find -exec O8 (#1093 1b)", FIND + q(P19) + " \\;"),
    ("O12 R1 behind a UTF-8 byte delimiter (#1093 3)", "cat <<$'E\\xc3\\xa9'\nit's\nEé\necho x > src/f\necho 'y'"),
    ("O13 terminator split by a continuation (#1093)", "cat <<EOF\nit's\nE\\\nOF\necho x > src/f\necho 'y'"),
    ("O14 $( split by a continuation (#1093)", "cat <<E\nit's $\\\n(echo x > src/f)\nE\necho 'y'"),
    # F8 matches a review-script path anywhere, body text included, as on main (Deviation 4).
    ("O15 a body's review-script path exempts a visible redirect", "cat <<E\nsh litmus/scripts/x\nE\necho x > src/f"),
]
# Known over-blocks, none writes. Fixing one fails its row: move it to ALLOW.
KNOWN_BLOCK = [
    ("K1 two read-only $( ) apostrophe bodies, as on main", "v=$(cat <<E\nit's\nE\necho ok\n)\n" * 2),
    ("K7 a quoted pattern in an expanding body (new, R40)", "cat <<E\nit's ${v#'x'}\nE\necho ok"),
    ("K9 K7 inside a program (new)", "bash -c " + q("cat <<E\nit's ${v#'x'}\nE\necho ok")),
    ("K8 UTF-8 delimiter in $( ), as on main (#1093 3)", ': "$(cat <<$\'E\\xc3\\xa9\'\nhi\nEé\n)"'),
    ("N1 25 identical $( ) spend the scan budget as on main",
     'echo "' + ("$(echo " + "x " * 200 + ") ") * 25 + '"'),
]


def nest(levels, fill):
    # Each level a heredoc and then a bash -c of the next; read-only throughout.
    prog = "cat <<E\nx\nE\necho " + "a" * fill + "\necho ok"
    for _ in range(levels):
        prog = "cat <<E\nx\nE\nbash -c " + q(prog)
    return prog


def switch_rows():
    """marker_check reads as on main: every new reading is off with the switch off."""
    sys.path.insert(0, fx.LIB)
    import shell_lex
    import cmdword

    def on(f, *a):
        shell_lex._cmdword_on[0] = True
        try:
            return f(*a)
        finally:
            shell_lex._cmdword_on[0] = False
    body = "cat <<E\n: $(rm -rf src) `tee x`\nE\n"
    spans = []
    checks = [
        ("expanding-body substitutions read (on)", on(shell_lex._subst_bodies, body) == (["rm -rf src", "tee x"], True)),
        ("expanding-body substitutions skipped as on main (off)", shell_lex._subst_bodies(body) == ([], True)),
        ("quoted-delimiter body never read (on)", on(shell_lex._subst_bodies, body.replace("<<E", "<<'E'")) == ([], True)),
        ("spans leave the result unchanged", shell_lex._subst_bodies(body, spans) == shell_lex._subst_bodies(body)),
        ("spans: joined text, operator, body", spans == [body, (4, 7), (8, len(body))]),
        ("heredoc_free cuts operator and body", cmdword.heredoc_free(body) == "cat \n"),
        ("heredoc_free restores the switch", shell_lex._cmdword_on[0] is False),
        ("heredoc_free: None without a heredoc", cmdword.heredoc_free("echo hi") is None),
        # Deviation 1: over the cap, a quote-split `<<` blocks before any reading runs.
        ("an over-cap <\"\"< program blocks", cmdword.is_file_mod(R46 + "\necho " + "a" * 40000)),
        ("an over-cap command with no heredoc shape does not", not cmdword.is_file_mod("echo " + "a" * 40000 + "\necho b")),
    ]
    # The ${...} recursion keeps the body's _arith_closes cache: characters rebuilt on a
    # cache miss stay linear in the body (round 1's recursion rebuilt it once per ${...}).
    b, orig, cost = "$((1))${a-$((1))}" * 400, shell_lex._arith_closes, [0]

    def counting(s, i):
        if shell_lex._paren_matches[0] is not s:
            cost[0] += len(s)
        return orig(s, i)
    shell_lex._arith_closes = counting
    try:
        scanned = on(shell_lex._heredoc_substs, b, [])
    finally:
        shell_lex._arith_closes = orig
    checks.append(("${...} recursion keeps the body's arithmetic cache (%d chars rebuilt)" % cost[0],
                   scanned and cost[0] < 3 * len(b)))
    for label, good in checks:
        fx.ok("switch: " + label) if good else fx.no("switch: " + label, "differs")


def rows(repo):
    switch_rows()
    for label, cmd in BLOCK:
        if not fx.writes(cmd):
            fx.no(label, "bash 5 did not write -- the row proves nothing")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "block" else fx.no(label, "hook said " + got)
    for label, cmd in ALLOW:
        if fx.writes(cmd):
            fx.no(label, "a control that writes")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "allow" else fx.no(label, "hook said " + got)
    for label, cmd in KNOWN_ALLOW:
        if not fx.writes(cmd):
            fx.no(label, "a known allow that does not write -- the row proves nothing")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "allow" else fx.no(label, "now %s: flip this row" % got)
    for label, cmd in KNOWN_BLOCK:
        if fx.writes(cmd):
            fx.no(label, "a known over-block that writes")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "block" else fx.no(label, "now %s: move this row to ALLOW" % got)
    # Three nested levels near the cap, read-only, allowed by main and here. Four is refused
    # by the gate-state helper scan before the design check runs, on main too.
    cmd = nest(3, 30000 - 120)
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of three nested heredoc programs allowed in %.2fs" % (len(cmd), dt)
    fx.ok(label) if got == "allow" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))
    # ${...} holding $(( )), repeated through one body: the inner scan keeps the cache.
    unit = "$((1))${a-$((1))}"
    cmd = "cat <" + "<E\n" + unit * ((fx.CAP - 80) // len(unit)) + "\nE\nrm -rf src"
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of ${a-$((1))} in one body then a write blocked in %.2fs" % (len(cmd), dt)
    fx.ok(label) if got == "block" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))
    # Body and top-level $(( )) alternating, under and over the cap, then a write.
    unit = ": $((1)) <" + "<E\n$((1))\nE\n"
    for size in (fx.CAP - 800, 64000):
        cmd = unit * (size // len(unit)) + "rm -rf src"
        got, dt = fx.hook(repo, cmd, timeout=10)
        label = "timing: %d chars of $(( )) bodies then a write blocked in %.2fs" % (len(cmd), dt)
        fx.ok(label) if got == "block" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "rows":
        print(__doc__)
        return 2
    fx.BASH = fx.bash5()
    rows(sys.argv[2])
    print("SUMMARY %d %d" % (fx.PASS, fx.FAIL))
    return 1 if fx.FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
```

Before relying on the `switch:` expectations, compute them once in a Python shell against the Task 1 code: `<<E` spans indices 4 to 7, the body 8 to the end, and `heredoc_free(body)` is `"cat \n"` (the newline after the operator stays). If one differs, the code is wrong, not the row.

- [ ] **Step 2: the suite.** Create `tests/test-heredoc-body-1093.sh`, mode 755:

```bash
#!/usr/bin/env bash
# #1093: writes hidden by reading inside a heredoc body were allowed while a design was
# pending. The checks live in tests/fixtures/heredoc_1093.py; this suite builds the repo.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
FIX="$ROOT/tests/fixtures/heredoc_1093.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

ARMED=""
trap 'rm -rf ${ARMED:+"$ARMED"}' EXIT
ARMED="$(mktemp -d)" || ARMED=""
[[ -n "$ARMED" && -d "$ARMED" ]] || { echo "  FAIL  mktemp -d"; exit 1; }
git -C "$ARMED" init -q
mkdir -p "$ARMED/docs/plans" "$ARMED/.claude" "$ARMED/src"
printf '# plan\n' >"$ARMED/docs/plans/thing.md"
bash "$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$ARMED/docs/plans/thing.md" >/dev/null 2>&1

# The fixture is only meaningful with a design pending: prove it, or every allow is vacuous.
case "$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"rm -rf src"}}' "$ARMED" \
        | (cd "$ARMED" && bash "$GATE") 2>/dev/null)" in
    *'"block"'*) ok "fixture: a design is pending in the armed repo" ;;
    *) no "fixture: a design is pending in the armed repo" "rm -rf src was allowed"
       printf '\n════ heredoc-body-1093: %d passed, %d failed ════\n' "$PASS" "$FAIL"; exit 1 ;;
esac

out="$(python3 -I "$FIX" rows "$ARMED" 2>&1)"
rc=$?
printf '%s\n' "$out" | grep -v '^SUMMARY '
sum="$(printf '%s\n' "$out" | grep '^SUMMARY ' | tail -1 || true)"
p=0 f=0
if [[ -n "$sum" ]]; then
    read -r _ p f <<<"$sum"
fi
PASS=$((PASS + p)); FAIL=$((FAIL + f))
if [[ -z "$sum" ]] || [[ $rc -ne 0 && $f -eq 0 ]]; then
    no "rows" "fixture exited $rc${sum:+ ($sum)}"
fi

printf '\n════ heredoc-body-1093: %d passed, %d failed ════\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 3: B11 and B12.** In `tests/test-gate-classifier-fail-closed.sh`, inside the B10 `else` branch and directly before its `rm -rf "$ARMD"`, add:

```bash
    # B11 (#1093): heredoc_free raises inside the gate redirect check. Same armed repo and
    # the same untouched-copy control as B10, then the injection.
    cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs11"
    got="$(vd "$WORK/gs11/pre-implementation-gate.sh")"
    if [[ "$got" == "allow" ]]; then ok "B11 control: copied tree allows ls -la with a design pending"
    else no "B11 control: copied tree allows ls -la with a design pending" "got=$got without the injection"; fi
    printf '\n\ndef heredoc_free(cmd):\n    raise RuntimeError("injected")\n' >>"$WORK/gs11/lib/cmdword.py"
    got="$(vd "$WORK/gs11/pre-implementation-gate.sh")"
    if [[ "$got" == "BLOCK" ]]; then ok "heredoc_free raises -> BLOCK"
    else no "heredoc_free raises -> BLOCK" "got=$got — an exception in the redirect check must block"; fi
    # B12 (#1093): cmdword imports but has no heredoc_free (a gate newer than its lib). R1,
    # a redirect hidden behind a body apostrophe, must still block.
    R1=$'cat <<E\nit\x27s\nE\necho x > src/f\necho \x27y\x27'
    cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs12"
    got="$(vd "$WORK/gs12/pre-implementation-gate.sh" "$R1")"
    if [[ "$got" == "BLOCK" ]]; then ok "B12 control: copied tree blocks R1"
    else no "B12 control: copied tree blocks R1" "got=$got without the injection"; fi
    perl -pi -e 's/^def heredoc_free\(/def _heredoc_free_removed(/' "$WORK/gs12/lib/cmdword.py"
    if grep -q '^def heredoc_free(' "$WORK/gs12/lib/cmdword.py"; then no "B12 injection" "heredoc_free still defined"
    else
        got="$(vd "$WORK/gs12/pre-implementation-gate.sh" "$R1")"
        if [[ "$got" == "BLOCK" ]]; then ok "no heredoc_free -> R1 still BLOCK"
        else no "no heredoc_free -> R1 still BLOCK" "got=$got — a missing helper must fail closed"; fi
    fi
```

- [ ] **Step 4: Run the three suites.**

```bash
failed=0
for t in tests/test-heredoc-body-1093.sh tests/test-gate-classifier-fail-closed.sh tests/test-cmdword-subst-comment-1085.sh; do
  bash "$t" >/dev/null 2>&1 || { echo "FAIL $t"; bash "$t" 2>&1 | grep FAIL; failed=1; }
done
[ "$failed" -eq 0 ]
```

Expected: exit 0, with every row `ok`:
- every BLOCK row writes and blocks, R43 (Deviation 4), R44 and R45 (a body the scan gives up on, Deviation 5), R46 (`<""<`, Deviation 1), and R47–R49 (round 1's regression and its `$( )` forms) included;
- every ALLOW row allows without writing, C27 included (F8 still exempts a plain review-script redirect);
- every KNOWN_ALLOW row writes and is still allowed;
- every KNOWN_BLOCK row is still blocked and does not write;
- every `switch:` check passes;
- the three-level nested timing row allows within the limit, and the `${a-$((1))}` body row and both `$(( ))` rows block within it;
- B11 and B12 block.

---

### Task 5: lock, full verification, commit

- [ ] **Step 1: regenerate the lock.** `./scripts/gate-integrity.sh --update && ./scripts/gate-integrity.sh --check`. Expected: `--check` exits 0.

- [ ] **Step 2: the #1085 fuzz at full size against the merge base.** It covers the **cmdword** half of "additive only": the fixture pairs the baseline `is_file_mod` with this branch's redirect check. The redirect half is additive by construction, because `texts` always includes `cmd`.

```bash
T="$(mktemp -d)" && mkdir -p "$T/base" && git archive "$(git merge-base HEAD origin/main)" hooks/gate-scripts/lib | tar -x -C "$T/base" \
  && git -C "$T" init -q && mkdir -p "$T/docs/plans" "$T/src" && printf '# plan\n' >"$T/docs/plans/p.md" \
  && bash hooks/gate-scripts/lib/resolve-repo-dir.sh arm "$T/docs/plans/p.md" >/dev/null 2>&1 \
  && python3 -I tests/fixtures/cmdword_1085.py fuzz "$T" --full --baseline "$T/base/hooks/gate-scripts/lib/cmdword.py"; rc=$?; rm -rf "$T"; [ "$rc" -eq 0 ]
```

Expected: `ok    fuzz: <about 38049> commands that write, none allowed, no block->allow vs baseline (full)`. Record the count in the PR description.

- [ ] **Step 3: full suites on UM.** Use `um-run` to run the full shell sweep (`scripts/ci/run-shell-tests.sh`), `npm test` and `scripts/test-python.sh`. Expected: all pass.

- [ ] **Step 4: the corpus check (local, not CI).**
  - **Input:** every distinct Bash command under 64 KiB in `~/.claude/projects/*/*.jsonl`.
  - **Classification only.** No corpus command is ever executed: they are past commands from real sessions, and replaying one can touch anything on this Mac.
  - **cmdword half:** each command goes through `cmdword.is_file_mod` and, separately, the gate's redirect check, once per revision (the merge base, then this branch), each in its own `python3 -I` process. Both verdicts are recorded per command (Deviation 7). The runner takes a tree `W`. For the merge base, `W` is a `git archive "$(git merge-base HEAD origin/main)"` extract. For this branch it is a copy of the **working tree**, made with `rsync -a --exclude .git --exclude __pycache__ ./ "$W/"`, because this step runs before the Step 5 commit and `git archive HEAD` would silently hand back the base code. It puts `W/hooks/gate-scripts/lib` and `W/tests/fixtures` first on `sys.path`, asserts that `cmdword.__file__` and `shell_lex.__file__` are under `W`, and takes the redirect check from `W`'s own `cmdword_1085.gate_redirect_check()`, which cuts it from `W`'s gate (on the merge base that block needs no `heredoc_free`; on this branch Task 3 Step 3 supplies it). An exception is recorded as such, never as an allow.
  - **marker_check half:** every command holding `<<` goes through `marker_check.py` from each lib, as the gate runs it.

  Expected:
  - **0 block→allow** in cmdword plus redirect, with no exception. Any one fails the check.
  - **0 explicit drops:** no command the base `is_file_mod` blocks is passed by this branch's `is_file_mod`, whatever the redirect check says.
  - **0 differing marker_check verdicts.**
  - Every allow→block printed and read. The prototype had 3, all real redirects after an apostrophe body. A new block of any other kind must be explained in the PR or fixed.

- [ ] **Step 5: commit** (litmus runs on it):

```bash
git add hooks/gate-scripts/lib/shell_lex.py hooks/gate-scripts/lib/cmdword.py hooks/gate-scripts/pre-implementation-gate.sh \
  .gate-integrity.lock tests/fixtures/cmdword_1085.py tests/fixtures/heredoc_1093.py tests/test-heredoc-body-1093.sh \
  tests/test-gate-classifier-fail-closed.sh docs/plans/2026-11-15-heredoc-free-pass-1093.md
git commit -m "fix(gate): read commands with their heredocs cut out (#1093, part 1)" \
  -m "Refs #1093: members 1a and 2 addressed; 1b, 3 and split terminators open. Refs #1101: item 4 addressed, items 1-3 open. Refs #1112, #1113: pinned as known allows." \
  -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: PR.** The body states the four changes, the Deviations, the fuzz count and the corpus result, and names #1093, #1101, #1112 and #1113 only with `Refs`, never next to a closing keyword. Comment on #1093 with what part 1 covers and what stays open (rows O7–O14), on #1101 that item 4 is addressed, and on #1113 adding row O6.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
