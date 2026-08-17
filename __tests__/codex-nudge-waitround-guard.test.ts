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

  /**
   * #683 — the premise check, and the fixtures proving it FIRES.
   *
   * The premise is that `dispatcher-commit-block.sh` commits the INDEX and
   * nothing else. Anything that writes the index here makes a non-staged change
   * reachable by a push, at which point the wait-round guard under-reports
   * fix-rounds and fires the nudge on a round that will actually push.
   *
   * The original check was `/^\s*git add\b/m`. The `^\s*` anchor only caught a
   * `git add` that BEGINS a line, so `cd "$REPO" && git add -A`, a `git add`
   * inside a function body, or one after `||`/`;` all passed while breaking the
   * premise — a check that cannot fire on the thing it exists to catch.
   *
   * DO NOT RE-ANCHOR, and do not narrow the extractor to "command position".
   * Both are the tempting wrong fix (#683 says so about the anchor explicitly).
   * If this ever trips on a mere mention of a git verb, make the check MORE
   * precise — the normalizer below already drops whole-line comments and the
   * commit check already ignores quoted prose; extend those.
   *
   * De-anchoring is necessary but nowhere near sufficient, and four successive
   * review rounds proved a regex cannot decide this at all: wrapper binaries
   * (`command git add`), shell keyword positions (`if git add …; then`), git
   * global options (`git -C "$R" add -A`), `git rm`/`git mv` (both write the
   * index — a staged deletion and a staged rename), `commit -a`/`--include`/
   * pathspec, comment-vs-continuation ordering, and `bash -c "git add -A"`
   * nesting. Every fix drew another counterexample. Deciding "does this shell
   * text write the index" is not a regex problem.
   *
   * So the real proof moved to where the shell can answer it:
   * `tests/test-dispatcher-commit-block.sh::test_q_index_only_premise` runs the
   * block in a sandbox holding a staged file, an unstaged tracked modification
   * and an untracked file, then asserts the resulting commit contains ONLY the
   * staged path. That is immune to every evasion above — verified by running it
   * against five doctored copies (plain, compound, wrapper, `bash -c` nested,
   * and `commit -a`), each of which it correctly fails.
   *
   * What survives HERE is a LINT: it catches a naive regression in-editor,
   * seconds after it is typed, instead of waiting on the shell suite. It is
   * deliberately NOT complete and must never be described as if it were. If you
   * find a form it misses, add a case to test_q — do not grow this back into a
   * parser, and do not re-anchor it.
   */

  const NON_COMMENT = (src: string): string =>
    src.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  // Unanchored on purpose — the anchor WAS the bug. Command position is NOT
  // required, so wrappers (`command git add`) and keyword positions (`if git
  // add`) are caught. The verb must be the SUBCOMMAND though: leading global
  // options are skipped (with `-c`/`-C` consuming their value), which keeps
  // `git -C "$r" ls-files --stage` — a real line in this script — from matching
  // on its `--stage` FLAG. `rm`/`mv` are included because both write the index.
  // Known-incomplete by design; see the docstring.
  const STAGES = /\bgit\b(?:\s+(?:-[cC]\s+\S+|-\S+))*\s+(?:add|stage|rm|mv)\b/;

  it('the lint fires on the forms the anchored regex waved through', () => {
    // A guard never observed failing is not a guard. These are cases the old
    // `/^\s*git add\b/m` missed; the lint catches them, and test_q catches these
    // plus the ones no regex can.
    for (const breach of [
      'cd "$REPO" && git add -A',
      'stage(){ git add .; }',
      'false || git add -u',
      'if git add -A; then :; fi',
      'command git add -A',
      'git -C "$R" add -A',
      'git rm tracked',
      'git mv old new',
      'git stage -A',
    ]) {
      expect(NON_COMMENT(breach), `lint should catch: ${breach}`).toMatch(STAGES);
    }
    expect(NON_COMMENT('  # we never git add here')).not.toMatch(STAGES);
    // The retired regex, proven blind — so the fix cannot be silently reverted.
    expect('cd "$REPO" && git add -A').not.toMatch(/^\s*git add\b/m);
  });

  it('the dispatcher commit block stages nothing (lint; test_q is the proof)', () => {
    const block = readFileSync(
      join(__dirname, '..', 'scripts', 'dispatcher-commit-block.sh'),
      'utf8',
    );
    expect(NON_COMMENT(block)).not.toMatch(STAGES);
  });
});
