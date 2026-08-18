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
    # #692 gap 1: a bare earliest-mention search is fooled by negation —
    # "do NOT bump this constant yet. First run BUSDRIVER_PI_LIVE=1 ..., then
    # bump it." has "bump" precede BUSDRIVER_PI_LIVE, so the old order test
    # passed even though the actual instruction is reversed. first_valid_pos()
    # walks every occurrence of a token (not just the first) and discards any
    # whose enclosing clause (bounded by "." on each side, capped at 150
    # chars) reads as a negation, apostrophes stripped so "don't"/"doesn't"
    # match the same as "do not" — taking the earliest occurrence that
    # survives that filter. A bump mention that is entirely negated is
    # treated the same as no bump mention at all. This is a bounded
    # heuristic, not a parser: it defends against comment wording drifting
    # out of sync with the code (the failure mode #692 actually reproduced),
    # not against deliberately adversarial prose constructed to defeat it.
    #
    # Nine commit-mode review rounds (#692 follow-up) tried widening this
    # into a parser that tracks WHICH verb or clause a negation governs —
    # semicolon transparency, an intervening-verb cut, coordinated-verb
    # unwinding, infinitive gaps, colon-terminated lists, stacked adverbial
    # modifiers. Each fix closed one adversarial construction and the next
    # review round produced another; the design was unbounded because
    # English negation is unbounded. first_valid_pos() below is the
    # reverted, narrow version: a negation word ANYWHERE in the same
    # period-bounded clause rejects the mention, full stop — no
    # semicolon/colon boundary, no verb-scoping, no coordination tracking.
    # This can false-REJECT prose that uses a negation word about something
    # else in the same sentence; that is the safe direction (a false reject
    # just needs a comment reworded, a false accept is the #692 outage
    # class), and every real protected comment in this repo already keeps
    # its bump instruction in a clause with no other negation word — see
    # dispatch.sh's two PI_RITUAL_SITE anchors and ADR 0034's "Fail-closed
    # version pin" bullet.
    awk '
        # comment lines only: an adjacent code line must never satisfy a concept
        /^[[:space:]]*#/ { c = $0; sub(/^[[:space:]]*#[[:space:]]?/, "", c); buf[NR] = c; next }
        { buf[NR] = "" }        # code line → empty, so windows cannot borrow from it
        function first_valid_pos(text, tok,    p, idx, from, cs, ce, k, clause, neg) {
            text = tolower(text)   # case-insensitive token/clause search throughout
            tok = tolower(tok)     # TOK must be lowercased too, or an uppercase-only synonym
                                    # like BUSDRIVER_PI_PROBED_VERSION could never match the
                                    # already-lowercased text
            from = 1
            while (1) {
                idx = index(substr(text, from), tok)
                if (idx == 0) return 0
                p = from + idx - 1
                from = p + length(tok)
                # Word-boundary check (PR-mode review): plain substring matching
                # also matches "bump" inside "bumping"/"bumper" -- skip anything
                # that is not a whole word, without counting it as a candidate.
                if (substr(text, p - 1, 1) ~ /[a-z0-9_]/ || substr(text, p + length(tok), 1) ~ /[a-z0-9_]/) continue
                # Clause boundary: nearest "." on each side, capped at 150 chars so an
                # unterminated sentence cannot pull in an unrelated earlier/later thought.
                # A "." immediately followed by a letter/digit is a filename extension
                # or version-number separator ("release.sh", "0.84.2"), not a sentence
                # boundary (PR-mode review finding).
                cs = (p - 150 > 1 ? p - 150 : 1)
                for (k = p - 1; k >= cs; k--) {
                    if (substr(text, k, 1) == "." && substr(text, k + 1, 1) !~ /[a-z0-9]/) { cs = k + 1; break }
                }
                ce = (p + length(tok) + 150 <= length(text) ? p + length(tok) + 150 : length(text))
                for (k = p + length(tok); k <= ce; k++) {
                    if (substr(text, k, 1) == "." && substr(text, k + 1, 1) !~ /[a-z0-9]/) { ce = k - 1; break }
                }
                clause = " " substr(text, cs, ce - cs + 1) " "
                gsub(/[\x27\x60]/, "", clause)   # apostrophe/backtick contractions fold to dont, wont, etc.
                gsub(/[,;:!?]/, " ", clause)      # "not," must still match " not " as a whole word
                # Any whole-word negation trigger ANYWHERE in the period-bounded clause
                # rejects the mention -- including bare "no", folded in here rather than
                # kept as a separate adjacency-only special case (an adjacency-only "no"
                # check is what let "Under no circumstances bump this constant" slip
                # through as a false ACCEPT: "no" was never adjacent to "bump"). This can
                # false-REJECT a bump instruction that shares a clause with an unrelated
                # "no"/"not" about something else ("bump this constant with no other
                # changes" now reads as negated); that is the safe direction -- a false
                # reject just needs a comment reworded, a false accept is the #692 outage
                # class.
                neg = (clause ~ / (no|not|never|cannot|cant|wont|dont|couldnt|wouldnt|isnt|arent|wasnt|werent|hasnt|hadnt|havent|shouldnt|didnt|doesnt|mustnt|neednt|avoid|refrain|without) /)
                if (!neg) return p
            }
        }
        END {
            seen = 0; bad = 0; m = 0
            for (i = 1; i <= NR; i++) if (buf[i] ~ /BUSDRIVER_PI_LIVE/) { m++; mentions[m] = i }
            for (mi = 1; mi <= m; mi++) {
                i = mentions[mi]
                seen++
                prev_line = (mi > 1 ? mentions[mi - 1] : 0)
                next_line = (mi < m ? mentions[mi + 1] : NR + 1)
                w = ""; li = 0
                lo = (i - 8 < 1 ? 1 : i - 8); hi = i + 3
                if (lo <= prev_line) lo = prev_line + 1
                if (hi >= next_line) hi = next_line - 1
                for (j = lo; j <= hi; j++) {
                    piece = " " buf[j]
                    if (j == i) li = length(w) + 1
                    w = w piece
                }
                live = index(substr(w, li), "BUSDRIVER_PI_LIVE")
                if (live > 0) live = live + li - 1
                bump = 0
                # earliest NON-NEGATED mention of the literal word "bump".
                # Deliberately just "bump", not a noun-phrase/constant-name
                # synonym -- an earlier version also matched bare "this
                # constant"/"the constant" and the constants own name, but
                # those are nouns any verb can govern ("verify this constant"
                # / "verify BUSDRIVER_PI_PROBED_VERSION" satisfied the concept
                # just as well as "bump this constant" would have, defeating
                # the entire point of this guard -- PR-mode review, #692
                # follow-up). All three real ritual comments this guard
                # protects use the literal word "bump", so nothing is lost.
                # _ritual_prose_check already made this same call for ADR
                # prose; this matches it.
                p = first_valid_pos(w, "bump")
                if (p > 0) bump = p
                if (bump == 0)      { bad++; good = 0; print "  (line " i ": names the live test but never a non-negated bump)" > "/dev/stderr" }
                else if (bump > live) { bad++; good = 0; print "  (line " i ": names the live test BEFORE the bump — deadlocks)" > "/dev/stderr" }
                else { good = 1 }
                print "MENTION " i " " (good ? "good" : "bad") > "/dev/stderr"
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

# #692 gap 1 negative fixture: negation bypass. The earliest-mention search used
# to accept this because "bump" textually precedes BUSDRIVER_PI_LIVE, even
# though the actual instruction is reversed — the only valid (non-negated) bump
# mention is the SECOND one, which comes after the live-test mention.
_ritual_negation_fixture='
# do NOT bump this constant yet. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by negation — \"do NOT bump\" satisfies the bump concept because it textually precedes the live-test mention"
else
    ok "ritual guard rejects a negated bump mention (proven able to fail on issue #692's reproduction)"
fi

# Trailing negation: the negation word comes AFTER the bump token in the same
# clause ("a bump is not required"), which a preceding-only window would miss
# entirely (litmus review on #692).
_ritual_trailing_negation_fixture='
# A bump is not required. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_trailing_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by TRAILING negation — \"is not required\" after the token is invisible to a preceding-only scan"
else
    ok "ritual guard rejects a trailing-negation bump mention (negation after the token, same clause)"
fi

# Long preceding negation: more than a fixed 40-char window separates the
# negation word from the token, but both are still in the same sentence
# (litmus review on #692).
_ritual_long_negation_fixture='
# Do not, under any circumstances during a live audit window, bump this
# constant casually. First run BUSDRIVER_PI_LIVE=1
# tests/test-pi-dispatch-arm.sh, then bump it for real.
'
if _ritual_check <<<"$_ritual_long_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard misses a negation more than 40 chars before the token, still in the same sentence"
else
    ok "ritual guard rejects a long-distance same-sentence negation"
fi

# "without" is a real negation word the earlier finite list omitted (litmus
# review on #692): "Without bumping this constant, first run
# BUSDRIVER_PI_LIVE=1 ..., then bump it" still has an earlier, unnegated-by-
# the-old-list "bump" mention that textually precedes the live-test mention.
_ritual_without_negation_fixture='
# Without bumping this constant, first run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_without_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by \"without\" negation — the finite word list omitted it"
else
    ok "ritual guard rejects a \"without\"-negated bump mention"
fi

# "no"/"cannot" are also real negation words PR-mode review found the list
# still omitted: "No bump is required. Run BUSDRIVER_PI_LIVE=1 ..." and
# "Bumping cannot happen here. Run BUSDRIVER_PI_LIVE=1 ..." both leave an
# unnegated-by-the-old-list "bump"/"Bumping" mention preceding the live-test
# mention (note: "Bumping" does not match the bare "bump" token search, so
# this fixture instead uses the same "bump" wording with "cannot" to isolate
# the negation-word gap specifically, matching the "no" fixture's shape).
_ritual_no_cannot_negation_fixture='
# No bump is required here — this comment merely mentions
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh in passing.
'
if _ritual_check <<<"$_ritual_no_cannot_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by \"no\" negation — the word list omitted it"
else
    ok "ritual guard rejects a \"no\"-negated bump mention"
fi

_ritual_cannot_negation_fixture='
# You cannot bump this constant here. Run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it for real.
'
if _ritual_check <<<"$_ritual_cannot_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by \"cannot\" negation — the word list omitted it"
else
    ok "ritual guard rejects a \"cannot\"-negated bump mention"
fi

# Negation ~118 chars from the token in an unterminated sentence (no period
# appears anywhere before "bump"): a bare fixed cap first tried at 80 chars
# was too tight for this shape (PR-mode review), and removing the cap
# entirely was then its own defect -- an unrelated, unterminated EARLIER
# sentence could bleed into a later valid instruction with no bound at all
# (commit-mode review, round 2). The cap is restored at 150: measured
# headroom above this fixture's ~118-char distance, so the legitimate
# long-distance case still passes while the scan stays bounded.
_ritual_very_long_negation_fixture='
# Operators must not, under any circumstances, for any reason, during any
# release cycle, regardless of urgency or operator preference, bump this
# constant casually without following the full ritual. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it for real.
'
if _ritual_check <<<"$_ritual_very_long_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard misses a negation ~118 chars before the token, still in the same unterminated sentence"
else
    ok "ritual guard rejects a long-distance same-sentence negation within the 150-char cap"
fi

# Negative fixture (redesign, #692 follow-up): the redesigned guard folds
# bare "no" into the whole-clause negation list rather than keeping a
# separate adjacency-only special case (see first_valid_pos()) -- an
# adjacency-only "no" check is what let "Under no circumstances bump this
# constant" slip through as a false ACCEPT (see the fixture below). The
# tradeoff is that an incidental "no" elsewhere in the same clause, as here,
# now false-rejects too. That is the accepted, safe-direction cost: a false
# reject just needs a comment reworded, a false accept is the #692 outage
# class.
_ritual_no_incidental_fixture='
# bump this constant with no other changes, then run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_no_incidental_fixture" >/dev/null 2>&1; then
    fail "ritual guard accepts a clause containing an incidental \"no\" -- the whole-clause \"no\" list should reject it"
else
    ok "ritual guard rejects a clause containing an incidental \"no other changes\" phrasing (accepted false-reject tradeoff)"
fi

# Negative fixture (redesign, #692 follow-up): proves the gap the
# adjacency-only "no" check actually had -- "no" separated from the token by
# other words was invisible to it. The whole-clause list closes this.
_ritual_under_no_circumstances_fixture='
# Under no circumstances bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_under_no_circumstances_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by \"under no circumstances\" -- \"no\" is not adjacent to the token, and an adjacency-only check misses it"
else
    ok "ritual guard rejects a bump instruction negated by \"under no circumstances\" (no adjacent to the token)"
fi

# Negative fixture (commit-mode review, round 3): an arbitrary run of
# whitespace between "No" and the token must still count as adjacency -- a
# fixed 6-char lookback missed "No" once padded with extra spaces.
_ritual_wide_no_fixture='
# No          bump is scheduled. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_wide_no_fixture" >/dev/null 2>&1; then
    fail "ritual guard misses a \"No\" negation separated from the token by extra whitespace"
else
    ok "ritual guard rejects a \"No\"-negated bump mention across a wide whitespace run"
fi

# Positive fixture (commit-mode review, round 3): "no" must only match as a
# whole word immediately before the token, never mid-word -- "casino bump"
# is not a negation.
_ritual_no_midword_fixture='
# Run the casino bump migration, then run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_no_midword_fixture" >/dev/null 2>&1; then
    ok "ritual guard does not treat a mid-word \"no\" (\"casino\") as negating the token"
else
    fail "ritual guard false-rejects \"casino bump\" by matching \"no\" mid-word"
fi

# Negative fixture (redesign, #692 follow-up): the redesigned guard rejects
# ANY negation word in the same period-bounded clause, without trying to
# work out which verb it governs -- "Do not edit the provider list" and
# "bump this constant" share a clause (comment lines concatenate with no
# sentence boundary between them, and there is no period here), so this now
# correctly reports as a false reject rather than the accept it used to be.
# Accepted safe-direction cost, same as the incidental-"no" fixture above.
_ritual_unrelated_negation_fixture='
# Do not edit the provider list
# bump this constant, then run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_unrelated_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard accepts a bump instruction sharing an unpunctuated clause with an unrelated negated verb -- the whole-clause negation check should reject it"
else
    ok "ritual guard rejects a bump instruction sharing an unpunctuated clause with an unrelated negated verb (accepted false-reject tradeoff)"
fi

# Negative fixture (redesign, #692 follow-up): the redesigned guard treats
# only "." as a clause boundary, not ":" -- "cannot" and "bump this
# constant" now share a clause across the colon, so this correctly rejects
# rather than requiring machinery to prove the colon separates two topics.
# Accepted false-reject tradeoff, same reasoning as the two fixtures above.
_ritual_colon_boundary_fixture='
# This cannot wait: bump this constant, then run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_colon_boundary_fixture" >/dev/null 2>&1; then
    fail "ritual guard accepts a bump instruction sharing a colon-joined clause with an unrelated negation -- \".\" is the only clause boundary now"
else
    ok "ritual guard rejects a bump instruction sharing a colon-joined clause with an unrelated negation (accepted false-reject tradeoff)"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): still correctly rejected under the whole-clause check -- "."
# is the only clause boundary, so "not" reaches "bump" through the colon.
_ritual_list_colon_fixture='
# Do not follow this sequence: bump this constant, then run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_list_colon_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a list-introducing colon — \"do not follow this sequence:\" still negates the bump it introduces"
else
    ok "ritual guard rejects a negated bump introduced by a colon-delimited list"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): still correctly rejected -- "not" and "bump" share the same
# period-bounded clause regardless of the coordinating conjunction.
_ritual_coordinated_verb_fixture='
# Do not edit or bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_coordinated_verb_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a coordinated verb (\"edit or bump\") — accepts the earlier, still-negated bump"
else
    ok "ritual guard rejects a negated bump reached through a coordinating conjunction"
fi

# Positive fixture (commit-mode review, round 4): the token search was
# case-sensitive, so a grammatically ordinary sentence-initial "Bump this
# constant..." was silently missed once the earlier "this constant"/"the
# constant" fallback (narrowed away as a vacuity, see the wrong-verb fixture
# below) stopped incidentally covering it.
_ritual_capitalized_bump_fixture='
# Bump this constant, then run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_capitalized_bump_fixture" >/dev/null 2>&1; then
    ok "ritual guard recognises a sentence-initial capitalized \"Bump\" as the token"
else
    fail "ritual guard misses a valid bump instruction because \"Bump\" is capitalized (case-sensitive token search)"
fi

# Regression fixtures (retained from pre-redesign negation-tracking
# machinery): comma/wide-space/multi-verb conjunction variants, all still
# correctly rejected -- "not" and "bump" share the same clause regardless.
_ritual_coordinated_comma_fixture='
# Do not edit, or bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_coordinated_comma_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a comma-separated coordinated verb (\"edit, or bump\")"
else
    ok "ritual guard rejects a negated bump reached through a comma-separated coordinating conjunction"
fi

_ritual_coordinated_wide_space_fixture='
# Do not edit  or bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_coordinated_wide_space_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a wide-whitespace coordinated verb (\"edit  or bump\")"
else
    ok "ritual guard rejects a negated bump reached through a wide-whitespace coordinating conjunction"
fi

_ritual_coordinated_chain_fixture='
# Do not edit or verify and bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_coordinated_chain_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a multi-verb coordinated chain (\"edit or verify and bump\")"
else
    ok "ritual guard rejects a negated bump reached through a multi-verb coordinating chain"
fi

# Negative fixture (redesign, #692 follow-up): "." is the only clause
# boundary now, not ";" -- "cannot" reaches back across the semicolon to
# negate the bump the same way it would across a comma. Accepted
# false-reject tradeoff, same reasoning as the fixtures above.
_ritual_semicolon_scope_fixture='
# Bump this constant; the old binary cannot be trusted, so then run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_semicolon_scope_fixture" >/dev/null 2>&1; then
    fail "ritual guard accepts a bump instruction sharing a semicolon-joined clause with an unrelated negation -- \".\" is the only clause boundary now"
else
    ok "ritual guard rejects a bump instruction sharing a semicolon-joined clause with an unrelated negation (accepted false-reject tradeoff)"
fi

# Negative fixture (commit-mode review, round 6): a semicolon can directly
# qualify the preceding clause with a negation, the opposite of the fixture
# above -- treating every forward semicolon as a hard boundary (round 5) let
# an explicit live-first negation become invisible, a real negation bypass.
# "not" is the first word after the semicolon here, so the guard must keep
# scanning across it rather than stopping there.
_ritual_semicolon_negation_fixture='
# Bump this constant; not before running
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_semicolon_negation_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a semicolon hiding a negation that directly qualifies the preceding clause (\"; not before running\")"
else
    ok "ritual guard rejects a bump instruction directly negated across a semicolon"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): still correctly rejected -- "not" and the constant name share
# the same clause.
_ritual_verb_governs_token_fixture='
# Do not set BUSDRIVER_PI_PROBED_VERSION. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_verb_governs_token_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a verb whose direct object is the token itself (\"do not set BUSDRIVER_PI_PROBED_VERSION\")"
else
    ok "ritual guard rejects a negated constant-name mention where the verb directly governs the token"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): tab-separated conjunction variant, still correctly rejected.
_ritual_coordinated_tab_fixture=$(printf '%s\n' \
    $'# Do not edit\tor bump this constant. First run' \
    '# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.')
if _ritual_check <<<"$_ritual_coordinated_tab_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a tab-separated coordinated verb (\"edit\\tor bump\")"
else
    ok "ritual guard rejects a negated bump reached through a tab-separated coordinating conjunction"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): still correctly rejected -- "." is the only clause boundary,
# so "not" reaches the constant name through the verb and colon.
_ritual_verb_list_colon_fixture='
# Do not update the following: BUSDRIVER_PI_PROBED_VERSION. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_verb_list_colon_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a listed verb introducing a colon-delimited list (\"do not update the following: BUSDRIVER_PI_PROBED_VERSION\")"
else
    ok "ritual guard rejects a negated constant-name mention introduced by a listed verb's colon-delimited list"
fi

# Negative fixture (commit-mode review, round 8): a coordinating conjunction
# does not have to sit immediately after the cut verb -- an intervening noun
# phrase can separate them, and the coordination still reaches the bump.
_ritual_coordinated_noun_phrase_fixture='
# Do not edit the provider list or bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_coordinated_noun_phrase_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a coordinating conjunction separated from the cut verb by a noun phrase (\"edit the provider list or bump\")"
else
    ok "ritual guard rejects a negated bump coordinated through a conjunction separated by an intervening noun phrase"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): still correctly rejected -- "not" and "bump" share the clause.
_ritual_infinitive_gap_fixture='
# Do not start to bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_infinitive_gap_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a bare infinitive marker between a listed verb and the token (\"start to bump\")"
else
    ok "ritual guard rejects a negated bump instruction separated from its governing verb by only a bare infinitive marker"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): still correctly rejected -- "." is the only clause boundary,
# so "not" reaches "bump" across the semicolon.
_ritual_semicolon_modifier_fixture='
# Bump this constant; absolutely not before running
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_semicolon_modifier_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by an adverbial modifier hiding a negation right after a semicolon (\"; absolutely not before running\")"
else
    ok "ritual guard rejects a bump instruction negated across a semicolon by a modifier-qualified negation word"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): stacked-modifier variant, still correctly rejected.
_ritual_semicolon_stacked_modifier_fixture='
# Bump this constant; please absolutely not before running
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
'
if _ritual_check <<<"$_ritual_semicolon_stacked_modifier_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by stacked adverbial modifiers hiding a negation right after a semicolon (\"; please absolutely not before running\")"
else
    ok "ritual guard rejects a bump instruction negated across a semicolon by stacked modifiers before the negation word"
fi

# Regression fixture (retained from pre-redesign negation-tracking
# machinery): "let alone" coordination, still correctly rejected -- "not"
# and "bump" share the same clause regardless of the conjunction wording.
_ritual_let_alone_fixture='
# Do not edit, let alone bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_let_alone_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a \"let alone\" coordination (\"edit, let alone bump\")"
else
    ok "ritual guard rejects a negated bump coordinated through \"let alone\""
fi

# Negative fixture (PR-mode review, #692 follow-up): substring matching
# alone also matches "bump" inside "bumping"/"bumper" -- a comment naming
# the concept without instructing it must not satisfy the guard.
_ritual_substring_word_fixture='
# Bumping is optional here. First run BUSDRIVER_PI_LIVE=1
# tests/test-pi-dispatch-arm.sh, and a bumper plate is not required.
'
if _ritual_check <<<"$_ritual_substring_word_fixture" >/dev/null 2>&1; then
    fail "ritual guard matches \"bump\" as a substring of \"bumping\"/\"bumper\" instead of requiring a whole word"
else
    ok "ritual guard requires a whole-word \"bump\", not a substring match inside a longer word"
fi

# Negative fixture (PR-mode review, #692 follow-up): a "." immediately
# followed by a letter or digit is a filename extension or version-number
# separator, not a clause boundary -- the period in "release.sh" must not
# hide the "not" on the other side of it from "bump".
_ritual_filename_dot_fixture='
# Do not update release.sh or bump this constant yet. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_check <<<"$_ritual_filename_dot_fixture" >/dev/null 2>&1; then
    fail "ritual guard treats the period in a filename (release.sh) as a clause boundary and misses the negation on the other side of it"
else
    ok "ritual guard does not treat a filename period (release.sh) as a clause boundary"
fi

# Negative fixture (PR-mode review, #692 follow-up): the negation word list
# omitted several ordinary contractions (couldnt/wouldnt/isnt/hasnt and
# siblings, after apostrophe stripping).
_ritual_contraction_fixture='
# You couldnt bump this constant now. First run BUSDRIVER_PI_LIVE=1
# tests/test-pi-dispatch-arm.sh, then bump it for real.
'
if _ritual_check <<<"$_ritual_contraction_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by the contraction couldnt -- the negation list omitted it"
else
    ok "ritual guard rejects a bump negated by the contraction couldnt"
fi

# Negative fixture (commit-mode review, #692 follow-up round 2): "havent"
# was also missing from the same list.
_ritual_havent_fixture='
# You havent been authorized to bump this constant. First run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it for real.
'
if _ritual_check <<<"$_ritual_havent_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by the contraction havent -- the negation list omitted it"
else
    ok "ritual guard rejects a bump negated by the contraction havent"
fi

# Negative fixture found via manual real-file drift testing on #692 (not a
# litmus finding): the earlier token list also matched bare "this
# constant"/"the constant" as bump synonyms, but those are noun phrases any
# verb can govern -- "verify this constant" satisfied the concept exactly
# like "bump this constant" would have, silently defeating the guard for a
# verify-then-bump corruption that keeps the noun phrase intact.
_ritual_wrong_verb_fixture='
# Clearing it, IN THIS ORDER: verify this constant to the new version, run
# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, and revert the bump if
# it fails.
'
if _ritual_check <<<"$_ritual_wrong_verb_fixture" >/dev/null 2>&1; then
    fail "ritual guard is fooled by a bare noun-phrase mention (\"verify this constant\") standing in for an actual bump instruction"
else
    ok "ritual guard requires the actual word \"bump\" (or the constant's name), not just a bare noun-phrase mention"
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

# #692 gap 2: a bare `seen >= 2` COUNT is unsound -- an incidental new
# BUSDRIVER_PI_LIVE mention added anywhere else in the file keeps the count at
# 2+ even if a REAL ritual site's comment was deleted, and conversely a
# legitimate new unrelated mention could false-fail a count-based ceiling.
# An earlier version of this check anchored on a nearby stable symbol with a
# fixed backward WINDOW and picked the mention CLOSEST to that anchor -- but
# review found even "closest" isn't sound: if the real ritual comment is
# deleted and exactly one unrelated, coincidentally order-valid mention still
# sits somewhere else in the window, it becomes "the closest" by elimination
# and the check still passes.
#
# _ritual_site_check replaces the window entirely with an explicit
# `# PI_RITUAL_SITE: <name>` marker comment placed by hand at the START of
# each ritual block (see dispatch.sh). The scanned text is bounded by the
# marker on one end and the site's own anchor symbol on the other -- nothing
# before the marker and nothing after the anchor is ever in scope, so an
# unrelated mention elsewhere in the file (or even elsewhere in the same
# function) cannot be mistaken for this site's ritual comment. The marker
# must appear exactly once; deleting or duplicating it fails the check
# outright, same as deleting the ritual text itself.
_ritual_site_check() {   # $1=file $2=marker(grep -F pattern, exactly once) $3=anchor(grep -F pattern, searched from the marker forward)
    local _rsc_file="$1" _rsc_marker="$2" _rsc_anchor="$3"
    local _rsc_marker_count
    _rsc_marker_count="$(grep -cF -- "$_rsc_marker" "$_rsc_file")" || true
    if [[ "${_rsc_marker_count:-0}" -ne 1 ]]; then
        echo "  (site marker '$_rsc_marker' must appear exactly once, found ${_rsc_marker_count:-0})" >&2
        return 1
    fi
    local _rsc_marker_line
    _rsc_marker_line="$(grep -nF -- "$_rsc_marker" "$_rsc_file" | head -1 | cut -d: -f1)" || true
    if [[ -z "$_rsc_marker_line" ]]; then
        echo "  (site marker '$_rsc_marker' not found)" >&2
        return 1
    fi
    local _rsc_anchor_rel
    _rsc_anchor_rel="$(tail -n "+$_rsc_marker_line" "$_rsc_file" | grep -nF -- "$_rsc_anchor" | head -1 | cut -d: -f1)" || true
    if [[ -z "$_rsc_anchor_rel" ]]; then
        echo "  (anchor '$_rsc_anchor' not found at or after site marker '$_rsc_marker')" >&2
        return 1
    fi
    local _rsc_anchor_line=$(( _rsc_marker_line + _rsc_anchor_rel - 1 ))
    local _rsc_err="$FAKE_HOME/ritual-site.err"
    local _rsc_out
    _rsc_out="$(sed -n "${_rsc_marker_line},${_rsc_anchor_line}p" "$_rsc_file" | _ritual_check 2>"$_rsc_err")"
    local _rsc_rc=$?
    local _rsc_seen="${_rsc_out#seen=}"; _rsc_seen="${_rsc_seen%% bad=*}"
    if [[ "$_rsc_rc" -eq 0 && "${_rsc_seen:-0}" -ge 1 ]]; then
        rm -f "$_rsc_err"
        return 0
    fi
    echo "  (site '$_rsc_marker' -> '$_rsc_anchor', $_rsc_out: $(cat "$_rsc_err" 2>/dev/null))" >&2
    rm -f "$_rsc_err"
    return 1
}

# Negative fixture: marker present, but the block between marker and anchor
# carries no ritual comment at all (the "real site deleted" case).
_ritual_site_missing_fixture="$FAKE_HOME/ritual-site-missing.txt"
printf '%s\n' \
    '# PI_RITUAL_SITE: test-missing' \
    '# this comment has nothing to do with the ritual' \
    'BUSDRIVER_PI_PROBED_VERSION="9.9.9"' \
    > "$_ritual_site_missing_fixture"
if _ritual_site_check "$_ritual_site_missing_fixture" 'PI_RITUAL_SITE: test-missing' 'BUSDRIVER_PI_PROBED_VERSION="' 2>/dev/null; then
    fail "site check passes a marker with no ritual comment in its block (a deleted real site would go undetected)"
else
    ok "site check fails a marker whose ritual comment was deleted (proven able to fail)"
fi
rm -f "$_ritual_site_missing_fixture"

# Negative fixture: the marker appears TWICE -- ambiguous, must fail closed
# rather than silently pick one.
_ritual_site_duplicate_fixture="$FAKE_HOME/ritual-site-duplicate.txt"
printf '%s\n' \
    '# PI_RITUAL_SITE: test-dup' \
    '# bump this constant, then run' \
    '# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh' \
    '# PI_RITUAL_SITE: test-dup' \
    'BUSDRIVER_PI_PROBED_VERSION="9.9.9"' \
    > "$_ritual_site_duplicate_fixture"
if _ritual_site_check "$_ritual_site_duplicate_fixture" 'PI_RITUAL_SITE: test-dup' 'BUSDRIVER_PI_PROBED_VERSION="' 2>/dev/null; then
    fail "site check passes a DUPLICATED marker instead of failing closed on ambiguity"
else
    ok "site check fails closed when its marker is duplicated"
fi
rm -f "$_ritual_site_duplicate_fixture"

# Positive fixture: marker present, comment present and order-valid.
_ritual_site_present_fixture="$FAKE_HOME/ritual-site-present.txt"
printf '%s\n' \
    '# PI_RITUAL_SITE: test-present' \
    '# bump this constant, then run' \
    '# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh' \
    'BUSDRIVER_PI_PROBED_VERSION="9.9.9"' \
    > "$_ritual_site_present_fixture"
if _ritual_site_check "$_ritual_site_present_fixture" 'PI_RITUAL_SITE: test-present' 'BUSDRIVER_PI_PROBED_VERSION="' 2>/dev/null; then
    ok "site check passes a marker whose ritual comment is present and order-valid"
else
    fail "site check rejects a correctly-ordered ritual comment (false fail)"
fi
rm -f "$_ritual_site_present_fixture"

# Positive fixture: content BEFORE the marker (a different, unrelated ritual
# mention) must be entirely EXCLUDED from the scan -- this is what the marker
# redesign buys over the old "closest mention wins" window, which could still
# be fooled by unrelated content inside its fixed-size lookback.
_ritual_site_excludes_before_fixture="$FAKE_HOME/ritual-site-excludes-before.txt"
printf '%s\n' \
    '# unrelated: do not bump this constant here, run BUSDRIVER_PI_LIVE=1 elsewhere' \
    '# PI_RITUAL_SITE: test-excl' \
    '# bump this constant, then run' \
    '# BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh' \
    'BUSDRIVER_PI_PROBED_VERSION="9.9.9"' \
    > "$_ritual_site_excludes_before_fixture"
if _ritual_site_check "$_ritual_site_excludes_before_fixture" 'PI_RITUAL_SITE: test-excl' 'BUSDRIVER_PI_PROBED_VERSION="' 2>/dev/null; then
    ok "site check ignores unrelated ritual mentions BEFORE its own marker"
else
    fail "site check let content before the marker leak into the scan"
fi
rm -f "$_ritual_site_excludes_before_fixture"

# Regression for a `set -euo pipefail` trap (litmus review on #692): with no
# `|| true` on a lookup, a genuinely ABSENT marker/anchor makes the assignment
# itself exit non-zero (pipefail reports the rightmost non-zero exit in the
# pipe) and kills the whole script before the "not found" branch can run.
# This must complete and return 1, not abort.
_ritual_site_no_marker_fixture="$FAKE_HOME/ritual-site-no-marker.txt"
printf '%s\n' '# nothing relevant here' > "$_ritual_site_no_marker_fixture"
if _ritual_site_check "$_ritual_site_no_marker_fixture" 'PI_RITUAL_SITE: does-not-exist' 'BUSDRIVER_PI_PROBED_VERSION="' 2>/dev/null; then
    fail "site check somehow passed with a wholly absent marker"
else
    ok "site check completes (does not abort the script) and fails cleanly when the marker itself is absent"
fi
rm -f "$_ritual_site_no_marker_fixture"

# Now the two real sites in dispatch.sh, each verified independently against
# its own hand-placed marker. This REPLACES the old file-wide seen>=2 count
# AND the old window-based "closest mention" heuristic. The third statement --
# the _pi_setup_fail message -- is a code string, deliberately out of scope
# here (comment-only is what stops an adjacent code line satisfying a
# concept); it is covered by the version-mismatch site below via the comment
# that precedes it, and separately by the five-setup-failure assertion above
# (that one counts _pi_setup_fail calls and never inspects ordering).
if _ritual_site_check "$DISPATCH" 'PI_RITUAL_SITE: probed-version' 'BUSDRIVER_PI_PROBED_VERSION="'; then
    ok "the BUSDRIVER_PI_PROBED_VERSION declaration site names the bump before the live test"
else
    fail "the BUSDRIVER_PI_PROBED_VERSION declaration site is missing its ritual comment (deleted, drifted, or its marker was removed/duplicated)"
fi
if _ritual_site_check "$DISPATCH" 'PI_RITUAL_SITE: version-mismatch' '_pi_setup_fail "pi version'; then
    ok "the version-mismatch refusal site names the bump before the live test"
else
    fail "the version-mismatch refusal site is missing its ritual comment (deleted, drifted, or its marker was removed/duplicated)"
fi

# ── #692 gap 3: a FOURTH ritual statement lives outside the guard's scope ──
# docs/adr/0034 ("Fail-closed version pin") restates the same bump-then-verify
# invariant in prose. It is correct today, which is exactly the problem the
# issue names: nothing catches it drifting, because the guard above only reads
# dispatch.sh. _ritual_prose_check reuses the same order+negation logic as
# _ritual_check but drops the "#-prefixed comment lines only" filter — an ADR
# bullet has no code lines to guard against borrowing from, so every non-blank
# line is fair game.
_ritual_prose_check() {   # stdin = prose -> prints "seen=N bad=M"; nonzero if any bad
    awk '
        { buf[NR] = $0 }
        function first_valid_pos(text, tok,    p, idx, from, cs, ce, k, clause, neg) {
            text = tolower(text)   # case-insensitive token/clause search throughout
            tok = tolower(tok)     # TOK must be lowercased too, or an uppercase-only synonym
                                    # like BUSDRIVER_PI_PROBED_VERSION could never match the
                                    # already-lowercased text
            from = 1
            while (1) {
                idx = index(substr(text, from), tok)
                if (idx == 0) return 0
                p = from + idx - 1
                from = p + length(tok)
                # Word-boundary check (PR-mode review): plain substring matching
                # also matches "bump" inside "bumping"/"bumper" -- skip anything
                # that is not a whole word, without counting it as a candidate.
                if (substr(text, p - 1, 1) ~ /[a-z0-9_]/ || substr(text, p + length(tok), 1) ~ /[a-z0-9_]/) continue
                # Clause boundary: nearest "." on each side, capped at 150 chars so an
                # unterminated sentence cannot pull in an unrelated earlier/later thought.
                # A "." immediately followed by a letter/digit is a filename extension
                # or version-number separator ("release.sh", "0.84.2"), not a sentence
                # boundary (PR-mode review finding).
                cs = (p - 150 > 1 ? p - 150 : 1)
                for (k = p - 1; k >= cs; k--) {
                    if (substr(text, k, 1) == "." && substr(text, k + 1, 1) !~ /[a-z0-9]/) { cs = k + 1; break }
                }
                ce = (p + length(tok) + 150 <= length(text) ? p + length(tok) + 150 : length(text))
                for (k = p + length(tok); k <= ce; k++) {
                    if (substr(text, k, 1) == "." && substr(text, k + 1, 1) !~ /[a-z0-9]/) { ce = k - 1; break }
                }
                clause = " " substr(text, cs, ce - cs + 1) " "
                gsub(/[\x27\x60]/, "", clause)   # apostrophe/backtick contractions fold to dont, wont, etc.
                gsub(/[,;:!?]/, " ", clause)      # "not," must still match " not " as a whole word
                # Any whole-word negation trigger ANYWHERE in the period-bounded clause
                # rejects the mention -- including bare "no", folded in here rather than
                # kept as a separate adjacency-only special case (an adjacency-only "no"
                # check is what let "Under no circumstances bump this constant" slip
                # through as a false ACCEPT: "no" was never adjacent to "bump"). This can
                # false-REJECT a bump instruction that shares a clause with an unrelated
                # "no"/"not" about something else ("bump this constant with no other
                # changes" now reads as negated); that is the safe direction -- a false
                # reject just needs a comment reworded, a false accept is the #692 outage
                # class.
                neg = (clause ~ / (no|not|never|cannot|cant|wont|dont|couldnt|wouldnt|isnt|arent|wasnt|werent|hasnt|hadnt|havent|shouldnt|didnt|doesnt|mustnt|neednt|avoid|refrain|without) /)
                if (!neg) return p
            }
        }
        END {
            seen = 0; bad = 0; m = 0
            for (i = 1; i <= NR; i++) if (buf[i] ~ /BUSDRIVER_PI_LIVE/) { m++; mentions[m] = i }
            for (mi = 1; mi <= m; mi++) {
                i = mentions[mi]
                seen++
                prev_line = (mi > 1 ? mentions[mi - 1] : 0)
                next_line = (mi < m ? mentions[mi + 1] : NR + 1)
                w = ""; li = 0
                lo = (i - 8 < 1 ? 1 : i - 8); hi = i + 3
                if (lo <= prev_line) lo = prev_line + 1
                if (hi >= next_line) hi = next_line - 1
                for (j = lo; j <= hi; j++) {
                    piece = " " buf[j]
                    if (j == i) li = length(w) + 1
                    w = w piece
                }
                live = index(substr(w, li), "BUSDRIVER_PI_LIVE")
                if (live > 0) live = live + li - 1
                bump = 0
                # prose only: bare-name/synonym mentions are legitimate descriptive text
                # in an ADR ("the constant that governs X"), unlike shell code where a
                # bare mention is either the declaration or a borrow -- so only the verb
                # "bump" counts as an instruction here.
                split("bump", toks, "|")
                for (t in toks) {
                    p = first_valid_pos(w, toks[t])
                    if (p > 0 && (bump == 0 || p < bump)) bump = p
                }
                if (bump == 0)      { bad++; print "  (line " i ": names the live test but never a non-negated bump)" > "/dev/stderr" }
                else if (bump > live) { bad++; print "  (line " i ": names the live test BEFORE the bump -- deadlocks)" > "/dev/stderr" }
            }
            print "seen=" seen " bad=" bad
            exit (bad > 0 ? 1 : 0)
        }'
}

# Negative fixture: the same deadlocking (verify-then-bump) order, in ADR
# prose form rather than a shell comment.
_ritual_adr_bad_fixture='
The reverse order cannot work: run BUSDRIVER_PI_LIVE=1
tests/test-pi-dispatch-arm.sh, then bump BUSDRIVER_PI_PROBED_VERSION.
'
if _ritual_prose_check <<<"$_ritual_adr_bad_fixture" >/dev/null 2>&1; then
    fail "ADR prose guard is VACUOUS -- it accepts verify-then-bump ordering in prose form"
else
    ok "ADR prose guard rejects verify-then-bump ordering (proven able to fail)"
fi

# Negative fixture: negated bump, same shape as the gap-1 shell fixture, to
# prove the prose checker inherits the negation fix rather than reintroducing
# the bug in its own copy of the logic.
_ritual_adr_negation_fixture='
Operators must not bump BUSDRIVER_PI_PROBED_VERSION casually. First run
BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, then bump it.
'
if _ritual_prose_check <<<"$_ritual_adr_negation_fixture" >/dev/null 2>&1; then
    fail "ADR prose guard is fooled by negation, same as the pre-#692 shell guard was"
else
    ok "ADR prose guard rejects a negated bump mention in prose form"
fi

# The real ADR. docs/adr/0034 states the ritual under the "Fail-closed version
# pin" bullet, but the bullet's own heading is too wide an anchor: the bullet
# ALSO mentions BUSDRIVER_PI_LIVE once earlier in unrelated context
# (introducing the opt-in live test), several lines before the actual
# instruction sentence. An earlier version of this check anchored on the
# heading with a 20-line forward window and a "some mention is order-valid"
# (good=seen-bad>=1) pass condition to tolerate that incidental mention --
# but that also tolerates a SECOND, genuinely drifted instruction sentence
# anywhere else in the same window, since one good mention masks one bad one
# (litmus review on #692). Anchor tighter instead: "**in this order**:" is
# the stable phrase that immediately introduces the instruction sentence
# itself, with nothing else in scope, so the window can require bad==0 (every
# mention in scope must be order-valid) -- the same strict semantics gap 2
# uses for the code-comment sites -- rather than tolerating any incidental
# mention by design.
_ritual_adr_anchor_line="$(grep -nF -- 'in this order' "$ROOT/docs/adr/0034-pi-in-tree-read-lane.md" | head -1 | cut -d: -f1)" || true
if [[ -z "$_ritual_adr_anchor_line" ]]; then
    fail "docs/adr/0034 no longer has an 'in this order' phrase to anchor on"
else
    _ritual_adr_out="$(sed -n "${_ritual_adr_anchor_line},$(( _ritual_adr_anchor_line + 4 ))p" "$ROOT/docs/adr/0034-pi-in-tree-read-lane.md" | _ritual_prose_check 2>/dev/null)" && _ritual_adr_rc=0 || _ritual_adr_rc=1
    _ritual_adr_seen="${_ritual_adr_out#seen=}"; _ritual_adr_seen="${_ritual_adr_seen%% *}"
    if [[ "$_ritual_adr_rc" -eq 0 && "${_ritual_adr_seen:-0}" -ge 1 ]]; then
        ok "docs/adr/0034's ritual statement names the bump before the live test ($_ritual_adr_out)"
    else
        fail "docs/adr/0034's ritual statement is wrong, missing, or under-discovered ($_ritual_adr_out)"
    fi
fi

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
