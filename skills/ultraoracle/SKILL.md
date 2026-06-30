---
name: ultraoracle
description: >
  Standalone maintainer workflow for a single repo-grounded UltraOracle (GPT-5.5 Pro)
  expert-witness consult. Use when the user says "ultraoracle", "ask the oracle",
  "oracle consult", "repo-grounded oracle review", "upstream audit with oracle", or
  wants a high-cost external expert opinion on a design/plan/repo question that is
  attached as real evidence (not a peer-reviewer vote and not a gate). Implements
  ADR 0007 Phase 1: quick / repo / upstream-audit modes, review-type labeling,
  fail-closed handling, and a documented evidence boundary. NOT for routine review —
  use litmus/blueprint-review/council for that.
origin: custom
---

# UltraOracle — Repo-Grounded Expert Witness (standalone)

UltraOracle is an **expert witness, not a vote and not a judge** (ADR 0007). Its
output is advisory; it is high-signal only when backed by real attached evidence
and validated downstream. This skill is the standalone maintainer surface — it does
not gate anything and does not feed blueprint-review yet (that is Phase 4).

## Security / data boundary (read first)

- UltraOracle transmits your prompt + attached files to ChatGPT Pro via the `oracle`
  browser engine. Only run it when the content carries **no secrets**.
- Enablement is **user-config only** (`~/.claude/busdriver.json` → `ultraOracle.*`).
  Repo/project config can never enable transmission. Do not add an enable flag to repo config.
- The evidence-pack script excludes secret-like files with **no override path**.
  If a file you need is being excluded, sanitize it — do not bypass the filter.

## Modes

| Mode | What is sent | Resulting label (decided by the pack, not by you) |
|------|--------------|---------------------------------------------------|
| `quick` | prompt + small inline `--context` text only | `ORACLE_SUMMARY_REVIEW` |
| `repo` | deterministic evidence pack with **raw repo files** attached | `ORACLE_REPO_ATTACHED_REVIEW` |
| `upstream-audit` | repo evidence + inventory of upstream paths | `ORACLE_REPO_ATTACHED_REVIEW` if raw files attached, else `ORACLE_SUMMARY_REVIEW` |
| `retrieval-loop` | two-round Oracle-directed retrieval | Implemented as the **separate** `run-retrieval-loop.sh` (default-OFF — see "Phase 5 retrieval loop" below), which emits `ORACLE_RETRIEVAL_REVIEW` only via the validated wrapper. It is **not** a `build-evidence-pack.sh` mode: that script still rejects `--mode retrieval-loop`. |

The label is whatever `build-evidence-pack.sh` prints — it is determined by what was
**actually attached**, so a summary-only consult can never masquerade as a repo review
(ADR settling check #2). Never relabel by hand.

## Procedure

Set `RUN_ID`, build the pack (for `repo`/`upstream-audit`), dispatch through the shared
adapter, then render the verdict under its label. Run as ONE Bash block so a failing
adapter cannot leave a half-state.

```bash
# NOTE: deliberately NOT `set -e`. ultra_oracle_consult PRINTS a typed status token
# (ok|error|timeout|skipped:*) AND returns non-zero on failure — we MUST capture the
# token and render ORACLE_FAILED, so errexit (which would abort before the case) is
# wrong here. Each external call is handled explicitly instead.
set -uo pipefail
PR="${CLAUDE_PLUGIN_ROOT}"
# STATE must resolve INSIDE the repo — build-evidence-pack.sh refuses an --out-dir
# outside GIT_ROOT, so an absolute BUSDRIVER_STATE_DIR elsewhere would fail closed.
STATE="${BUSDRIVER_STATE_DIR:-.claude}"
RUN_ID="ultraoracle-$$"
WORK="$STATE/ultra-oracle"
PACK_DIR="$WORK/$RUN_ID"          # the script CREATES this; it must NOT pre-exist
QUESTION="$WORK/q-$RUN_ID.txt"    # question lives OUTSIDE the pack dir (no self-copy)
OUT="$WORK/verdict-$RUN_ID.md"    # verdict also outside the pack dir
mkdir -p "$WORK"                  # parent only — never pre-create PACK_DIR

# 1. Write the question/design into $QUESTION (injection-safe; passed as --prompt-file).
#    (Claude writes the actual question text into "$QUESTION" before this block.)

# 2. Build the evidence pack for repo modes. LABEL is the LAST stdout line.
LABEL="ORACLE_SUMMARY_REVIEW"   # quick mode default
MODE="repo"                      # set per the user's request: repo | upstream-audit | quick
PACK_ARGS=()    # repeated --file / --upstream you chose; declared so [@] is safe when empty
PACK_ATTACH=()  # declared up front so "${PACK_ATTACH[@]}" never trips set -u on bash 3.2
if [ "$MODE" = "repo" ] || [ "$MODE" = "upstream-audit" ]; then
  # Pass the files you deliberately chose to attach via repeated --file, and
  # upstream paths via --upstream. Keep the set minimal and secret-free.
  # Guard the empty-array expansion (bash 3.2 + set -u): "${arr[@]}" on an empty
  # array aborts, so branch on the element count.
  if [ "${#PACK_ARGS[@]}" -gt 0 ]; then
    LABEL="$(bash "$PR/skills/ultraoracle/scripts/build-evidence-pack.sh" \
              --mode "$MODE" --out-dir "$PACK_DIR" --question-file "$QUESTION" \
              "${PACK_ARGS[@]}" | tail -n1)" \
      || { echo "⚠ ULTRAORACLE: evidence pack failed — ABORTING (fail closed)"; exit 1; }
  else
    LABEL="$(bash "$PR/skills/ultraoracle/scripts/build-evidence-pack.sh" \
              --mode "$MODE" --out-dir "$PACK_DIR" --question-file "$QUESTION" \
              | tail -n1)" \
      || { echo "⚠ ULTRAORACLE: evidence pack failed — ABORTING (fail closed)"; exit 1; }
  fi
  # Attach every file the pack collected (globs that match nothing are skipped by -f).
  for f in "$PACK_DIR"/files/* "$PACK_DIR"/git-*.txt "$PACK_DIR"/upstream-*.txt; do
    [ -f "$f" ] && PACK_ATTACH+=(--context "$f")
  done
fi

# 3. Dispatch via the shared adapter (the ONLY surface that touches the oracle CLI).
#    On any non-zero return, force STATUS=error so the case below renders ORACLE_FAILED.
source "$PR/scripts/lib/ultra-oracle.sh"
# The adapter PRINTS its typed token (ok|timeout|error|skipped:*) even on non-zero
# exit, and there is no `set -e` here, so the capture keeps that token. Only default
# to "error" when nothing was printed — never clobber a specific diagnostic token.
if [ "${#PACK_ATTACH[@]}" -gt 0 ]; then
  STATUS="$(ultra_oracle_consult --prompt-file "$QUESTION" \
    "${PACK_ATTACH[@]}" --out "$OUT" --mode blocking --slug "ultra oracle consult")"
else
  STATUS="$(ultra_oracle_consult --prompt-file "$QUESTION" \
    --out "$OUT" --mode blocking --slug "ultra oracle consult")"
fi
[ -n "$STATUS" ] || STATUS="error"

# 4. Render under label, fail-closed. `ok` AND a non-empty verdict are BOTH required —
#    defense in depth even though the adapter already maps exit-0-but-empty to a failure.
case "$STATUS" in
  ok)
    if [ -s "$OUT" ]; then
      echo "## UltraOracle Expert Witness — [$LABEL]"
      cat "$OUT"
    else
      echo "## ⚠ ORACLE_FAILED [empty-verdict] — adapter returned ok but $OUT is empty"
    fi ;;
  *)
    echo "## ⚠ ORACLE_FAILED [$STATUS] — no usable verdict (NOT silently omitted)" ;;
esac
```

## Rendering rules

- Always print the label (`ORACLE_*`) next to the verdict. A repo-specific claim with
  no file/path/search evidence is **ungrounded** — say so explicitly.
- On `timeout` / `error` / `skipped:*` / empty verdict → render a loud `ORACLE_FAILED`
  banner. Never drop the failure silently (ADR settling check #6).
- The verdict is advisory. Do not let it flip a decision without independent local
  evidence (grep / Read / run). Oracle raises issues; you and the arbiter decide if they're real.

## What this skill documents

Every run leaves an auditable trail in `$PACK_DIR`: `manifest.txt` (run id, repo root,
git SHA, byte budget, every attached file, every secret/budget exclusion, the label),
`question.txt`, git context, and the raw `verdict.md`. That manifest is the record of
exactly what evidence was sent.

## Phase 5 retrieval loop (ADR 0007 Phase 5)

An Oracle-directed, two-round alternative to the single-shot evidence pack: the Oracle
first says what it needs, Busdriver retrieves it read-only, then the Oracle reviews only
that evidence. The deterministic core lives in `scripts/`:

- **`lib/evidence-safety.sh`** — sourceable secret-scan + repo-containment gates
  (`is_secret_basename`/`is_secret_path`/`is_secret_like`/`contained_path`/`bytes_of`/
  `emit_nonsecret_z`), single-sourced by `build-evidence-pack.sh` and the scripts below.
  Caller must set canonicalized `GIT_ROOT` first.
- **`retrieve-evidence.sh`** — Round-1 executor. Consumes the Oracle's UNTRUSTED request
  JSON (`--request-file`) and writes a read-only manifest + copied evidence (`--out-dir`).
  Every requested path/search runs the gates; out-of-repo, traversal, secret, symlink,
  untracked, and FIFO/special paths are rejected and recorded, never copied. Fail-CLOSED
  on malformed/wrong-typed JSON.
- **`validate-retrieval-review.sh`** — Round-2 validator (`--review-file`). Fail-CLOSED
  (typed non-zero exit) on invalid JSON, wrong `review_type`, non-enum verdict, empty
  claims, or any uncited/malformed claim. Citation *existence* is the Phase-4 arbiter's
  job, not this structural check.
- **`run-retrieval-loop.sh`** — thin wrapper chaining consult → retrieve → consult →
  validate (`--question-file`/`--out-dir`). Prints a typed status token on its last line.

**Live dispatch is default-OFF.** The two billed `ultra_oracle_consult` calls only fire
when `ultra_oracle_surface_enabled blueprintReview` returns 0 — a USER-config opt-in
(`~/.claude/busdriver.json` → `ultraOracle.blueprintReview.enabled: true`), never a
repo-controlled toggle. With the flag off the wrapper prints `skipped:disabled` and exits
0. The loop is verified by the static contract test
`tests/test-ultraoracle-retrieval-loop-contract.sh` only — no test performs a live consult.
