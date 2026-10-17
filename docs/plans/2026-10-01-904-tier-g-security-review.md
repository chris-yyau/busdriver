# #904 — Tier G: a trailing clean Codex Security Review must not mask the verdict

> **Status: historical.** This plan records the design and validation as they
> stood during review. The current behavior is the "Amendment (#904)" section of
> `docs/adr/0043-codex-comment-form-verdict-tiers.md`, `scripts/ack-ledger.sh`
> and `tests/test-codex-clean-comment-tier.sh`. Where they differ, they win.

## Problem

Tier G (`scripts/ack-ledger.sh`, ADR 0043) acks Codex from the **latest** Codex
issue comment. It acks only when that comment opens with the clean template
`Codex Review: Didn't find any major issues.` and its `**Reviewed commit:**`
line names HEAD. The only comments Tier G drops are the two infra notices in
`CODEX_NOTICE_RE`.

Codex now posts an automatic **Security Review** (SR) as a separate issue
comment, seconds after the code-review verdict. That makes the SR the latest
Codex comment, so Tier G never sees the verdict and Codex reads `stale`.

| PR (Dive-And-Dev/jikdak) | HEAD | Verdict | SR | 👍 |
|---|---|---|---|---|
| #446 | `a99c6855` | 04:35:00Z | 04:35:14Z | 04:35:18Z |
| #447 | `8b01cdeb` | 05:12:17Z | 05:12:35Z | 05:12:40Z |

Tier F could not rescue either PR. `HEAD_PUSH_DATE` and `HEAD_CHECKS_DATE` were
both empty. Each retrigger reproduces the same comment order, so retriggering
spends the budget for nothing.

The clean SR body, full and verbatim from #446 (identical on #447 apart from the
SHA and task link):

```
### 🛡️ Codex Security Review · _Automatically triggered_

Security review completed. No security issues were found in this pull request.

**Reviewed commit:** `a99c685550`

[View security finding report](https://chatgpt.com/codex/cloud/tasks/task_e_<id>)

_Only the user who started this review can view the report in Codex._

<details> <summary>ℹ️ About Codex security reviews in GitHub</summary>
<br/>

This is an experimental Codex feature. Security reviews are triggered when:
- You comment "@codex security review"
- A regular code review gets triggered (for example, "@codex review" or when a PR is opened), and you’re opted in so security review runs alongside code review

Once complete, Codex will leave suggestions, or a comment if no findings are found.


</details>
```

It contains exactly one `**Reviewed commit:**` line.

**Residual unknown.** No SR that reports findings has been observed anywhere. We
have only the clean shape above. Getting one would mean triggering Codex on a
seeded PR, which is outside this ticket's authority (external spend). The design
therefore treats every SR that is not exactly the clean shape as a finding, and
detects SRs by a broad rule (below), so an unknown findings shape blocks rather
than slips through.

## Definitions

All of these are evaluated in jq over the Codex-authored, non-notice comments
Tier G already reads. The predicates are written **once**, as a jq `def`
prefix string (`CODEX_SR_JQ_DEFS`), and that prefix is prepended to every
query that uses them, so the selection, veto and count queries cannot drift
apart.

- **SR**: the comment's first non-empty line contains `Codex Security Review`.
  The jq predicate is `is_sr: test("\\A\\s*[^\\n]*Codex Security Review")`:
  leading whitespace and blank lines are skipped, so a body that opens with a
  blank line is still an SR (litmus/arbiter finding; it was a fail-open when
  only line 1 was tested). Since #979, leading lines that open with `<!--`
  (a receipt marker, LF or CRLF) are skipped too:
  `test("\\A(\\s*<!--[^\\n]*\\n)*\\s*[^\\n]*Codex Security Review")`.
  The observed header is
  `### 🛡️ Codex Security Review · …`. The rule is deliberately broader than that
  header because it feeds a veto, and broadening a veto fails closed. No
  code-review template contains that phrase.
- **SR SHAs**: every `**Reviewed commit:** \`<hex7-64>\`` line, extracted per
  line as `split("\n")[] | capture("^\\*\\*Reviewed commit:\\*\\*[[:space:]]*`(?<s>[0-9a-fA-F]{7,64})`")`.
  jq's `^` anchors only at string start, so a whole-body `test("^…")` would see
  only line 1. The per-line split is the anchoring mechanism. It was run
  against the #446 body above and returns `["a99c685550"]`. As in ADR 0043
  (iii), the SHA is never taken from a body-wide hex scan.
- **Clean SR**: the WHOLE body matches `CODEX_SR_CLEAN_RE`, anchored `\A … \z`.
  A prefix match is not enough: a finding inserted after the clean sentence, or
  appended to the header line, would still pass a prefix test (litmus finding).
  The regex pins, in order:
  - the exact observed header line
    `### 🛡️ Codex Security Review · _Automatically triggered_` (not
    `[^\n]*`, so text added to the header makes the SR non-clean);
  - a blank line, then the exact clean sentence
    `Security review completed. No security issues were found in this pull request.`;
  - a blank line, then exactly one `**Reviewed commit:** \`<hex7-64>\`` line;
  - an optional report link restricted to
    `https://chatgpt.com/codex/[A-Za-z0-9/_.-]*`;
  - the optional `_Only the user who started this review…_` note;
  - the verbatim `<details> <summary>ℹ️ About Codex security reviews in GitHub`
    footer through `</details>`.

  Only whitespace before `</details>` and at the very end is loose, so the
  fixture with a trailing newline still matches. The regex is held in a shell
  variable and passed with `--arg`, exactly as `CODEX_NOTICE_RE` is, so it is
  never re-escaped as a jq string literal. CRLF bodies do not match and are
  non-clean (fail-closed). A non-clean SR is never benign, so it can never
  occlude the verdict; it can only block.
- **Head and unknown SHA sets** (`sr_head_shas`, `sr_unknown_shas`). jq first
  emits the distinct SR SHAs. The shell sanitizes each to hex 7–64 before any
  git call, then sorts it into exactly one bucket:
  - **head**: `acks_head` succeeds. This is the same proof Tiers B, C and G
    use: a direct match, or an ADR 0004 content-identical predecessor (same
    tree, same parents). A message-only amend therefore neither strands a clean
    SR nor hides a findings SR.
  - **other**: `_sr_provably_other` succeeds. This is a separate, positive
    proof that the SHA names a different commit. `acks_head` failing is NOT
    that proof, because it fails the same way for a real mismatch, a missing
    object and an unreadable tree or parent (PR-mode litmus finding).
  - **unknown**: neither proof holds. An unknown SHA is treated as being about
    HEAD.

  Both sets go back to the queries with `--argjson`. Building them is part of
  (b), so any failure there exits `stale`.
- **Proof of another commit** (`_sr_provably_other`), with content identity on:
  1. both the SR SHA and HEAD (`HEAD_FULL_SHA`, else `HEAD_SHA`) must resolve
     with `git rev-parse --verify "<sha>^{commit}"`. A SHA naming a tree or
     blob, or a missing object, stays unknown. `^{tree}` alone is not enough,
     because it also accepts a bare tree SHA.
  2. both trees must resolve. Different trees prove a different commit.
  3. Equal trees need parents. Each parent list is read from the RAW commit
     object, `git cat-file commit <oid>`, keeping only the `parent ` header
     lines before the first empty line. Unequal lists prove a different commit.

  Formatted parent output (`git show -s --format=%P`) is not used here. It is
  not the stored list: `log.showSignature` prepends gpg diagnostics, and a
  shallow boundary hides parents. Because an unequal read counts as proof, either
  artifact would turn a message-only predecessor into "another commit" and drop
  its findings SR (PR-mode litmus finding, reproduced in a throwaway repo). Any
  failed read returns "not proven", so the SHA stays unknown.
- **Content identity off** (`ACK_CONTENT_IDENTITY=0`). `acks_head` is then a
  direct SHA match only, and `_sr_provably_other` returns "other" for every SHA
  that is not a direct match, without resolving any object. This is the
  explicit kill-switch semantics. The unknown bucket exists only when content
  identity is on.
- **Benign SR**: a clean SR with at least one SHA, every one of which is in
  `sr_head_shas`.
- **SR concerning HEAD**: an SR with at least one SHA in `sr_head_shas` or
  `sr_unknown_shas`. An SR with no parseable SHA also counts, but only when its
  `createdAt` is at or after the anchor (`HEAD_PUSH_DATE`, falling back to
  `HEAD_CHECKS_DATE`). When the anchor is empty, every such SR counts. An
  unattributable SR from before the push cannot block every later HEAD
  (ADR 0043's unanchored-block deadlock), while a missing anchor still fails
  closed.

## Decision

**(b) Security veto: a terminal `stale`, evaluated first.** Right after the
comment-shape validation and before Tier G's own verdict selection, take the
latest SR concerning HEAD by `createdAt`. If it is non-benign, `echo stale;
exit 0`. That exit precedes Tier G, the eyes-override, the post-anchor veto (0),
Tier F, Tier A.2 and the downgrade block, so no later 👍, resolved thread or
verdict can ack past it. This includes the production order
verdict → findings SR → 👍 with a push anchor present.

Ties are handled as follows. Several SRs concerning HEAD can share the latest
second. That is fine when every one of them is benign, as with a duplicate post
(test 23i records Codex double-posting). Otherwise the result is `stale`.

The veto clears only when a later benign SR concerns HEAD.

Every failure in (b) exits `stale` and never just declines: a jq error, a
non-integer count, or a failure building `sr_head_shas` or `sr_unknown_shas`. With no SR
concerning HEAD, (b) does nothing, so repos without SR behave exactly as they
do today.

**(a) Candidate selection (the #904 fix).** Benign SRs are dropped from Tier
G's three selection queries (`codex_max_at`, `codex_max_tie`,
`codex_last_comment`). Every other SR stays a candidate, exactly as today:
findings, another SHA, no SHA, reworded, or CRLF. When such an SR is the latest
comment, Tier G declines, as the ticket requires ("keep it as a blocker in
every other case, such as when it reports findings or names another commit").

**(c) Post-anchor veto (0).** Benign SRs are dropped from (0)'s count as well.
(0) exists to stop a later 👍 or resolved thread from acking past a Codex
comment that might be a finding. A benign SR names HEAD and says there are no
findings, so counting it could only produce a false block. One case: a
findings-free review whose clean SR lands after the 👍 would deadlock Tier F.
Every other SR, and every other comment, still counts.

**Unchanged.** Engagement (5) still counts every SR, benign ones included.
Dropping it there would turn "Codex only posted a clean SR" into `none`,
which is non-gating. That is the misreading ADR 0043 exists to prevent.
`CODEX_NOTICE_RE` is unchanged.

### Why other-commit SRs block in (a)/(0) but not in (b)

The two rules have different time scopes. (a) and (0) already reason about
time: the latest comment, or comments after the anchor. An SR naming another
commit that lands late, for example from a quick earlier push, therefore
blocks only until Codex posts newer output. That is the ticket's fail-closed
requirement for a different SHA.

(b) looks at every SR regardless of age. If it included SRs naming only
superseded commits, a repo that runs SR only on demand would be blocked
forever by one old SR. So (b) is scoped to SRs that concern HEAD. A security
finding on old code that still affects HEAD is caught by the next SR on HEAD,
since Codex runs SR alongside every code review on opted-in repos. On repos
where SR is not opted in, nothing changes from today.

### Invariants preserved

- **Same-second tie guard (Tier G).** It still applies to the remaining
  candidates. A verdict tied with a findings comment or a non-benign SR still
  declines. A verdict tied with a benign SR no longer ties, because the pair
  carries no finding in either order.
- **Live-finding veto.** Tier A.1, an unresolved non-outdated thread, still
  blocks above everything. The 👀-at-or-after and `/reviews`-at-or-after checks
  still compare against the verdict's own timestamp.
- **Last-comment semantics.** A findings comment after a benign SR is still the
  latest candidate, so Tier G declines.
- **Fail-closed parsing.** The shape validation that runs before Tier G already
  covers `.body` and `.createdAt` for every comment the new queries read.

## Tests (`tests/test-codex-clean-comment-tier.sh`)

Fixtures store the full #446 SR body above, with the SHA rewritten to the
suite's HEAD, and assert that it has exactly one `Reviewed commit` line.

`run_ledger` gains an optional push-date argument, read as `${6-$PUSH_AT}` so
that an explicit empty string is possible, and it sets `HEAD_CHECKS_DATE`
explicitly. The inlined `bash` calls set `HEAD_CHECKS_DATE` too.

The content-identity rows build throwaway git repos under one `mktemp -d` root:
one commit and a message-only amend of it, plus a second repo for the shallow
and signed-commit rows (`.git/shallow` affects a whole repo). They run the
ledger from inside that repo with `ACK_CONTENT_IDENTITY=1`.

### Fixture isolation (#961 finding, this suite only)

`git -C "$dir"` does not protect a fixture: an inherited `GIT_DIR` /
`GIT_WORK_TREE` wins over `-C`, so the fixture's `config`, `commit` and
`commit --amend` would land on the caller's real checkout (#961). This suite
fixes that for itself only; the files #961 names stay with #961.

- **Clear inherited selection and config injection, once, near the top.** Unset
  `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_PARAMETERS
  GIT_CONFIG_COUNT`, and every `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>`.
  This is the list main's `test-890-*` suites use, plus the `GIT_CONFIG_COUNT`
  family, which can inject config such as `log.showSignature` into every
  fixture git call. It runs in the test's own process, so it reaches every
  subprocess (fixture git, the ledger) and never the caller's shell.
- **Keep the deliberate per-command override.** The showSignature row passes
  `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=log.showSignature …` through `env` on
  that one ledger invocation. It is set after the unset, so it still applies.
- **Prove each fixture repo is disposable before mutating it.** Right after
  `git init` and before any `config`, `add`, `commit`, `commit --amend`,
  `commit-tree`, `mktree` or `hash-object -w`, assert both:
  - the repo directory, physically resolved, lies inside this run's fresh
    `mktemp -d` root;
  - `git -C "$dir" rev-parse --absolute-git-dir` equals `<that dir>/.git` and
    `--show-toplevel` equals that dir.

  On any mismatch the suite prints a FAIL line and exits non-zero before the
  first mutating command. It never "repairs" the environment and continues.
- **Real checkout untouched.** Apart from the fixture repos, the suite runs only
  read-only git (the ledger's `rev-parse` / `cat-file`), so the caller's HEAD,
  index and working tree are unchanged.

### Validation status

Historical, NOT re-run for this revision:

- 2026-10-02: 108 passed, 0 failed, on the then-dirty tree. Recorded only in the
  session transcript; no saved output file.
- First negative control (pre-fix ledger, the suite at 99 assertions): 70 passed,
  12 #904 assertions failed, 5 of them fail-open paths. Raw output files are no
  longer on disk; the numbers survive only in ADR 0043 and the transcript.
- Second negative control (2026-10-02, ledger byte-identical by `cmp` to commit
  `df4a109`, which still read `%P`): 106 passed, exactly 2 failed, the
  showSignature and shallow rows. Evidence is kept in the session scratchpad
  (`negctl4/evidence.md`, `run-output.txt`).

Static only, 2026-10-16T18:39Z: `shellcheck --severity=warning
scripts/ack-ledger.sh tests/test-codex-clean-comment-tier.sh` (ShellCheck
0.9.0) on the current dirty files, before the isolation edits, reported no
findings. It ran no tests, so it is not runtime evidence.

Required after the isolation lands, before any commit: the full suite, the
related ack-ledger suites, ShellCheck, and an isolation check that runs the suite
with `GIT_DIR` / `GIT_WORK_TREE` pointed at a sacrificial decoy repo (never the
real checkout) and confirms the decoy's HEAD, index and config are unchanged.
The real checkout's HEAD, index and dirty blobs are recorded before and after.

### Cases

| Case | Expected |
|---|---|
| #446 replay: verdict → benign SR → 👍, both anchors empty | `<HEAD>:G` (`stale` before the fix) |
| Clean SR names another SHA (latest comment) | `stale` |
| SR body reports findings (latest comment) | `stale` |
| Clean sentence present but not first after the header | `stale` |
| SR with CRLF line endings | `stale` |
| SR with no `Reviewed commit` line, after the anchor | `stale` |
| SR with a second `Reviewed commit` line naming another SHA | `stale` |
| Verdict → benign SR → findings comment | `stale` |
| Verdict + benign SR + 👀 after both | `stale` |
| Verdict + benign SR + later Codex `/reviews` entry | `stale` |
| Verdict + benign SR in the same second | `<HEAD>:G` |
| Verdict + two benign SRs, all in the same second | `<HEAD>:G` |
| Benign SR tied with a findings SR (both for HEAD) | `stale` |
| (b) findings SR for HEAD before the clean verdict, no 👍 | `stale` |
| (b) push anchor set: verdict → findings SR for HEAD → 👍 | `stale` (`<HEAD>:F` before the fix) |
| (b) findings SR for HEAD → later benign SR for HEAD → verdict | `<HEAD>:G` |
| (b) findings SR naming only an older SHA, then verdict → benign SR | `<HEAD>:G` |
| (b) unparseable SR before the push, then verdict → benign SR | `<HEAD>:G` |
| (c) push anchor set, no verdict comment, 👍, then benign SR after the 👍 | `<HEAD>:F` |
| (c) same, but the SR after the 👍 reports findings | `stale` |
| Only a benign SR (no verdict, no 👍) | `stale` (engagement (5), not `none`) |
| Amend: clean verdict and benign SR name the predecessor; HEAD is a message-only amend | `<HEAD>:G` |
| Amend: findings SR names the predecessor, then a clean verdict for HEAD | `stale` |
| Clean opening + appended finding (whole-shape match) | `stale` |
| A finding line inserted after each line of the clean SR (one row per line) | `stale` every time |
| Finding text appended to, or prepended on, the SR header line | `stale` |
| Clean SR with a trailing newline | `<HEAD>:G` |
| Verdict + findings SR in the same second | `stale` |
| (b) findings SR whose body opens with a blank line, then 👍 | `stale` |
| (b) findings SR behind a `<!--` receipt-marker line (LF or CRLF), then 👍 | `stale` |
| A `<!-- … -->` line with visible text before a clean SR | `stale` (an SR, not clean) |
| Findings SR names an object missing from the clone, then clean verdict | `stale` (unknown ⇒ about HEAD) |
| Findings SR names a provably different commit (different tree), then verdict → benign SR | `<HEAD>:G` |
| Stub git: trees equal, parent read fails | `stale` (identity undecided) |
| Findings SR names a TREE object, not a commit | `stale` |
| Findings SR names a signed same-tree/same-parent predecessor, `log.showSignature` on | `stale` |
| Findings SR names the predecessor, HEAD is a shallow boundary | `stale` |
| Missing-object findings SR with `ACK_CONTENT_IDENTITY=0` | `<HEAD>:G` (direct match only ⇒ another commit) |

The existing 70 assertions must pass unchanged. With the rows above the suite
has 108 assertions (70 + 38 for #904): the 36 rows above, plus the
fixture-shape check, plus one extra because the header-line row asserts the
append and prepend variants separately. The per-line insertion row is one
assertion over all lines.

## Out of scope

- The `<!-- codex-pull-request-review-summary -->` comment is edited in place
  and keeps its early `createdAt`, so it does not mask the verdict today. Its
  first line is an HTML comment, not the SR phrase, so it is not an SR.
- Tier F's anchor gaps (#788) and other open tickets (#891) are left alone.
- An SR that reports findings through inline review threads is already covered
  by Tier A.1 and the `/reviews`-after-verdict check.

## ADR

Append a short "Amendment (#904)" section to
`docs/adr/0043-codex-comment-form-verdict-tiers.md`. It records (a)–(c), the
terminal placement of (b), the head/unknown split and the `_sr_provably_other`
proof (commit resolution, raw `cat-file` parent headers), the
`ACK_CONTENT_IDENTITY=0` exception, the assertion count and both negative
controls, and the revisit triggers:

- The SR template changes. Tier G then declines again (`stale`, the fail-closed
  direction).
- A real findings-SR body is observed. It should then be captured as a fixture.

### Draft amendment edits (historical — applied to ADR 0043)

These edits have been applied to ADR 0043. They are kept as the record of what
was proposed; do not re-apply them.

The "Amendment (#904, 2026-10-02)" section was first added to ADR 0043 in
commit `5e73d3d`. It predated the raw-parent fix, so the three edits below were
proposed, gated on this plan passing review, the isolation landing, and the
fresh validation above running, with the `Result` line filled from that run.

**Edit 1.** Replace the "Unproven identity" bullet (ADR 0043 lines 210–215)
with:

```markdown
- **Unproven identity.** A SHA counts as "another commit" only when that is
  proven (`_sr_provably_other`). Both the SR SHA and HEAD must resolve with
  `git rev-parse --verify "<sha>^{commit}"`. Then either the trees differ, or
  the trees match and the parent lists differ. Parent lists come from the raw
  commit object (`git cat-file commit`, the `parent ` header lines before the
  first empty line), never from `git show --format=%P`: `log.showSignature`
  prepends gpg output to that, and a shallow boundary hides parents, so either
  would turn a message-only predecessor into "another commit". A missing
  object, a SHA naming a tree or blob, or any failed read leaves the identity
  UNKNOWN, and an UNKNOWN SHA counts as being about HEAD. `acks_head` failing
  is not proof, because it fails the same way for a real mismatch and for an
  unreadable object.
- **Content identity off.** With `ACK_CONTENT_IDENTITY=0`, `acks_head` is a
  direct SHA match only, and every other SHA counts as another commit without
  resolving any object. There is no UNKNOWN bucket. This is the kill switch's
  existing meaning.
```

**Edit 2.** Replace the first "Verification" bullet (ADR 0043 lines 241–246)
with:

```markdown
- `tests/test-codex-clean-comment-tier.sh` now has 108 assertions: the 70
  original ones plus 38 for #904. These include a check that inserts a finding
  after every line of the clean body, findings appended to and prepended on the
  header line, a stubbed `git` whose trees match while its parent read fails, a
  findings SR naming a tree object, a signed same-tree/same-parent predecessor
  read with `log.showSignature` on, a shallow-boundary HEAD, and a missing
  object under `ACK_CONTENT_IDENTITY=0`. The clean SR fixture is the full #446
  body. Rows that need real git objects build them in throwaway repos under one
  `mktemp -d` root. The suite clears inherited `GIT_DIR`, `GIT_WORK_TREE` and
  config-injection variables, and proves each fixture repo lies inside that root
  before mutating it (#961).
- Result: <N passed, 0 failed, date — from the fresh run>.
```

**Edit 3.** After the first negative-control bullet (ADR 0043 line 257), add:

```markdown
- A second negative control ran the 108-assertion suite against the ledger at
  commit `df4a109` (byte-identical by `cmp`), which still read parents with
  `git show --format=%P`. 106 passed and exactly 2 failed: the
  `log.showSignature` row and the shallow-boundary row. On both, the `%P`
  ledger acked (`:G`) past a findings SR naming the predecessor.
```

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
