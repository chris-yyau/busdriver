# Shard CI shell-tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Source:** roadmap item 5 of `docs/plans/2026-08-27-pipeline-final-plan.md` (line 281). That roadmap row is not binding. This document is the item's spec.

**Goal:** Cut the required `shell-tests` check from ~41 min to ~15 min. The suite runs as 4 duration-balanced shards behind one aggregate check that keeps the name `shell-tests`. The aggregate fails unless every test found by the live glob ran exactly once and passed.

**Architecture:** `scripts/ci/run-shell-tests.sh` gains three modes:
- `--list-shard I/N` prints the tests a shard owns.
- `--shard I/N --record FILE` runs those tests and writes a completion record.
- `--reconcile N DIR` checks the records against the live glob.

Each shard computes the same deterministic greedy partition (longest-first) from a committed durations file. A test missing from that file still gets a default weight, so the partition can never drop a test. The aggregate `shell-tests` job runs `if: always()` and reconciles the records, so completeness is checked on every run rather than once at cutover.

**Tech Stack:** bash 3.2-compatible shell, POSIX awk (BSD awk, mawk and gawk), and GitHub Actions: a matrix job plus `actions/upload-artifact` and `actions/download-artifact`.

**Global Constraints:**
- bash 3.2 compatible: no `declare -A`, no `mapfile`. An empty-array expansion must be guarded (`${a[@]+"${a[@]}"}`) under `set -u`.
- Do NOT edit the `# BD803-CLEAN-ENV-BEGIN` … `# BD803-CLEAN-ENV-END` block in `run-shell-tests.sh`. `tests/test-trusted-review-cli.sh` extracts it and asserts on it.
- No new dependencies. Pin every action to a full commit SHA with a version comment.
- `shell-tests` stays the only required shell-test context. Branch protection is NOT changed, and the shard contexts are classified `advisory` in `.github/required-checks.lock`.
- The no-argument invocation (local use) still runs the whole suite, and its PASS/SKIP/FAIL classification and skip-masking allowlist are unchanged.
- awk must work on BSD awk (macOS), mawk (ubuntu `awk`) and gawk. Use no gawk-only features: no `ARGIND`, no `asort`, no `PROCINFO`.

---

## Measured baseline (not the historical 14.9 min)

These numbers come from the `shell-tests` job of PR #883, run 36321967050, job 108627491973, on 2026-09-27. Each test's duration is the gap between consecutive runner verdict lines.
- 156 tests, summing to 2418 s. The whole job took 2459 s (41 min).
- Heaviest tests: `test-litmus-mode-transition` 760 s, `test-impl-gate-scope-519` 398 s, `test-ultra-oracle` 171 s and `test-impl-gate-scope-553` 128 s. The other 152 tests sum to 961 s.
- The weights file floors the 49 tests that measured 0 s up to 1 s, so the weights sum to 2467 s against 2418 s measured.
- Greedy longest-first loads, simulated with the committed weights:
  - N=3: [823, 822, 822]
  - N=4: [760, 569, 569, 569]
  - N=5: [760, 427, 427, 427, 426]

## Decisions (lightweight ADR)

| Decision | Choice | Alternatives and why not | Revisit trigger |
|---|---|---|---|
| Shard count | **N=4**. Its wall time is bounded by the 760 s test, and three shards keep ~190 s of growth headroom. | N=3 is 823 s with no headroom as the suite grows. N=5 buys nothing because the 760 s test is the floor. | `test-litmus-mode-transition` is split, or the heaviest shard's measured load passes 900 s |
| Partition | **Computed at runtime** from the live glob plus a committed weights file. Unknown tests get weight 10. | A static committed partition drops any test added after it was computed. Reconciliation would catch that, but only by failing every PR until someone regenerates the file. | — |
| Guarantee | **The aggregate reconciles the records against the live glob.** The weights affect balance only, never correctness. | Trusting the partition function alone fails silently: a shard that crashes after assigning its tests but before running them looks the same as one that finished. | — |
| Shard classification | **Advisory**, one lock entry per matrix leg. | Required legs would need a branch-protection PATCH on every change of N. The aggregate already fails on any failed, cancelled or missing shard, so a shard failure still blocks the merge. | — |
| Sub-case SKIP (#821 residual) | **Shown, not failed.** Each PASS line carries a sub-case SKIP count and the first matching lines, and the summary lists the suites. | Failing on it needs a per-row allowlist across ~150 suites, which is its own design. | A sub-case skip goes unnoticed long enough to hide a regression again |
| #829 (dependency-install latency) | **Not in scope.** #829 is CLOSED. Dependency installs already run as separate steps, so their latency shows per step and a failed install is not reported as a test failure. | — | — |
| #632 (dropped `pull_request` event) | **Partly addressed.** With `if: always()` and a final result check, `shell-tests` cannot post `skipped` when its shards were skipped, cancelled or failed. #632 stays OPEN: its re-run lever and the `commitlint`/`version-drift` skip trap are untouched. | — | — |
| When `shellcheck` fails | `shell-tests` now reports **failure**, where before it reported `skipped`. That is stricter, and `shellcheck` is required anyway. | — | — |

## File Structure

- Modify `scripts/ci/run-shell-tests.sh`: mode parsing, partition, per-test duration, sub-case skip exposure, shard record and reconcile. Discovery stays in one file, so the shards and the aggregate share the same glob.
- Create `scripts/ci/shell-test-durations.tsv`: `<test-basename>\t<seconds>` weights.
- Create `tests/test-shell-test-sharding.sh`: partition and reconcile regressions. It uses `--list-shard`/`--reconcile`, plus one real `--shard` run pinned to a single hermetic suite, which is never itself (see Task 6 Step 3).
- Modify `.github/workflows/tests.yml`: add the `shell-tests-shard` matrix job and turn `shell-tests` into the aggregate.
- Modify `.github/required-checks.lock`: 4 advisory shard entries plus one `_doc` line.
- Modify `docs/ci/shell-test-inventory.md`: a sharding section.

---

### Task 1: Runner modes, partition, durations and sub-case skips

**Files:**
- Modify: `scripts/ci/run-shell-tests.sh`. The anchors are current line numbers: `is_skip_allowed` ends at ~318, counters at 320-322, discovery at 336-343, the loop at 346-381 and the summary at 383-392.
- Create: `scripts/ci/shell-test-durations.tsv`

**Interfaces:**
- Produces:
  - CLI `run-shell-tests.sh [--shard I/N --record /abs/file | --list-shard I/N | --reconcile N /abs/dir]`. Bad arguments exit 2.
  - Env `SHELL_TEST_DURATIONS` overrides the weights path; the default is `scripts/ci/shell-test-durations.tsv`.
  - Record format, tab-separated and one per line: `N\t<n>`, then `SHARD\t<i>`, then `ASSIGNED\t<base>`…, then `DONE\t<base>\t<PASS|SKIP|FAIL>\t<seconds>\t<subskips>`…, then `END\t<count>`.

- [ ] **Step 1: Add the header doc and mode parsing.** In the header comment block, extend the `# Env:` section and add a `# Modes:` section:

```bash
# Modes (0827 roadmap item 5 — sharded CI; docs/plans/2026-09-27-ci-shard-shell-tests.md):
#   (no args)                      run every discovered test (local use; unchanged)
#   --shard I/N --record FILE      run only shard I of N; write a completion record to FILE
#   --list-shard I/N               print shard I of N's test basenames, run nothing
#   --reconcile N DIR              aggregate check: DIR/shell-shard-*.tsv vs the live glob
#
# Env:
#   SHELL_TEST_TIMEOUT   per-test timeout in seconds (default 180)
#   SHELL_TEST_DURATIONS partition weights file (default scripts/ci/shell-test-durations.tsv)
```

Insert directly after the `is_skip_allowed` function:

```bash
MODE=run SHARD_I=0 SHARD_N=0 RECORD_FILE='' RECONCILE_DIR=''
usage() {
  echo "usage: run-shell-tests.sh [--shard I/N --record /abs/file | --list-shard I/N | --reconcile N /abs/dir]" >&2
  exit 2
}
parse_shard() {   # <I/N> -> SHARD_I, SHARD_N (1 <= I <= N <= 99), else usage
  [[ "$1" =~ ^([1-9][0-9]?)/([1-9][0-9]?)$ ]] || usage
  SHARD_I=${BASH_REMATCH[1]} SHARD_N=${BASH_REMATCH[2]}
  [ "$SHARD_I" -le "$SHARD_N" ] || usage
}
case "${1:-}" in
  "") [ $# -eq 0 ] || usage ;;
  --shard)
    [ $# -eq 4 ] && [ "$3" = --record ] && [[ "$4" == /* ]] || usage
    parse_shard "$2"; MODE=shard RECORD_FILE=$4 ;;
  --list-shard)
    [ $# -eq 2 ] || usage
    parse_shard "$2"; MODE=list ;;
  --reconcile)
    [ $# -eq 3 ] && [[ "$2" =~ ^[1-9][0-9]?$ ]] && [[ "$3" == /* ]] || usage
    SHARD_N=$2 RECONCILE_DIR=$3 MODE=reconcile ;;
  *) usage ;;
esac

DURATIONS_FILE="${SHELL_TEST_DURATIONS:-$REPO_ROOT/scripts/ci/shell-test-durations.tsv}"
# Weight for a test absent from the durations file — every newly added test until the
# file is refreshed. It affects balance only: reconciliation, not the weights, is what
# guarantees every discovered test ran exactly once.
DEFAULT_WEIGHT=10

# shard_members <I> <N> <base>... -> the bases shard I of N owns, one per line.
# Longest-processing-time greedy: heaviest first (ties by name), each onto the lightest
# shard so far (ties to the lowest index). Pure function of (test list, weights file),
# so every shard computes the same partition independently. The weights are read with
# getline in BEGIN, not the NR==FNR idiom, which misreads stdin as weights when the
# weights file is empty. A malformed or unreadable weights file fails closed.
shard_members() {
  local i="$1" n="$2"; shift 2
  printf '%s\n' "$@" | awk -v want="$i" -v n="$n" -v dflt="$DEFAULT_WEIGHT" -v dfile="$DURATIONS_FILE" '
    BEGIN {
      while ((r = (getline line < dfile)) > 0) {
        ln++
        if (line ~ /^#/ || line == "") continue
        nf = split(line, f, "\t")
        if (nf != 2 || f[2] !~ /^[0-9]+$/) {
          print "ERROR: bad durations line " ln ": " line > "/dev/stderr"; bad = 1; exit 1
        }
        w[f[1]] = f[2] + 0
      }
      if (r < 0) { print "ERROR: cannot read durations file: " dfile > "/dev/stderr"; bad = 1; exit 1 }
    }
    { k++; name[k] = $0; wt[k] = ($0 in w) ? w[$0] : dflt }
    END {
      if (bad) exit 1
      for (a = 2; a <= k; a++) {
        nm = name[a]; x = wt[a]
        for (b = a - 1; b >= 1 && (wt[b] < x || (wt[b] == x && name[b] > nm)); b--) {
          name[b + 1] = name[b]; wt[b + 1] = wt[b]
        }
        name[b + 1] = nm; wt[b + 1] = x
      }
      for (s = 1; s <= n; s++) load[s] = 0
      for (a = 1; a <= k; a++) {
        best = 1
        for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
        load[best] += wt[a]
        if (best == want) print name[a]
      }
    }'
}
```

- [ ] **Step 2: Name validation, shard selection and reconcile dispatch.** Replace the discovery block from `shopt -s nullglob` through the `echo "Discovered …"` line with:

```bash
shopt -s nullglob
tests=(tests/test-*.sh)
if [[ "${#tests[@]}" -eq 0 ]]; then
  echo "ERROR: no tests matched tests/test-*.sh" >&2
  exit 1
fi
# Basenames become tab-separated fields in shard records; refuse any name that could
# split or forge a field rather than let the reconcile misread it.
all_bases=()
for t in "${tests[@]}"; do
  b=${t##*/}; b=${b%.sh}
  [[ "$b" =~ ^test-[A-Za-z0-9._-]+$ ]] || { echo "ERROR: unsupported test file name: $t" >&2; exit 1; }
  all_bases+=("$b")
done

if [[ "$MODE" == reconcile ]]; then
  printf '%s\n' "${all_bases[@]}" >"$out_file"
  reconcile_shards "$SHARD_N" "$RECONCILE_DIR" "$out_file"
  exit $?
fi

if [[ "$MODE" == shard || "$MODE" == list ]]; then
  members="$(shard_members "$SHARD_I" "$SHARD_N" "${all_bases[@]}")" || exit 1
  if [[ "$MODE" == list ]]; then
    [ -n "$members" ] && printf '%s\n' "$members"
    exit 0
  fi
  tests=()
  while IFS= read -r b; do [ -n "$b" ] && tests+=("tests/$b.sh"); done <<<"$members"
  { printf 'N\t%s\nSHARD\t%s\n' "$SHARD_N" "$SHARD_I"
    for t in ${tests[@]+"${tests[@]}"}; do b=${t##*/}; printf 'ASSIGNED\t%s\n' "${b%.sh}"; done
  } >"$RECORD_FILE" || { echo "ERROR: cannot write $RECORD_FILE" >&2; exit 1; }
  echo "Shard ${SHARD_I}/${SHARD_N}: ${#tests[@]} of ${#all_bases[@]} discovered shell tests (per-test timeout ${PER_TEST_TIMEOUT}s, per-test overrides may extend individual suites)"
else
  echo "Discovered ${#tests[@]} shell tests (per-test timeout ${PER_TEST_TIMEOUT}s, per-test overrides may extend individual suites)"
fi

# record <field>... — append one tab-joined line to the shard record (shard mode only).
# A failed append exits: a record that silently stops growing would reconcile as
# "missing completion record", but naming the real cause is cheaper to debug.
record() {
  [[ "$MODE" != shard ]] && return 0
  local IFS=$'\t'
  printf '%s\n' "$*" >>"$RECORD_FILE" || { echo "ERROR: cannot append to $RECORD_FILE" >&2; exit 1; }
}
```

Next to the counters at lines 320-322, add `subskipped_names=()`.

- [ ] **Step 3: Loop changes (duration, sub-case skips, records).** Change the loop header to `for t in ${tests[@]+"${tests[@]}"}; do`. A shard can own zero tests when N exceeds the test count, and bash 3.2 treats an empty `"${tests[@]}"` as unbound. Wrap the test's execution in timing and count its sub-case skips:

```bash
  started=$SECONDS
  _portable_timeout "$this_timeout" /bin/bash -p "$t" >"$out_file" 2>&1
  rc=$?
  dur=$((SECONDS - started))
  last="$(grep -vE '^[[:space:]]*$' "$out_file" | tail -n1)"
  # Sub-case skips (#821 residual): a suite that ends on its pass/fail summary can still
  # have skipped rows mid-file, which the verdict below cannot see. Shown, not failed —
  # see the plan's decision table. Matches SKIP after an optional non-alphanumeric prefix
  # ("  SKIP:", "⏭️  SKIP:", "↳ SKIP:", "[SKIP]") or after an optional "label:" prefix
  # ("test_af: SKIP —"), the formats the suites use today. A format outside these shapes
  # is not counted; the count is informational, so a miss only hides a line from the log.
  SUBSKIP_RE='^[^[:alnum:]]*([[:alnum:]_.-]+:[[:space:]]*)?\[?SKIP\]?([:[:space:]]|$)'
  subskips="$(grep -cE "$SUBSKIP_RE" "$out_file" || true)"
```

In the branches:
- **Allowed-SKIP branch:** print `echo "SKIP: $base (${dur}s) — ${last#SKIP:}"`, then `record DONE "$base" SKIP "$dur" 0`.
- **Unexpected-skip FAIL branch:** add `record DONE "$base" FAIL "$dur" 0`.
- **PASS branch:** replace `echo "PASS: $base"` with:

```bash
    if [[ "$subskips" -gt 0 ]]; then
      echo "PASS: $base (${dur}s, ${subskips} sub-case SKIP)"
      grep -E "$SUBSKIP_RE" "$out_file" | head -n 3 | sed 's/^/    ~ /'
      subskipped_names+=("$base")
    else
      echo "PASS: $base (${dur}s)"
    fi
    record DONE "$base" PASS "$dur" "$subskips"
```

- **rc≠0 FAIL branch:** change the two echo lines to append ` (${dur}s)`, and add `record DONE "$base" FAIL "$dur" 0` beside `fail=$((fail + 1))`.

- [ ] **Step 4: Summary.** After the loop's `done`, add `record END "$((pass + skip + fail))"`. After the existing `skipped:` line, add:

```bash
[[ "${#subskipped_names[@]}" -gt 0 ]] && printf 'sub-case skips in: %s\n' "${subskipped_names[*]}"
```

- [ ] **Step 5: The `reconcile_shards` function.** Place it right after `shard_members`:

```bash
# reconcile_shards <N> <dir> <discovered-list-file> — the aggregate `shell-tests` verdict.
# Every test the LIVE glob discovers must be ASSIGNED by exactly one shard and carry
# exactly one DONE line with a PASS/SKIP verdict; shards 1..N must each have produced
# exactly one record with a matching N header and an END line. Anything else fails,
# naming the test or shard. A shard that never ran (skipped, cancelled, crashed before
# writing) has no record file at all, which reads as "no record".
# Per-file protocol, mirroring exactly what the runner writes: two-field N and SHARD
# headers, one END as the last line whose count equals the file's DONE lines, numeric
# DONE fields, every DONE naming a test the same file ASSIGNED, and no record file
# without a valid SHARD line. A truncated or spliced record therefore fails.
reconcile_shards() {
  local n="$1" dir="$2" listf="$3" f
  # awk never visits a zero-byte file, so an empty stray record would slip past the
  # per-file checks below; refuse it here instead.
  for f in "$dir"/shell-shard-*.tsv; do
    [ -s "$f" ] || { echo "RECONCILE FAIL: $f: empty record file"; return 1; }
  done
  awk -F'\t' -v n="$n" -v listf="$listf" '
    function err(m) { print "RECONCILE FAIL: " m; bad = 1 }
    FILENAME == listf { disc[$0] = 1; nd++; next }
    FILENAME != cur { cur = FILENAME; nrec++; sh = ""; fended = 0; fdone = 0 }
    fended { err(FILENAME ":" FNR ": line after END"); next }
    FNR == 1 { if ($1 != "N" || $2 != n || NF != 2) err(FILENAME ": header is not N\t" n); next }
    FNR == 2 {
      if ($1 != "SHARD" || NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > n) { err(FILENAME ": bad SHARD line"); next }
      sh = $2; seen[sh]++; nseen++; next
    }
    $1 == "ASSIGNED" && NF == 2 { assigned[$2]++; inshard[FILENAME, $2] = 1; next }
    $1 == "DONE" && NF == 5 {
      if ($4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/) { err(FILENAME ":" FNR ": non-numeric DONE field"); next }
      if (!((FILENAME, $2) in inshard)) err(FILENAME ": DONE for a test this shard did not ASSIGN: " $2)
      done[$2]++; fdone++; verdict[$2] = $3; dur[$2] = $4; next
    }
    $1 == "END" && NF == 2 {
      if ($2 !~ /^[0-9]+$/ || $2 + 0 != fdone) err(FILENAME ": END count " $2 " != " fdone " DONE lines")
      fended = 1; if (sh != "") ended[sh] = 1; next
    }
    { err(FILENAME ":" FNR ": unrecognised record line") }
    END {
      if (nrec != nseen) err((nrec - nseen) " record file(s) without a valid SHARD line")
      for (s = 1; s <= n; s++) {
        if (!(s in seen)) err("shard " s "/" n ": no record (shard missing, skipped or cancelled)")
        else if (seen[s] > 1) err("shard " s "/" n ": more than one record")
        else if (!(s in ended)) err("shard " s "/" n ": record has no END line (shard did not finish)")
      }
      for (t in disc) {
        if (!(t in assigned)) err("unassigned: " t)
        else if (assigned[t] > 1) err("assigned twice: " t)
        else if (!(t in done)) err("missing completion record: " t)
        else if (done[t] > 1) err("completion recorded twice: " t)
        else if (verdict[t] != "PASS" && verdict[t] != "SKIP") err("not passing: " t " (" verdict[t] ")")
      }
      for (t in assigned) if (!(t in disc)) err("assigned but not discovered: " t)
      for (t in done) if (!(t in assigned)) err("completed but never assigned: " t)
      if (bad) exit 1
      for (t in done) print "duration\t" t "\t" dur[t]
      print "OK: reconciled " nd " discovered tests across " n " shards"
    }' "$listf" "$dir"/shell-shard-*.tsv
}
```

`nullglob` is already on when this runs, so a directory with no records passes only `$listf`. Every shard then reports "no record".

The per-file protocol checks mirror exactly what the runner writes:
- a single END, as the file's last line;
- END's count equals that file's DONE lines, because the runner writes `END $((pass+skip+fail))` and one DONE per verdict;
- numeric duration and sub-skip fields;
- every DONE names a test the same file ASSIGNED.

A record that is truncated, spliced or hand-edited therefore fails. Truncation is what a killed leg leaves behind; splicing would come from artifact-merge confusion. The `duration` lines are the refresh source for the weights file (see Task 4).

- [ ] **Step 6: Weights file.** Generate it from the measured CI log. This is the exact command, and its output is committed as-is:

```bash
gh api --allow-escape-sequences repos/chris-yyau/busdriver/actions/jobs/108627491973/logs >/tmp/st883.log
python3 - /tmp/st883.log >scripts/ci/shell-test-durations.tsv <<'EOF'
import sys, re, datetime
prev = None; rows = []
for l in open(sys.argv[1], errors="replace"):
    m = re.match(r"(\d{4}-\S+?)\.\d+Z (.*)", l.rstrip())
    if not m: continue
    ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    body = re.sub(r"\x1b\[[0-9;]*m", "", m.group(2))
    if body.startswith("Discovered"): prev = ts
    mm = re.match(r"(PASS|SKIP|FAIL[^:]*): (\S+)", body)
    if mm and prev:
        rows.append((max(int((ts - prev).total_seconds()), 1), mm.group(2))); prev = ts
rows.sort(key=lambda r: (-r[0], r[1]))
print("# Partition weights for scripts/ci/run-shell-tests.sh --shard (seconds, CI-measured).")
print("# Source: Tests run 36321967050 job 108627491973 (PR #883), 2026-09-27. Balance only —")
print("# correctness comes from --reconcile. Refresh: see docs/ci/shell-test-inventory.md.")
for s, n in rows: print(f"{n}\t{s}")
EOF
```

Expected: 3 comment lines and 156 data lines. The first data line is `test-litmus-mode-transition\t760`.

- [ ] **Step 7: Smoke test the modes.**

```bash
for i in 1 2 3 4; do /bin/bash -p scripts/ci/run-shell-tests.sh --list-shard $i/4 | wc -l; done
/bin/bash -p scripts/ci/run-shell-tests.sh --list-shard 1/4 | head -3
/bin/bash -p scripts/ci/run-shell-tests.sh --list-shard 5/4; echo rc=$?
```

Expected: four counts summing to 156. Shard 1 lists `test-litmus-mode-transition` first. The last command prints the usage and `rc=2`.

- [ ] **Step 8: ShellCheck.** Run `shellcheck -S warning scripts/ci/run-shell-tests.sh`. Expected: no output.

### Task 2: Regression suite `tests/test-shell-test-sharding.sh`

**Files:**
- Create: `tests/test-shell-test-sharding.sh`

**Interfaces:**
- Consumes: the Task 1 CLI, the record format and `SHELL_TEST_DURATIONS`.

- [ ] **Step 1: Write the suite.**

```bash
#!/bin/bash
# Shard partition + aggregate reconciliation for scripts/ci/run-shell-tests.sh
# (0827 roadmap item 5; docs/plans/2026-09-27-ci-shard-shell-tests.md).
# Drives --list-shard / --reconcile, plus ONE --shard run whose weights pin a single
# fast, hermetic suite onto shard 1 — never this file — so it cannot recurse into the
# suite that runs it. bash 3.2 compatible.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable only so the plan's mutation proof can point the suite at a mutant; CI never sets it.
R="${SHELL_TEST_RUNNER:-$ROOT/scripts/ci/run-shell-tests.sh}"
pass=0 fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
run() { /bin/bash -p "$R" "$@"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TAB="$(printf '\t')"

all="$(cd "$ROOT" && for t in tests/test-*.sh; do b=${t##*/}; echo "${b%.sh}"; done | LC_ALL=C sort)"

echo "── partition ──"
for n in 1 3 4 7; do
  : >"$TMP/union"
  for i in $(seq 1 "$n"); do run --list-shard "$i/$n" >>"$TMP/union" || bad "list-shard $i/$n rc!=0"; done
  if [ "$(LC_ALL=C sort "$TMP/union")" = "$all" ]; then ok "N=$n: shards disjoint, union == live glob"
  else bad "N=$n: partition != live glob"; fi
done
[ "$(run --list-shard 2/4)" = "$(run --list-shard 2/4)" ] && ok "partition is deterministic" || bad "partition not deterministic"

printf '# no weights\n' >"$TMP/empty.tsv"
: >"$TMP/union"
for i in 1 2 3 4; do SHELL_TEST_DURATIONS="$TMP/empty.tsv" run --list-shard "$i/4" >>"$TMP/union"; done
[ "$(LC_ALL=C sort "$TMP/union")" = "$all" ] && ok "tests absent from the weights file are still assigned" || bad "unweighted tests dropped"

heavy="$(printf '%s\n' "$all" | head -n1)"
printf '%s\t100000\n' "$heavy" >"$TMP/heavy.tsv"
[ "$(SHELL_TEST_DURATIONS="$TMP/heavy.tsv" run --list-shard 1/2)" = "$heavy" ] && ok "weights are honoured (heaviest test alone on shard 1)" || bad "weights ignored"

printf 'test-x\tnot-a-number\n' >"$TMP/bad.tsv"
SHELL_TEST_DURATIONS="$TMP/bad.tsv" run --list-shard 1/2 >/dev/null 2>&1 && bad "malformed weights accepted" || ok "malformed weights file fails closed"
SHELL_TEST_DURATIONS="$TMP/nope.tsv" run --list-shard 1/2 >/dev/null 2>&1 && bad "missing weights accepted" || ok "missing weights file fails closed"

echo "── argument validation ──"
for args in "--list-shard 5/4" "--list-shard 0/4" "--list-shard x/4" "--shard 1/4" "--shard 1/4 --record rel.tsv" "--reconcile 0 /tmp" "--reconcile 4 rel" "--bogus"; do
  # shellcheck disable=SC2086  # deliberate word-split of the case's argv
  run $args >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "rejects: $args" || bad "rc=$rc for: $args (want 2)"
done

echo "── record writer ──"
# One real --shard run: the weights pin test-upstream-manifest (hermetic, ~1s) alone onto
# shard 1 of 2, so the writer's actual output is checked, not a hand-built fixture.
# Recursion guard: the pinned shard must own exactly that fixture, and the fixture must
# exist — a renamed fixture would otherwise put every test (this suite included) on the
# shard and make this real run recurse.
fast=test-upstream-manifest
printf '%s\t100000\n' "$fast" >"$TMP/fast.tsv"
owned="$(SHELL_TEST_DURATIONS="$TMP/fast.tsv" run --list-shard 1/2)"
if [ "$owned" != "$fast" ] || [ ! -f "$ROOT/tests/$fast.sh" ]; then
  bad "record-writer fixture shard owns '$owned', not '$fast' — refusing the real run"
elif SHELL_TEST_DURATIONS="$TMP/fast.tsv" run --shard 1/2 --record "$TMP/written.tsv" >"$TMP/shard.out" 2>&1 \
  && awk -F'\t' -v t="$fast" '
       NR == 1 { ok = ($0 == "N\t2") }
       NR == 2 { ok = ok && ($0 == "SHARD\t1") }
       NR == 3 { ok = ok && ($0 == "ASSIGNED\t" t) }
       NR == 4 { ok = ok && NF == 5 && $1 == "DONE" && $2 == t && $3 == "PASS" && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ }
       NR == 5 { ok = ok && ($0 == "END\t1") }
       END { exit !(ok && NR == 5) }' "$TMP/written.tsv"; then
  ok "--shard writes N/SHARD/ASSIGNED/DONE/END for the tests it ran"
else
  bad "--shard record wrong"; sed 's/^/      /' "$TMP/written.tsv" "$TMP/shard.out" 2>/dev/null | tail -n 12
fi

echo "── reconcile ──"
mkrec() {   # <dir> <n> — a complete, passing record set for the real partition
  local d="$1" n="$2" i t
  mkdir -p "$d"
  for i in $(seq 1 "$n"); do
    run --list-shard "$i/$n" >"$TMP/m$i"
    { printf 'N\t%s\nSHARD\t%s\n' "$n" "$i"
      while IFS= read -r t; do printf 'ASSIGNED\t%s\n' "$t"; done <"$TMP/m$i"
      while IFS= read -r t; do printf 'DONE\t%s\tPASS\t1\t0\n' "$t"; done <"$TMP/m$i"
      printf 'END\t%s\n' "$(wc -l <"$TMP/m$i" | tr -d ' ')"
    } >"$d/shell-shard-$i.tsv"
  done
}
drop() { grep -v -F -x "$2" "$1" >"$1.new"; mv "$1.new" "$1"; }   # <file> <exact line>
# reend <file> — move END back to the last line with the file's current DONE count, so a
# fixture mutation trips only the rule it targets and not the END-count check.
reend() { grep -v '^END' "$1" >"$1.new"; printf 'END\t%s\n' "$(grep -c '^DONE' "$1.new")" >>"$1.new"; mv "$1.new" "$1"; }
addrec() { local f="$1"; shift; printf '%s\n' "$@" >>"$f"; reend "$f"; }   # <file> <line>... (lands before END)
expect_ok() {   # <label> <dir> <n>
  local out
  if out="$(run --reconcile "$3" "$2" 2>&1)" && printf '%s\n' "$out" | grep -q '^OK: reconciled'; then ok "$1"
  else bad "$1"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'; fi
}
expect_fail() {   # <label> <dir> <n> <needle>
  local out rc
  out="$(run --reconcile "$3" "$2" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "$4"; then ok "$1"
  else bad "$1 (rc=$rc, wanted '$4')"; printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'; fi
}

mkrec "$TMP/good" 4
victim="$(head -n1 "$TMP/m2")"
expect_ok "complete record set reconciles" "$TMP/good" 4
vdone="DONE${TAB}$victim${TAB}PASS${TAB}1${TAB}0"

c="$TMP/skipok"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; addrec "$c/shell-shard-2.tsv" "DONE${TAB}$victim${TAB}SKIP${TAB}1${TAB}0"
expect_ok "a SKIP verdict (runner-allowed) reconciles" "$c" 4

c="$TMP/unassigned"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "ASSIGNED${TAB}$victim"; drop "$c/shell-shard-2.tsv" "$vdone"; reend "$c/shell-shard-2.tsv"
expect_fail "a test no shard owned fails as unassigned" "$c" 4 "unassigned: $victim"

c="$TMP/twice"; cp -R "$TMP/good" "$c"
addrec "$c/shell-shard-3.tsv" "ASSIGNED${TAB}$victim" "$vdone"
expect_fail "a test owned by two shards fails as assigned twice" "$c" 4 "assigned twice: $victim"

c="$TMP/nodone"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; reend "$c/shell-shard-2.tsv"
expect_fail "an assigned test with no DONE fails as missing completion record" "$c" 4 "missing completion record: $victim"

c="$TMP/noshard"; cp -R "$TMP/good" "$c"; rm "$c/shell-shard-4.tsv"
expect_fail "a missing shard record fails" "$c" 4 "shard 4/4: no record"

c="$TMP/noend"; cp -R "$TMP/good" "$c"; grep -v '^END' "$c/shell-shard-1.tsv" >"$c/x"; mv "$c/x" "$c/shell-shard-1.tsv"
expect_fail "a record without END (shard did not finish) fails" "$c" 4 "shard 1/4: record has no END line"

c="$TMP/failed"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; addrec "$c/shell-shard-2.tsv" "DONE${TAB}$victim${TAB}FAIL${TAB}1${TAB}0"
expect_fail "a FAIL verdict fails the aggregate" "$c" 4 "not passing: $victim"

expect_fail "an N mismatch (matrix vs --reconcile) fails" "$TMP/good" 3 "header is not N"

c="$TMP/ghost"; cp -R "$TMP/good" "$c"
addrec "$c/shell-shard-1.tsv" "ASSIGNED${TAB}test-does-not-exist" "DONE${TAB}test-does-not-exist${TAB}PASS${TAB}1${TAB}0"
expect_fail "a record naming an undiscovered test fails" "$c" 4 "assigned but not discovered: test-does-not-exist"

echo "── record protocol ──"
c="$TMP/afterend"; cp -R "$TMP/good" "$c"
printf 'DONE\t%s\tPASS\t1\t0\n' "$victim" >>"$c/shell-shard-2.tsv"
expect_fail "a line after END fails" "$c" 4 "line after END"

c="$TMP/endcount"; cp -R "$TMP/good" "$c"
grep -v '^END' "$c/shell-shard-2.tsv" >"$c/x"; printf 'END\t999\n' >>"$c/x"; mv "$c/x" "$c/shell-shard-2.tsv"
expect_fail "an END count that disagrees with the DONE lines fails" "$c" 4 "END count 999"

c="$TMP/nonnum"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; addrec "$c/shell-shard-2.tsv" "DONE${TAB}$victim${TAB}PASS${TAB}x${TAB}0"
expect_fail "a non-numeric DONE duration fails" "$c" 4 "non-numeric DONE field"

c="$TMP/crossfile"; cp -R "$TMP/good" "$c"
drop "$c/shell-shard-2.tsv" "$vdone"; reend "$c/shell-shard-2.tsv"; addrec "$c/shell-shard-3.tsv" "$vdone"
expect_fail "a DONE in a shard that did not ASSIGN the test fails" "$c" 4 "did not ASSIGN: $victim"

c="$TMP/headeronly"; cp -R "$TMP/good" "$c"; printf 'N\t4\n' >"$c/shell-shard-9.tsv"
expect_fail "a header-only extra record file fails" "$c" 4 "without a valid SHARD line"

c="$TMP/extrafield"; cp -R "$TMP/good" "$c"
{ printf 'N\t4\textra\n'; tail -n +2 "$TMP/good/shell-shard-1.tsv"; } >"$c/shell-shard-1.tsv"
expect_fail "a header with extra fields fails" "$c" 4 "header is not N"

c="$TMP/emptyfile"; cp -R "$TMP/good" "$c"; : >"$c/shell-shard-9.tsv"
expect_fail "a zero-byte extra record file fails" "$c" 4 "empty record file"

mkdir -p "$TMP/emptydir"
expect_fail "no records at all (every shard skipped) fails" "$TMP/emptydir" 4 "shard 1/4: no record"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it.** Run `/bin/bash -p tests/test-shell-test-sharding.sh`. Expected: `Results: 36 passed, 0 failed`. That is 17 partition and argument cases (4 partition, 1 determinism, 1 unweighted, 1 weights, 2 weights-file failures, 8 argument cases), 1 record-writer case (a real `--shard --record` run behind the recursion guard), 10 reconcile cases and 8 record-protocol cases. Exit 0. The record-writer fixture `test-upstream-manifest` needs `jq`, like much of the suite; CI and um have it.

- [ ] **Step 3: Prove the guard can fail, against a mutant.**
  - The mutant must live inside the repo tree, because the runner derives `REPO_ROOT` from its own path and sources `scripts/lib/resolve-cli.sh`.
  - The mutation replaces the `err(...)` call with an empty block, which keeps the `else if` chain valid awk. The flip therefore comes from the missing guard and not from a syntax error.

```bash
M=scripts/ci/.mutant-run-shell-tests.sh
trap 'rm -f "$M"' EXIT
sed 's/if (!(t in assigned)) err("unassigned: " t)/if (!(t in assigned)) { }/' scripts/ci/run-shell-tests.sh >"$M"
grep -c 'if (!(t in assigned)) { }' "$M"                      # expect 1: the mutation applied
SHELL_TEST_RUNNER="$PWD/$M" /bin/bash -p tests/test-shell-test-sharding.sh | grep -E '^  FAIL|^Results'
rm -f "$M"; trap - EXIT
/bin/bash -p tests/test-shell-test-sharding.sh | tail -n 1      # original runner
```

  Expected results:
  - The mutant run shows exactly one `FAIL  a test no shard owned fails as unassigned` and `Results: 35 passed, 1 failed`.
  - The original run shows `Results: 36 passed, 0 failed`.
  - Record both lines in the commit message.

- [ ] **Step 4: Linux awk (mawk).** CI's `awk` is mawk. Run the suite on the Linux executor with a command that only reads:

```bash
um-run test -- /bin/bash -p tests/test-shell-test-sharding.sh
```

  Expected: `Results: 36 passed, 0 failed`. Check `exit_code: 0` and `verified: true` in the evidence JSON; the terminal pipeline's status is not the command's. The um snapshot is not a git checkout, but this suite needs none.

- [ ] **Step 5: ShellCheck and commit.** Run `shellcheck -S warning tests/test-shell-test-sharding.sh`; expected clean. Commit Tasks 1-2 together, going through litmus:

```bash
git add scripts/ci/run-shell-tests.sh scripts/ci/shell-test-durations.tsv tests/test-shell-test-sharding.sh
git commit -m "feat(ci): shard-aware shell-test runner with live-glob reconciliation"
```

### Task 3: Workflow matrix, aggregate and lock

**Files:**
- Modify: `.github/workflows/tests.yml:358-430` (the `shell-tests` job).
- Modify: `.github/required-checks.lock`

**Interfaces:**
- Consumes: `--shard I/N --record FILE`, `--reconcile N DIR` and the record file name `shell-shard-<i>.tsv`.
- Produces: contexts `shell-tests-shard (1)` … `shell-tests-shard (4)` (advisory) and `shell-tests` (required, unchanged name).

- [ ] **Step 1: Rename the existing job to the shard job.** Change its key from `shell-tests:` to `shell-tests-shard:` and keep its existing comment block verbatim. Append this paragraph to that comment block:

```yaml
    # Sharded 2026-09-27 (0827 roadmap item 5, docs/plans/2026-09-27-ci-shard-shell-tests.md):
    # 4 legs, each running the duration-balanced slice run-shell-tests.sh --shard computes
    # from the live glob. Measured unsharded: 2418s of tests, 2459s job. The heaviest leg
    # is bounded by test-litmus-mode-transition (760s CI). 40 minutes sits above that
    # suite's 1500s per-test override, so the per-test timeout, which names the suite,
    # stays the binding constraint. The number 4 appears three times (matrix, --shard,
    # --reconcile). A mismatch fails the aggregate closed (N header mismatch or missing
    # shard), never open.
```

Replace `timeout-minutes: 60` with `timeout-minutes: 40`, and add after `runs-on`:

```yaml
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
```

Replace the final `Full shell gate-test suite` step's `name` and `run` (keep its comment) with:

```yaml
      - name: Shell gate-test shard
        env:
          SHARD: ${{ matrix.shard }}
        run: /bin/bash -p scripts/ci/run-shell-tests.sh --shard "${SHARD}/4" --record "${RUNNER_TEMP}/shell-shard-${SHARD}.tsv"
      - name: Upload shard record
        if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: shell-shard-${{ matrix.shard }}
          path: ${{ runner.temp }}/shell-shard-${{ matrix.shard }}.tsv
          if-no-files-found: error
          # A re-run of a leg re-uploads the same name; upload-artifact defaults to
          # overwrite: false and would fail the re-run at this step.
          overwrite: true
          # 7, not 1: "Re-run failed jobs" re-runs one leg plus the aggregate, which then
          # needs the passing legs' records from the earlier attempt.
          retention-days: 7
```

- [ ] **Step 2: Add the aggregate job** directly after the shard job:

```yaml
  shell-tests:
    # The REQUIRED check (branch protection + .github/required-checks.lock). It runs even
    # when shards failed, were cancelled or were skipped, and it fails unless (1) every test
    # the live glob discovers at THIS commit was assigned to exactly one shard and has
    # exactly one passing completion record, and (2) the shard matrix itself succeeded.
    # A static partition checked once at cutover could not see a test added later; this
    # check runs on every run (docs/plans/2026-09-27-ci-shard-shell-tests.md). `if: always()`
    # is what keeps this context from posting `skipped`, which GitHub would count as
    # satisfying a required check (#632's trap).
    needs: shell-tests-shard
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1 # v2.21.1
        with:
          egress-policy: audit
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Download shard records
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          pattern: shell-shard-*
          path: ${{ runner.temp }}/shell-shards
          merge-multiple: true
      - name: Reconcile shards against the live test glob
        if: always()
        run: /bin/bash -p scripts/ci/run-shell-tests.sh --reconcile 4 "${RUNNER_TEMP}/shell-shards"
      - name: Every shard job succeeded
        if: always()
        env:
          SHARDS_RESULT: ${{ needs.shell-tests-shard.result }}
        run: |
          echo "shell-tests-shard result: ${SHARDS_RESULT}"
          test "${SHARDS_RESULT}" = success
```

- [ ] **Step 3: Lock entries.** In `.github/required-checks.lock`, leave `required` untouched and append to `advisory`:

```json
    {
      "name": "shell-tests-shard (1)",
      "source_app": "github-actions",
      "workflow": ".github/workflows/tests.yml",
      "job": "shell-tests-shard",
      "matrix_value": "1"
    },
```

Add the same entry for `2`, `3` and `4`. Also add one `_doc` string after the "Which list a check belongs in" block:

```json
    "shell-tests-shard (N) legs are advisory because the required `shell-tests` aggregate fails on any failed, cancelled or missing shard; the legs are diagnostics, and branch protection gates only the aggregate.",
```

- [ ] **Step 4: Verify locally.**

```bash
bash scripts/check-required-checks.sh --local-only
/bin/bash -p tests/test-required-checks-lock-classification.sh
python3 -c "import json;json.load(open('.github/required-checks.lock'))"
```

Expected: `check-required-checks.sh --local-only` exits 0, and surfaces (a), (d) and (e) report no drift for the four new shard contexts (`shell-tests` itself is unchanged). The classification suite ends green and the JSON parses.

- [ ] **Step 5: Commit** through litmus:

```bash
git add .github/workflows/tests.yml .github/required-checks.lock
git commit -m "ci(shell-tests): 4-leg duration-balanced matrix behind the shell-tests aggregate"
```

### Task 4: Docs

**Files:**
- Modify: `docs/ci/shell-test-inventory.md`

- [ ] **Step 1: Append this section:**

```markdown
## Sharding (2026-09-27)

CI runs the suite as `shell-tests-shard (1..4)`: advisory legs, each executing the
slice `run-shell-tests.sh --shard I/4` computes from the live glob and
`scripts/ci/shell-test-durations.tsv` (longest-first greedy; unknown tests weigh
10s). The REQUIRED `shell-tests` check is an aggregate that runs `if: always()` and
`--reconcile`s the legs' completion records against the glob at the same commit: a
test that is unassigned, assigned twice, missing its completion record, or not passing
fails it, as does a missing/unfinished leg. The weights only balance the legs;
correctness never depends on them being current.

Refresh the weights when a leg drifts well past the others. The aggregate prints one
`duration<TAB><test><TAB><seconds>` line per test. `gh run view --log` prefixes each
line with `<job><TAB><step><TAB><timestamp> `, and there is a SPACE after the
timestamp, so extract with awk (portable to macOS, unlike `grep -P`). The file's
3-line header comment is kept by hand; the command prints only the data lines, sorted by
seconds descending (0 s floored to 1 s, as in the committed file):

    gh run view <run-id> --job <aggregate-job-id> --log \
      | awk -F'\t' '{ sub(/^[^ ]* /, "", $3) } $3 == "duration" { print $4 "\t" ($5 < 1 ? 1 : $5) }' \
      | sort -t "$(printf '\t')" -k2,2nr -k1,1

Local runs (`bash scripts/ci/run-shell-tests.sh`, no args) still execute every test and
now print each test's duration and any mid-file sub-case `SKIP` lines.
```

- [ ] **Step 2: Commit.** Run `git add docs/ci/shell-test-inventory.md && git commit -m "docs(ci): shell-test sharding and weights refresh"`.
- [ ] **Step 3: Commit this plan** once its blueprint review has passed (code and docs cite it): `git add docs/plans/2026-09-27-ci-shard-shell-tests.md && git commit -m "docs(plans): shard CI shell-tests plan (roadmap item 5)"`, through litmus.

### Task 5: End-to-end verification on the PR

- [ ] **Step 1:** Open the PR through the pre-PR gate: litmus PR mode, then `gh pr create`.
- [ ] **Step 2:** On the PR's Tests run, confirm all of the following:
  - four `shell-tests-shard (i)` checks, each listing `Shard i/4: … of 157 discovered` (156 + the new suite);
  - the `shell-tests` aggregate prints `OK: reconciled 157 discovered tests across 4 shards` and passes;
  - the wait a PR author sees, measured, not the aggregate job's own ~1-minute duration. The metric is the aggregate's `completed_at` minus the earliest shard's `started_at`:

```bash
gh api "repos/chris-yyau/busdriver/actions/runs/<run-id>/jobs?per_page=100" --jq '
  [.jobs[] | select(.name | startswith("shell-tests"))] as $j
  | ($j | map(select(.name | startswith("shell-tests-shard"))) | map(.started_at | fromdateiso8601) | min) as $s
  | ($j | map(select(.name == "shell-tests"))[0].completed_at | fromdateiso8601) as $e
  | {wait_s: ($e - $s),
     legs: [$j[] | select(.name | startswith("shell-tests-shard"))
            | {name, s: ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601))}]}'
```

  Record `wait_s` and each leg's duration in the PR body. State the result explicitly:
  - PASS if `wait_s` ≤ 900 (the ~15-min target);
  - otherwise FAIL, naming the slowest leg.
  The floor is `test-litmus-mode-transition` at 760 s plus setup. Compare against the 2459 s unsharded baseline.
- [ ] **Step 3: pr-grind's view.** `scripts/relevant-check-status.sh` reads raw `gh pr checks` rows on stdin and takes the repo root as `$1`. It prints `<failed> <pending> <mode> <kept>`. Feed it the real rows, then two synthetic variants:

```bash
gh pr checks <PR> >/tmp/rows.txt || true            # gh exits non-zero while checks are pending
test -s /tmp/rows.txt                                # retrieval must have produced rows
bash scripts/relevant-check-status.sh "$PWD" </tmp/rows.txt
awk -F'\t' 'BEGIN{OFS="\t"} $1 ~ /^shell-tests-shard \(/ {$2="fail"} {print}' /tmp/rows.txt \
  | bash scripts/relevant-check-status.sh "$PWD"
awk -F'\t' 'BEGIN{OFS="\t"} $1 == "shell-tests" {$2="fail"} {print}' /tmp/rows.txt \
  | bash scripts/relevant-check-status.sh "$PWD"
```

  Expected results:
  - Every call reports mode `required`.
  - The real rows report `0 0 required 12` once green.
  - The legs-failed variant still reports failed=0, which confirms the legs are advisory.
  - The aggregate-failed variant reports failed=1, which confirms `shell-tests` is required.
  - **If `wait_s` > 900:** record the per-leg split. When a leg's setup (npm ci + zsh) is the excess, add `cache: npm` to the shard job's `setup-node` step. When `test-litmus-mode-transition` itself is the excess, split that suite. Both are follow-up issues, not blockers for this PR: the aggregate's correctness does not depend on the wait.

### Task 6: Bring the already-committed branch up to this revision

Commits `37b3b324`, `623a036c` and `1e6dacea` on `feat/ci-shard-shell-tests` implement the iteration-2 revision of this plan. The changes from the later review iterations still have to land as one commit, going through litmus. The target state of each file is the listing in Tasks 1–4; the steps below name the deltas against the branch:

- [ ] **Step 1: `overwrite: true`** on the `Upload shard record` step in `.github/workflows/tests.yml`, as shown in Task 3 Step 1.
- [ ] **Step 2: 1 s floor** in the refresh command in `docs/ci/shell-test-inventory.md`: `print $4 "\t" ($5 < 1 ? 1 : $5)`, as in Task 4.
- [ ] **Step 3: Recursion guard and empty-record case** in `tests/test-shell-test-sharding.sh`. Make the record-writer block and the `emptyfile` case match the Task 2 Step 1 listing exactly: the `owned=… --list-shard 1/2` check guards the real `--shard` run, and the new case expects `empty record file`.
- [ ] **Step 4: Empty-record check** in `scripts/ci/run-shell-tests.sh`: at the top of `reconcile_shards`, add the `[ -s "$f" ]` loop exactly as in the Task 1 Step 5 listing.
- [ ] **Step 5: Wording.**
  - In shard mode the summary line reads `ran=${#tests[@]}`. It counts the slice, not the discovered tests.
  - In the kept shard-job comment and `tests.yml`'s zsh/js-yaml comments (around lines 47 and 95), which refer to the job that installs zsh and runs the suite, `shell-tests` becomes `shell-tests-shard`. The same rename applies in `skills/council/SKILL.md` around line 207, and "Full shell gate-test suite" becomes "Shell gate-test shard". The kept comment block therefore changes by these names only; it is otherwise verbatim.
  - In Task 3 Step 4 the lock adds four contexts, not five.
- [ ] **Step 6: Verify.** The sharding suite reports `Results: 36 passed, 0 failed` on macOS and on um (mawk). Run `shellcheck -S warning` on the edited scripts, and run `check-required-checks.sh --local-only` and `zizmor .github/workflows/tests.yml`.

## Plan sanity check (done)

- **Spec coverage:**
  - per-test durations → Task 1 Step 3;
  - duration-balanced matrix → Tasks 1 and 3;
  - one aggregate named `shell-tests` with `if: always()`, failing on failed, cancelled or missing shards → Task 3 Step 2;
  - lock `matrix_value` entries → Task 3 Step 3;
  - sub-case skip exposure → Task 1 Step 3;
  - live-glob reconciliation on every run → Task 1 Step 5 and Task 3;
  - the three required regressions (unassigned, assigned twice, missing completion record) → Task 2;
  - measured durations rather than the 14.9-min baseline → Measured baseline and Task 1 Step 6;
  - #829 and #632 → decision table.
- **Placeholders:** none.
- **Names used consistently:** `shard_members`, `reconcile_shards`, `record`, `SHELL_TEST_DURATIONS`, `shell-shard-<i>.tsv` and `shell-tests-shard`.

**Execution:** in this session, not a Codex handoff. The workflow and lock changes can only be proven on a PR run, which needs judgment between steps.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
