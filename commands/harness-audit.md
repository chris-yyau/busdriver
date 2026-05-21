# Harness Audit Command

Run a deterministic repository harness audit and return a prioritized scorecard.

## Usage

`/harness-audit [scope] [--format text|json] [--root path]`

- `scope` (optional): `repo` (default), `hooks`, `skills`, `commands`, `agents`
- `--format`: output style (`text` default, `json` for automation)
- `--root`: audit a specific path instead of the current working directory

## Deterministic Engine

Always run:

```bash
node scripts/harness-audit.js <scope> --format <text|json> [--root <path>]
```

This script is the source of truth for scoring and checks. Do not invent additional dimensions or ad-hoc points.

Rubric version: `2026-03-30`.

The script computes 7 fixed categories (`0-10` normalized each):

1. Tool Coverage
2. Context Efficiency
3. Quality Gates
4. Memory Persistence
5. Eval Coverage
6. Security Guardrails
7. Cost Efficiency

Scores are derived from explicit file/rule checks and are reproducible for the same commit.
The script audits the current working directory by default and auto-detects whether the target is the ECC repo itself or a consumer project using ECC.

## Output Contract

Return:

1. `overall_score` out of `max_score` (68 for `repo`; smaller for scoped audits)
2. Category scores and concrete findings
3. Failed checks with exact file paths
4. Top 3 actions from the deterministic output (`top_actions`)
5. Suggested ECC skills to apply next

## Checklist

- Use script output directly; do not rescore manually.
- If `--format json` is requested, return the script JSON unchanged.
- If text is requested, summarize failing checks and top actions.
- Include exact file paths from `checks[]` and `top_actions[]`.

## Example Result

```text
Harness Audit (repo): NN/MM    # scoring varies with rubric version + repo state
- Tool Coverage: <points>/<max>
- Context Efficiency: <points>/<max>
- Quality Gates: <points>/<max>
...

Top 3 Actions:
1) [Category] <description>. (<path>)
2) [Category] <description>. (<path>)
3) [Category] <description>. (<path>)
```

Run the script for current numbers and the actual top actions for your branch — example shape only, not a prediction.

## Arguments

$ARGUMENTS:
- `repo|hooks|skills|commands|agents` (optional scope)
- `--format text|json` (optional output format)
