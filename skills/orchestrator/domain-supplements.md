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

### Django
**Detection:** `manage.py`, `settings.py`, Django context
- Patterns: `busdriver:django-patterns`
- Security: `busdriver:django-security`
- Testing: `busdriver:django-tdd`
- Verification: `busdriver:django-verification`

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
- Build issues: `busdriver:java-build` command / `java-build-resolver` agent

### Frontend (React / Next.js / TypeScript)
**Detection:** `*.tsx`, `*.jsx`, `*.ts`, React components, Next.js, TypeScript
- Rules: `rules/typescript/` (coding-style, patterns, security, testing, hooks)
- Patterns: `busdriver:frontend-patterns`
- Standards: `busdriver:coding-standards`
- Review: `typescript-reviewer` agent (type safety, async correctness, Node/web security, idiomatic patterns)
- Design direction: `frontend-design` (local skill — aesthetics, visual hierarchy, anti-slop patterns. `document-skills:frontend-design` is an equivalent alternative)
- Design context: If `.impeccable.md` exists, read it first. If missing for generative work, suggest `teach-impeccable`.
- Design refinement: Impeccable-family skills (`animate`, `bolder`, `delight`, `polish`, `colorize`, `distill`, `arrange`, `typeset`, `normalize`, `critique`, `audit`, etc.) — see orchestrator "Design Refinement" section
- **Next.js-specific** (detect: `next.config.*`, `app/` with `layout.tsx`/`page.tsx`, RSC patterns):
  - Framework: `next-best-practices` (file conventions, RSC boundaries, data patterns, async APIs)
  - Turbopack: `busdriver:nextjs-turbopack` (Next.js 16+ incremental bundling, FS caching, when to use Turbopack vs webpack)
  - Performance: `vercel-react-best-practices` (React + Next.js optimization from Vercel)
  - Composition: `vercel-composition-patterns` (component patterns that scale)
- **Bun** (detect: `bun.lock`, `bun.lockb`, `bunfig.toml`, Bun imports):
  - Runtime: `busdriver:bun-runtime` (Bun as runtime, package manager, bundler, test runner; migration from Node)
- **Video/Media** (detect: Remotion imports, video component creation):
  - Video: `remotion-best-practices`

### Nuxt
**Detection:** `nuxt.config.*`, `.nuxt/` directory, `useFetch`, `useAsyncData`, Nuxt imports
- Patterns: `busdriver:nuxt4-patterns` (hydration safety, SSR, route rules, lazy loading, data fetching)
- Review: `code-reviewer` agent (no Nuxt-specific reviewer yet)

### Mobile (React Native / Expo)
**Detection:** `app.json` with expo config, React Native imports, `*.tsx` with native components, `expo-router`
- Framework: `vercel-react-native-skills` (performance, navigation, optimization)
- Native UI: `building-native-ui` (Expo Router, styling, components, animations)

### Backend (Node.js / Express / Next.js API)
**Detection:** `*.js`, `*.ts` in API routes, Express/Node.js context
- Patterns: `busdriver:backend-patterns`
- Standards: `busdriver:coding-standards`

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
- Review: `code-reviewer` agent (no Swift-specific reviewer yet)

### Database
**Detection:** SQL, migrations, schema changes, database operations
- PostgreSQL: `busdriver:postgres-patterns`
- Supabase Postgres: `supabase-postgres-best-practices` (Supabase-specific Postgres optimization — connection pooling, RLS policies, query performance)
- ClickHouse: `busdriver:clickhouse-io`
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

### Flutter
**Detection:** `*.dart` files, `pubspec.yaml`, Flutter imports, widget code
- Code review: `busdriver:flutter-dart-code-review` (library-agnostic checklist — BLoC, Riverpod, Provider, GetX, MobX, Signals)
- Review: `flutter-reviewer` agent (see Phase 4 DISPATCH rules)
- Build issues: `busdriver:gradle-build` command (Android/Gradle build failures)

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
- Agent tools: `agent-tools` (inference.sh CLI — image/video generation, multi-model pipelines)
- Documentation: `busdriver:documentation-lookup` (up-to-date library/framework docs via Context7 MCP — use instead of training data for API references, setup guides, code examples)
- **PyTorch** (detect: `torch` imports, training loops, CUDA usage):
  - Patterns: `busdriver:pytorch-patterns` (training pipelines, model architectures, data loading)
  - Build issues: `pytorch-build-resolver` agent (tensor shape, CUDA, gradient, DataLoader, mixed precision errors)

### Marketing & Growth
**Detection:** Marketing copy, landing pages, SEO work, conversion optimization, analytics setup, pricing decisions
**Sub-categories:**
- **CRO:** `form-cro`, `page-cro`, `onboarding-cro`, `signup-flow-cro`, `popup-cro`, `paywall-upgrade-cro`, `ab-test-setup`, `analytics-tracking`
- **Content & Copy:** `content-strategy`, `copywriting`, `copy-editing`, `social-content`, `email-sequence`, `product-marketing-context`
- **Growth & Monetization:** `pricing-strategy`, `launch-strategy`, `referral-program`, `free-tool-strategy`, `paid-ads`, `competitor-alternatives`, `audit-website`
- **SEO:** `programmatic-seo`, `seo-audit`, `schema-markup`
- **Psychology:** `marketing-psychology` (behavioral science, mental models)
- **Ideas:** `marketing-ideas` (strategy inspiration)

### Video & Media
**Detection:** Video files, FFmpeg commands, Remotion imports, video editing context
- Understanding/indexing: `busdriver:videodb` (ingest, index, search video/audio)
- Editing workflows: `busdriver:video-editing` (FFmpeg, Remotion, ElevenLabs, fal.ai)
- Generation: `busdriver:fal-ai-media` (text-to-image/video/audio)
- Remotion: `remotion-best-practices` (video creation in React)

### MCP Development
**Detection:** MCP server code, `@modelcontextprotocol/sdk`, tool/resource definitions
- Creation: `document-skills:mcp-builder` (guided MCP server creation — supports both Python FastMCP and TypeScript)
- Patterns (Node/TS only): `busdriver:mcp-server-patterns` (Node/TS SDK — tools, resources, prompts, Zod validation, stdio vs Streamable HTTP. Do NOT load for Python FastMCP projects.)
