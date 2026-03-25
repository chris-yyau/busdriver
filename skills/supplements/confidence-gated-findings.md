---
name: confidence-gated-findings
description: Confidence-gated severity thresholds for security reviews — daily mode (8/10, zero noise) vs comprehensive mode (2/10, surface more)
targets: security-reviewer agent, security-scan skill
type: supplement
source: gstack /cso
added: 2026-03-24
---

# Confidence-Gated Findings

> Load alongside `security-reviewer` agent and `security-scan` skill.

## Two Modes

### Daily Mode (default)

Confidence threshold: **8/10**

Only report findings you are highly confident about. Zero noise. If you're not sure, don't report it.

- Use for: per-commit reviews, routine security checks, PR reviews
- Goal: no false positives — every finding is actionable
- Skip: theoretical risks, edge cases requiring unlikely preconditions, findings that depend on unknown runtime configuration

### Comprehensive Mode (monthly / on request)

Confidence threshold: **2/10**

Surface everything, including low-confidence findings. The user expects noise and will triage.

- Use for: periodic deep audits, pre-launch reviews, compliance checks
- Goal: coverage — miss nothing, accept false positives
- Include: theoretical risks, "this might be a problem if...", findings that need investigation
- Trigger: user says "comprehensive scan", "deep audit", "monthly review", or "surface everything"

## How to Apply

For each finding, mentally assign a confidence score (1-10):
- **9-10:** You traced the code path and confirmed the vulnerability exists
- **7-8:** The pattern is present and likely exploitable, but you didn't trace every path
- **4-6:** The pattern looks suspicious but could be a false positive
- **1-3:** Theoretical risk based on the technology stack, not confirmed in code

In daily mode, only report 8+. In comprehensive mode, report 2+.

## False Positive Exclusions

These are NOT findings — skip regardless of mode:
- Test files importing test utilities (not production dependencies)
- Environment variables referenced in `.env.example` (not actual secrets)
- Commented-out code containing old API keys (already dead)
- Development-only debug endpoints behind `NODE_ENV !== 'production'` checks
- Type-only imports that don't execute at runtime
