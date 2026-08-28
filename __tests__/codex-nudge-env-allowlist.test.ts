import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * #673 / PR #676 — what the codex-nudge hooks may forward through `env -i`.
 *
 * `env -i` in hooks.json is ADR 0016's (#325) deny-by-default boundary: gate env is
 * wiped and each variable must be named explicitly to survive. That list is therefore
 * a security decision, not plumbing. A committed `.claude/settings.json` `env` block
 * is repo-controlled and CAN set any of these in the ambient session, so every name
 * added here is a value a hostile repo gets to choose.
 *
 * PR #676 added the bounded-retry knobs and Codex correctly flagged that they never
 * reached the real pre-merge / pre-create paths. Two of the three are safe to forward
 * because `codex-retrigger.sh` clamps them to a range (MAX to [1,10], COOLDOWN to
 * [0,86400]) — the worst a hostile value can do is a bounded number of extra nudges,
 * or disable nudging, which is already an operator-visible outcome.
 *
 * PR_GRIND_CODEX_RETRIGGER_PHRASE is deliberately NOT forwarded. It is unclamped and
 * becomes the BODY of a comment posted with the operator's `gh` credentials — and that
 * body is read by the AI reviewer whose ack gates the merge. Repo-controlled text →
 * operator credentials → an LLM reviewer's input is exactly the shape the repo's own
 * rule refuses ("authenticate consent by location, not by content"). An operator who
 * genuinely runs a connector with a different trigger phrase should get a `.local`
 * file, not an env var a repo can set.
 *
 * This test exists because that reasoning is invisible in the JSON. Without it, the
 * next person fixing "the phrase override doesn't work in hooks" re-adds the name and
 * nothing objects.
 */
describe('codex-nudge hooks: env -i allowlist', () => {
  const hooks = JSON.parse(
    readFileSync(join(__dirname, '..', 'hooks', 'hooks.json'), 'utf8'),
  );

  const NUDGE_SCRIPTS = ['codex-nudge-premerge.sh', 'codex-nudge-precreate.sh'];

  // #713: registrations are exec form (`command` + `args`), so `env -i` and the script
  // basename now sit on DIFFERENT JSON lines. The old single-line filter matched nothing
  // and this suite would have gone vacuous — passing while checking nothing — which is
  // precisely the failure mode the negative pin below exists to prevent. Walk the
  // document structurally and join each registration's full argv instead.
  const argvs: string[] = [];
  (function walk(node: unknown): void {
    if (Array.isArray(node)) { node.forEach(walk); return; }
    if (node && typeof node === 'object') {
      const o = node as Record<string, unknown>;
      if (typeof o.command === 'string') {
        argvs.push([o.command, ...(Array.isArray(o.args) ? (o.args as string[]) : [])].join(' '));
      }
      Object.values(o).forEach(walk);
    }
  })(hooks);

  const commandsFor = (script: string): string[] =>
    argvs.filter((a) => a.includes('/usr/bin/env') && a.includes(script));

  for (const script of NUDGE_SCRIPTS) {
    describe(script, () => {
      const commands = commandsFor(script);

      it('is registered with a sanitized env -i invocation', () => {
        expect(commands.length).toBeGreaterThan(0);
      });

      // #713 / ADR 0049: these two registrations are the ONLY ones deliberately left in
      // shell form. Exec form substitutes only documented PATH placeholders, so a
      // `${PR_GRIND_CODEX_RETRIGGER:-}` capture cannot be transcribed into an argv element
      // — it would ship as a literal string — and `env -i` would then strip the real value.
      // That matters here and nowhere else: this hook runs its delegate
      // (codex-nudge-if-expected.sh -> codex-retrigger.sh) as a CHILD of the `env -i`
      // process, so under exec form the delegate reads the switch as unset too and
      // `PR_GRIND_CODEX_RETRIGGER=0` would stop suppressing an OUTBOUND `gh pr comment`.
      // Both nudges are non-gating, so leaving them in shell form costs only the #713
      // SHELLOPTS hardening on a nudge, never on a gate. Keeping the forwarding asserted
      // is what stops a future "migrate the last two" edit from silently re-enabling the
      // comments.
      it('still forwards the clamped RETRIGGER knobs (shell form — ADR 0049)', () => {
        for (const cmd of commands) {
          expect(cmd).toContain('PR_GRIND_CODEX_RETRIGGER="${PR_GRIND_CODEX_RETRIGGER:-}"');
          expect(cmd).toContain('PR_GRIND_CODEX_RETRIGGER_MAX="${PR_GRIND_CODEX_RETRIGGER_MAX:-}"');
          expect(cmd).toContain('PR_GRIND_CODEX_RETRIGGER_COOLDOWN="${PR_GRIND_CODEX_RETRIGGER_COOLDOWN:-}"');
        }
      });

      it('does NOT forward the unclamped PHRASE knob (repo-settable comment body)', () => {
        for (const cmd of commands) {
          expect(cmd).not.toContain('PR_GRIND_CODEX_RETRIGGER_PHRASE');
        }
      });
    });
  }

  // The other half of the #713 split. Every EXEC-FORM contained registration lost the
  // knobs (they cannot be transcribed), so none may carry one — including the pre-merge
  // GATE, whose read-only missing-Codex advisory consequently no longer honours the kill
  // switch (named residual R9, ADR 0049 / #777; it posts nothing, so no outbound effect).
  // Asserted as its own population: without it, "no exec-form row forwards a knob" would
  // be satisfied just as well by there being no exec-form rows at all.
  describe('exec-form contained gates', () => {
    // #713: the first hop is contained-launch.sh, which supplies `env -i` itself — naming
    // bare /usr/bin/env as `command` was residual R7. The disposition is its first argument.
    const execArgvs = argvs.filter(
      (a) => /^\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/gate-scripts\/lib\/contained-launch\.sh (closed|open) PATH=\/usr\/bin:\/bin /.test(a)
        && (a.includes('sanitized-gate.sh') || a.includes('sanitized-node.sh'))
        && !NUDGE_SCRIPTS.some((n) => a.includes(n)),
    );

    it('are the expected population (17 — the two nudges excluded)', () => {
      expect(execArgvs).toHaveLength(17);
    });

    it('forward NO PR_GRIND_* knob', () => {
      for (const cmd of execArgvs) {
        expect(cmd).not.toContain('PR_GRIND_CODEX_RETRIGGER');
      }
    });
  });
});
