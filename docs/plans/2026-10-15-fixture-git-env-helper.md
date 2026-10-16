# Shared git-env isolation for test fixtures (#967) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `tests/test-*.sh` that invokes git clears the repository and config environment it inherited, before anything else runs. A lint suite keeps it that way.

**Architecture:** The #890 guard moves into one sourced file, `tests/lib/git-env-isolation.sh`. Four suites already carry it inline. Each suite that invokes git sources the file with one line, `. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1`. That line goes directly after the suite's first `set -` line. The `set -` line must be the suite's first non-comment, non-blank line, so nothing (no `cd`, no `$(cd …)`, no git call) can run before the guard. In the four suites that carry the guard inline, the inline lines are deleted.

A new suite, `tests/test-git-env-isolation.sh`, does three things:
- fails when a suite that invokes git does not have exactly that layout;
- shows the helper's effect against a positive control;
- proves the scan can fail, using a negative control.

**Tech Stack:** bash (all 85 affected suites are bash; `compgen` is a bash builtin), git, and the existing CI glob over `tests/test-*.sh`.

**Global Constraints:**
- **Helper body.** It is the same four statements as `tests/test-shipping-merge-watch.sh:10-13` (the `unset` line, the `GIT_CONFIG_KEY/VALUE` loop, `unset _v`, and the `export` line). No variable is added or dropped.
- **Detection rule.** A suite "invokes git" when any non-comment line contains `git` as a word, by the ERE `(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)`.
  - The rule catches calls in the middle of a line (`( cd "$r" && git init`), absolute paths (`/usr/bin/git`), and lines that name git while storing it in a variable (`G=$(command -v git)`).
  - It also catches read-only calls, which an inherited `GIT_DIR` redirects too, and prose that mentions git. That over-count is deliberate: a false positive costs one sourced line.
  - It excludes `.git`, `.github`, `git-…` names and `…_git`, so the helper's own path in the source line does not count.
  - Known residual: a suite that runs git only through a variable whose value never names git on any line (for example, a path passed in as an argument) is not detected. None exists today; the detection-coverage check in Task 2 counts suites, so a large drop shows.
  - Measured at `origin/main` `0ac6e3b8`, the rule selects **85** of the 165 `tests/test-*.sh`. The line-anchored, mutating-only regex that #967 used selects 62.
- **`env -i` does not exempt a suite.** 11 suites use `env -i` only around gate invocations. That says nothing about their fixture git calls.
- **Layout is uniform.** In all 85 suites, the first non-comment line is the first `set -` line (measured by `broad967.sh` in the appendix). So "directly after it" puts the guard before every other statement.
- **No behaviour change in a normal run, compared under CI's git condition.** In both runs, `GIT_CONFIG_GLOBAL` points at an empty file; `tests.yml` sets no global git config. Each suite's exit code must equal the baseline, and so must its last `N passed`/`N failed` line where it prints one. The last raw output line is not compared, because some suites print PIDs.
- **Paths.** `$W` is the checkout and `$S` a scratch directory for the evidence scripts; export both before running any step.
- **Commits.** Conventional Commits; each commit ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Litmus refuses more than 8 staged files per commit, so the migration lands in batches.

---

## File Structure

- **Create `tests/lib/git-env-isolation.sh`:** the guard. It is sourced and has no shebang, like `tests/lib/careful-guard-harness.sh`.
- **Create `tests/test-git-env-isolation.sh`:** the lint, the helper checks and the controls.
- **Modify the 85 suites the detection rule selects:** one inserted line each. The four inline-guard suites also lose their inline lines:
  - `test-shipping-merge-watch.sh`
  - `test-skip-file-mtime-946.sh`
  - `test-890-pr-grind-skill.sh`
  - `test-890-push-destination-units.sh`
- **Evidence scripts:** these live in the scratchpad and are not committed. Their full text is in the appendix: `broad967.sh` (selection and layout), `run967c.sh` (runner) and `compare967.sh` (comparison).

---

### Task 0: Baseline (before any edit)

- [ ] **Confirm the tree is the unmodified base.** In the checkout `$W`:
  - `git rev-parse HEAD` must print `0ac6e3b8081907ac28a3715d0a2d2768ca2f2149`.
  - `git status --porcelain` must print only `?? docs/plans/2026-10-15-fixture-git-env-helper.md`.
  - Any other output → stop. The baseline would not be of `0ac6e3b8`.
- [ ] **Select the suites and check the layout:** `bash broad967.sh` must print `matched=85 odd=0`. It writes the list to `broad967.txt`.
- [ ] **Run the baseline and the unfixed sentinel pass**, in one background call:

  ```bash
  bash run967c.sh base "$W" broad967.txt normal && bash run967c.sh unfixed "$W" broad967.txt sentinel
  ```

  Result: `res967-base.tsv` and `res967-unfixed.tsv`, 85 rows each.
  - No row may be `SETUP_FAIL`. If one is, fix the sentinel setup and re-run.
  - Do not start Task 1 until both files are complete. The runner reads the suites from this tree.

### Task 1: Helper and migration

**Files:**
- Create: `tests/lib/git-env-isolation.sh`
- Modify: the 85 suites in `broad967.txt`

**Interfaces:**
- Produces: sourcing the helper does two things.
  - It unsets `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG GIT_CONFIG_PARAMETERS` and every `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`.
  - It exports `GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`.

- [ ] **Write the helper** `tests/lib/git-env-isolation.sh`:

```bash
# shellcheck shell=bash
# Sourced first by every tests/test-*.sh that invokes git (#967; the #890 guard).
# Git honors an inherited GIT_DIR / GIT_WORK_TREE over -C, and the GIT_CONFIG_* family can inject
# settings such as core.hooksPath, so a suite run from a hook, `git rebase --exec` or any wrapper
# that exports them would act on the caller's checkout. tests/test-git-env-isolation.sh enforces it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG GIT_CONFIG_PARAMETERS
for _v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_' || true); do unset "$_v"; done
unset _v
export GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
```

- [ ] **Migrate the suites.** Run as one Bash call. It edits only the files in `broad967.txt`. A failed `awk`/`chmod` leaves the original in place and is reported.

```bash
cd "$W" || exit 1
SRC='. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1'
n=0; err=0
while read -r f; do
  grep -qxF "$SRC" "$f" && { echo "already: $f"; continue; }
  # Insert SRC after the first `set -` line. Delete an inline #890 block: the unset line, the
  # KEY/VALUE loop, `unset _v`, the `export GIT_CONFIG_COUNT=0...` line after it, and the
  # `# Fixture repos must not inherit` comment only when the very next line is that unset line.
  if awk -v src="$SRC" '
       !done && /^set -/ { print; print src; done = 1; next }
       held != "" { if ($0 ~ /^unset GIT_DIR GIT_WORK_TREE/) { held = ""; blk = 1; next }
                    print held; held = "" }
       /^# Fixture repos must not inherit/ { held = $0; next }
       /^unset GIT_DIR GIT_WORK_TREE/ { blk = 1; next }
       blk && /^for _v in \$\(compgen -e/ { next }
       blk && /^unset _v$/ { next }
       blk && /^export GIT_CONFIG_COUNT=0/ { blk = 0; next }
       { blk = 0; print }
       END { if (held != "") print held }
     ' "$f" > "$f.new" && chmod "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" "$f.new" && mv "$f.new" "$f"; then
    n=$((n + 1))
  else
    rm -f "$f.new"; echo "FAILED: $f"; err=$((err + 1))
  fi
done < "$S"/broad967.txt
echo "migrated=$n failed=$err"; git diff --stat | tail -1
```

Expected output: `migrated=85 failed=0`, then `85 files changed`. The diff for 81 suites is one added line. The four inline-guard suites each also lose their four guard lines. Three of them also lose the `# Fixture repos must not inherit` comment directly above the guard. `test-890-pr-grind-skill.sh` keeps its comment (line 17), because the line under it is `unset BUSDRIVER_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT`, which stays.

- [ ] **Check the layout and the deletions.** One self-contained Bash call:

```bash
cd "$W" || exit 1
SRC='. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1'
c=0
while read -r f; do
  c=$((c + 1))
  first=$(grep -nvE '^[[:space:]]*#|^[[:space:]]*$' "$f" | head -2)
  l1=$(printf '%s\n' "$first" | sed -n 1p); l2=$(printf '%s\n' "$first" | sed -n 2p)
  case ${l1#*:} in "set -"*) ;; *) echo "BAD first-line $f"; continue ;; esac
  [ "${l2#*:}" = "$SRC" ] && [ "${l2%%:*}" -eq $(( ${l1%%:*} + 1 )) ] || echo "BAD second-line $f"
done < "$S"/broad967.txt
echo "LAYOUT_CHECKED suites=$c"
grep -l '^unset GIT_DIR GIT_WORK_TREE' tests/test-*.sh || echo "NO_INLINE_LEFT"
```

Expected output: `LAYOUT_CHECKED suites=85`, then `NO_INLINE_LEFT`.

- [ ] **Review the four inline-guard diffs by eye:**

  ```bash
  git -C "$W" diff tests/test-shipping-merge-watch.sh tests/test-skip-file-mtime-946.sh tests/test-890-pr-grind-skill.sh tests/test-890-push-destination-units.sh
  ```

  - In each of the four, the guard moves from its inline position to directly after `set -`.
  - The two `test-890-*` suites keep their earlier `export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0` line (lines 16 and 17). The awk does not match that line, so they keep `GIT_TERMINAL_PROMPT=0`.
  - `test-890-pr-grind-skill.sh` keeps lines 17-18 (its comment and `unset BUSDRIVER_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT`).

- [ ] **Commit in batches of at most 8 files**, taking `broad967.txt` in order.
  - The first batch is the helper plus 7 suites.
  - Each later batch is the next 8 suites, so the 85 suites take 11 batches.
  - Every commit goes through litmus at the commit gate. The first one:

    ```bash
    git -C "$W" add tests/lib/git-env-isolation.sh <first 7 suites>
    git -C "$W" commit -m "test: clear inherited git env in fixture suites via a shared helper (#967, 1/11)" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
    ```

  - The rest are `(2/11)` through `(11/11)`.

### Task 2: Lint suite

**Files:**
- Create: `tests/test-git-env-isolation.sh`

**Interfaces:**
- Consumes: the helper from Task 1 and the exact source line.

- [ ] **Write the suite:**

```bash
#!/usr/bin/env bash
# Every tests/test-*.sh that invokes git must have, as its first two code lines, a `set -` line and
# then the line that sources tests/lib/git-env-isolation.sh (#967). Nothing can run before the
# guard. Also checks the helper's effect, and that the scan can fail.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# git as a word on a non-comment line; excludes .git, .github, git-* and *_git.
GIT_WORD='(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)'
SRC_LINE='. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1'

invokes_git() { grep -nE "$GIT_WORD" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; }

# unguarded <dir>: each <dir>/test-*.sh that invokes git and whose first two code lines are not a
# `set -` line followed directly by SRC_LINE.
unguarded() {
  local f code l1 l2
  for f in "$1"/test-*.sh; do
    [ -f "$f" ] && invokes_git "$f" || continue
    code=$(grep -nvE '^[[:space:]]*#|^[[:space:]]*$' "$f" | head -2)
    l1=$(printf '%s\n' "$code" | sed -n 1p); l2=$(printf '%s\n' "$code" | sed -n 2p)
    [[ ${l1#*:} =~ ^set\ -[a-z]+(\ pipefail)?$ ]] || { echo "$f"; continue; }
    { [ "${l2#*:}" = "$SRC_LINE" ] && [ "${l2%%:*}" -eq $(( ${l1%%:*} + 1 )) ]; } || echo "$f"
  done
}

echo "── every git-invoking suite sources the helper first ─────────"
bad=$(unguarded tests)
if [ -z "$bad" ]; then pass "no unguarded suite"; else fail "unguarded: $(echo $bad)"; fi
n=$(for f in tests/test-*.sh; do invokes_git "$f" && echo "$f"; done | wc -l | tr -d ' ')
if [ "$n" -ge 85 ]; then pass "scan sees $n git-invoking suites (85 at #967)"; else fail "scan sees only $n git-invoking suites (expected >= 85)"; fi
if invokes_git tests/test-git-env-isolation.sh; then pass "this suite is inside its own scan"
else fail "this suite is not inside its own scan, so removing its source line would go unnoticed"; fi

echo "── the scan can fail ─────────────────────────────────────────"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#!/usr/bin/env bash\nset -u\ngit init -q "$1"\n' > "$T/test-a.sh"
printf '#!/usr/bin/env bash\nset -u\n( cd "$1" && git init -q )\n%s\n' "$SRC_LINE" > "$T/test-b.sh"
printf '#!/usr/bin/env bash\nset -u\nG=$(command -v git)\n"$G" init -q "$1"\n' > "$T/test-c.sh"
printf '#!/usr/bin/env bash\nset -u\nR=$(cd "$1" && pwd)\n%s\ngit -C "$R" init -q\n' "$SRC_LINE" > "$T/test-d.sh"
printf '#!/usr/bin/env bash\nX=1\nset -u\n%s\ngit init -q "$1"\n' "$SRC_LINE" > "$T/test-e.sh"
printf '#!/usr/bin/env bash\n# header\nset -u\n%s\n\ngit init -q "$1"\n' "$SRC_LINE" > "$T/test-f.sh"
printf '#!/usr/bin/env bash\nset -u\n# git init in a comment\nls .github\n' > "$T/test-g.sh"
got=$(unguarded "$T" | sed "s|$T/||" | tr '\n' ' ')
if [ "$got" = "test-a.sh test-b.sh test-c.sh test-d.sh test-e.sh " ]; then
  pass "missing, late, after-\$(cd) and after-code source lines are reported; guarded and git-free suites are not"
else fail "negative control reported: '$got'"; fi

echo "── the helper clears inherited repository and config env ─────"
R="$T/repo"; git init -q "$R"
out=$(env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/x GIT_COMMON_DIR=/x \
      GIT_OBJECT_DIRECTORY=/x GIT_CONFIG=/x GIT_CONFIG_PARAMETERS="'core.hookspath=/evil'" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/evil \
      bash -c '. tests/lib/git-env-isolation.sh || exit 9
        for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; do
          [ -z "${!v+x}" ] || echo "still set: $v"; done
        echo "count=$GIT_CONFIG_COUNT global=$GIT_CONFIG_GLOBAL nosystem=$GIT_CONFIG_NOSYSTEM"
        echo "hooksPath=$(git -C "$1" config --get core.hooksPath)"' _ "$R" 2>&1)
want="count=0 global=/dev/null nosystem=1
hooksPath="
if [ "$out" = "$want" ]; then pass "poisoned GIT_* env is cleared and no injected config reaches git"
else fail "helper left: $out"; fi
# Positive control: the same poison without the helper does reach git.
leak=$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/evil git -C "$R" config --get core.hooksPath)
if [ "$leak" = /evil ]; then pass "control: without the helper the injected config reaches git"
else fail "control: injected config did not reach git ('$leak'), so the check above proves nothing"; fi

echo ""
echo "git-env-isolation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

How this suite satisfies its own rule:
- Its first two code lines are `set -uo pipefail` and the source line.
- The line `R="$T/repo"; git init` names git, so the suite is inside its own scan; the third check asserts that.
- The negative-control fixture `test-f.sh` shows that comments before `set -` and a blank line after the source line are allowed. Nothing at all may sit between `set -` and the source line: the check requires the source line to be the very next line.

- [ ] **Run it:** `bash tests/test-git-env-isolation.sh`. Expected: `git-env-isolation: 6 passed, 0 failed`.
- [ ] **Prove the main check can fail on a real suite.**
  1. Delete the source line from `tests/test-shipping-kick.sh` in the working tree. That suite calls git only in the middle of a line, and #967's regex missed it.
  2. Run the lint. Expected: `FAIL  unguarded: tests/test-shipping-kick.sh`.
  3. Restore the file: `git -C "$W" checkout -- tests/test-shipping-kick.sh`.
- [ ] **shellcheck:** `shellcheck --severity=warning tests/lib/git-env-isolation.sh tests/test-git-env-isolation.sh` must print nothing.
- [ ] **Commit:** `test: lint that git-invoking suites source the git-env helper first (#967)`, with the trailer.

### Task 3: Evidence and PR

- [ ] **Run the same two passes on the branch.** One background call:

  ```bash
  bash run967c.sh fixed "$W" broad967.txt normal && bash run967c.sh fixedsent "$W" broad967.txt sentinel
  ```

- [ ] **Compare:**

  ```bash
  bash compare967.sh res967-base.tsv res967-fixed.tsv
  bash compare967.sh res967-base.tsv res967-fixedsent.tsv require-untouched
  ```

  Both must print `COMPARE_OK`. Under the second, each suite run with `GIT_DIR` pointing at a sentinel must:
  - leave that sentinel untouched;
  - exit with its baseline code;
  - print its baseline summary line.

  Suites that already fail in `base` (a missing tool or network) pass `compare967.sh` only by failing the same way. They are listed in the PR as pre-existing.
- [ ] **Count the unfixed mutations:** `awk -F'\t' '$3=="MUTATED"' res967-unfixed.tsv | wc -l`. This number goes in the PR.
- [ ] **Open the PR.** Push, wait for litmus PR mode to pass, then in a separate call run `cd "$W" && gh pr create ...`.

  The body covers:
  - the helper and the detection rule, with why it over-counts;
  - the lint and its controls;
  - the mutated count from `unfixed`, then all 85 untouched in `fixedsent`;
  - both `COMPARE_OK` results;
  - `Closes #967`;
  - the closing line `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

---

## Appendix: evidence scripts (scratchpad, not committed)

`broad967.sh` selects the suites and checks the layout:

```bash
#!/bin/bash
W=${W:?set W to the checkout}
S=${S:?set S to a scratch directory}
WORD='(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)'
cd "$W" || exit 1
: > "$S/broad967.txt"; bad=0
for f in tests/test-*.sh; do
  g=$(grep -nE "$WORD" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
  [ -n "$g" ] || continue
  echo "$f" >> "$S/broad967.txt"
  first=$(grep -nvE '^[[:space:]]*#|^[[:space:]]*$' "$f" | head -1)
  fl=${first%%:*}; ft=${first#*:}
  st=$(grep -nE '^set -' "$f" | head -1 | cut -d: -f1)
  cdl=$(grep -nE '^[[:space:]]*cd ' "$f" | head -1 | cut -d: -f1)
  ok=1
  case $ft in "set -"*) ;; *) ok=0 ;; esac
  [ -n "$st" ] && [ "$st" -lt "$g" ] || ok=0
  [ -z "$cdl" ] || [ "$st" -lt "$cdl" ] || ok=0
  [ "$ok" = 1 ] || { bad=$((bad+1)); echo "ODD $f"; }
done
echo "matched=$(wc -l < "$S/broad967.txt") odd=$bad"
```

`run967c.sh <label> <tree> <list> <normal|sentinel> [start-line]` runs the suites. It writes one row per suite: path, exit code, sentinel state, seconds, and the last `N passed`/`N failed` line. How it runs:
- It clears its own inherited `GIT_*` first.
- It builds each sentinel with `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 -c commit.gpgsign=false`, so the operator's config plays no part: no signing and no `core.hooksPath`. Every setup step is checked, and a failed one records `SETUP_FAIL`.
- It fingerprints the sentinel as `cksum` of every file under it, `.git` included, plus `ls -aR`. Index, refs, config, logs and objects all count.

```bash
#!/bin/bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG GIT_CONFIG_PARAMETERS
for _v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_' || true); do unset "$_v"; done
unset _v
export GIT_CONFIG_COUNT=0
label=$1; tree=$2; list=$3; mode=$4; start=${5:-1}
S=${S:?set S to a scratch directory}
out="$S/res967-$label.tsv"; logd="$S/logs967-$label"; mkdir -p "$logd"; : > "$out"
: > "$S/gitconfig967"
sg() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
fp() { (cd "$1" && find . -type f -exec cksum {} + | sort; ls -aR); }
summary() { grep -E '[0-9]+ (passed|failed)' "$1" | tail -1 | cut -c1-120; }
cd "$tree" || exit 1
tail -n +"$start" "$list" | while read -r f; do
  name=$(basename "$f" .sh); t0=$(date +%s); state=-
  if [ "$mode" = sentinel ]; then
    sn="$S/sent967/$label-$name"; rm -rf "$sn"; mkdir -p "$sn"
    if sg -C "$sn" init -q -b keep && sg -C "$sn" -c user.name=s -c user.email=s@s -c commit.gpgsign=false commit -q --allow-empty -m sentinel \
       && echo "uncommitted work" > "$sn/precious"; then
      before=$(fp "$sn")
      GIT_DIR="$sn/.git" GIT_WORK_TREE="$sn" GIT_CONFIG_GLOBAL="$S/gitconfig967" timeout 1500 bash "$f" > "$logd/$name.log" 2>&1 < /dev/null; rc=$?
      [ "$before" = "$(fp "$sn")" ] && state=untouched || state=MUTATED
    else
      rc=-; state=SETUP_FAIL
    fi
  else
    GIT_CONFIG_GLOBAL="$S/gitconfig967" timeout 1500 bash "$f" > "$logd/$name.log" 2>&1 < /dev/null; rc=$?
  fi
  printf '%s\t%s\t%s\t%ss\t%s\n' "$f" "$rc" "$state" "$(( $(date +%s) - t0 ))" "$(summary "$logd/$name.log" 2>/dev/null)" >> "$out"
done
```

`compare967.sh <before.tsv> <after.tsv> [require-untouched]` compares two runs. Every suite in `before` must appear in `after` with the same exit code and the same summary line. With `require-untouched`, every `after` row must also be `untouched`. It prints `COMPARE_OK` or lists each difference, then `COMPARE_FAILED <n>`.

```bash
#!/bin/bash
b=$1; a=$2; req=${3:-}
awk -F'\t' -v req="$req" '
  NR == FNR { rc[$1] = $2; sm[$1] = $5; next }
  { seen[$1] = 1
    if (!($1 in rc)) { print "NEW    " $1 " rc=" $2; next }
    if ($2 != rc[$1]) { print "RC     " $1 " " rc[$1] " -> " $2; bad++ }
    if ($5 != sm[$1]) { print "SUMMARY " $1 " [" sm[$1] "] -> [" $5 "]"; bad++ }
    if (req != "" && $3 != "untouched") { print "SENTINEL " $1 " " $3; bad++ } }
  END { for (k in rc) if (!(k in seen)) { print "MISSING " k; bad++ }
        print (bad ? "COMPARE_FAILED " bad : "COMPARE_OK"); exit (bad ? 1 : 0) }
' "$b" "$a"
```

---

## Sanity check

- #967 asks for a shared helper and a lint test: Task 1 and Task 2.
- #967 says "each one needs a look", because its regex over-counts. This plan guards every suite that invokes git under a broader rule instead of triaging each match. The broader rule also catches calls in the middle of a line and git stored in a variable.
- The baseline runs before any edit (Task 0), on a tree checked to be `0ac6e3b8`.
- Names used across tasks are defined once and used the same way: `tests/lib/git-env-isolation.sh`, the exact source line, the detection ERE, `invokes_git()`, `unguarded()`, and the three scratch scripts.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
