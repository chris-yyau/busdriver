# ADR 0021 — Design-review marker: fail-closed pre-arm + Bash cd-effective-dir resolution

## Status

Accepted (2026-07-20). Closes the first two deferred-hardening items of issue #347
(the follow-up tail of #346, design `docs/plans/2026-07-13-task2-worktree-design-marker.md`
§2/§9). Items 3–6 and the CodeScene advisory remain accepted residuals (see #347).

## Context

#346 shipped the worktree-safe design-review marker (immutable per-arming tokens under
the shared git-common-dir, ADR-A..E) but deferred two fail-opens that Codex (litmus
xhigh) and CodeRabbit independently flagged as real during the grind:

1. **Arming cannot fail closed.** Arming lives in the PostToolUse detector
   `check-design-document.sh`, which self-declares fail-open (`trap 'exit 0' ERR`) and
   structurally cannot block. A post-resolution arm failure (the marker dir is
   resolvable but `os.makedirs`/`O_EXCL` fails) leaves **no** token, so a later read
   gate resolves the dir, sees nothing, and **allows** — a silent review loss.

2. **Bash writes are cd-blind.** A Bash tool call has no `file_path`, so the read gate
   anchored the pending-check on the payload `cwd` and the detector armed against the
   process cwd. A command that changes directory inline — `cd /other-repo && > impl.sh`
   (read gate) or `cd /other && > docs/plans/X.md` (detector) — is resolved against the
   wrong repository (fail-open on the read side; wrong-repo arm on the detector side).

The maintainer scoped this ADR to those two items and chose the **minimal** shape for
item 1 (a scoped PreToolUse pre-arm, not a full relocation of arming). A "sentinel on
arm failure" was rejected as security theater: when the failure is an FS write to the
git-common-dir, a sentinel written to that same dir fails identically, so it would be a
guard that cannot fire.

## Decision

### Item 2 engine — `gitcmd_detect.effective_cwd(cmd, payload_cwd) -> (cwd, ok)`

One shared, tested parser resolves the directory a Bash file-write lands in, honoring a
leading `cd`. It reuses the existing `split_segments` / `_tokenize` machinery and mirrors
ADR 0018's standalone-cd constraints. **It is BEST-EFFORT, not fail-closed** (`ok` is
always `True`): when the cd cannot be resolved confidently it returns the payload cwd —
the pre-existing cd-blind anchor — so the result is never *worse* than before, only
better in the confident case. Perfect static cd resolution is undecidable (a `cd` in a
function/alias, an interpreter one-liner, `xargs`, ambient `CDPATH`), so a fail-closed
promise here is an unwinnable arms race against an adversarial reviewer; the gate is
cooperative-mis-fire protection, so a best-effort accuracy bump is the right posture. The
anchor only needs to identify the write's **repository** (markers key on the
git-common-dir), so:

- No `cd` → `(payload_cwd, True)`.
- A single builtin `cd` (optionally `builtin`/`command`-wrapped — the only wrappers that
  move the parent shell's cwd) to an **absolute plain literal**, reached before any real
  command word via `''`/`;`/newline/`&&` → the target, but **only if `os.access(target,
  X_OK)`** proves bash could enter it (exists AND searchable): a `cd` into a missing or
  non-searchable dir fails, leaving the write in the prior cwd (`;`) or short-circuiting
  it (`&&`), so the prior cwd is kept. This closes both `cd /clean/missing ; write` and
  `cd /unsearchable ; write`. **Absolute-only is deliberate:** a relative operand is
  subject to `CDPATH` (`cd sub` can land outside the payload cwd), so it is left to the
  payload anchor rather than mis-resolved.
- Anything else involving a `cd` — a relative or opaque target (`..`/`$expansion`/glob), a
  second cd, a cd after a real command, a cd behind `||`/`|`/`&`, a subshell-grouped cd,
  or a `cd` token that is **not** the clean command word (inside `if`/`while`/a group) →
  falls back to `payload_cwd` (best-effort). Statically resolving every cd is undecidable
  (a `cd` in a function/alias, an interpreter one-liner, `xargs`, ambient `CDPATH`), so
  those stay the ADR 0006 hostile-dispatcher residual — never a *new* fail-open, since the
  fallback is the same anchor the gate used before this parser existed.

### Item 2b — read gate anchors on the write's real repo (`pre-implementation-gate.sh`)

The `_MK_ANCHOR` inline python imports `effective_cwd` (trusted lib dir prepended to
`sys.path` after the CWD scrub) and, for Bash, anchors the pending-check on the resolved
directory. This is a best-effort accuracy improvement: `cd /other-repo && > impl.sh` now
anchors on `/other-repo` (was the payload cwd), and any ambiguous cd falls back to the
payload cwd — exactly the pre-existing behavior, so no new blocks and no regressions.

### Item 2a — detector arms the repo the write lands in (`check-design-document.sh`)

The redirect/tee target is resolved to an absolute path via `effective_cwd` before the
anti-self-stamp PASS-strip and the arm, so both target the repo/file the write actually
lands in. An unresolvable cd falls back to the payload cwd (best-effort — PostToolUse
cannot block anyway).

### Item 1 — fail-closed pre-arm (`pre-implementation-gate.sh`)

A new early stage (before the pending fast-reject, so a *new* design doc in an otherwise
clean repo is still covered) detects a Write/Edit/MultiEdit design-doc target, and:

- mirrors the PostToolUse detector's flag logic so the two never disagree: a **Write**
  re-arms even a currently-reviewed doc (a rewrite re-opens review, so a write that
  removes/replaces PASS can never slip through unarmed); an **Edit/MultiEdit** of an
  already-honorably-reviewed doc is left alone (a small change preserves review status);
- when arming is needed and the doc is not already armed, `gate_marker_arm`s it and,
  **when the arm fails while the marker dir is resolvable, BLOCKS** the write (the exact
  residual — a resolvable dir whose token write failed); a helper failure other than
  ENOREPO falls through to the same fail-closed block;
- when the doc's parent dir does not exist yet (norm unresolvable) or the repo is ENOREPO
  → proceed, the pre-existing §2 best-effort miss, not the residual we close.

Arming stays keyed on the physical abspath (`gate_marker_arm` → `gate_marker_norm_path`)
identically to the PostToolUse detector and the blueprint-review prune, so the pre-arm
and detector never produce divergent tokens. blueprint-review stamps PASS and prunes via
its own script (guard-invisible), so the pre-arm never re-arms a doc mid-review.

## Why this does not weaken the gate

- **Item 1 is strictly additive fail-closed.** It only ever converts a former silent
  allow (arm failed) into a visible block, or arms a doc that would otherwise rely on the
  best-effort PostToolUse detector. It never allows a write the old gate blocked.
- **Item 2b is best-effort, so it never regresses.** Every ambiguous cd falls back to the
  payload cwd (the pre-existing anchor); the only behavior change is that a *confidently
  resolvable* leading `cd` now anchors on the write's real repo. No new blocks.
- **Single source of truth.** `effective_cwd` is one tested parser; the design-doc
  grammar is duplicated only where it already was (detector python + gate bash), each
  carrying the lockstep comment.

## Accepted residuals (NOT closed — see #347)

- **Bash-redirect design-doc creation** is not pre-arm-guarded (item 1 covers
  Write/Edit/MultiEdit only); it stays PostToolUse best-effort.
- **A relative `cd` / ambient `CDPATH`** — a relative `cd sub` is not resolved (left to
  the payload anchor), so a write it moves outside the payload repo is a best-effort miss,
  exactly as the pre-existing cd-blind gate behaved.
- **Edit/MultiEdit that removes PASS** from a reviewed doc — the pre-arm can't see an
  Edit's post-write content, so it defers to the PostToolUse detector's own Edit re-arm
  (best-effort). A Write, whose full content re-opens review unconditionally, is covered.
- **A hard FS failure on the git-common-dir itself** at pre-arm time still cannot record
  durable state, but item 1 now BLOCKS that write rather than allowing it.
- **A `cd` shell function/alias / interpreter one-liner** re-targeting the write is out of
  scope (the ADR 0006 hostile-dispatcher residual; this is cooperative-mis-fire
  protection, not a sandbox).

## Alternatives considered

- **Sentinel token on arm failure.** Rejected as theater — the sentinel writes to the
  same failing FS as the token (see Context).
- **Full PreToolUse relocation of all arming logic.** Rejected by the maintainer as too
  large a blast radius on a fail-closed gate; the anti-self-stamp PASS-strip genuinely
  needs the post-write file, so the detector must stay regardless.
- **Loosen `gitcmd_detect._trusted_cd`** to share cd trust. Rejected — that helper backs
  the fail-closed commit/PR security gates where `&&`-only cd trust is deliberate; kept
  the new logic in the standalone `effective_cwd`.

## Consequences

- New tests: `tests/test-design-marker-cd-prearm.sh` (effective_cwd grammar, item-2b
  cross-repo anchoring + no-false-positive, item-2a arm-targets-cd'd-repo, item-1
  arm-or-block). Existing marker/nudge suites unchanged and green.
- No new blocks from item 2b: a confidently-resolvable leading `cd` sharpens the anchor;
  every ambiguous cd keeps the pre-existing payload-cwd anchor.

## Revisit trigger

- A design doc is observed armed against the wrong repo despite `effective_cwd` → the
  resolver's repo-identification assumption is wrong.
- Cooperative-mis-fire evidence accumulates that a specific *common* cd shape is not being
  resolved (missed anchor sharpening) → extend `effective_cwd`'s confident set for it.
