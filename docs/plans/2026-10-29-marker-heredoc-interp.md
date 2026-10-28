# #1052 Marker heredoc interpreter program: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Bash command that is only `[cd WORD &&] python3|node [- args] <<'D' … D` is no longer refused because of `NAME()`-shaped text in its program body. Nothing else about the marker gate's verdicts changes.

**Architecture:** Add a raw-string predicate `_stdin_program_only(cmd)` to `marker_check.py` that implements the spec's §2 grammar. At the indirection withdrawal site in `_helper_invoked`, split `_INDIRECTION_RE` into its `NAME()` header branch and the rest. When the predicate holds, the `NAME()` branch searches only the introducer line. Every other branch, and every other scan, keeps reading the full command. A new shell test file pins OK and BLOCK shapes by execution under bash and zsh. A scratch re-measure over the local transcript corpus checks acceptance.

**Tech Stack:** Python 3 (stdlib `re`), bash/zsh shell tests, `um-run` for the full suite.

**Global Constraints:**
- Spec: `docs/specs/2026-10-28-marker-heredoc-interp-design.md` (blueprint-review PASS, run f6c95b83). Where this plan resolves one of that review's 12 LOW notes differently from the spec text, the resolution is stated in "Review notes carried in" below and is always the stricter reading.
- Every commit that touches `hooks/gate-scripts/**` also stages `.gate-integrity.lock`, regenerated with `./scripts/gate-integrity.sh --update` (CLAUDE.md "Gate-Script Content Lock").
- No new dependencies. Python stdlib only.
- The literal helper name never appears in a shell command you run through the Bash tool, because the live hook refuses it. Tests build it from fragments (`"lease""_slot.py"`), as `tests/test-marker-1013-holes.sh` does.
- Never weaken an existing assertion. If an existing `tests/test-marker-*.sh` row changes verdict, stop and report it; do not edit that row.
- Commits use Conventional Commits and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Each `git commit` goes through the litmus pre-commit gate.

---

## Review notes carried in (the spec's 12 LOW findings)

| # | Note | Resolution in this plan |
|---|------|-------------------------|
| 1 | §1 says the introducer line has no `(`. False: a single-quoted WORD can hold `foo()`. | Stricter than the spec. When the predicate holds, `NAME()` still searches the **introducer line**, both raw and through `_norm_for_scan`, exactly as it reads a whole command today. It just doesn't search the body. `python3 - 'x;foo()' '/*' <<'E'` and `python3 - 'if${IFS}foo()' '/*' <<'E'` therefore keep their 3.0.12 BLOCK. Task 2. |
| 2 | §2a (one trailing empty element) and §2c (any later blank lines) disagree. | Use §2a: the terminator is the last line, optionally followed by one `\n`. Task 2. |
| 3 | `>/dev/null 2>&1` (two ERR tokens on one side) is outside the grammar. | Kept outside. Counted in the re-measure as shortfall bucket `err-pair`. Task 4. |
| 4 | Testing lists "an extra space form" as a near-miss, but the grammar allows one or more spaces. | Multiple spaces are accepted, as the grammar says. A **tab** separator is the near-miss pin. Task 3. |
| 5 | A decoy `<<"F"` inside a single-quoted WORD. | `D` comes only from named groups of one anchored `fullmatch` of line 1. A pin checks that the decoy does not terminate the body. Tasks 2–3. |
| 6 | A top-level `function foo(` line in a Node body still trips the `function NAME` branch. | Accepted, as the spec's Non-goals already accept `hash(` and `eval(`. Shortfall bucket `other-branch`. Task 4. The PR body names it. |
| 7 | The acceptance checker is one-way: it only checks that flips match §2. | The re-measure also lists every command where the independent checker says "matches §2" but the branch still says BLOCK, and classifies each one. Task 4. |
| 8 | The timing test covers no worst-case 64 KiB introducer line. | Add a ~58 KiB introducer line made of many short WORDs, and one made of a single long quoted WORD. Sizes stay under 60000 bytes to keep clear of the input cap. Only rows that stay within the scanner's token budget reach the predicate; the others bound the whole hook. Task 3. |
| 9 | §2d says stdout goes only to the Bash tool, which is false for `>/dev/null`. | The code comment says "to the Bash tool or /dev/null". Task 2. |
| 10 | When zsh is missing, zsh rows SKIP and the run still passes. | SKIPs are printed and counted. `REQUIRE_ZSH=1` turns any SKIP into a FAIL. The local evidence run in Task 5 uses it. Task 3. |
| 11 | The spec does not say which copy of the command the predicate reads. | Each `_helper_invoked` call reads its own `cmd`. Safe, because the top-level call on the raw command still searches the whole command unless the raw command matches. Task 2 comment. |
| 12 | Every grammar near-miss keeps its 3.0.12 verdict. | Asserted by the re-measure (zero OK→BLOCK) and by near-miss pins. Tasks 3–4. |

## UltraOracle plan advisory (2026-10-29, auxiliary)

What was adopted from it:
- the heredoc corpus, so an OK→BLOCK regression is observable on commands that were never refused;
- a corpus frozen once and reused on both sides;
- a one-way checker implication, and a checker that tokenizes instead of reusing the gate regex;
- `<< 'E'` and a leading space as the concrete "spacing" near-misses;
- verifying each near-miss's 3.0.12 verdict before pinning it;
- exclusive shortfall buckets, and stating that the 78 comparison is by count only.

What was not adopted:
- Fixtures before the gate change. Instead, Task 3 proves the OK pins against a disabled predicate, which gives the same evidence with one fewer commit.
- Committing the re-measure report. It reads private transcripts, so it lives in the scratchpad and its summary goes in the PR body.

---

## File Structure

- **Modify:** `hooks/gate-scripts/lib/marker_check.py`
  - Lines 3942–3982 (`_INDIRECTION_RE`): split into `_FUNC_HEADER_RE` and `_INDIRECTION_OTHER_RE`.
  - New `_STDIN_PROGRAM_LINE_RE` and `_stdin_program_only()` right after them.
  - Lines ~6183–6208 (withdrawal site): use the split.
- **Modify:** `hooks/gate-scripts/lib/cmdword.py`, near line 421 (`_has_indirection`): comment only, recording the deliberate asymmetry.
- **Modify:** `.gate-integrity.lock` (regenerated).
- **Create:** `tests/test-marker-heredoc-interp-1052.sh`. CI discovers it through the full `tests/test-*.sh` glob in `scripts/ci/run-shell-tests.sh`; nothing to register.
- **Scratch, not committed:** `$SCRATCHPAD/b1052/` holds the corpus, baseline tree and re-measure scripts. `$SCRATCHPAD` is the session scratchpad directory.

---

### Task 1: Rebuild the corpus and record the 3.0.12 baseline

**Files:**
- Create (scratch): `$SCRATCHPAD/b1052/extract.py`, `$SCRATCHPAD/b1052/classify.py`, `$SCRATCHPAD/b1052/corpus.json`, `$SCRATCHPAD/b1052/base.json`
- Create (scratch): `$SCRATCHPAD/b1052/base/` (3.0.12 classifier tree)

**Interfaces:**
- Produces: `corpus.json`, a JSON list of distinct command strings. `classify.py <libdir> <corpus.json> <out.json>` writes `{command: verdict_line}`.

No behaviour change and no commit. This task exists so the baseline is fixed before any gate edit.

- [ ] **Export the 3.0.12 classifier**

```bash
S="${SCRATCHPAD:?export SCRATCHPAD=<this session's scratchpad dir>}/b1052"
mkdir -p "$S/base" && git archive b623af3e hooks/gate-scripts/lib | tar -x -C "$S/base"
ls "$S/base/hooks/gate-scripts/lib/marker_check.py"
```

Expected: the path is printed.

- [ ] **Write `extract.py`.** It collects every Bash command whose tool result carries the marker gate's block message.

```python
#!/usr/bin/env python3
"""Distinct Bash commands the marker gate refused, from local Claude transcripts."""
import glob, json, os, sys

BLOCK = "BLOCKED: Cannot call "
cmds = {}  # tool_use_id -> command
refused = set()
for path in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for line in fh:
            if '"tool_use"' not in line and BLOCK not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            content = (rec.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "tool_use" and item.get("name") == "Bash":
                    c = (item.get("input") or {}).get("command")
                    if isinstance(c, str):
                        cmds[item.get("id")] = c
                elif item.get("type") == "tool_result":
                    text = json.dumps(item.get("content"))
                    if BLOCK in text and "directly" in text:
                        refused.add(item.get("tool_use_id"))
out = sorted({cmds[i] for i in refused if i in cmds})
json.dump(out, open(sys.argv[1], "w"), indent=0)
print(len(out), "distinct refused commands")
# Second corpus: every distinct Bash command with a heredoc, refused or not. Most were never
# refused, so it is where an OK->BLOCK regression would show.
hd = sorted({c for c in cmds.values() if "<<" in c} - set(out))
json.dump(hd, open(sys.argv[2], "w"), indent=0)
print(len(hd), "distinct other heredoc commands")
```

- [ ] **Write `classify.py`.** It runs one classifier tree over the corpus, using the same payload shape as `verdict()` in `tests/test-marker-1013-holes.sh`.

```python
#!/usr/bin/env python3
"""classify.py <repo-root-with-hooks/gate-scripts/lib> <corpus.json> <out.json>"""
import json, os, subprocess, sys

root, corpus, out = sys.argv[1:4]
clf = os.path.join(root, "hooks/gate-scripts/lib/marker_check.py")
res = {}
for c in json.load(open(corpus)):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": c}})
    try:
        p = subprocess.run([sys.executable, "-I", clf], input=payload, capture_output=True,
                           text=True, timeout=60)
        res[c] = p.stdout.strip() if p.returncode == 0 else "ERROR"
    except subprocess.TimeoutExpired:
        res[c] = "TIMEOUT"
json.dump(res, open(out, "w"), indent=0)
print(sum(v.startswith("BLOCK") for v in res.values()), "BLOCK of", len(res))
```

- [ ] **Run both scripts**

```bash
S="${SCRATCHPAD:?export SCRATCHPAD=<this session's scratchpad dir>}/b1052"
python3 -I "$S/extract.py" "$S/corpus.json" "$S/heredoc.json"
python3 -I "$S/classify.py" "$S/base" "$S/corpus.json" "$S/base.json"
python3 -I "$S/classify.py" "$S/base" "$S/heredoc.json" "$S/base-hd.json"
```

Expected:
- the refused corpus has several hundred commands (659 in October; more is fine, since transcripts grow), and the heredoc corpus has more;
- a BLOCK count is printed;
- there is no `ERROR` or `TIMEOUT` (check with `grep -c '"ERROR"\|"TIMEOUT"' "$S/base.json"`, which should print 0).

Record both counts for the PR body.

---

### Task 2: Gate change — split the trigger and add the predicate

**Files:**
- Modify: `hooks/gate-scripts/lib/marker_check.py:3942-3982` and `:6183-6208`
- Modify: `hooks/gate-scripts/lib/cmdword.py:421` (comment)
- Modify: `.gate-integrity.lock`

**Interfaces:**
- Produces: `_FUNC_HEADER_RE`, `_INDIRECTION_OTHER_RE`, `_STDIN_PROGRAM_LINE_RE` (compiled patterns), and `_stdin_program_only(cmd: str) -> str | None`. The function returns the introducer line when the whole command is the §2 shape, else `None`.

- [ ] **Split `_INDIRECTION_RE`.** In `marker_check.py`, replace the opening of the assignment at line 3942:

```python
_INDIRECTION_RE = re.compile(
    r"(?:^|[\n;&|{()]\s*|" + _CMD_POS_WORDS + r"\s*)"
    + _ASSIGN_NOT_FUNC + _FUNC_NAME + r"\s*\(\s*\)"
    r"|" + _CMD_POS + r"function\s+" + _FUNC_NAME
```

with:

```python
# The NAME() header is its own pattern so #1052's stdin-program shape can narrow what it
# reads (see _stdin_program_only); every other branch below still reads the whole command.
_FUNC_HEADER_SRC = (r"(?:^|[\n;&|{()]\s*|" + _CMD_POS_WORDS + r"\s*)"
                    + _ASSIGN_NOT_FUNC + _FUNC_NAME + r"\s*\(\s*\)")
_FUNC_HEADER_RE = re.compile(_FUNC_HEADER_SRC)
_INDIRECTION_OTHER_RE = re.compile(
    _CMD_POS + r"function\s+" + _FUNC_NAME
```

Then, at the end of that expression (line ~3982), after the `BASH_CMDS` branch's closing `)`, add:

```python
_INDIRECTION_RE = re.compile(_FUNC_HEADER_SRC + r"|" + _INDIRECTION_OTHER_RE.pattern)
```

`_INDIRECTION_RE` is kept unchanged in meaning; nothing in `marker_check.py` reads it after this task, but the `KEEP IN STEP WITH` comments in `cmdword.py` refer to it by name. Leave every existing comment inside the expression where it is. The `function` branch's comment block moves with it.

`marker_check.py` is a script: it reads its JSON payload from stdin at module level (line ~7059), so it cannot be imported for a unit check. Every behavioural check in this plan goes through the CLI, as `verdict()` does.

The split is a pure rearrangement. The plan-review arbiter rebuilt it on a scratch copy and found the pattern and flags identical to 3.0.12's. Its behavioural proof is that every existing `tests/test-marker-*.sh` row keeps its verdict (step below).

- [ ] **Add the predicate** directly below the new `_INDIRECTION_RE` line:

```python
# #1052 (docs/specs/2026-10-28-marker-heredoc-interp-design.md §2): a command that is ONLY
#   [cd WORD &&] python|python2|python3|python2.N[t]|python3.N[t]|node [- WORD...] [ERR] <<'D' [ERR]
#   <body>
#   D
# runs its body as that interpreter's PROGRAM, so NAME()-shaped text in the body (a method
# call such as `open(f).read()`) is not a shell function definition. A positive grammar over
# the RAW string, not a list of exclusions: three review rounds each found a new
# same-command construct (sourcing, fd prefixes, exec/coproc output, zsh tables) that a
# list missed, and with nothing but this line in the command none of them can occur.
# Stdout goes to the Bash tool or /dev/null. RESIDUAL (ADR 0006): what the receiver or `cd`
# resolves to is set by the environment outside the command, and the program itself can
# build and run anything -- already true on 3.0.12 for a body without NAME() text.
# Each _helper_invoked call asks this of its OWN cmd; the top-level call on the raw command
# still searches everything unless the raw command itself matches.
_SP_WORD = r"(?:[A-Za-z0-9_./:@%+,-][A-Za-z0-9_./:@%+,=-]*|'[^'\n]*')"
_SP_ERR = r"(?:2>&1|2>/dev/null|>/dev/null)"
_SP_DELIM = r"[A-Za-z_][A-Za-z0-9_]*"
_STDIN_PROGRAM_LINE_RE = re.compile(
    r"(?:cd +" + _SP_WORD + r" +&& +)?"
    r"(?:python[23]?|python[23]\.[0-9]+t?|node)"
    r"(?: +-(?: +" + _SP_WORD + r")*)?"
    r"(?: +" + _SP_ERR + r")?"
    r" +<<(?:'(?P<sq>" + _SP_DELIM + r")'|\"(?P<dq>" + _SP_DELIM + r")\"|\\(?P<bs>"
    + _SP_DELIM + r"))"
    r"(?: +" + _SP_ERR + r")?")


def _stdin_program_only(cmd):
    """The introducer line when CMD is exactly the #1052 shape, else None."""
    if "<<" not in cmd:
        return None
    lines = cmd.split("\n")
    m = _STDIN_PROGRAM_LINE_RE.fullmatch(lines[0])
    if m is None:
        return None
    # D only from the anchored match, never from a later `<<` (a quoted WORD can hold one).
    delim = m.group("sq") or m.group("dq") or m.group("bs")
    try:
        end = lines.index(delim, 1)  # first line equal to D: where both shells end the body
    except ValueError:
        return None
    if end == len(lines) - 1 or (end == len(lines) - 2 and lines[-1] == ""):
        return lines[0]
    return None
```

- [ ] **Use it at the withdrawal site.** Replace, at line ~6208:

```python
    if any(_INDIRECTION_RE.search(_v)
           for _text in (cmd, _norm_for_scan(cmd))
           for _v in _shell_variants(_text)):
```

with:

```python
    # #1052: for the stdin-program shape the NAME() header reads only the introducer line
    # (a quoted argument there can still hold NAME() text); every other branch reads all.
    _intro = _stdin_program_only(cmd)
    _header_src = cmd if _intro is None else _intro
    # Both readings, as today: the normalized one restores `${IFS}` and rejoins continuations,
    # so `'if${IFS}foo()'` in a quoted argument is still seen.
    _header_texts = (_header_src, _norm_for_scan(_header_src))
    if (any(_FUNC_HEADER_RE.search(_v)
            for _text in _header_texts
            for _v in _shell_variants(_text))
            or any(_INDIRECTION_OTHER_RE.search(_v)
                   for _text in (cmd, _norm_for_scan(cmd))
                   for _v in _shell_variants(_text))):
```

- [ ] **Record the asymmetry in `cmdword.py`.** Add these lines immediately above `def _has_indirection(cmd):` (line 421):

```python
# DELIBERATE ASYMMETRY with marker_check (#1052): marker_check lets the NAME() header read
# only the introducer line of a `python3|node [-] <<'D'` stdin-program command. This copy
# feeds is_file_mod, which blocks only while a design review is pending, and keeps reading
# the whole command. Revisit if a file-mod over-block of that shape is reported.
```

The predicate's accept/reject behaviour is pinned through the CLI in Task 3. Before the plan was reviewed, its regex was cross-checked against `check_shape.py` (Task 4) on 23 shapes, and the two agreed on all 23.

- [ ] **Run the existing marker suites**

```bash
rc=0; for t in tests/test-marker-*.sh; do bash "$t" >/tmp/o.$$ 2>&1 || { rc=1; echo "FAIL $t"; tail -20 /tmp/o.$$; }; done; rm -f /tmp/o.$$; echo "rc=$rc"; [ $rc -eq 0 ]
```

Expected: `rc=0` and exit status 0. A failing existing row is a stop condition (Global Constraints).

- [ ] **Regenerate the lock and commit**

```bash
./scripts/gate-integrity.sh --update
git add hooks/gate-scripts/lib/marker_check.py hooks/gate-scripts/lib/cmdword.py .gate-integrity.lock
git commit -m "fix(gate): read only the introducer line for NAME() in a stdin-program heredoc command (#1052)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Shell test file

**Files:**
- Create: `tests/test-marker-heredoc-interp-1052.sh`

**Interfaces:**
- Consumes: the gate behaviour from Task 2, observed only through `marker_check.py`'s stdout (`OK|` or `BLOCK_*`).

- [ ] **Write the harness and benign pins.** The file starts with the following. Its helpers mirror `tests/test-marker-1013-holes.sh`, with three additions: per-shell execution, OK rows that prove the interpreter ran the body, and a SKIP count.

```bash
#!/usr/bin/env bash
# #1052: a command that is ONLY `[cd W &&] python3|node [- args] <<'D' <body> D` runs the body
# as the interpreter's program, so NAME()-shaped text there (a method call) must not withdraw
# the mention contract. Spec: docs/specs/2026-10-28-marker-heredoc-interp-design.md.
#
# Row types:
#   assert_ok          -- classifies OK, AND executing it runs the interpreter body (it writes
#                         a sentinel) without running the stub helper.
#   assert_block       -- executing it under each named shell runs the stub (a marker file,
#                         not an exit status), AND it classifies BLOCK.
#   assert_block_noexec -- a deliberate over-block that does not execute; must classify BLOCK.
# A row whose shell or interpreter is missing prints SKIP and is counted; REQUIRE_ZSH=1 (and
# REQUIRE_NODE=1) turn a SKIP into a FAIL. The helper name is assembled from fragments
# because the live hook refuses a Bash call that spells it.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0 FAIL=0 SKIP=0
TO=(perl -e 'alarm shift; exec @ARGV or exit 127' 60)
command -v timeout >/dev/null 2>&1 && TO=(timeout 60)
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }
skip() {
    if [[ "${REQUIRE_ZSH:-0}" == 1 && "$2" == zsh ]] || [[ "${REQUIRE_NODE:-0}" == 1 && "$2" == node ]]; then
        no "$1" "$2 is required but missing"
    else
        SKIP=$((SKIP + 1)); printf '  SKIP  %s (%s missing)\n' "$1" "$2"
    fi
}

verdict() { # <command> -> the verdict line, or ERROR
    local payload out
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    if out=$(${TO[@]+"${TO[@]}"} python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
        printf '%s' "$out"
    else
        printf 'ERROR'
    fi
}

LIBDIR="hooks/gate-scripts/lib"
NAME="lease""_slot.py"
H="$LIBDIR/$NAME"
G="$LIBDIR/lease""_slo?.py"

SCRATCH="$(mktemp -d)" || SCRATCH=""
[[ -n "$SCRATCH" && -d "$SCRATCH" ]] || { echo "FAIL: mktemp -d" >&2; exit 1; }
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/$LIBDIR" "$SCRATCH/dir"
printf '#!/usr/bin/env python3\nimport sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$SCRATCH/$H"
chmod +x "$SCRATCH/$H"

run_in() { # <shell> <command> -- run in the scratch tree, never fail the harness
    (cd "$SCRATCH" && env -u A -u X ${TO[@]+"${TO[@]}"} "$1" -c "$2" >/dev/null 2>&1) || true
}

assert_ok() { # <command> <label> <interpreter binary the row needs> -- executed under bash and zsh
    local got sh
    if ! command -v "$3" >/dev/null 2>&1; then skip "$2" "$3"; return; fi
    for sh in bash zsh; do
        if ! command -v "$sh" >/dev/null 2>&1; then skip "$2 [$sh]" "$sh"; continue; fi
        rm -f "$SCRATCH/$H.ran" "$SCRATCH/body.ran" "$SCRATCH/dir/body.ran"
        run_in "$sh" "$1"
        if [[ -f "$SCRATCH/$H.ran" ]]; then no "$2 [$sh]" "control executes the helper"; return; fi
        if [[ ! -f "$SCRATCH/body.ran" && ! -f "$SCRATCH/dir/body.ran" ]]; then
            no "$2 [$sh]" "the interpreter body did not run -- the row proves nothing"; return
        fi
    done
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} -- refused"; fi
}

assert_block() { # <command> <label> [shells: "bash zsh" | bash | zsh; default bash]
    local sh got ran=0
    for sh in ${3:-bash}; do
        if ! command -v "$sh" >/dev/null 2>&1; then skip "$2 [$sh]" "$sh"; continue; fi
        rm -f "$SCRATCH/$H.ran"
        run_in "$sh" "$1"
        if [[ -f "$SCRATCH/$H.ran" ]]; then ran=1; else
            no "$2 [$sh]" "fixture does not execute the helper under $sh -- it proves nothing"; return
        fi
    done
    [[ $ran == 1 ]] || return
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then no "$2" "got=$got -- the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- a real invocation was allowed"; fi
}

assert_block_noexec() { # <command> <label> -- deliberate over-block, not executed
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* && "$got" != BLOCK_CLASSIFIER_ERROR* ]]; then ok "$2"
    else no "$2" "got=${got:-<empty>} -- expected the 3.0.12 over-block"; fi
}

# Bodies with an empty-paren method call (the NAME() shape), an ordinary glob, and a sentinel
# proving the body ran. With the predicate disabled, rows using them must come back BLOCK
# (checked in the mutation step below); that is what makes them guards.
# The helper GLOB in a string is what 3.0.12's probe matches once NAME() withdraws the
# contract; without it a row can be OK on 3.0.12 already and guard nothing.
PYB="import glob
p = 'body.ran'
open(p, 'w').write(open('/etc/hosts').read()[:1])
print(glob.glob('/*'), 'a.b'.split('.'), '$G')"
JSB="const fs = require('fs');
fs.writeFileSync('body.ran', 'x');
console.log(process.cwd(), process.argv.slice(2));
console.log('$G');"

echo "=== #1052: the stdin-program shape is OK ==="
assert_ok "python3 - <<'E'
$PYB
E" "python3 - <<'E'" python3
assert_ok "python3 <<'E'
$PYB
E" "python3 <<'E' (no -)" python3
assert_ok "python3 - a b <<'E'
$PYB
E" "python3 - with argv" python3
assert_ok "python3  -  <<'E'
$PYB
E" "multiple spaces between tokens" python3
assert_ok "cd dir && python3 - <<'E'
$PYB
E" "cd WORD && python3 -" python3
assert_ok "python3 - 2>&1 <<\"E\"
$PYB
E" "2>&1 and a double-quoted delimiter" python3
assert_ok "python3 - <<\\E >/dev/null
$PYB
E" "backslash delimiter and >/dev/null" python3
assert_ok "python3 - <<'E'
#!/bin/sh
$PYB
E" "a #! first body line is a Python comment" python3
assert_ok "python3 - '<<\"F\"' <<'E'
$PYB
F
E" "decoy <<\"F\" in a quoted argv word does not end the body" python3
assert_ok "python - <<'E'
$PYB
E" "python receiver" python
assert_ok "python2 - <<'E'
$PYB
E" "python2 receiver" python2
PY3N="python3.$(python3 -c 'import sys;print(sys.version_info[1])')"
assert_ok "$PY3N - <<'E'
$PYB
E" "python3.N receiver" "$PY3N"
assert_ok "python3 - <<'E'
s = '\`date\` and \$(date) and \${x}'
$PYB
E" "backtick, \$( and \${ inside a quoted body" python3
assert_ok "node - a <<'E'
$JSB
E" "node - <<'E'" node
assert_ok "node <<'E'
#!/bin/sh
$JSB
E" "node, #! first body line is a JS comment" node

echo "=== #1052: grammar near-misses keep their 3.0.12 BLOCK ==="
# Each row below is BLOCK on 3.0.12 because the body holds NAME() text and a helper glob.
# A near-miss keeps whatever 3.0.12 says; if that is OK, the row does not belong here.
NM_BODY="x = open(p).read()
print('$G')"
NL=$'\n' CR=$'\r'
assert_block_noexec "python3	- <<'E'
$NM_BODY
E" "tab separator"
assert_block_noexec "python3 - << 'E'
$NM_BODY
E" "space between << and the delimiter (review note 4)"
assert_block_noexec " python3 - <<'E'
$NM_BODY
E" "leading space on the introducer line"
assert_block_noexec "python3 -u - <<'E'
$NM_BODY
E" "an interpreter option"
assert_block_noexec "/usr/bin/python3 - <<'E'
$NM_BODY
E" "path-qualified receiver"
assert_block_noexec "python3-config - <<'E'
$NM_BODY
E" "suffixed receiver name"
assert_block_noexec "python3 - <<E
$NM_BODY
E" "unquoted delimiter"
assert_block_noexec "python3 - <<-'E'
$NM_BODY
E" "<<- operator"
assert_block_noexec "python3 - 0<<'E'
$NM_BODY
E" "descriptor prefix"
assert_block_noexec "python3 - <<'E' > out.txt
$NM_BODY
E" "file redirection"
assert_block_noexec "python3 - >/dev/null 2>&1 <<'E'
$NM_BODY
E" "two ERR tokens on one side (review note 3)"
assert_block_noexec "python3 - <<'E'${NL}${NM_BODY}${NL}E${NL}${NL}" "a second trailing newline (review note 2)"
assert_block_noexec "python3 - <<'E'${CR}${NL}${NM_BODY}${CR}${NL}E${CR}" "CRLF line endings"
assert_block_noexec "python3 - 'x;foo()' '$G' <<'E'
print(1)
E" "NAME() text in a quoted argv word still triggers (review note 1)"
assert_block_noexec "python3 - 'if\${IFS}foo()' '$G' <<'E'
print(1)
E" "NAME() behind \${IFS} in a quoted argv word still triggers (normalized reading)"

echo "=== #1052: the OTHER indirection branches still read the whole body ==="
# These commands MATCH §2, so only the non-NAME() branches can block them. They pin that
# _INDIRECTION_OTHER_RE keeps reading the full command (spec §1), via the second mutation
# step below. (`eval(` is not here: the eval branch's lookahead excludes `(`, so it never
# fired on `eval(` -- on 3.0.12 either.)
assert_block_noexec "python3 - <<'E'
x = hash(p)
print('$G')
E" "hash in a qualifying body still triggers"
assert_block_noexec "node - <<'E'
function foo() { return 1; }
console.log('$G');
E" "function NAME in a qualifying node body still triggers"
assert_block_noexec "python3 - <<'E'
alias = 1
print('$G')
E" "alias in a qualifying body still triggers"
assert_block_noexec "python3 - <<'E'
s = 'BASH_CMDS[x]'
print('$G')
E" "BASH_CMDS[ in a qualifying body still triggers"
assert_block_noexec "python3 - <<'E'
$NM_BODY
E
echo done" "a line after the terminator"
assert_block_noexec "python3 - <<'E'
$NM_BODY
E
E" "the FIRST line equal to D ends the body; a second D line is trailing text"
```

- [ ] **Add the executing BLOCK pins for review classes.** Append a section `echo "=== #1052: classes found in review keep their 3.0.12 BLOCK ==="` with one `assert_block` row per class below.

  Each fixture must meet four conditions:
  - it is the shortest command that contains the class, a `NAME()` in a Python body, and a helper reach;
  - it actually runs the stub under each listed shell;
  - it is BLOCK on 3.0.12. Check this before adding the row by classifying it with the base tree from Task 1, `$S/base/hooks/gate-scripts/lib/marker_check.py`, where `$S` is the Task 1 scratch directory. The test file's `$SCRATCH` is a different, per-run temp dir;
  - it does not match §2.

  Concrete fixture text is written here and reviewed by litmus, not in this plan. The operator made that decision on 2026-10-28: adversarial fixtures live in the test file. Take each concrete form from the verdicts that confirmed it, in `docs/reviews/marker-heredoc-interp-design/attempts/001-89ec41a1/claude.json` (iteration 3) and `follow-up-issues.md`.

  | Class | Shells |
  |---|---|
  | allowlisted interpreter in a form that does not read the program from stdin (inline-program flag, module flag, script argument) | bash zsh |
  | perl receiver whose body hands itself to another program by its first line | bash zsh |
  | heredoc attached to a `{ …; }` group | bash zsh |
  | function definition outside the body, after a qualifying heredoc | bash zsh |
  | two heredocs queued on one line, the first non-qualifying | bash zsh |
  | heredoc on a non-zero descriptor | bash |
  | receiver output piped into a shell | bash zsh |
  | same-command source of a file that redefines the receiver | bash zsh |
  | zsh writable command table re-pointing the receiver | zsh |
  | zsh autoload of the receiver | zsh |
  | output channel to a shell set up by `exec`, a coprocess or a process substitution | bash zsh |
  | heredoc inside backticks with an escaped delimiter | bash zsh |

  Also add:
  - `assert_block` with the helper name spelled literally inside a qualifying Python body that runs it;
  - the existing "a heredoc written to a file, then run" pin, copied verbatim from `tests/test-marker-1013-holes.sh:148-151`.

- [ ] **Add the residual pin.** It is a comment block plus one `assert_ok`-style verdict check. The pin is a Node stdin program with no `NAME()` text that writes a script and runs it with `sh`, and it classifies OK on 3.0.12 and on the branch (spec §3). Check the 3.0.12 side with the base tree from Task 1. The comment says it is the ADR 0006 / §3 residual and not a fix target. Do not assert BLOCK.

- [ ] **Add the timing checks** (review note 8). The plan review measured that any command whose body is over about 15 KiB returns `BLOCK_UNSCANNABLE` on both 3.0.12 and the branch, because the scanner's token budget runs out. The ~58 KiB rows therefore bound the whole hook, not the predicate on its own. The 12 KiB row is the one that reaches the predicate and must come back OK. Sizes stay under 60000 bytes so they are clear of any 64 KiB input cap. Each body is joined to its terminator with `$'\n'`, because `$(…)` strips the trailing newline.

```bash
echo "=== #1052: bounded time on large inputs ==="
timed() { # <command> <label> -- classifies within 1s, to a real verdict
    local s e got
    s=$(python3 -c 'import time;print(time.monotonic())')
    got="$(verdict "$1")"
    e=$(python3 -c 'import time;print(time.monotonic())')
    if [[ "$got" != "OK|" && ( "$got" != BLOCK_* || "$got" == BLOCK_CLASSIFIER_ERROR* ) ]]; then
        no "$2" "no verdict: got=${got:-<empty>}"
    elif python3 -c "import sys;sys.exit(0 if $e - $s < 1.0 else 1)"; then ok "$2"
    else no "$2" "took $(python3 -c "print(round($e - $s, 2))")s"; fi
}
MID="$(python3 -c 'print("x = open(p).read()\n" * 640, end="")')"$'\n'"print('$G')"  # ~12 KiB, BLOCK on 3.0.12
BIG="$(python3 -c 'print("x = open(p).read()\n" * 3100, end="")')"    # ~58 KiB
WORDS="$(python3 -c 'print("a " * 29000, end="")')"                   # ~58 KiB
ONE="$(python3 -c 'print("a" * 58000, end="")')"
got="$(verdict "python3 - <<'E'${NL}${MID}${NL}E")"
if [[ "$got" == "OK|" ]]; then ok "12 KiB accepted body classifies OK"
else no "12 KiB accepted body classifies OK" "got=${got:-<empty>}"; fi
timed "python3 - <<'E'${NL}${MID}${NL}E" "12 KiB accepted body"
timed "python3 - <<'E'${NL}${BIG}${NL}E" "58 KiB accepted body"
timed "python3 -u - <<'E'${NL}${BIG}${NL}E" "58 KiB near-miss body"
timed "python3 - ${WORDS}<<'E'${NL}x${NL}E" "58 KiB introducer of short words"
timed "python3 - '${ONE}' <<'E'${NL}x${NL}E" "58 KiB introducer of one quoted word"
timed "python3 - ${WORDS}<<x${NL}x" "58 KiB introducer, failing at the delimiter"
```

If the 12 KiB row is not OK, find the largest body that is OK on the branch by halving, and use that size instead. Record the size in the row label. Do not raise any scanner budget.

  `verdict` includes interpreter start-up, so 1 s is a ceiling on the whole hook rather than on the predicate alone. If a run shows start-up is over 0.5 s on this machine, report that rather than raising the bound.

- [ ] **Close the file**

```bash
echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[[ $FAIL -eq 0 ]]
```

- [ ] **Run it, locally, with zsh and node required**

```bash
chmod +x tests/test-marker-heredoc-interp-1052.sh
REQUIRE_ZSH=1 REQUIRE_NODE=1 bash tests/test-marker-heredoc-interp-1052.sh
```

Expected: last line `passed: N  failed: 0  skipped: K`, where K counts only the `python`, `python2` and `python3.N` receiver rows, and only when that binary is absent. zsh and node are required, so they never SKIP here.

- [ ] **Prove the OK pins guard something.** Temporarily make `_stdin_program_only` return `None` on its first line, then re-run the file. The rows that must FAIL, and only these, are:
  - every `assert_ok` row, with a refused verdict;
  - "12 KiB accepted body classifies OK".

  Everything else must still pass, including the residual pin, which stays OK.

  Then restore the function. `git diff --stat hooks/` must print nothing, because Task 2 is already committed. Re-run the file to green.

- [ ] **Prove the other branches still read the whole command.** Temporarily change the second `for _text in (cmd, _norm_for_scan(cmd))` in the withdrawal-site condition (the one under `_INDIRECTION_OTHER_RE`) to `for _text in _header_texts`. Then re-run the file. The four rows in "the OTHER indirection branches still read the whole body" must FAIL, and every other row must still pass. Restore the line. `git diff --stat hooks/` must print nothing. Re-run the file to green. Before adding the four rows, confirm each is BLOCK on 3.0.12 using the Task 1 base tree.

- [ ] **ShellCheck and commit**

```bash
shellcheck -S warning tests/test-marker-heredoc-interp-1052.sh
git add tests/test-marker-heredoc-interp-1052.sh
git commit -m "test(gate): pin the #1052 stdin-program heredoc shape and the review classes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Corpus re-measure and acceptance

**Files:**
- Create (scratch): `$SCRATCHPAD/b1052/check_shape.py`, `$SCRATCHPAD/b1052/branch.json`, `$SCRATCHPAD/b1052/report.md`

**Interfaces:**
- Consumes: `corpus.json` and `base.json` from Task 1, and `classify.py`.

- [ ] **Classify the corpus with the branch**

```bash
S="${SCRATCHPAD:?export SCRATCHPAD=<this session's scratchpad dir>}/b1052"
python3 -I "$S/classify.py" "$PWD" "$S/corpus.json" "$S/branch.json"
python3 -I "$S/classify.py" "$PWD" "$S/heredoc.json" "$S/branch-hd.json"
```

The corpus is frozen at Task 1. Do not re-run `extract.py` here; both sides must see the same commands.

- [ ] **Write `check_shape.py`, the independent §2 checker.** It tokenizes and walks the token list, rather than reusing the gate's single regex, so a mistake in one is unlikely to repeat in the other. It does not import `marker_check`.

```python
#!/usr/bin/env python3
"""check_shape.py <corpus.json> <base.json> <branch.json> -- #1052 acceptance report."""
import json, re, sys

RECV = re.compile(r"python[23]?|python[23]\.[0-9]+t?|node")
ERR = {"2>&1", "2>/dev/null", ">/dev/null"}
SAFE = re.compile(r"[A-Za-z0-9_./:@%+,-][A-Za-z0-9_./:@%+,=-]*")


TOKEN = r"<<'[^']*'|'[^']*'|[^ ']+"  # a <<'D' operator is one token
HEREDOC = re.compile(r"<<(?:'([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\""
                     r"|\\([A-Za-z_][A-Za-z0-9_]*))")


def word(w):
    return bool(SAFE.fullmatch(w) or re.fullmatch(r"'[^'\n]*'", w))


def shape(cmd):
    lines = cmd.split("\n")
    first = lines[0]
    # Tab or CR outside quotes lands in a bare token and fails RECV/word(); inside a quoted
    # word it is literal, as in the gate's pattern. Token sequence: quoted or bare tokens separated by runs of spaces, nothing else.
    if not re.fullmatch(r"(?:(?:" + TOKEN + r") +)*(?:" + TOKEN + r")", first):
        return False
    raw = re.findall(TOKEN, first)
    hd = [k for k, t in enumerate(raw) if HEREDOC.fullmatch(t)]
    if len(hd) != 1:
        return False
    k = hd[0]
    m = HEREDOC.fullmatch(raw[k])
    d = m.group(1) or m.group(2) or m.group(3)
    before, after = raw[:k], raw[k + 1:]
    if len(after) > 1 or (after and after[0] not in ERR):
        return False
    if before and before[-1] in ERR:
        before = before[:-1]
    i = 0
    if before[:1] == ["cd"]:
        if len(before) < 3 or before[2] != "&&" or not word(before[1]):
            return False
        i = 3
    if i >= len(before) or not RECV.fullmatch(before[i]):
        return False
    rest = before[i + 1:]
    if rest and (rest[0] != "-" or not all(word(w) for w in rest[1:])):
        return False
    try:
        end = lines.index(d, 1)
    except ValueError:
        return False
    return end == len(lines) - 1 or (end == len(lines) - 2 and lines[-1] == "")


corpus, base, branch = (json.load(open(p)) for p in sys.argv[1:4])
assert corpus and set(corpus) <= set(base) and set(corpus) <= set(branch), "empty or mismatched"
ok = lambda v: v == "OK|"
# A classifier crash is not a verdict: BLOCK_CLASSIFIER_ERROR goes to `odd`, not to BLOCK.
blk = lambda v: v.startswith("BLOCK") and not v.startswith("BLOCK_CLASSIFIER_ERROR")
# ERROR / TIMEOUT / anything unrecognised is neither OK nor BLOCK: it fails acceptance.
odd = [c for c in corpus if not (ok(base[c]) or blk(base[c])) or not (ok(branch[c]) or blk(branch[c]))]
ok_to_block = [c for c in corpus if ok(base[c]) and blk(branch[c])]
flips = [c for c in corpus if blk(base[c]) and ok(branch[c])]
bad = [c for c in flips if not shape(c)]
held = [c for c in corpus if shape(c) and blk(branch[c])]
print(f"corpus {len(corpus)}  base BLOCK {sum(map(blk, base.values()))}  "
      f"branch BLOCK {sum(map(blk, branch.values()))}  unclassified {len(odd)}")
print(f"OK->BLOCK {len(ok_to_block)}  BLOCK->OK {len(flips)}  flips failing shape {len(bad)}")
print(f"shape-matching but still BLOCK {len(held)}")
json.dump({"odd": odd, "ok_to_block": ok_to_block, "flips": flips, "bad": bad, "held": held},
          open(sys.argv[3] + ".report.json", "w"), indent=1)
sys.exit(1 if odd or ok_to_block or bad else 0)  # `held` is explained by hand, not failed here
```

  The checker's acceptance implication runs one way only: every BLOCK→OK flip must match §2. Matching §2 does not require OK, because the other branches and sites still apply. A command that matches but stays BLOCK lands in `held` and is explained by hand. A flip the checker rejects lands in `bad` and fails acceptance.

- [ ] **Run it and apply the acceptance rules**

```bash
S="${SCRATCHPAD:?export SCRATCHPAD=<this session's scratchpad dir>}/b1052"
python3 -I "$S/check_shape.py" "$S/corpus.json" "$S/base.json" "$S/branch.json"; echo "rc=$?"
python3 -I "$S/check_shape.py" "$S/heredoc.json" "$S/base-hd.json" "$S/branch-hd.json"; echo "rc=$?"
```

  Acceptance (both runs, each printing `rc=0`):
  - `unclassified 0`;
  - `OK->BLOCK 0`;
  - `flips failing shape 0`;
  - every `held` entry is explained, as one of these:
    - review note 1 (`NAME()` text in a quoted word on the introducer line);
    - another indirection branch firing (`hash`, `function NAME`, `alias`, `BASH_CMDS[`, or `eval` followed by whitespace or a redirect in the body — review note 6);
    - `BLOCK_UNSCANNABLE` from the scanner's token budget on a large body;
    - a literal helper name in the body (the literal-name scan, which this change leaves alone).

    A `held` command that fits none of these is a stop condition. Name the site that blocked it and report it; do not add a reason to this list.

    Write each explanation into `report.md`.

  Any other outcome is a stop condition. Report it rather than adjusting the predicate.

- [ ] **Bucket the shortfall.** Take every corpus command that is still BLOCK on the branch, whose first line contains `<<`, and that has a whitespace-separated word on line 1 matching `(^|/)(python[0-9.]*t?|node|perl|ruby)$`. That covers wrapped (`uv run`, `env`, `timeout`), path-qualified and `cd`-prefixed forms. Assign each the first matching bucket and count it:

  | Bucket | Rule |
  |---|---|
  | `token-budget` | verdict is `BLOCK_UNSCANNABLE` |
  | `perl-ruby` | receiver word is `perl` or `ruby` |
  | `path-or-wrapper` | receiver path-qualified, or preceded by `uv run`, `env`, `timeout` or another wrapper word |
  | `other-segment` | line 1 has `|`, `;`, or `&&` beyond a leading `cd WORD &&` |
  | `file-redirect` | line 1 has `>` not in the ERR set |
  | `err-pair` | two ERR tokens on one side of the heredoc |
  | `option-or-script` | an argument before `-`, or no `-` but arguments |
  | `introducer-name` | `NAME()` text in a quoted word on line 1 (review note 1) |
  | `other-branch` | §2 shape, but `hash`, `function NAME`, `alias` or `BASH_CMDS[` in the body |
  | `other` | anything else |

  Apply the operator rules (`|`, `;`, `&&`, `>`) to line 1 with single-quoted words removed first (`re.sub(r"'[^']*'", "''", line1)`), so a quoted `;` or `>` is not counted as an operator. Buckets are exclusive, so the first rule that matches wins, in table order. The October prototype's 78-command list was not kept, so the shortfall "against 78" is a comparison of counts only, not of the same commands. Say so in the report. Put the counts, the BLOCK→OK count, the shortfall against 78, and the full list of released commands in `report.md`.

The released commands come from private transcripts and can carry private paths, hostnames or secrets, and the repo is public. So the full list is **not** posted. The operator reviews it locally in `report.md`; that is the human review the spec's Acceptance asks for. The PR body carries the counts and the shape breakdown only. If the operator wants examples in the PR, they choose and redact them.

---

### Task 5: Regression and delivery

- [ ] **Local marker and integrity suites**

```bash
rc=0; for t in tests/test-marker-*.sh tests/test-gate-integrity.sh; do bash "$t" >/tmp/o.$$ 2>&1 || { rc=1; echo "FAIL $t"; tail -20 /tmp/o.$$; }; done; rm -f /tmp/o.$$; echo "rc=$rc"; [ $rc -eq 0 ]
REQUIRE_ZSH=1 REQUIRE_NODE=1 bash tests/test-marker-heredoc-interp-1052.sh; echo "rc=$?"
./scripts/gate-integrity.sh --check; echo "rc=$?"
```

Expected: three `rc=0` lines. The 1052 file's last line is `failed: 0` with skips only as Task 3 allows.

- [ ] **Amend the spec's Acceptance line.** The plan keeps the released-command list local for privacy (Task 4), but spec §Acceptance says the list is attached to the PR. Change that sentence in `docs/specs/2026-10-28-marker-heredoc-interp-design.md` to: "The full list of released commands is reviewed by the operator locally; it is not posted, because it comes from private transcripts and the repo is public. The PR carries counts and the shape breakdown." In the same edit, bring the spec in line with what this plan builds:
  - §1: when the predicate holds, the `NAME()` header still reads the introducer line, raw and normalized, so a quoted word holding `NAME()` text keeps its verdict. This replaces "is not searched" and "contains no `(`".
  - §2d: stdout goes to the Bash tool or `/dev/null`.
  - §2a/§2c: the terminator is the last line, optionally followed by one `\n`.

  Editing the spec re-arms its design review. Continue it with `init-design-review.sh --continue docs/specs/2026-10-28-marker-heredoc-interp-design.md`, then run the loop and the arbiter as usual. Commit the spec change with `docs(spec): …` once it passes, before `gh pr create`.

- [ ] **Full shell suite on UM**

```bash
um-run test -- bash scripts/ci/run-shell-tests.sh
```

Expected: the evidence JSON has `verified: true`, `cleanup_confirmed: true` and exit 0. A non-zero exit is a real failure to diagnose; exit 70 is infrastructure.

- [ ] **PR.** Push the branch and run `gh pr create`; the pre-PR litmus gate reviews the full branch diff. The PR body includes:
  - the Task 4 numbers;
  - the shortfall table;
  - the released count by shape (receiver, `-` or not, `cd` prefix, ERR use), not the commands themselves, and a note that the operator reviewed the full list locally;
  - the `held` explanations;
  - a line naming review note 6 (Node `function NAME`);
  - the two residual statements from spec §3;
  - `Closes #1052`;
  - references to #1055 and #1025.
  End the body with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Grind.** Invoke `busdriver:pr-grind` on the PR.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
