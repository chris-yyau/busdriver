---
description: Convene the council with a forced UltraOracle (GPT-5.5 Pro) expert-witness escalation — the 5 voices plus a separately-rendered Expert Witness, never a vote.
---

# Ultra-Council

Invoke the `council` skill in **ultra-council** mode: run the normal 5-voice council and force the
UltraOracle escalation by setting `ULTRA_ORACLE_COUNCIL_FORCE=1` (a plain, non-exported assignment)
at the top of council's single Step 4 dispatch Bash block and `unset`-ting it at the end — never a
subshell, never `export`, never a `VAR=1 cmd` prefix (a trigger phrase alone sets no env var). The
GPT-5.5 Pro verdict is rendered as a SEPARATE `UltraOracle — Expert Witness [ORACLE_SUMMARY_REVIEW]`
section, after the five voices and before the Verdict, and is EXCLUDED from the vote tally (ADR 0007
Phase 3).

Oracle is an advisory expert witness, not a vote and not a gate; a repo-specific claim with no
file/path evidence is ungrounded. On timeout/empty it renders a loud `ORACLE_FAILED` banner, never a
silent omission.

Enablement is user-config only (`~/.claude/busdriver.json` → `ultraOracle.council.enabled`);
`ULTRA_ORACLE_COUNCIL_FORCE=1` is set only by an interactive ultra-council request, never by
repo/project config. See `skills/council/SKILL.md` Step 4.5.
