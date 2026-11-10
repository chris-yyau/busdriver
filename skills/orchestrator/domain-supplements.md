# Domain Supplements

Domain routing is loaded as context during execution. Entries are **additive** — a Python + React + PostgreSQL project loads all three simultaneously.

**Scope (ADR 0048):** busdriver no longer carries language pattern libraries or framework guides — the model covers that. Every domain reviews with `code-reviewer` (plus `security-reviewer` for security-sensitive diffs) and debugs build failures with `busdriver:systematic-debugging`; the per-language reviewer and build-resolver agents were removed (ADR 0062). What remains here is detection and any domain-specific routing. Testing guidance follows the Phase 4 "Always-on disciplines" policy (advisory, not gate-enforced — ADR 0038); no domain entry mandates test ordering.

### Python
**Detection:** `*.py` files, `requirements.txt`, `pyproject.toml`, Python code context
- Review: `code-reviewer` agent (see Phase 4 DISPATCH rules), FastAPI included

### Frontend (React / Next.js / TypeScript)
**Detection:** `*.tsx`, `*.jsx`, `*.ts`, React components, Next.js, TypeScript
- Review: `code-reviewer` agent (see Phase 4 DISPATCH rules), React included
- Build issues: `busdriver:systematic-debugging`
- **UI/UX Design** (load when design/styling work detected): `impeccable:impeccable` (separately installed plugin) owns design end-to-end — landing pages, dashboards, app UI, forms. Context: `.impeccable.md` if present (created via `impeccable:shape`). Refinement/enhancement/structure commands: see `tasks-catalog.md` → Design Refinement. Generic fallback: `document-skills:frontend-design`.

### Backend (Node.js / Express / Next.js API)
**Detection:** `*.js`, `*.ts` in API routes, Express/Node.js context
- Review: `code-reviewer` agent

### Database
**Detection:** SQL, migrations, schema changes, database operations
- Review: `code-reviewer` agent when writing SQL queries, creating migrations, designing schemas, or modifying database operations — ask it to check query performance, missing indexes, RLS gaps and schema design; add `security-reviewer` when queries take user input.

### AI / LLM Development
**Detection:** LLM API calls, prompt engineering, RAG pipelines, model routing, token optimization
- Cost optimization: `busdriver:cost-aware-llm-pipeline`
- Documentation: `context7-cli` *(personal skill, if installed)* — up-to-date library/framework docs via the ctx7 CLI; otherwise Context7 MCP / WebFetch

### Security-sensitive changes (any language)
**Detection:** auth, user input, API endpoints, payments, secrets — AND any change to `.claude/` config, `hooks/`, agents, MCP servers, or settings (supply-chain surface)
- Review: `security-reviewer` agent (also dispatched by Phase 5)
- Checklist: `busdriver:security-review`; for the supply-chain surface load the `skill-supply-chain.md` supplement alongside it
