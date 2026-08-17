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
   * The check is an ALLOWLIST, not a blacklist, and that inversion is the whole
   * design. Three successive review rounds each found another way to smuggle a
   * staging command past a blacklist — `git rm`/`git mv` (both write the index:
   * a staged deletion and a staged rename respectively), wrappers (`command`,
   * `env`, `xargs`), shell keyword positions (`if`, `while`), unlisted global
   * options (`--no-optional-locks`), backslash continuations. Enumerating
   * dangerous forms cannot converge. Enumerating this script's ACTUAL git verbs
   * can: the set is small, it is the property we care about, and anything new
   * fails the test until a human looks at it.
   *
   * Extraction is deliberately over-broad — it ignores command position entirely
   * and skips ANY `-…` option — because for an allowlist, over-detection is a
   * false alarm (safe) while under-detection is the silent failure (unsafe).
   *
   * Adding a git verb here is not automatically wrong; it just has to be a
   * deliberate, reviewed act. Add it to ALLOWED_VERBS with a reason. The one
   * thing NOT to do is loosen the extractor.
   */

  // Read it the way bash does: join backslash-continuations FIRST, then drop
  // whole-line comments. The order is load-bearing — stripping comments first
  // lets `echo x \` + `# comment` + `git add -A` re-join into a single echo
  // command, hiding a real staging call from the matcher.
  const NORMALIZE = (src: string): string =>
    src
      .replace(/\\\n[ \t]*/g, ' ')
      .split('\n')
      .filter((l) => !/^\s*#/.test(l))
      .join('\n');

  // Every `git` occurrence → the first token that is not a global option.
  // `-c`/`-C` consume their separate value, so `git -c trailer.separators=':' log`
  // yields `log`, not `trailer`.
  const verbsOf = (src: string): Set<string> => {
    const out = new Set<string>();
    const re = /\bgit\b(?:[\s]+(?:-[cC][\s]+\S+|-[a-zA-Z-]+(?:=\S+)?))*[\s]+([a-z][a-z-]*)/g;
    for (const m of src.matchAll(re)) out.add(m[1]);
    return out;
  };

  // The verbs this script legitimately uses. All of them read state or write
  // history; none stages working-tree content.
  const ALLOWED_VERBS = new Set([
    'status', 'diff', 'push', 'commit', 'ls-files', 'rev-parse', 'rev-list', 'log', 'reset',
  ]);

  // `commit` is allowlisted but not self-evidently safe: `-a`/`--all`,
  // `-i`/`--include`, `-o`/`--only` and a bare pathspec all read the WORKING
  // TREE instead of the index. So its operands are pinned to the one legal form.
  // A `git commit` sitting inside a double-quoted string (an error message) is
  // skipped via an odd-quote-count test on the line prefix.
  const REDIR = /(?:\d*>>?&?\s*\S+|<\s*\S+)/g;
  const ALLOWED_COMMIT_OPERANDS = '-F -';
  const badCommits = (src: string): string[] => {
    const out: string[] = [];
    for (const line of src.split('\n')) {
      const re = /\bgit\b(?:[\s]+(?:-[cC][\s]+\S+|-[a-zA-Z-]+(?:=\S+)?))*[\s]+commit\b(.*)$/g;
      for (const m of line.matchAll(re)) {
        if (((line.slice(0, m.index).match(/"/g) ?? []).length % 2) === 1) continue;
        const ops = m[1].replace(REDIR, '').replace(/\s+/g, ' ').trim();
        if (ops !== ALLOWED_COMMIT_OPERANDS) out.push(line.trim());
      }
    }
    return out;
  };

  const breaches = (src: string): string[] => {
    const n = NORMALIZE(src);
    return [
      ...[...verbsOf(n)].filter((v) => !ALLOWED_VERBS.has(v)).map((v) => `git ${v}`),
      ...badCommits(n),
    ];
  };

  it('the premise check actually fires (both outcomes)', () => {
    // A guard that has never been observed failing is not a guard. Every entry
    // below writes the index, and every one was invisible to the old anchored
    // regex `/^\s*git add\b/m`.
    for (const breach of [
      'cd "$REPO" && git add -A',
      'stage(){ git add .; }',
      'false || git add -u',
      'if git add -A; then :; fi',        // keyword command position
      'while git rm tracked; do :; done', // `git rm` stages a deletion
      'command git add -A',               // wrapper
      'env FOO=1 git add -A',
      'echo f | xargs git add',
      'git mv old new',                   // stages a rename
      'git stage -A',
      'git -C "$R" add -A',               // global option before the subcommand
      'git --no-optional-locks add -A',   // option no blacklist would have listed
      'git \\\n  add -A',                 // backslash-continued
      'echo x \\\n# c\ngit add -A',       // continuation/comment interaction
    ]) {
      expect(breaches(breach), `should catch: ${JSON.stringify(breach)}`).not.toHaveLength(0);
    }
    for (const breach of [
      '| git commit -am wip',
      '| git commit --all -F -',
      '| git commit --include tracked.txt -F -',
      '| git commit -o tracked.txt -F -',
      '| git commit tracked.txt -F -',    // bare pathspec bypasses the index
      '| git -C "$R" commit -a',
    ]) {
      expect(breaches(breach), `should catch: ${breach}`).not.toHaveLength(0);
    }
    // ...and stay silent on the legal forms, a comment, and quoted prose.
    expect(breaches('printf x | git commit -F - >/dev/null 2>&1')).toEqual([]);
    expect(breaches('  # we never git add here')).toEqual([]);
    expect(breaches('emit_bail "judgment" "git commit failed (exit $E)"')).toEqual([]);
    expect(breaches("git -c trailer.separators=':' log -1")).toEqual([]);
    // The old anchored regex is what this test exists to retire — prove it was
    // blind to the compound form, so the fix can never be silently reverted.
    expect('cd "$REPO" && git add -A').not.toMatch(/^\s*git add\b/m);
  });

  it('the dispatcher commit block still commits the index alone (the premise)', () => {
    // If this ever fails, the guard's justification is gone: anything that writes
    // the index here makes unstaged/untracked files reachable by a push, and the
    // staged-index-only predicate starts under-reporting fix-rounds.
    const block = readFileSync(
      join(__dirname, '..', 'scripts', 'dispatcher-commit-block.sh'),
      'utf8',
    );
    expect(breaches(block)).toEqual([]);
  });
});
