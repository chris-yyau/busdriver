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
dispatch_arm="$(awk '/if ! grok_sandbox_preflight; then/,/PROMPT_FILE/' "$DISPATCH")"
resolve_arm="$(awk '/^    grok\)    if ! grok_sandbox_preflight/,/;;$/' "$RESOLVE")"
# The invocation alone — starting AFTER the operator-facing warning, which
# quotes every flag name back and would satisfy any argv assertion on its own.
dispatch_cmd="$(awk '/_portable_timeout "\$_budget" \/usr\/bin\/env \\$/,/PROMPT_FILE/' "$DISPATCH")"
resolve_cmd="$(awk '/\/usr\/bin\/env PATH="\$_GROK_TRUSTED_HOME/,/;;$/' "$RESOLVE")"

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
  case "$site" in
    dispatch) bail='exit 1' ;;
    resolve)  bail='return 1' ;;
  esac
  if [[ "$whole" == *"if ! grok_sandbox_preflight; then"* && "$whole" == *"$bail"* ]]; then
    pass "$where: a failed preflight stops the dispatch ($bail)"
  else
    fail "$where: the preflight result is not acted on — execution would continue past a failed check"
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
  if [[ "$arm" == *"/usr/bin/env"* ]]; then
    pass "$where: env is invoked by absolute path, and the switches ride on it"
  else
    fail "$where: grok arm does not use /usr/bin/env — a PATH-shadowed 'env' would run before grok's sandbox exists"
  fi

  # env resolves the command against the PATH on its own command line, so this
  # is what stops a PATH-shadowed `grok` from running before the sandbox exists.
  if [[ "$arm" == *'PATH="$_GROK_TRUSTED_HOME/.grok/bin'* && "$arm" == *'/opt/homebrew/bin'* ]]; then
    pass "$where: grok is resolved against a PATH pinned to the verified home"
  else
    fail "$where: grok arm does not re-set PATH — an injected PATH could shadow the grok binary itself"
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
  _slug() { printf '%s' "$1" | tr -d '"*/.' ; }
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
    _profile 'deny' "deny = [$_rest]" > "$tmp/missing-$(_slug "${_GLOBS[$_i]}").toml"
  done

  # required globs present only as a COMMENT, with an empty deny array
  _profile 'deny' '# deny = ["**/.grok", "**/.grok/**", "**/.claude", "**/.claude/**", "**/.cursor", "**/.cursor/**", "**/.env", "**/.env.*", "**/*.pem", "**/*.key"]
deny = []' > "$tmp/commented.toml"
  # single-quoted entries whose VALUES contain the quote characters: the denied
  # paths are not the ones a substring search sees
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
            literal-quotes widened quoted-widen squoted-widen read-only-widen \
            unicode-key unicode-key-upper multiline decoy-head; do
    [[ -s "$tmp/$_f.toml" ]] || fail "fixture $_f.toml was not created — its case would pass for the wrong reason"
  done
  [[ -L "$tmp/link.toml" ]] || fail "link.toml is not a symlink — the symlink-refusal case would pass for the wrong reason"

  # The DIRECTORY check has no path override, so it is asserted on the source:
  # a symlinked ~/.grok makes every file inside it repo-controlled while each
  # one is still a regular file.
  if /usr/bin/grep -q '\[\[ -L "\$_gsp_home/.grok" \]\] && return 1' "$RESOLVE"; then
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

  for _g in "${_GLOBS[@]}"; do
    _f="$tmp/missing-$(_slug "$_g").toml"
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

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-grok-sandbox-arm"; else echo "FAIL: test-grok-sandbox-arm"; fi
exit "$FAILED"
