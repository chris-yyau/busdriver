# Task 2 — Repository-wide design-review marker (worktree fail-open)

> **Standalone design doc**, lifted out of `docs/plans/2026-07-12-pipeline-audit-fixes.md`
> Task 2. **Descoped (2026-07-13) to the accidental worktree fail-open only** — see §2.
> **Rearchitected (2026-07-14, ultimate-council) to a directory of immutable per-arming tokens** —
> lock and whole-file mutations deleted. **Corrected (2026-07-15, blueprint-review): (iter 1) the
> reader is EXISTENCE-keyed, not PASS-keyed; (iter 2) the pre-implementation gate's `.claude/`
> write-allowlist is scoped repo-relatively so a worktree homed under `.claude/worktrees/` is not
> vacuously exempted (ADR-E), and the legacy union is a bounded per-worktree-root probe (no
> recursive `find` on the 5 s-budget gating path).** Two adversarial forks (fail-closed arming, a
> forge-proof content-bound trust anchor) remain deferred. Implementation is its own PR after this
> doc passes review.

**Goal:** Close the *accidental* fail-OPEN where a design doc authored in one worktree does not
block commits/implementation in a *linked* worktree — the normal busdriver flow (plan in `main`,
implement in a linked worktree, which here lives under `<main>/.claude/worktrees/<name>/`). Every
fix is proven by a shell test that FAILS before and PASSES after.

**Tech stack:** bash, python3 (stdlib: `hashlib`, `secrets`, `os`). No new dependencies.

**Global constraints (inherit from parent plan):** fail-CLOSED is non-negotiable; shellcheck
clean on touched `*.sh`; conventional lowercase commit subject; litmus fires per commit; no
skill deletions. **The read gates run under a 5 s (pre-implementation) / 10 s (pre-commit)
PreToolUse timeout (`hooks.json`); a timed-out hook emits no block ⇒ fail-OPEN, so every hot-path
operation must be bounded.**

**Why a rethink, not a patch (council record).** The prior single-file + `mkdir`-lock design
FAILed review 4/4 and an ultimate-council converged 5/5 against patching the lock (accidental
complexity: rmdir-on-nonempty, first-add fail-open, cross-host false-steal, god-module). The
insight (Mythos Witness): **git loose refs** — one file per key, add = atomic create, remove =
atomic unlink — need no lock (no read-modify-write) and a ref's *existence* is the signal (you do
not parse the ref to decide whether it is set). The Critic refined plain one-file-per-doc into
**option C** (immutable per-arming *tokens*) to also kill a lost-rearm race; the EXISTENCE-keyed
reader is what makes the loose-refs analogy actually hold.

---

## 2. Scope — and what is explicitly deferred

**IN SCOPE (this PR):**
- **ADR-A** — one shared marker location across linked worktrees.
- **ADR-B** — each pending doc is one token file keyed on the doc's physical absolute path.
- **ADR-C** — read gates are **pure, existence-keyed classifiers** that never mutate.
- **ADR-D** — directory of immutable per-arming tokens; arm = create, retire = trusted-loop unlinks
  its pre-review snapshot; **no lock**.
- **ADR-E** — the pre-implementation gate's `*"$STATE_DIR"/*` write-allowlist is scoped
  **repo-relatively**, so an implementation file inside a linked worktree homed under
  `<main>/.claude/worktrees/<name>/` is not vacuously exempted (without this the pre-implementation
  half of the fix is inert in busdriver's own layout).

**DEFERRED (tracked follow-up issue — do NOT attempt here):**
- **Fail-closed arming.** Arming lives in a **PostToolUse** detector (`check-design-document.sh`,
  `hooks.json:222-233`) that self-declares fail-open (`trap 'exit 0' ERR`, 5 s timeout) and cannot
  block. Making it fail-closed means moving it into a PreToolUse gate. This PR keeps arming
  best-effort: a timeout/ERR/create-failure or an unresolvable Bash-redirect `cd` may still fail to
  arm — **unchanged from today, not regressed.** A missed arm is the deferred *arming* fail-open,
  not durable state loss (ADR-D — no shared state to corrupt).
- **Forge-proof trust anchor.** No content-hash verdict record is built here (§3).

Follow-up issue on merge: *"Design-review marker: fail-closed arming + forge-proof content-bound
trust anchor"* — carries arming location, content-bound verdict, divergent-branch collision,
Bash-write effective-directory resolution, and the SessionStart subdir-legacy auto-import.

---

## 1. The bug, from the actual code (verified this session)

A non-empty marker blocks commits and implementation writes. Today it is a single markdown file.
**Four divergences** make it fail-open across worktrees:

| # | Divergence | Where (verified) |
|---|-----------|------------------|
| 1 | **Location base differs.** Write is CWD-relative `$STATE_DIR/…`; pre-commit reads `$REPO_DIR/$STATE_DIR/…`; **pre-impl reads CWD-relative `$STATE_DIR/…`** (NOT repo-anchored); cleanup is CWD-relative. Three bases. | write `check-design-document.sh:164`; pre-commit read `pre-commit-gate.sh:273`; pre-impl read `pre-implementation-gate.sh:427` (CWD-relative); cleanup `design_cleanup.py:14`, `load-orchestrator.sh:50` |
| 2 | **Entry-resolution base differs.** pre-commit resolves relative entries against `$REPO_DIR`; pre-impl/cleanup against CWD. | `pre-commit-gate.sh:283-284`; `pre-implementation-gate.sh:596`; `design_cleanup.py:51` |
| 3 | **Absent doc ⇒ dropped (core fail-open).** `[ -f "$doc" ] && ! has_PASS`: when the doc is absent from the resolving worktree, `[ -f ]` is false, the doc is dropped from "unreviewed", and the commit passes. | `pre-commit-gate.sh:286`; `pre-implementation-gate.sh:596`; `design_cleanup.py:51` |
| 4 | **Whole-file delete.** "All reviewed" ⇒ every consumer `rm -f`s the ENTIRE marker; once shared, one reviewed doc wipes other worktrees' pending entries. | `pre-commit-gate.sh:297`; `pre-implementation-gate.sh:603`; `run-design-review-loop.sh:1193`; `design_cleanup.py:67` |

Also latent (fixed here as ADR-E): the pre-implementation gate's write-allowlist substring-matches
`.claude/` (`pre-implementation-gate.sh:574-576`), and this repo's linked worktree is
`<main>/.claude/worktrees/opus4-1m-window` (verified `git worktree list`) — so every impl file in a
linked worktree is vacuously exempted and the pre-impl block never fires there.

**Canonical failing flow:** write `docs/plans/X.md` in main (`/repo`) → marker in `/repo/.claude/…`.
`cd` into the linked worktree, implement, `git commit` → pre-commit reads that worktree's
`.claude/…` which does not exist (1) → Gate 1 never fires. Sharing the marker alone is insufficient:
pre-commit would then resolve `X.md` against the wrong worktree (2), find it absent (3), and pass.

---

## 3. Trust model — the block signal, what is UNCHANGED, what deliberately CHANGES, what is DEFERRED

- **New-token path — the block decision is keyed on TOKEN EXISTENCE, not the doc's PASS comment.**
  A token in the marker directory means "pending"; it is retired ONLY by the trusted review loop
  (snapshot-prune on PASS — ADR-D) or a manual operator `rm`. The classifier never opens the doc.
  Consequence: a direct `Edit` forging `PASS` into a doc cannot clear its token, so it cannot bypass
  the new gate — a small **strengthening** of the block path.
- **The loop still writes the PASS comment** into the doc (`run-design-review-loop.sh:1156-1166`)
  for human readers, the coverage marker, and the *separate* spec-only codex-bypass gate
  (`pre-commit-gate.sh:316-347`, §9). Unchanged; the new reader simply does not consult it.
- **Legacy path — PASS-keyed** (`pre-commit-gate.sh:286`, `pre-implementation-gate.sh:596`): a legacy
  `- <path>` entry is **reviewed iff its resolved doc exists AND contains the exact
  `<!-- design-reviewed: PASS -->`**; a missing file, missing marker, unreadable, or malformed entry
  ⇒ **pending → block**. **This is a deliberate fail-closed CHANGE, not "unchanged from today":**
  today both gates *drop* a missing legacy doc (`[ -f ] && ! has_PASS` → fail-open); the union
  applies the ADR-C absent⇒pending flip to legacy entries too. During migration a legitimately
  deleted legacy doc therefore blocks until the operator drains its legacy marker (same fail-closed
  tradeoff as ADR-C).
- **DEFERRED (unchanged):** the forge-proof anchor — a signed verdict bound to reviewed *content* —
  is not built here. Existence-keying stops the reader consulting the editable marker on the block
  path, but the loop's decision to prune/PASS is still gated only by the review it runs, as today.
  This PR neither closes nor widens the deferred content-anchor hole.

---

## 4. Decisions

### ADR-A · Marker location: the shared git-common-dir

- **Decision.** A **directory** at `<git-common-dir>/busdriver/design-review-needed.local.d/`,
  resolved portably as `cd "$anchor" && cd "$(git rev-parse --git-common-dir)" && pwd -P` (no
  `--path-format`, so no git-2.31 floor), then `/busdriver/design-review-needed.local.d`. Shared by
  every linked worktree (arbiter-validated against `git init --separate-git-dir`).
- **Directory name is load-bearing for the guard (Step 5).** The basename keeps the
  `design-review-needed.local` prefix, so **every token path contains the string the existing marker
  guard already matches** (`pre-implementation-gate.sh` `MARKER_FILES` :348; `mf in fp` :354 for
  Write/Edit; `_writes_marker` :263-380 for Bash — both vectors arbiter-verified). A direct Claude
  Write/rm of a token is already blocked — no `MARKER_FILES` change; Step 5 proves it by regression.
- **Consequences.** The marker leaves `.claude/`; skip files stay in `.claude/`. Being outside
  `$STATE_DIR`, a token write is not whitelisted by the read gate's allowlist — and ADR-E makes that
  allowlist repo-relative regardless. Unresolvable common-dir → §5.
- **Alternatives.** `dirname(common-dir)/$STATE_DIR` (wrong under `--separate-git-dir`); per-worktree
  scope (reintroduces the bug); single locked file (rejected 5/5).
- **Revisit trigger.** A supported layout where `--git-common-dir` is not shared.

### ADR-B · A pending doc is one token file; keyed on the physical absolute path

- **Group key = physical absolute path (fail-CLOSED — chosen over repo-relative).** The token's group
  key is `sha256(norm)`, where `norm` is the doc's **physical absolute path** from one helper
  `gate_marker_norm_path <path>`: `dir="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)"` (**non-zero if
  that `cd` fails** — deleted/unreadable/not-yet-created parent → §2 best-effort miss), then
  `norm="$dir/$(basename "$f")"` (symlink policy: `pwd -P` resolves symlinked parents). **A
  repo-relative key was drafted and REVERTED (iter-5 HIGH):** keying on `docs/plans/X.md` is
  worktree-invariant, but that means reviewing branch-a's `X.md` would prune branch-b's *divergent,
  unreviewed* `X.md` (same key) — a **fail-OPEN**, and fail-closed is non-negotiable. The physical
  abspath is per-worktree, so it never cross-clears; the price is that arming a doc in one worktree and
  reviewing *that same doc* in another leaves a **fail-CLOSED immortal-block** (rare — a plan is
  normally authored and reviewed in the same worktree, and the worktree flow blocks *code* writes, not
  plan reviews), drained via the §6 operator token `rm`. Test (x). *(The separate repo-relative
  resolution for the ADR-B structural exclusion and the ADR-E allowlist — `gate_marker_relpath` — is a
  different helper for a different purpose; only the token KEY reverts to abspath.)*
- **Token format + body.** Filename `<sha256(norm)>.<nonce>`; body is exactly `norm` (the absolute
  path) + one trailing LF, no CR. `sha256` via python3 `hashlib` (**not** `sha256sum` — absent on macOS
  under `env -i`); `<nonce>` (`secrets.token_hex(8)`) makes every arming a distinct file (anti-race).
  The body's abspath is the block-message `doc_path` and the loop's `<sha>.*` prune key; the operator
  drains by `rm`ing the token file (`source_path`).
- **Loop-side identity (avoids `state.md` quote-stripping).** The loop recomputes `norm($DESIGN_FILE)`
  at prune time (it already holds the file path); where a persisted copy is needed it uses a **raw
  one-line sidecar** `docs/reviews/<slug>/doc-abspath.local` written verbatim, **not** a `state.md`
  YAML field — `get_state_field` runs `gsub(/"/,"")` (`state_management.sh`) and would corrupt a path
  containing a quote. Test (s).
- **norm-failure semantics.** `gate_marker_norm_path` non-zero (`cd`/`pwd -P` fails) ⇒ arm is a §2
  best-effort miss (records nothing, or the §5 legacy fallback). The **reader never resolves**: a token
  body is the stored abspath, used verbatim for the message only (existence-keyed).
- **Read-side validation + fixed check order.** The reader (a) reads the body, (b) strips exactly one
  trailing LF and rejects any remaining CR/LF, (c) requires it to start with `/`, (d) recomputes
  `sha256(stripped)` == filename hash. This runs first; the doc is never opened. A valid token yields a
  trusted `doc_path` (= abspath) for the message; an invalid one is still **pending → block**, reported
  by its opaque token path (`reason=unparseable`). Validation governs message quality, not the block.
  Test (t).
- **Structural-dir exclusion must be repo-relative (in scope, cheap).** `check-design-document.sh:115`
  early-exits on `(^|/)(agents|commands|scripts|hooks|tests|src|lib|skills)/` matched against the FULL
  path; a repo under `/home/u/src/proj/` would silently un-flag `docs/plans/X.md`. Anchor the
  exclusion to the repo-relative path (pre-existing hole; today stores the abspath at :170).
- **Revisit trigger.** Design docs routinely written via Bash redirect with a `cd`.

### ADR-C · Read gates are pure, EXISTENCE-keyed classifiers; they never mutate

- **Decision.** `gate_marker_pending <anchor>` resolves the shared marker dir (ADR-A), lists its
  token files, and **any token present ⇒ pending ⇒ block** — it does not open/stat/grep the doc for
  new tokens (existence is the pending signal). Per token it runs ADR-B validation only to build the
  message record. It also unions the legacy markers (Decision-D3), which use the PASS-keyed rule.
  **Readers never unlink/prune/whole-file-delete.** This deletes divergence 4 and subsumes divergence
  3 (a token for a deleted doc still exists → blocks — absent⇒pending, free).
- **Why existence-keyed (iter-1 keystone).** A PASS-keyed reader breaks the race fix: the loop writes
  PASS at `:1156-1166` *before* pruning at `:1193`, so a surviving post-snapshot token would read the
  now-PASS doc and classify "reviewed". Existence-keying removes the doc read from the block path, so
  a surviving token blocks regardless of the doc's marker (test (i)).
- **Structured, NUL-delimited output contract.** Because paths can contain spaces/quotes/newlines,
  `gate_marker_pending` emits per pending finding a **NUL-delimited record** of NUL-terminated fields:
  `source_kind` (`token`|`legacy`), `source_path` (the token file or legacy marker — what an operator
  `rm`s), `doc_path` (validated abspath, or empty), `reason`
  (`token`|`legacy-pending`|`unparseable`|`unreadable`). Consumers read NUL-delimited. Exit `0` = no
  pending; `1` = ≥1 pending (records on stdout); `2` = enumerate/list failure → gating callers block
  with no mutation. Both gates render `source_path`/`doc_path` from these records (§6).
- **Bounded classify + caller idiom.** The reader checks the token dir first (cheap `ls`), then the
  bounded legacy roots; it returns exit 1 as soon as pending is known but still enumerates **both**
  sources so the union (test (g)) sees token *and* legacy, capping output at **K = 20** records + a
  total count — never one python3 subprocess per token on the hot path. **A bash variable cannot hold
  NUL**, so callers must **stream** the records, not `$()`-capture them, and capture the exit via a
  temp file so `set -e`/an ERR trap cannot abort on the meaningful non-zero exit:
  `recs="$(mktemp)"; code=0; gate_marker_pending "$anchor" >"$recs" || code=$?;`
  `while IFS= read -r -d '' field; do …; done <"$recs"; rm -f "$recs"; case $code in 0) : ;; 1|2) block ;; esac`.
  Test (y) asserts a record whose `source_path` contains a space/newline round-trips intact.
- **Failure-layer rule (reconciles ADR-C/§5/D3).** An unreadable **individual** token or legacy
  marker (we know it exists, can't trust it) ⇒ that entry is **exit-1 pending**,
  `reason=unreadable`, reported by `source_path` — absent-vs-unreadable is distinguished with
  `[ -e ] && [ -r ]` (a bare `test -f` cannot separate the two). A failure to **list the token
  directory** (on an existing dir) or to **enumerate worktrees** ⇒ **exit 2** (cannot build the set).
  An **absent token directory (ENOENT)** ⇒ zero tokens ⇒ **not an error** (exit 0 unless legacy is
  pending).
- **Consequences.** Retirement is exclusively the loop's snapshot-prune (immediate on PASS) or a
  manual `rm`. A scrapped doc blocks until re-reviewed or drained. SessionStart housekeeping
  (`design_cleanup.py`) is **warn-only**.
- **Revisit trigger.** Spurious blocks from legitimately-deleted docs become common.

### ADR-D · Directory of immutable tokens — no lock; snapshot-guarded prune

- **arm (add) — best-effort, PostToolUse, §2 posture unchanged.** Compute `norm` (ADR-B),
  `sha=sha256(norm)`, `nonce=secrets.token_hex(8)`; `mkdir -p` the marker dir; create the token with
  a **create-only, no-clobber** primitive: `python3`
  `fd=os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o644)`, then write **bytes** —
  `data=(norm+"\n").encode(); off=0; while off<len(data): off+=os.write(fd,data[off:])` (os.write
  takes bytes and may short-write) — then `os.close(fd)`. `EEXIST` (nonce collision) → regenerate
  nonce, one retry; any other failure is the §2 best-effort miss. **arm never reads existing tokens
  and never dedups** (that read-before-write is the race). Duplicate tokens for one doc are harmless
  (existence-keyed) and GC'd together at prune. (temp-file + `os.rename` is an acceptable alternative.)
- **prune (retire) — ONLY the review loop, snapshot-guarded, inline (no public CLI).**
  `run-design-review-loop.sh` (today `rm -f "$STATE_DIR/design-review-needed.local.md"` at :1193)
  instead, for the reviewed doc `D` using `norm(D)` (ADR-B, recomputed from `$DESIGN_FILE`): (1) at
  loop start snapshot `SNAP = <marker-dir>/<sha(norm(D))>.*`; (2) on PASS `rm -f` exactly `SNAP`.
  The key is the physical abspath, so the prune matches only a token armed from the *same* worktree; a
  doc armed in a different worktree than the review leaves a fail-CLOSED immortal-block (ADR-B, §6
  drain) — the accepted price of never cross-clearing a divergent branch. A token created after
  the snapshot (new nonce) survives; because the reader is existence-keyed it **blocks regardless of
  D's PASS** → the lost-rearm race is killed by construction (test (i)). No lock. The prune is inline
  in the trusted loop (an agent-callable `gate_marker_remove` would be a bypass — none shipped,
  Critic); its internal `rm` is invisible to the marker guard (which sees only the top-level
  `bash …run-design-review-loop.sh` call), while a Claude tool-call `rm` of a token stays blocked.
- **No lock, no stale-lock recovery.** A SIGKILL mid-arm leaves at most a partial/empty token, which
  the reader treats as `reason=unparseable` pending — fail-closed, never a stuck mutation.
- **Revisit trigger.** Token accumulation large enough to matter (bounded by edits-between-reviews).

### ADR-E · Pre-implementation write-allowlist scoped repo-relatively

- **Problem.** `pre-implementation-gate.sh:574-576` does `case "$FILE_PATH" in *"$STATE_DIR"/*) exit
  0` — a substring match. busdriver homes linked worktrees at `<main>/.claude/worktrees/<name>/`
  (verified), so every impl file there contains `.claude/` → the gate exits 0 before the marker check
  → the pre-implementation block is inert in the exact layout Task 2 targets.
- **Decision.** Scope the allowlist to paths that are `$STATE_DIR/…` **relative to the resolved repo
  root** (strip `git -C dirname(FILE_PATH) rev-parse --show-toplevel` first), mirroring the ADR-B
  structural-dir fix. A file in a linked worktree resolves to *that worktree's* root, whose
  repo-relative path is `src/…` (no `$STATE_DIR/`) → not exempted → the marker check runs. A genuine
  `<repo>/.claude/config.local` stays exempt. Fail-closed: if the repo root cannot be resolved, do
  not exempt (fall through to the marker check).
- **Sibling allowlists (:565-571) — decided, left broad.** The neighbouring entries
  (`*PLAN*.md`, `*docs/plans/*`, `*docs/reviews/*`, `*CLAUDE.md`, `*NOTES.md`) are **intentionally not
  narrowed**: they exempt design-doc / review / notes writes, which are legitimately allowed in *any*
  worktree, and an *implementation* file does not match those patterns — so they are not an impl-write
  fail-open. Only `*"$STATE_DIR"/*`, which matches arbitrary source under `.claude/worktrees/`, needed
  the repo-relative fix.
- **Consequences.** Only the *structural allowlist* narrows; the unconditional marker guard
  (:351-356, runs earlier) is untouched. Test (l)-worktree variant pins it.
- **Revisit trigger.** A legitimate need to write repo-root `.claude/` files that this narrows.

### Decision-D2 · `design_cleanup.py` classifies via the helper; mutates nothing

Under ADR-C, SessionStart cleanup no longer mutates. It shells out (`subprocess`) to
`gate_marker_pending` (same location + classifier, explicit anchor) and prints a warning from its
records. **The warning must reach the user:** `load-orchestrator.sh:54` invokes the script with
`2>/dev/null` and captures **stdout** into the session message, so cleanup emits its warning on
**stdout** (not stderr, which is dropped). It may still delete the local
`.impl-gate-block-count.local` counter when nothing is pending. Non-gating, so subprocess cost is
irrelevant.

### Decision-D3 · Migration: bounded per-worktree-root legacy union (read-only, fail-closed)

Markers are not ephemeral (F11 removed auto-expiry: `pre-implementation-gate.sh:430-434`;
`load-orchestrator.sh:47-54`; cleanup only warns). Migration is merge-safe:

- **Hot-path (gating) legacy check is BOUNDED — no recursive `find`.** For each root in
  `git worktree list --porcelain` (+ `$REPO_DIR`), a single
  `[ -e "$m" ] && [ -r "$m" ]` probe (`m=$root/$STATE_DIR/design-review-needed.local.md`; worst case =
  N roots × one `stat`, N tiny) — an existing-but-unreadable marker (`-e` without `-r`) ⇒ exit-1
  pending (§5), which a bare `test -f` cannot distinguish; parsing only readable markers that exist.
  **No walk of worktree subtrees** — a recursive
  `find` on the 5 s-budget PreToolUse path can exceed the timeout, and a timed-out hook emits no
  block ⇒ fail-OPEN (the thing we are closing). Enumeration failure (`git worktree list` errors) ⇒
  exit 2 (block); a listed worktree with no marker ⇒ ignore; an existing-but-unreadable marker ⇒
  exit-1 pending with its `source_path`.
- **Legacy grammar.** Extract only `^- ` lines (skip frontmatter/heading). Resolve a **relative**
  entry against the **owning worktree's root** (the marker's location — the legacy writer appended
  the hook-payload path verbatim at `check-design-document.sh:170`, so Bash-redirect entries can be
  relative). PASS-keyed classify (§3); malformed entry ⇒ pending (fail-closed).
- **Subdir-CWD legacy markers → manual drain only (documented limitation).** A legacy marker in a
  worktree *subdirectory's* `.claude/` (a detector that ran with a subdir CWD) is NOT caught by the
  bounded per-root probe, and is **NOT** scanned at SessionStart either — `load-orchestrator.sh`'s
  SessionStart hook has its own ~10 s budget, so a recursive `find` there is the same timeout risk we
  refuse on the gating path. Such a marker is drained by the operator manually (its existence is rare
  — the detector CWD is normally a worktree root); the one-time auto-import is DEFERRED (§2/§9;
  cleanup never mutates marker state). Acceptable for a transitional, operator-drained migration.
- **Read-only.** Imports nothing on the gating path, writes nothing, deletes nothing. A legacy
  pending entry blocks; the message prints the exact legacy marker path(s).
- **One-time operator drain.** Review under the new flow (arms a token; loop prunes on PASS) and
  delete the named legacy marker(s). No auto-import/auto-delete on the gating path.
- Drop the legacy scan one release later — inline `# migration(remove after <version>):` receipt.

---

## 5. Resolution-failure policy (global invariant)

- **ENOREPO carve-out (must precede the exit-2 rule).** If the anchor is **not inside any git repo**
  (`git rev-parse --is-inside-work-tree` is false), there is no marker to consult and the design gate
  does not apply → **exit 0 / ALLOW** — matching today (a Write outside a repo is allowed;
  `pre-implementation-gate.sh:427` `[ ! -f ] && exit 0`). `gate_marker_dir` distinguishes this from an
  in-repo-but-unresolvable common-dir; only the latter is a fail-closed block. Test (v) pins that a
  Write in a non-git directory is NOT blocked (fail-before would block it, a regression).
- **PreToolUse read gates (in a repo)** → `gate_marker_pending` returns `2` (common-dir unresolvable
  *while inside a repo*, token-dir **list** failure on an existing dir, or worktree **enumeration**
  failure) → **block** (fail-CLOSED), no mutation. An **absent** token dir (ENOENT) is exit 0 (empty),
  not an error. An unreadable *individual* token/legacy marker is an exit-1 pending record
  (`reason=unreadable`), not exit 2.
- **PostToolUse detector** (`check-design-document.sh`) → cannot block (§2); on unresolvable common-dir
  it records to the legacy marker **anchored at the resolved repo root**
  (`$REPO_DIR/$STATE_DIR/design-review-needed.local.md` — where readers union), never CWD-relative. If
  even `$REPO_DIR` is unresolvable, a loud stderr warning + the §2 arming fail-open. Never silently
  skips.
- **Cleanup consumers** (`design_cleanup.py`, `load-orchestrator.sh`) → loud **stdout** warning
  (Decision-D2), no destructive action. Bare repo falls here.

---

## 6. Recovery paths (verified)

- **Implementation-write block** (pre-implementation gate): operator-created
  `.claude/skip-design-review.local` (consumed `pre-implementation-gate.sh:447-474`, ≥30 s age).
- **Commit block** (pre-commit gate): pre-commit consumes only `.claude/skip-litmus.local`, NOT
  `skip-design-review.local` (`pre-commit-gate.sh:242-269`); the block message must name
  `skip-litmus.local`.
- **Abandoned doc (durable drain — no removal CLI, by design).** A token whose doc was deleted blocks
  every future write/commit. The **operator deletes that token file in their own terminal** — the
  block message prints the exact `source_path`, and a human `rm` in a real terminal is not a Claude
  tool call so the marker guard does not see it. No `gate_marker_remove` subcommand ships (same-UID
  software cannot prove "human" — Critic). Skip files remain the temporary bypass; the manual token
  `rm` is the permanent drain.

---

## 7. Consumer map + implementation steps

Consumers (verified): WRITE `check-design-document.sh:164-183`; READ/BLOCK
`pre-commit-gate.sh:273-299`, `pre-implementation-gate.sh:48-54,427-428,574-576,590-606`; PRUNE/CLEAR
`run-design-review-loop.sh:1193`, `design_cleanup.py:47-71`, `load-orchestrator.sh:50-54`; GUARD
`pre-implementation-gate.sh:334-380`.

- [ ] **Step 1 — Shared helper + CLI dispatcher.** Extend
  `hooks/gate-scripts/lib/resolve-repo-dir.sh`: `gate_marker_norm_path <path>` (ADR-B physical-abspath
  token key, non-zero on `cd` failure) and `gate_marker_relpath <path>` (repo-relative — for the ADR-B
  structural exclusion + ADR-E allowlist only); `gate_marker_dir <anchor>` (ADR-A, non-zero on
  unresolvable → §5); `gate_marker_arm <abspath>` (norm+sha+nonce, `O_EXCL` bytes write — ADR-D,
  best-effort); `gate_marker_pending
  <anchor>` (existence-keyed classifier + bounded legacy union — ADR-C/D3; **mandatory** anchor;
  NUL-delimited records; exit 0/1/2; never mutates). The file is source-only today (sourced at
  `pre-implementation-gate.sh:442` and pre-commit); add the CLI dispatcher behind
  `if [[ "${BASH_SOURCE[0]}" == "$0" ]]` so sourcing has **no side effects**; unknown subcommand →
  exit 2. `design_cleanup.py` invokes the SAME classifier via `subprocess`. **No `gate_marker_remove`/
  `_prune` subcommand.** python3 for sha/nonce/path-resolution (portable under `env -i`).
- [ ] **Step 2 — Detector → token arm.** `check-design-document.sh:162-188`: replace the
  append-to-file block with `gate_marker_arm`; apply the structural-dir exclusion on the
  **repo-relative** path (ADR-B); on unresolvable common-dir, legacy fallback at `$REPO_DIR` + warning
  (§5). Keep anti-self-stamp (:141-154) and Edit-only-flag-if-no-PASS (:155-159).
- [ ] **Step 3 — Read gates → pure classifier (ADR-C) + allowlist fix (ADR-E).**
  `pre-commit-gate.sh:273-299`, `pre-implementation-gate.sh:427-428,590-606`: replace the read+grep
  loop + whole-file `rm` with one `gate_marker_pending <anchor>` (**pre-implementation resolves and
  passes an explicit anchor** — the hook-payload `cwd` or `dirname` of the target — since :427 is
  CWD-relative today); block on exit 1 or 2; consume NUL-delimited records; **remove the whole-file
  `rm`**. Additionally scope the `pre-implementation-gate.sh:574-576` allowlist repo-relatively
  (ADR-E). Block message: pre-implementation prints `skip-design-review.local`; pre-commit prints
  `skip-litmus.local`; both print each record's `source_path`/`doc_path` and any legacy path.
  **Also fix the python3-missing pre-check (`pre-implementation-gate.sh:48-54`):** its fail-closed
  probe keys on the legacy CWD marker file, which is gone post-migration → fail-open. It runs
  *because* python3 is absent, so in **pure shell** resolve the shared marker dir
  (`git rev-parse --git-common-dir`) and block if the token dir is non-empty **OR** any bounded
  per-worktree-root legacy marker exists (test (w)).
  *(Ordering note: pre-commit exits 0 before Gate 1 for `--amend`/auto-generated commits
  `:158-164,:272` — pre-existing §9 behavior, unchanged; Gate 1 keeps its current position.)*
- [ ] **Step 4 — Prune + cleanup.** `run-design-review-loop.sh:1193` whole-file `rm` → the
  snapshot-guarded inline prune of `<sha(norm)>.*` (ADR-D); snapshot at loop start; the loop
  recomputes `norm($DESIGN_FILE)` (or reads the raw `doc-abspath.local` sidecar — ADR-B — never a
  quote-stripped `state.md` field). `design_cleanup.py` shells out to `gate_marker_pending`, warns on
  **stdout** (Decision-D2), no delete, **no SessionStart subdir scan** (D3). `load-orchestrator.sh:50`
  drops the CWD-relative `[ -f ]` pre-check (cleanup resolves the shared location itself).
- [ ] **Step 5 — Marker-protection guard (verify first).** Add a Write/rm regression against
  `<common-dir>/busdriver/design-review-needed.local.d/<sha>.<nonce>`; extend `MARKER_FILES` only if
  it exposes a gap.

## 8. Tests (`tests/test-design-marker-worktree.sh`, all fail-before / pass-after)

- (a) doc-in-main / commit-in-linked-worktree → Gate 1 **fires** (headline repro).
- (b) two **distinct** pending docs (distinct abspath → distinct sha) → reviewing A prunes only A's tokens; B blocks.
- (c) reviewed doc → its `<sha>.*` tokens pruned.
- (d) malformed token (hash mismatch / empty / CR-in-body / extra trailing LF) → **pending → block**, and
  the message reports the token `source_path` with `reason=unparseable` (fail-closed + NUL-record).
- (e) plain (non-worktree) repo unchanged.
- (f) `git init --separate-git-dir` → marker dir resolves to the shared common dir.
- (g) legacy marker + new token → **both** block (union).
- (h) delete a pending doc, restart, commit → **blocked** (token exists ⇒ pending; cleanup warn-only);
  message prints the token `source_path` (drain hint).
- **(i) lost-rearm race, real ordering (keystone).** arm D (T1); snapshot {T1}; **write PASS into D**
  (simulating :1156-1166); re-arm D → T2 (new nonce); prune {T1}. Assert the gate **blocks** because
  T2 exists — though D contains PASS. (PASS-keyed would allow; existence-keyed blocks.)
- (j) design doc in a repo whose parent path contains `/src/` or `/lib/` → still flagged.
- **(l) impl Write from a linked worktree — including one homed under `<main>/.claude/worktrees/<name>/`**
  → pre-implementation gate **blocks** (ADR-C + **ADR-E**: the `.claude/`-in-path variant must not be
  vacuously exempted; the pre-ADR-E code passes it → fail-before/pass-after).
- (m) legacy marker in a **linked worktree root** → hot-path **blocks** (bounded per-root probe); a
  legacy marker in a worktree **subdirectory's** `.claude/` is a documented **manual-drain** limitation
  — assert the bounded probe does not walk into it (no hot-path or SessionStart recursive scan; D3).
- (o) after the loop prunes a reviewed doc's tokens → **allow**; a doc that still has a token but whose
  body-doc contains a *forged* `PASS` → still **blocks** (existence-keyed forge-resistance); a LEGACY
  entry whose doc has `PASS` → allow, PASS absent (or doc missing) → **blocks** (legacy PASS-keyed,
  absent⇒pending).
- (p) PostToolUse detector CWD ≠ doc worktree, common-dir unresolvable → fallback records at
  `$REPO_DIR/$STATE_DIR` (where readers union) → discoverable, blocks (§5).
- (q) marker guard (Step 5): a Claude `Write`/`Edit` and a Bash `rm` of a token path are **blocked**.
- **(r) exit-2 fail-closed:** force common-dir resolution failure, token-dir **list** failure (chmod
  the existing dir), and `git worktree list` failure → `gate_marker_pending` returns 2, both gates
  block without mutation, cleanup warns without deleting. Separately assert an **absent** token dir
  (ENOENT) → exit 0 (allow when no legacy), and an unreadable **individual** token → exit-1 pending.
- **(s) path-identity:** init the review with a *relative* doc path while the detector armed the
  *absolute* one → both resolve to the same physical `norm` (abspath), so the loop's prune glob matches.
- **(t) valid-token positive:** one well-formed token → exit 1 with one `source_kind=token` record
  carrying the trusted `doc_path` (guards against a hash/format bug making every valid token block
  forever).
- **(u) hot-path is bounded:** a large decoy subtree under a worktree (deep dirs, a `node_modules`)
  does **not** get walked by the gating legacy probe — assert the probe issues only per-root `stat`s
  (e.g. via `strace`/a shimmed `find` that fails the test if invoked on the gating path).
- **(v) ENOREPO:** a Write in a **non-git directory** is NOT blocked (fail-before would block it — §5
  carve-out regression guard).
- **(w) python3-missing post-migration:** with `python3` removed from `PATH` and only the new token
  dir present (no legacy marker), a pending token → the `:48-54` pre-check **blocks** (fail-before:
  the legacy-only probe falls through to fail-open).
- **(x) cross-worktree arm/review is fail-CLOSED, never fail-open.** (x1) arm D in a linked worktree,
  review/prune from **main** → main's abspath-keyed prune does NOT remove the worktree token → the
  worktree still **blocks** (accepted fail-closed immortal-block; §6 token `rm` drains it). (x2) two
  worktrees on different branches with a same-relpath *divergent* `X.md`; review branch-a's → branch-b's
  token is **NOT** pruned (distinct abspath) → branch-b still **blocks** (the cross-branch fail-open the
  repo-relative key would have caused — regression guard).
- **(y) NUL record round-trip:** a pending record whose `source_path` contains a space and a newline is
  streamed and parsed intact by the caller idiom (guards against `$()`-capture stripping NULs — ADR-C).

**Verify:** new test + `bash tests/test-pre-implementation-gate.sh && bash
tests/test-pre-commit-gate.sh && bash tests/test-blueprint-review-state.sh` PASS; shellcheck clean;
the full `scripts/ci/run-shell-tests.sh` glob green (gate suites PASS, never SKIP).

## 9. Out of scope / do not touch

- The `env -i` shell-gate wrapper, `gate_skip_file_repo_controlled`, anti-self-bypass 30 s check,
  deferred-marker consumption — verified healthy.
- The spec-only codex-bypass (`pre-commit-gate.sh:316-347`) and the `--amend`/auto-generated
  early-pass (`pre-commit-gate.sh:158-164,272`) — different/ pre-existing gate concerns; unchanged.
- Cross-platform `stat`/`sed`/`date` — already correct (Issue #338).
- **Everything in §2 "DEFERRED"** — fail-closed arming, forge-proof content-bound anchor, Bash-write
  effective-directory resolution, divergent-branch collision, SessionStart subdir-legacy auto-import,
  and auto-import/auto-delete consolidation. (The read-side bounded union is IN scope per D3; the
  *mutating* consolidation is deferred.)
- **Any lock, owner file, or stale-lock recovery** — deleted by ADR-D, not to be reintroduced.

## 10. Success criteria

- (a) worktree repro FAILS before, PASSES after; a stashed revert of the Step-3 semantic reds it.
- The pre-implementation block fires for a linked worktree homed under `.claude/worktrees/` (ADR-E,
  test (l)).
- No consumer resolves the marker location or a doc path against "its own" worktree; all route through
  the shared helper with an explicit anchor.
- The reader is existence-keyed, bounded, and never mutates; the only writers are `gate_marker_arm`
  (create) and the loop's snapshot-guarded prune (unlink). Test (i) passes on the PASS-last ordering;
  test (u) proves the hot path is bounded.
- The token key is the physical abspath (fail-CLOSED): reviewing a divergent branch never cross-clears
  another branch's token; a doc armed in one worktree and reviewed in another leaves an accepted
  fail-closed immortal-block drained via §6 (test (x)). The python3-missing pre-check stays fail-closed
  post-migration (test (w)).
- Every gate suite PASS (never SKIP) under the CI shell-test runner.
- The deferred content-bound trust anchor and the arming posture are demonstrably unchanged from
  pre-PR; the only trust delta is the new reader no longer consulting the editable PASS comment on the
  block path (§3), a strengthening.

## 11. Implementation hardening checklist (match existing gate conventions; TDD-proven in the impl PR)

These are line-level hardening obligations, not architecture. They match established patterns in the
existing gates and are proven by the §8 suite during implementation, not further pre-specified here.

- [ ] **python3 isolation.** Every gate python3 one-liner (sha/nonce/relpath/arm/classify) runs with
  `-S` and the same `sys.path` scrub `pre-commit-gate.sh:78-80` uses, under the existing `env -i`
  wrapper — a CWD-planted `hashlib.py`/`secrets.py`/`os.py` must not hijack the gate. (iter-3 HIGH.)
- [ ] **Block-message rendering must not depend on `jq`.** Under `env -i PATH=/usr/bin:/bin`, Homebrew
  `jq` is absent on macOS, so any jq path silently falls back. Render the NUL records into the block
  message via python3 (already required) or a safe quoting helper; embed arbitrary paths
  (spaces/quotes/newlines) without breaking `block_emit`. (iter-3 HIGH.)
- [ ] **NUL I/O end to end.** `git worktree list --porcelain -z` (worktree paths may contain
  newlines); consume records with `while IFS= read -r -d ''`.
- [ ] **List/read TOCTOU.** A token unlinked between list and read (just-pruned) → `ENOENT`-on-read is
  "gone" (skip), not `unreadable`-pending. (iter-3 low.)
- [ ] **Token-body CR/LF.** Strip exactly one trailing LF; ANY other CR/LF ⇒ `reason=unparseable`
  (fail-closed) — already ADR-B, restated for the writer/reader pair.

*(Promoted into the design this round and removed from this list: bounded-classify K + `set -e`
capture → ADR-C; the `:565-571` sibling-allowlist decision → ADR-E; the not-yet-created-dir anchor →
ADR-B's `gate_marker_relpath` deepest-existing-ancestor rule.)*

<!-- design-reviewed: PENDING -->
