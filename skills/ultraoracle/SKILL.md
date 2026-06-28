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
| `retrieval-loop` | two-round Oracle-directed retrieval | **Phase 5 — not implemented.** The script rejects it; never claim `ORACLE_RETRIEVAL_REVIEW`. |

The label is whatever `build-evidence-pack.sh` prints — it is determined by what was
**actually attached**, so a summary-only consult can never masquerade as a repo review
(ADR settling check #2). Never relabel by hand.

## Procedure

Set `RUN_ID`, build the pack (for `repo`/`upstream-audit`), dispatch through the shared
adapter, then render the verdict under its label. Run as ONE Bash block so a failing
adapter cannot leave a half-state.

```bash
set -uo pipefail
PR="${CLAUDE_PLUGIN_ROOT}"
STATE="${BUSDRIVER_STATE_DIR:-.claude}"
RUN_ID="ultraoracle-$$"
PACK_DIR="$STATE/ultra-oracle/$RUN_ID"
OUT="$PACK_DIR/verdict.md"
mkdir -p "$PACK_DIR"

# 1. Write the question/design to a file (injection-safe; passed as --prompt-file).
#    (Claude writes the actual question into $PACK_DIR/question.txt before this block.)

# 2. Build the evidence pack for repo modes. LABEL is the LAST stdout line.
LABEL="ORACLE_SUMMARY_REVIEW"   # quick mode default
MODE="repo"                      # set per the user's request: repo | upstream-audit | quick
PACK_ARGS=()
if [ "$MODE" = "repo" ] || [ "$MODE" = "upstream-audit" ]; then
  # Pass the files you deliberately chose to attach via repeated --file, and
  # upstream paths via --upstream. Keep the set minimal and secret-free.
  LABEL="$(bash "$PR/skills/ultraoracle/scripts/build-evidence-pack.sh" \
            --mode "$MODE" --out-dir "$PACK_DIR" \
            --question-file "$PACK_DIR/question.txt" \
            "${PACK_ARGS[@]}" | tail -n1)" || {
    echo "⚠ ULTRAORACLE: evidence pack failed — ABORTING (fail closed)"; exit 1; }
  # Attach every file the pack collected.
  for f in "$PACK_DIR"/files/* "$PACK_DIR"/git-*.txt "$PACK_DIR"/upstream-*.txt; do
    [ -f "$f" ] && PACK_ATTACH+=(--context "$f")
  done
fi

# 3. Dispatch via the shared adapter (the ONLY surface that touches the oracle CLI).
source "$PR/scripts/lib/ultra-oracle.sh"
STATUS="$(ultra_oracle_consult \
  --prompt-file "$PACK_DIR/question.txt" \
  "${PACK_ATTACH[@]:-}" \
  --out "$OUT" --mode blocking --slug "ultra oracle consult")"

# 4. Render under label, fail-closed.
case "$STATUS" in
  ok)
    echo "## UltraOracle Expert Witness — [$LABEL]"
    cat "$OUT" ;;
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
