import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * #678 — the worker-side Codex nudge must gate on the STAGED INDEX only.
 *
 * `agents/pr-grinder.md` Step 6.5 fires the `@codex review` nudge on a wait-round.
 * "Wait-round" has exactly one canonical definition (ADR 0005): the dispatcher's
 * `RESULT_COMMIT_SHA == "none"`, which `scripts/dispatcher-commit-block.sh` derives
 * from `git diff --cached --quiet` on the `needs_more` branch and nothing else. That
 * script contains zero `git add` calls — it commits the index — so unstaged tracked
 * edits and untracked files can NEVER become a push.
 *
 * The guard originally tested a clean working TREE (three clauses: `git diff`,
 * `git diff --cached`, and `git ls-files --others --exclude-standard`). That is a
 * strict superset of the classifier, so it could only under-fire. The untracked
 * clause was the live bug: `ls-files --others` returns any untracked non-ignored
 * path, not only paths this round created, so a single long-lived untracked file
 * (`.claude/parked/` here) disables the nudge permanently and SILENTLY. The
 * worker-side site had never once fired in this repo.
 *
 * It matters because #673 established the nudge as the only exit once the Codex ack
 * tiers go sticky after round 1 — a suppressed nudge is a merge gate that dead-ends
 * at --max-wait. This test exists because the failure is invisible: nothing errors,
 * the worker just reports it didn't fire. A future "the guard should also check for
 * uncommitted work" edit would restore that silence, and prose alone would not object.
 */
describe('pr-grinder Step 6.5: wait-round guard predicate', () => {
  const agent = readFileSync(
    join(__dirname, '..', 'agents', 'pr-grinder.md'),
    'utf8',
  );

  // The guard is the `if` condition that leads into the codex-retrigger.sh call.
  // Anchor on the call so this keeps pointing at the right block if Step 6.5 moves.
  const guard = (): string => {
    const lines = agent.split('\n');
    const callIdx = lines.findIndex((l) => l.includes('codex-retrigger.sh') && l.includes('bash'));
    expect(callIdx, 'Step 6.5 codex-retrigger.sh invocation not found').toBeGreaterThan(-1);
    const openIdx = lines.slice(0, callIdx).map((l) => l.trimStart()).lastIndexOf('if git diff --cached --quiet 2>/dev/null \\');
    expect(
      openIdx,
      'guard must open with `if git diff --cached --quiet` — the dispatcher\'s own wait-round predicate',
    ).toBeGreaterThan(-1);
    return lines.slice(openIdx, callIdx).join('\n');
  };

  it('gates on the staged index, matching the dispatcher\'s classifier', () => {
    const text = guard();
    expect(text).toContain('git diff --cached --quiet');
    // Assert the guard contains exactly one Git worktree-state predicate — not
    // just that it lacks `ls-files`/bare `git diff`, but that it can never grow
    // a fourth clause (e.g. `git status --porcelain`) that reintroduces the
    // same silent-suppression bug via a different Git command.
    expect(text.match(/\bgit\s+[^&|;\n]+/g) ?? []).toHaveLength(1);
  });

  it('does NOT test untracked files (#678: repo debris silently kills the nudge)', () => {
    expect(guard()).not.toContain('ls-files');
  });

  it('does NOT test unstaged tracked changes (same class — never becomes a push)', () => {
    // `git diff --cached --quiet` legitimately contains "git diff", so strip the
    // staged clause before asserting the bare unstaged form is absent.
    expect(guard().replaceAll('git diff --cached --quiet', '')).not.toContain('git diff --quiet');
  });

  it('still requires Codex to be the SOLE stale ack', () => {
    // Guards the other half of the condition: the nudge must not fire while a
    // registered bot is also stale (that round is waiting on them, not on Codex).
    expect(guard()).toContain('$CODEX_ACK" = "stale"');
    expect(guard()).toContain("grep -q '=stale'");
  });

  it('the dispatcher commit block still commits the index alone (the premise)', () => {
    // If this ever fails, the guard's justification is gone: a `git add` in the
    // commit block would make unstaged/untracked files reachable by a push, and
    // the staged-index-only predicate would start under-reporting fix-rounds.
    const block = readFileSync(
      join(__dirname, '..', 'scripts', 'dispatcher-commit-block.sh'),
      'utf8',
    );
    expect(block).not.toMatch(/^\s*git add\b/m);
  });
});
