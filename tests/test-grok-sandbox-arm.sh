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
  # is what stops a PATH-shadowed `grok` from running before the sandbox exists.
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
  _profile() {  # $1 = which line to replace, $2 = its replacement ('' drops it)
    local drop="${1:-}" repl="${2:-}"
    local -a lines=(
      '[profiles.busdriver-review]'
      'extends = "strict"'
      'restrict_network = true'
      'deny = ["**/.grok", "**/.grok/**", "**/.claude", "**/.claude/**", "**/.cursor", "**/.cursor/**", "**/.env", "**/.env.*", "**/*.pem", "**/*.key"]'
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
            unicode-key unicode-key-upper multiline decoy-head; do
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
  if /usr/bin/grep -q 'application/x-mach-binary|application/x-executable' "$CHILD"; then
    pass "grok must match the native-image allowlist, not merely application/*"
  else
    fail "the preflight does not allowlist native image types — the file(1) classifier labels unidentifiable data application/octet-stream, and execvp hands a shebang-less script to /bin/sh"
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
  # Mirrors the production predicate, universal-binary handling included: a
  # multi-architecture image reports one line per slice, each prefixed with
  # `(for architecture …):`.
  _allow() {
    local _k
    _k="$(/usr/bin/file -b --mime-type -- "$1" 2>/dev/null | /usr/bin/sed 's/^.*:[[:space:]]*//')"
    [[ -n "$_k" ]] || return 1
    /usr/bin/grep -qvE '^(application/x-mach-binary|application/x-executable|application/x-pie-executable|application/x-sharedlib)$' <<<"$_k" && return 1
    return 0
  }
  if _allow /usr/bin/head; then
    pass "the native-image rule accepts a real binary (/usr/bin/head)"
  else
    fail "the native-image rule rejects a real binary — it would refuse every grok install"
  fi
  for _probe in shebang plain binaryish; do
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
if /usr/bin/grep -qA2 '^why() {' "$CHILD" | /usr/bin/grep -q 'why '; then
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
if declare -F grok_sandbox_preflight >/dev/null && grok_sandbox_preflight "$EXAMPLE"; then
  pass "docs/examples/grok-sandbox.toml passes grok_sandbox_preflight as shipped"
else
  fail "docs/examples/grok-sandbox.toml does not pass the preflight — the setup instructions would not work"
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

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-grok-sandbox-arm"; else echo "FAIL: test-grok-sandbox-arm"; fi
exit "$FAILED"
