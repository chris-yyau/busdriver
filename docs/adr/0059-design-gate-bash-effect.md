# ADR 0059 — Arm the design-review gate on a Bash call's effect

**Status:** Accepted (2026-10-23 — #921)
**Date:** 2026-10-23
**Amends:** `docs/specs/2026-10-22-issue-921-design-gate-bash-effect-design.md` (the
reviewed spec; the sections named below are superseded by this ADR)
**Related:** ADR 0017 / ADR 0031 (repo-wide block scope), ADR 0021 (Bash write
resolution is cooperative, not adversarial), #347 / #449 (a write re-opens review)

## Context

`check-design-document.sh` armed a design-review token for a Bash write only when the
command text named the doc in a redirect, `tee` or `cp`/`mv`. A script, `sed -i`,
`git checkout <ref> --`, or a destination spelled through a variable changed a design doc
with no token armed (chrisyau.me PR #406). The spec above designed the fix and passed
blueprint-review (FULL 3/3, iteration 5 of 6). Implementation and its litmus review then
found places where the spec was weaker than it needed to be. The spec is committed as
reviewed, PASS marker intact: editing it would downgrade that PASS and arm a repo-wide
token for every worktree until another review round ran, with one round left under the
ceiling. This ADR records where the code deliberately differs.

## Decision

Implement the spec (a PreToolUse snapshot of each repository's dirty design docs, a post
comparison that arms what the call changed and is not committed at HEAD or a revision
being brought in, per-doc work through the shared `marker_ops` functions, the redirect
parser kept). Where the code differs from the spec, it differs toward arming more or
running less:

1. **Marker lines** (spec "Body hash"). Only a line holding nothing but the marker is left
   out of the hash: the comment may not contain another `<!--` or `-->`, and nothing but
   blanks may follow its `-->`. A coverage line may still be truncated (no `-->`), the shape
   the review loop repairs. The spec's `.*` rules let text added after a marker, or a second
   comment on a marker line, change a doc without arming it.
2. **Ignored docs** (spec "Non-goals", "Residuals"). Gitignored docs inside a `plans/` or
   `specs/` directory (`docs/**/plans`, `<STATE_DIR>/**/specs`, …) are listed with
   `git ls-files --others --ignored` and compared like any other. Ignored files matched only
   by basename (`plan*.md`) stay out: blueprint-review's own run rewrites the ignored
   `.claude/ultra-oracle/plan-consult-verdict.md`, and covering it would arm a token every
   review round that the PASS never prunes. A failed ignored listing only warns.
3. **Deadline** (spec "Deadline", "Error handling", "Residuals: Deadline overrun"). Nothing
   discovered is dropped. A doc whose hashing the deadline cuts off, before or after the
   call, keeps an `unhashed:` sentinel and is armed after the call; candidates still waiting
   when the deadline passes are armed without the classifier and without a PASS downgrade
   (the string exclusions still apply). A post-call `git status` failure re-hashes the docs
   the snapshot holds and arms any that changed, without a downgrade; a doc the call newly
   created in that root stays unseen, which remains the "Uncompared roots" residual.
   A doc larger than 4 MiB is not normalized: its raw bytes are hashed in 1 MiB chunks
   under the deadline, so memory stays bounded and any byte change arms without a
   downgrade, and a blob that large is never fetched from a revision; a revision read
   whose blobs total more than 16 MiB is not fetched either. A revision lookup
   that fails for any reason other than "no such revision" (rev-parse exit 1) counts as a
   failed revision read; a failed pre-call HEAD lookup keeps the root compared, and a doc
   the call newly dirtied there arms without a downgrade. A cat-file `missing` record for
   a blob ls-tree listed is a failed revision read too, not "that path is absent" as the
   spec says: the path exists at that revision and only its object is unreadable. In the
   status-failure fallback a doc made unreadable arms; only a deleted one counts as gone.
   That fallback re-hashes a doc past 4 MiB to the same chunked `bighash:` the snapshot
   stored, so an untouched one does not arm; once the budget is spent it arms unread.
   A payload whose `cwd` is missing or not absolute (the spec assumes an absolute one)
   compares the hook process cwd's repository instead, with a warning.
   Each root's marker dir is looked up in the PreToolUse half, after every root's dirty
   set and under its deadline, and recorded in the snapshot, so the post-call half starts
   no git child before its comparison. The recorded one is used only while it matches the
   common dir the filesystem now shows (`.git`, or gitfile → gitdir → `commondir`), since
   the call may have moved or retargeted the git dir. Otherwise the root is looked up
   there first, with no deadline, and that lookup can still spend the comparison's budget.
   Every doc, gitfile and `commondir` read opens non-blocking and refuses anything but a
   regular file, since a call can leave a FIFO there and a blocking open outlives every
   deadline: such a doc arms as unreadable and such a git file reruns the lookup.
   The token is armed before the PASS downgrade and the PASS probe, so a failure in
   either (both read the whole doc) cannot cost it.
4. **Pre-approval execution** (spec "Snapshot set"). The PreToolUse half runs before the
   Bash call is approved, including in a repository the command only `cd`s into. Every git
   call runs with `-c core.fsmonitor=false`, `GIT_ALLOW_PROTOCOL` naming no protocol and
   `GIT_NO_LAZY_FETCH=1`, so neither an fsmonitor hook nor a lazy fetch through a
   repo-configured transport can start (a `-c protocol.allow=never` default was measured to
   lose to a repository's own `protocol.ssh.allow=always`). `git status` ignores submodules.
   A `cd` target whose config names a clean/process filter is not compared, since `status`
   can run a clean filter on a stat-dirty file; the session repository keeps the trust every
   other gate gives its own config.
5. **Registration counts.** The two new registrations move `EXPECTED_CONTAINED` to 22 and
   `EXPECTED_EXEC_FORM` to 20 as the spec says, and also the matching pins the spec did not
   list: the exec-form population in `__tests__/codex-nudge-env-allowlist.test.ts` and
   `tests/test-hook-exec-form-713.sh` (18 → 20) and the sanitized-gate population in
   `tests/test-passwd-home-trusted-path.sh` (11 → 13).

## Alternatives

- **Edit the spec to match.** Rejected for this PR: it downgrades the reviewed PASS and arms
  a repo-wide token across worktrees other sessions are writing in, for a review round whose
  only input is "the code is stricter than the text".
- **Cover every ignored design-pattern file.** Rejected: it arms blueprint-review's own
  oracle output on every review round.
- **Deny-list risky git config for `cd` targets** (partial clone, promisor keys). Tried and
  dropped: each round found another key (`remote.<name>.partialclonefilter` alone creates a
  promisor). `GIT_ALLOW_PROTOCOL` closes the transport class whatever the config says.

## Consequences

- More Bash calls arm than the spec describes: ignored plans/specs docs, deadline overruns,
  and text added on a marker line. Each is the over-arm direction ADR 0017 accepts.
- A cd'd-into repository with a filter driver is not compared; the session repository still
  is, under the same trust as every other gate.
- The suppression residuals stand: a deliberate actor can rewrite its own snapshot or plant
  a `MERGE_HEAD` (ADR 0021).

## Revisit trigger

The next edit of the spec for any other reason should fold these five points into it and
retire this ADR's "Amends" line.
