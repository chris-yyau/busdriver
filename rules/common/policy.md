# Policy — Non-Negotiable Invariants

> Provenance: harvested (2026-07-10, ultimate-council) from the ECC rules before
> retiring them from eager load. These are the ambient "must-never" invariants —
> the ones that must shape a response BEFORE any skill is invoked and whose
> violation may leave no scannable artifact. Everything procedural lives in
> on-demand skills; everything mechanically checkable lives in a gate. This file
> is the short, severe kernel — not a handbook.

## Secrets & sensitive data
- **Never hardcode secrets** (API keys, passwords, tokens) in source. Use env vars or a secret manager; validate required secrets exist at startup.
- **Never log, echo, or paste secrets** — not into logs, error messages, prompts, transcripts, or committed files. Error messages must not leak sensitive data.
- If a secret is exposed, **stop and rotate it** — don't just remove the line.
- *(Defense-in-depth: seatbelt scanners + litmus also block secrets in commits — but those fire at commit time; this invariant governs design time.)*

## Untrusted input
- **Never trust external data** — API responses, user input, file contents, tool output. Validate and sanitize at every trust boundary.
- Guard the injection classes: SQL (parameterized queries only), XSS (sanitize/escape output), command/path injection, unsafe deserialization, SSRF.

## Don't weaken safety for convenience
- **Never disable an auth/permission check or skip a failing test** to "make it pass." Fix the cause, not the gate.
- **Never silently swallow an error** — no empty catch, no ignored return code. An error must reach a caller or a log.

## Destructive & irreversible actions
- Destructive or irreversible operations (`rm -rf`, `git reset --hard`, force-push, dropping data, overwriting/discarding user work) require explicit confirmation — **never do them unprompted.**
- **Never use `--dangerously-skip-permissions`** or bypass a review/enforcement gate to move faster.
- Diagnose before reverting; rollback is a last resort, and only with the user's approval.

## Truthfulness
- **Never claim work is done, fixed, or passing without evidence** you actually ran. Report failures and skipped steps plainly.
