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
  const hooks = readFileSync(
    join(__dirname, '..', 'hooks', 'hooks.json'),
    'utf8',
  );

  const NUDGE_SCRIPTS = ['codex-nudge-premerge.sh', 'codex-nudge-precreate.sh'];

  // Pull each nudge hook's full `env -i ... <script>` command out of the JSON.
  const commandsFor = (script: string): string[] =>
    hooks
      .split('\n')
      .filter((line) => line.includes('env -i') && line.includes(script));

  for (const script of NUDGE_SCRIPTS) {
    describe(script, () => {
      const commands = commandsFor(script);

      it('is registered with a sanitized env -i invocation', () => {
        expect(commands.length).toBeGreaterThan(0);
      });

      it('forwards the clamped MAX and COOLDOWN knobs so operator config reaches the hook path', () => {
        for (const cmd of commands) {
          expect(cmd).toContain('PR_GRIND_CODEX_RETRIGGER_MAX=');
          expect(cmd).toContain('PR_GRIND_CODEX_RETRIGGER_COOLDOWN=');
        }
      });

      it('does NOT forward the unclamped PHRASE knob (repo-settable comment body)', () => {
        for (const cmd of commands) {
          expect(cmd).not.toContain('PR_GRIND_CODEX_RETRIGGER_PHRASE');
        }
      });
    });
  }
});
