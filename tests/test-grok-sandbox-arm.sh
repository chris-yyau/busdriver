#!/usr/bin/env bash
# test-grok-sandbox-arm.sh — pins grok's containment argv at BOTH call sites.
#
# No grok binary is invoked: CI has no grok, and the flags are only observable
# live. So this is a SOURCE-TEXT pin, which is the proportionate rung — what it
# defends against is silent drift, and drift is exactly what a source pin sees.
#
# Why both sites: grok is dispatched from skills/dispatch-cli/scripts/dispatch.sh
# (the generic lane) AND from scripts/lib/resolve-cli.sh's execute_review (the
# blueprint-review reviewer_3 slot). This repo has already paid once for two
# copies of an argv drifting apart (see the ack-ledger.sh header, and #686 where
# agy's --add-dir landed on one path only), so the two lists are asserted here
# together.
#
# The invariant, measured 2026-08-19 on macOS:
#   --sandbox busdriver-review
#                      a CUSTOM profile: built-in profiles FAIL OPEN (grok warns
#                      and runs unconfined when the kernel policy cannot be
#                      applied), a custom one refuses to start. It extends
#                      strict (reads confined to CWD) and kernel-denies the
#                      in-tree hook sources and secrets
#   --deny 'Bash(*)'   shell exec denied by policy
#   --deny 'Edit'      write/edit tool denied — load-bearing, because strict
#                      PERMITS CWD writes and a Bash deny does not gate the
#                      write tool
#   --deny 'MCPTool(*)' MCP is a separate class the other two denies miss; a
#                      write/exec-capable MCP server would bypass both
#   GROK_{CLAUDE,CURSOR}_HOOKS_ENABLED=0
#                      hooks run outside the permission system, and under strict
#                      anything grok spawns can write the CWD. Defense-in-depth:
#                      grok's hook discovery loaded NO project source here
#                      (`project_sources=0`), so this closes a vector a future
#                      version could open, not a live one — see the dispatch.sh
#                      SAFETY MODEL block for the measurement
# Dropping any one of these re-opens a hole a probe already walked through.

# Literal grep patterns must never expand.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh"
RESOLVE="$REPO_ROOT/scripts/lib/resolve-cli.sh"
# The preflight child is a separate file (see its header for why it is not a
# heredoc): child-side rules are asserted there, parent-side ones in RESOLVE.
CHILD="$REPO_ROOT/scripts/lib/grok-preflight.sh"

# The account home, derived the way grok-preflight.sh derives it — id(1) plus
# the password database — NOT from $HOME. The preflight deliberately does not
# trust $HOME, so fixtures built from $HOME would target a different directory
# whenever HOME is unset or redirected: the tests would then fail for a reason
# unrelated to the rule under test, and would never exercise the identity
# contract that is the actual production behaviour. Reported by litmus on the
# home-secret change (PR #704).
_acct_home() {
  local _u _h=""
  _u="$(/usr/bin/id -un 2>/dev/null)" || return 1
  [[ -n "$_u" ]] || return 1
  if [[ -x /usr/bin/dscl ]]; then
    _h="$(/usr/bin/dscl . -read "/Users/$_u" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')"
  elif [[ -x /usr/bin/getent ]]; then
    _h="$(/usr/bin/getent passwd "$_u" 2>/dev/null | /usr/bin/cut -d: -f6)"
  fi
  [[ -n "$_h" && "${_h#/}" != "$_h" && -d "$_h" ]] || return 1
  printf '%s' "$_h"
}
ACCT_HOME="$(_acct_home || true)"

# Which home secrets actually exist decides whether the requirement applies at
# all — on an account with none of them the preflight requires nothing, so the
# cases that assert refusal would be asserting a bug rather than a rule.
HOME_SECRET_PRESENT=0
if [[ -n "$ACCT_HOME" ]]; then
  for _hs in .ssh .aws .netrc; do
    [[ -e "$ACCT_HOME/$_hs" ]] && HOME_SECRET_PRESENT=1
  done
fi

FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; FAILED=1; }

# Slice each file down to the grok COMMAND ITSELF — not the whole case arm.
# Two ways an arm-wide slice lies about the argv, both of them found the hard
# way: the arm's comments name flags it deliberately does NOT pass, and its
# operator-facing warning line quotes the flag names back verbatim. Either
# would satisfy a `--sandbox strict` assertion on an arm whose actual command
# had lost the flag. So: start at the command word, stop at the end of the
# invocation, and assert only on that.
dispatch_arm="$(awk '/if grok_sandbox_preflight ""; then/,/^            fi ;;$/' "$DISPATCH")"
resolve_arm="$(awk '/^    grok\)    # The explicit "" is the no-override/,/^             fi ;;$/' "$RESOLVE")"
# The invocation alone — starting AFTER the operator-facing warning, which
# quotes every flag name back and would satisfy any argv assertion on its own.
dispatch_cmd="$(awk '/^            LD_PRELOAD='"''"' LD_AUDIT=/,/PROMPT_FILE/' "$DISPATCH")"
resolve_cmd="$(awk '/^             LD_PRELOAD='"''"' LD_AUDIT=/,/;;$/' "$RESOLVE")"

# An empty slice would pass every "flag is absent" assertion below, so a stale
# slice pattern must fail loudly rather than certify nothing.
for _slice in dispatch_arm resolve_arm dispatch_cmd resolve_cmd; do
  if [[ -z "${!_slice}" ]]; then
    fail "could not locate \$$_slice — the slice pattern needs updating"
  fi
done

for site in dispatch resolve; do
  case "$site" in
    dispatch) arm="$dispatch_cmd"; whole="$dispatch_arm"; where="dispatch.sh" ;;
    resolve)  arm="$resolve_cmd";  whole="$resolve_arm";  where="resolve-cli.sh" ;;
  esac

  if [[ "$arm" == *"--sandbox busdriver-review"* ]]; then
    pass "$where: grok runs under the custom busdriver-review profile"
  else
    fail "$where: grok arm lost --sandbox busdriver-review (custom = fail-closed; built-ins fail open)"
  fi

  # Assert the BUILT-IN profiles are gone, not merely that the custom one is
  # named: every built-in fails open, and `readonly` additionally left reads
  # unconfined (it returned a full ~/.ssh listing in the probe that started
  # this change).
  for builtin in readonly read-only strict workspace devbox off; do
    if [[ "$arm" == *"--sandbox $builtin"* ]]; then
      fail "$where: grok arm passes the built-in '$builtin' profile — built-in profiles run unconfined when the kernel policy cannot be applied"
    fi
  done
  pass "$where: no fail-open built-in profile"

  # A custom profile is only fail-closed against the REPO if the operator's own
  # ~/.grok/sandbox.toml defines it; otherwise a repo-local .grok/sandbox.toml
  # supplies the definition. Assert the REFUSAL, not the call: the slice starts
  # at the call, so checking for it would be tautological — and a preflight
  # whose failure branch fell through would still dispatch.
  # The POSITIVE form specifically. `if ! preflight; then bail; fi; dispatch`
  # puts the invocation AFTER the branch, so a shadowed `return`/`exit` in the
  # bail falls through into it. `if preflight; then dispatch; else …; fi` has
  # nowhere to fall through to.
  if [[ "$whole" == *"if grok_sandbox_preflight \"\"; then"* ]]; then
    pass "$where: the dispatch sits in the preflight's positive branch"
  else
    fail "$where: the dispatch is not gated by 'if grok_sandbox_preflight \"\"; then' — a shadowed return/exit in a bail branch would fall through into it"
  fi
  if [[ "$whole" == *"if ! grok_sandbox_preflight"* ]]; then
    fail "$where: still uses the bail-then-fall-through shape"
  else
    pass "$where: no bail-then-fall-through shape"
  fi

  if [[ "$arm" == *"--deny 'Bash(*)'"* ]]; then
    pass "$where: grok shell exec is denied by policy"
  else
    fail "$where: grok arm lost --deny 'Bash(*)' — shell exec would be reachable"
  fi

  if [[ "$arm" == *"--deny 'Edit'"* ]]; then
    pass "$where: grok write/edit tool is denied by policy"
  else
    fail "$where: grok arm lost --deny 'Edit' — strict permits CWD writes, so this is the only write block"
  fi

  # MCP is its own permission class: neither the Bash nor the Edit deny reaches
  # it, so a write/exec-capable MCP server would walk straight through both.
  if [[ "$arm" == *"--deny 'MCPTool(*)'"* ]]; then
    pass "$where: grok MCP tool class is denied by policy"
  else
    fail "$where: grok arm lost --deny 'MCPTool(*)' — an MCP server could bypass the Bash and Edit denies"
  fi

  # Project hooks run OUTSIDE the permission system, so no deny rule reaches
  # them, and strict lets them write the CWD. These two switches are the only
  # thing stopping a hostile branch of a trusted repo from executing during its
  # own review (GROK_FOLDER_TRUST=0 does NOT — probed, the hook still fired).
  if [[ "$arm" == *"GROK_CLAUDE_HOOKS_ENABLED=0"* && "$arm" == *"GROK_CURSOR_HOOKS_ENABLED=0"* ]]; then
    pass "$where: vendor project-hook scanners are disabled"
  else
    fail "$where: grok arm lost GROK_CLAUDE_HOOKS_ENABLED=0 / GROK_CURSOR_HOOKS_ENABLED=0 — a repo hook could execute and write the CWD"
  fi

  # grok reads its config dir from $GROK_HOME. Verifying the password-database
  # ~/.grok/sandbox.toml while the child inherits a repo-set GROK_HOME would
  # check one file and load another, so both are pinned on the env line.
  if [[ "$arm" == *'HOME="$_GROK_TRUSTED_HOME"'* && "$arm" == *'GROK_HOME="$_GROK_TRUSTED_HOME/.grok"'* ]]; then
    pass "$where: HOME and GROK_HOME are pinned to the verified home"
  else
    fail "$where: grok arm does not pin HOME + GROK_HOME — a repo-set GROK_HOME could load a weaker sandbox.toml than the preflight checked"
  fi

  # Passed via `env`, not an export, so an inherited value cannot re-enable the
  # scanners (#325 / ADR 0016: a committed settings.json can set env vars).
  # `-i` matters as much as the absolute path: without it every unlisted
  # ambient variable survives into grok, and loader variables (BASH_ENV,
  # NODE_OPTIONS, DYLD_*, LD_PRELOAD) run code before the sandbox exists.
  if [[ "$arm" == *"/usr/bin/env -i"* ]]; then
    pass "$where: env is absolute AND clears the environment (-i)"
  else
    fail "$where: grok arm does not use '/usr/bin/env -i' — an injected ambient variable would reach grok"
  fi

  # `-i` is too late for the loader: LD_PRELOAD / LD_AUDIT act while
  # /usr/bin/env itself is being loaded, so they must be blanked on the exec
  # that starts env, not by env.
  if [[ "$arm" == *"LD_PRELOAD='' LD_AUDIT=''"* && "$arm" == *"LD_LIBRARY_PATH=''"* \
     && "$arm" == *"DYLD_INSERT_LIBRARIES=''"* && "$arm" == *"DYLD_LIBRARY_PATH=''"* ]]; then
    pass "$where: loader variables are blanked before env is exec'd"
  else
    fail "$where: grok arm does not blank LD_PRELOAD/LD_AUDIT/DYLD_* before exec — the loader runs injected code inside env itself, before -i clears anything"
  fi

  # As an assignment PREFIX on the shell command, never as argv words: both
  # call sites hand their argv to a helper that execs "$@", where a bare
  # LD_PRELOAD= would become the command name and the dispatch would die.
  # The prefix must therefore come BEFORE the helper name on its line.
  _prefix_line="$(printf '%s\n' "$arm" | /usr/bin/grep -n 'LD_PRELOAD' | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
  _helper_line="$(printf '%s\n' "$arm" | /usr/bin/grep -nE '_portable_timeout|_run_review_with_retries' | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
  if [[ -n "$_prefix_line" && -n "$_helper_line" && "$_prefix_line" -le "$_helper_line" ]]; then
    pass "$where: the loader blanks precede the helper, so they are a shell assignment prefix"
  else
    fail "$where: the loader blanks sit inside the helper argv — the helper execs \"\$@\", so they would be run as the command name"
  fi

  # env resolves the command against the PATH on its own command line, so this
  # is what stops a PATH-shadowed `grok` from running before the sandbox exists,
  # and it is also where a pinned-only install is found — which is why
  # availability is not separately gated on the ambient PATH.
  if [[ "$arm" == *'PATH="$_GROK_PINNED_PATH"'* ]]; then
    pass "$where: grok is resolved against a PATH pinned to the verified home"
  else
    fail "$where: grok arm does not re-set PATH to \$_GROK_PINNED_PATH — an injected PATH could shadow the grok binary itself"
  fi

  # --always-approve would defeat the deny rules' whole point.
  if [[ "$arm" == *"--always-approve"* || "$arm" == *"--yolo"* ]]; then
    fail "$where: grok arm passes an always-approve flag"
  else
    pass "$where: no always-approve flag"
  fi
done

# The retired user-config clause must not creep back into the operator-facing
# warnings: it told the operator to secure a setting that was never the
# boundary, which is worse than silence.
for f in "$DISPATCH" "$RESOLVE" "$REPO_ROOT/skills/blueprint-review/scripts/run-design-review-loop.sh"; do
  if grep -q "safety relies on user-config\|Safety also requires 'always approve'\|+ 'always approve' DISABLED in grok user-config" "$f"; then
    fail "$(basename "$f"): still tells the operator grok safety depends on their user-config"
  else
    pass "$(basename "$f"): no user-config safety claim"
  fi
done

# ── the preflight itself ────────────────────────────────────────────
# It takes a path override for exactly this: the production path derives the
# home from the password database, which a test cannot fake.
# shellcheck source=/dev/null
source "$RESOLVE" >/dev/null 2>&1 || true
if ! declare -F grok_sandbox_preflight >/dev/null; then
  fail "grok_sandbox_preflight is not defined in resolve-cli.sh"
else
  # `set -e` is off in this file, so an unchecked mktemp would leave $tmp empty
  # and write every fixture to /good.toml, /wrong.toml and friends.
  if ! tmp="$(mktemp -d)" || [[ -z "$tmp" || ! -d "$tmp" ]]; then
    fail "could not create a temp dir for the preflight fixtures"
    tmp=""
  fi

  if [[ -n "$tmp" ]]; then
  # Every negative fixture below differs from the accepted one in EXACTLY ONE
  # way. A fixture that broke two rules at once could pass for the wrong
  # reason, and would keep passing after the rule it is named for was deleted.
  # The preflight requires the ABSOLUTE home-secret entries for the paths that
  # exist, alongside the ten relative globs (Codex + Greptile P1, PR #704).
  # Build them here the same way it does, so `good.toml` stays a VALID profile.
  # If it silently became a negative case, the "preflight accepts the shipped
  # profile shape" assertion would fail and every negative below would pass for
  # the wrong reason -- the exact trap this fixture matrix is built to avoid.
  _REL_DENY='"**/.grok", "**/.grok/**", "**/.claude", "**/.claude/**", "**/.cursor", "**/.cursor/**", "**/.env", "**/.env.*", "**/*.pem", "**/*.key"'
  # $ACCT_HOME, not $HOME — see the derivation near the top of this file.
  _HOME_DENY=""
  if [[ -n "$ACCT_HOME" ]]; then
    for _s in .ssh .aws; do
      [[ -e "$ACCT_HOME/$_s" ]] && _HOME_DENY="$_HOME_DENY, \"$ACCT_HOME/$_s\", \"$ACCT_HOME/$_s/**\""
    done
    [[ -e "$ACCT_HOME/.netrc" ]] && _HOME_DENY="$_HOME_DENY, \"$ACCT_HOME/.netrc\""
  fi

  _profile() {  # $1 = which line to replace, $2 = its replacement ('' drops it)
    local drop="${1:-}" repl="${2:-}"
    local -a lines=(
      '[profiles.busdriver-review]'
      'extends = "strict"'
      'restrict_network = true'
      "deny = [${_REL_DENY}${_HOME_DENY}]"
    )
    local l
    for l in "${lines[@]}"; do
      if [[ -n "$drop" && "$l" == "$drop"* ]]; then
        [[ -n "$repl" ]] && printf '%s\n' "$repl"
      else
        printf '%s\n' "$l"
      fi
    done
  }

  _profile > "$tmp/good.toml"
  printf '%s\n' '[profiles.something-else]' > "$tmp/wrong.toml"
  ln -s "$tmp/good.toml" "$tmp/link.toml"

  # one deviation each
  _profile 'extends' > "$tmp/no-extends.toml"
  _profile 'restrict_network' > "$tmp/no-restrict.toml"
  _profile 'deny' 'deny = ["**/.grok", "**/.grok/**", "**/.claude", "**/.cursor", "**/.cursor/**", "**/.env", "**/.env.*", "**/*.pem", "**/*.key"]' > "$tmp/half-deny.toml"
  # one fixture per required glob: a fixture dropping four at once would keep
  # passing after validation for three of them was deleted
  _GLOBS=('"**/.grok"' '"**/.grok/**"' '"**/.claude"' '"**/.claude/**"'
          '"**/.cursor"' '"**/.cursor/**"' '"**/.env"' '"**/.env.*"'
          '"**/*.pem"' '"**/*.key"')
  # Index-suffixed: "**/.grok" and "**/.grok/**" both strip to `grok`, so a
  # name built from the glob alone had the paired fixtures overwriting each
  # other and one companion going untested.
  _slug() { printf '%s-%s' "$2" "$(printf '%s' "$1" | tr -d '"*/.')" ; }
  # one fixture per required glob, each dropping exactly that one and keeping
  # the other nine. Built by array join, not by editing a string: the globs are
  # full of regex and shell metacharacters.
  for _i in "${!_GLOBS[@]}"; do
    _rest=""
    for _j in "${!_GLOBS[@]}"; do
      [[ "$_i" == "$_j" ]] && continue
      [[ -n "$_rest" ]] && _rest="$_rest, "
      _rest="$_rest${_GLOBS[$_j]}"
    done
    _profile 'deny' "deny = [$_rest]" > "$tmp/missing-$(_slug "${_GLOBS[$_i]}" "$_i").toml"
  done

  # required globs present only as a COMMENT, with an empty deny array
  _profile 'deny' '# deny = ["**/.grok", "**/.grok/**", "**/.claude", "**/.claude/**", "**/.cursor", "**/.cursor/**", "**/.env", "**/.env.*", "**/*.pem", "**/*.key"]
deny = []' > "$tmp/commented.toml"
  # single-quoted entries whose VALUES contain the quote characters: the denied
  # paths are not the ones a substring search sees
  # Differs from the accepted profile in ONE way: a backslash. Every required
  # glob is still present and correctly spelled, so only the escape rule can
  # reject it — TOML decodes escapes, which is how a source that reads like the
  # required entry becomes a value that denies something else.
  _profile 'deny' 'deny = ["**/.grok", "**/.grok/**", "**/.claude", "**/.claude/**", "**/.cursor", "**/.cursor/**", "**/.env", "**/.env.*", "**/*.pem", "**/*.key", "a\\tb"]' > "$tmp/escaped-quotes.toml"
  _profile 'deny' "deny = ['\"**/.grok\"', '\"**/.grok/**\"', '\"**/.claude\"', '\"**/.claude/**\"', '\"**/.cursor\"', '\"**/.cursor/**\"', '\"**/.env\"', '\"**/.env.*\"', '\"**/*.pem\"', '\"**/*.key\"']" > "$tmp/literal-quotes.toml"

  { _profile; echo 'read_write = ["/"]'; }            > "$tmp/widened.toml"
  { _profile; echo '"read_write" = ["/"]'; }          > "$tmp/quoted-widen.toml"
  { _profile; echo "'read_write' = ['/']"; }          > "$tmp/squoted-widen.toml"
  { _profile; echo 'read_only = ["/"]'; }             > "$tmp/read-only-widen.toml"
  { _profile; echo '"read\u005fwrite" = ["/"]'; }     > "$tmp/unicode-key.toml"
  { _profile; echo '"read\U0000005fwrite" = ["/"]'; } > "$tmp/unicode-key-upper.toml"
  { _profile; printf 'note = """\n"**/.grok"\n"""\n'; } > "$tmp/multiline.toml"
  printf '%s\n' '[profiles.busdriver-review]' '[decoy]' > "$tmp/decoy-head.toml"
  _profile | tail -n +2 >> "$tmp/decoy-head.toml"
  printf '%s\n' '[profiles.busdriver-review]' > "$tmp/header-only.toml"
  # A profile carrying ONLY the relative globs -- i.e. exactly what this fixture
  # set looked like before the P1 fix, and what an operator gets by deleting the
  # home lines. Denies nothing for real credentials.
  _profile 'deny' "deny = [${_REL_DENY}]" > "$tmp/no-home-secrets.toml"
  # ...and the shipped placeholder left un-edited, which is the likelier mistake:
  # it LOOKS like the entries are there.
  _profile 'deny' "deny = [${_REL_DENY}, \"/Users/YOU/.ssh\", \"/Users/YOU/.ssh/**\", \"/Users/YOU/.aws\", \"/Users/YOU/.aws/**\", \"/Users/YOU/.netrc\"]" > "$tmp/placeholder-home.toml"

  if grok_sandbox_preflight "$tmp/good.toml"; then
    pass "preflight accepts the shipped profile shape"
  else
    fail "preflight rejected a valid profile — every negative case below would then pass for the wrong reason"
  fi

  # name -> why it must be refused
  # A negative case treats ANY refusal as success, so an un-created fixture
  # would pass without testing anything. Verify each one exists first — and
  # that the symlink case really is a symlink.
  for _f in good wrong header-only no-extends no-restrict half-deny commented \
            literal-quotes escaped-quotes widened quoted-widen squoted-widen read-only-widen \
            unicode-key unicode-key-upper multiline decoy-head \
            no-home-secrets placeholder-home; do
    [[ -s "$tmp/$_f.toml" ]] || fail "fixture $_f.toml was not created — its case would pass for the wrong reason"
  done
  [[ -L "$tmp/link.toml" ]] || fail "link.toml is not a symlink — the symlink-refusal case would pass for the wrong reason"

  # The DIRECTORY check has no path override, so it is asserted on the source:
  # a symlinked ~/.grok makes every file inside it repo-controlled while each
  # one is still a regular file.
  # The only airtight answer to BASH_FUNC_* shadowing is a function-clean
  # child: `unset` can be shadowed, and so can the `builtin` that would
  # un-shadow it. `env -i` drops exported functions, `-p` stops bash
  # re-importing them, and an absolute path cannot be shadowed at all.
  if /usr/bin/grep -q '/usr/bin/env -i /bin/bash -p' "$RESOLVE"; then
    pass "the preflight runs in a function-clean child"
  else
    fail "the preflight no longer runs under env -i /bin/bash -p — an inherited BASH_FUNC_* could run inside the check that authorises the dispatch"
  fi

  # The PARENT side must be shadow-proof too, or an exported BASH_FUNC_return%%
  # turns a refusal into a pass before the clean child's verdict is ever read.
  # Keywords (`[[`, `&&`, `if`) cannot be function names and assignments are not
  # command lookups, so the parent may use only those plus absolute paths.
  # Everything between the function header and the heredoc, and everything after
  # the heredoc terminator, is parent-side; the child body legitimately uses
  # `return` and runs where nothing can shadow it.
  _parent="$(/usr/bin/awk '
    /^grok_sandbox_preflight\(\) \{/ { inp = 1 }
    /^PREFLIGHT_CHILD$/                  { inh = 0; next }
    inp && !inh                          { print }
    inp && /<<.PREFLIGHT_CHILD./         { inh = 1 }
    inp && !inh && /^\}/                  { exit }
  ' "$RESOLVE" | /usr/bin/grep -v '^[[:space:]]*#')"
  # The outputs must be cleared at entry: they are globals, so an inherited or
  # left-over value would be trusted if any path returned success without
  # setting them.
  for _v in _GROK_TRUSTED_HOME _GROK_PINNED_PATH _GROK_PREFLIGHT_WHY; do
    /usr/bin/grep -qE "^  $_v=''$" "$RESOLVE" || fail "grok_sandbox_preflight does not clear $_v at entry — an inherited value could be used as verified containment"
  done
  pass "the preflight clears its output globals at entry"

  if [[ -z "$_parent" ]]; then
    fail "could not slice the parent side of grok_sandbox_preflight — the pattern needs updating"
  else
    _bad=""
    for _w in local return true false eval command builtin unset; do
      /usr/bin/grep -qE "^[[:space:]]*$_w([[:space:]]|\$)" <<<"$_parent" && _bad="$_bad $_w"
    done
    if [[ -z "$_bad" ]]; then
      pass "the preflight's parent side runs no shadowable command word"
    else
      fail "the preflight's parent side runs shadowable builtins:$_bad — an exported BASH_FUNC_* could turn a refusal into a pass"
    fi
  fi

  # The preflight's OWN exec needs the loader scrub as much as grok's: code
  # injected there could forge the success output the whole gate rests on.
  _pf_scrub=0
  for _v in LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH; do
    /usr/bin/grep -qE "^  $_v=''$" "$RESOLVE" || _pf_scrub=1
  done
  if [[ "$_pf_scrub" -eq 0 ]]; then
    pass "the preflight's own child exec is loader-scrubbed"
  else
    fail "the preflight launches env -i without blanking every loader variable — injected code could forge its verdict"
  fi

  # A wrapper script's interpreter is resolved at exec time, so a safe wrapper
  # path proves nothing about what actually runs.
  # Assert the REFUSAL and the regular-file guard, not just the identifier: a
  # grep for `head2` still passes if the comparison that rejects a script is
  # deleted, and reading two bytes from an executable FIFO named grok would
  # hang the gate instead of refusing.
  # Not "does not start with #!": an executable text file with no shebang is
  # handed to /bin/sh by execvp, so the test has to be what the file IS.
  # The FAT magic is shared with Java .class files, so accepting it on the magic
  # alone re-opens the wrapper path: an executable .class named grok would pass
  # and then be handed to /bin/sh on ENOEXEC.
  if /usr/bin/grep -q '01000007|0100000c) : ;;' "$CHILD"; then
    pass "the universal-binary magic is qualified by cputype, not accepted bare"
  else
    fail "the FAT magic (cafebabe) is accepted without checking the arch cputype — a Java .class shares that magic"
  fi

  # The magic alone is not proof: `\x7fELF\n` + shell text carries the right
  # first word, gets ENOEXEC, and is handed to /bin/sh. The header fields are
  # what a text payload cannot satisfy by accident.
  if /usr/bin/grep -q 'case "\$etype" in 0002|0003)' "$CHILD"; then
    pass "ELF images are validated by e_type (EXEC/DYN), not just the magic"
  else
    fail "the preflight accepts the ELF magic without checking e_type — a shell payload prefixed with the magic would pass, then be handed to /bin/sh on ENOEXEC"
  fi
  if /usr/bin/grep -q '00000002) : ;;' "$CHILD" && /usr/bin/grep -q '02000000) : ;;' "$CHILD"; then
    pass "thin Mach-O images are validated by filetype (MH_EXECUTE), both endiannesses"
  else
    fail "the preflight accepts a thin Mach-O magic without checking filetype"
  fi
  if /usr/bin/grep -q '7f454c46)' "$CHILD"; then
    pass "grok is classified from the header, with no optional-package dependency"
  else
    fail "the preflight does not read the header — either it accepts non-binaries, or it depends on file(1), which is absent from a stock Ubuntu image and would refuse every valid install"
  fi
  if /usr/bin/grep -q '/usr/bin/file' "$CHILD"; then
    fail "the preflight still calls file(1) — an optional package; on a host without it every grok install is refused as WHY=binary"
  else
    pass "the preflight does not depend on file(1)"
  fi

  # Behavioural, not textual: run the same classifier the preflight runs and
  # confirm it separates a real binary from the two wrapper shapes on THIS host.
  # A grep alone would have stayed green through the octet-stream bypass.
  # `set -e` is off here, so an unchecked mktemp would leave $_bin_probe empty,
  # write the fixtures to /shebang, /plain and /binaryish, and then report the
  # MISSING files as correctly rejected — false-green on the one check that is
  # behavioural rather than textual.
  if ! _bin_probe="$(mktemp -d)" || [[ -z "$_bin_probe" || ! -d "$_bin_probe" ]]; then
    fail "could not create a temp dir for the binary-classifier fixtures"
    _bin_probe=""
  fi
  if [[ -n "$_bin_probe" ]]; then
  printf '#!/bin/sh\necho hi\n' > "$_bin_probe/shebang"; chmod +x "$_bin_probe/shebang"
  printf 'echo hi\n' > "$_bin_probe/plain";              chmod +x "$_bin_probe/plain"
  printf 'echo hi\n\001\n' > "$_bin_probe/binaryish";   chmod +x "$_bin_probe/binaryish"
  # The exact shape Codex reported: right magic, shell body. The kernel refuses
  # it (ENOEXEC) and execvp hands it to /bin/sh — so the classifier must not
  # bless it on the strength of those four bytes.
  printf '\177ELF\necho hi\n' > "$_bin_probe/elfish";     chmod +x "$_bin_probe/elfish"
  # ACCEPT fixtures. This host is macOS, so there is no real ELF binary to
  # point at and the accept path of the ELF arm would otherwise never run -
  # which is how it shipped refusing every genuine ELF image. Synthetic headers
  # are enough: the classifier reads nothing past byte 19.
  #   ELF64 LE EXEC:  class=02 data=01 ver=01, 9 pad, e_type=02 00, e_machine
  #   ELF64 LE DYN:   same, e_type=03 00       (a PIE - how most CLIs ship)
  #   ELF32 BE EXEC:  class=01 data=02 ver=01, e_type=00 02 (byte order flips)
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\076\000' > "$_bin_probe/elf64le-exec"
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\003\000\076\000' > "$_bin_probe/elf64le-dyn"
  printf '\177ELF\001\002\001\000\000\000\000\000\000\000\000\000\000\002\000\024' > "$_bin_probe/elf32be-exec"
  # ...and one that must still be refused, so the e_type check is doing work
  # rather than the arm having been widened to accept anything ELF-shaped:
  # e_type=01 is ET_REL, an object file the kernel will not load.
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\001\000\076\000' > "$_bin_probe/elf64le-rel"
  # FAT (universal) headers: magic, then nfat_arch, then the first arch's
  # cputype at bytes 8..11. `cafebabf` is FAT_MAGIC_64; the `*feca` spellings
  # are the byte-swapped forms, in which the cputype is reversed too.
  printf '\312\376\272\276\000\000\000\002\001\000\000\007\000\000\000\003\000\000\000\000' > "$_bin_probe/fat-be"
  printf '\312\376\272\277\000\000\000\002\001\000\000\014\000\000\000\003\000\000\000\000' > "$_bin_probe/fat64-be"
  printf '\276\272\376\312\002\000\000\000\007\000\000\001\003\000\000\000\000\000\000\000' > "$_bin_probe/fat-swapped"
  printf '\277\272\376\312\002\000\000\000\014\000\000\001\003\000\000\000\000\000\000\000' > "$_bin_probe/fat64-swapped"
  # A Java .class shares the cafebabe magic; its bytes 8..11 are a constant-pool
  # count and tag, which cannot spell either cputype. It must still be refused.
  printf '\312\376\272\276\000\000\000\064\000\035\012\000\002\000\003\007\000\004\014\000' > "$_bin_probe/javaclass"
  # …and the swapped cputypes must NOT be honoured on a big-endian header (or
  # the two arms have been collapsed into one that accepts either spelling).
  printf '\312\376\272\276\000\000\000\002\007\000\000\001\000\000\000\003\000\000\000\000' > "$_bin_probe/fat-be-wrongorder"
  # Shorter than the 20 bytes the classifier reads: a truncated or empty
  # candidate must be refused, not indexed past its end.
  printf '\177ELF\002\001\001' > "$_bin_probe/truncated"
  : > "$_bin_probe/empty"
  chmod +x "$_bin_probe"/elf64le-exec "$_bin_probe"/elf64le-dyn \
           "$_bin_probe"/elf32be-exec "$_bin_probe"/elf64le-rel \
           "$_bin_probe"/fat-be "$_bin_probe"/fat64-be \
           "$_bin_probe"/fat-swapped "$_bin_probe"/fat64-swapped \
           "$_bin_probe"/javaclass "$_bin_probe"/fat-be-wrongorder \
           "$_bin_probe"/truncated "$_bin_probe"/empty
  # Mirrors the production predicate: header fields, not just the magic. Keep
  # the offsets in step with grok-preflight.sh - a mirror that repeats the
  # production bug agrees with it and proves nothing, which is exactly how the
  # e_type offsets shipped wrong: every assertion here was a grep for the text,
  # and the only behavioural fixtures were ones expected to be REJECTED.
  _allow() {
    local _h _et
    _h="$(/usr/bin/od -An -tx1 -N20 -- "$1" 2>/dev/null | /usr/bin/tr -d ' \n')"
    [[ ${#_h} -eq 40 ]] || return 1
    case "${_h:0:8}" in
      7f454c46)
        case "${_h:8:2}"  in 01|02) ;; *) return 1 ;; esac
        case "${_h:12:2}" in 01)    ;; *) return 1 ;; esac
        case "${_h:10:2}" in
          01) _et="${_h:34:2}${_h:32:2}" ;;
          02) _et="${_h:32:2}${_h:34:2}" ;;
          *) return 1 ;;
        esac
        case "$_et" in 0002|0003) return 0 ;; *) return 1 ;; esac ;;
      feedface|feedfacf) case "${_h:24:8}" in 00000002) return 0 ;; *) return 1 ;; esac ;;
      cefaedfe|cffaedfe) case "${_h:24:8}" in 02000000) return 0 ;; *) return 1 ;; esac ;;
      cafebabe|cafebabf) case "${_h:16:8}" in 01000007|0100000c) return 0 ;; *) return 1 ;; esac ;;
      bebafeca|bfbafeca) case "${_h:16:8}" in 07000001|0c000001) return 0 ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
  }
  if _allow /usr/bin/head; then
    pass "the native-image rule accepts a real binary (/usr/bin/head)"
  else
    fail "the native-image rule rejects a real binary — it would refuse every grok install"
  fi
  for _img in elf64le-exec elf64le-dyn elf32be-exec \
              fat-be fat64-be fat-swapped fat64-swapped; do
    if _allow "$_bin_probe/$_img"; then
      pass "the native-image rule accepts a genuine $_img header"
    else
      fail "the native-image rule REJECTS a genuine $_img header - grok would refuse to dispatch on every host of that architecture"
    fi
  done
  for _probe in shebang plain binaryish elfish elf64le-rel javaclass \
                fat-be-wrongorder truncated empty; do
    if _allow "$_bin_probe/$_probe"; then
      fail "the native-image rule accepts the '$_probe' wrapper — it would run before grok's sandbox"
    else
      pass "the native-image rule rejects the '$_probe' wrapper"
    fi
  done
  unset -f _allow
  rm -rf "$_bin_probe"
  fi
  if /usr/bin/grep -q '\[\[ -f "\$target" \]\] || why binary' "$CHILD"; then
    pass "the grok candidate must be a regular file before it is read"
  else
    fail "the preflight reads the candidate without requiring a regular file — an executable FIFO named grok would block it forever"
  fi

  # The config directory is checked on its own, not as a by-product of the PATH
  # walk: its pinned entry is $home/.grok/BIN, which need not exist, and a
  # non-existent entry is skipped — which would leave the directory that holds
  # the profile uncompared.
  if /usr/bin/grep -q 'cfgreal=' "$CHILD"; then
    pass "the config directory itself is checked against the reviewed tree"
  else
    fail "the config dir is only checked via the PATH walk — with no bin/ under it, a checkout containing the operator home could supply its own sandbox.toml"
  fi

  if /usr/bin/grep -q 'pathrest="\$pinned:"' "$CHILD"; then
    pass "every pinned PATH entry is checked against the reviewed tree"
  else
    fail "the containment check does not walk the whole pinned PATH — a checkout rooted at ~/.local, /opt/homebrew or /usr/local could supply grok or an interpreter it resolves"
  fi

  # the INVOCATION form, not the mention — the comment above the walk explains
  # why git is not asked, and would otherwise match
  if /usr/bin/grep -q '/usr/bin/git rev-parse' "$CHILD"; then
    fail "preflight asks git for the checkout root — GIT_DIR/GIT_WORK_TREE are injectable, so the reviewed tree could nominate its own root"
  elif /usr/bin/grep -q '\-e "\$walk/.git"' "$CHILD"; then
    pass "containment walks up for the checkout root instead of trusting git env"
  else
    fail "containment does not find the checkout root — run from a subdirectory of a checkout rooted at \$HOME, ~/.grok would pass while the branch owns it"
  fi

  if /usr/bin/grep -q 'resolve_link "\$p/grok"' "$CHILD"; then
    pass "the grok binary is resolved through symlinks before it is trusted"
  else
    fail "the grok binary is trusted by path — a trusted-looking entry could be a symlink into the reviewed checkout"
  fi

  # env execs the FIRST grok on the pinned PATH, so an unsafe first candidate
  # must fail the check, not be skipped in favour of a safe later one.
  if /usr/bin/grep -q 'target="\$(resolve_link "\$p/grok")" || why binary' "$CHILD"; then
    pass "an unsafe first grok candidate fails the preflight instead of being skipped"
  else
    fail "the PATH scan continues past an unsafe candidate — it would bless a binary that never runs"
  fi

  if /usr/bin/grep -q '\[\[ -L "\$p" \]\] && return 1' "$CHILD"; then
    pass "an unresolved symlink chain is a failure, not a partial answer"
  else
    fail "resolve_link returns a still-symlinked path at its bound — exec would follow the remaining hops elsewhere"
  fi

  if /usr/bin/grep -q 'command -v grok' "$CHILD"; then
    fail "preflight uses 'command -v grok' — it consults shell functions, so an inherited grok function passes a check that /usr/bin/env then fails with 127"
  else
    pass "preflight tests for the grok executable, not a resolvable name"
  fi

  if /usr/bin/grep -q 'root="\$(pwd -P)"' "$CHILD"; then
    pass "the child takes the reviewed-tree root from its own cwd, not a passed \$PWD"
  else
    fail "the child derives the root from a passed value — \$PWD is reassignable, so it could be forged"
  fi

  if /usr/bin/grep -q 'pwd -P' "$CHILD"; then
    pass "preflight refuses a ~/.grok that sits inside the reviewed tree"
  else
    fail "preflight does not compare RESOLVED paths — a checkout reached through a symlink could still contain ~/.grok"
  fi

  if /usr/bin/grep -q '\-x "\$p/grok"' "$CHILD"; then
    pass "preflight refuses when no grok EXECUTABLE sits on the pinned PATH"
  else
    fail "preflight does not check grok against the pinned PATH — selection and execution could disagree"
  fi

  if /usr/bin/grep -q '\-L "\$home/.grok" \]\] && why configdir' "$CHILD"; then
    pass "preflight refuses a symlinked ~/.grok directory, not just a symlinked file"
  else
    fail "preflight only checks the file for symlinks — a symlinked ~/.grok would hand the repo the profile and the grok binary"
  fi
  [[ -e "$tmp/missing.toml" ]] && fail "missing.toml exists — the missing-file case is not testing what it claims"

  _cases=(
    "wrong.toml|the profile is not defined at all"
    "header-only.toml|the header is there but the body is empty"
    "no-extends.toml|extends is missing, and grok defaults to workspace (reads everything)"
    "no-restrict.toml|restrict_network is missing"
    "half-deny.toml|a directory deny lost its /** companion, leaving the contents readable"
    "commented.toml|the required globs are only in a comment; deny is empty"
    "literal-quotes.toml|single-quoted entries whose values contain the quote characters"
    "escaped-quotes.toml|a backslash escape, which decodes to something other than what the source reads as"
    "widened.toml|read_write makes paths writable again"
    "quoted-widen.toml|a double-quoted read_write key"
    "squoted-widen.toml|a single-quoted read_write key"
    "read-only-widen.toml|read_only grants extra readable paths"
    "unicode-key.toml|a lowercase \\u escape spells a widening key"
    "unicode-key-upper.toml|an uppercase \\U escape does the same"
    "multiline.toml|a multiline string can carry the required globs as text"
    "decoy-head.toml|a [decoy] table owns the fields, not the profile"
    "link.toml|a symlink can point back into the reviewed tree"
    "missing.toml|the file does not exist"
  )
  # Guarded: with none of ~/.ssh, ~/.aws, ~/.netrc present there is nothing to
  # require, so these two fixtures are legitimately VALID and asserting refusal
  # would be asserting a bug. Skip loudly rather than pass for free.
  if [[ "$HOME_SECRET_PRESENT" -eq 1 && -n "$_HOME_DENY" ]]; then
    _cases+=(
      "no-home-secrets.toml|the absolute home-secret denies are absent, so real credentials are undenied"
      "placeholder-home.toml|the shipped /Users/YOU placeholder was never replaced, so it denies a path that does not exist"
    )
  else
    echo "  SKIP  home-secret deny cases: none of ~/.ssh ~/.aws ~/.netrc exist on this host, so nothing is required"
  fi
  for _case in "${_cases[@]}"; do
    _f="${_case%%|*}"; _why="${_case#*|}"
    if grok_sandbox_preflight "$tmp/$_f"; then
      fail "preflight accepted $_f — $_why"
    else
      pass "preflight refuses $_f ($_why)"
    fi
  done

  for _i in "${!_GLOBS[@]}"; do
    _g="${_GLOBS[$_i]}"
    _f="$tmp/missing-$(_slug "$_g" "$_i").toml"
    # the fixture must still carry the other nine, or it would be refused for a
    # reason that has nothing to do with the glob it is named for
    if [[ ! -s "$_f" ]] || [[ "$(/usr/bin/grep -o '\*\*' "$_f" | wc -l)" -lt 9 ]]; then
      fail "fixture for a missing $_g deny was not built correctly"
    elif grok_sandbox_preflight "$_f"; then
      fail "preflight accepted a deny list missing $_g"
    else
      pass "preflight refuses a deny list missing $_g"
    fi
  done

  unset -f _profile _slug
  fi

  [[ -n "$tmp" ]] && rm -rf "$tmp"
fi

# The shipped example must actually define what the preflight looks for, or the
# error message sends the operator to a file that will not satisfy it.
EXAMPLE="$REPO_ROOT/docs/examples/grok-sandbox.toml"
# Each refusal reason must produce its OWN remediation. One generic "install the
# profile" message is wrong advice for four of the five ways this refuses, and
# wrong advice on a security gate is worse than none — the operator edits a file
# that was never the problem and concludes the gate is broken.
# The reason helper must TERMINATE. It was briefly self-recursive here (a bulk
# edit rewrote its own `exit 1` into a `why` call), which printed WHY= forever
# instead of refusing — a hang where a refusal belongs.
if /usr/bin/grep -A2 '^why() {' "$CHILD" | /usr/bin/grep -q '^[[:space:]]*why '; then
  fail "why() calls itself — a refusal would loop instead of exiting"
else
  pass "why() exits rather than recursing"
fi

if declare -F grok_preflight_hint >/dev/null; then
  _GROK_PREFLIGHT_WHY=containment
  _h_containment="$(grok_preflight_hint)"
  _GROK_PREFLIGHT_WHY=binary
  _h_binary="$(grok_preflight_hint)"
  _GROK_PREFLIGHT_WHY=configdir
  _h_configdir="$(grok_preflight_hint)"
  _GROK_PREFLIGHT_WHY=identity
  _h_identity="$(grok_preflight_hint)"
  _GROK_PREFLIGHT_WHY=profile
  _h_profile="$(grok_preflight_hint)"
  unset _GROK_PREFLIGHT_WHY

  if [[ "$_h_containment" == *"INSIDE the checkout"* ]]; then
    pass "the containment refusal explains the checkout overlap, not the profile"
  else
    fail "the containment refusal reuses the generic profile message"
  fi
  if [[ "$_h_binary" == *"no grok executable"* ]]; then
    pass "the binary refusal explains the PATH problem"
  else
    fail "the binary refusal reuses the generic profile message"
  fi
  if [[ "$_h_configdir" == *"symlink"* && "$_h_identity" == *"password database"* ]]; then
    pass "the config-dir and identity refusals each explain themselves"
  else
    fail "the config-dir or identity refusal reuses the generic profile message"
  fi
  if [[ "$_h_profile" == *"docs/examples/grok-sandbox.toml"* ]]; then
    pass "the profile refusal names the file to install"
  else
    fail "the profile refusal no longer names docs/examples/grok-sandbox.toml"
  fi
else
  fail "grok_preflight_hint is not defined — the refusal messages have no source"
fi

# The strongest statement available: run the real preflight against the file the
# error message tells operators to install. Header/glob greps alone would still
# pass an example that the preflight rejects on install.
#
# It is validated AS THE DOCS INSTRUCT IT TO BE USED — with `/Users/YOU`
# replaced by the real home — because since the home-secret requirement
# (Codex + Greptile P1, PR #704) the un-edited file MUST be refused: its
# placeholder paths deny nothing. Both halves are asserted, and the second is
# the one that matters: an example that passed while still saying `/Users/YOU`
# would be an example that protects no one.
if ! declare -F grok_sandbox_preflight >/dev/null; then
  fail "grok_sandbox_preflight is not defined — the example profile cannot be validated"
else
  _ex_edited="$(mktemp)"
  # $ACCT_HOME, not $HOME: the preflight resolves the account home itself, so
  # substituting $HOME here would produce entries it does not require.
  /usr/bin/sed "s|/Users/YOU|${ACCT_HOME:-/nonexistent}|g" "$EXAMPLE" > "$_ex_edited"
  if grok_sandbox_preflight "$_ex_edited"; then
    pass "docs/examples/grok-sandbox.toml passes the preflight once /Users/YOU is replaced, as its instructions say"
  else
    fail "docs/examples/grok-sandbox.toml does not pass the preflight even after substituting the real home — the setup instructions would not work"
  fi
  # Only meaningful when this account HAS a home secret to protect. With none of
  # ~/.ssh, ~/.aws or ~/.netrc present the requirement does not apply, the
  # unedited example is legitimately valid, and asserting refusal would assert a
  # bug. Skip loudly rather than fail on a clean account.
  if [[ "$HOME_SECRET_PRESENT" -eq 1 ]]; then
    if grok_sandbox_preflight "$EXAMPLE"; then
      fail "docs/examples/grok-sandbox.toml passes UNEDITED — the /Users/YOU placeholder denies nothing, so an operator who copied it without editing would be told their secrets are kernel-denied when they are not"
    else
      pass "the unedited example is refused, so the /Users/YOU placeholder cannot be mistaken for protection"
    fi
  else
    echo "  SKIP  unedited-example refusal: this account has none of ~/.ssh ~/.aws ~/.netrc, so no absolute entry is required"
  fi
  rm -f "$_ex_edited"
fi

# Every in-tree hook SOURCE must be denied, not just the vendor settings files:
# a project plugin carries its own hooks/hooks.json and is discovered
# separately, so missing one leaves the whole hook vector open.
# Both forms per directory: the bare glob matches only the directory path, the
# `/**` companion its contents. Missing either one leaves a hook file readable,
# and grok loads what it can read.
for _src in '.grok' '.grok/**' '.claude' '.claude/**' '.cursor' '.cursor/**' '.env' '.env.*'; do
  if grep -qF "\"**/$_src\"" "$EXAMPLE" 2>/dev/null; then
    pass "example profile kernel-denies **/$_src"
  else
    fail "example profile does not deny **/$_src — a branch-planted hook, plugin, LSP command or plugin-path redirect there could load and write the CWD"
  fi
done

if grep -qE '^[[:space:]]*extends[[:space:]]*=[[:space:]]*"strict"' "$EXAMPLE" 2>/dev/null; then
  pass "example profile extends strict (reads confined to CWD)"
else
  fail "example profile does not extend strict — reads would not be confined"
fi

# ── containment matching is literal, not glob ───────────────────────────
# The containment tests are `[[ "$subject" == "$root"* ]]`. Only the trailing
# `*` may be a wildcard: if the QUOTED variable were treated as a pattern, a
# checkout at a path containing `[`, `]`, `*` or `?` would silently stop being
# matched as a prefix and the gate would fail OPEN on exactly the case it
# exists for. Bash matches a quoted portion literally, and this pins that —
# raised by CodeRabbit on PR #704, which read the expression as globbing.
for _cr in '/w/re[1]' '/w/re*x' '/w/re?y'; do
  _sub="$_cr/.grok"
  if [[ "${_sub%/}/" == "${_cr%/}/"* ]]; then
    pass "containment still matches under a path containing glob metacharacters ($_cr)"
  else
    fail "containment failed OPEN for a checkout path containing glob metacharacters ($_cr) — the quoted root is being treated as a pattern"
  fi
done

# ...and the production expression must keep the root QUOTED. The loop above
# proves bash matches a quoted portion literally; it does not read
# grok-preflight.sh. An unquoted `${root%/}/*` would turn the root into a
# pattern and fail OPEN on a metacharacter path, with the loop above still
# green.
_unquoted=$(/usr/bin/grep -c '== \${root%/}/\*' "$CHILD" || true)
if [[ "${_unquoted:-0}" -eq 0 ]]; then
  pass "the containment comparisons keep the checkout root quoted"
else
  fail "a containment comparison uses an UNQUOTED root (\${root%/}/*) — a checkout path containing [ ] * or ? would stop matching as a prefix and the gate would fail OPEN"
fi

# ── bash 3.2 parse ──────────────────────────────────────────────────────
# macOS ships /bin/bash 3.2 and this repo's scripts run under it. A construct
# it mis-parses is not a style nit: 3.2 reported this very file's earlier
# heredoc-inside-$() as a syntax error hundreds of lines away, at an unrelated
# `case` arm, and `bash -n` under a Homebrew bash 5 said nothing. That is the
# #595 silent-fail-open shape, so both files are parsed with the real 3.2.
if [[ -x /bin/bash ]] && /bin/bash --version 2>/dev/null | /usr/bin/grep -q 'version 3\.2'; then
  for _f in "$RESOLVE" "$DISPATCH" "$CHILD"; do
    if /bin/bash -n "$_f" 2>/dev/null; then
      pass "$(basename "$_f") parses under macOS /bin/bash 3.2"
    else
      fail "$(basename "$_f") does NOT parse under /bin/bash 3.2 — sourcing it on macOS fails, and the error points at an unrelated line"
    fi
  done
else
  pass "no bash 3.2 on this host — skipping the 3.2 parse check"
fi

# ── a refused preflight is a REFUSAL, not a failed attempt ──────────────
# The consequence that matters: droid must not rescue it. A rescue would ship
# the prompt, and the repo content quoted in it, to a different CLI than the
# one the operator asked for — after being told the lane refuses. It must also
# not be retried, and must not fail a whole batch for the other voices.
_refuse_arm="$(/usr/bin/awk '/^            else$/,/^            fi ;;$/' "$DISPATCH" | /usr/bin/grep -v '^ *#')"
# And the refusal must be self-contained: dispatch.sh tolerates resolve-cli.sh
# being absent, in which case both preflight helpers are undefined — the `if`
# fails with 127 and takes this same branch. Without shims the hint calls also
# fail, $outfile is truncated empty, and the voice reports `skipped` with no
# reason at all.
# Each shim must be guarded on ITS OWN name. Bundling them behind another
# symbol's guard means a resolve-cli.sh that defines that symbol but not these
# — a different plugin version — skips the shims entirely, which is the case
# they exist for.
# `declare -F`, never `type`: type also succeeds for an alias, a builtin, or a
# same-named EXECUTABLE on PATH, so a stray file would skip the fail-closed
# shim and then be run as the verifier.
if /usr/bin/grep -q 'if ! declare -F grok_sandbox_preflight >/dev/null; then' "$DISPATCH"; then
  pass "the preflight shim is guarded on its own name, with declare -F"
else
  fail "the preflight shim guard is missing or uses 'type' — a same-named executable on PATH would satisfy it and be run as the verifier"
fi
if /usr/bin/grep -q 'if ! declare -F grok_preflight_hint >/dev/null; then' "$DISPATCH"; then
  pass "the hint shim is guarded on its own name, with declare -F"
else
  fail "the hint shim guard is missing or uses 'type'"
fi
if /usr/bin/grep -q "type grok_sandbox_preflight\|type grok_preflight_hint" "$DISPATCH"; then
  fail "a shim guard still uses 'type' — it succeeds for executables and aliases too"
else
  pass "no shim guard uses 'type'"
fi
if /usr/bin/grep -q 'grok_sandbox_preflight() { return 1; }' "$DISPATCH"; then
  pass "the preflight shim fails closed"
else
  fail "no fail-closed shim for grok_sandbox_preflight"
fi
if /usr/bin/grep -q 'grok_preflight_hint() {' "$DISPATCH"; then
  pass "a missing resolve-cli.sh leaves a hint shim, so a refusal still states its reason"
else
  fail "no shim for grok_preflight_hint — a refusal would write an empty \$outfile and report 'skipped' with no reason"
fi

if [[ "$_refuse_arm" != *"_grok_refused=1"* ]]; then
  fail "the preflight refusal does not set _grok_refused — the shared loop would read it as a failed CLI and escalate to droid"
else
  pass "the preflight refusal marks itself a refusal, not a failed attempt"
fi

_esc="$(/usr/bin/awk '/&& type should_escalate_to_droid/{found=1} found' "$DISPATCH" | /usr/bin/head -1)"
_esc_guard="$(/usr/bin/awk '/^    if \[\[ "\$CLI" != "all"/,/should_escalate_to_droid "\$name"/' "$DISPATCH")"
if [[ "$_esc_guard" == *'_grok_refused'* ]]; then
  pass "the droid-escalation guard excludes a refused grok preflight"
else
  fail "the droid-escalation guard does not exclude _grok_refused — a refusal would still be rescued, dispatching the prompt to droid"
fi

_retry_guard="$(/usr/bin/awk '/_pi_setup_failed:-0/,/continue/' "$DISPATCH" | /usr/bin/head -8)"
if [[ "$_retry_guard" == *'_grok_refused'* ]]; then
  pass "the retry loop does not retry a refused preflight"
else
  fail "the retry loop does not check _grok_refused — a deterministic refusal would be retried"
fi

if /usr/bin/grep -q '\[\[ "\${_grok_refused:-0}" == "1" \]\] && status="skipped"' "$DISPATCH"; then
  pass "a refused voice is skipped in a batch, not counted as a failure"
else
  fail "a refused grok is not marked skipped — one unconfigured host would fail a whole --cli all batch"
fi

# Availability and execution must agree on WHERE grok lives. `_has_cli` searches
# the ambient PATH; execution uses the pinned one. Gating on both, against two
# different path sets, rejected a pinned-only install as "grok not found" while
# telling the operator that installing it in a pinned location was enough.
if /usr/bin/grep -qE '^\s+\[\[ "\$CLI" == "grok" \]\] && ! _has_cli grok' "$DISPATCH"; then
  fail "grok availability is still gated on the ambient PATH — an install only in ~/.grok/bin would be rejected as 'not found' though the dispatch would have run it"
else
  pass "grok availability is left to the preflight, which looks where the dispatch will run"
fi

# Same for the batch path: --cli all discovery must not drop a pinned-only
# install before it can reach its own preflight.
# The array name is load-bearing and was wrong once: appending to `CLIS` while
# the loop builds `ALL_CLIS` left --cli all omitting grok exactly as before,
# and the first version of THIS test grepped for the typo, so it passed.
# Joining the batch means receiving the batch's flags. grok rejects --model,
# and as a bare `exit 1` that failed the whole batch for every other voice the
# moment a model was pinned — #594's failure mode, reintroduced by the very fix
# that put grok in the batch. It must be a REFUSAL (skipped), like opencode's
# missing .auditor.model.
if /usr/bin/grep -q 'Skipped: %s\\n. "--model is not supported by grok-build' "$DISPATCH"; then
  pass "a --model batch marks grok skipped rather than failing every other voice"
else
  fail "grok's --model rejection does not write a Skipped: marker — a --cli all --model batch fails on grok and takes every other voice down with it"
fi
# Availability and execution must answer the SAME question. A binary-only probe
# said "grok is available" on a host with the binary but no sandbox profile, so
# a ["grok","droid"] route stopped at grok, the dispatch preflight refused, and
# the voice was skipped instead of falling through to droid (Codex, PR #704).
# The fix is delegation, so what this pins is the delegation itself: there is no
# second candidate list left to drift, which is the point.
_avail_body="$(/usr/bin/sed -n '/^_grok_available()/,/^}/p' "$RESOLVE")"
if /usr/bin/printf '%s' "$_avail_body" | /usr/bin/grep -q 'grok_sandbox_preflight'; then
  pass "grok availability delegates to the preflight, so routing and execution agree"
else
  fail "grok availability does not consult grok_sandbox_preflight -- a host with the binary but no sandbox profile would route to grok, be refused at dispatch, and lose its configured droid fallback"
fi
# ...and it must not have grown a private copy of the candidate list again.
if /usr/bin/printf '%s' "$_avail_body" | /usr/bin/grep -q '\.grok/bin'; then
  fail "the availability probe has re-acquired its own candidate directory list -- that duplication is exactly what drifted out of step with the preflight"
else
  pass "the availability probe keeps no candidate list of its own"
fi
# The refusal must still be VISIBLE on a route that names only grok: silently
# degrading everywhere would trade one invisible failure for another.
if /usr/bin/grep -q 'missing:' "$RESOLVE"; then
  pass "a sole-grok route still reports missing:<cli> rather than resolving to nothing"
else
  fail "resolve_role_cli no longer emits a missing:<cli> sentinel -- a broken grok profile on a non-fallback route would resolve silently"
fi

if /usr/bin/grep -q 'elif grok_sandbox_preflight ""' "$DISPATCH"; then
  pass "an already-refused grok skips the preflight instead of overwriting its reason"
else
  fail "the preflight still runs after a --model refusal — it overwrites \$outfile with a profile hint that is not why the voice was skipped"
fi

if /usr/bin/grep -q 'if \[\[ "\$c" == "grok" \]\]; then ALL_CLIS+=("\$c"); continue; fi' "$DISPATCH"; then
  pass "batch discovery appends grok to ALL_CLIS without an ambient-PATH probe"
else
  fail "batch discovery does not add grok to ALL_CLIS — a pinned-only install is silently omitted from --cli all and never reaches its preflight"
fi
if /usr/bin/grep -q 'CLIS+=("\$c"); continue; fi' "$DISPATCH" && ! /usr/bin/grep -q 'ALL_CLIS+=("\$c"); continue; fi' "$DISPATCH"; then
  fail "batch discovery appends to the wrong array (CLIS, not ALL_CLIS) — the append is a no-op for --cli all"
else
  pass "the batch-discovery append targets the array the loop actually uses"
fi

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-grok-sandbox-arm"; else echo "FAIL: test-grok-sandbox-arm"; fi
exit "$FAILED"
