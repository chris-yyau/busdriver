# Imported files count as agent config (#936)

## Context
`scripts/needs-shipping.py` decides `agent_config_edited` and the never-skippable rule by path name alone. `agent_config()` matches any `.cursor`, `.claude`, `.codex` or `.agents` component, or a basename in `AGENT_FILES`, at any depth (ADR 0055).

Agent-config files can also pull other files in by reference:
- **Claude Code** expands `@path` imports in `CLAUDE.md`, `CLAUDE.local.md` and `AGENTS.md` ([Claude Code memory docs](https://code.claude.com/docs/en/memory), "Import additional files"). Each import resolves relative to the importing file, and imports recurse up to four hops. Code spans, fenced blocks and quoted paths are not imported. `.claude/rules/` follows file and directory symlinks.
- **Cursor**'s rules documentation (cursor.com/docs/rules) says a file mention "tells Agent where to look … the same in the editor, the CLI, and Cloud Agents", and that rule content "reaches Agent as written". It does not say how a mention resolves or how deep it goes. The Shipping agent is a Cursor Cloud agent (ADR 0055).
- **Cursor** also loads skills from `.agents/skills`, `.claude/skills` and `.codex/skills` (cursor.com/docs/skills).

So in an opted-in repo, a PR that edits `docs/agent-notes.md`, imported from `CLAUDE.md`, changes what every later cloud agent reads as instructions. Today that PR is classified as an ordinary doc:
- if it is docs-only, it is skippable and merges with no Shipping run;
- if it mixes code and docs, it routes to Shipping with `agent_config_edited=0`, and the kicker auto-kicks it.

Found by the litmus PR-mode security backstop on #933 and recorded there as a residual.

## Decisions
- **Detection: walk the import graph.** This was the operator's choice over treating any changed `*.md` as agent config, which would force a hand landing on every docs PR.
- **Hand-landing beats emulating undocumented parsers.** Neither Claude Code's nor Cursor's import parser is fully documented. So every live token the walk cannot resolve to a path in the tree, or cannot be sure a reader would ignore, makes the walk incomplete. Rules that drop a token are kept only where the token provably names nothing a PR can edit (a URL, an empty token), or where it is not live.
- **Failure split.** An API or `gh` error exits 1, as today. A walk that cannot finish, including a walk that runs out of time, instead makes the PR agent config (§6). Turning a walk limit into a BAIL would block merges in a repo that merely has a large tree.
- **Symlinks are not resolved** (the operator's choice after review). An `agent_config()` path that is a symlink, or a symlink met while resolving a live candidate, makes the walk incomplete.
  - On 2026-10-11 the three opted-in repos (jikdak, diveand.dev, chrisyau.me) held zero symlinks (mode `120000`) at their default-branch tip, so this costs nothing today.
  - A repo that adds a symlink hand-lands until the walk learns to resolve them. The code is marked `keep-simple(UPGRADE: resolve link targets if an opted-in repo needs symlinks)`.
- **Directories are not walked.** A live token that resolves to a tree makes the walk incomplete. The same 2026-10-11 probe found no live directory tokens in the three repos. The code is marked `keep-simple(UPGRADE: walk a tree's instruction files if an opted-in repo mentions a directory)`.
- **Only live tokens are followed** (the operator's choice). On Claude-only visits, a token inside a code span, or directly after a quote character, is not live (§4); Cursor visits treat every token as live. A non-live token's resolved target joins the exact set by path and nothing else happens: it is not fetched, size-checked or walked, and it never makes the walk incomplete. A non-live candidate whose resolution meets a symlink is dropped. So in a Claude-only file, one backticked `@/…` or `@src` does not force hand landings on unrelated PRs.
- **Fenced blocks are not excluded.** Claude Code skips fenced blocks, but every fence rule tried in review could pair the wrong lines and hide prose. So a token in a fence is treated as prose: it can only over-count. On 2026-10-11 the only fenced token in the three repos, `@cloudflare/workers-types` in a file-tree block, named no path.
- **Liveness is reader-specific.**
  - Claude's code-span and quote exclusions decide Claude-liveness, in any file Claude reaches.
  - For Cursor, every token in every file reached from a Cursor-read entry is live, because Cursor documents no exclusion (cursor.com/docs/rules describes backticked mentions too). A file both readers see is judged for each reader separately (§4).
  - Any live token starting with `/` makes the walk incomplete, whoever reads it: Claude reads it as an absolute path, and Cursor's Agent can reach an absolute checkout path such as `/workspace/project/docs/x.md` with its tools. So a backticked `@/*` alias note hand-lands every PR if it sits in a Cursor-read file such as a root `CLAUDE.md`. On 2026-10-11 the three repos had no root `CLAUDE.md` or `AGENTS.md`, and no Cursor-read file held a `/` token, so this costs nothing today. The code is marked `keep-simple(UPGRADE: resolve absolute paths against the checkout root if an opted-in repo needs Cursor alias notes)`.
  - Treating `CLAUDE.md` outside `.claude/` as Cursor-read is this design's assumption: cursor.com/docs/rules names `AGENTS.md` but not `CLAUDE.md`. It can only add live tokens.
  - On 2026-10-11 every `@` token in the three repos' Cursor-read files (`@type`, `@id`, `@playwright/test`) named no path, and no Cursor-read file imported a non-markdown file. So this costs nothing today.

## Design

### 1. When it runs
The walk runs only in opted-in repos, after `verify_skills()` returns a non-empty list, on the same branch of `classify()` that already lists changed files.

A repo that is not opted in makes no `git/trees?recursive=1` or GraphQL calls. Its existing reads are unchanged.

The walk uses the `head` and `tip` SHAs that `classify()` already holds, so the existing final re-check of head and base also covers it.

### 2. Revisions and trees
The walk runs at two revisions, and their results are unioned:
- **`head`**, the reviewed PR head: what the cloud agent reads on the PR.
- **`base_tip`**: what the agent reads after Shipping's server-side update-branch merges the base in.

A file imported at only one of the two can still become instructions. For example, `base_tip` adds `@docs/y.md` after the PR branched, and the PR edits `docs/y.md`.

For each revision, the walk reads `repos/<o>/<r>/git/trees/<rev>?recursive=1` once, into a map from path to `(type, mode, sha, size)`. Mode is compared as the string GitHub returns. A `truncated` tree makes the walk incomplete; this differs from `tree_entries()`, which raises `Fail`.

### 3. Entry files and resolution
An **instruction file** is a `blob` whose lower-cased basename ends in `.md` or `.mdc` or equals `.cursorrules`.

**Entries** at a revision are the instruction files whose path satisfies `agent_config()`. An `agent_config()` path with mode `120000`, a symlink of any name, makes the walk incomplete.

Each entry's two memberships are computed separately, comparing paths lower-cased and matching every rule at any depth:
- **Cursor-read** when any of these holds: its path has a `.cursor` component, or an `.agents/skills/`, `.claude/skills/`, `.codex/skills/`, `.claude/agents/` or `.codex/agents/` segment (Cursor loads skills and subagents from these: cursor.com/docs/skills, cursor.com/docs/subagents); its basename is `agents.md` or `.cursorrules`; or its basename is `claude.md` and it is not inside a `.claude/` directory.
- **Claude-read** when any of these holds: its path has a `.claude` component; its basename is `claude.md`, `claude.local.md` or `agents.md`; or it is not Cursor-read. An entry neither reader is documented to load is thus treated as Claude-read, the stricter reading for absolute paths.

Its **reader** is both when it is both Cursor-read and Claude-read, cursor when only Cursor-read, and claude when only Claude-read. So `.cursor/CLAUDE.md` and `.claude/rules/.cursor/x.md` are both. The reader passes to every file reached from that entry.

**`resolve(rev, path)`** walks the path one component at a time, keeping a stack:
- An empty component or `.` is skipped.
- `..` pops the stack. Popping an empty stack puts the path outside the repo, and the result stays outside whatever follows.
- After each push, the prefix is looked up in the revision's map:
  - a symlink makes the walk incomplete for a live candidate, and drops a non-live candidate;
  - a gitlink (type `commit`) joins the exact set (§5), and resolution continues lexically. The components under the gitlink have no entries, and a following `..` pops it.

`resolve()` returns `'/'.join(stack)` plus two facts, or one of three sentinels: outside, root, or incomplete. The two facts are whether a gitlink is still on the stack, and the shallowest pushed prefix that had no tree entry, including one a later `..` popped.
- Every prefix is checked before `..` is applied, so normalisation cannot erase a symlink.
- An outside or root result is ignored for a non-live token. For a live one the walk is incomplete: a `..` past the root can re-enter the checkout (`@../<repo-dir>/docs/x.md`), and a root mention would cover every path.

Each tree row is read as `(type, mode, sha, size)`. Only `blob` rows must carry an integer `size`; GitHub omits it on `tree` and `commit` rows. A blob row without one is a malformed tree.

### 4. Parsing
Only fetched files are parsed: entries and live-imported blobs (§5).

A **token** starts at every `@` whose preceding character is not an ASCII letter or digit, so `a@b.com` and `serve@14` are not tokens. That covers a link's `)`, an HTML `>`, a backslash and emphasis markers such as `**@docs/x.md**`. Its text runs from after the `@` to the next whitespace not escaped with a backslash. An escaped space becomes a plain space.

Each token yields candidates from up to three **bases**:
- the text as is;
- if the text contains `](`, the part before the first `](`;
- if the text contains `#`, the part before the first `#`. Claude Code 2.1.296 cuts a token there, so `@docs/policy.md#rules` imports `docs/policy.md`.

Each base gives two candidates: the base itself, and the base with any trailing `. , ; : ! ? ) ] } > " ' * _ ~ `` ` `` removed. So `[**@docs/x.md**](docs/x.md)` yields `docs/x.md`.

A **root-only** candidate is one made only of `/` and `.` characters, such as `/`, `.` or `./`. One counts only when it is the token's text as is. A root-only candidate produced by a cut or a strip is dropped, so `` `@/*` `` yields `` /*` `` and `/*`, never `/`.

Each token has two liveness views, and a token is **live** when either holds:
- **Cursor-live:** the visit's reader is cursor or both, in any fetched file.
- **Claude-live:** all of the conditions below hold. They are checked on every visit, whatever the reader.

The Claude-live conditions:
- **outside an inline code span.** Fence lines get no special treatment. Spans are paired per line: a backtick run opens a span closed by the next run of the same length on that line. CommonMark pairs across lines within a paragraph, and per-line pairing gives the same spans only when every run finds its closer on its own line. So if any line of a **paragraph** (a run of consecutive non-blank lines) holds a backtick run with no closer later on that line, such as a ```` ``` ```` fence line, or a backslash directly before a backtick, code spans are ignored for that whole paragraph. Other constructs can swallow a backtick before code spans are paired: raw HTML and autolinks (`<1`@example.com>`), link destinations (`[x](a`)`), reference definitions and backslash escapes. So code spans are also ignored in any paragraph holding `<`, `\`, `](` or `]:`. Every one of these rules can only make more tokens live; code spans are honoured only in paragraphs plain enough that per-line pairing matches Markdown.
- **not quoted.** A token is quoted when the character immediately before its `@` is a `"` or `'` that is not itself preceded by a backslash. A quoted token is not Claude-live. Nothing else about quotes changes liveness, so `don't @docs/a`, `"see @docs/a"` and `\"@docs/a` are Claude-live.

Rules for each candidate, applied to the raw candidate text before any joining:
- **empty, or a URL** (starts with a scheme, `[A-Za-z][A-Za-z0-9+.-]*://`): ignored. Neither names a file a PR can edit. A `://` later in the text, as in `docs/a://rules.md`, is an ordinary path.
- **starts with `~`:** incomplete if the token is live, otherwise ignored. A cloud checkout can sit under the agent's home directory, so `@~/project/docs/x.md` can name a repo file.
- **starts with `/`:** incomplete if the token is live, otherwise ignored. An absolute path can point into the checkout for either reader.
- **anything else:** `resolve(rev, posixpath.join(dirname(file), candidate))`. On a visit whose reader is cursor or both, a live candidate is also resolved two more ways, because Cursor's Agent finds a bare mention such as `@express-service-template.ts` with its own search tools:
  - `resolve(rev, candidate)` from the repo root;
  - by name: every path in the union of the `head` and `base_tip` trees that equals or ends in `/` plus the normalised candidate, for a candidate with no `..` component. Searching the union catches a file only the merged tree holds. Each match is resolved at the visit's revision and handled as a live resolved path (§5); a match with no entry there joins the exact and cover sets.

  Neither extra reading applies to Claude-only files such as `.claude/CLAUDE.md`.

### 5. Walking
The walk builds two sets, each unioned across both revisions:
- the **exact** set, matched by equality only;
- the **cover** set, matched by equality or prefix.

Every entry joins the exact set. The queue holds `(rev, path, depth, reader)`, and a visited set of `(rev, path, reader)` ends cycles. Keeping `reader` in the key matters: a file first reached from a Claude-only entry is parsed again, with root-relative candidates and Cursor liveness, when a Cursor-read entry reaches it.

The walk is breadth-first: depth `d` is fully processed before depth `d+1`. Entries are at depth 0, and a file reached from a depth-`d` file is at depth `d+1`.

A **non-live** candidate's resolved path joins the exact set, and nothing else happens.

A **live** candidate's resolved path is handled by its tree entry:
- **`blob`, of any name or extension:** joins the exact set and is enqueued at `d+1`, unless already visited. Claude Code follows imports through any file, so `@README` and `@package.json` are walked like `@docs/a.md`.
  - **Depth limit.** A file at depth 5 is fetched and parsed, but a live candidate in it that resolves to a blob not already visited makes the walk incomplete instead of being enqueued. So a chain longer than Claude Code's four hops plus one spare is never dropped silently. Every other outcome below applies at depth 5 as at any depth.
- **`tree`:** the walk is incomplete.
- **`commit` (gitlink), or a path `resolve()` flags as under one:** joins the exact set, and the walk is incomplete. Submodule content is not in this tree, yet a submodule's file can import `@../docs/policy.md` back into the parent. On 2026-10-11 the three repos held no gitlinks, so this costs nothing today.
- **No entry:** joins both the exact set and the cover set. This catches a file or directory the PR adds, including one that only the merged head+base tree holds. A cover on a path that turns out to be a file is harmless over-inclusion.

Whatever the outcome, when `resolve()` reports a missing prefix for a live candidate, that shallowest missing prefix also joins the cover set. So if `base_tip` imports `@docs/link/x.md` with no `docs/link`, a PR that adds `docs/link` as a symlink or a directory is agent config, although neither walk alone sees the merged result.

Candidate extraction is cached by blob SHA, so a blob reached under several paths or readers is parsed once.
- **The cache holds only reader-independent syntax:** each candidate text, plus whether its token sits in a code span or after a quote.
- **Each visit recomputes the rest:** liveness, from the visit's reader (§4); and resolution, from the visiting path's directory and the reader.

**Fetching.** Only entries and enqueued blobs are fetched, by object id:

```graphql
query($owner: String!, $name: String!, $o0: GitObjectID!, $o1: GitObjectID!) {
  repository(owner: $owner, name: $name) {
    f0: object(oid: $o0) { ... on Blob { byteSize isBinary isTruncated text } }
    f1: object(oid: $o1) { ... on Blob { byteSize isBinary isTruncated text } }
  }
}
```

- Every value is passed as a raw string with `gh api graphql -f`, so an all-digit owner or name is never converted to a number. Each `$oN` holds a 40-hex SHA from the tree map. No path or other repository text enters the query.
- A SHA seen at both revisions, or under two paths, is fetched once.
- A blob to fetch whose tree-map `size` exceeds 512 KiB makes the walk incomplete without being fetched.
- One query holds at most 50 aliases and at most 2 MiB of tree-map size in total.

A result is parsed only when all of these hold: `isBinary` is `false`, `isTruncated` is `false`, `byteSize` is at most 512 KiB, and `text` is a string. Every other shape makes the walk incomplete, including `isBinary: true` on any file, since GitHub flags a text file holding one NUL byte as binary. On 2026-10-11 no agent-config file in the three repos imported a binary, so this costs nothing today.

**Limits.** Each of these makes the walk incomplete:
- more than 300 distinct blobs to fetch;
- more than 12 GraphQL queries;
- more than 2000 visited states;
- either tree truncated;
- the walk deadline in §7 passing.

A malformed tree or GraphQL response, a GraphQL `errors` array, or a failed `gh` call that is not a timeout raises `Fail` (exit 1), as every other read does.

### 6. Effect
A changed path counts as agent config when either of these holds:
- `agent_config(path)` is true;
- lower-cased, it equals a lower-cased path in the exact set, or equals or lies under (`r + "/"`) a lower-cased path in the cover set.

That one predicate replaces `agent_config()` in `skippable()` and in the `agent_config_edited` field.

The walk is **incomplete** exactly when one of these happens:
- an `agent_config()` path is a symlink, including a symlinked directory such as `.cursor/rules`, or a symlink is met while resolving a live candidate;
- a live candidate starts with `/`;
- a live candidate starts with `~`;
- a live candidate resolves outside the repo or to the repo root;
- a live token resolves to a tree, or to or under a gitlink;
- a depth-5 file has a live candidate that resolves to a blob not already visited;
- a truncated tree is returned;
- a blob to fetch is over 512 KiB;
- a fetched blob comes back in a shape that is not parsed, including any binary;
- the blob, query or visited-state limit is exceeded;
- the walk deadline passes.

When the walk is incomplete:
- `agent_config_edited` is 1, whatever the number of changed paths, and every changed path counts as agent config;
- the PR routes to Shipping and is never auto-kicked, so the operator lands it by hand through the ADR 0054 D4 escape.

The stdout line, stderr and exit codes are unchanged. The classifier does not say which condition fired (§Residuals).

### 7. Timeouts
**Walk deadline.** The walk has its own wall-clock budget, `WALK_DEADLINE = 600` seconds, measured from its first call. Each walk `gh` call gets `min(GH_TIMEOUT, remaining)` as its timeout. If the deadline passes or a walk call times out, the walk is incomplete; it does not exit 1. Any other `gh` failure still raises `Fail`.

**Worst cases.**
- **Classifier:** 8 non-walk calls × 120s = 960s, plus the 600s walk, about 1560s in all.
- **Kicker:** `CLASSIFIER_TIMEOUT` 1700s + 11 more `gh` calls × 120s + 3 × 10s of `UNKNOWN` retries = 3050s. That is under the 3300000 ms stated below and the 3600000 ms Bash cap.

**Changes.**
- `scripts/shipping-kick.py`: `CLASSIFIER_TIMEOUT` becomes 1700, and its comment states both worst cases.
- `tests/test-shipping-kick.sh`: it rewrites that literal with `sed`, so its pattern changes to `CLASSIFIER_TIMEOUT = 1700 ` in the same commit.
- `skills/pr-grind/references/completion.md`: the prose above the direct classifier call (line 573) says to run it with a Bash timeout of 1800000 ms, and the prose above the kicker call (line 609) says 3300000 ms. The bash blocks themselves are unchanged, since `tests/test-needs-shipping.sh:382` requires the kick block to be one line. An interrupted classifier call merges nothing, but it would end the grind without a classification. An interrupted kicker call can still have posted the kick, and a re-run dedupes on the head marker.

### 8. Docs
- ADR 0055 is amended. Agent config now also includes paths reached through imports from agent-config files at `head` or `base_tip`. The amendment records the §6 failure split and the symlink and directory decisions.
- The operator-facing descriptions of agent config at `skills/pr-grind/SKILL.md:83` and `skills/pr-grind/references/completion.md:571` each gain one clause naming imports.
- The docstrings of `agent_config()` and `skippable()`, and the module header, are updated to match.

## Testing
`tests/test-needs-shipping.sh` gets a stub-`gh` extension that serves `?recursive=1` trees and GraphQL blob batches from fixtures, keyed by object id. The stub's tree key strips the `?recursive=1` query, `opt_in()` writes default non-truncated recursive trees for `HEAD` and `BASE` with a `size` on every blob row, and `api graphql` is served instead of falling through. Every existing opted-in case keeps its current stdout.

**Opt-in and basic routing**
- A repo that is not opted in makes no `?recursive=1` or GraphQL calls.
- A docs-only PR editing an imported file → shipping, `agent_config_edited=1`. It was `merge` before.
- A code+docs PR editing an imported file → `agent_config_edited=1`.

**Import graph**
- A two-hop import, and a cycle.
- A chain of exactly five imports, where depth 5 is parsed and has no further candidate → complete. A sixth import of an instruction file → incomplete, and a depth-5 file whose live candidate is an existing `@package.json` → incomplete.
- `@docs/policy.md#rules`, with only `docs/policy.md` edited → agent config.
- `[see](x)@docs/a.md` and `\"@docs/a.md` in Claude-only prose import `docs/a.md`.
- `base_tip` imports a live `@docs/link/x.md` with no `docs/link`; the PR adds `docs/link` as a symlink → agent config.
- A depth-5 live `@docs/new.md` with no entry, where the PR adds `docs/new.md` and touches `docs/other.md` → `docs/new.md` is agent config and the walk is complete.
- A file import inside a code span still counts, unfetched.
- A backticked `@docs/notes.md` whose prose holds `@/abs` leaves an unrelated docs-only PR at `merge` with the walk complete.
- An import present only at `base_tip`, and one present only at `head`.
- A missing target the PR adds → agent config.
- A live `@docs/new-rules/` present only at `base_tip`, with no tree there, and a PR that adds only `docs/new-rules/a.md` → `agent_config_edited=1`.
- `@package.json` in `.claude/CLAUDE.md`, with only `package.json` edited → `agent_config_edited=1`. Its `"@types/node"` dependency key is quoted, so not Claude-live, and that visit is Claude-only, so the key adds nothing. Imported from root `CLAUDE.md` instead, the key is Cursor-live and adds only a `types/node` cover.
- A chain `CLAUDE.md` → `@README` → `@docs/policy.md`, with only `docs/policy.md` edited → agent config.
- A link import `[@docs/x.md](docs/x.md)`, with only `docs/x.md` edited → agent config.

**Directories**
- A live `@docs`, with `docs/guide.md` importing `@../src/conventions.md` and a PR that edits only `src/conventions.md` → incomplete, so agent config.
- A backticked `@docs/guides` in a Claude-only file leaves a docs-only `docs/guides/a.md` PR at `merge`, including when `docs/guides/` exists only at `head`.
- A backticked `@docs/policies` in a Cursor-read file → incomplete.

**Fences and code spans**
- A `@/abs` inside a ```` ``` ```` fenced block in a Claude-only file → incomplete, since fences are not excluded.
- At top level, `  ~~~`, `code`, `~~~`, `@../docs/a.md`, `~~~`: `@../docs/a.md` is Claude-live, so a PR that edits only a file `docs/a.md` imports → agent config.
- A Claude-only paragraph whose line 1 ends with an unpaired backtick, line 2 is the single span `` `code @../docs/a.md literal` `` and line 3 starts with a backtick. Per-line pairing alone would hide the token, so this fails without the paragraph fallback. With it the token is live, and a PR that edits only `docs/b.md`, imported from `docs/a.md`, is agent config.
- A paragraph whose backticks all pair on their own lines keeps its code spans: `` `@/x` `` there is not live.

**Paths outside the repo**
- A live `@~/x.md` and a live `@../../outside.md` → incomplete. The same tokens in backticks in a Claude-only file are ignored.
- A live `@/abs/x.md` in Claude-only markdown prose → incomplete.
- `@/x` in a Claude-only code span, or after a quote → an unrelated docs-only PR stays `merge`.
- A `.ts` file imported from a Claude-only entry holds `import x from '@/lib'` → not Claude-live, so an unrelated docs-only PR stays `merge`.
- The same `.ts` file imported from `AGENTS.md`: `@/lib` is Cursor-live, so → incomplete.
- A Cursor rule imports an extensionless `README` whose backticked `@docs/policy.md` imports `@docs/detail.md`. A PR that edits only `docs/detail.md` → agent config.
- A live `@assets/logo.png` binary → incomplete. A backticked one in a Claude-only file is not fetched and leaves the walk complete.
- A `@/lib` in `.cursor/skills/s/SKILL.md`, and `@/workspace/project/docs/policy.md` in a Cursor rule → incomplete.
- A backticked `` `@/*` `` in `.claude/CLAUDE.md`, in a plain paragraph, is not Claude-live, so an unrelated docs-only PR stays `merge`. The same note in root `CLAUDE.md` → incomplete, since it is Cursor-live. `` `@/*` `` never yields the root-only candidate `/`.
- `` [x](a`) @../docs/a.md ` `` in `.claude/CLAUDE.md`, with `docs/a.md` importing `docs/b.md` and only `docs/b.md` edited → agent config.
- A Claude-only paragraph holding `<https://example.com>` and a backticked `` `@/x` `` → code spans ignored there, so incomplete. The same holds for the line ``<1`@example.com> @../docs/a.md ` `` when `docs/a.md` imports `docs/b.md` and the PR edits only `docs/b.md`.
- `@docs/a://rules.md` in root `CLAUDE.md`, with only `docs/a:/rules.md` edited → agent config; `@https://example.com/x.md` is ignored.
- A bare `@template.ts` in `.cursor/rules/r.mdc`, with only `src/gen/template.ts` edited → agent config, found by name. The same holds when `@template.ts` exists only at `base_tip` and the PR adds `src/gen/template.ts`.
- `@docs/x.md` in `.claude/agents/a.md` and in `.codex/agents/b.md`, with only the root `docs/x.md` changed → agent config.
- `[**@docs/x.md**](docs/x.md)` in Claude-only prose, with only `docs/x.md` edited → agent config.

**Symlinks and gitlinks**
- Each of these → incomplete:
  - a symlinked entry `.claude/rules/x.md`;
  - a symlinked directory `.cursor/rules`;
  - `docs/link` as a symlink, with a live import of `docs/link/../payload.md` and only `tests/payload.md` changed;
  - a live import whose target is a symlink.
- A backticked `@docs/link` that resolves through a symlink, and a backticked `@README` in a depth-5 file, both in Claude-only files, leave the walk complete.
- A live import of `vendor/rules.md` under a gitlink `vendor` → incomplete. A backticked one in a Claude-only file only joins the exact set.
- `@submod/../docs/x.md`, with only `docs/x.md` changed → agent config.

**Cursor**
- `@docs/x.md` in `.cursor/skills/verify-site/SKILL.md`, with only the root `docs/x.md` changed → agent config. The same holds for `.claude/skills/s/SKILL.md`.
- `` `@shared` `` in `.claude/CLAUDE.md`, with only `shared/a.ts` changed → not agent config.
- A shared file reached first from a Claude-only entry and then from a Cursor-read entry gets its root-relative candidates. If it holds a backticked `@docs/policies`, that token is live on the Cursor visit, so the walk is incomplete.
- A `.cursorrules` file that imports a doc.
- `frontend/CLAUDE.md` and a lower-case `frontend/agents.md` are Cursor-read.
- Readers: `.cursor/CLAUDE.md` and `.claude/rules/.cursor/x.md` are both; `pkg/.agents/skills/s/SKILL.md` and `pkg/.cursorrules` are cursor; `.claude/rules/x.md` is claude.

**Size, shape and limits**
- More than 50 entries at both revisions → classified precisely, deduplicated and chunked. Batches also split by the 2 MiB byte budget.
- A 600 KiB blob that is neither an entry nor a live import leaves a docs-only PR at `merge` with no fetch. This covers a backticked 600 KiB `.md` target in a Claude-only file.
- Each of these → incomplete:
  - a truncated tree;
  - a live-imported 600 KiB JSON file, without a fetch;
  - an `isTruncated` blob;
  - an `isBinary: true` `.md` blob, an `isBinary: true` `notes.txt`, and an `isBinary: null` one;
  - more than 300 blobs;
  - a 13th GraphQL query; exactly 12 queries stay complete;
  - more than 2000 visited states;
  - a passed walk deadline (stubbed clock);
  - a walk call that times out.
- Each of these → exit 1, with stdout and exit code asserted:
  - a GraphQL `errors` array;
  - a malformed recursive tree;
  - a malformed GraphQL response;
  - a walk `gh` call that fails without timing out.

**Elsewhere**
- `tests/test-shipping-kick.sh` asserts the new `CLASSIFIER_TIMEOUT`.
- `tests/test-needs-shipping.sh` greps `completion.md` for the 1800000 ms and 3300000 ms sentences.
- `--selftest` gains parser, resolver and query cases:
  - an escaped space;
  - trailing punctuation;
  - the `](` link candidate;
  - an email-like `a@b` that does not import;
  - token starts after `)`, `>`, `\`, `*` and a letter or digit;
  - liveness in each kind of file, inside and outside code spans, and inside a fence;
  - quotes: `"@docs/a"` is not Claude-live; `don't @docs/a`, `"see @docs/a"`, `"done" @docs/a` and `\"@docs/a` are Claude-live;
  - root-only candidates: `@.` and `@./` are root mentions, while `` `@/*` `` and `@/.,` yield none;
  - a symlink prefix before `..`;
  - a gitlink before `..`;
  - the root result;
  - the generated GraphQL text for two aliases.

## Residuals
- Only `@path` references are followed. Another mechanism, such as a tool that loads files named in prose, is not.
- Code spans are paired per line, and a paragraph whose backticks do not all pair on their own lines ignores code spans (§4). Other CommonMark inline rules that outrank code spans, such as autolinks and raw HTML, are not modelled.
- In Cursor-read files, live tokens that match no path, such as the npm scope `@playwright/test` or the JSON-LD key `@type`, become covers (`playwright/test`, `type`). They are harmless until a repo adds a matching top-level path, which is then swept into agent config. The §6 comparison is case-insensitive, so a Cursor `@Docs` mention with no `Docs` entry covers all of `docs/`.
- Cursor's resolution and depth are undocumented. Root-relative reading and the depth-5 rule are the coverage, and a deeper chain goes incomplete.
- Each revision is walked on its own. That covers the merged head+base tree for files: a file the PR did not touch has its `base_tip` content there, so on any merged-tree chain the `base_tip` walk reaches the first PR-touched file. A path that exists only in the merged tree is caught by the no-entry and missing-prefix cover rules (§5).
- Likewise, a hook or MCP server command in `.claude/settings.json`, `.cursor/hooks.json` or `.mcp.json` can name a repo script, and an edit to that script is still classified as ordinary code. That is a separate gap, to be filed as its own issue.
- An incomplete walk does not say which condition fired, so the operator investigates a surprise hand landing by reading the import graph.
- Tree lookups are case-sensitive, as git and the Linux cloud checkout are. The §6 comparison is case-insensitive.
- The walk reads committed content only. An operator's untracked local files are outside the PR's reach anyway.
- **Review status.** Blueprint review ran five times. Each round found about two new parser edge cases while the design itself held, and the fifth run parked. The operator then chose to proceed past the design gate (2026-10-12) with the last four fixes applied. Litmus then reviewed the spec text and found more of the same kind; each was closed by removing an exclusion rather than adding one (fences, `://`, gitlinks, the leading `/`). Known open lower-severity items, carried into the plan as follow-ups: root `CLAUDE.md` and `AGENTS.md` pass the both reader on, so a by-name match on a directory (`@media`, `@config`) makes the walk incomplete; and the parser tests are example-based, with a property-based check left for the plan to decide.
