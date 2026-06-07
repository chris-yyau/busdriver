# Domain Supplements

Domain skills are loaded as context during execution. They are **additive** — a Go + React + PostgreSQL project loads all three simultaneously.

### Go
**Detection:** `*.go` files, `go.mod`, Go code context
- Rules: `rules/golang/` (coding-style, patterns, security, testing, hooks)
- Patterns: `busdriver:golang-patterns`
- Testing: `busdriver:golang-testing`
- Review: `go-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `busdriver:go-build` command

### Python
**Detection:** `*.py` files, `requirements.txt`, Python code context
- Rules: `rules/python/` (coding-style, patterns, security, testing, hooks)
- Patterns: `busdriver:python-patterns`
- Testing: `busdriver:python-testing`
- Review: `python-reviewer` agent (see Phase 4 DISPATCH rules)
- **FastAPI** (detect: `fastapi` imports, `APIRouter`, `@app.get`/`@app.post`, Pydantic models):
  - Patterns: `busdriver:fastapi-patterns` (routers, dependency injection, Pydantic, async, middleware)
  - Review: `fastapi-reviewer` agent (see Phase 4 DISPATCH rules)
  - Commands: `/fastapi-review`

### Django
**Detection:** `manage.py`, `settings.py`, Django context
- Patterns: `busdriver:django-patterns`
- Security: `busdriver:django-security`
- Testing: `busdriver:django-tdd`
- Verification: `busdriver:django-verification`
- Async tasks: `busdriver:django-celery` (Celery task queues, workers, beat scheduling, retries)
- Review: `django-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `django-build-resolver` agent

### Spring Boot / Java
**Detection:** `pom.xml`, `@SpringBootApplication`, Spring context
- Rules: `rules/java/` (coding-style, patterns, security, testing, hooks)
- Patterns: `busdriver:springboot-patterns`
- Security: `busdriver:springboot-security`
- Testing: `busdriver:springboot-tdd`
- JPA: `busdriver:jpa-patterns`
- Standards: `busdriver:java-coding-standards`
- Verification: `busdriver:springboot-verification`
- Review: `java-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `java-build-resolver` agent (auto-detects Spring Boot vs Quarkus)

### Quarkus
**Detection:** `quarkus` in `pom.xml`/`build.gradle`, `quarkus-bom`, `application.properties` with `quarkus.*`, Quarkus imports
- Patterns: `busdriver:quarkus-patterns`
- Security: `busdriver:quarkus-security`
- Testing: `busdriver:quarkus-tdd`
- Verification: `busdriver:quarkus-verification`
- Review: `java-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `java-build-resolver` agent (Quarkus augmentation, native image, CDI errors)

### Frontend (React / Next.js / TypeScript)
**Detection:** `*.tsx`, `*.jsx`, `*.ts`, React components, Next.js, TypeScript
- Rules: `rules/typescript/` (coding-style, patterns, security, testing, hooks)
- Patterns: `busdriver:frontend-patterns`
- Standards: `busdriver:coding-standards`
- Review: `typescript-reviewer` agent (type safety, async correctness, Node/web security, idiomatic patterns)
- **React-specific** (detect: `react` imports, hooks, components):
  - Patterns: `busdriver:react-patterns` (composition, hooks, state, effects)
  - Performance: `busdriver:react-performance` (memoization, re-render reduction, bundle)
  - Testing: `busdriver:react-testing` (React Testing Library, hooks, async)
  - Animation: `busdriver:motion-foundations`, `busdriver:motion-patterns`, `busdriver:motion-ui`, `busdriver:motion-advanced`
  - Review: `react-reviewer` agent (see Phase 4 DISPATCH rules)
  - Build issues: `react-build-resolver` agent
  - Commands: `/react-review`, `/react-test`, `/react-build`
- **Vite** (detect: `vite.config.*`, Vite imports): `busdriver:vite-patterns`
- **Vue migration** (React→Vue work): `busdriver:ui-to-vue`
- Design: `busdriver:design-system` (generate/audit design tokens)
- **UI/UX Design** (load when design/styling work detected):
  - **Dual-engine workflow — diverge, then converge:**
    - **Marketing / landing / portfolio / showcase** → *explore* with `design-taste-frontend` (if installed) first (lead): bold asymmetric layout, dark palettes, GSAP motion — push `DESIGN_VARIANCE` / `MOTION_INTENSITY` high. Then *harden* with `impeccable:impeccable` (`/typeset` → `/layout` → `/audit`) to converge on a11y, spacing, responsive. Variants (if installed): `gpt-taste` (GPT/Codex), `stitch-design-taste` (Google Stitch); reference image → code: `image-to-code`. When `design-taste-frontend` is absent, `impeccable:impeccable` leads end-to-end. (`design-taste-frontend` is a global `npx skills` install — invoke by bare name; absent on machines without it.)
    - **Dashboard / app UI / forms / settings / data tables** → `impeccable:impeccable` owns it end-to-end; `design-taste-frontend` explicitly excludes these, so there is no explore phase.
    - **Why this order:** taste-skill maximizes visual entropy (divergence); impeccable minimizes error rate (convergence). Taste drives early; impeccable has final say on hardening.
    - **Presets & Phase 0 — manual, invoke by name on request (NOT auto-routed):** specific aesthetics → `minimalist-ui`, `industrial-brutalist-ui`, `high-end-visual-design`. Optional pre-explore reference boards → `imagegen-frontend-web`, `imagegen-frontend-mobile`, `brandkit`. (`redesign-existing-projects` and `full-output-enforcement` deliberately omitted — redundant with `design-taste-frontend`'s redesign protocol and the litmus/verification gates respectively.)
  - **Supplements — fill gaps only, do NOT lead:**
    - `ui-ux-pro-max` — breadth catalog (50 styles, 21 palettes, 50 font pairings, 20 charts, shadcn MCP). Option lookup when an engine needs a named style / palette / font / chart, or shadcn component search on dashboards.
    - `document-skills:frontend-design` — generic fallback; only for gaps the engines don't cover.
  - Context: `.impeccable.md` if present (created via `impeccable:shape`)
  - Refinement: `/polish`, `/critique`, `/audit`, `/normalize`, `/harden`, `/distill`, `/clarify`
  - Enhancement: `/colorize`, `/bolder`, `/quieter`, `/delight`, `/animate`, `/overdrive`
  - Structure: `/arrange`, `/extract`, `/typeset`, `/adapt`, `/optimize`, `/onboard`
- **Next.js-specific** (detect: `next.config.*`, `app/` with `layout.tsx`/`page.tsx`, RSC patterns):
  - Turbopack: `busdriver:nextjs-turbopack` (Next.js 16+ incremental bundling, FS caching, when to use Turbopack vs webpack)
- **Bun** (detect: `bun.lock`, `bun.lockb`, `bunfig.toml`, Bun imports):
  - Runtime: `busdriver:bun-runtime` (Bun as runtime, package manager, bundler, test runner; migration from Node)

### Angular
**Detection:** `angular.json`, `@angular/*` imports, `*.component.ts`, Angular CLI projects
- Developer guide: `busdriver:angular-developer` (signals, standalone components, reactive forms, SSR, routing, testing, a11y — comprehensive 36-file family)
- Rules: `rules/typescript/` (Angular is TypeScript-based)
- Review: `typescript-reviewer` agent

### Nuxt
**Detection:** `nuxt.config.*`, `.nuxt/` directory, `useFetch`, `useAsyncData`, Nuxt imports
- Patterns: `busdriver:nuxt4-patterns` (hydration safety, SSR, route rules, lazy loading, data fetching)
- Review: `code-reviewer` agent (no Nuxt-specific reviewer yet)

### Backend (Node.js / Express / Next.js API)
**Detection:** `*.js`, `*.ts` in API routes, Express/Node.js context
- Patterns: `busdriver:backend-patterns`
- Standards: `busdriver:coding-standards`
- **NestJS** (detect: `@nestjs/core`, `@Module`, `@Controller`, `@Injectable` decorators):
  - Patterns: `busdriver:nestjs-patterns` (modules, controllers, providers, DTO validation, guards, interceptors, config)

### C# / .NET
**Detection:** `*.cs`, `*.csproj`, `*.sln`, .NET context
- Patterns: `busdriver:dotnet-patterns` (DI, async/await, conventions, best practices)
- Testing: `busdriver:csharp-testing` (xUnit, FluentAssertions, mocking, integration tests)
- Review: `csharp-reviewer` agent
- Rules: `rules/csharp/` (coding-style, patterns, security, testing, hooks)

### F#
**Detection:** `*.fs`, `*.fsproj`, `*.fsx`, F# context
- Patterns: no F#-specific skill yet — fall back to `busdriver:dotnet-patterns` for shared .NET idioms (DI, async/await)
- Testing: `busdriver:fsharp-testing` (Expecto, FsCheck, property-based testing)
- Review: `fsharp-reviewer` agent (see Phase 4 DISPATCH rules)

### C++
**Detection:** `*.cpp`, `*.h`, `*.hpp`, `CMakeLists.txt`, C++ context
- Rules: `rules/cpp/` (coding-style, patterns, security, testing, hooks)
- Standards: `busdriver:cpp-coding-standards`
- Testing: `busdriver:cpp-testing`
- Review: `cpp-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `busdriver:cpp-build` command

### Swift
**Detection:** `*.swift`, `Package.swift`, Xcode project context
- Rules: `rules/swift/` (coding-style, patterns, security, testing, hooks)
- SwiftUI: `busdriver:swiftui-patterns` (@Observable, navigation, view composition)
- Concurrency: `busdriver:swift-concurrency-6-2` (Swift 6.2 model, @concurrent, nonisolated)
- Persistence: `busdriver:swift-actor-persistence` (actor-based thread-safe data)
- Testing/DI: `busdriver:swift-protocol-di-testing`
- On-device AI: `busdriver:foundation-models-on-device` (Apple FoundationModels framework)
- iOS 26 UI: `busdriver:liquid-glass-design` (Liquid Glass design system)
- Review: `swift-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `swift-build-resolver` agent

### Database
**Detection:** SQL, migrations, schema changes, database operations
- PostgreSQL: `busdriver:postgres-patterns`
- MySQL: `busdriver:mysql-patterns`
- ClickHouse: `busdriver:clickhouse-io`
- Redis: `busdriver:redis-patterns` (caching, data structures, pub/sub, persistence)
- Prisma ORM: `busdriver:prisma-patterns` (schema, migrations, type-safe queries, relations)
- Migrations: `busdriver:database-migrations`
- **DISPATCH `database-reviewer` agent** via Agent tool when writing SQL queries, creating migrations, designing schemas, or modifying database operations. This is NOT optional for database work — the agent catches query performance issues, missing indexes, RLS gaps, and schema design problems.

### Perl
**Detection:** `*.pl`, `*.pm`, Perl context
- Patterns: `busdriver:perl-patterns`
- Security: `busdriver:perl-security`
- Testing: `busdriver:perl-testing`
- Rules: `rules/perl/` (coding-style, patterns, security, testing, hooks)

### PHP / Laravel
**Detection:** `*.php`, `composer.json`, Laravel context
- Patterns: `busdriver:laravel-patterns`
- Security: `busdriver:laravel-security`
- Testing: `busdriver:laravel-tdd`
- Verification: `busdriver:laravel-verification`
- Rules: `rules/php/` (coding-style, patterns, security, testing, hooks)

### Kotlin
**Detection:** `*.kt`, `*.kts`, `build.gradle.kts`, Kotlin context
- Patterns: `busdriver:kotlin-patterns`
- Testing: `busdriver:kotlin-testing`
- Coroutines/Flow: `busdriver:kotlin-coroutines-flows`
- Exposed ORM: `busdriver:kotlin-exposed-patterns`
- Ktor: `busdriver:kotlin-ktor-patterns`
- Android/KMP: `busdriver:android-clean-architecture`, `busdriver:compose-multiplatform-patterns`
- Review: `kotlin-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `busdriver:kotlin-build` command
- Rules: `rules/kotlin/` (coding-style, patterns, security, testing, hooks)

### Flutter / Dart
**Detection:** `*.dart` files, `pubspec.yaml`, Flutter imports, widget code
- Patterns: `busdriver:dart-flutter-patterns` (null safety, immutable state, async, widget arch, BLoC, Riverpod, Provider, GoRouter, Dio, Freezed, clean arch)
- Code review: `busdriver:flutter-dart-code-review` (library-agnostic checklist — BLoC, Riverpod, Provider, GetX, MobX, Signals)
- Review: `flutter-reviewer` agent (see Phase 4 DISPATCH rules)
- Commands: `/flutter-review`, `/flutter-test`, `/flutter-build`
- Build issues: `busdriver:gradle-build` command (Android/Gradle build failures), `dart-build-resolver` agent

### Android / Kotlin Multiplatform (KMP)
**Detection:** `app/src/main/`, KMP config, `build.gradle.kts` with Android plugin, Compose imports
- Clean architecture: `busdriver:android-clean-architecture` (module structure, dependency rules, UseCases, Repositories)
- Compose: `busdriver:compose-multiplatform-patterns` (state management, navigation, theming, platform UI)
- Kotlin patterns: `busdriver:kotlin-patterns`, `busdriver:kotlin-coroutines-flows`
- Review: `kotlin-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `busdriver:kotlin-build` or `busdriver:gradle-build` command

### Rust
**Detection:** `*.rs`, `Cargo.toml`, Rust context
- Patterns: `busdriver:rust-patterns`
- Testing: `busdriver:rust-testing`
- Review: `rust-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `busdriver:rust-build` command

### Networking / Homelab
**Detection:** Cisco IOS configs, BGP, VLAN, network device configs, `netmiko`, homelab/VPN setup, network troubleshooting
- Cisco IOS: `busdriver:cisco-ios-patterns` (read-only diagnostics, config patterns)
- SSH automation: `busdriver:netmiko-ssh-automation` (⚠️ read-only first; config changes require explicit operator approval)
- Diagnostics: `busdriver:network-bgp-diagnostics`, `busdriver:network-config-validation`, `busdriver:network-interface-health`
- Homelab: `busdriver:homelab-network-setup`, `busdriver:homelab-network-readiness`, `busdriver:homelab-vlan-segmentation`, `busdriver:homelab-pihole-dns`, `busdriver:homelab-wireguard-vpn`
- Agents: `network-architect`, `network-config-reviewer`, `network-troubleshooter`, `homelab-architect`

### Infrastructure / DevOps
**Detection:** Dockerfile, docker-compose.yml, CI/CD pipelines, deployment configs, Kubernetes
- Docker: `busdriver:docker-patterns`
- Deployment: `busdriver:deployment-patterns`

### AI / LLM Development
**Detection:** LLM API calls, prompt engineering, RAG pipelines, model routing, token optimization, PyTorch training
- Cost optimization: `busdriver:cost-aware-llm-pipeline`
- RAG/retrieval: `busdriver:iterative-retrieval`
- Text extraction: `busdriver:regex-vs-llm-structured-text`
- Document processing: `busdriver:nutrient-document-processing`
- Documentation: `busdriver:documentation-lookup` (up-to-date library/framework docs via Context7 MCP — use instead of training data for API references, setup guides, code examples)
- **PyTorch** (detect: `torch` imports, training loops, CUDA usage):
  - Patterns: `busdriver:pytorch-patterns` (training pipelines, model architectures, data loading)
  - Build issues: `pytorch-build-resolver` agent (tensor shape, CUDA, gradient, DataLoader, mixed precision errors)
- **ML Engineering** (detect: training pipelines, feature stores, model serving, MLOps):
  - Workflow: `busdriver:mle-workflow` (end-to-end ML engineering: data, training, eval, deployment)
  - RecSys: `busdriver:recsys-pipeline-architect` (recommendation system pipelines)
  - Review: `mle-reviewer` agent (see Phase 4 DISPATCH rules)
- **Performance-critical** (latency budgets, HFT, throughput): `busdriver:latency-critical-systems`, `busdriver:data-throughput-accelerator`, `busdriver:benchmark-optimization-loop`

### Video & Media
**Detection:** Video files, FFmpeg commands, Remotion imports, video editing context
- Understanding/indexing: `busdriver:videodb` (ingest, index, search video/audio)
- Editing workflows: `busdriver:video-editing` (FFmpeg, Remotion, ElevenLabs, fal.ai)
- Generation: `busdriver:fal-ai-media` (text-to-image/video/audio)

### Crypto / DeFi / EVM
**Detection:** Solidity, EVM, `ethers.js`, `web3.js`, AMM, liquidity pools, token contracts
- AMM Security: `busdriver:defi-amm-security` (reentrancy, CEI, donation attacks, oracle manipulation, slippage)
- Token Decimals: `busdriver:evm-token-decimals` (runtime decimal lookup, bridged-token drift, safe normalization)
- Node.js Hashing: `busdriver:nodejs-keccak256` (Keccak-256 vs NIST SHA3 — critical for selectors, signatures, storage slots)
- Trading Agent Security: `busdriver:llm-trading-agent-security` (prompt injection, spend limits, circuit breakers, MEV protection)

### Healthcare
**Detection:** EMR, clinical, PHI, HIPAA, HL7, FHIR context
- EMR Patterns: `busdriver:healthcare-emr-patterns`
- CDSS: `busdriver:healthcare-cdss-patterns`
- PHI Compliance: `busdriver:healthcare-phi-compliance`
- HIPAA: `busdriver:hipaa-compliance` (HIPAA-specific entrypoint for PHI handling, BAAs, breach posture)
- Eval Harness: `busdriver:healthcare-eval-harness`
- Review: `healthcare-reviewer` agent

### MCP Development
**Detection:** MCP server code, `@modelcontextprotocol/sdk`, tool/resource definitions
- Patterns (Node/TS only): `busdriver:mcp-server-patterns` (Node/TS SDK — tools, resources, prompts, Zod validation, stdio vs Streamable HTTP. Do NOT load for Python FastMCP projects.)

### Supply Chain / Logistics
**Detection:** Freight, shipping, carrier, warehouse, inventory, procurement, customs, tariff, demand planning, production scheduling context
- Carrier Management: `busdriver:carrier-relationship-management` (carrier portfolios, freight negotiation, lane optimization)
- Customs/Trade: `busdriver:customs-trade-compliance` (customs docs, tariff classification, duty calculations, trade compliance)
- Energy Procurement: `busdriver:energy-procurement` (electricity/gas procurement, tariff optimization)
- Inventory: `busdriver:inventory-demand-planning` (demand forecasting, safety stock, reorder points)
- Exceptions: `busdriver:logistics-exception-management` (freight exceptions, shipment delays, damage claims)
- Production: `busdriver:production-scheduling` (job sequencing, line balancing, capacity planning)
- Quality: `busdriver:quality-nonconformance` (quality control, non-conformance investigation, CAPA)
- Returns: `busdriver:returns-reverse-logistics` (returns authorization, inspection, disposition)
