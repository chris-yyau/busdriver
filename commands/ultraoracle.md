---
description: Run a single repo-grounded UltraOracle (ChatGPT Pro) expert-witness consult — quick/repo/upstream-audit modes with review-type labeling and fail-closed handling.
---

# UltraOracle

Invoke the `ultraoracle` skill. It runs one standalone UltraOracle expert-witness
consult through the shared `ultra_oracle_consult` adapter: builds a deterministic,
secret-free evidence pack (`repo`/`upstream-audit` modes), dispatches to ChatGPT Pro,
and renders the verdict under its review-type label (`ORACLE_SUMMARY_REVIEW` /
`ORACLE_REPO_ATTACHED_REVIEW` / `ORACLE_FAILED`).

Enablement is user-config only (`~/.claude/busdriver.json`). See `skills/ultraoracle/SKILL.md`.
