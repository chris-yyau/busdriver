# ADR 0023 — Design-review marker: disposition of deferred items 4, 5, 6 (issue #347 tail)

## Status

Accepted (2026-07-22). Closes the remaining deferred-hardening items of issue #347
(the follow-up tail of #346, design `docs/plans/2026-07-13-task2-worktree-design-marker.md`
§2/§9). With items 1&2 (ADR 0021), item 3 (ADR 0022), and items 4–6 here all resolved,
issue #347 is closed; the CodeScene `marker_ops.py` complexity advisory continues to be
tracked separately in #445.

## Context

After ADR 0021 (items 1&2) and ADR 0022 (item 3), three deferred items remained on #347:

- **Item 5** is already implemented.
- **Item 6** targets a write-dead format; the feature is obsolete.
- **Item 4** was filed (and initially dispositioned here) as a "fail-closed-safe" residual —
  but a review pass (Codex litmus, HIGH) refuted that: it is a real, if narrow,
  design-review **fail-OPEN**. It is fixed here, not wontfixed.

## Decision

### Item 4 — payload-cwd allowlist → FIXED (closed a real fail-OPEN)

The pre-implementation `$STATE_DIR/` write-allowlist resolved `FILE_PATH` via
`gate_marker_relpath`, and `gate_marker_relpath` resolves a **relative** path against the
**gate process cwd** (`git -C "$d"` / `cd "$d"` on a relative dirname). Issue #347 called
this "fail-closed-safe" on the reasoning that a relative impl path resolves to `src/…`, never
`$STATE_DIR/…`. That only covered the *over-block* direction (payload cwd shallower than the
gate cwd). The **opposite** divergence is a fail-open:

- payload cwd = `<repo>/src` (session in a subdir), gate cwd = `<repo>`, `file_path =
  ".claude/impl.py"` (relative);
- the gate resolves `.claude/impl.py` against `<repo>` → repo-relative `.claude/impl.py` →
  matches `$STATE_DIR/*` → **EXEMPT**;
- but the write lands at `<repo>/src/.claude/impl.py` — an implementation file under `src/`,
  wrongly exempted from a pending design review.

This is a genuine design-review bypass, not a theoretical one: the gate's *own* code already
defends this exact gate-cwd-vs-payload-cwd divergence elsewhere (the `_MK_ANCHOR` block,
`pre-implementation-gate.sh:596` — *"NOT the gate process CWD — otherwise a write with
cwd=/other/repo…"*), and the sibling design-doc arm one branch up already resolves the
payload-cwd-joined `$_NORM_FP`. The `$STATE_DIR` arm was the one branch that never got that
treatment — the exact asymmetry item 4 names.

**Fix.** Key the allowlist on `$_NORM_FP` (the payload-cwd-joined, `normpath`'d,
newline-rejected target already computed at `:883-906`) instead of the raw `$FILE_PATH`:

    - _REL="$(gate_marker_relpath "$FILE_PATH" 2>/dev/null || true)"
    + _REL="$(gate_marker_relpath "$_NORM_FP"  2>/dev/null || true)"

This makes the arm consistent with its sibling and keys on the write's real directory. Because
`$_NORM_FP` is already `normpath`'d and newline-rejected, the fix carries none of the
newline-truncation fail-open that got the #346 attempt reverted — the reason this was
deferred is retired. Fail-CLOSED preserved: an empty `$_NORM_FP` (python failure) or an
out-of-repo target makes `gate_marker_relpath` return non-zero → no exemption → the marker
check runs. Absolute paths (the common case) are unaffected — `$_NORM_FP` equals the
`normpath` of the abspath. A regression test in `tests/test-design-marker-cd-prearm.sh`
(the item-4 section) pins the bypass closed AND checks no false positive on a genuine
repo-root `.claude/` config write; it was verified to FAIL against the pre-fix code
(`.claude/impl.py` was exempted) and PASS after.

The ADR-E half (a linked-worktree impl file under `<main>/.claude/worktrees/<name>/` resolves
to `src/…`, not `$STATE_DIR/…`) is unchanged and still holds — `$_NORM_FP` for an absolute
worktree path resolves physically to that worktree's own `src/…`.

### Item 5 — divergent-branch collision drain → ALREADY IMPLEMENTED

The immortal-block UX item 5 asked for already exists. `scripts/design-clear.sh` (ADR 0017)
lists pending tokens through the gate's own classifier and, per token, calls
`gate_marker_owner_note` (`hooks/gate-scripts/lib/resolve-repo-dir.sh`), which annotates a
token whose doc lives in a *different* worktree:

    [in another worktree, now on branch <b> — do not drain it unless it is abandoned]

and, when the doc's directory is gone:

    [doc dir missing — this marker looks abandoned]

That is precisely the "small drain helper/UX" for the fail-CLOSED divergent-branch
immortal-block (design §6 / ADR-B): the operator sees which worktree/branch armed the stuck
token and an explicit abandonment cue before draining it with `design-clear.sh <doc>`. No new
code. The token KEY stays the physical abspath (never cross-clears a divergent branch —
settled, ADR-B); only the *drain ergonomics* were the open item, and they are done.

### Item 6 — SessionStart subdir-legacy auto-import → WONTFIX (obsolete format) + cleanup

The legacy single-file `design-review-needed.local.md` format is **write-dead**: the detector
deliberately no longer writes it (`check-design-document.sh:250-252` — a `>>`/`>` to a computed
path is a symlink/TOCTOU surface). Only a bounded per-worktree-root *reader* union
(`marker_ops.py` `_classify_legacy`) still honors pre-existing markers, and D3 already plans to
drop even that one release on.

Building a recursive SessionStart auto-importer for a write-dead format — on the ~10s
SessionStart budget the design (§D3) explicitly refused a recursive `find` on — adds a
timeout-fail-**open** risk to catch a vanishingly rare, self-inflicted artifact. That inverts
the fail-closed posture for negative value.

Two such orphaned markers were found in-tree at investigation time
(`docs/reviews/{nifty-sleeping-liskov,pr-grind-lock-aware-filter}/.claude/`, created
2026-06-03 / 2026-07-01, both gitignored `.local`). Both are **inert** — the bounded gate probe
checks only each worktree *root's* `$STATE_DIR/`, never a subdirectory, so neither blocks
anything. They are stale cruft the operator removes with a plain `rm` in their own terminal:
the marker-protection guard (`pre-implementation-gate.sh` `MARKER_FILES`) correctly refuses an
*agent* Bash `rm` of any `design-review-needed.local` path — the same anti-forge posture that
makes item 3 unbuildable (ADR 0022) — so cleanup is an operator action, not an agent one. No
auto-import is added.

## Consequences

- Issue #347 is closed. Items 1&2 (ADR 0021), item 3 (ADR 0022), items 4–6 (this ADR) are all
  resolved; the CodeScene advisory remains tracked in #445.
- One code change: item 4's fail-open is closed (`pre-implementation-gate.sh` one-line arm
  swap + `tests/test-design-marker-cd-prearm.sh` regression). Item 5 is already built; item 6's
  format is write-dead. The two inert stale legacy markers are left for operator drain (the
  marker guard blocks an agent `rm`); leaving them changes no behavior since they are non-blocking.

## Revisit triggers

- **Item 4:** a *new* allowlist arm is added, or the gate stops computing `$_NORM_FP` before
  this point → re-audit that the STATE_DIR arm still keys on the payload-cwd-resolved target,
  not a gate-cwd-relative path. The regression test guards the current shape.
- **Item 6:** subdir-CWD legacy markers stop being rare/inert (e.g. one is observed *blocking* a
  worktree root) → reconsider, but the correct direction remains *removing* the legacy reader on
  schedule (D3), not extending it with an auto-importer.
- **Item 5:** none — the drain UX is complete; the abspath key is settled (ADR-B).
