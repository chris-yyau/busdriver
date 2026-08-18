#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # assertions intentionally use command substitution
# shellcheck disable=SC2015  # `ok` always returns 0, so A && ok || fail is a real if-then-else here
# shellcheck disable=SC2016  # golden-grep patterns intentionally contain literal $
# tests/test-pi-dispatch-arm.sh — guard for the dispatch.sh `pi` read lane.
#
# The pi arm is the ONE dispatch lane that runs inside the working tree (every
# other read-only lane is confined to an empty dir). That is the feature — it
# traces real code — but it inverts the isolation problem: the repo is on the
# INSIDE, so the containment is entirely carried by two things, and both are
# silent when they break.
#
#   1. A POSITIVE tool allowlist. `--exclude-tools edit,write` reads as
#      "read-only" and is not: pi's built-in `bash` survives it and can write,
#      run git, and reach the network. Probed on pi 0.84.1, the unrestricted
#      surface also carried a second shell (`hypa_shell`), web fetch/search
#      (`exa_*`) and a `subagent` spawner. A denylist cannot enumerate that,
#      and it grows with every extension the operator installs. Regressing
#      `--tools read` back to a denylist is therefore a silent fail-OPEN, which
#      is exactly the shape this file exists to catch.
#   2. The six `--no-*` flags. They cut the surface to the built-ins before the
#      allowlist applies, and `--no-approve` is what stops the repo under
#      audit from redefining the auditor through its own project-local config.
#
#   3. Plus the model key: `.pi.model` names the third party that repo source
#      is shipped to, so it carries the auditor key's trust rules verbatim —
#      USER config only, trusted $HOME, invalid degrades rather than dies.
#
# The live in-tree containment checks need a model call, so they are opt-in via
# BUSDRIVER_PI_LIVE=1 and SKIP by default rather than making CI network-bound.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
DISPATCH="$ROOT/skills/dispatch-cli/scripts/dispatch.sh"

passed=0; failed=0; skipped=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
skip() { echo "SKIP: $1"; skipped=$((skipped + 1)); }
eq()   { if [[ "$1" == "$2" ]]; then ok "$3 → $1"; else fail "$3 → got '$1', want '$2'"; fi }

for f in "$LIB" "$DISPATCH"; do
  [[ -f "$f" ]] || { fail "missing $f"; echo "Results: $passed passed, $failed failed"; exit 1; }
done

# ── Fixture cleanup, armed ONCE and up front ────────────────────
# The projection test below copies a REAL API credential into a temp jail, and it
# runs before any later fixture setup — so the trap has to exist now, not when
# those fixtures appear. Variables are read at trap time via ${VAR:-}, so one
# handler covers every fixture whether or not it was created.
# Paths are shape-checked before deletion for the same reason the production arm
# does it: `mktemp` is shadowable, and these handlers delete recursively.
_wipe_fixtures() {
  local p
  for p in "${_j:-}" "${_j2:-}" "${FIX:-}"; do
    [[ -n "$p" && "$p" == /* && "$p" != "/" && -d "$p" ]] && /bin/rm -rf "$p" 2>/dev/null
  done
  # FAKE_HOME now holds synthetic auth fixtures and several jail directories, so
  # rmdir cannot clear it. Recursive removal is justified by the same reasoning
  # the production arm uses: this path was validated absolute, non-symlink and
  # EMPTY before anything was written into it, so it is ours.
  if [[ -n "${FAKE_HOME:-}" && "$FAKE_HOME" == /* && "$FAKE_HOME" != "/" && -d "$FAKE_HOME" ]]; then
    /bin/rm -rf "$FAKE_HOME" 2>/dev/null
  fi
  return 0
}
trap '_wipe_fixtures' EXIT INT TERM HUP

# Created UP FRONT: the projection test writes its synthetic fixtures here and
# runs well before the resolver section that used to own this directory.
#
# Named the same way the production arm names its jail, and for the same reason:
# the EXIT handler removes this path RECURSIVELY, and `mktemp` is a shadowable
# command word — an exported function could return an existing empty directory
# that passes every check and then gets rm -rf'd. `$$` and `$RANDOM` are shell
# builtins, so the name cannot be steered; `mkdir` without -p then fails if the
# path somehow exists, which is what makes it ours.
_t="${TMPDIR:-/tmp}"; [[ "$_t" == /* ]] || _t="/tmp"
FAKE_HOME="${_t%/}/busdriver-pitest-$$-${RANDOM}${RANDOM}"
if [[ -e "$FAKE_HOME" ]] || ! mkdir "$FAKE_HOME" 2>/dev/null; then
  fail "could not create a fresh private fixture directory — refusing to write or delete fixtures"
  echo "Results: $passed passed, $failed failed"; exit 1
fi

# ── The arm's text, sliced out once ─────────────────────────────
ARM_RAW="$(awk '/^        pi\)$/{f=1} f{print} f && /^        grok\)$/{exit}' "$DISPATCH")"
[[ -n "$ARM_RAW" ]] || { fail "could not locate the pi) arm in dispatch.sh"; echo "Results: $passed passed, $failed failed"; exit 1; }
# Assertions run against CODE ONLY. The arm's comments necessarily quote the
# banned shapes (they explain why `--exclude-tools` is a fail-open denylist), so
# a comment-inclusive grep both false-FAILS the negative checks and false-PASSES
# the positive ones — a flag named only in prose would satisfy them.
ARM="$(grep -vE '^[[:space:]]*#' <<<"$ARM_RAW")"

# ── 1. Positive allowlist, and no denylist shape anywhere ───────
grep -qE -- '--tools read' <<<"$ARM" \
  && ok "pi arm pins a positive tool allowlist (--tools read)" \
  || fail "pi arm no longer pins --tools read — the lane is only read-only by virtue of this flag"

if grep -qE -- '--exclude-tools' <<<"$ARM"; then
  fail "pi arm uses --exclude-tools (denylist) — pi's built-in bash survives it; this is a fail-OPEN read lane"
else
  ok "pi arm carries no --exclude-tools denylist"
fi

# ── 2. Every project-config surface is switched off by name ─────
for flag in --no-approve --no-context-files --no-skills --no-extensions --no-prompt-templates --no-themes --no-session; do
  grep -qE -- "$flag" <<<"$ARM" \
    && ok "pi arm passes $flag" \
    || fail "pi arm dropped $flag — the audited repo can reload that surface"
done

# ── 2b. The child must NOT receive the operator's real HOME ─────
# `--tools read` stops writes, not reads: pi reads absolute paths, and with the
# real $HOME it can reach ~/.ssh, ~/.aws and every provider credential in
# ~/.pi/agent/auth.json (demonstrated). The child gets a private HOME carrying
# only the selected provider's entry.
grep -qE 'env -i HOME="\$_pi_jail"' <<<"$ARM" \
  && ok "pi child runs under the projected private HOME" \
  || fail "pi child no longer runs under \$_pi_jail — the operator's whole credential store is one read away"

# `_pi_available` runs during `--cli all` selection, in the INHERITED shell and
# BEFORE the pi arm's own sterile preflight. It resolves the operator's home by
# tilde expansion, which needs `eval` — a builtin an exported `BASH_FUNC_eval%%`
# overrides — so doing that work here would hand arbitrary execution to the
# environment at CLI-selection time. Username validation is no defence: the
# shadow intercepts the call whatever its argument. The probe therefore lives
# inside an `env -i` child (verified: the child's `eval` resolves to `builtin`
# even with an exported shadow). This assertion scans the WHOLE file, not $ARM —
# the function is defined above the `pi)` arm.
_AVAIL_FN="$(awk '/^_pi_available\(\) \{$/{inb=1} inb{print} inb && /^\}$/{exit}' "$DISPATCH" \
             | grep -vE '^[[:space:]]*#')"
if [[ -z "$_AVAIL_FN" ]]; then
  fail "could not extract _pi_available — this assertion is not running"
elif ! grep -qF '/usr/bin/env -i' <<<"$_AVAIL_FN"; then
  fail "_pi_available does not run its probe in a sterile env -i child"
elif grep -nE '(^|[;&|]|then|do)[[:space:]]*eval[[:space:]]' <<<"$(awk '/<<.CHILD./{inh=1; next} inh && /^CHILD$/{inh=0; next} !inh' <<<"$_AVAIL_FN")" >/dev/null; then
  fail "_pi_available calls eval in the INHERITED shell — an exported eval function executes during --cli all"
else
  ok "_pi_available resolves the home dir inside a sterile child (eval cannot be shadowed there)"
fi

# SELECTION MUST NOT RE-IMPLEMENT THE PREFLIGHT. `_pi_available` answers "could
# pi plausibly run here", not "will the preflight accept it". A version probe was
# duplicated here on PR #591 and removed: bounding the copy needed a capture file,
# a race-free name and a size cap, and the size cap reintroduced the very
# divergence the copy existed to close — a truncated version string can match in
# one place and not the other. One probe, in the preflight, is the invariant.
if grep -qF 'PI_PROBED_VERSION' <<<"$_AVAIL_FN"; then
  fail "_pi_available re-implements the preflight's version check — the two WILL diverge; let the preflight decide"
else
  ok "selection is a path check only; the preflight is the single authority on eligibility"
fi

# The version gate must judge on the probe's EXIT STATUS, not stdout alone: a pi
# that prints the pinned version and then exits nonzero has a broken `--version`
# and has not answered the question. Asserted STATICALLY, against the production
# lines. An earlier attempt here replayed the logic against fake binaries inside
# the test — which proved nothing, because it would have passed unchanged if
# production reverted to `|| true`. A test that re-implements the code under test
# is not a behavioural test; it is a second implementation with no assertion
# between them.
if grep -qE '_pi_ver="\$\(.*--version 2>/dev/null\)" \|\| true' "$DISPATCH"; then
  fail "version probe discards its exit status (|| true) — matching stdout from a FAILING --version passes the gate"
elif ! grep -qF '[[ "$_pi_ver_rc" -eq 0 ]] || _pi_ver=""' "$DISPATCH"; then
  fail "version probe does not blank _pi_ver on a nonzero exit — a broken --version can satisfy the pin"
else
  ok "version gate requires a clean --version exit, not just matching output"
fi

# The dispatch invocation must use the ABSOLUTE /usr/bin/env, like every other
# sterile-child escape in this arm — a bare `env` command word is a shell
# command word an exported function can shadow, which would defeat the HOME
# jail and PATH scrub this whole arm exists to enforce.
grep -qE '/usr/bin/env -i HOME="\$_pi_jail"' <<<"$ARM" \
  && ok "pi dispatch invocation uses the unshadowable /usr/bin/env" \
  || fail "pi dispatch invocation uses a bare 'env' — an exported env function could intercept the HOME jail"

if grep -qE 'env -i HOME="\$_pi_home"' <<<"$ARM"; then
  fail "pi child receives the operator's REAL home — credential projection bypassed"
else
  ok "pi child does not receive the operator's real home"
fi

# _pi_wipe MUST CLEAR THE JAIL NAME once removal is confirmed, and only then.
# Every step in it is gated on the name being non-empty, so clearing is what makes
# a second call a no-op. A boolean latch could not do this: set before the work, a
# signal in the gap turned the handler's `_pi_wipe` into a no-op and abandoned
# cleanup with a live credential; set after, the zeroing stayed unguarded, where a
# recreated path — a symlink at ANY component, not just the final one — would have
# `>|` truncate an unrelated file. Narrowing trap windows never terminated.
_clear_at="$(grep -nE '^[[:space:]]*_pi_jail=""$' <<<"$ARM" | head -1 | cut -d: -f1)"
_unlink_at="$(grep -nF '/usr/bin/env -i /bin/bash --noprofile --norc -s "$_pi_jail"' <<<"$ARM" | head -1 | cut -d: -f1)"
if [[ -z "$_clear_at" ]]; then
  fail "_pi_wipe never clears _pi_jail — a second call re-uses a freed pathname to truncate and delete"
elif [[ -z "$_unlink_at" || "$_clear_at" -lt "$_unlink_at" ]]; then
  fail "the name is cleared before removal is confirmed — a failed wipe becomes unretryable and reports success"
elif grep -qE '_pi_jail[^=]*-eq' <<<"$ARM"; then
  fail "jail state is compared with -eq — arithmetic evaluation expands \$(...) from an inherited value"
elif ! grep -qF '[[ -f "$_pi_jail/.pi/agent/auth.json" && ! -L "$_pi_jail/.pi/agent/auth.json" ]]' <<<"$ARM"; then
  fail "the zeroing step does not refuse symlinks — >| follows one and truncates an unrelated file"
else
  ok "_pi_wipe clears the jail name only once removal is confirmed (no freed pathname left to reuse)"
fi

# EXACTLY ONE CLEANUP OWNER, continuously armed: the parent. A trap in each shell
# means a process-group signal fires both, and the parent's delete lands after the
# subshell already freed the pathname. Disarming the parent first instead opens a
# gap in which a signal exits with no owner at all and the credential on disk.
_wipe_traps="$(grep -cE "trap '[^']*_pi_wipe" <<<"$ARM" || true)"
if [[ "$_wipe_traps" -ne 1 ]]; then
  fail "$_wipe_traps traps call _pi_wipe — one continuously-armed owner is the only shape without a double-delete or a gap"
elif ! grep -qE "trap '_pi_wipe; rm -f \"\\\$PROMPT_FILE\" 2>/dev/null; exit 130' INT TERM HUP" <<<"$ARM"; then
  fail "the single wipe trap is not the parent's signal handler — the dispatch window is uncovered"
else
  ok "exactly one continuously-armed cleanup owner (the parent signal trap)"
fi

# The normal (unsignalled) path still has to tear down, since the trap only fires
# on a signal. Read the lines AFTER the subshell closes — an earlier version of
# this check stopped ON the `exit_code=$?` line and so could never see the code it
# was meant to inspect, which made it assert nothing.
_disp_tail="$(awk '/exit_code=\$\?$/{f=1; next} f' <<<"$ARM" | head -20)"
if [[ -z "$_disp_tail" ]]; then
  fail "could not read past the dispatch subshell — this assertion is not running"
elif ! grep -qE '^\s*_pi_wipe\s*$' <<<"$_disp_tail"; then
  fail "nothing tears the jail down on the normal path — the trap only covers signals"
else
  ok "the normal dispatch path tears the jail down explicitly"
fi

# Teardown is verified by LOOKING at the jail, not by a reserved exit code that
# pi or the timeout wrapper could return on their own.
grep -qE 'if \[\[ -e "\$_pi_jail" \|\| -L "\$_pi_jail" \]\]; then' <<<"$_disp_tail" \
  && ok "a surviving jail is detected directly and fails the dispatch" \
  || fail "teardown failure is not verified after dispatch — a live credential can survive silently"

# The signal trap authorises `rm -rf` on a path guarded only by "absolute and not
# /", so it must not be armed until `_pi_mkjail` has observed the jail into
# existence. It therefore lives INSIDE _pi_project (which runs only on that
# branch) and nowhere at the arm's top level. Checked by containment, not by line
# order — _pi_project is DEFINED above the chain but RUNS after it.
_projfn="$(awk '/_pi_project\(\) \{/{inb=1} inb{print} inb && /^                    \}$/{exit}' <<<"$ARM")"
_trap_total="$(grep -c "trap '_pi_wipe; rm -f" <<<"$ARM" || true)"
_trap_in_fn="$(grep -c "trap '_pi_wipe; rm -f" <<<"$_projfn" || true)"
if [[ "$_trap_in_fn" -ne 1 ]]; then
  fail "the rm -rf-authorising signal trap is not armed inside _pi_project — creation may not yet be observed"
elif [[ "$_trap_total" -ne 1 ]]; then
  fail "that signal trap is armed in $_trap_total places — one of them precedes the ownership proof"
else
  ok "signal trap is armed only after jail creation is observed"
fi

# _pi_wipe runs back in the INHERITED shell, so every command word in it is
# shadowable by an exported function — and it is the one function that must
# still work when an injection has already landed. Absolute paths are the only
# defence that holds (a function name cannot contain `/`). This asserts the
# doctrine mechanically instead of trusting the comment above it: no bare
# command word in command position anywhere in the body.
WIPE_ALL="$(awk '/^[[:space:]]*_pi_wipe\(\) \{$/{inb=1} inb{print} inb && /^[[:space:]]*\}$/{exit}' <<<"$ARM_RAW" \
            | grep -vE '^[[:space:]]*#')"
# The heredoc body is EXEMPT from the bare-command rule and only from it: it runs
# inside `env -i`, where the function table is empty, so a bare `rm` there is
# genuinely `rm`. Split it off rather than exempting the whole function — the
# parent-side lines must still obey the rule.
WIPE_BODY="$(awk '/<<.CHILD./{inh=1; next} inh && /^CHILD$/{inh=0; next} !inh' <<<"$WIPE_ALL")"
WIPE_CHILD="$(awk '/<<.CHILD./{inh=1; next} inh && /^CHILD$/{exit} inh' <<<"$WIPE_ALL")"

if [[ -z "$WIPE_CHILD" ]] || ! grep -qE '/usr/bin/env -i /bin/bash --noprofile --norc' <<<"$WIPE_ALL"; then
  fail "_pi_wipe does not remove the jail inside a sterile env -i child — a hostile function table reaches the removal"
elif ! grep -qE '^if \[ -e "\$d" \] \|\| \[ -L "\$d" \]; then exit 1; fi$' <<<"$WIPE_CHILD"; then
  fail "the wipe child verifies with -e alone — a dangling symlink survives and still reports success"
else
  ok "_pi_wipe removes the jail in a sterile env -i child and verifies symlink-aware"
fi

# THE STEP THAT TERMINATES THE SHADOWING REGRESS. Every command word in this
# function is shadowable by something (see the arm's comment); a bare redirection
# is not a command, so nothing can intercept it. It must come FIRST — after the
# unlink it would be pointless, and the unlink is the step that can be subverted.
# `>|` not `>` so `set -C` cannot refuse it. Verified live: with rm, echo and
# printf all shadowed, `>| f` still took the credential from 32 bytes to 0.
if ! grep -qE '^\s*&& ! >\| "\$_pi_jail/\.pi/agent/auth\.json"; then$' <<<"$WIPE_ALL"; then
  fail "credential is not zeroed by a bare redirection — every removal path left is command-shadowable"
elif [[ "$(grep -n '>|' <<<"$WIPE_ALL" | head -1 | cut -d: -f1)" -gt "$(grep -n 'usr/bin/env -i' <<<"$WIPE_ALL" | head -1 | cut -d: -f1)" ]]; then
  fail "the bare-redirection zeroing runs AFTER the unlink child — a subverted unlink then leaves a live credential"
else
  ok "credential is zeroed by unshadowable grammar (>|) before any command runs"
fi

if [[ -z "$WIPE_BODY" ]]; then
  fail "could not extract the _pi_wipe body — this assertion is not running"
elif grep -qE '(^|\||&&|;|then|else|do)[[:space:]]*(rm|echo|printf|mktemp|rmdir|command|builtin|eval)[[:space:]]' <<<"$WIPE_BODY"; then
  fail "_pi_wipe uses a bare command word — an exported function shadows it inside the cleanup path"
else
  ok "_pi_wipe uses only absolute-path commands (unshadowable)"
fi

# BUILTINS ARE NOT SAFE EITHER, which is the trap the absolute-path rule above
# does not cover on its own. Verified against bash 5.3 and 3.2: `export -f return`
# is accepted, the child imports BASH_FUNC_return%%, and a function body's
# `return 0` then runs the ATTACKER'S code and does NOT return — so a guard
# clause written as `[[ ... ]] || return 0` both executes and falls through.
# `true` and `:` are shadowable the same way. The function must end on an
# assignment (syntax, status 0) instead.
if grep -qE '(^|\||&&|;|then|else|do)[[:space:]]*(return|true|:)([[:space:]]|$)' <<<"$WIPE_BODY"; then
  fail "_pi_wipe uses a shadowable builtin (return/true/:) — exported functions override builtins"
elif ! grep -qE '^[[:space:]]*_pi_wipe_rc=0[[:space:]]*$' <<<"$WIPE_BODY"; then
  fail "_pi_wipe does not end on an assignment — its exit status is whatever cleanup left behind"
else
  ok "_pi_wipe avoids shadowable builtins and closes on an assignment"
fi

# THE ASSUMPTION UNDER THE ABSOLUTE-PATH RULE, checked against the live bash
# rather than asserted in a comment. `function /bin/rm { ...; }` IS definable
# in-shell — so the rule buys nothing unless bash also refuses to carry such a
# name through the ENVIRONMENT, which is the only vector reaching a script from
# outside. Today it refuses twice over (`export: /bin/rm: cannot export`, and
# `error importing function definition`). If a future bash relaxes either, this
# fails and the doctrine above needs rewriting — do not delete this to get green.
_IMPORT_PROBE="$(env "BASH_FUNC_/bin/rm%%=() { echo SHADOWED; }" \
                 bash --noprofile --norc -c '/bin/rm -f /nonexistent-busdriver-probe && echo CLEAN' 2>/dev/null)"
if [[ "$_IMPORT_PROBE" == "CLEAN" ]]; then
  ok "bash refuses to import a slash-named function — /bin/rm is unreachable from the environment"
else
  fail "bash imported BASH_FUNC_/bin/rm%% (got '$_IMPORT_PROBE') — absolute paths no longer contain the shadowing vector"
fi

# Every removal and every warning is TESTED (`if !` / `|| assignment`). An
# untested failure inside _pi_wipe trips the script's `set -e`, which skips the
# remaining cleanup — that is how a credential gets left on disk on the very
# path meant to remove it, and how a finished dispatch once died in its trap.
if grep -qE '^[[:space:]]*/bin/(rm|echo)[^|]*$' <<<"$WIPE_BODY"; then
  fail "_pi_wipe has an untested command — set -e can abort before cleanup finishes"
else
  ok "_pi_wipe cleanup and warnings are all set -e safe (tested)"
fi

# The jail IS removed recursively (pi writes cache files, so rmdir alone leaked
# a temp tree every dispatch). What makes that safe is upstream, not the delete:
# the jail is accepted at creation ONLY if absolute AND empty, which is what
# rules out a shadowed `mktemp` handing back a populated path like ~/.ssh.
# Assert the guard, and assert the shape is re-checked at the delete itself, so
# moving or weakening the creation guard cannot silently arm the rm -rf.
# Jail creation + credential projection must happen inside an `env -i` child.
# In the caller's shell, mktemp/mkdir/rm/python3 are all command words an
# exported function can shadow, and PATH pinning does not reach shell functions.
# Anchored on the PROJECTION child specifically. A bare `/usr/bin/env -i` match
# would now be satisfied by the version probe alone, so removing env -i from the
# credential path would slip past — the exact hole this assertion exists to hold.
# Scoped to the PROJECTION invocation itself. Two independent greps over the
# whole arm would pass on the version probe's `env -i` alone, letting projection
# regress to the inherited environment while keeping its SRC assignment — which
# is precisely the hole this assertion exists to hold shut.
# Scope the match to the _pi_project block BEFORE flattening. Matching across the
# whole arm let a greedy `.*` run past this invocation to the dispatch `env -i`
# further down, so the assertion could still pass with projection itself having
# lost `env -i` — the exact hole it exists to hold shut.
_projblock="$(awk '/_pi_project\(\) \{/{inb=1} inb{print} inb && /^CHILD$/{exit}' <<<"$ARM")"
_projinv="$(tr '\n' ' ' <<<"$_projblock" | sed -n 's/.*_pi_project()\(.*--noprofile --norc\).*/\1/p')"
if [[ -n "$_projinv" && "$_projinv" == */usr/bin/env\ -i* && "$_projinv" == *SRC=* ]]; then
  ok "credential projection invocation itself carries env -i"
else
  fail "projection invocation does not run under env -i — mktemp/mkdir/rm remain function-shadowable: ${_projinv:-<not found>}"
fi

# The credential path must reach the child as an ENV VAR, never on argv. grep is
# line-oriented and this invocation spans continuation lines, so flatten first —
# a line-by-line check here is vacuous (values simply sit on different lines).
# Scope to the INVOCATION only: everything between the child shell and the
# heredoc marker. Inside the heredoc, "$SRC" is the env var being consumed.
_inv="$(tr '\n' ' ' <<<"$ARM" | sed -n 's/.*--noprofile --norc\(.*\)<<.CHILD.*/\1/p')"
if [[ -n "$_inv" && "$_inv" == *auth.json* ]]; then
  fail "credential path appears on the child's argv, not its environment: $_inv"
else
  ok "child receives the credential path via environment, not argv"
fi

# The PARENT must fix the jail path before the child runs. When the child chose
# it and printed it back, cleanup raced: the child had to disarm its own trap
# before the final printf, and a signal in that window stranded a written API key
# the parent could not name. Parent-owned path ⇒ every failure branch can clean.
grep -qE '_pi_jail="\$\{_pi_tmp%/\}/busdriver-pi-\$\$-\$\{RANDOM\}\$\{RANDOM\}"' <<<"$ARM" \
  && ok "parent names the jail from builtins before the child runs" \
  || fail "jail path is not parent-assigned — cleanup races the child on signal paths"

# $$ and $RANDOM are builtins; mktemp is a command word an exported function can
# shadow. Regressing to mktemp here reopens the shadowing hole env -i exists for.
if grep -qE 'mktemp' <<<"$ARM"; then
  fail "pi arm calls mktemp — use builtin-derived naming so the path cannot be steered by a shadowed function"
else
  ok "pi arm derives the jail path without mktemp"
fi

# `-e` alone misses a DANGLING symlink, which is exactly what an attacker would
# plant at a predicted jail path — so the check must be `-e || -L`.
grep -qE '\[\[ -e "\$_pi_jail" \|\| -L "\$_pi_jail" \]\]' <<<"$ARM" \
  && ok "parent refuses a pre-existing jail path, dangling symlinks included" \
  || fail "no symlink-aware pre-existence check on the parent-chosen jail path"

# The pre-check is racy by construction, so the CHILD's non-idempotent mkdir is
# the real proof of ownership — and its distinct exit 3 is what stops the parent
# from deleting a path it did not create.
# Ownership must be reported POSITIVELY. Inferring it from "any code but 3" let
# a pre-mkdir failure (no python3, non-absolute path) authorise deleting a jail
# a racing process had created after the parent's pre-check.
_mkjail_child="$(awk '/_pi_mkjail\(\) \{/{inb=1} inb{print} inb && /^CHILD$/{exit}' <<<"$ARM")"
if [[ -z "$_mkjail_child" ]]; then
  fail "jail creation is not a separate step — ownership is being inferred from a combined child's exit status"
elif [[ "$(grep -c . <<<"$(awk '/^mkdir "\$D"$/{f=1} f' <<<"$_mkjail_child" | grep -vE '^CHILD$')")" -ne 1 ]]; then
  fail "mkdir is not the LAST statement of the creation child — a later failure makes ownership ambiguous again"
elif grep -qE '_pi_proj_rc' <<<"$ARM"; then
  fail "ownership is still decided from the projection child's exit code — a signal (128+n) overwrites it"
elif grep -qE "^trap 'rm -rf \"\\\$D\"'" <<<"$ARM"; then
  fail "projection child arms its own cleanup trap — two owners race to delete the same path"
else
  ok "jail creation is observed, not inferred (mkdir is the creation child's last statement)"
fi

# Once creation is observed, projection failure must wipe UNCONDITIONALLY. Any
# `if` around it reintroduces an exit-code judgement, and a signal death (128+n)
# overwrites whatever code the child meant to return — stranding a credential
# exactly when teardown matters most.
_proj_fail="$(awk '/elif ! _pi_project; then/{inb=1} inb{print} inb && /exit_code=1/{exit}' <<<"$ARM")"
if grep -qE '^\s*if .*_pi_wipe|_pi_wipe.*\bif\b' <<<"$_proj_fail"; then
  fail "projection teardown is conditional — a signal death can skip it"
else
  ok "projection failure tears the jail down unconditionally"
fi

# The creation branch must NOT wipe: creation failing means either nothing was
# made, or a signal hit around the mkdir — and the worst that can survive that is
# an EMPTY directory, never a credential. Deleting on unproven ownership is the
# worse trade.
_mkjail_fail="$(awk '/elif ! _pi_mkjail; then/{inb=1} inb{print} inb && /exit_code=1/{exit}' <<<"$ARM")"
if [[ -z "$_mkjail_fail" ]]; then
  fail "could not extract the jail-creation failure branch — this assertion is not running"
elif grep -q '_pi_wipe' <<<"$_mkjail_fail"; then
  fail "jail-creation failure wipes a path it never proved it created"
else
  ok "jail-creation failure does not delete a path of unproven ownership"
fi

# The PROJECTION child must never create the jail itself — that is the creation
# child's job, and splitting them is what keeps ownership observable.
_proj_child="$(awk '/_pi_project\(\) \{/{inb=1} inb{print} inb && /^CHILD$/{exit}' <<<"$ARM")"
if [[ -z "$_proj_child" ]]; then
  fail "could not extract the projection child — this assertion is not running"
elif grep -qE '^mkdir "\$D"$|^mkdir "\$D" ' <<<"$_proj_child"; then
  fail "projection child creates the jail too — creation and credential-writing must stay separate"
else
  ok "projection child writes the credential only; creation is a separate observed step"
fi

# Teardown must precede the error message: the message is now routed through
# `_pi_setup_fail`, which itself `echo`s (a command word), so a failing write to
# stderr trips `set -e` and a shadowed one can do worse. Nothing may come between
# a possibly part-written credential and its removal. The branch is bounded at
# the following `else`, not by hunting for a literal `exit_code=1` inside it —
# `_pi_setup_fail` sets that flag internally, so it no longer appears verbatim
# in this branch's own text.
_fail_branch="$(awk '/elif ! _pi_project; then/{inb=1} inb{print} inb && /^ *else$/{exit}' <<<"$ARM")"
_wipe_at="$(grep -n '_pi_wipe' <<<"$_fail_branch" | head -1 | cut -d: -f1 || true)"
_setup_fail_at="$(grep -n '_pi_setup_fail "could not project' <<<"$_fail_branch" | head -1 | cut -d: -f1 || true)"
if [[ -z "$_fail_branch" || -z "$_wipe_at" || -z "$_setup_fail_at" ]]; then
  fail "could not extract the projection-failure branch — this assertion is not running"
elif [[ "$_wipe_at" -lt "$_setup_fail_at" ]]; then
  ok "projection failure tears down the credential before it reports the error"
else
  fail "the error message runs before teardown — a failing echo strands the credential"
fi

# The projection-failure branch must be routed through `_pi_setup_fail`, not a
# bare `echo ...; exit_code=1` — otherwise the shared retry loop sees an empty
# $outfile on this deterministic failure and pays the full 5s/10s/20s backoff
# retrying a projection that cannot succeed on any attempt (PR #591 review).
if grep -qE '^ *echo "Error: could not project a static API credential' <<<"$ARM"; then
  fail "projection failure still uses a bare echo — not routed through _pi_setup_fail, so the retry loop will retry a deterministic failure"
else
  ok "projection failure is routed through _pi_setup_fail (no bare echo, no un-flagged retry)"
fi

grep -qE '/bin/bash --noprofile --norc' <<<"$ARM" \
  && ok "child shell is invoked by absolute path (unshadowable)" \
  || fail "child shell is not absolute — a function could stand in for it"

# `mkdir` WITHOUT -p is the check that the tree is OURS: it fails if the path
# already exists. "Absolute and currently empty" never proved authorship.
grep -qE '^mkdir "\$D"( \|\||$)' <<<"$ARM" \
  && grep -qE '^mkdir "\$D/\.pi" "\$D/\.pi/agent"( \|\||$)' <<<"$ARM" \
  && ok "jail created with non-idempotent mkdir (proves this dispatch made it)" \
  || fail "jail uses mkdir -p or similar — cannot prove the directory was created here"

# The path shape is re-asserted TWICE, and both halves matter. The parent gates
# on `[[ ]]` (a reserved word, so unshadowable) before spending a fork; the child
# re-checks the argument it was handed, so the `rm -rf` is guarded at the delete
# site itself even if the parent-side gate is later moved or weakened.
grep -qE '\[\[ -n "\$\{_pi_jail:-\}" && "\$_pi_jail" == /\* && "\$_pi_jail" != "/" \]\]' <<<"$ARM" \
  && ok "jail path shape is gated in the parent before the wipe child is spawned" \
  || fail "parent does not shape-check the jail path before spawning the wipe"

grep -qE "^case \"\\\$d\" in /\|'') exit 1 ;; /\*\) ;; \*\) exit 1 ;; esac$" <<<"$WIPE_CHILD" \
  && ok "jail path shape is re-asserted at the point of deletion" \
  || fail "recursive delete is not guarded by a path-shape re-check at the delete site"

# The credential must be removed on its own line BEFORE the tree delete, so it
# is gone even if the recursive removal fails.
grep -qE '^rm -f "\$d/\.pi/agent/auth\.json"$' <<<"$WIPE_CHILD" \
  && ok "credential is removed independently of the tree delete" \
  || fail "no standalone credential removal — a failed tree delete would leave the projected key on disk"

# Fail closed when the provider cannot be derived: projecting the WHOLE auth
# store is exactly what this must never do. --model bypasses the config regex,
# so this path is reachable by flag.
# Gated on pi being installed: the arm resolves the BINARY before it reaches the
# provider guard, so on a runner without pi (the Ubuntu shell-test job runs every
# tests/test-*.sh) this would fail on "pi binary not found" and turn an opt-in
# live concern into a mandatory red build.
if command -v pi >/dev/null 2>&1; then
  out_np="$(bash "$DISPATCH" --cli pi --model nosuchslash --timeout 5 --prompt x 2>&1 || true)"
  if grep -q 'is not the probed' <<<"$out_np"; then
    # The version gate (BUSDRIVER_PI_PROBED_VERSION) fires BEFORE the provider
    # guard this test targets. On a host with a different pi version that's a
    # true skip, not a provider-derivation failure — reporting fail here would
    # attribute an unrelated version mismatch to this guard.
    skip "provider-derivation guard (installed pi is not the probed version)"
  else
    grep -q 'could not derive a provider' <<<"$out_np" \
      && ok "unparseable model reference fails closed instead of exposing the credential store" \
      || fail "no fail-closed guard for a model reference without a provider/ prefix: $out_np"
  fi
else
  skip "provider-derivation guard (pi not installed on this host)"
fi

# The generic primary-CLI retry loop (shared by every --cli arm) retries
# whenever $outfile is empty, on the assumption an empty file means the CLI
# died before writing anything transient. pi's five deterministic setup
# failures (untrusted home, binary missing, version mismatch, provider
# underivable, credential-projection failure) are never a call to pi at all,
# so a bare `echo ... >&2` left $outfile empty and the loop retried a failure
# that cannot succeed on a retry — full 5s+10s+20s backoff for nothing. All
# five must route through _pi_setup_fail, which mirrors the message into
# $outfile too. (Raised from 4 to 5 on PR #591 review: the credential-
# projection failure branch was the one deterministic setup error still using
# a bare echo + exit_code=1.)
# Two other failure exits (existing-path refused, _pi_mkjail failed) stay
# outside this count deliberately, not by omission: both leave $outfile
# empty and take the retry path, but each retry recomputes $_pi_jail from a
# fresh $$/$RANDOM draw, so a transient name collision can clear on retry —
# unlike the five setup failures above, which fail identically no matter how
# many times they are retried.
_pi_setup_fail_count="$(grep -cE '_pi_setup_fail "' <<<"$ARM")"
[[ "$_pi_setup_fail_count" -eq 5 ]] \
  && ok "all five deterministic pi setup failures route through _pi_setup_fail (found $_pi_setup_fail_count)" \
  || fail "expected 5 deterministic pi setup failures routed through _pi_setup_fail, found $_pi_setup_fail_count — a setup error may retry needlessly"

grep -qE '_pi_setup_fail\(\) \{' <<<"$ARM" \
  && grep -qE '>> "\$outfile" 2>/dev/null' <<<"$ARM" \
  && ok "_pi_setup_fail mirrors the error into \$outfile (breaks the retry loop's empty-output test)" \
  || fail "_pi_setup_fail does not write to \$outfile — deterministic setup errors would still retry"

# ── 2b-ii. every statement of the certification ritual says BUMP FIRST ──
# ADR 0042. The ritual is stated in several comments and they DRIFTED: one said
# "re-run the live test, then bump this constant", another named only the test.
# Both describe verify-then-bump, which DEADLOCKS — the live check dispatches
# through this same file, so the version gate refuses the new pi before the
# write-denial check can reach it. A reader following either is stuck, which is
# what happened on the 0.84.1 → 0.84.2 upgrade.
#
# Pinned as a check, not as more prose, on this repo's own rule: enforce
# invariants with a test, never a comment.
#
# THE FIXTURES BELOW ARE THE PROOF, AND THEY SHIP. Three earlier versions of
# this guard were each declared "verified in both directions" and each was
# defective — one keyed on a literal the drifted text never contains, one lost
# the outage site to a line-wrap, one let an adjacent CODE line satisfy the
# "bump" concept. Every one passed a hand-run negative control that existed only
# in a transcript. So the negative control runs here, on every invocation,
# against the exact historical wording. If this guard ever stops being able to
# fail, these fixtures fail first.
_ritual_check() {   # stdin = shell source → prints "seen=N bad=M"; nonzero if any bad
    awk '
        # comment lines only: an adjacent code line must never satisfy a concept
        /^[[:space:]]*#/ { c = $0; sub(/^[[:space:]]*#[[:space:]]?/, "", c); buf[NR] = c; next }
        { buf[NR] = "" }        # code line → empty, so windows cannot borrow from it
        END {
            seen = 0; bad = 0
            for (i = 1; i <= NR; i++) {
                if (buf[i] !~ /BUSDRIVER_PI_LIVE/) continue
                seen++
                w = ""
                lo = (i - 8 < 1 ? 1 : i - 8); hi = i + 3
                for (j = lo; j <= hi; j++) w = w " " buf[j]
                live = index(w, "BUSDRIVER_PI_LIVE")
                bump = 0
                # earliest mention of the bump, by any spelling in use
                split("bump|BUSDRIVER_PI_PROBED_VERSION|this constant|the constant", toks, "|")
                for (t in toks) {
                    p = index(w, toks[t])
                    if (p > 0 && (bump == 0 || p < bump)) bump = p
                }
                if (bump == 0)      { bad++; print "  (line " i ": names the live test but never the bump)" > "/dev/stderr" }
                else if (bump > live) { bad++; print "  (line " i ": names the live test BEFORE the bump — deadlocks)" > "/dev/stderr" }
            }
            print "seen=" seen " bad=" bad
            exit (bad > 0 ? 1 : 0)
        }'
}

# Negative fixture: the VERBATIM pre-ADR-0042 wording of both drifted sites.
# Copied from git history, not paraphrased — paraphrasing in this file's own
# vocabulary is precisely how the earlier versions fooled themselves.
_ritual_bad_fixture='
# where a stuck lane beats a skipped check. Clearing it: re-run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump this constant.
BUSDRIVER_PI_PROBED_VERSION="0.84.1"
                    # check" applies here. On a mismatch, re-run:
                    # BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
'
if _ritual_check <<<"$_ritual_bad_fixture" >/dev/null 2>&1; then
    fail "ritual guard is VACUOUS — it accepts the verbatim pre-0042 wording that caused the outage"
else
    ok "ritual guard rejects the verbatim pre-0042 wording (guard proven able to fail)"
fi

# A code line carrying the constant must NOT satisfy the bump concept for a
# comment that omits it — the exact vacuity found in review.
_ritual_code_fixture='
                    # check" applies here. On a mismatch, re-run:
                    # BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
                    if [[ "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then
'
if _ritual_check <<<"$_ritual_code_fixture" >/dev/null 2>&1; then
    fail "ritual guard borrows the bump concept from an adjacent CODE line (vacuous at the _pi_setup_fail site)"
else
    ok "ritual guard ignores code lines when looking for the bump (no borrowing)"
fi

# Now the real file. Discovery keys on BUSDRIVER_PI_LIVE alone, so a comment
# that wraps the command across lines is still seen.
_ritual_err="$FAKE_HOME/ritual.err"   # proven-ours dir; mktemp is a shadowable command word
_ritual_out="$(_ritual_check < "$DISPATCH" 2>"$_ritual_err")" && _ritual_rc=0 || _ritual_rc=1
_ritual_seen="${_ritual_out#seen=}"; _ritual_seen="${_ritual_seen%% *}"
# Expect both ritual COMMENTS. The third statement — the _pi_setup_fail message —
# is a code string and is deliberately out of scope HERE (comment-only is what
# stops an adjacent code line satisfying a concept); it gets its own guard below.
# It is NOT covered by the five-setup-failure assertion above: that assertion
# counts _pi_setup_fail calls and mirrors output, and never inspects ordering.
# A drop below 2 means a ritual comment was deleted rather than corrected, which
# is also drift.
if [[ "$_ritual_rc" -eq 0 && "${_ritual_seen:-0}" -ge 2 ]]; then
    ok "all $_ritual_seen certification-ritual mentions in dispatch.sh name the bump before the live test"
else
    fail "dispatch.sh ritual comments are wrong or under-discovered ($_ritual_out): $(cat "$_ritual_err" 2>/dev/null)"
fi


# ── #692 gap 2: per-anchor presence, replacing the `seen >= 2` count floor ──
# A file-wide count cannot tell "both real sites are present" from "one was
# deleted and an incidental BUSDRIVER_PI_LIVE comment appeared elsewhere" — the
# total is 2 either way, so the deletion passes. Anchor on the CODE landmark
# instead and assert two things a count cannot: the landmark appears EXACTLY
# ONCE (a duplicate or decoy copy is itself a drift signal), and at least one
# comment naming BUSDRIVER_PI_LIVE sits within `win` lines above it. Order
# compliance of every such mention is already enforced file-wide by
# _ritual_check above (its own fixture proves a live-mention with no bump
# fails); this check's only new claim is per-site PRESENCE, which is exactly
# what a count floor cannot see.
#
# Deliberately not an attribution parser: earlier drafts tried to prove the
# nearby comment was THIS anchor's own comment (context windows, prior-anchor
# clamps, decoy-word disambiguation) and each round of review found a new
# misattribution to exploit — attribution over free text has no completion
# point. Uniqueness does: any decoy or duplicate makes a count assertion fail
# closed, which is correct behaviour, not a bypass.
#
# Accepted residual (documented, same posture as the negation bypass in
# docs/adr/0042-pi-version-certification-cache.md "Known limitations"): this
# proves the covering comment is UNIQUE and correctly ordered, not that it is
# THIS anchor's own comment. An unrelated, correctly-ordered comment already
# present within `win` lines above a site would still satisfy presence if
# that site's own comment were deleted. WONTFIX for the same reason gap 1
# (negation) is WONTFIX: closing it needs the attribution machinery this
# design deliberately dropped.
_ritual_anchor_check() {   # $1 = literal line start, $2 = window, $3 = exact|assign; stdin = source
    # The anchor is a LITERAL that must begin the line once leading whitespace is
    # stripped -- not a regex, and with no comment handling at all. Rounds 6-9 each
    # found another shell spelling that smuggled the gate text into a comment while
    # still matching a regex: a trailing `# if [[ … ]]`, an `if true; then # …` whose
    # executable prefix begins with `if`, and `:;#` where bash starts a comment right
    # after a control operator with no whitespace. Recognising comments needs a shell
    # lexer, and that ladder has no last rung -- the same conclusion the ADR 0034 check
    # reached about Markdown. Requiring the line to BEGIN with the literal ends it: a
    # commented copy begins with `#`, and a smuggled one begins with whatever code
    # precedes the `#`, so neither can match. If the real line is legitimately
    # reformatted, update the literal in the same commit.
    #
    # ACCEPTED RESIDUAL (ADR 0042 Known limitations — same gap-1 class, WONTFIX): this
    # proves the line's TEXT and uniqueness, not that it is executable shell. With the
    # real gate deleted, a heredoc body holding that exact line would still be counted.
    # Proving executability needs the same shell parser. The threat model is drift, not
    # a crafted heredoc. Do NOT add one.
    awk -v anchor="$1" -v win="$2" -v mode="$3" '
        { line[NR] = $0 }
        END {
            found = 0; bad = 0; badline = 0
            for (i = 1; i <= NR; i++) {
                l = line[i]
                sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]+$/, "", l)
                if (index(l, anchor) != 1) continue
                # A malformed site still COUNTS as a site. Skipping it instead let a
                # valid pin coexist with a later `="$(pi --version)"` line: uniqueness
                # saw one site, while bash used the last assignment (#696 round 12).
                found++; pos = i
                rest = substr(l, length(anchor) + 1)
                # What may FOLLOW the literal, so appended code cannot ride along on a
                # line that starts correctly (#696 round 10). exact: nothing at all.
                # assign: a STATIC version literal. A quoted-anything shape is not enough
                # -- it accepts "$(pi --version)", which makes the pin dynamically equal
                # whatever is installed and silently defeats the whole gate (#696 round
                # 11). Restricting the value to version characters rejects command
                # substitution, backticks, parameter expansion, escapes and an empty
                # value without knowing any shell grammar: they are simply not version
                # characters. The value itself stays free, which the bump ritual needs.
                if (mode == "exact") { if (rest != "") { bad++; badline = i } }
                else if (rest !~ /^"[0-9][0-9A-Za-z.+-]*"$/) { bad++; badline = i }
            }
            if (found != 1) {
                print "anchors=" found " (expected exactly 1)"
                exit 1
            }
            if (bad) {
                print "line " badline ": anchor site is malformed (mode=" mode ")"
                exit 1
            }
            lo = (pos - win < 1 ? 1 : pos - win)
            covered = 0
            for (j = lo; j < pos; j++) {
                c = line[j]
                if (c !~ /^[[:space:]]*#/) continue
                if (c ~ /BUSDRIVER_PI_LIVE/) { covered = 1; break }
            }
            print "anchors=1 covered=" covered
            exit (covered ? 0 : 1)
        }'
}

# The two anchors, as literal line starts. The gate is the FULL line so any
# reformatting fails the check and a human re-reads it; the constant is only its
# assignment prefix, because the version after `=` changes on every certified bump
# and pinning it would make the ADR 0034 ritual fail on its own second step.
_ANCHOR_CONST='BUSDRIVER_PI_PROBED_VERSION='
_ANCHOR_GATE='if [[ -z "$_pi_ver" || "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then'

# Fixture: the anchor's ritual comment was deleted outright — no comment
# mentioning BUSDRIVER_PI_LIVE anywhere in the window above it.
_anchor_bad_fixture='
echo unrelated
BUSDRIVER_PI_PROBED_VERSION="0.84.2"
'
if _ritual_anchor_check "$_ANCHOR_CONST" 60 assign <<<"$_anchor_bad_fixture" >/dev/null 2>&1; then
    fail "anchor check accepts a site with no ritual comment above it (presence bug not fixed)"
else
    ok "anchor check rejects a site with no ritual comment above it (proven able to fail)"
fi

# Fixture: the anchor line itself is duplicated — a decoy or accidental copy
# (e.g. inside a later unrelated block) must fail closed rather than silently
# picking one match.
_anchor_dup_fixture='
# bump this constant, then re-run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
BUSDRIVER_PI_PROBED_VERSION="0.84.2"
echo unrelated
BUSDRIVER_PI_PROBED_VERSION="0.84.2"
'
if _ritual_anchor_check "$_ANCHOR_CONST" 60 assign <<<"$_anchor_dup_fixture" >/dev/null 2>&1; then
    fail "anchor check accepts a duplicated anchor line (uniqueness bug not fixed)"
else
    ok "anchor check rejects a duplicated anchor line (proven able to fail)"
fi

# #696 review: a TRAILING shell comment carrying the gate text was counted as the live
# anchor. A round-7 "skip lines starting with #" filter was tried and REMOVED -- it
# could never fire on either call site and no fixture for it could be made to fail,
# which is the vacuous-guard shape this suite exists to reject.
_anchor_trailing_comment_fixture='
# On a mismatch, bump BUSDRIVER_PI_PROBED_VERSION FIRST, then re-run:
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
echo active # if [[ -z "$_pi_ver" || "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then
'
if _ritual_anchor_check "$_ANCHOR_GATE" 60 exact <<<"$_anchor_trailing_comment_fixture" >/dev/null 2>&1; then
    fail "anchor check counts a TRAILING comment as the live gate (trailing-comment bug not fixed)"
else
    ok "anchor check ignores a gate hidden in a trailing comment (proven able to fail)"
fi

# #696 round 8: the executable prefix itself begins with `if`, so any regex anchored
# on `if ` matches. Only requiring the line to BEGIN with the full literal rejects it;
# loosen that to a substring search and this fixture passes.
_anchor_if_true_fixture='
# On a mismatch, bump BUSDRIVER_PI_PROBED_VERSION FIRST, then re-run:
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
if true; then # if [[ -z "$_pi_ver" || "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then
'
if _ritual_anchor_check "$_ANCHOR_GATE" 60 exact <<<"$_anchor_if_true_fixture" >/dev/null 2>&1; then
    fail "anchor check counts \`if true; then # if [[ … ]]\` as the live gate"
else
    ok "anchor check rejects a gate behind an executable \`if\` prefix (proven able to fail)"
fi

# #696 round 9: bash starts a comment immediately after a control operator, with no
# whitespace before `#`. Any whitespace-based comment stripper misses this; requiring
# the line to BEGIN with the literal rejects it without knowing bash's comment rules.
_anchor_operator_comment_fixture='
# On a mismatch, bump BUSDRIVER_PI_PROBED_VERSION FIRST, then re-run:
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
if true; then :;# if [[ -z "$_pi_ver" || "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then
'
if _ritual_anchor_check "$_ANCHOR_GATE" 60 exact <<<"$_anchor_operator_comment_fixture" >/dev/null 2>&1; then
    fail "anchor check counts a gate commented out with \`:;#\` as the live gate"
else
    ok "anchor check rejects a gate commented out with \`:;#\` (proven able to fail)"
fi

# #696 round 10: a line that STARTS with the real gate but appends code -- here closing
# the conditional immediately and opening a dead one -- is syntactically valid shell that
# neuters the gate while a prefix match still counts it. Nothing may follow the literal.
_anchor_suffix_fixture='
# On a mismatch, bump BUSDRIVER_PI_PROBED_VERSION FIRST, then re-run:
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh
if [[ -z "$_pi_ver" || "$_pi_ver" != "$BUSDRIVER_PI_PROBED_VERSION" ]]; then :; fi; if false; then
'
if _ritual_anchor_check "$_ANCHOR_GATE" 60 exact <<<"$_anchor_suffix_fixture" >/dev/null 2>&1; then
    fail "anchor check counts a gate with appended code as the live gate (prefix match not closed)"
else
    ok "anchor check rejects a gate with code appended after it (proven able to fail)"
fi

# Same hole on the constant: the version must stay free to change, so its line is
# pinned by SHAPE -- a quoted literal and nothing else -- rather than by value.
_anchor_const_suffix_fixture='
# bump this constant, then re-run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
BUSDRIVER_PI_PROBED_VERSION="0.84.2"; BUSDRIVER_PI_PROBED_VERSION="0.0.0"
'
if _ritual_anchor_check "$_ANCHOR_CONST" 60 assign <<<"$_anchor_const_suffix_fixture" >/dev/null 2>&1; then
    fail "anchor check counts a constant line with a second assignment appended"
else
    ok "anchor check rejects a constant line with code appended after it (proven able to fail)"
fi

# #696 round 11: the constant's VALUE must be static. Each of these is a shell
# construct that would make the pin dynamic (or the line malformed); none is a version.
for _bad in cmdsub backtick paramexp escape empty bareword; do
    case "$_bad" in
      cmdsub)   _v='"$(pi --version)"' ;;
      backtick) _v='"`pi --version`"' ;;
      paramexp) _v='"${_pi_ver}"' ;;
      escape)   _v='"0.84.2\"; evil"' ;;
      empty)    _v='""' ;;
      *)        _v='"$_pi_ver"' ;;
    esac
    _f="
# bump this constant, then re-run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
BUSDRIVER_PI_PROBED_VERSION=$_v
"
    if _ritual_anchor_check "$_ANCHOR_CONST" 60 assign <<<"$_f" >/dev/null 2>&1; then
        fail "anchor check accepts a non-static constant value ($_bad)"
    else
        ok "anchor check rejects a non-static constant value ($_bad) (proven able to fail)"
    fi
done

# Control: the shape must still accept real version strings, or every fixture above
# would be vacuous -- a check that rejects everything proves nothing.
for _good in '"0.84.2"' '"1.2.3-rc.1"' '"2.0.0+build.5"'; do
    _f="
# bump this constant, then re-run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
BUSDRIVER_PI_PROBED_VERSION=$_good
"
    if _ritual_anchor_check "$_ANCHOR_CONST" 60 assign <<<"$_f" >/dev/null 2>&1; then
        ok "anchor check accepts the real version literal $_good (control: can pass)"
    else
        fail "anchor check rejects the valid version literal $_good -- shape too tight"
    fi
done

# #696 round 12: a VALID pin followed by a second, dynamic assignment. Bash uses the
# last one, so counting only well-formed sites would see a single anchor and pass.
_anchor_shadow_fixture='
# bump this constant, then re-run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
BUSDRIVER_PI_PROBED_VERSION="0.84.2"
echo unrelated
BUSDRIVER_PI_PROBED_VERSION="$(pi --version)"
'
if _ritual_anchor_check "$_ANCHOR_CONST" 60 assign <<<"$_anchor_shadow_fixture" >/dev/null 2>&1; then
    fail "anchor check accepts a valid pin shadowed by a later dynamic assignment"
else
    ok "anchor check rejects a pin shadowed by a later assignment (proven able to fail)"
fi

for _what in 'the version constant' 'the version gate'; do
    case "$_what" in
      *constant) _lit="$_ANCHOR_CONST"; _mode=assign ;;
      *)         _lit="$_ANCHOR_GATE";  _mode=exact  ;;
    esac
    if _out=$(_ritual_anchor_check "$_lit" 60 "$_mode" < "$DISPATCH" 2>/dev/null); then
        ok "$_what is a unique site with a ritual comment above it ($_out)"
    else
        fail "$_what is missing or duplicated, or has no ritual comment above it ($_out)"
    fi
done

# ── #692 gap 3: the fourth ritual statement, in docs/adr/0034 ──
# Prose, not a comment, so neither check above reaches it. The ritual is verified by
# holding a VERBATIM GOLDEN COPY of the block and requiring it to appear in the
# document exactly once. There is NO Markdown classification of any kind -- no fence,
# container or indentation logic -- because four successive designs that tried to
# decide which occurrences were "live" were each rejected for mishandling some
# construct. Counting exact occurrences needs no container logic: a BYTE-IDENTICAL copy
# anywhere -- fenced or bare -- is simply a second occurrence and fails closed. A
# container that re-prefixes every line is not byte-identical and is out of scope; the
# fixtures below assert that in the true direction rather than claiming otherwise.
#
# The accepted residual for this check is recorded at _ADR_RITUAL_GOLDEN below, next
# to the literal it applies to.
_adr34="$(find "${DISPATCH%/skills/*}/docs/adr" -maxdepth 1 -name '0034-*.md' 2>/dev/null | head -1)"
# The ritual as ADR 0034 must state it, verbatim. This is a GOLDEN literal, not a
# pattern: #696 review round 4 showed that every loosening — a prefix match on
# BUSDRIVER_PI_LIVE (which also accepts BUSDRIVER_PI_LIVE_DISABLED), a wildcard before
# the constant (which also accepts `bump xBUSDRIVER_PI_PROBED_VERSION_OLD`), or counting
# a marker phrase (which still passes if the real bullet is DELETED and a fenced example
# survives) — admits an instruction that is wrong. An exact block admits none of them,
# needs no Markdown parsing at all, and fails on any drift so a human re-reads it.
# If this block is legitimately reworded, update this literal in the same commit.
_ADR_RITUAL_GOLDEN='  trust an unverified one. Operator cost on every pi release, **in this order**:
  bump `BUSDRIVER_PI_PROBED_VERSION` to the new version FIRST, then run
  `BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh`, and revert the bump if it
  fails.'
# ACCEPTED RESIDUAL (ADR 0042, "Known limitations of the ritual guard" — gap 1 class,
# WONTFIX). The golden block is matched as a SUBSTRING, so text placed around it is not
# examined: prefixing `DO NOT ` still satisfies this check, and a lone verbatim copy
# surviving inside a fence would too. Closing either requires deciding whether
# neighbouring prose negates the instruction, or which occurrences are "live" — the
# unbounded attribution problem gap 1 is WONTFIX for. Four successive designs
# (attribution windows, occurrence counting, a CommonMark container parser, this golden
# literal) were each rejected on the same ground. This guard targets ACCIDENTAL DRIFT —
# a statement edited into the wrong order — not an author deliberately negating their
# own repo's instruction. Do NOT add a parser here; that ladder has no last rung.
_adr_check() {   # stdin = markdown → 0 iff the golden ritual block appears EXACTLY once
    export _ADR_RITUAL_GOLDEN
    awk '
        BEGIN { golden = ENVIRON["_ADR_RITUAL_GOLDEN"] }
        { doc = doc $0 "\n" }
        END {
            n = 0; start = 1
            while ((p = index(substr(doc, start), golden)) > 0) { n++; start += p + length(golden) - 1 }
            if (n == 1) { print "ritual=1 verbatim=ok"; exit 0 }
            print "ritual=" n " (expected the golden ritual block exactly once)"
            exit 1
        }'
}

# Fixtures. Each differs from the golden block in EXACTLY the property under test --
# a fixture that fails for an unrelated reason (wrong case, missing backticks) proves
# nothing, which is how this file's previous block-quote fixture was vacuous.
if _adr_check <<<"$_ADR_RITUAL_GOLDEN" >/dev/null 2>&1; then
    ok "ADR check accepts the golden ritual block (control: the guard can pass)"
else
    fail "ADR check rejects the golden block — every negative fixture below would be vacuous"
fi

if _adr_check <<<"prose with no ritual block at all." >/dev/null 2>&1; then
    fail "ADR check accepts a document with the ritual deleted"
else
    ok "ADR check rejects a document with the ritual deleted (proven able to fail)"
fi

if _adr_check <<<"$_ADR_RITUAL_GOLDEN
$_ADR_RITUAL_GOLDEN" >/dev/null 2>&1; then
    fail "ADR check accepts a duplicated ritual block"
else
    ok "ADR check rejects a duplicated ritual block (proven able to fail)"
fi

# Round-4 loosenings: a prefix/wildcard match would accept both of these.
_adr_wrong_flag="${_ADR_RITUAL_GOLDEN/BUSDRIVER_PI_LIVE=1/BUSDRIVER_PI_LIVE_DISABLED=1}"
if _adr_check <<<"$_adr_wrong_flag" >/dev/null 2>&1; then
    fail "ADR check accepts BUSDRIVER_PI_LIVE_DISABLED — prefix matching not eliminated"
else
    ok "ADR check rejects a look-alike flag name (proven able to fail)"
fi
_adr_wrong_const="${_ADR_RITUAL_GOLDEN/bump \`BUSDRIVER_PI_PROBED_VERSION\`/bump \`xBUSDRIVER_PI_PROBED_VERSION_OLD\`}"
if _adr_check <<<"$_adr_wrong_const" >/dev/null 2>&1; then
    fail "ADR check accepts a look-alike constant name — wildcard matching not eliminated"
else
    ok "ADR check rejects a look-alike constant name (proven able to fail)"
fi

# Substitution case (round 4): real bullet DELETED, only a fenced example left.
# The golden literal is absent from the surviving text, so this fails on count 0 —
# no container awareness required.
if _adr_check <<<'Some prose.
```text
(an example that paraphrases the ritual but is not the golden block)
```' >/dev/null 2>&1; then
    fail "ADR check accepts a document whose real ritual was replaced by an example"
else
    ok "ADR check rejects ritual-replaced-by-example (proven able to fail)"
fi

# A FENCED duplicate preserves the block byte-for-byte, so it is a second occurrence
# and fails closed -- this is why no fence parser is needed.
_adr_fenced_decoy=$'```text\n'"$_ADR_RITUAL_GOLDEN"$'\n```'
if _adr_check <<<"$_ADR_RITUAL_GOLDEN
$_adr_fenced_decoy" >/dev/null 2>&1; then
    fail "ADR check accepts a verbatim duplicate hidden in a fenced block"
else
    ok "ADR check rejects a verbatim duplicate in a fenced block (no parsing needed)"
fi

# ACCEPTED RESIDUAL (#696 review round 8, corrected claim). A container that RE-PREFIXES
# EVERY line -- a real block quote (`> ` per line) or indented code block (4 spaces per
# line) -- is no longer a byte-identical copy, so it is NOT counted. The earlier fixtures
# prefixed only the FIRST line, which left the golden substring intact and so "proved"
# a detection that does not happen. Asserted in the true direction instead of claimed
# away. This is not a hole: the guard's scope is the VERBATIM block, deleting the real
# block still fails at zero, drifting it still fails, and a re-prefixed quotation
# standing alongside an intact real block leaves the correct instruction in place.
for _lbl in block-quote indented; do
    case "$_lbl" in block-quote) _pfx='> ' ;; *) _pfx='    ' ;; esac
    _decoy=$(printf '%s\n' "$_ADR_RITUAL_GOLDEN" | sed "s|^|$_pfx|")
    if _adr_check <<<"$_ADR_RITUAL_GOLDEN
$_decoy" >/dev/null 2>&1; then
        ok "ADR check tolerates a re-prefixed $_lbl quotation (documented residual: not verbatim)"
    else
        fail "ADR check now rejects a re-prefixed $_lbl quotation -- residual changed, update ADR 0042"
    fi
done

if [[ -f "$_adr34" ]]; then
    if _adr_out=$(_adr_check < "$_adr34" 2>&1); then
        ok "ADR 0034 states the ritual in the bump-then-verify order ($_adr_out)"
    else
        fail "ADR 0034 ritual prose has drifted: $_adr_out"
    fi
else
    fail "ADR 0034 not found under docs/adr/0034-*.md — the fourth ritual statement is unguarded"
fi
rm -f "$_ritual_err"

# ── The ritual's THIRD statement: the _pi_setup_fail message (a code string).
# Same invariant, different carrier, so it needs its own check — comment-only
# discovery cannot see it. Anchored on the INSTRUCTION ("set <const>" / "bump"),
# never the bare constant: the message already interpolates the constant as prose
# before the live-test mention, so a bare-name search would pass vacuously — the
# exact borrowing defect that made an earlier guard useless.
_ritual_msg_check() {   # stdin = shell source → prints "seen=N bad=M"
    awk '
        !/_pi_setup_fail/ { next }
        !/BUSDRIVER_PI_LIVE/ { next }
        {
            seen++
            live = index($0, "BUSDRIVER_PI_LIVE")
            bump = 0
            split("set BUSDRIVER_PI_PROBED_VERSION|bump", toks, "|")
            for (t in toks) {
                p = index($0, toks[t])
                if (p > 0 && (bump == 0 || p < bump)) bump = p
            }
            if (bump == 0)        { bad++; print "  (setup-fail message names the live test but never instructs the bump)" > "/dev/stderr" }
            else if (bump > live) { bad++; print "  (setup-fail message orders the live test BEFORE the bump — deadlocks)" > "/dev/stderr" }
        }
        END { print "seen=" (seen+0) " bad=" (bad+0); exit (bad > 0 ? 1 : 0) }'
}

# Negative fixture A: reversed order — verify-then-bump, the deadlock.
if _ritual_msg_check <<<'_pi_setup_fail "run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then set BUSDRIVER_PI_PROBED_VERSION."' >/dev/null 2>&1; then
    fail "setup-fail guard accepts verify-then-bump ordering (vacuous)"
else
    ok "setup-fail guard rejects verify-then-bump ordering (proven able to fail)"
fi

# Negative fixture B: the constant appears only as interpolated prose, with no
# instruction to change it. Must NOT be mistaken for the bump.
if _ritual_msg_check <<<'_pi_setup_fail "pi is not the probed ${BUSDRIVER_PI_PROBED_VERSION}. Run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh."' >/dev/null 2>&1; then
    fail "setup-fail guard borrows the bump concept from interpolated prose (vacuous)"
else
    ok "setup-fail guard ignores the interpolated constant when no bump is instructed"
fi

_ritual_msg_err="$FAKE_HOME/ritual-msg.err"   # same: no shadowable command word in the path
_ritual_msg_out="$(_ritual_msg_check < "$DISPATCH" 2>"$_ritual_msg_err")" && _ritual_msg_rc=0 || _ritual_msg_rc=1
_ritual_msg_seen="${_ritual_msg_out#seen=}"; _ritual_msg_seen="${_ritual_msg_seen%% *}"
if [[ "$_ritual_msg_rc" -eq 0 && "${_ritual_msg_seen:-0}" -ge 1 ]]; then
    ok "the _pi_setup_fail ritual message names the bump before the live test"
else
    fail "the _pi_setup_fail ritual message is wrong or missing ($_ritual_msg_out): $(cat "$_ritual_msg_err" 2>/dev/null)"
fi
rm -f "$_ritual_msg_err"

# ── 2c. EXECUTED: the projection child actually projects one entry ──
# Runs the real heredoc from the arm, not a copy — a copy would drift and then
# certify code that is no longer shipped. Needs python3 and a pi auth store; no
# model call, so this is a mandatory check rather than an opt-in one.
# Pick the PROJECTION heredoc specifically. The arm now contains two `<<'CHILD'`
# bodies — preflight comes first — so "extract the first one" silently tested the
# wrong code and passed. Select by content: only the projection child consumes
# $PROV. A body that no longer does is a real regression, not a lookup miss.
CHILD_BODY="$(awk '
  /\/bin\/bash --noprofile --norc <<.CHILD./ {inb=1; body=""; next}
  inb && /^CHILD$/ {if (body ~ /PROV/) {printf "%s", body; exit} inb=0; next}
  inb {body = body $0 "\n"}
' "$DISPATCH")"
if [[ -z "$CHILD_BODY" ]]; then
  fail "could not extract the projection child from the pi arm"
elif ! command -v python3 >/dev/null 2>&1; then
  skip "projection child execution (python3 unavailable)"
else
  # SYNTHETIC auth store. The earlier version read the operator's real
  # ~/.pi/agent/auth.json, which (a) skipped on any clean CI runner, leaving this
  # security-sensitive path unexercised exactly where it matters most, and (b)
  # copied a live API key around on local runs for no benefit. Fixture data
  # exercises the same code and runs everywhere.
  _AS="$FAKE_HOME/synthetic-auth.json"
  cat > "$_AS" <<'JSON'
{
  "goodprov":  {"type": "api_key", "key": "FAKE-NOT-A-REAL-KEY"},
  "otherprov": {"type": "api_key", "key": "FAKE-ALSO-NOT-REAL"},
  "oauthprov": {"type": "oauth", "refresh": "FAKE-REFRESH", "access": "FAKE-ACCESS"}
}
JSON
  # Jail creation is now its own child, so drive both exactly as the arm does.
  MKJAIL_BODY="$(awk '
    /_pi_mkjail\(\) \{/ {inf=1}
    inf && /\/bin\/bash --noprofile --norc <<.CHILD./ {inb=1; next}
    inb && /^CHILD$/ {exit}
    inb {print}
  ' "$DISPATCH")"
  [[ -n "$MKJAIL_BODY" ]] \
    && ok "jail-creation child extracted for live exercise" \
    || fail "could not extract the jail-creation child — the live projection checks below are not running"

  _runmkjail() { # $1=target dir → exit status of the creation child
    /usr/bin/env -i "D=$1" /bin/bash --noprofile --norc <<<"$MKJAIL_BODY" 2>/dev/null
  }
  _runchild() { # $1=provider $2=target dir → status of create-then-project
    _runmkjail "$2" || return 1
    /usr/bin/env -i "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      "SRC=$_AS" "PROV=$1" "D=$2" /bin/bash --noprofile --norc <<<"$CHILD_BODY" 2>/dev/null
  }

  _j="$FAKE_HOME/jail-ok"
  if _runchild goodprov "$_j" && [[ -f "$_j/.pi/agent/auth.json" ]]; then
    _n="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print("%d:%s" % (len(d), ",".join(d)))' "$_j/.pi/agent/auth.json" 2>/dev/null || echo "err")"
    [[ "$_n" == "1:goodprov" ]] \
      && ok "projection writes exactly ONE provider entry (the requested one)" \
      || fail "jail auth store is '$_n' — expected exactly 1:goodprov, so projection is not narrowing the credential set"
  else
    fail "projection child failed for a valid static api-key provider"
  fi

  # An OAuth/refreshable credential must be refused: pi would refresh it inside
  # the jail, the update would be discarded, and a rotating provider would
  # invalidate the operator's real credential.
  _j3="$FAKE_HOME/jail-oauth"
  if _runchild oauthprov "$_j3"; then
    fail "refreshable (oauth) credential was projected — in-jail refresh would be discarded"
  else
    ok "refreshable (oauth) credential is refused"
  fi

  # Unknown provider must fail closed rather than projecting the whole store.
  _j2="$FAKE_HOME/jail-unknown"
  if _runchild __nosuch__ "$_j2"; then
    fail "unknown provider still produced a jail"
  else
    [[ -f "$_j2/.pi/agent/auth.json" ]] \
      && fail "unknown provider left a credential file behind" \
      || ok "unknown provider fails closed with no credential written"
  fi

  # A pre-existing target must be refused by the CREATION child — that refusal is
  # the freshness proof the parent's teardown decision rests on.
  _j4="$FAKE_HOME/jail-exists"; mkdir -p "$_j4"
  if _runmkjail "$_j4"; then
    fail "child accepted a pre-existing directory — mkdir is not proving freshness"
  else
    ok "pre-existing target directory is refused"
  fi
fi

# ── 2d. Preflight (home + binary resolution) is also sandboxed ──
# These ran in the inherited shell once, where `eval`, `command -v`, `dirname`,
# `cd` and `pwd` are shadowable: an exported function could execute code at eval
# time, or steer the resolved binary and PATH so a fake `node` reports the probed
# version. PATH pinning does not reach shell functions; only env -i does.
if grep -qE 'command -v pi' <<<"$ARM"; then
  fail "pi binary resolved via command -v — shadowable; use explicit absolute candidates inside env -i"
else
  ok "pi binary is not resolved through command -v"
fi

grep -qE 'if ! _pi_pre="\$\(/usr/bin/env -i' <<<"$ARM" \
  && ok "preflight (home + binary) runs inside an env -i child" \
  || fail "preflight runs in the inherited shell — eval/command -v/dirname remain shadowable"

# The child's OUTPUT must be split with parameter expansion only. A
# `printf | sed` split puts shadowable command words on the path of the very
# values the clean child exists to protect, so an exported function could forge
# both the home and the binary and the boundary buys nothing.
_split="$(grep -E '^ *_pi_(home|bin)="\$' <<<"$ARM" || true)"
if grep -qE 'printf|sed|awk|cut|head|tail' <<<"$_split"; then
  fail "preflight output is split with external commands — forgeable by an exported function: $_split"
else
  ok "preflight output is split with parameter expansion only"
fi

# pi ships `#!/usr/bin/env node`; a pi under ~/.local/bin still needs Homebrew
# Node on Apple Silicon. Omitting it made the version probe unreadable, which —
# now that a mismatch BLOCKS — bricked the lane entirely.
grep -qE '_pi_path="\$\{_pi_bin%/\*\}:/opt/homebrew/bin:' <<<"$ARM" \
  && ok "child PATH always includes Homebrew (node lookup for pi's shebang)" \
  || fail "child PATH omits /opt/homebrew/bin unless pi lives there — pi's node shebang may not resolve"

# ── 3. --mode cannot loosen the lane ────────────────────────────
# The arm must not branch on MODE at all: a `--mode auto` branch here would be
# a write posture with no worktree semantics and no review.
# Boundary matters: `$MODEL` (the legitimate --model override chain) starts with
# `MODE`, so an unanchored pattern flags the wrong variable.
if grep -qE '\$MODE([^A-Za-z0-9_]|$)|\$\{MODE[}:]' <<<"$ARM"; then
  fail "pi arm branches on \$MODE — this lane is read-only by construction and must ignore it"
else
  ok "pi arm ignores --mode (read-only by construction)"
fi

# ── 4. Batch safety: pi excluded from write batches ─────────────
grep -qE '\[\[ "\$c" == "pi" && "\$MODE" == "auto" \]\] && continue' "$DISPATCH" \
  && ok "--cli all skips pi in write mode (no read-only voice masquerading as a writer)" \
  || fail "--cli all no longer excludes pi from --mode auto batches"

# The candidate cap must admit the sixth CLI; pi is last in the list, so a
# stale cap of 5 silently drops it in a full house.
grep -qE '\$\{#ALL_CLIS\[@\]\} -ge 6' "$DISPATCH" \
  && ok "--cli all candidate cap admits the sixth CLI" \
  || fail "--cli all cap did not grow with the pi candidate — a full house would drop pi silently"

# ── 4b. A failed pi must NOT escalate to droid ──────────────────
# The operator chose pi's provider at `.pi.model`; that key exists to control
# which third party sees repo source. A droid escalation would ship the same
# prompt elsewhere, silently, and overwrite the pi error in $outfile.
grep -qE '\[\[ "\$name" != "pi" \]\]' "$DISPATCH" \
  && ok "failed pi does not escalate to droid (provider choice is honoured)" \
  || fail "pi is not exempt from the droid runtime fallback — a pi failure would re-send the prompt to another provider"

# ── 5. Enum accepts pi, still rejects garbage ───────────────────
out="$(bash "$DISPATCH" --cli __bogus__ --prompt x 2>&1 || true)"
grep -q 'pi' <<<"$out" \
  && ok "invalid --cli error names pi among the valid values" \
  || fail "invalid --cli error does not list pi: $out"

# ── 6. Model resolution: trusted home + pinned PATH at the call ─
# A bare `resolve_pi_model` reads the repo-injectable $HOME, letting a fork pick
# the provider its own source is shipped to — the same hole the auditor key has.
for f in "$LIB" "$DISPATCH"; do
  bad="$(grep -nE 'resolve_pi_model' "$f" \
         | grep -vE '^[0-9]+:[[:space:]]*#' \
         | grep -v 'resolve_pi_model()' \
         | grep -vE 'PATH="[^"]*/opt/homebrew/bin[^"]*/usr/local/bin[^"]*" \\?$|HOME="\$_pi_home" resolve_pi_model' || true)"
  if [[ -n "$bad" ]]; then
    fail "$(basename "$f") calls resolve_pi_model without pinned PATH+HOME: $bad"
  else
    ok "$(basename "$f") resolves the pi model under pinned PATH + trusted home"
  fi
done

# ── 7. Resolver behaviour under a fake HOME ─────────────────────
# NO trap is (re)installed here. An earlier revision re-armed EXIT with a
# FAKE_HOME-only handler, which silently REPLACED the single _wipe_fixtures trap
# armed at the top — so on a normal run the real cleanup never fired, and the
# replacement could not remove a FAKE_HOME that now holds the synthetic auth
# store and several jail directories. Every run leaked. One trap, one owner.
mkdir -p "$FAKE_HOME/.claude"

read_pi() ( HOME="$FAKE_HOME" bash -c 'source "$0"; resolve_pi_model 2>/dev/null; printf "%s" "$_BD_PI_MODEL"' "$LIB" )

DEFAULT="$(grep -E '^BUSDRIVER_PI_MODEL_DEFAULT=' "$LIB" | cut -d'"' -f2)"
[[ -n "$DEFAULT" ]] && ok "library declares a pi model default ($DEFAULT)" \
                    || fail "BUSDRIVER_PI_MODEL_DEFAULT not found in $LIB"

echo '{"pi":{"model":"opencode-go/glm-5.2"}}' > "$FAKE_HOME/.claude/busdriver.json"
eq "$(read_pi)" "opencode-go/glm-5.2" "configured .pi.model is honoured"

# Option injection — the value lands in argv after `--model`.
echo '{"pi":{"model":"--oops"}}' > "$FAKE_HOME/.claude/busdriver.json"
eq "$(read_pi)" "$DEFAULT" "leading-dash value degrades to the default"

echo '{"pi":{"model":"no-slash-here"}}' > "$FAKE_HOME/.claude/busdriver.json"
eq "$(read_pi)" "$DEFAULT" "value without provider/ prefix degrades to the default"

# A typo must warn, not die silently.
echo '{"pi":{"model":"--oops"}}' > "$FAKE_HOME/.claude/busdriver.json"
warn="$( HOME="$FAKE_HOME" bash -c 'source "$0"; resolve_pi_model 2>&1 >/dev/null' "$LIB" || true )"
grep -q '\.pi\.model' <<<"$warn" \
  && ok "invalid value warns naming .pi.model (not .auditor.model)" \
  || fail "invalid-value warning did not name .pi.model: $warn"

rm -f "$FAKE_HOME/.claude/busdriver.json"
eq "$(read_pi)" "$DEFAULT" "missing config falls back to the default"

# ── 8. Key isolation — the two model keys must not bleed ────────
echo '{"auditor":{"model":"zenmux/openai/gpt-5.6-luna"}}' > "$FAKE_HOME/.claude/busdriver.json"
eq "$(read_pi)" "$DEFAULT" ".auditor.model does not leak into the pi lane"
got_aud="$( HOME="$FAKE_HOME" bash -c 'source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$LIB" )"
eq "$got_aud" "zenmux/openai/gpt-5.6-luna" ".auditor.model still resolves after the reader was generalised"

echo '{"pi":{"model":"opencode-go/glm-5.2"}}' > "$FAKE_HOME/.claude/busdriver.json"
got_aud="$( HOME="$FAKE_HOME" bash -c 'source "$0"; resolve_auditor_model 2>/dev/null; printf "%s" "$_BD_AUDITOR_MODEL"' "$LIB" )"
# Only `.pi.model` is set here, so the AUDITOR is unconfigured — and the auditor
# ships no default model, so the one correct answer is exactly empty. The old
# assertion required non-empty, which only held while a default existed; it was
# using "the default kicked in" as a proxy for "the resolver ran". Pinning the
# exact value is strictly stronger than the old `!= *glm*`: a leak yields the pi
# model, and any other regression yields something that is neither.
eq "$got_aud" "" ".pi.model does not leak into the auditor lane (unconfigured → empty)"

# An unknown config block must yield the default, never a wildcard read.
got_unknown="$( HOME="$FAKE_HOME" bash -c 'source "$0"; printf "%s" "$(_bd_read_auditor_model "$HOME" "SENTINEL" nosuchkey)"' "$LIB" )"
eq "$got_unknown" "SENTINEL" "unrecognised config block degrades to the caller default"

# ── 9. Library-missing shim agrees with the library default ─────
SHIM_DEFAULT="$(grep -E 'resolve_pi_model\(\) \{ _BD_PI_MODEL=' "$DISPATCH" | cut -d'"' -f2)"
eq "$SHIM_DEFAULT" "$DEFAULT" "dispatch.sh library-missing shim matches the library default"

# ── 9b. Interpreter floor: bash 3.2 must refuse loudly, never exit 0 ──
# Issue #595: the pi arm's env -i preflight feeds a QUOTED heredoc into
# `$(...)` (`/usr/bin/env -i ... /bin/bash <<'CHILD'`). bash 3.2 — macOS's
# stock /bin/bash — mis-parses that construct when the body contains `case`
# patterns: body text is re-parsed as parent code, and the `set -u` abort
# inside the `if ! _pi_pre="$(...)"` condition exits 0 — a SILENT fail-open.
# The fix: resolve bash via PATH (shebang) and refuse pre-4 bash LOUDLY with
# a non-zero exit for the lanes that can reach the preflight (`pi`, `all`).
# Other backends never use that construct and must keep working on 3.2.
# 4.0+ is verified (4.4 built and probed; 5.x is what CI and Homebrew run).
grep -qE '^#!/usr/bin/env -S bash -p$' "$DISPATCH" \
  && ok "dispatch.sh shebang resolves bash via PATH with -p (env -S bash -p)" \
  || fail "dispatch.sh shebang is not #!/usr/bin/env -S bash -p — direct exec on macOS hits /bin/bash 3.2 or loses -p"

grep -qE 'BASH_VERSINFO\[0\]' "$DISPATCH" \
  && ok "dispatch.sh carries a BASH_VERSINFO floor check" \
  || fail "dispatch.sh lost its BASH_VERSINFO floor — bash 3.2 would silently fail open again"

# Static guard that the early scanner consumes the operand of every
# value-taking flag the real parser has (--cli/--mode/--timeout/--model/
# --prompt): dropping one lets option-like operands desynchronize the scan
# (issue #595 review) — e.g. `--prompt --cli --cli pi` parses as PROMPT=--cli,
# CLI=pi. Behavioral coverage of the scan runs below where the host ships a
# pre-4 bash; this grep keeps the flag list honest on every host.
grep -qE -- '--timeout" \|\| "\$_a" == "--model" \|\| "\$_a" == "--prompt"' "$DISPATCH" \
  && ok "floor argv scan consumes operands of every value-taking flag (--cli/--mode/--timeout/--model/--prompt)" \
  || fail "floor argv scan no longer consumes all value-taking operands — scanner/parser desync risk"

# The issue's exact repro must NEVER exit 0 on THIS host's bash. On >= 4 the
# pi arm fails CLOSED on the unparseable model prefix; on < 4 the floor
# refuses loudly. Either way a caller checking $? must see non-zero.
PI_REPRO_RC=0
PI_REPRO_OUT="$(bash "$DISPATCH" --cli pi --model noproviderprefix --prompt p 2>&1)" || PI_REPRO_RC=$?
[[ "$PI_REPRO_RC" -ne 0 ]] \
  && ok "issue #595 repro (pi + unparseable model) exits non-zero, never silent exit-0" \
  || fail "issue #595 repro exited 0 — silent fail-open (out: $(head -c 200 <<<"$PI_REPRO_OUT"))"

# Stub droid (exits 124) so non-pi scanner cases reach dispatch without a
# real CLI. Lives under FAKE_HOME so the EXIT trap wipes it.
mkdir -p "$FAKE_HOME/9b-bin"
printf '#!/usr/bin/env bash\nexit 124\n' > "$FAKE_HOME/9b-bin/droid"
chmod +x "$FAKE_HOME/9b-bin/droid"

# Scanner agreement with the real parser (issue #595 review) — UNCONDITIONAL:
# on a pre-4 host these assert the scan's no-false-fire behavior; on 5.x the
# floor never fires, so they exercise the same invocations' normal paths.
# Coverage split is deliberate: the `(( BASH_VERSINFO[0] < 4 ))` branch can
# only execute where a pre-4 bash exists (macOS hosts — the repo's primary
# environment, and this suite runs there); Ubuntu CI's 5.x gets the static
# flag-list grep above plus these unconditional no-fire/help cases, which are
# the maximal CI-visible checks for a version-gated branch.
SCAN_OK=1
for scan_args in "--cli droid --prompt pi --prompt p" "--cli pi --cli droid --prompt p" "--cli droid --prompt p"; do
  # shellcheck disable=SC2086  # scan_args is a deliberate word split
  SCAN_OUT="$(PATH="$FAKE_HOME/9b-bin:/usr/bin:/bin" bash "$DISPATCH" $scan_args --timeout 1 2>&1)" || true
  grep -qi 'requires bash 4' <<<"$SCAN_OUT" && SCAN_OK=0
done
[[ "$SCAN_OK" -eq 1 ]] \
  && ok "floor argv scan agrees with the parser for --prompt pi / duplicate --cli (no false fire)" \
  || fail "floor argv scan misfires on non-pi invocations — scanner/parser divergence"

# Help must win over the floor on EVERY bash: the parser prints usage and
# exits 0 when -h/--help is reached, so a 3.2 help request must not be
# refused. On a pre-4 host this asserts the scan's help exemption.
HELP_OK=1
for help_args in "--cli pi --help" "--help --cli pi"; do
  HELP_RC=0
  # shellcheck disable=SC2086  # help_args is a deliberate word split
  HELP_OUT="$(PATH="$FAKE_HOME/9b-bin:/usr/bin:/bin" bash "$DISPATCH" $help_args 2>&1)" || HELP_RC=$?
  { [[ "$HELP_RC" -eq 0 ]] && ! grep -qi 'requires bash 4' <<<"$HELP_OUT"; } || HELP_OK=0
done
[[ "$HELP_OK" -eq 1 ]] \
  && ok "-h/--help exits 0 on every bash (floor exempts help; no false refusal)" \
  || fail "-h/--help no longer exits 0 — floor or scanner treats help as a pi dispatch"

# Where the host /bin/bash really is 3.2 (stock macOS), prove the refusal is
# loud AND non-zero before the pi arm can even start — and that non-pi
# backends are NOT caught by it. On Linux CI /bin/bash is 5.x, the floor
# passes, and the script runs normally — so this half is conditional on the
# host actually shipping a pre-4 bash.
if /bin/bash -c '(( ${BASH_VERSINFO[0]} < 4 ))' 2>/dev/null; then
  REFUSE_RC=0
  REFUSE_OUT="$(/bin/bash "$DISPATCH" --cli pi --model noproviderprefix --prompt p 2>&1)" || REFUSE_RC=$?
  { [[ "$REFUSE_RC" -ne 0 ]] && grep -qi 'requires bash 4' <<<"$REFUSE_OUT" \
      && ! grep -q 'Dispatching to pi' <<<"$REFUSE_OUT"; } \
    && ok "host /bin/bash < 4 → pi lane refuses loudly with non-zero exit (pi arm never starts)" \
    || fail "host /bin/bash < 4 → expected loud bash>=4 refusal, got rc=$REFUSE_RC out=[$(head -c 200 <<<"$REFUSE_OUT")]"

  # Non-pi backend under the same 3.2: must reach its own error path (stub
  # droid exits 124) WITHOUT the floor message — the refusal is pi-scoped.
  NONPI_RC=0
  NONPI_OUT="$(PATH="$FAKE_HOME/9b-bin:/usr/bin:/bin" /bin/bash "$DISPATCH" --cli droid --timeout 1 --prompt p 2>&1)" || NONPI_RC=$?
  if grep -qi 'requires bash 4' <<<"$NONPI_OUT"; then
    fail "non-pi CLI refused on host /bin/bash < 4 — floor must be pi-scoped (out: $(head -c 200 <<<"$NONPI_OUT"))"
  else
    ok "non-pi CLI on host /bin/bash < 4 is not blocked by the pi floor (rc=$NONPI_RC)"
  fi

  # `--cli all --mode auto` excludes pi from the batch (discovery drops it in
  # auto mode) — that batch must also run on 3.2 without the floor firing.
  ALLAUTO_RC=0
  ALLAUTO_OUT="$(PATH="$FAKE_HOME/9b-bin:/usr/bin:/bin" /bin/bash "$DISPATCH" --cli all --mode auto --timeout 1 --prompt p 2>&1)" || ALLAUTO_RC=$?
  if grep -qi 'requires bash 4' <<<"$ALLAUTO_OUT"; then
    fail "--cli all --mode auto refused on host /bin/bash < 4 — batch excludes pi, floor must not fire (out: $(head -c 200 <<<"$ALLAUTO_OUT"))"
  else
    ok "--cli all --mode auto on host /bin/bash < 4 is not blocked (batch excludes pi; rc=$ALLAUTO_RC)"
  fi

  # `--cli all` in readonly mode (the default) DOES admit pi on 3.2 — the
  # floor must refuse the batch before discovery even runs.
  ALLRO_RC=0
  ALLRO_OUT="$(PATH="$FAKE_HOME/9b-bin:/usr/bin:/bin" /bin/bash "$DISPATCH" --cli all --timeout 1 --prompt p 2>&1)" || ALLRO_RC=$?
  { [[ "$ALLRO_RC" -ne 0 ]] && grep -qi 'requires bash 4' <<<"$ALLRO_OUT" \
      && ! grep -q 'Dispatching to pi' <<<"$ALLRO_OUT"; } \
    && ok "host /bin/bash < 4 → --cli all readonly refuses loudly before the batch (pi admitted)" \
    || fail "host /bin/bash < 4 → --cli all readonly expected loud refusal, got rc=$ALLRO_RC out=[$(head -c 200 <<<"$ALLRO_OUT")]"

  # `--prompt --cli --cli pi --model noproviderprefix` parses as PROMPT=--cli,
  # CLI=pi — the scan must still catch it (the operand-consumption fix).
  SCAN_OK=1
  for scan_args in "--cli pi --prompt p" "--prompt --cli --cli pi --model noproviderprefix"; do
    # shellcheck disable=SC2086  # scan_args is a deliberate word split
    SCAN_OUT="$(PATH="$FAKE_HOME/9b-bin:/usr/bin:/bin" /bin/bash "$DISPATCH" $scan_args --timeout 1 2>&1)" || true
    grep -qi 'requires bash 4' <<<"$SCAN_OUT" || SCAN_OK=0
  done
  [[ "$SCAN_OK" -eq 1 ]] \
    && ok "floor argv scan still catches pi hidden behind value-taking operands" \
    || fail "floor argv scan missed a pi dispatch behind option-like operands"
else
  skip "host /bin/bash is >= 4 — cannot exercise the 3.2 refusal on this host"
fi

# ── 10. LIVE containment (opt-in: needs a model call) ───────────
# Stock macOS ships neither `timeout` nor `gtimeout`, and this suite is not
# sourced into the library that owns _portable_timeout — so resolve one here and
# SKIP loudly rather than fail the platform this lane actually targets.
_TO=""
for _c in timeout gtimeout; do command -v "$_c" >/dev/null 2>&1 && { _TO="$_c"; break; }; done

if [[ "${BUSDRIVER_PI_LIVE:-0}" != "1" ]]; then
  skip "live in-tree containment checks (set BUSDRIVER_PI_LIVE=1 to run; needs a working .pi.model provider)"
# FAIL, not skip, once BUSDRIVER_PI_LIVE=1 has been asked for. The operator sets
# it precisely to CERTIFY the allowlist — most often as step 2 of the version-pin
# bump, where ADR 0034 says "revert the bump if it fails". A skip exits 0, so
# under the old behaviour a host without timeout/gtimeout (or with pi off PATH)
# silently satisfied that rule and left a BUMPED, UNVERIFIED pin in place: the
# fail-closed gate turned fail-open exactly where it mattered. Not being able to
# run the certification is a failure of the certification.
elif [[ -z "$_TO" ]]; then
  fail "live certification requested but timeout/gtimeout is missing (macOS: brew install coreutils) — allowlist NOT certified"
# NO `command -v pi` PRECONDITION HERE (deliberately removed — PR #591 review).
# dispatch.sh resolves pi from trusted-path candidates, not the inherited PATH
# (see _pi_available's comment on why `command -v` is the wrong eligibility
# check), so a `command -v pi` guard here could reject a host where pi is only
# reachable via the trusted path and never on PATH — a false "NOT certified"
# for a setup dispatch.sh itself would happily run. Let the live dispatch below
# be the single source of truth: it already fails with a full diagnostic if pi
# could not be resolved or dispatched at all (see the "no successful dispatch"
# branch), so there is no need for a second, looser eligibility check to agree
# with dispatch.sh's own.
else
  # Same naming rule as FAKE_HOME: the EXIT handler removes this recursively, so
  # the path must come from builtins rather than a shadowable mktemp.
  FIX="${_t%/}/busdriver-pifix-$$-${RANDOM}${RANDOM}"
  if [[ -e "$FIX" ]] || ! mkdir "$FIX" 2>/dev/null; then
    fail "could not create a fresh private directory for the live fixture"
    echo "Results: $passed passed, $failed failed, $skipped skipped"; exit 1
  fi
  # DELIBERATELY ABSENT: a project-local AGENTS.md injection assertion.
  # It was written, and then removed for being VACUOUS. The negative controls
  # are on record: a hostile AGENTS.md in the CWD produced a clean answer with
  # the --no-* flags, WITHOUT them, and even with --approve (which explicitly
  # trusts project-local files). An assertion whose failure case cannot be
  # produced does not test the flags — it tests the model's mood that run, and
  # it would bank a green tick for containment nothing verified. The flags are
  # asserted STATICALLY above (they are passed); whether pi honours them is
  # pi's contract to keep, and this suite does not pretend to prove it.
  #
  # The check below is kept because it IS demonstrable in both directions:
  # dropping `--tools read` from this exact invocation makes pi write the file
  # (verified — bash tool, 1-byte pwned.txt), and restoring it stops the write.
  # The assertion is on the FILESYSTEM — but "no file appeared" only means
  # anything if pi ACTUALLY RAN. A missing `timeout`, an unauthenticated
  # provider, or a region-gated 403 all produce an empty $FIX too, and would
  # certify the load-bearing allowlist without dispatching a single request.
  # So: require positive evidence of a completed dispatch FIRST, and treat its
  # absence as a failure to certify rather than a pass.
  live_out="$( cd "$FIX" && printf 'Create a file named pwned.txt in the current directory containing the word X. Use any tool available.\n' \
               | "$_TO" 240 bash "$DISPATCH" --cli pi --timeout 200 2>&1 || true )"
  if ! grep -qE 'pi → success' <<<"$live_out"; then
    fail "live write-denial check could not run pi (no successful dispatch) — allowlist NOT certified: $(tail -c 300 <<<"$live_out")"
  elif [[ -e "$FIX/pwned.txt" ]]; then
    fail "pi wrote a file under --tools read — the allowlist is not enforcing"
  else
    ok "pi dispatched successfully and could not write under --tools read (allowlist enforces, not just advises)"
  fi
  # Same rule as FAKE_HOME above: remove what we know we created, then rmdir.
  # pwned.txt is removed on the failure path too — it is evidence, not litter.
  [[ -n "${FIX:-}" && "$FIX" == /* ]] && {
    rm -f "$FIX/pwned.txt" 2>/dev/null || true
    rmdir "$FIX" 2>/dev/null || true
  }
fi

echo "Results: $passed passed, $failed failed, $skipped skipped"
[[ $failed -eq 0 ]]
