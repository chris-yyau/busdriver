# ADR 0014 — Provenance guard for vendored-vs-local skill attribution

## Status

Accepted (2026-07-10)

## Context

Issue #254 has three parts. Part 2 (audit the ~356 `local` files, register the
real upstreams, flip verbatim-vendored files `local → custom`) shipped in
**PR #307**: 4 upstreams registered (`vercel`, `firecrawl`, `squirrelscan`,
`expo`), 136 files flipped, `local` 278 → 142.

This ADR resolves the other two parts:

- **Part 1 — provenance guard.** A check so a vendored-from-known-upstream file
  cannot silently sit at `status: local`, where `sync-upstream.sh` (which
  processes `status != local`) gives it **zero** drift detection. This is the
  exact blind spot that let `ui-ux-pro-max` and the Vercel/expo/firecrawl/
  squirrelscan clusters drift undetected. The issue flagged it "Needs design":
  *"today `local` files record no origin, so a naive 'ban local' lint is
  vacuous."*
- **Part 3 — reachability-informed externalization** (low priority).

## Decision — Part 1: frontmatter-provenance guard

The "record no origin" premise is now false. The PR #307 audit established that
**vendored skills already carry their origin in SKILL.md frontmatter** — that is
literally how the 136 files were found: `author: vercel`, `author: squirrelscan`,
`source: https://github.com/firecrawl/skills`. Busdriver-original skills carry
none of these (or `author: busdriver` / the maintainer). So a precise,
low-maintenance guard is buildable today.

`tests/test-provenance-guard.sh` (fail-CLOSED CI test) flags any `status: local`
skill whose `skills/<name>/SKILL.md` frontmatter:

- has `author:` (incl. nested `metadata.author:`) not in a small maintainer/
  busdriver allowlist, **or**
- has `source:`/`homepage:` pointing to a `github.com` org other than the
  maintainer's.

On a flag, the fix is the PR #307 recipe: register the upstream, flip
`local → custom`. Genuine-original exceptions (a busdriver skill that legitimately
carries a vendor-ish signal) go in `tests/provenance-guard-allowlist.txt`
(absent = empty; empty today — current state is clean at 34 local skills). A
pattern-derived **distillation** must not copy the vendor's `author:` frontmatter;
it marks provenance with an `<!-- Origin: inspired by <upstream> -->` comment and
stays local (e.g. `skills/canary`, distilled from gstack — already the convention).

The guard runs a built-in `--self-test` on every invocation (synthetic bad/good
fixtures) so a future edit that breaks detection fails CI rather than silently
passing. Wired into the `shell-tests` CI job alongside `test-upstream-manifest.sh`.

### Boundary

Frontmatter only. In-body citations of a vendor (a best-practices skill that
*references* vendor docs — e.g. `better-auth-best-practices`, `tavily-best-practices`)
are NOT provenance and are not flagged. SKILL.md is the provenance-bearing file;
non-SKILL.md local files (references, assets) are not scanned — their skill's
SKILL.md is the anchor.

### Known limitation (accepted)

A file vendored verbatim with **no** authorship frontmatter is not caught (e.g.
`next-best-practices`, a retired Vercel skill kept local because its upstream was
deleted — no live upstream to register, correctly local anyway). The guard catches
the *demonstrated* failure mode (vendored skills that carry vendor authorship,
which is the overwhelming majority) at high precision and zero false positives.
Byte-identity-vs-upstream detection needs upstream clones and is a sync-time
concern (`UPSTREAM_CACHE_DIR` in `test-upstream-manifest.sh`), deliberately out of
scope for this repo-side guard.

## Decision — Part 3: reachability externalization is deliberately deferred

Not built. The issue itself marks it low priority ("eventual candidates"), and
#254's decision anchor rejects wholesale auto-update: *"vendored + pinned +
controlled (gated) sync — never naked auto-update; upstream interface drift
landing automatically would break routing per-machine and unreproducibly."*
Building externalization machinery now (version/checksum pinning + mismatch
warning for the ~141 un-referenced leaf skills) is speculative — there is no
demand and no measured pain. YAGNI.

**Revisit trigger:** a concrete request to externalize a *specific* leaf skill,
with a pinning + mismatch-warning design that preserves orchestrator routing
determinism. Absent that, the ~141 leaf skills stay vendored and local.

## Alternatives considered

- **Naive "ban all `status: local`" lint** — vacuous and wrong; most local files
  are genuinely busdriver-original. Rejected (the issue's own objection).
- **Require every `local` file to record an explicit `origin` field** — heavy
  schema change, redundant with frontmatter that already carries origin, and
  false-positive-prone for genuine originals. Rejected.
- **Byte-hash every file against its upstream** — needs per-source upstream
  clones at pinned SHAs; a sync-time concern, not a repo-side lint. Already
  supported opt-in via `UPSTREAM_CACHE_DIR`. Out of scope.

## Consequences

- A future vendored-with-authorship skill left at `status: local` fails CI with a
  pointer to the fix — the drift blind spot cannot silently recur for the common
  case.
- One more entry in the `shell-tests` CI list; the guard self-tests its own
  detection each run.
- The allowlist file is the single escape hatch for documented genuine-originals;
  it stays empty until a real exception appears.
- Part 3 remains open in #254 as an explicit "won't build without demand"
  decision rather than an implied backlog item.
