#!/bin/bash
# resolve-cli.sh — Plugin-wide shared CLI library
#
# Single source of truth for CLI availability and resolution.
# Sourced by litmus, blueprint-review, and council.
#
# Usage (sourced):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-cli.sh"
#   is_cli_available codex && echo "codex is installed"
#   resolved=$(resolve_review_cli)
#
# Usage (direct, machine-readable):
#   bash resolve-cli.sh --json
#
# Env var: BUSDRIVER_REVIEW_CLI
# Values: auto (default) | codex | agy | droid | grok | builtin | none

# Intentional pipeline patterns throughout: ls | sort | tail for semver
# ordering, tr | head for JSON sanitisation, etc. — masked return values
# from the inner command are not load-bearing here.
# shellcheck disable=SC2312

# Directory this library lives in — used to locate plugin-owned assets
# (opencode-review-config.json) by absolute path, so a reviewed repo's CWD
# cannot substitute its own.
#
# ${BASH_SOURCE[0]} is EMPTY when this file is sourced from zsh (observed
# 2026-07-20 — the operator's login shell). A bare `dirname ""` yields `.`,
# silently resolving the asset against the CALLER'S CWD, i.e. the reviewed
# repo. That is fail-OPEN, not merely wrong: a missing OPENCODE_CONFIG makes
# opencode fall back to the user's DEFAULT config, restoring the write/bash
# tools this arm exists to remove (verified — the probe wrote its file).
# So resolve best-effort here and have the dispatch arm ASSERT the asset
# exists; never trust this value on its own.
# NOTE the deliberate absence of a `$0` fallback. Under zsh $0 is `zsh`, so
# `dirname` yields `.` and this would resolve to the REVIEWED REPO's CWD — a
# repo-controlled opencode-review-config.json at its root would then satisfy the
# arm's `-f` existence check and be handed to opencode as policy. Empty is the
# correct failure value: the arm treats it as fail-closed and refuses.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  # Use the BUILTIN `${var%/*}` to strip the filename — NOT external `dirname`,
  # which would resolve through a possibly repo-injected PATH at source time
  # (before any arm can pin PATH) and could run an attacker `dirname`. `cd`/`pwd`
  # are builtins too, so this whole computation touches no external command.
  _bd_lib_dir="$(cd "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P)" || _bd_lib_dir=""
else
  _bd_lib_dir=""
fi

# ── Low-level utilities (used by all three systems) ──────────────

is_cli_available() {
  local cli_name="$1"
  if [[ "$cli_name" == "grok" ]]; then
    _grok_available
    return
  fi
  command -v "$cli_name" &>/dev/null
}

# grok availability IS preflight readiness — one question, one answer.
#
# A binary-only probe reported grok available on a host that has the binary but
# not the now-mandatory ~/.grok/sandbox.toml. A route like
# `council.researcher: ["grok", "droid"]` then STOPPED at grok, the dispatch
# preflight refused, and the voice was skipped — an upgraded host silently lost
# its documented droid fallback. Reported by Codex on PR #704.
#
# Delegating wholesale (rather than bolting a profile check onto a copied
# directory list) is what removes the failure class instead of this instance of
# it: the preflight already checks the pinned candidate directories, the binary
# identity, in-tree containment AND the profile contract, so there is now ONE
# definition of "can grok run here" and nothing left to drift out of step.
#
# Note WHICH fallback this is. Falling back at ROUTING time is safe because no
# prompt has been committed to grok yet. Falling back after a DISPATCH-time
# refusal is not, and is deliberately not done: `_grok_refused` exists precisely
# to stop a refused grok's prompt — and the repo content quoted in it — from
# being handed to another CLI after the operator was told the lane refuses.
# Same word, opposite safety, different moment.
#
# Fail direction is safe: anything that prevents the preflight from answering
# (including a shell with no BASH_SOURCE, which resolves the child to /dev/null)
# refuses, so grok reads as unavailable and the route continues to droid.
_grok_available() {
  grok_sandbox_preflight "" && return 0
  # #785: a refusal here is otherwise SILENT. The route simply walks on to
  # droid and the slot is recorded `resolve-droid-fallback`, which names the
  # fallback but never the cause — and `grok_preflight_hint` prints only at
  # DISPATCH time, which a route-time fallback never reaches.
  #
  # Only `runtime-socket` is surfaced, and that is a scoping decision, not an
  # oversight. The other reasons all mean "grok is not set up on this host",
  # where falling through to droid IS the documented behaviour and a warning on
  # every council/blueprint run would be noise. `runtime-socket` is the one
  # where grok is fully installed and configured and still cannot run, for a
  # host reason the operator can fix in one step — the case that had #785's
  # owner re-running FULL coverage against a machine, not a review.
  #
  # Emitted on EVERY runtime-socket refusal, with no dedup state of any kind.
  #
  # It was once-per-process, and that guard is gone rather than fixed. The
  # variable form did not work at all: every production caller reads the
  # resolver through a command substitution (`REVIEWER_3_CLI=$(resolve_role_cli
  # ...)`, `actual=$(resolve_role_cli ...)`), so a flag assigned in that subshell
  # is discarded on exit while the hint — stderr, which `$(...)` does not
  # capture — still reaches the operator every time (Codex, PR #791). The
  # file-marker form that replaced it worked, and cost a HIGH-severity symlink
  # attack to do it: a predictable path under `${TMPDIR:-/tmp}` created by shell
  # redirection, which follows symlinks, lets another local user on a shared
  # /tmp pre-create it as a link and have this truncate any file the victim can
  # write. It also raced (test-then-create is not atomic across concurrent
  # substitutions), and every variant that closes those two fails SILENT on an
  # unwritable TMPDIR — suppressing the warning outright, which is #785's
  # original defect restored by the fix for it (litmus, PR #791).
  #
  # So: no marker, no state, nothing to attack and nothing to go stale. The
  # cost is 2-5 duplicate paragraphs per run, on a host that has grok fully
  # configured AND a symlinked docker.sock — the one operator who needs to read
  # them. Being told repeatedly is strictly better than the silence this whole
  # issue is about. Do not reintroduce a dedup guard here: an advisory line is
  # not worth process state, and both shapes have now been tried.
  if [[ "${_GROK_PREFLIGHT_WHY:-}" == runtime-socket ]]; then
    grok_preflight_hint >&2
  fi
  return 1
}

get_cli_version() {
  local cli_name="$1"
  if is_cli_available "$cli_name"; then
    # grok may not be on the ambient PATH at all — that mismatch is this PR's
    # whole subject. The availability check above ran the preflight, which
    # published the pinned PATH, so ask the binary that would actually run
    # rather than reporting `unknown` for a perfectly good pinned-only install.
    # Guarded on the value being present: if the side effect ever stops being
    # set, this degrades to the ambient lookup rather than running with an
    # empty PATH.
    if [[ "$cli_name" == "grok" && -n "${_GROK_PINNED_PATH:-}" ]]; then
      PATH="$_GROK_PINNED_PATH" command grok --version 2>/dev/null || echo "unknown"
      return
    fi
    "$cli_name" --version 2>/dev/null || echo "unknown"
  else
    echo "not-installed"
  fi
}

get_cli_install_hint() {
  local cli="$1"
  case "$cli" in
    codex)  echo "npm install -g @openai/codex" ;;
    agy)    echo "See https://antigravity.google/docs/cli/" ;;
    droid)  echo "See https://droid.dev" ;;
    grok)   echo "See xAI Grok Build documentation (https://x.ai)" ;;
    opencode) echo "See https://opencode.ai (auth via 'opencode auth login')" ;;
    pi)     echo "See https://github.com/badlogic/pi-mono (check providers with 'pi auth check --provider <name>')" ;;
    *)      echo "Install '$cli' and ensure it is in your PATH" ;;
  esac
}

# ── Config file reader (jq preferred, python3 fallback) ──────
# Usage: _read_config_value "/path/to/busdriver.json" '.routes["council.critic"][0]'
# Returns: extracted value on stdout, empty if missing/error. Exit 1 on parse error.

# `${_JSON_PARSER:-}` (not a bare "") preserves a value inherited from the
# environment across re-sourcing — the deliberate test hook that lets
# test-ultimate-config.sh force `_JSON_PARSER=python3` to exercise the
# python3 normalization branch. Prod never sets it, so behavior is unchanged.
_JSON_PARSER="${_JSON_PARSER:-}"

# NOTE on hardening scope: this shared reader keeps its long-standing posture —
# a bare `jq`/`python3` command word, which an attacker-controlled function table
# can shadow (`BASH_FUNC_jq%%` via a committed settings.json, #325). That is the
# documented accepted residual of the opencode arm below and the domain of
# hooks/gate-scripts/lib/sanitized-gate.sh (#325 / ADR 0016); no construct inside
# a bash process whose function table is already owned can undo it — `local`,
# `return` and `printf` are shadowable too. The one value that must not rest on
# that residual — `.auditor.model`, which picks the third party a review is
# transmitted to — is therefore NOT read through this path at all;
# `resolve_auditor_model` reads it in a clean `env -i` process instead.
_detect_json_parser() {
  if [[ -n "$_JSON_PARSER" ]]; then return; fi
  if command -v jq &>/dev/null; then
    _JSON_PARSER="jq"
  elif command -v python3 &>/dev/null; then
    _JSON_PARSER="python3"
  else
    echo "busdriver: cannot parse config — install jq or python3" >&2
    _JSON_PARSER="none"
  fi
}

_read_config_value() {
  local config_path="$1" jq_query="$2"
  [[ ! -f "$config_path" ]] && return 0

  _detect_json_parser

  case "$_JSON_PARSER" in
    jq)
      jq -r "$jq_query // empty" "$config_path" 2>/dev/null || return 1
      ;;
    python3)
      # -I (isolated): do NOT prepend the CWD to sys.path, and ignore PYTHONPATH /
      # PYTHON* env vars. Without it `python3 -c` imports `json` from the CURRENT
      # DIRECTORY first — which, for every review path, is the REVIEWED CHECKOUT.
      # A fork committing a `json.py` at its root would execute arbitrary code
      # inside the reviewer (verified: it prints from the planted module). This
      # branch reads config that gates external transmission and review routing,
      # so the interpreter must not import anything the reviewed repo controls.
      # Safe for this script: it uses stdlib (json/sys/re) only.
      python3 -I -c "
import json, sys, re

def parse_jq_path(query):
    query = query.lstrip('.')
    parts = []
    while query:
        if query.startswith('[\"'):
            end = query.index('\"]')
            parts.append(query[2:end])
            query = query[end+2:]
        elif query.startswith('['):
            end = query.index(']')
            parts.append(query[1:end])
            query = query[end+1:]
        elif query.startswith('.'):
            query = query[1:]
        else:
            dot = query.find('.')
            bracket = query.find('[')
            if dot == -1 and bracket == -1:
                parts.append(query)
                break
            elif bracket != -1 and (dot == -1 or bracket < dot):
                parts.append(query[:bracket])
                query = query[bracket:]
            else:
                parts.append(query[:dot])
                query = query[dot:]
    return parts

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for k in parse_jq_path(sys.argv[2]):
        if isinstance(data, list):
            data = data[int(k)]
        elif isinstance(data, dict):
            data = data.get(k)
        else:
            sys.exit(0)
        if data is None:
            sys.exit(0)
    if data is not None:
        print(data)
except (KeyError, IndexError, TypeError, ValueError):
    pass
except (json.JSONDecodeError, OSError) as e:
    print('busdriver: config parse error: ' + str(e), file=sys.stderr)
    sys.exit(1)
" "$config_path" "$jq_query" 2>/dev/null || return 1
      ;;
    none)
      return 0
      ;;
  esac
}

# _read_user_config_value <jq-path> <default>
# Reads ONLY the USER config (~/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json) —
# NEVER repo-controlled project config. Security-sensitive: callers gate
# external-transmission / cost / model surfaces on this, so a malicious branch
# must never be able to opt a reviewer in via committed project config.
# Returns the value, or <default> when absent/null/unreadable.
_read_user_config_value() {
    local jq_path="$1" default="$2" val="" state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
    local user_config="$HOME/$state_dir/busdriver.json"
    if [[ -f "$user_config" ]]; then
        val="$(_read_config_value "$user_config" "$jq_path" 2>/dev/null || true)"
    fi
    if [[ -n "$val" && "$val" != "null" ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

# ── Auditor (opencode / Mechanism Witness) model ────────────────
# The model id handed to `opencode run -m`. Configurable so the operator can
# switch provider or model without editing dispatch code:
#
#   ~/.claude/busdriver.json  →  { "auditor": { "model": "opencode-go-lb/deepseek-v4-flash" } }
#
# USER config ONLY, and no env override — both by the same rule the rest of this
# file follows for external-transmission surfaces (#325 / ADR 0016): the value
# picks WHICH third party the witness prompt is shipped to, and a reviewed fork
# controls its own project `.claude/busdriver.json` and can inject env via
# `settings.json`.
#
# CALLER CONTRACT — pass a TRUSTED $HOME. "USER config" is only as trustworthy as
# the path it is read from, and `$HOME` is itself repo-injectable (#325): a fork's
# settings.json can point it at a directory the fork controls, which would let the
# reviewed repo choose the model — i.e. choose where its own review is sent. Both
# dispatch sites therefore call this as `HOME="$_oc_home" resolve_auditor_model`,
# with `_oc_home` derived from the PASSWORD DATABASE, exactly as the opencode arm
# already does for the binary lookup.
#
# The read runs in a CLEAN PROCESS, not through `_read_config_value`. Every other
# config value tolerates the accepted BASH_FUNC_* residual (#325 / ADR 0016);
# this one must not, because it names the third party the review is shipped to,
# and no in-shell construct escapes an attacker-owned function table — `jq`,
# `command`, `printf`, `local` and `return` are all shadowable. `env -i` is the
# escape: exported functions ARE environment variables, so wiping the environment
# wipes the function table, and the child's builtins are trustworthy again. Both
# `/usr/bin/env` and `/bin/bash` are invoked by absolute path (bash refuses to
# import a function whose name contains `/`), so the escape itself is unshadowable.
#
# The state dir is PINNED to `.claude` inside the child. `BUSDRIVER_STATE_DIR` is
# repo-injectable, and no shape-check makes an injectable value safe: the reviewed
# checkout normally lives UNDER the trusted home, so any accepted value — `../x`,
# `projects/reviewed/.claude`, or a bare `reviewed` for a checkout at
# `$HOME/reviewed` — reaches a busdriver.json the fork commits itself. Consequence:
# a custom state dir does not move THIS key. `~/.claude` always.
#
# READ, VALIDATE, and DEFAULT all happen INSIDE the child. Anything the parent
# runs after obtaining the value is a shadowable command word that could rewrite
# it — `|| true`, an `echo` warning, even `printf` on the result line (each was a
# separate live finding). So the child returns a value that is already final, and
# the parent body is one assignment.
#
# jq first, python3 second — mirroring `_read_config_value`, so a host with only
# one of them still honours an explicitly configured provider. Both are looked up
# by absolute path, and the child always exits 0 so no `|| true` is needed.
#
# `opencode models` lists valid ids.
_bd_read_auditor_model() {
  /usr/bin/env -i "HOME=$1" /bin/bash --noprofile --norc -s "$2" "${3:-auditor}" <<'CHILD'
default="$1"
# The config BLOCK is SELECTED from an enum of literals — never built from the
# parameter. Both readers below take the block name from code, so a caller
# cannot steer the read at a different key, and an unrecognised key degrades to
# the default rather than performing a wildcard read. Constructing a jq path
# from a parameter would open a second injection surface inside the very child
# that exists to escape one.
# `shape` selects the validation grammar below. opencode-style lanes name a
# provider AND a model (`provider/id`); agy's own ids are bare, with no provider
# segment, so requiring a slash there would reject every valid value and
# silently degrade to the default. Deliberately no example id in this comment:
# an id may appear at its default constant and nowhere else (see
# tests/test-auditor-model-config.sh), or the prose goes stale next to it.
case "$2" in
  auditor)  jqf='.auditor.model | select(type=="string") // empty';  pykey='auditor';  shape='slash' ;;
  pi_read)  jqf='.pi_read.model | select(type=="string") // empty'; pykey='pi_read'; shape='slash' ;;
  pi_read_raw) jqf='.pi_read.model | select(type=="string") // empty'; pykey='pi_read'; shape='any' ;;
  pi_legacy_raw) jqf='.pi.model | select(type=="string") // empty'; pykey='pi'; shape='any' ;;
  agy_read) jqf='.agy_read.model | select(type=="string") // empty'; pykey='agy_read'; shape='bare'  ;;
  writing_prose) jqf='.writing_prose.model | select(type=="string") // empty'; pykey='writing_prose'; shape='bare' ;;
  # PRESENCE probe for the prose lane. Same hardened child, same enum-of-literals
  # discipline — but `shape='any'` skips the grammar check, so this reports
  # whether the key holds ANY non-empty value. Pairing it with the validated read
  # above is what lets the caller tell "absent" (both empty → use agy's own
  # model, normal) from "present but rejected" (this non-empty, that empty →
  # refuse). Doing the presence read HERE rather than via _read_config_value
  # keeps it inside `env -i` with absolute parser paths; the earlier attempt used
  # that weaker reader and introduced a PATH-resolved code-execution surface to
  # protect a provider selection, which was a losing trade.
  writing_prose_raw) jqf='.writing_prose.model | select(type=="string") // empty'; pykey='writing_prose'; shape='any' ;;
  *)        printf '%s' "$default"; exit 0 ;;
esac
cfg="$HOME/.claude/busdriver.json"
m=""
if [[ -f "$cfg" ]]; then
  for b in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq /bin/jq; do
    if [[ -x "$b" ]]; then m="$("$b" -r "$jqf" "$cfg" 2>/dev/null)"; break; fi
  done
  if [[ -z "$m" ]]; then
    for b in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 /bin/python3; do
      if [[ -x "$b" ]]; then
        m="$("$b" -I -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = (d.get(sys.argv[2]) or {}).get("model")
    print(v if isinstance(v, str) else "")
except Exception:
    pass' "$cfg" "$pykey" 2>/dev/null)"
        break
      fi
    done
  fi
fi
# The value becomes a single argv word after `-m`. No shell eval reaches it, so
# the only real hazards are option injection (a leading `-`) and whitespace or
# control characters. Require the `provider/model` shape opencode actually uses
# (at least one slash, each segment starting alphanumeric); colons and `@` are
# allowed because some providers tag variants `model:tag` or `model@tag` (e.g.
# Vertex Anthropic model ids like `claude-sonnet-4@20250514`). An optional
# trailing `#variant` is allowed too — OpenCode's model-reference docs
# (https://v2.opencode.ai/docs/models) define references as `provider/model`
# with an optional `#variant` (e.g. `openai/gpt-5.2#high`), and rejecting the
# `#` silently dropped a valid user-selected reasoning/token variant. A bad
# value degrades to the CALLER-SUPPLIED default with a loud note rather than
# killing the voice on a typo. Callers that pass an EMPTY default — the auditor
# and pi-read both do — therefore resolve empty and skip, which is the intended
# outcome: no shipped default means no provider is selected that nobody chose.
if [[ "$shape" == 'any' ]]; then
  # PRESENCE probe: report the value as read, with NO grammar check, so the
  # caller can distinguish an absent key from one whose value the grammar
  # rejected. Honest limit: the jq/python readers above both keep only STRINGS,
  # so a present-but-non-string value (a number, a bool) still reads as empty
  # and is therefore indistinguishable from absent. This probe closes the
  # dominant real case — a well-formed string in the wrong grammar, e.g. a
  # `provider/id` pasted from the pi config — not every shape.
  printf '%s' "$m"
  exit 0
fi
if [[ "$shape" == 'bare' ]]; then
  # Same hazards, same guard, one less segment: leading `-` (option injection)
  # and whitespace/control chars stay excluded by the character class. A bare id
  # is the whole value, so no `/` and no `#variant` — those belong to the
  # opencode reference grammar, not agy's.
  _bd_re='^[A-Za-z0-9][A-Za-z0-9._:@-]*$'
  _bd_want='a bare model id with no provider/ prefix'
else
  _bd_re='^[A-Za-z0-9][A-Za-z0-9._:@-]*(/[A-Za-z0-9][A-Za-z0-9._:@-]*)+(#[A-Za-z0-9._-]+)?$'
  _bd_want='provider/model'
fi
if [[ ! "$m" =~ $_bd_re ]]; then
  if [[ -n "$m" ]]; then
    echo "busdriver: ignoring invalid .${pykey}.model '$m' in ~/.claude/busdriver.json (expected ${_bd_want}) — using $default" >&2
  fi
  m="$default"
fi
printf '%s' "$m"
CHILD
}

# NO shipped default, deliberately. The auditor is an AUXILIARY advisory voice,
# and a built-in model id is only ever consulted by an operator who has NOT
# configured one — i.e. the one person guaranteed to hold no credential for
# whichever provider we picked. That dispatch does not "work by default", it
# fails at the provider, so the honest unconfigured outcome is no auditor at
# all. Deleting the constant also ends the drift class for THIS key: there is no
# longer an auditor model id in-tree to go stale. (The `.pi_read.model` default
# below is gone for the same reason; the config example above remains.)
#
# Consequence to know: a MALFORMED `.auditor.model` now also yields empty, so a
# typo skips the voice instead of degrading to a default. The loud stderr note
# from the reader is unchanged, so the operator still learns why.
#
# Result comes back in a VARIABLE: an stdout hand-off would put a shadowable
# `printf`/`echo` on the value's path, undoing the child (verified — an injected
# BASH_FUNC_printf%% overwrote a correctly-read model on its way out). The body
# is `$( )`, `[[ ]]` and assignment: syntax and keywords, none overridable. The
# only command word left is the absolute `/usr/bin/env` inside the reader.
_BD_AUDITOR_MODEL=""
resolve_auditor_model() {
  _BD_AUDITOR_MODEL="$(_bd_read_auditor_model "$HOME" "")"
  # Normalises the function's exit status where `set -e` is suspended: the
  # assignment is now the last statement, so without this the reader's status
  # would become the function's. NOT protection against a failed read — under
  # `set -e` a failed command substitution exits AT the assignment, so this line
  # would never run. Kept as cheap insurance if the reader ever becomes fallible.
  # (The old body ended with a `[[ -n ]] ||` fallback, which returned 0
  # incidentally; that prop went out with the default.)
  return 0
}

# ── Operator home config validation for the opencode arms ────────────
# opencode loads ~/.opencode/opencode.json[c] in EVERY environment — including
# the dispatch sandbox (verified 2026-08-09) — so they are a fourth config
# surface the three isolation boundaries (empty dir, empty XDG_CONFIG_HOME,
# plugin OPENCODE_CONFIG) do NOT cover. An `mcp` entry there would load inside
# the sandbox and read_mcp_resource survives the tool denylist (exactly why
# XDG_CONFIG_HOME is redirected). BOTH opencode arms (execute_review here and
# dispatch.sh's opencode arm) MUST call this before dispatching. The file is
# operator-owned (password-DB home, outside the reviewed repo), so this
# enforces operator discipline — it is NOT an anti-injection boundary.
# Usage: validate_opencode_home_config <home>  →  0 if every existing
# ~/.opencode/opencode.json[c] under <home> is provider/$schema-only or absent;
# 1 otherwise (caller refuses to dispatch).
# On success it ALSO stages a validated copy into a fresh 0700 temp home
# (`_BD_OC_SANDBOX_HOME`) — the dispatch arms run opencode with
# HOME=<sandbox home>, so opencode reads EXACTLY the validated bytes and the
# real ~/.opencode is never reopened (no validate-then-open race: a swap or
# retarget of the real file after validation cannot reach the review lane).
# Operator-username allowlist: only plain [A-Za-z0-9._-] may reach
# `eval echo "~$user"` — AND the name must not BE a tilde directory-stack
# form. Bash treats `~-`/`~+`/`~N`/`~-N`/`~+N` as $OLDPWD/$PWD expansions,
# NOT username lookups: a name matching `^[-+]?[0-9]*$` (e.g. `-0`, `+1`,
# `7`, bare `-`/`+`) would make the reviewed checkout the "trusted home".
# Digit-LEADING names like `0abc` are ordinary usernames and remain valid
# (POSIX permits them) — hence the WHOLE-NAME regex, which a glob cannot
# express (`[0-9]*` matches every digit-leading string). `[[ =~ ]]` is a
# bash builtin — no shadowable command word. (Same allowlist the pi lane's
# probes apply; dispatch.sh carries an identical fallback copy.)
# Usage: _bd_valid_username <name> → 0 valid / 1 invalid
_bd_valid_username() {
  [[ -n "${1:-}" ]] || return 1
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [[ "$1" =~ ^[-+]?[0-9]*$ ]] && return 1
  return 0
}

# Trusted git resolution: /usr/bin/git on a CLT-less macOS is a developer-
# tools SHIM that exists but fails when run — a bare PATH lookup picks it and
# never retries. Probe each candidate by EXECUTION (--version) and take the
# first that works. The candidate list is FIXED (operator-owned install
# dirs), never the caller PATH.
_bd_git=""
_bd_resolve_git() {
  [[ -n "$_bd_git" ]] && return 0
  local _c
  for _c in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do
    if [[ -x "$_c" ]] && /usr/bin/env -i PATH="/usr/bin:/bin" HOME=/tmp "$_c" --version >/dev/null 2>&1; then
      _bd_git="$_c"
      return 0
    fi
  done
  return 1
}

validate_opencode_home_config() {
  local _voh_home="$1" _voh_cfg _voh_py="/usr/bin/python3" _voh_sandbox _c
  # Trusted-path interpreter resolution by EXECUTION probe (never `command -v`:
  # an exported BASH_FUNC_command%% could return an attacker-selected path):
  # /usr/bin/python3 first (CLT), falling through to Homebrew/usr-local when
  # the CLT interpreter is absent OR a nonfunctional shim (CLT-less machines —
  # the reviewer's P2; documented project requirements do not require CLT).
  # Every candidate is an absolute slash-named path in an operator-owned
  # install dir a fork's settings.json cannot write; `-I` isolation applies
  # regardless of which interpreter is chosen.
  _voh_py=""
  for _c in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [[ -x "$_c" ]] && /usr/bin/env -i PATH="/usr/bin:/bin" HOME=/tmp "$_c" -I -c 'import sys' >/dev/null 2>&1; then
      _voh_py="$_c"
      break
    fi
  done
  [[ -n "$_voh_py" ]] || _voh_py="/usr/bin/python3"
  # NO auto-clean of a "previous" sandbox here: this function cannot prove it
  # created a value found in _BD_OC_SANDBOX_HOME (an inherited/exported value
  # could name a CONCURRENT dispatch's sandbox — anchored path checks cannot
  # distinguish "mine" from "another's", both being <home>/.busdriver-oc-home.*).
  # Ownership belongs to the calling lane: the opencode arms run validation
  # INSIDE a trap-owned subshell, so the sandbox they create is cleaned on any
  # exit. The tests clean their own staged homes explicitly.
  _BD_OC_SANDBOX_HOME=""
  # Fail closed if the trusted interpreter is absent (macOS CLT provides it).
  [[ -x "$_voh_py" ]] || { echo "busdriver: cannot validate the operator ~/.opencode home config — $_voh_py not found; refusing to dispatch unconfined." >&2; return 1; }
  # Stage under the TRUSTED home, NOT ${TMPDIR}: TMPDIR is repo-injectable
  # (a fork's settings.json can point it at an observable filesystem), while
  # the password-DB home is the arm's trust anchor. Same filesystem as the
  # real data dir; XDG_CACHE_HOME in the dispatch env keeps the inert model/
  # package cache shared. XDG_DATA_HOME is deliberately NOT set (see the arm
  # comment: the data dir's account state would reopen a config surface).
  _voh_sandbox="$(/usr/bin/mktemp -d "$_voh_home/.busdriver-oc-home.XXXXXX" 2>/dev/null)" || { echo "busdriver: cannot stage the validated opencode home — mktemp failed; refusing to dispatch unconfined." >&2; return 1; }
  # Assign IMMEDIATELY (before populating): a caller's already-armed cleanup
  # trap sees the path during the whole staging window, so TERM mid-staging
  # cannot orphan the (possibly credential-bearing) dir.
  _BD_OC_SANDBOX_HOME="$_voh_sandbox"
  # Ownership marker: cleanup acts ONLY on dirs carrying this marker (or
  # still-empty dirs — nothing credential-bearing was staged yet), so an
  # inherited/exported _BD_OC_SANDBOX_HOME (even one matching the anchored
  # prefix) can never make a lane's trap delete a CONCURRENT dispatch's
  # populated sandbox.
  /usr/bin/touch "$_voh_sandbox/.bd-own" || { echo "busdriver: cannot mark the staged opencode home — refusing to dispatch unconfined." >&2; if /bin/rm -rf "$_voh_sandbox" 2>/dev/null; then _BD_OC_SANDBOX_HOME=""; fi; return 1; }
  # HOME-based SDK credential/config dirs (AWS profiles, Azure, GCP ADC):
  # providers that obtain credentials from ~/.aws etc. must keep reading the
  # REAL files under the redirected HOME. Explicit symlinks into the sandbox,
  # created only for dirs the operator actually has; the review lane is the
  # operator's own process and already read these under the pre-fix HOME=real.
  for _voh_sdk in .aws .azure .config/gcloud; do
    if [[ -e "$_voh_home/$_voh_sdk" || -L "$_voh_home/$_voh_sdk" ]] && [[ ! -e "$_voh_sandbox/$_voh_sdk" ]]; then
      if [[ "${_voh_sdk%/*}" != "$_voh_sdk" ]] && ! /bin/mkdir -p "$_voh_sandbox/${_voh_sdk%/*}" 2>/dev/null; then
        echo "busdriver: cannot stage the sandbox path for $_voh_sdk — refusing to dispatch unconfined." >&2
        if /bin/rm -rf "$_voh_sandbox" 2>/dev/null; then _BD_OC_SANDBOX_HOME=""; fi
        return 1
      fi
      if ! /bin/ln -s "$_voh_home/$_voh_sdk" "$_voh_sandbox/$_voh_sdk" 2>/dev/null; then
        echo "busdriver: cannot stage the operator's $_voh_sdk (provider credential dir) — refusing to dispatch unconfined." >&2
        if /bin/rm -rf "$_voh_sandbox" 2>/dev/null; then _BD_OC_SANDBOX_HOME=""; fi
        return 1
      fi
    fi
  done
  # BOTH the .opencode subdir AND the home-root configs: opencode's ancestor
  # project discovery does NOT stop at the sandbox — it walks up into the
  # real home, so a home-root opencode.json[c] is a discoverable surface too.
  # The staging copy preserves each file's HOME-RELATIVE path, so a home-root
  # opencode.json lands at $sandbox/opencode.json (never colliding with the
  # $sandbox/.opencode/opencode.json copy).
  for _voh_cfg in "$_voh_home/.opencode/opencode.json" "$_voh_home/.opencode/opencode.jsonc" "$_voh_home/opencode.json" "$_voh_home/opencode.jsonc"; do
    # Existence OR link here — `[[ -e ]]` alone follows a symlink and returns
    # false for a DANGLING one, skipping the python O_NOFOLLOW refusal; -L
    # keeps every symlink (live or dangling) on the python path.
    [[ -e "$_voh_cfg" || -L "$_voh_cfg" ]] || continue
    _voh_rel="${_voh_cfg#"$_voh_home"/}"   # .opencode/opencode.json | opencode.json
    if ! "$_voh_py" -I - "$_voh_cfg" "$_voh_sandbox" "$_voh_rel" <<'PY' 2>/dev/null
import json, os, stat, sys

def strip_jsonc(s):
    # String-aware comment + trailing-comma stripping: //, /* */, and a comma
    # directly before } or ] are dropped ONLY outside strings, so a provider
    # value containing e.g. "http://x//y" or "a,}" is never corrupted. A
    # removed comment is replaced by a SPACE so tokens cannot merge
    # (1/*x*/2 must stay invalid, not become 12). An unterminated block
    # comment returns the input UNCHANGED so the strict parse fails (the
    # guard refuses malformed documents rather than silently truncating).
    out = []
    i, n = 0, len(s)
    in_str = False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(s[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if s.startswith("//", i):
            # JSONC line terminators are LF, CR, U+2028, and U+2029 (opencode
            # treats all four): a doc like "//c\u2028\"mcp\":{}" must end the
            # comment at U+2028, exactly as opencode's parser does — otherwise
            # the validator strips "mcp" while opencode still sees it.
            j = i
            while j < n and s[j] not in "\n\r\u2028\u2029":
                j += 1
            if j == n:
                i = n
            else:
                out.append(" ")
                i = j + 1
                if s[j] == "\r" and i < n and s[i] == "\n":
                    i += 1  # consume the LF of a CRLF pair too
            continue
        if s.startswith("/*", i):
            j = s.find("*/", i + 2)
            if j == -1:
                return s  # unterminated — let the strict parse fail
            out.append(" "); i = j + 2
            continue
        if c == ",":
            j = i + 1
            while j < n:
                ch = s[j]
                if ch in " \t\r\n":
                    j += 1
                    continue
                if s.startswith("//", j):
                    k = j
                    while k < n and s[k] not in "\n\r\u2028\u2029":
                        k += 1
                    j = n if k == n else k + 1
                    continue
                if s.startswith("/*", j):
                    k = s.find("*/", j + 2)
                    j = n if k == -1 else k + 2
                    continue
                break
            if j < n and s[j] in "}]":
                i += 1  # trailing comma (even with comments after it) — drop
                continue
        out.append(c); i += 1
    return "".join(out)

def parse(path):
    # Open ONCE with the type check atomic to the read: O_NOFOLLOW refuses a
    # symlink (opencode would follow it), O_NONBLOCK refuses a FIFO (which
    # would otherwise hang, and whose content can differ per open), and fstat
    # after open confirms a REGULAR file — no separate check-then-read gap.
    # Reads are capped at 1 MiB + 1; a longer read REFUSES (truncation would
    # let a padded valid prefix hide invalid trailing content).
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except OSError:
        sys.exit(1)  # missing, symlink, or unreadable — refuse
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            sys.exit(1)  # FIFO / socket / device — refuse
        raw = os.read(fd, (1 << 20) + 1)
    finally:
        os.close(fd)
    if len(raw) > (1 << 20):
        sys.exit(1)  # oversized — refuse, never truncate
    # OpenCode expands {file:...}, {env:...}, and other {name:...} placeholders
    # across config text INCLUDING object keys, so a key like
    # `{"provider":{"p":{"n{env:UNSET}pm":"file:///tmp/evil.mjs"}}}` becomes an
    # npm provider entry at load time, bypassing the npm scan above. Refuse ANY
    # {name: reference (fail-closed; operators inline values instead).
    if b"{" in raw:
        import re as _re
        if _re.search(r"\{[A-Za-z_][A-Za-z0-9_]*:", raw.decode("utf-8", errors="replace")):
            sys.exit(1)
    return raw

try:
    raw = parse(sys.argv[1])
    text = raw.decode("utf-8")  # strict — invalid UTF-8 must REFUSE (opencode would reject it too)
    # Reject Python-only constants (NaN/Infinity): python accepts them,
    # opencode's parser does not — a config opencode refuses to load is not
    # a safe provider-only config.
    def _reject(x):
        raise ValueError(x)
    try:
        d = json.loads(text, parse_constant=_reject)
    except Exception:
        d = json.loads(strip_jsonc(text), parse_constant=_reject)
except Exception:
    sys.exit(1)
# Root must be an object; a non-object ([] / ["provider"] / scalar) is not a
# provider-only configuration and must refuse.
if not isinstance(d, dict):
    sys.exit(1)
# The top-level allowlist is not enough: an `npm` key ANYWHERE inside a
# provider block — including per-model overrides
# (`provider.<id>.models.<model>.provider.npm`, which opencode prioritizes
# over the provider-level value) — makes opencode load that package
# in-process (arbitrary code execution in the review lane; no `mcp` key
# needed). The dispatch lane's providers must be defined without npm
# (built-in openai-compatible handling; verified), so any nested npm key
# refuses. Recursive, because models can carry their own provider objects.
def has_npm(v):
    if isinstance(v, dict):
        return "npm" in v or any(has_npm(x) for x in v.values())
    if isinstance(v, list):
        return any(has_npm(x) for x in v)
    return False

_prov = d.get("provider", {})
if not isinstance(_prov, dict) or any(has_npm(v) for v in _prov.values()):
    sys.exit(1)
if [k for k in d if k not in ("provider", "$schema")]:
    sys.exit(1)
# Stage the VALIDATED bytes (the same read) into the sandbox home at the
# HOME-RELATIVE path (argv[3]); the dispatch arms run opencode with
# HOME=<sandbox home>, so opencode consumes exactly these bytes and the real
# ~/.opencode is never reopened. The relative path keeps home-root and
# .opencode configs in distinct destinations.
try:
    dest = os.path.join(sys.argv[2], sys.argv[3])
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "wb") as f:
        f.write(raw)
except Exception:
    sys.exit(1)
sys.exit(0)
PY
    then
      echo "busdriver: $_voh_cfg is loaded by opencode inside the sandbox and is not a safe provider-only config (unparseable, keys beyond provider/\$schema, non-regular file, or an npm package reference) — refusing to dispatch unconfined." >&2
      # Clear the global only if the removal actually succeeded — otherwise
      # the lane's EXIT trap retries it with the still-live handle.
      if /bin/rm -rf "$_voh_sandbox" 2>/dev/null; then _BD_OC_SANDBOX_HOME=""; fi
      return 1
    fi
  done
  # Auth availability: copy the operator's auth.json (single fd, same
  # O_NOFOLLOW+fstat+size+JSON discipline as the config) into the sandbox
  # DATA dir. The arms set XDG_DATA_HOME=$sandbox/.local/share, so opencode
  # reads THIS copy — auth-based providers work — while the rest of the data
  # dir stays EMPTY: no account/org state, no wellknown credentials, nothing
  # that merges config after OPENCODE_CONFIG. Fail-open with a warning: the
  # lane's own provider carries apiKey in the validated config, so an
  # unstageable auth.json costs auth-based providers only. There is no
  # write-back — the real file is never modified by the lane (a token
  # refreshed mid-run is lost; the next dispatch re-copies the real file).
  _voh_authp="$_voh_home/.local/share/opencode/auth.json"
  if [[ -e "$_voh_authp" || -L "$_voh_authp" ]]; then
    # exit 0 = staged / nothing to stage; exit 2 = source unreadable (fail-open,
    # warned — the lane's own provider is apiKey-based); exit 1 = write or
    # cleanup failure (FAIL-CLOSED — a partial/incorrectly-permissioned
    # auth.json left in the sandbox would break every provider's auth parse).
    _voh_auth_rc=0
    _bd_oc_stage_auth_json "$_voh_authp" "$_voh_sandbox" "$_voh_py" || _voh_auth_rc=$?
    if [[ "$_voh_auth_rc" -eq 0 ]]; then
      :  # staged (or nothing to stage)
    elif ! _bd_oc_auth_rc_classify "$_voh_auth_rc" "$_voh_sandbox"; then
      return 1
    fi
  fi
  return 0
}

# Copy auth.json into <sandbox>/.local/share/opencode/auth.json with the same
# O_NOFOLLOW+fstat+size+JSON discipline and born-0600 write semantics as the
# opencode arms. exit 0 = staged; 2 = fail-open; 1 = fail-closed.
# Usage: _bd_oc_stage_auth_json <src_auth.json> <sandbox_home> [<python>]
_bd_oc_stage_auth_json() {
  local _src="$1" _sand="$2" _py="${3:-/usr/bin/python3}"
  "$_py" -I - "$_src" "$_sand" <<'PY' 2>/dev/null
import errno, json, os, stat, sys

src, sand = sys.argv[1], sys.argv[2]
try:
    fd = os.open(src, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
except OSError:
    sys.exit(2)  # missing/symlink/unreadable — caller warns, fails open
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        sys.exit(2)  # FIFO/socket/device — fail open (no auth staged)
    raw = os.read(fd, (1 << 20) + 1)
finally:
    os.close(fd)
if len(raw) > (1 << 20):
    sys.exit(2)  # oversized — fail open (no auth staged)
try:
    # Reject Python-only constants (NaN/Infinity) and non-dict roots
    # (null/[]): python's default loads accepts them, opencode's parser or
    # auth schema does not — staging them would turn fail-open into a
    # failed dispatch.
    def _reject(x):
        raise ValueError(x)
    parsed = json.loads(raw.decode("utf-8"), parse_constant=_reject)
    if not isinstance(parsed, dict) or not parsed:
        sys.exit(2)  # empty/malformed — fail open (nothing staged)
except Exception:
    sys.exit(2)  # mid-write/unparseable — fail open
d = os.path.join(sand, ".local", "share", "opencode")
dest = os.path.join(d, "auth.json")
try:
    os.makedirs(d, exist_ok=True)
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # born 0600 — no chmod-after window
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
except Exception:
    # If the destination exists after a failed write, it is partial or
    # incorrectly permissioned and MUST NOT stay for opencode; if the unlink
    # fails too, FAIL CLOSED. ENOENT/ENOTDIR prove the destination never
    # existed (nothing partial) — fail open; any OTHER lookup failure leaves
    # the state unknown — fail closed.
    try:
        os.lstat(dest)
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.ENOTDIR):
            sys.exit(2)
        sys.exit(1)
    try:
        os.unlink(dest)
    except Exception:
        sys.exit(1)  # partial file may remain — FAIL CLOSED
    sys.exit(2)      # cleaned up — fail open
PY
}

# Auth staging rc classifier: 0 = staged (ok); 2 = source unreadable/nothing
# staged (fail-OPEN, warned — the lane's own provider is apiKey-based); ANY
# other nonzero (1 = partial may remain; 137/143 = helper killed mid-write)
# FAILS CLOSED — a partial auth.json must never be left for opencode.
# Usage: _bd_oc_auth_rc_classify <rc> <sandbox_home>  →  0 continue / 1 refuse
_bd_oc_auth_rc_classify() {
  local _rc="$1" _sb="${2:-}"
  [[ "$_rc" -eq 0 ]] && return 0
  if [[ "$_rc" -eq 2 ]]; then
    echo "busdriver: WARNING — could not stage the operator auth.json; auth-based providers will be unavailable this dispatch (apiKey-based providers unaffected)." >&2
    return 0
  fi
  echo "busdriver: the operator auth.json could not be staged and a partial file may remain in the sandbox — refusing to dispatch unconfined." >&2
  if /bin/rm -rf "$_sb" 2>/dev/null; then _BD_OC_SANDBOX_HOME=""; fi
  return 1
}

# Anchored sandbox-home cleanup: the path must be a DIRECT child of the
# trusted home with our mktemp prefix, AND its basename must carry the prefix
# (the prefix pattern's trailing `*` would otherwise match "/../" traversal —
# the basename can never contain a slash). Used by both opencode arms'
# cleanup traps, so a forged _BD_OC_SANDBOX_HOME can never point rm -rf at an
# unrelated path.
# Usage: _bd_rm_sandbox_home <path> <trusted_home>
_bd_rm_sandbox_home() {
  local _p="${1:-}" _home="${2:-}"
  [[ -n "$_p" && -n "$_home" ]] || return 0
  case "$_p" in
    "$_home"/.busdriver-oc-home.*) ;;
    *) return 0 ;;
  esac
  [[ "${_p##*/}" == .busdriver-oc-home.* ]] || return 0
  [[ -f "$_p/.bd-own" ]] || { [[ -z "$(/bin/ls -A "$_p" 2>/dev/null)" ]] || return 0; }   # marked, or still-empty (nothing staged yet — early-orphan window)
  /bin/rm -rf "$_p" 2>/dev/null || { echo "busdriver: WARNING — could not remove staged opencode home $_p" >&2; return 1; }
}

# Lane cleanup for the opencode arms: neutral-dir and sandbox-home removal.
# EXIT runs it once; the TERM/INT handlers run it and then EXIT (a caught
# signal otherwise resumes the run with its HOME already deleted). ${VAR:-}
# guards keep the handlers alive under set -u even when the signal lands
# before staging assigned the sandbox variable. The caller's exit status is
# captured FIRST and returned, so a cleanup failure (each removal is
# individually non-fatal) can neither abort the later steps under set -e nor
# replace the lane's original status.
# Usage: _bd_oc_lane_cleanup <real_home> <neutral_cwd>
_bd_oc_lane_cleanup() {
  local _rc=$?
  /bin/rm -rf "$2" 2>/dev/null || true
  _bd_rm_sandbox_home "${_BD_OC_SANDBOX_HOME:-}" "$1" || true
  return "$_rc"
}

# ── Pi read lane model ──────────────────────────────────────────
#
# Operator migration is an intentional hard cut: legacy `.pi.model` is not
# read, aliased, or used as a fallback. Configure `.pi_read.model` explicitly.
#
#   ~/.claude/busdriver.json  →  { "pi_read": { "model": "<provider>/<model-id>" } }
#
# ONE key carries provider AND model: `pi --model provider/id` is pi's own
# documented reference form (verified — a single --model flag carrying both
# runs without a separate --provider), so this reuses the auditor key's shape
# and its validation regex verbatim rather than inventing a second config
# grammar. `pi --list-models` enumerates valid ids.
#
# Same trust rules as the auditor model, for the same reason: the value names
# the third party an exploration prompt — which quotes repo source — is shipped
# to. USER config only, no env override, no project config, and the CALLER MUST
# pass a password-DB-derived $HOME (a repo-injectable $HOME would let a reviewed
# fork choose where its own contents are sent).
#
# NO shipped default, deliberately — an unset or invalid `.pi_read.model` resolves
# empty and the lane skips, rather than silently selecting a provider nobody chose.
#
# A *configured* model may still be region-gated: some providers return HTTP 403
# `RegionError` without their workspace opt-in, and the voice then produces no
# output. That is why the pi arm surfaces the child's stderr into the transcript
# rather than swallowing it — a 403 must read as a diagnosable provider error, not
# a silent dead voice. `pi --list-models` enumerates the alternatives, and
# `pi auth check --provider <name>` confirms one is reachable before use.

_BD_PI_READ_MODEL=""
_BD_PI_READ_MIGRATION_REQUIRED=0
resolve_pi_read_model() {
  local _new_raw _legacy_raw
  _new_raw="$(_bd_read_auditor_model "$HOME" "" pi_read_raw)"
  _legacy_raw="$(_bd_read_auditor_model "$HOME" "" pi_legacy_raw)"
  _BD_PI_READ_MIGRATION_REQUIRED=0
  if [[ -z "$_new_raw" && -n "$_legacy_raw" ]]; then
    _BD_PI_READ_MODEL=""
    _BD_PI_READ_MIGRATION_REQUIRED=1
    echo "busdriver: legacy .pi.model is no longer read; move the provider/model value to .pi_read.model before using the pi-read lane." >&2
    return 0
  fi
  _BD_PI_READ_MODEL="$(_bd_read_auditor_model "$HOME" "" pi_read)"
  # Normalises the function's exit status where `set -e` is suspended. NOT
  # protection against a failed read: under `set -e` a failed command
  # substitution exits AT the assignment, so this line would never run.
  return 0
}

# ── agy READ-lane model ─────────────────────────────────────────
# Scoped to `--cli agy-read` ONLY. Plain `--cli agy` — the blueprint-review
# reviewer_1 slot and every other reviewer dispatch — passes no `--model` and so
# keeps agy's own configured model. That separation is the point: the read lane
# wants a cheap fast model per dispatch, the reviewer slot must not silently get
# downgraded to it.
#
# Same trust rules as `.pi_read.model` (USER config only, no env override, no project
# config, password-DB-derived $HOME): the value names the third party this
# repo's source is shipped to. `agy models` enumerates ids.
BUSDRIVER_AGY_READ_MODEL_DEFAULT="gemini-3.7-flash-medium"

_BD_AGY_READ_MODEL=""
resolve_agy_read_model() {
  _BD_AGY_READ_MODEL="$(_bd_read_auditor_model "$HOME" "$BUSDRIVER_AGY_READ_MODEL_DEFAULT" agy_read)"
  [[ -n "$_BD_AGY_READ_MODEL" ]] || _BD_AGY_READ_MODEL="$BUSDRIVER_AGY_READ_MODEL_DEFAULT"
}

# ── writing-prose lane model ────────────────────────────────────
# Scoped to `--cli agy-prose` ONLY, exactly as `.agy_read.model` is scoped to
# `--cli agy-read`. Plain `--cli agy` (blueprint-review reviewer_1 and friends)
# is unaffected and keeps agy's own configured model.
#
# Same trust rules as `.pi_read.model` / `.agy_read.model` (USER config only, no env
# override, no project config, password-DB-derived $HOME): the value names the
# third party your prose — and anything quoted into the brief — is shipped to.
# `agy models` enumerates ids; the value is BARE (no `provider/` segment).
#
# DELIBERATE DIVERGENCE from pi and agy_read — do NOT "unify" this away:
# there is no shipped default and empty is NOT a refusal. Empty means "pass no
# --model", i.e. agy's own configured model, which is the behaviour this lane
# was validated on. The read lane refuses on empty because falling through to
# agy's model would silently price every repo read at the reviewer's model;
# prose has no such cost cliff, and a writer that stops dead because an
# optional key is unset is worse than one that uses the operator's own default.
_BD_WRITING_PROSE_MODEL=""
resolve_writing_prose_model() {
  _BD_WRITING_PROSE_MODEL="$(_bd_read_auditor_model "$HOME" "" writing_prose)"
}

# Presence probe — see the `writing_prose_raw` enum entry. Non-empty here with an
# EMPTY resolve_writing_prose_model means the key was set to something the `bare`
# grammar rejected, which the lane refuses rather than dispatching on a model the
# operator did not choose. Both empty means absent, which is this lane's normal.
_BD_WRITING_PROSE_RAW=""
resolve_writing_prose_raw() {
  _BD_WRITING_PROSE_RAW="$(_bd_read_auditor_model "$HOME" "" writing_prose_raw)"
}

# ── Portable timeout wrapper ────────────────────────────────────
# macOS does not ship GNU timeout. Try timeout, then gtimeout,
# then fall back to a Perl alarm wrapper.

_portable_timeout() {
  local duration="$1"
  shift

  if command -v timeout &>/dev/null; then
    timeout "$duration" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$duration" "$@"
  else
    # Perl alarm fallback (available on all macOS)
    perl -e '
      use POSIX ":sys_wait_h";
      our $pid = fork();
      if (!defined $pid) { die "fork failed: $!"; }
      if ($pid == 0) { alarm 0; exec @ARGV[1..$#ARGV]; die "exec failed: $!"; }
      $SIG{ALRM} = sub { kill "TERM", $pid if $pid; exit 124 };
      alarm $ARGV[0];
      waitpid($pid, 0);
      alarm 0;
      if ($? & 127) { exit(128 + ($? & 127)); }
      exit($? >> 8);
    ' "$duration" "$@"
  fi
}

# ── Runtime droid fallback predicate ────────────────────────────
# Should a FAILED primary CLI fall back to droid at runtime? Shared by the
# council (dispatch.sh — per-voice, no cap) and blueprint-review
# (run-design-review-loop.sh — capped at one voice). This is the RUNTIME
# fallback (a voice ran but failed), distinct from the resolve-time
# availability fallback (a binary is missing) handled by the route arrays below.
# Args: primary_cli exit_code output_file
# Returns 0 (escalate) iff: primary != droid AND droid installed AND
#   (exit_code != 0 [includes 124 timeout] OR output_file empty/missing).
should_escalate_to_droid() {
  local primary_cli="$1" exit_code="$2" output_file="$3"
  [[ "$primary_cli" == "droid" ]] && return 1
  # grok NEVER escalates, by name and unconditionally — the same rule pi and
  # opencode already get at dispatch.sh's call site, but enforced HERE, inside
  # the predicate, so it cannot be dropped by editing that one call site.
  #
  # This closes the DISPATCH path only. There is a second, independent droid
  # fallback: blueprint-review's post-run loop calls `_bp_droid_rescue` directly
  # (skills/blueprint-review/scripts/run-design-review-loop.sh) and never
  # consults this predicate. That path is guarded separately, by the same
  # name-keyed rule, inside `_bp_droid_rescue` itself. Both guards are load-
  # bearing; neither subsumes the other.
  #
  # `_grok_refused` covered only the STATIC refusals (preflight failed, --model
  # rejected). When the preflight PASSES and grok then fails at RUNTIME — most
  # importantly when the custom profile cannot be applied and grok refuses to
  # start with its protections missing — that flag is still 0, the failure reads
  # as an ordinary CLI error, and the prompt plus the repo content quoted in it
  # is forwarded to droid. A sandbox that correctly refused to run would have
  # caused the content to be sent to a different provider anyway; the protection
  # would have inverted into the leak it exists to prevent. Reported by Codex
  # (P1) on PR #704.
  #
  # Keyed on the CLI NAME rather than on detecting the sandbox error, because
  # only the name is knowable with certainty: matching grok's failure text would
  # have to enumerate every way a sandbox can fail to apply, and any message it
  # did not anticipate would fail OPEN into exactly this leak. The cost of the
  # blunt rule is that an ordinary transient grok failure no longer gets a droid
  # stand-in — the voice is simply reported failed, which is the correct
  # direction for a cross-provider boundary and is already how pi behaves.
  [[ "$primary_cli" == "grok" ]] && return 1
  is_cli_available droid || return 1
  [[ "$exit_code" -ne 0 ]] && return 0
  [[ ! -s "$output_file" ]] && return 0
  return 1
}

# Classify a droid escalation attempt after Codex failed.
# Args: droid_exit_code droid_stdout
# Prints one of: ok | timeout | no-output | failed
#
# Distinguishes a silent refusal (empty stdout well inside the budget) from a
# spent-budget kill (exit 124). Callers that set timed_out from Codex must clear
# it on no-output so BUILTIN_FALLBACK (rc 3) is not misreported as timeout 124
# (#804). Spent-budget 124 stays timeout.
_classify_droid_escalation_outcome() {
  local droid_exit="$1"
  local droid_out="$2"
  if [[ "$droid_exit" -eq 0 && -n "$droid_out" ]]; then
    echo "ok"
    return 0
  fi
  if [[ "$droid_exit" -eq 124 ]]; then
    echo "timeout"
    return 0
  fi
  if [[ -z "$droid_out" ]]; then
    echo "no-output"
    return 0
  fi
  echo "failed"
  return 0
}

# ── Per-role CLI resolution with config + fallback chain ─────
# Usage: resolve_role_cli "council.critic"
# Precedence: env var > project config > user config > defaults > auto-detect
# Returns: CLI name, "builtin", "none", or "missing:<cli>"

# Is this the Auditor role — the ONLY role opencode may serve? The opencode
# dispatch arm in execute_review always launches the fixed read-only Auditor
# harness (plugin-owned config, --dir empty, XDG/env isolation) regardless of
# which role asked for it, so an "opencode" resolution for any OTHER role would
# silently run the Auditor lens while the output is still labeled as that role's
# reviewer (misleading coverage + arbitration — #436, symmetric to the auditor
# containment guard in resolve_role_cli). Single source of truth for the
# opencode-role restriction used by the non-auditor guards below.
_is_auditor_role() {
  case "$1" in
    council.auditor|blueprint-review.auditor) return 0 ;;
    *) return 1 ;;
  esac
}

_resolve_from_route_array() {
  local config_path="$1" role_key="$2"
  local i=0 cli
  local warned_deprecated_gemini=0
  local warned_deprecated_removed=0
  local last_rejected=""
  local saw_other_entry=0  # any non-rejected, non-resolving entry (missing binary, "auto" fallthrough, etc.)
  while true; do
    cli=$(_read_config_value "$config_path" ".routes[\"$role_key\"][$i]")
    [[ -z "$cli" ]] && break
    if [[ "$cli" == "gemini" ]]; then
      # Skip deprecated entries — config arrays support fallback, so the user's
      # ["gemini", "droid"] route gracefully degrades to droid instead of failing.
      # Warn once per call so a stale config gets visible feedback without spam.
      if [[ "$warned_deprecated_gemini" -eq 0 ]]; then
        echo "busdriver: config route '$role_key' references deprecated 'gemini'; use 'agy' (antigravity) instead — skipping" >&2
        warned_deprecated_gemini=1
      fi
      last_rejected="gemini"
    elif [[ "$cli" == "amp" || "$cli" == "claude" || "$cli" == "aider" ]]; then
      # Removed in the 2026-05-21 dispatch-surface cleanup. Without this skip,
      # a stale ["codex", "amp", "droid"] route would resolve to amp if the
      # binary is still on PATH, then execute_review fails with "Unsupported
      # CLI" because the dispatch case was deleted. Treat as missing so the
      # route walker continues to the next entry.
      if [[ "$warned_deprecated_removed" -eq 0 ]]; then
        echo "busdriver: config route '$role_key' references unsupported '$cli'; use 'codex', 'agy', 'droid', 'grok', or 'opencode' instead — skipping" >&2
        warned_deprecated_removed=1
        last_rejected="$cli"
      fi
    elif [[ "$cli" == "opencode" ]] && ! _is_auditor_role "$role_key"; then
      # opencode is Auditor-ONLY (#436). The opencode dispatch arm always runs the
      # fixed read-only Auditor harness, so honoring it for a normal role would
      # mislabel an Auditor lens as that role's reviewer. Skip it like a removed
      # CLI so ["opencode","droid"] still degrades to droid; a pure ["opencode"]
      # route resolves to unsupported:opencode via the all-rejected check below.
      echo "busdriver: config route '$role_key' references 'opencode', which is only valid for the Auditor role (it always runs the fixed read-only Auditor harness) — skipping" >&2
      last_rejected="opencode"
    elif [[ "$cli" == "auto" ]]; then
      # grok is INTENTIONALLY excluded from the auto-detect cascade. Since
      # 2026-08-19 its containment is enforceable from code (--sandbox
      # busdriver-review + --deny Bash/Edit/MCPTool + the vendor-hook
      # switches), so the
      # exclusion rests on scope, not on an unenforceable model: grok still
      # transmits externally and keeps its web tools, so silently picking it
      # via auto would extend its exposure surface to contexts whose threat
      # model wasn't reviewed. Grok must be explicitly named
      # (BUSDRIVER_REVIEW_CLI=grok, route array entry, or per-role default).
      #
      # opencode is excluded because its read-only posture is not a property of
      # the binary — it is assembled from a plugin-owned config + `--dir` +
      # XDG_CONFIG_HOME isolation (see the opencode) dispatch arm). That harness
      # only exists on the surfaces that build it explicitly (litmus/council/
      # blueprint via execute_review + dispatch.sh). Auto-selecting opencode as a
      # generic CLI would run it WITHOUT that harness, so it must always be named
      # explicitly, never picked by the cascade.
      for auto_cli in codex agy droid; do
        is_cli_available "$auto_cli" && echo "$auto_cli" && return 0
      done
      saw_other_entry=1  # auto fell through — entry wasn't a removed CLI
    elif [[ "$cli" == "none" || "$cli" == "builtin" ]]; then
      echo "$cli" && return 0
    elif is_cli_available "$cli"; then
      echo "$cli" && return 0
    else
      saw_other_entry=1  # named CLI that just isn't installed (e.g., codex missing)
    fi
    i=$((i + 1))
  done
  # Route exhausted without resolution. Only emit the hard unsupported sentinel
  # if every entry was a rejected (deprecated/removed) CLI — e.g., a pure stale
  # ["amp"] or ["gemini", "opencode"] route. If the route mixed rejected entries
  # with missing-binary ones (e.g., ["amp", "codex"] with codex not installed),
  # fall through to legacy defaults instead — the user clearly wanted something
  # working, and a missing codex shouldn't bake in unsupported:amp as the
  # answer just because amp came first in the array.
  if [[ -n "$last_rejected" && "$saw_other_entry" -eq 0 ]]; then
    echo "unsupported:$last_rejected"
    return 0
  fi
  return 1
}

resolve_role_cli() {
  local role_key="$1"
  local _bd_result

  # Auditor containment guard (P1 — PR #435 review). The Auditor's entire
  # value proposition is the read-only opencode sandbox (plugin-owned config +
  # `--dir` + XDG_CONFIG_HOME isolation, see the opencode dispatch arm below).
  # blueprint-review runs against WHATEVER repo it is reviewing — on this
  # public repo that is frequently an untrusted fork/branch — and Step 2 below
  # reads project config from THAT repo's `.claude/busdriver.json`. Without
  # this guard, a hostile branch could ship
  # `{"routes":{"blueprint-review.auditor":["droid"]}}` and Step 2 would
  # honor it BEFORE Step 4b's opencode-only legacy default is ever reached —
  # silently swapping the isolated opencode arm for a normal Droid arm (which
  # defaults to `--auto high`, i.e. real write/exec authority) while the
  # council/blueprint output is still labeled the read-only opencode Mechanism Witness. Route the
  # normal precedence chain through `_resolve_role_cli_impl` as before, but
  # for the Auditor role ONLY accept its "opencode"/"none"/"builtin" outputs;
  # anything else (a project- or user-config route naming any other CLI) is
  # rejected and re-resolved via the Step-4b-equivalent opencode-or-none path,
  # regardless of which source (env/project/user/defaults) produced it.
  case "$role_key" in
    council.auditor|blueprint-review.auditor)
      _bd_result=$(_resolve_role_cli_impl "$role_key")
      case "$_bd_result" in
        opencode|none|builtin) echo "$_bd_result"; return ;;
        *)
          echo "busdriver: ignoring non-opencode route/override '$_bd_result' for auditor role '$role_key' (untrusted-checkout containment) — using opencode-or-none" >&2
          is_cli_available opencode && echo "opencode" && return
          echo "none"
          return ;;
      esac
      ;;
  esac

  _resolve_role_cli_impl "$role_key"
}

_resolve_role_cli_impl() {
  local role_key="$1"
  local env_cli="${BUSDRIVER_REVIEW_CLI:-}"
  # All function-scoped locals declared ONCE up front. Re-declaring `local`
  # for the same name within a function leaks `name=value` to stdout under
  # zsh (silent under bash). This file is sourced; macOS callers run zsh by
  # default, so any re-declaration corrupts the single-line return contract.
  # Never reintroduce `local` inside the if-blocks or for-loop below.
  local ver default_primary default_fallback project_config user_config
  local _git_root cfg cfg_last_rejected cfg_saw_other

  # Step 1: Env var override (hard-fail if unavailable)
  if [[ -n "$env_cli" && "$env_cli" != "auto" ]]; then
    # Reject deprecated CLI names — this is the hard-cutover migration point
    # (gemini → agy). A stale BUSDRIVER_REVIEW_CLI=gemini from before the
    # migration would otherwise resolve to "gemini" (if the binary is still
    # installed) and crash downstream with a cryptic "Unsupported CLI: gemini".
    # Surfacing it here gives the user a clear migration pointer.
    if [[ "$env_cli" == "gemini" ]]; then
      echo "busdriver: BUSDRIVER_REVIEW_CLI=gemini is deprecated; use 'agy' (antigravity) instead" >&2
      echo "unsupported:gemini"
      return
    fi
    case "$env_cli" in
      amp|claude|aider)
        echo "busdriver: BUSDRIVER_REVIEW_CLI=$env_cli is no longer supported; use 'codex', 'agy', 'droid', 'grok', or 'opencode' instead" >&2
        echo "unsupported:$env_cli"
        return ;;
    esac
    # opencode via env override is Auditor-ONLY (#436). For any other role it
    # would run the fixed read-only Auditor harness while the output is labeled
    # as that role's reviewer — reject rather than mislabel. (Auditor roles are
    # handled by resolve_role_cli's containment guard, which calls this impl and
    # accepts opencode; they never reach here for a non-auditor key.)
    if [[ "$env_cli" == "opencode" ]] && ! _is_auditor_role "$role_key"; then
      echo "busdriver: BUSDRIVER_REVIEW_CLI=opencode is only valid for the Auditor role (it always runs the fixed read-only Auditor harness), not '$role_key'" >&2
      echo "unsupported:opencode"
      return
    fi
    if [[ "$env_cli" == "none" || "$env_cli" == "builtin" ]]; then
      echo "$env_cli" && return
    fi
    is_cli_available "$env_cli" && echo "$env_cli" && return
    echo "missing:$env_cli" && return
  fi

  # Step 2: Project config routes
  _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  project_config="${_git_root:+$_git_root/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json}"
  [[ -z "$project_config" ]] && project_config=""  # empty _git_root → skip
  if [[ -f "$project_config" ]]; then
    ver=$(_read_config_value "$project_config" '.version')
    if [[ -n "$ver" && "$ver" != "1" ]]; then
      echo "busdriver: ignoring $project_config (version $ver != 1)" >&2
    else
      _resolve_from_route_array "$project_config" "$role_key" && return
    fi
  fi

  # Step 3: User config routes
  user_config="$HOME/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json"
  if [[ -f "$user_config" ]]; then
    ver=$(_read_config_value "$user_config" '.version')
    if [[ -n "$ver" && "$ver" != "1" ]]; then
      echo "busdriver: ignoring $user_config (version $ver != 1)" >&2
    else
      _resolve_from_route_array "$user_config" "$role_key" && return
    fi
  fi

  # Step 4: Defaults from project config, then user config
  #
  # Per-cfg "all rejected" tracking (mirrors _resolve_from_route_array): when
  # every entry in this cfg's defaults chain is a removed CLI (amp/opencode/
  # claude/aider) and none resolved, emit the unsupported sentinel so the
  # user's stale-but-explicit defaults aren't silently overridden by legacy
  # defaults / auto-detect. Mixed chains (some rejected + some missing-binary)
  # fall through normally — the user clearly intended a working reviewer.
  for cfg in "$project_config" "$user_config"; do
    [[ ! -f "$cfg" ]] && continue
    cfg_last_rejected=""
    cfg_saw_other=0
    default_primary=$(_read_config_value "$cfg" '.defaults.primary')
    if [[ -n "$default_primary" ]]; then
      if [[ "$default_primary" == "auto" ]]; then
        break
      elif [[ "$default_primary" == "gemini" ]]; then
        # Reject deprecated CLI in defaults path — same hard-cutover as Step 1
        echo "busdriver: defaults.primary=gemini is deprecated; use 'agy' (antigravity) instead" >&2
        echo "unsupported:gemini" && return
      elif [[ "$default_primary" == "amp" || "$default_primary" == "claude" || "$default_primary" == "aider" ]]; then
        # Removed CLI in defaults.primary — warn and let execution fall through
        # to defaults.fallback below. Track for the all-rejected check.
        echo "busdriver: defaults.primary=$default_primary is no longer supported; use 'codex', 'agy', 'droid', 'grok', or 'opencode' instead — trying defaults.fallback" >&2
        cfg_last_rejected="$default_primary"
      elif [[ "$default_primary" == "opencode" ]] && ! _is_auditor_role "$role_key"; then
        # opencode is Auditor-ONLY (#436) — see _is_auditor_role. Track as
        # rejected and let defaults.fallback / legacy defaults resolve instead.
        echo "busdriver: defaults.primary=opencode is only valid for the Auditor role (it always runs the fixed read-only Auditor harness), not '$role_key' — trying defaults.fallback" >&2
        cfg_last_rejected="opencode"
      elif [[ "$default_primary" == "none" || "$default_primary" == "builtin" ]]; then
        echo "$default_primary" && return
      elif is_cli_available "$default_primary"; then
        echo "$default_primary" && return
      else
        cfg_saw_other=1  # named CLI not installed — valid intent, just unavailable
      fi
    fi
    # Fallback evaluation runs whether or not defaults.primary was set —
    # a config like {"defaults":{"fallback":"droid"}} (no primary) must
    # still honor the explicit fallback. Pre-fix this block was nested
    # inside `if -n primary`, which silently ignored fallback-only configs.
    default_fallback=$(_read_config_value "$cfg" '.defaults.fallback')
    if [[ "$default_fallback" == "auto" ]]; then
      # Explicit "auto" fallback — run auto-detect inline and return, bypassing
      # Step 4b legacy per-role defaults. "break" would fall into Step 4b first,
      # defeating the user's intent to let auto-detect handle resolution.
      # grok intentionally excluded — see Step 1 (config route "auto") for
      # the rationale: grok's safety model is documented but unenforceable
      # from code, so it must be explicitly named to opt in.
      for cli in codex agy droid; do
        is_cli_available "$cli" && echo "$cli" && return 0
      done
      echo "builtin" && return 0
    fi
    if [[ -n "$default_fallback" ]]; then
      if [[ "$default_fallback" == "gemini" ]]; then
        # Reject deprecated CLI in defaults path — same hard-cutover as Step 1
        echo "busdriver: defaults.fallback=gemini is deprecated; use 'agy' (antigravity) instead" >&2
        echo "unsupported:gemini" && return
      elif [[ "$default_fallback" == "amp" || "$default_fallback" == "claude" || "$default_fallback" == "aider" ]]; then
        # Removed CLI in defaults.fallback — warn and continue.
        echo "busdriver: defaults.fallback=$default_fallback is no longer supported; use 'codex', 'agy', 'droid', 'grok', or 'opencode' instead" >&2
        cfg_last_rejected="$default_fallback"
      elif [[ "$default_fallback" == "opencode" ]] && ! _is_auditor_role "$role_key"; then
        # opencode is Auditor-ONLY (#436) — see _is_auditor_role. Track as
        # rejected; the all-rejected check below emits unsupported:opencode when
        # nothing else in this cfg's defaults chain resolved.
        echo "busdriver: defaults.fallback=opencode is only valid for the Auditor role (it always runs the fixed read-only Auditor harness), not '$role_key'" >&2
        cfg_last_rejected="opencode"
      elif [[ "$default_fallback" == "none" || "$default_fallback" == "builtin" ]]; then
        echo "$default_fallback" && return
      elif is_cli_available "$default_fallback"; then
        echo "$default_fallback" && return
      else
        cfg_saw_other=1
      fi
    fi
    # All-rejected detection: this cfg's defaults chain contained only
    # removed CLIs and nothing else. Emit unsupported so the user's
    # explicit (if stale) intent isn't silently bypassed.
    if [[ -n "$cfg_last_rejected" && "$cfg_saw_other" -eq 0 ]]; then
      echo "unsupported:$cfg_last_rejected"
      return 0
    fi
  done

  # Step 4b: Legacy per-role defaults (backward compat when no config exists)
  case "$role_key" in
    blueprint-review.reviewer_1) is_cli_available agy && echo "agy" && return ;;
    blueprint-review.reviewer_2) is_cli_available codex && echo "codex" && return ;;
    # reviewer_3 (grok) added 2026-05-26: adds xAI lineage to blueprint-review,
    # mirroring the council Researcher promotion. Walks grok → droid → none
    # to match council.researcher and the existing reviewer_1/_2 droid-fallback
    # pattern (all three reviewer slots fall to droid when their primary is
    # missing). Duplicate-droid risk (e.g., both reviewer_1 and reviewer_3
    # landing on droid when agy and grok are both missing) is handled by the
    # loop's REVIEWER_3_DUPLICATE check, which skips reviewer_3 when it
    # collides with a higher slot.
    blueprint-review.reviewer_3) is_cli_available grok  && echo "grok"  && return
                                 is_cli_available droid && echo "droid" && return
                                 echo "none" && return ;;
    blueprint-review.arbiter)    echo "builtin" && return ;;  # arbiter is always Claude
    # Trade-off: when agy/codex are unavailable, these roles fall back to
    # droid. Droid runs at DROID_AUTO_LEVEL=low when invoked from council's
    # pragmatist/critic templates (file-write tier only, no installs/network/
    # git push). This is wider than "voice skipped" but the user opted into
    # this by adopting the droid-fallback default. Override by configuring
    # `"council.pragmatist": ["agy", "none"]` in .claude/busdriver.json to
    # keep the lens pure and let the voice drop when agy is missing.
    council.pragmatist)         is_cli_available agy   && echo "agy"   && return
                                is_cli_available droid && echo "droid" && return
                                echo "none" && return ;;
    council.critic)             is_cli_available codex && echo "codex" && return
                                is_cli_available droid && echo "droid" && return
                                echo "none" && return ;;
    # Grok was promoted to primary on 2026-05-26: xAI lineage adds the only
    # consistent non-Anthropic/non-OpenAI/non-Gemini voice to council Researcher,
    # and demonstrated Researcher-role competencies (file reads, cited external
    # evidence, self-flagging ungrounded claims) match Droid's. Droid stays as
    # fallback so users without grok installed get identical behavior to
    # pre-2026-05-26. This reverses PR #134's "Researcher stays single-CLI"
    # decision — that PR pruned unused backends (opencode/amp/claude/aider) and
    # Grok hadn't shipped yet.
    council.researcher)         is_cli_available grok  && echo "grok"  && return
                                is_cli_available droid && echo "droid" && return
                                echo "none" && return ;;
    # Auditor roles (added 2026-07-20, "opencode" voice) are only routed
    # explicitly in THIS repository's .claude/busdriver.json. Without this
    # case, a repo with no busdriver.json config falls through Step 4b to
    # Step 5's generic auto-detect (codex/agy/droid) instead of "none" —
    # silently bypassing the opencode isolation harness while blueprint's
    # output is still labeled the read-only opencode Mechanism Witness. No droid fallback here
    # (unlike the fixed voices above): a droid Mechanism Witness is explicitly
    # documented as false corroboration for this lens (see skills/council/SKILL.md).
    council.auditor|blueprint-review.auditor)
                                is_cli_available opencode && echo "opencode" && return
                                echo "none" && return ;;
  esac

  # Step 5: Auto-detect — grok intentionally excluded. Not because its
  # containment is unenforceable (since 2026-08-19 it is: --sandbox
  # busdriver-review + --deny Bash/Edit/MCPTool + the vendor-hook switches),
  # but because grok
  # still transmits externally
  # and keeps its web tools, so it must be explicitly named via
  # BUSDRIVER_REVIEW_CLI / route arrays / per-role defaults to opt in.
  # Auto-picking grok would extend its exposure surface to contexts whose
  # threat model wasn't reviewed.
  for cli in codex agy droid; do
    is_cli_available "$cli" && echo "$cli" && return
  done

  # Step 6: Ultimate fallback
  echo "builtin"
}

# ── Review CLI resolution: resolve to ONE cli based on env var ──

resolve_review_cli() {
  resolve_role_cli "litmus.reviewer"
}

# ── Coverage provenance (read-only; does NOT alter resolve_role_cli) ──
# describe_role_resolution <role_key>
# Emits ONE tab-separated line: "<requested>\t<actual>\t<resolution_reason>"
# requested = intended primary (env override, else first non-deprecated route
#   entry, else defaults.primary, else "auto"); actual = resolve_role_cli output.
# reason ∈ ok | resolve-droid-fallback | builtin | missing-cli | unsupported-cli | explicit-none
# Used only by blueprint-review coverage tracking. resolve_role_cli's single-token
# stdout contract is untouched. zsh-safe: all locals declared ONCE up front
# (re-declaring `local` for a name leaks name=value to stdout under zsh).
describe_role_resolution() {
  local role_key="$1"
  local env_cli requested actual reason _git_root project_config user_config cfg i cli
  env_cli="${BUSDRIVER_REVIEW_CLI:-}"
  requested=""

  if [[ -n "$env_cli" && "$env_cli" != "auto" ]]; then
    requested="$env_cli"
  else
    _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    project_config="${_git_root:+$_git_root/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json}"
    user_config="$HOME/${BUSDRIVER_STATE_DIR:-.claude}/busdriver.json"
    for cfg in "$project_config" "$user_config"; do
      [[ -z "$cfg" || ! -f "$cfg" ]] && continue
      i=0
      while true; do
        cli=$(_read_config_value "$cfg" ".routes[\"$role_key\"][$i]")
        [[ -z "$cli" ]] && break
        case "$cli" in
          gemini|amp|claude|aider) i=$((i + 1)); continue ;;
        esac
        # opencode is Auditor-ONLY (#436) — mirror _resolve_from_route_array's
        # filtering (line ~280) so a rejected opencode route entry isn't
        # recorded as "requested" while resolve_role_cli actually falls
        # through to the NEXT entry (e.g. droid). Without this, coverage/
        # provenance metadata attributes the review to a CLI the resolver
        # rejected (Greptile finding, PR #455).
        if [[ "$cli" == "opencode" ]] && ! _is_auditor_role "$role_key"; then
          i=$((i + 1)); continue
        fi
        requested="$cli"; break
      done
      [[ -n "$requested" ]] && break
      cli=$(_read_config_value "$cfg" ".defaults.primary")
      if [[ -n "$cli" ]]; then
        if [[ "$cli" != "opencode" ]] || _is_auditor_role "$role_key"; then
          requested="$cli"; break
        fi
        # defaults.primary=opencode rejected for a non-Auditor role — mirror
        # _resolve_role_cli_impl's Step 4 (line ~463): it tries
        # defaults.fallback next within the SAME cfg rather than stopping.
        # Apply the SAME Auditor-only filter to the fallback — otherwise a
        # {"defaults":{"primary":"opencode","fallback":"opencode"}} config for a
        # non-Auditor role would report requested=opencode while resolve_role_cli
        # rejects both and resolves elsewhere, recreating the provenance mismatch.
        cli=$(_read_config_value "$cfg" ".defaults.fallback")
        if [[ -n "$cli" ]] && { [[ "$cli" != "opencode" ]] || _is_auditor_role "$role_key"; }; then
          requested="$cli"; break
        fi
      fi
    done
    [[ -z "$requested" ]] && requested="auto"
  fi

  actual=$(resolve_role_cli "$role_key")

  case "$actual" in
    none)           reason="explicit-none" ;;
    builtin)        reason="builtin" ;;
    missing:*)      reason="missing-cli" ;;
    unsupported:*)  reason="unsupported-cli" ;;
    droid)
      if [[ "$requested" == "droid" ]]; then reason="ok"; else reason="resolve-droid-fallback"; fi ;;
    *)              reason="ok" ;;
  esac

  printf '%s\t%s\t%s\n' "$requested" "$actual" "$reason"
}

# ── Codex invocation: app-server (preferred) → CLI fallback ────
# The official codex-plugin-cc uses a JSON-RPC app-server protocol that is
# more reliable than piping to `codex exec` (which can hang on stdin).
# We prefer the plugin's companion script when installed; fall back to
# direct CLI invocation otherwise.

_CODEX_COMPANION=""
_resolve_codex_companion() {
  [[ -n "$_CODEX_COMPANION" ]] && return
  # Check common plugin cache locations
  local base="${HOME}/.claude/plugins/cache/openai-codex/codex"
  if [[ -d "$base" ]]; then
    # Find the latest installed version
    local latest
    # sort -t. -k1,1n -k2,2n -k3,3n is portable semver sort (no GNU sort -V needed)
    # shellcheck disable=SC2012 # ls is safe here: version dirs are numeric semver only
    latest=$(ls -1 "$base" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [[ -n "$latest" && -f "$base/$latest/scripts/codex-companion.mjs" ]]; then
      _CODEX_COMPANION="$base/$latest/scripts/codex-companion.mjs"
      return
    fi
  fi
  _CODEX_COMPANION="none"
}

# ── Shared transient-error predicate ────────────────────────────
# Reads candidate CLI output from stdin; returns 0 (true) if it looks like a
# transient failure worth retrying: connection resets, rate-limits, 5xx,
# EAGAIN I/O races. Single source of truth for _execute_codex's retry loop,
# the agy/grok retry wrapper below, and dispatch.sh's dispatch_one (council).
# Match only the `EAGAIN` token (not the phrase "resource temporarily
# unavailable") to avoid false-positives on fork/thread exhaustion that shares
# the same strerror text. The 5xx match is context-qualified (an HTTP/status
# word within a few non-digit chars, or a 5xx reason phrase) so incidental
# 3-digit runs — "line 503", "port 5000", "1500 tokens" — are NOT misread as
# transient server errors and needlessly retried + droid-escalated.
# Keep this regex in sync with the fallback copy in dispatch.sh.
_is_transient_cli_error() {
  grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|rate.limit|overloaded|capacity|too many requests|(http|status|code|response)[^0-9]{0,6}(429|5[0-9][0-9])|internal server error|bad gateway|service unavailable|gateway time-?out|getaddrinfo'
}

# Strict transient signal — only unambiguous network/protocol/5xx error TOKENS
# that never occur in human review prose. This is DELIBERATELY narrower than
# _is_transient_cli_error: it drops the ambiguous words "rate.limit", "overloaded",
# and "capacity", which legitimately appear in review text ("capacity handling
# looks correct"). For the same reason the HTTP reason phrases (bad gateway,
# service unavailable, gateway timeout, internal server error, too many requests)
# match ONLY when adjacent to their numeric status code, in either word order
# ("502 Bad Gateway" or "Bad Gateway (502)") — a bare phrase in clean exit-0
# prose ("bad gateway handling looks correct") is a
# review, not a transient notice, and must not be retried/replaced away. Real
# wrapper notices carry the code; prose does not. Used ONLY to judge whether
# *clean-exit* output is a bare error notice; the broad predicate stays for
# non-zero-exit output, which is genuine error text rather than a possible review.
_is_hard_transient_signal() {
  grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|EPIPE|EAGAIN|socket hang up|fetch failed|getaddrinfo|(http|status|code|response)[^0-9]{0,6}(429|5[0-9][0-9])|(429|5[0-9][0-9])[^0-9a-z]{0,4}(too many requests|bad gateway|service unavailable|gateway time-?out|internal server error)|(too many requests|bad gateway|service unavailable|gateway time-?out|internal server error)[^0-9a-z]{0,4}(429|5[0-9][0-9])'
}

# Max size (chars) of a "bare error notice" — output from a CLI that exits 0
# while printing only a short transient-error message (some wrappers emit a
# network/5xx notice and still exit 0) instead of a real review. A genuine
# review is a substantial JSON/structured payload; this bound plus the JSON-brace
# check below separate the two so a review that merely *discusses* rate limits /
# 5xx (this repo's own reviews do) is never misread as a transient failure.
CLI_BARE_ERROR_MAX_CHARS="${CLI_BARE_ERROR_MAX_CHARS:-512}"

# True (0) when exit-0 output is a bare transient-error notice masquerading as a
# successful review: it is short AND carries a HARD transient signal (a machine
# error token — ECONNRESET, "fetch failed", a context-qualified 5xx, etc. — not a
# mere prose word). A genuine litmus review payload carries the review schema
# (top-level "status" + "issues") and is exempted up front: such a review may
# legitimately *discuss* a 5xx / network condition in a finding (e.g. an "HTTP
# 500 handler lacks tests" description) without being a transient notice. A bare
# error *envelope* like {"error":"ECONNRESET ..."} lacks that schema, so braces
# alone do not exempt it — it still retries. Reviews also typically exceed the
# size bound, a second backstop against misreading them as transient failures.
# True (0) when output reads like a code review *discussing* an error term rather
# than *being* a bare error notice. Freeform council prose (Pragmatist/Critic/
# Researcher) has no "status"/"issues" envelope to key off, so a terse but valid
# reply that names an HTTP/5xx code ("the HTTP 500 handler lacks tests", "503 retry
# path looks correct") would otherwise trip _is_hard_transient_signal and be retried
# away. Every term below is review-assessment vocabulary that does NOT appear in a
# genuine network/5xx error notice ("502 Bad Gateway", "ECONNRESET: socket hang up",
# "fetch failed"), so this guard cannot reclassify a true notice as a review — it
# only rescues prose that the bare-notice heuristic would misfire on.
_reads_as_review_prose() {
  grep -qiE '\b(lacks?|looks (correct|good|fine|right|ok)|need(s|ed)? (a|an|to|more|tests?)|should (add|be|use|have|handle|return|check|verify|guard|consider)|consider|recommend|suggest|missing (a|an|tests?|guards?|checks?|coverage|handling)|edge case|refactor|rename|nit|LGTM|no issues|test coverage|docstring|assertion)\b'
}

_is_bare_transient_notice() {
  local out="$1"
  [[ "${#out}" -le "$CLI_BARE_ERROR_MAX_CHARS" ]] || return 1
  # Review schema present → it's a verdict, not a notice. Never bare.
  if printf '%s' "$out" | grep -qiE '"status"[[:space:]]*:' \
     && printf '%s' "$out" | grep -qiE '"issues"[[:space:]]*:'; then
    return 1
  fi
  # Reads like a review discussing an error term → a verdict, not a notice. Closes
  # the gap the schema exemption leaves open for *freeform* (non-schema) prose.
  if printf '%s' "$out" | _reads_as_review_prose; then
    return 1
  fi
  printf '%s' "$out" | _is_hard_transient_signal
}

# #541: opencode prints "> busdriver-review · <model>" plus blank lines
# UNCONDITIONALLY — healthy runs included — so a run that produced no assistant
# text is NOT byte-empty: it carries just the banner (32 bytes, model id
# length aside).
# The generic empty-output guards test byte size / non-empty strings, so a
# banner-only result was reported as success and never retried. This predicate
# recognizes exactly that: stdin containing ONLY blank lines and/or the
# literal "> busdriver-review ·" agent banner (ANSI escapes stripped first, so
# a styled banner still classifies). The agent name is anchored literally — the
# arm pins --agent busdriver-review — so a Markdown quote that merely contains
# '·' ("> substantive verdict · confidence 95") is substantive prose, not a
# banner. Substantive output keeps every byte.
# True (0) when stdin is banner-only. Mirrored by a fallback copy in
# dispatch.sh; keep the pattern identical there.
# (a) NO `-q` on the grep — grep -q exits as soon as it finds a substantive
# line and SIGPIPEs the upstream printf on any larger stream, so a negated
# pipeline would misclassify substantial output as banner-only and the arm
# would truncate it (litmus round-1 finding). `-c` drains the whole stream.
# (b) The sed runs into a VARIABLE first, NOT into a pipeline: sed exits
# non-zero on malformed UTF-8 in a multibyte locale ("stream did not contain
# valid UTF-8"), and a negated pipeline would invert that processing failure
# into "banner-only" — erasing a substantive review (litmus round-3 finding).
# The `|| return 1` makes any sed failure mean "not banner-only" (keep the
# output). (c) No review text reaches the caller's stdout — the stream is
# consumed by awk/grep inside the condition, and grep's count is discarded
# via >/dev/null (litmus round-2 finding; the predicate runs in an `if`
# condition whose stdout is the CALLER's). (d) The banner exemption is
# anchored to the WHOLE line and applies to the FIRST non-blank line only:
# opencode prints exactly one banner line, at the very start — so a capture
# of a real banner followed by a second banner-SHAPED substantive line
# ("> busdriver-review · PASS") stays substantive (litmus round-4 + PR-mode
# findings). The awk step blanks that first banner line; `grep -c -v` then
# classifies everything else (blank-only exemption). (e) grep's status is
# classified EXPLICITLY, never negated: 0 = substantive lines exist → not
# banner-only; 1 = no substantive lines → banner-only; any other status
# (execution/processing error, in grep OR awk) → NOT banner-only (fail
# closed — a classifier error must never erase a review; litmus round-5
# finding). The status is captured IMMEDIATELY after the pipeline (`rc=$?`)
# — bash resets $? to 1 inside an elif condition, so a `$?` check there
# would match ANY failure status and re-open the fail-open hole (verified
# empirically on bash 5.x).
_oc_output_is_banner_only() {
  local stripped rest rc
  stripped=$(sed "s/$(printf '\033')\[[0-9;]*m//g" 2>/dev/null) || return 1
  # awk runs into a VARIABLE first, its status checked separately: if awk and
  # grep BOTH fail, pipefail surfaces grep's (rightmost) status — a clean
  # "no match" (1) — masking the awk error as banner-only (litmus round-6
  # finding). The `|| return 1` makes any awk failure mean "not banner-only".
  rest=$(printf '%s' "$stripped" | awk '
    /^[[:space:]]*$/ { print; next }
    !seen && /^>[[:space:]]*busdriver-review[[:space:]]*·[[:space:]]*[^[:space:]]*[[:space:]]*$/ { seen=1; print ""; next }
    { seen=1; print }
  ') || return 1
  printf '%s' "$rest" | grep -c -v -e '^[[:space:]]*$' >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    return 0
  fi
  return 1
}

# ── Shared duration validator (retry engines) ────────────────────
# $duration feeds `$(( ))` budget arithmetic in both retry engines below, and
# bash evaluates arithmetic operands RECURSIVELY — a numeric-prefixed string
# such as `1+x[$(cmd)]` would execute `cmd` during expansion. Callers derive
# it from repo-injectable env (#325 / ADR 0016), so validate BEFORE any
# arithmetic touches it — fail closed, not guess. Also strips leading zeros,
# since `$(( ))` reads a leading-zero operand as OCTAL (`0600` → 384s
# silently, `08` → "value too great for base"). One copy shared by
# `_run_review_with_retries` and `_execute_codex` so a future fix can't be
# applied to one call path and silently missed in the other (this exact
# arithmetic-injection guard is security-relevant).
# Prints the normalized duration on stdout and returns 0, or prints nothing
# and returns 1 with an error on stderr.
_validate_positive_duration() {
  local label="$1" duration="$2"
  case "$duration" in
    ''|*[!0-9]*)
      echo "busdriver: ${label} duration must be a non-negative integer (got: $duration)" >&2
      return 1
      ;;
  esac
  duration="${duration#"${duration%%[!0]*}"}"
  [[ -z "$duration" ]] && duration=0
  if [[ "${#duration}" -ge 8 ]]; then
    echo "busdriver: ${label} duration is implausibly large (got: $duration)" >&2
    return 1
  fi
  duration=$((10#$duration))
  if [[ "$duration" -lt 1 ]]; then
    echo "busdriver: ${label} duration must be >= 1 second" >&2
    return 1
  fi
  printf '%s' "$duration"
}

# ── Retry wrapper for non-codex review CLIs (agy / grok) ────────
# Codex has its own richer retry loop in _execute_codex. agy and grok were
# single-shot until now, so one transient hiccup dropped the voice straight to
# droid. This retries up to BUSDRIVER_CLI_RETRIES (default 3; blueprint-review
# exports 5) on a transient failure or an empty-but-clean exit, with short
# exponential backoff. It NEVER retries a timeout (124) — re-running the full
# window is too costly; the caller's droid fallback catches that. Echoes the
# final output to stdout and returns the final exit code.
# Args: <label> <prompt> <duration> <cmd...>  (cmd reads the prompt from stdin)
_run_review_with_retries() {
  # $4 = STDIN MODE, an EXPLICIT argument: `pipe` (default, prompt on fd 0) or
  # `none` (prompt already in argv; hand the child /dev/null).
  #
  # It is an argument and NOT an ambient variable on purpose. Reading it from the
  # environment — even via bash dynamic scoping from a caller's `local` — means a
  # repo-controlled .claude/settings.json `env` block can set it (#325 / ADR 0016)
  # and starve EVERY stdin-mode reviewer: grok and agy 1.0.x would receive an
  # empty prompt, find nothing, and return a vacuous PASS, silently defeating the
  # review gate. Verified before this fix: an inherited `_RRWR_STDIN_MODE=none`
  # turned an 11-byte prompt into STDIN_BYTES=0. An argument cannot be injected.
  #
  # Unknown/empty values fall back to `pipe` — the mode that always delivers the
  # prompt, so a malformed caller degrades to "reviewer sees the prompt", never to
  # "reviewer sees nothing".
  local label="$1" prompt="$2" duration="$3" stdin_mode="${4:-pipe}"; shift 4
  case "$stdin_mode" in pipe|none) ;; *) stdin_mode=pipe ;; esac
  local max_retries="${BUSDRIVER_CLI_RETRIES:-3}"
  local retry_delay="${BUSDRIVER_CLI_RETRY_DELAY:-5}"
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac
  case "$retry_delay" in ''|*[!0-9]*) retry_delay=5 ;; esac
  duration=$(_validate_positive_duration "${label} review" "$duration") || return 1
  # The WHOLE retry sequence — every attempt PLUS all backoff sleeps — is bounded
  # to ~"$duration" (the caller's total budget): each attempt's timeout is the
  # REMAINING budget (equals "$duration" on the first attempt), and each backoff
  # is capped to the remaining budget so the sleep itself can't overrun. Retries
  # therefore never multiply the wall-clock to (retries+1)× the timeout; once the
  # budget is spent we stop and let the caller's droid fallback take over.
  local attempt=0 exit_code=0 output="" start now remaining cap
  start=$(date +%s)
  while [[ "$attempt" -le "$max_retries" ]]; do
    exit_code=0
    if [[ "$attempt" -eq 0 ]]; then
      # The FIRST attempt always runs with the full budget — set it directly (not
      # via now-start) so a sub-second clock tick can never zero it out and skip
      # the only invocation. Only RETRIES are budget-gated below.
      remaining="$duration"
    else
      now=$(date +%s); remaining=$(( duration - (now - start) ))
      # A retry needs budget for the backoff PLUS at least a 1s attempt; if the
      # remaining budget can't fund a 1s attempt, escalate now instead of
      # sleeping the rest of the budget away for a retry that can't run.
      if [[ "$remaining" -le 1 ]]; then
        echo "⟳ ${label}: retry budget (${duration}s) spent — escalating instead of retrying" >&2
        # Budget exhaustion is a CLI FAILURE, not a real timeout — use a generic
        # non-zero (1), never 124, so callers don't trip their timeout/split path.
        [[ "$exit_code" -eq 0 ]] && exit_code=1
        break
      fi
      # Cap backoff to leave >= 1s for the attempt — never sleep the whole budget.
      cap=$(( remaining - 1 ))
      [[ "$retry_delay" -gt "$cap" ]] && retry_delay="$cap"
      if [[ "$retry_delay" -gt 0 ]]; then
        echo "⟳ ${label} retry ${attempt}/${max_retries} (waiting ${retry_delay}s)..." >&2
        sleep "$retry_delay"
      fi
      retry_delay=$((retry_delay * 2))
      now=$(date +%s); remaining=$(( duration - (now - start) ))
      if [[ "$remaining" -le 0 ]]; then
        echo "⟳ ${label}: retry budget (${duration}s) spent — escalating instead of retrying" >&2
        # Budget exhaustion is a CLI FAILURE, not a real timeout — use a generic
        # non-zero (1), never 124, so callers don't trip their timeout/split path.
        [[ "$exit_code" -eq 0 ]] && exit_code=1
        break
      fi
    fi
    # STDIN MODE. Most CLIs read the prompt from fd 0, so the default pipes it in.
    # A CLI that takes the prompt via ARGV (agy >=1.1, `--print "$prompt"`) never
    # drains fd 0 — and under `pipefail` the upstream `printf` then dies of SIGPIPE
    # as soon as the child exits, making the whole command substitution return 141
    # even though the CLI produced a perfectly good review. Callers read that as a
    # failure and degrade to droid, silently losing the reviewer.
    # Only bites above the ~64 KB pipe buffer: a small prompt is absorbed and exits
    # 0, so this is invisible in light testing and fires on real 40-100 KB review
    # prompts. Verified: 1 KB → rc=0, 200 KB → rc=141 with valid output.
    # Reads the validated $4 argument — never the environment (see the signature).
    if [[ "$stdin_mode" == "none" ]]; then
      output=$(_portable_timeout "$remaining" "$@" </dev/null 2>&1) || exit_code=$?
    else
      output=$(printf '%s' "$prompt" | _portable_timeout "$remaining" "$@" 2>&1) || exit_code=$?
    fi
    # #541: opencode prints "> busdriver-review · <model>" (+ blank lines)
    # UNCONDITIONALLY — healthy runs included — so a banner-only capture is an
    # EMPTY VERDICT, not output: left in place it passes the non-empty
    # classification below (it carries no transient token) and a content-free
    # run reports as success with no retry. Normalize AT THE SOURCE so the
    # empty-output retry and the final empty-verdict failure marking below work
    # untouched. Keyed on the opencode label — agy/grok/droid print no such
    # banner. Sibling: the file-based normalization in dispatch.sh's opencode
    # arm (fallback copy of the predicate lives there too).
    if [[ "$label" == "opencode" ]] && printf '%s' "$output" | _oc_output_is_banner_only; then
      output=""
    fi
    # Timeout → don't retry; let the caller's droid fallback handle it.
    [[ "$exit_code" -eq 124 ]] && break
    # A clean exit with non-empty output is success — UNLESS it is a bare
    # transient notice the CLI emitted while still exiting 0 (a rate-limit/5xx
    # message in place of a review). Those fall through to the retry/droid path
    # below; a real review payload — even one discussing rate limits / 5xx — is
    # accepted here because it carries a JSON object and/or is substantial.
    if [[ "$exit_code" -eq 0 && -n "$output" ]] && ! _is_bare_transient_notice "$output"; then
      break
    fi
    # Retry if the attempt produced NO output (a CLI that died before writing a
    # review — empty is never a valid review, whatever the exit code) OR the
    # failure text looks transient. Otherwise bail (non-transient hard failure
    # that did produce output → the caller's droid fallback owns the rescue).
    if [[ -z "$output" ]] || printf '%s' "$output" | _is_transient_cli_error; then
      attempt=$((attempt + 1))
      continue
    fi
    break
  done
  # Exhausted retries while still empty OR while still emitting a bare transient
  # notice on a clean exit → report a FAILURE, not a silent success: neither an
  # empty review nor a rate-limit/5xx notice is a passing review, and callers key
  # fallback/error handling off this exit status (e.g. execute_review → blueprint
  # droid rescue / litmus error path). Without this, an always-empty or
  # always-rate-limited reviewer would return exit 0 and be treated as a clean run.
  if [[ "$exit_code" -eq 0 ]] && { [[ -z "$output" ]] || _is_bare_transient_notice "$output"; }; then
    exit_code=1
  fi
  printf '%s' "$output"
  return "$exit_code"
}

_execute_codex() {
  local prompt="$1"
  local duration="${2:-1200}"
  # Defaults sized for codex rate-limit windows. At the default 3 retries the
  # backoff sequence is 30, 60, 120 seconds — ~3.5 min of waiting before
  # exhausting and escalating to droid. From retry 2 onward (t≥90s) the
  # sequence clears OpenAI's per-minute (60s) window. The MOST IMPORTANT review
  # paths raise this to 5: blueprint-review and litmus PR mode both export
  # LITMUS_CODEX_RETRIES=5 (backoff 30,60,120,240,480) because those reviews are
  # the gate of record and have no/limited droid net. Sustained outages still
  # fall through to droid as the external-voice safety net. Override via env vars
  # for faster bail or longer patience.
  #
  # THE BACKOFF LADDER IS AN UPPER BOUND, NOT A SCHEDULE. Since the sequence is
  # budget-bounded (see the loop below), those sleeps only run while "$duration"
  # lasts — the 5-retry ladder cannot actually spend 15.5 min inside a 540s
  # LITMUS_TIMEOUT. That mostly preserves the intent it was sized for (#160):
  # rate-limited attempts FAIL FAST, so nearly the whole budget goes to sleeping
  # and 540s still outwaits the per-minute and per-5min windows. What it does cut
  # short is the pathological case — slow attempts that each burn most of the
  # timeout — which is precisely the case that used to blow the 600s harness cap.
  # If a path genuinely needs to outwait an hourly quota, raise ITS duration
  # (LITMUS_TIMEOUT); raising retries alone can no longer buy wall-clock.
  local max_retries="${LITMUS_CODEX_RETRIES:-3}"
  local retry_delay="${LITMUS_CODEX_RETRY_DELAY:-30}"
  # Reasoning effort. Unset (the default) = whatever the codex CLI's own config
  # says — deliberately NOT restated here, because a hardcoded claim about the
  # default drifts silently (#331). Set LITMUS_CODEX_EFFORT to pin a tier for a
  # run; it then applies to EVERY attempt, retries included. There is no effort
  # ladder: retries here fire on rate-limits/5xx/timeouts, which lowering
  # reasoning does not fix — it only makes the attempt that finally succeeds the
  # weakest one, on the gate-of-record review path.
  local codex_effort="${LITMUS_CODEX_EFFORT:-}"

  # Validate env vars are non-negative integers
  local _v
  for _v in "$max_retries" "$retry_delay"; do
    case "$_v" in
      ''|*[!0-9]*)
        echo "busdriver: LITMUS_CODEX_RETRIES and LITMUS_CODEX_RETRY_DELAY must be non-negative integers" >&2
        return 1
        ;;
    esac
  done

  # LITMUS_TIMEOUT is repo-injectable via a fork's settings.json `env` (#325),
  # so validate BEFORE any arithmetic touches it. See _validate_positive_duration
  # for the full rationale (shared with _run_review_with_retries).
  duration=$(_validate_positive_duration "codex review" "$duration") || return 1

  case "$codex_effort" in
    ''|minimal|low|medium|high|xhigh) ;;
    *)
      echo "busdriver: LITMUS_CODEX_EFFORT must be one of: minimal|low|medium|high|xhigh (got: $codex_effort)" >&2
      return 1
      ;;
  esac

  _resolve_codex_companion

  # Pre-buffer the prompt to a file so the companion path can read via
  # --prompt-file instead of fd 0. The companion's stdin reader
  # (lib/fs.mjs readStdinIfPiped → fs.readFileSync(0, ...)) throws
  # "EAGAIN: resource temporarily unavailable, read" when fd 0 has
  # O_NONBLOCK set — a stable condition under Claude Code's Bash tool that
  # retry+backoff cannot clear (the fd flag does not change between
  # attempts). --prompt-file reads via fs.readFileSync(absolutePath) and
  # is unaffected. The direct codex CLI fallback further down still uses
  # stdin; that path only fires when the companion plugin is uninstalled,
  # and codex exec lacks an equivalent file-input flag at present.
  local _prompt_file=""
  if [[ "$_CODEX_COMPANION" != "none" ]] && command -v node &>/dev/null; then
    _prompt_file=$(mktemp -t codex-prompt 2>/dev/null) || _prompt_file=$(mktemp 2>/dev/null) || _prompt_file=""
    if [[ -z "$_prompt_file" || ! -f "$_prompt_file" ]]; then
      echo "busdriver: failed to create temp file for codex prompt" >&2
      return 1
    fi
    if ! printf '%s' "$prompt" > "$_prompt_file"; then
      rm -f "$_prompt_file"
      echo "busdriver: failed to write codex prompt to temp file" >&2
      return 1
    fi
  fi

  local attempt=0
  local exit_code=0
  local output=""
  local last_was_transient=0  # narrows droid fallback to rate-limit/network exhaustion
  local timed_out=0           # a single full-duration timeout is droid-eligible (not retried)
  # The WHOLE retry sequence — every attempt PLUS all backoff sleeps — is bounded
  # to ~"$duration", the same arithmetic _run_review_with_retries uses: each
  # attempt's timeout is the REMAINING budget (equal to "$duration" on the first),
  # and each backoff is capped to the remaining budget so the sleep itself cannot
  # overrun. Before this, EVERY attempt got the full "$duration" — at the PR
  # path's 5 retries that is up to 6x the timeout of wall-clock against a 600s
  # harness cap, and pinned xhigh lengthens each attempt further.
  # SCOPE: this bounds the retry LOOP. The droid escalation below still gets its
  # own "$duration" (it is the safety net, and a droid handed 0s is no net at
  # all), so a droid-eligible failure can still reach ~2x — never 6x. The PR lead
  # disables droid entirely, so that path is bounded at exactly "$duration".
  local start now remaining cap
  start=$(date +%s)

  while [[ "$attempt" -le "$max_retries" ]]; do
    # Budget gate + backoff FIRST, before the per-attempt state resets below — the
    # bail-outs here must still see the PREVIOUS attempt's exit_code and
    # last_was_transient so a budget-exhausted sequence stays droid-eligible.
    if [[ "$attempt" -eq 0 ]]; then
      # The FIRST attempt always runs with the full budget — set it directly (not
      # via now-start) so a sub-second clock tick can never zero it out and skip
      # the only invocation. Only RETRIES are budget-gated.
      remaining="$duration"
    else
      now=$(date +%s); remaining=$(( duration - (now - start) ))
      # A retry needs budget for the backoff PLUS at least a 1s attempt; if the
      # remaining budget can't fund a 1s attempt, escalate now instead of
      # sleeping the rest of the budget away for a retry that can't run.
      if [[ "$remaining" -le 1 ]]; then
        echo "⟳ Codex: retry budget (${duration}s) spent — escalating instead of retrying" >&2
        # Budget exhaustion is a CLI FAILURE, not a real timeout — use a generic
        # non-zero (1), never 124, so callers don't trip their timeout/split path.
        [[ "$exit_code" -eq 0 ]] && exit_code=1
        break
      fi
      # Cap backoff to leave >= 1s for the attempt — never sleep the whole budget.
      cap=$(( remaining - 1 ))
      [[ "$retry_delay" -gt "$cap" ]] && retry_delay="$cap"
      if [[ "$retry_delay" -gt 0 ]]; then
        echo "⟳ Codex retry $attempt/$max_retries (waiting ${retry_delay}s)..." >&2
        sleep "$retry_delay"
      fi
      # Exponential backoff: double delay each retry
      retry_delay=$((retry_delay * 2))
      now=$(date +%s); remaining=$(( duration - (now - start) ))
      if [[ "$remaining" -le 0 ]]; then
        echo "⟳ Codex: retry budget (${duration}s) spent — escalating instead of retrying" >&2
        [[ "$exit_code" -eq 0 ]] && exit_code=1
        break
      fi
    fi

    exit_code=0
    # Reflect only THIS attempt's classification — never carry a prior attempt's
    # transience into the post-loop droid decision. A timeout escalates via its
    # own `timed_out` flag, so resetting here does not weaken timeout handling.
    last_was_transient=0
    local effort_args=()
    if [[ -n "$codex_effort" ]]; then
      effort_args=(--effort "$codex_effort")
    fi

    if [[ "$_CODEX_COMPANION" != "none" ]] && command -v node &>/dev/null; then
      # Use official plugin's app-server protocol via --prompt-file — see the
      # pre-loop comment for the EAGAIN background. Omit --json to get raw
      # review output (--json wraps in an envelope that breaks downstream
      # extract_review_json.py parsing).
      # ${effort_args[@]+...} guards against "unbound variable" when array is
      # empty under set -u (macOS bash 3.2).
      output=$(_portable_timeout "$remaining" node "$_CODEX_COMPANION" task --prompt-file "$_prompt_file" ${effort_args[@]+"${effort_args[@]}"} 2>&1) || exit_code=$?
    else
      # Fallback: direct CLI invocation
      local config_args=()
      if [[ -n "$codex_effort" ]]; then
        config_args=(-c "model_reasoning_effort=\"$codex_effort\"")
      fi
      output=$(printf '%s' "$prompt" | _portable_timeout "$remaining" codex exec -s read-only ${config_args[@]+"${config_args[@]}"} - 2>&1) || exit_code=$?
    fi

    # Success — a clean exit WITH a real review payload. An exit-0 that is empty
    # or only a bare transient notice (a network/5xx envelope the companion
    # emitted while still exiting 0) is NOT a review; fall through to the
    # retry/droid path, mirroring _run_review_with_retries and dispatch_one.
    if [[ "$exit_code" -eq 0 && -n "$output" ]] && ! _is_bare_transient_notice "$output"; then
      break
    fi

    # Timeout (124) — retrying burns the whole window again, so don't; but a
    # timeout IS droid-eligible (a different backend may still answer in time).
    #
    # Classify a 124 by the window the attempt was actually GRANTED, not by its
    # attempt index. An attempt that ran with the FULL "$duration" timed out
    # honestly — Codex couldn't finish in the configured window — so preserve
    # the timeout signal (droid-eligible via timed_out; if droid can't rescue
    # it, the caller sees exit 124 and correctly reads "split the diff"). An
    # attempt granted only a TRUNCATED "$remaining" (the budget is shared across
    # every attempt plus every backoff sleep) hit the shared budget, not a real
    # Codex limit: treat it as budget exhaustion — droid-eligible via
    # last_was_transient (same as the explicit budget-exhaustion breaks above),
    # but NOT timed_out, so a droid-less path falls through to BUILTIN_FALLBACK
    # (return 3) rather than a misleading "genuine timeout" exit 124.
    #
    # Keying on `remaining == duration` rather than `attempt == 0` matters at
    # the edges: with LITMUS_CODEX_RETRY_DELAY=0 and a first attempt that fails
    # fast, date's 1s resolution can leave a RETRY holding the full window — and
    # that retry's 124 is a genuine timeout, which an attempt-index test would
    # have downgraded and silently discarded.
    if [[ "$exit_code" -eq 124 ]]; then
      if [[ "$remaining" -eq "$duration" ]]; then
        timed_out=1
      else
        echo "⟳ Codex: retry timed out on truncated remaining budget (${remaining}s of ${duration}s) — treating as budget exhaustion, not a genuine timeout" >&2
        last_was_transient=1
        exit_code=1
      fi
      break
    fi

    # Only retry on transient Codex service errors (network, API, rate-limit)
    # AND on non-blocking I/O races (EAGAIN). Script bugs (unbound variable,
    # syntax error, command not found) should not be retried.
    #
    # EAGAIN history: the primary historical trigger was the codex-companion
    # reading stdin via fs.readFileSync(0) under Claude Code's Bash tool,
    # where fd 0 has O_NONBLOCK set. That path is now bypassed by writing the
    # prompt to a temp file and passing --prompt-file (see pre-loop block).
    # EAGAIN remains in the retry regex as defense-in-depth in case a future
    # codex version or codepath regresses. We match only the `EAGAIN` token
    # (not the phrase "resource temporarily unavailable") to avoid false-
    # positives on unrelated fork/thread exhaustion errors that share the
    # same strerror text.
    # Retry on transient service errors, OR on a clean exit that produced no real
    # review (empty, or a bare transient notice) — a flake, not a verdict.
    if { [[ "$exit_code" -eq 0 ]] && { [[ -z "$output" ]] || _is_bare_transient_notice "$output"; }; } \
       || printf '%s' "$output" | _is_transient_cli_error; then
      last_was_transient=1
      attempt=$((attempt + 1))
    else
      last_was_transient=0
      echo "⚠️  Codex failed with non-transient error (exit $exit_code) — not retrying" >&2
      break
    fi
  done

  # A clean exit that never yielded a real review (empty, or a bare transient
  # notice, through exhaustion) is not success — promote it to a transient
  # failure so the droid/builtin fallback below engages instead of returning a
  # blank PASS. Mirrors _run_review_with_retries' exhaustion guard.
  if [[ "$exit_code" -eq 0 ]] && { [[ -z "$output" ]] || _is_bare_transient_notice "$output"; }; then
    exit_code=1
    last_was_transient=1
  fi

  # All retries exhausted, non-transient error, or a timeout — try droid (if
  # eligible), else fall back to builtin (or preserve the timeout signal).
  if [[ "$exit_code" -ne 0 ]]; then
    local attempts_run=$(( attempt > max_retries ? max_retries + 1 : attempt + 1 ))
    # Surface codex's captured stderr/stdout so callers writing 2>&1 to a raw
    # log can diagnose the failure. Without this, only the wrapper's own
    # messages survive and the underlying cause is unrecoverable.
    if [[ -n "$output" ]]; then
      printf '%s\n%s\n%s\n' \
        "----- codex output (exit $exit_code) -----" \
        "$output" \
        "----- end codex output -----" >&2
    fi

    # Droid escalation: on transient-error exhaustion (rate-limit, network, 5xx)
    # OR a single full-duration timeout (a different backend may still answer).
    # Non-transient codex failures (script bugs, malformed prompt) would likely
    # break droid too — go straight to builtin in that case.
    #
    # Three opt-outs honored:
    #   1. LITMUS_CODEX_DROID_FALLBACK_DISABLED=1 — matches opt-out convention
    #      (LITMUS_SHORTCIRCUIT_DISABLED, LITMUS_SKIP_*).
    #   2. LITMUS_CODEX_DROID_FALLBACK=0 — earlier name used in pre-merge drafts
    #      of this feature, kept as an alias to avoid silently re-enabling droid
    #      for anyone who adopted that env var.
    #   3. BUSDRIVER_REVIEW_CLI=codex — explicit codex pin. Treat as "user wants
    #      only codex, fall through to builtin if codex fails" — matches the
    #      semantics implied by pinning a single backend.
    local _droid_disabled="${LITMUS_CODEX_DROID_FALLBACK_DISABLED:-0}"
    # Widen to accept common truthy shell boolean conventions (1/true/yes/on).
    if [[ "$_droid_disabled" =~ ^(1|true|yes|on)$ ]]; then _droid_disabled=1; fi
    [[ "${LITMUS_CODEX_DROID_FALLBACK:-1}" =~ ^(0|false|no|off)$ ]] && _droid_disabled=1
    [[ "${BUSDRIVER_REVIEW_CLI:-auto}" == "codex" ]] && _droid_disabled=1
    if { [[ "$last_was_transient" -eq 1 ]] || [[ "$timed_out" -eq 1 ]]; } && \
       [[ "$_droid_disabled" != "1" ]] && \
       is_cli_available droid; then
      local _fail_reason="transient errors"
      [[ "$timed_out" -eq 1 ]] && _fail_reason="timeout"
      echo "⚠️  Codex failed after ${attempts_run} attempt(s) (${_fail_reason}) — escalating to droid" >&2
      local droid_out='' droid_err='' droid_exit=0
      # Bare `droid exec` (default read-only mode, Create/Edit blocked) matches
      # execute_review's posture and the codex `-s read-only` posture this is
      # escalating from. See execute_review droid case for PR #97 historical context.
      # Capture stdout and stderr separately: classification keys on stdout only
      # so an exit-0 diagnostic on stderr is not treated as a successful review
      # (CodeRabbit on #806 / #804).
      local _droid_errf=""
      _droid_errf=$(mktemp -t droid-err 2>/dev/null) || _droid_errf=$(mktemp 2>/dev/null) || _droid_errf=""
      if [[ -n "$_droid_errf" ]]; then
        droid_out=$(printf '%s' "$prompt" | _portable_timeout "$duration" droid exec 2>"$_droid_errf") || droid_exit=$?
        droid_err=$(cat "$_droid_errf" 2>/dev/null || true)
        rm -f "$_droid_errf"
      else
        # Tempfile unavailable — do NOT merge stderr into stdout (that recreates
        # the exit-0+stderr-only false-success). Discard stderr for classification
        # and note the loss so the failure log still explains the gap.
        droid_out=$(printf '%s' "$prompt" | _portable_timeout "$duration" droid exec 2>/dev/null) || droid_exit=$?
        droid_err="(stderr discarded: mktemp unavailable)"
      fi

      # Classify before the post-escalation timed_out check: empty stdout inside
      # budget is a refusal/no-output, not a timeout (#804). Spent-budget 124
      # stays timeout so the caller can still react (split the diff).
      local _droid_outcome
      _droid_outcome=$(_classify_droid_escalation_outcome "$droid_exit" "$droid_out")
      local _droid_ok=0
      [[ "$_droid_outcome" == "ok" ]] && _droid_ok=1
      if [[ "$_droid_outcome" == "no-output" ]]; then
        timed_out=0
      elif [[ "$_droid_outcome" == "timeout" ]]; then
        # Spent-budget droid 124 is a real timeout even when Codex only failed
        # transiently — preserve exit 124 for callers that split the diff.
        timed_out=1
      fi

      # Telemetry: log every escalation regardless of outcome, with droid_ok
      # reflecting the actual success/failure determination. Resolve .claude
      # against the git root, not cwd — hooks fire from whatever subdir the
      # user ran `git commit` in, so a cwd-relative check would silently drop
      # events for any non-root invocation.
      local _git_root=""
      _git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [[ -n "$_git_root" && -d "$_git_root/${BUSDRIVER_STATE_DIR:-.claude}" ]]; then
        printf '{"ts":"%s","event":"codex-droid-fallback","codex_exit":%d,"droid_exit":%d,"droid_ok":%d,"droid_outcome":"%s","codex_attempts":%d}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$exit_code" "$droid_exit" "$_droid_ok" "$_droid_outcome" "$attempts_run" \
          >> "$_git_root/${BUSDRIVER_STATE_DIR:-.claude}/bypass-log.jsonl" 2>/dev/null || true
      fi

      if [[ "$_droid_ok" -eq 1 ]]; then
        [[ -n "$_prompt_file" ]] && rm -f "$_prompt_file"
        printf '%s' "$droid_out"
        return 0
      fi
      echo "⚠️  Droid escalation failed (${_droid_outcome}: exit $droid_exit, output_bytes=${#droid_out}, stderr_bytes=${#droid_err}) — falling back to built-in review" >&2
      if [[ -n "$droid_err" ]]; then
        printf '%s
%s
%s
'           "----- droid stderr -----"           "$droid_err"           "----- end droid stderr -----" >&2
      fi
    fi

    [[ -n "$_prompt_file" ]] && rm -f "$_prompt_file"
    # Timeout with no droid rescue (droid disabled/unavailable, e.g. litmus PR
    # mode or blueprint's one-voice cap) — preserve the timeout signal (exit
    # 124) so the caller can react (litmus: split into smaller commits). Do NOT
    # emit BUILTIN_FALLBACK for a timeout.
    if [[ "$timed_out" -eq 1 ]]; then
      printf '%s' "$output"
      return 124
    fi
    echo "⚠️  Codex failed after ${attempts_run} attempt(s) — falling back to built-in review" >&2
    echo "BUILTIN_FALLBACK"
    return 3
  fi

  [[ -n "$_prompt_file" ]] && rm -f "$_prompt_file"
  printf '%s' "$output"
  return "$exit_code"
}

# ── SECURITY TRADE-OFF: agy prompt travels in argv (accepted residual) ────────
# Delivering the prompt as `--print "$prompt"` puts the ENTIRE review prompt —
# repo content, the full diff, and anything embedded in it — into the process
# argument list. The old `--print /dev/stdin` form did not: fd 0 is not visible
# to `ps`, /proc/<pid>/cmdline, or command-line auditing.
#
# This is a REAL regression in exposure, accepted because there is no alternative
# that works: agy 1.1.4 has no file-input flag, bare `--print` errors with "flag
# needs an argument", and the stdin form is simply broken (it sends the literal
# string "/dev/stdin"). The choice is argv delivery or no agy reviewer at all.
#
# Exposure bounds: on Linux /proc/<pid>/cmdline is world-readable by default
# (mitigate with hidepid, or don't run reviews on a shared host); on macOS other
# users' full argv requires root. The content is the repo's own working tree,
# already readable by the same user — the marginal leak is to OTHER local users
# for the lifetime of the process.
#
# Revisit if: agy gains a file/stdin input flag, or these reviews ever run on a
# multi-tenant host. Do not "fix" by moving the prompt to an env var without
# checking agy supports it — /proc/<pid>/environ has its own exposure profile.
#
# ── agy argv size ceiling (shared by execute_review and dispatch.sh) ──────────
# agy 1.1.x takes the prompt as `--print`'s argv VALUE, so it is subject to the
# kernel's exec limits. TWO independent ceilings apply and they differ by OS:
#   - ARG_MAX          total argv+envp; getconf reports it (macOS 1 MB, Linux ~2 MB)
#   - MAX_ARG_STRLEN   per-ARGUMENT, LINUX ONLY, 32 pages - 1 = 131071 B. Not
#                      reported by getconf, not derived from ARG_MAX, and NOT
#                      present on macOS/BSD — where a single 500 KB argv element
#                      is fine as long as the ARG_MAX total holds.
# Applying the Linux figure unconditionally would reject prompts that macOS
# delivers happily, so it is gated on uname. Review prompts run ~40-100 KB, so on
# Linux the headroom is modest (~30% at the top end) — this is a live constraint,
# not a theoretical one.
_agy_argv_limit() {
    local total linux_strmax=131071
    total=$(( $(getconf ARG_MAX 2>/dev/null || echo 1048576) / 2 ))
    if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] && [[ "$linux_strmax" -lt "$total" ]]; then
        printf '%s\n' "$linux_strmax"
    else
        printf '%s\n' "$total"
    fi
}

# BYTE length of $1 — NOT ${#var}, which counts CHARACTERS under a multibyte
# locale (LANG=*.UTF-8). MAX_ARG_STRLEN and ARG_MAX are byte limits, so a prompt
# of non-ASCII text (CJK review comments, em-dashes, box-drawing in a diff) can
# report far fewer characters than bytes and slip past a ${#var} guard straight
# into the E2BIG this check exists to prevent. LC_ALL=C forces byte semantics.
_agy_bytelen() {
    local LC_ALL=C
    printf '%s' "${1-}" | wc -c | tr -d '[:space:]'
}

# Does this agy read `--print`'s value as PROMPT TEXT (>=1.1) or as a PATH (1.0.x)?
# 1.0.x resolved the value as a file, which is why `--print /dev/stdin` worked
# there; 1.1.x sends it verbatim. Delivering argv unconditionally would break a
# 1.0.x install (it would treat the whole prompt as a filename), so probe once.
# Unknown/unparseable version => assume modern: every current release is >=1.1,
# and guessing "old" would reintroduce the /dev/stdin bug on a working install.
# Cached across calls: the probe spawns a process, and both call sites may run it
# more than once per dispatch. `_AGY_ARGV_PROMPT` holds 1 (argv) or 0 (stdin).
#
# NOT inherited from the environment (`=""`, never `="${_AGY_ARGV_PROMPT:-}"`).
# An inherited value would let anything that can set env — including a committed
# .claude/settings.json `env` block, the #325 / ADR 0016 gate-env threat — pin the
# delivery path: a forced "1" breaks agy 1.0.x by handing it the prompt as a
# filename, and any non-"1" value forces the stdin form that is broken on >=1.1.
# Detection is cheap (bounded, cached per process), so there is nothing to gain by
# letting it be overridden. Only the two assignments below ever populate it, and
# only with a literal 1 or 0.
_AGY_ARGV_PROMPT=""
# Companion to the above, recording WHETHER the probe actually learned the
# version (1) or fell back to the assume-modern default (0). Same
# never-inherited discipline and the same reason: an inherited "1" would forge
# "version confirmed" and re-enable the --model forwarding that
# `_agy_model_flag_supported` below exists to refuse.
_AGY_PROBE_CONCLUSIVE=""
_agy_wants_argv_prompt() {
    case "$_AGY_ARGV_PROMPT" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    local v maj min
    # BOUNDED at 2s: a stalled `agy --version` must not hang the caller before its
    # own bounded invocation begins — that would defeat the outer timeout contract.
    # This probe runs OUTSIDE the caller's review budget (#423), so its cap is added
    # to total wall-clock; capping it keeps that overshoot small (+2s worst case, was
    # +5s). 2s (not 1s) leaves headroom for a working-but-slow CLI cold-starting under
    # CPU/IO contention: a false timeout returns an empty version and routes to
    # "modern" (argv), which MIS-delivers the prompt to a legacy 1.0.x agy — 2s makes
    # that only fire when the CLI is genuinely broken, not merely momentarily slow.
    # (Even then it degrades safely: the mis-route yields no valid review and the
    # caller's droid fallback rescues it — same safe direction as a real timeout.)
    v=$(_portable_timeout 2 agy --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$v" ]]; then _AGY_PROBE_CONCLUSIVE=0; _AGY_ARGV_PROMPT=1; return 0; fi
    _AGY_PROBE_CONCLUSIVE=1
    maj="${v%%.*}"; min="${v#*.}"
    if [[ "$maj" -gt 1 ]] || [[ "$maj" -eq 1 && "$min" -ge 1 ]]; then
        _AGY_ARGV_PROMPT=1; return 0
    fi
    _AGY_ARGV_PROMPT=0; return 1
}

# True only when the probe PARSED a version and that version supports `--model`
# (>=1.1). Runs the probe itself, so callers need not order the two.
#
# The distinction that matters is between the probe's two "argv" outcomes, which
# `_agy_wants_argv_prompt` alone cannot tell apart (both return 0):
#
#   parsed >=1.1        → --model supported.
#   parsed 1.0.x        → not supported (no --model flag at all).
#   INCONCLUSIVE        → not supported *as far as we know*. Assume-modern is the
#     (timeout /          right default for prompt DELIVERY — every current
#      unparseable)       release is >=1.1, and guessing "old" would reintroduce
#                         the /dev/stdin bug on a working install — but it is a
#                         guess, and a guess is not evidence of flag support.
#
# Treating the guess as support is what PR #687 measured: a 1.0.x install whose
# `agy --version` takes longer than the 2s probe budget is classified modern, so
# `--model` is forwarded and the confirmed-1.0.x refusal is never reached. The
# read lane is exempt from droid escalation (deliberately — ADR 0040), so the
# rescue the assume-modern default originally leaned on is gone there, and the
# operator gets agy's raw option/path error instead of an actionable one.
# Refusing an inconclusive probe is the fail-CLOSED direction: it costs a false
# refusal on a merely-slow modern install, which says exactly what happened,
# rather than a confusing failure on a genuinely old one. Codex P2 on PR #687.
_agy_model_flag_supported() {
    _agy_wants_argv_prompt || return 1
    [[ "$_AGY_PROBE_CONCLUSIVE" == 1 ]]
}

# Returns 0 (true) when $1 bytes exceeds the agy argv ceiling. Callers fail loudly;
# the alternative is a raw E2BIG at exec, which surfaces as an empty/garbled reply
# and degrades to "Output was not valid JSON" — the silent failure this whole
# change exists to remove.
_agy_prompt_oversize() {
    local size="${1:-0}" limit
    limit=$(_agy_argv_limit)
    [[ "$size" -gt "$limit" ]]
}

# -- grok sandbox preflight -------------------------------------------------
# The grok lane runs under the CUSTOM sandbox profile `busdriver-review`, not a
# built-in one, because built-in profiles FAIL OPEN (grok warns and runs
# unconfined when the kernel policy cannot be applied) while an explicitly
# requested custom profile refuses to start. Verified 2026-08-19: naming a
# profile that does not exist prints "Refusing to start with its protections
# missing" and exits non-zero.
#
# That guarantee has one hole, and this check closes it. Custom profiles resolve
# from the operator's ~/.grok/sandbox.toml OR a project `.grok/sandbox.toml`;
# the user file wins when both define the name, but with NO user file the REPO's
# definition is what applies — a reviewed branch writing its own containment.
# So: refuse unless the operator's own file defines the profile.
#
# $HOME is not trusted for the lookup. An inherited HOME is repo-injectable via
# a committed settings.json env block (#325 / ADR 0016), which would let the
# reviewed tree aim this check at a sandbox.toml it controls. The home comes
# from the password database instead — the same derivation the agy-read and
# opencode lanes use.
#
# Checking the right file is only half the job: grok reads its config directory
# from $GROK_HOME (default ~/.grok), so verifying the password-database copy
# while the child inherits a repo-set GROK_HOME would check one file and load
# another. On success this publishes the derived home in _GROK_TRUSTED_HOME, and
# BOTH call sites pin HOME and GROK_HOME to it on the `env` line — check and
# child then read the same directory by construction.
#
# $1 overrides the file path and exists ONLY for tests; production callers pass
# nothing and get the derived path.
# The PATH grok is executed under, and the one the preflight checks it against.
# Repo-injectable PATH entries are excluded by construction: only the operator's
# own home and the system prefixes are listed.
# ── grok sandbox preflight ────────────────────────────────────────────────
# Runs every check inside a FUNCTION-CLEAN CHILD: `/usr/bin/env -i /bin/bash -p`.
# That is the point, not a detail. This function is sourced by blueprint-review,
# whose shell has no `bash -p` boundary (dispatch.sh re-execs under one — see its
# header), so an exported BASH_FUNC_* can shadow any name the checks use. Trying
# to clean up from inside that shell is a regress with no bottom: `unset` can be
# shadowed, and so can the `builtin` that would un-shadow `unset`. `env -i` drops
# the exported functions along with the rest of the environment, `-p` stops bash
# re-importing them, and an ABSOLUTE path cannot be shadowed at all — a function
# name may not contain `/`.
#
# The child body avoids `case` on purpose: bash 3.2 (macOS /bin/bash) mis-parses
# a quoted heredoc inside `$( )` when the body contains case patterns, which is
# the #595 silent fail-open this repo has already been bitten by once.
#
# WHAT IT DEFENDS. The grok lane runs under the CUSTOM profile
# `busdriver-review` because built-in profiles FAIL OPEN — grok warns and runs
# unconfined when the kernel policy cannot be applied — while an explicitly
# requested custom profile refuses to start ("Refusing to start with its
# protections missing", verified 2026-08-19). Custom profiles resolve from the
# operator's ~/.grok/sandbox.toml OR a project `.grok/sandbox.toml`; the user
# file wins when both define the name, but with NO user file the REPO's
# definition applies — the reviewed branch writing its own containment. So the
# case being defended against is a MISSING or MISCONFIGURED operator profile.
#
# WHAT IT DOES NOT. A maliciously crafted profile in the operator's own home is
# not in the threat model: an attacker who can write there has already won. The
# body checks below are conservative configuration checks — anything unusual
# (escapes, multiline strings, single-quoted deny entries) is refused rather
# than interpreted. If a legitimate profile ever needs one of those spellings,
# parse TOML properly rather than adding another regex here.
#
# The CALLERS matter as much as this function: both sites put the dispatch in
# the POSITIVE branch of an `if`, never after a `return`/`exit` in a failure
# branch. A shadowed `return` would fall through such a branch straight into the
# dispatch it was meant to stop; there is nothing to fall through into when the
# only path to the invocation is the branch where the check passed.
#
# $1 overrides the file path and exists ONLY for tests; production callers pass
# nothing and get the derived path.
grok_sandbox_preflight() {
  # NO shadowable command word runs in the parent — not even `local` or
  # `return`. Everything here is either a KEYWORD (`[[`, `&&`, `||`, `{`), which
  # bash resolves before functions and which cannot be defined as a function
  # name, a plain ASSIGNMENT, which is not a command lookup at all, or an
  # ABSOLUTE path, which no function name can spell. The function's exit status
  # is the status of its last command, so the `[[ ... ]] && { ... }` at the
  # bottom IS the return value: empty output from the child ⇒ non-zero ⇒ refuse.
  # That is why the variables below are unprefixed globals rather than `local`s.
  # The trailing `|| _GSP_OUT="${_GSP_OUT}"` is a deliberate no-op, not a
  # mistake: `VAR="$(cmd)"` keeps cmd's stdout even when cmd exits non-zero, so
  # the self-assignment preserves the child's WHY= line while neutralising
  # `set -e`. `|| _GSP_OUT=""` would throw the refusal reason away and every
  # failure would report the generic one.
  # The loader blanks apply to THIS exec too, not only to grok's: LD_PRELOAD &
  # friends are processed while /usr/bin/env is being loaded, so without them
  # injected code runs inside the very check that authorises the dispatch — and
  # could forge its HOME=/PATH= success output.
  #
  # They are STATEMENTS, not an assignment prefix on the command substitution:
  # macOS /bin/bash 3.2 mis-parses a prefixed heredoc inside `$( )` and the
  # error surfaces hundreds of lines later, at an unrelated `case` arm (#595,
  # and this file broke exactly that way once during review). Assigning to a
  # variable that was already exported updates the exported value, so the child
  # sees the blank; one that was never in the environment just stays a harmless
  # shell variable.
  # shellcheck disable=SC2034  # not unused: these are inherited EXPORTED vars,
  # and assigning to one keeps it exported with the new (empty) value
  # Clear the outputs FIRST. They are globals (the parent side may not use
  # `local` — see above), so a value inherited from the environment, or left
  # by an earlier dispatch, would otherwise still be sitting there if any
  # path returned success without setting them.
  _GROK_TRUSTED_HOME=''
  _GROK_PINNED_PATH=''
  _GROK_PREFLIGHT_WHY=''
  # shellcheck disable=SC2034  # not unused: inherited EXPORTED vars, and
  # assigning to one keeps it exported with the new (empty) value
  LD_PRELOAD=''
  # shellcheck disable=SC2034
  LD_AUDIT=''
  # shellcheck disable=SC2034
  LD_LIBRARY_PATH=''
  # shellcheck disable=SC2034
  DYLD_INSERT_LIBRARIES=''
  # shellcheck disable=SC2034
  DYLD_LIBRARY_PATH=''
  # The child is a FILE beside this one, not a heredoc inside this `$( )`:
  # macOS /bin/bash 3.2 mis-parses a quoted heredoc in a command substitution
  # once the body carries enough quoting, and reports the error hundreds of
  # lines away at an unrelated `case` arm while bash 5 stays silent (#595).
  # `${BASH_SOURCE[0]%/*}` is parameter expansion, so no command lookup — and
  # it resolves under the installed plugin root, giving the child the same
  # trust as this file rather than the checkout's.
  _GSP_CHILD="${BASH_SOURCE[0]%/*}/grok-preflight.sh"
  [[ -f "$_GSP_CHILD" && ! -L "$_GSP_CHILD" ]] || _GSP_CHILD=/dev/null
  # shellcheck disable=SC2269
  _GSP_OUT="$(/usr/bin/env -i /bin/bash -p "$_GSP_CHILD" "${1:-}")" || _GSP_OUT="${_GSP_OUT}"

  # Publish what the child derived. Both are consumed on the `env` line of the
  # grok invocation, so the file that was checked and the file that is loaded
  # are the same one. A refusal prints `WHY=<reason>` instead, so the HOME=
  # prefix — not emptiness — is the success test, and this compound command is
  # the function's exit status.
  _GROK_PREFLIGHT_WHY="${_GSP_OUT#WHY=}"
  [[ "$_GROK_PREFLIGHT_WHY" == "$_GSP_OUT" ]] && _GROK_PREFLIGHT_WHY="profile"
  [[ "$_GSP_OUT" == HOME=* ]] && {
    _GROK_TRUSTED_HOME="${_GSP_OUT#HOME=}"
    _GROK_TRUSTED_HOME="${_GROK_TRUSTED_HOME%%$'\n'*}"
    _GROK_PINNED_PATH="${_GSP_OUT#*$'\n'PATH=}"
  }
}

# The hint is chosen by the child's reason code, because "install the example
# profile" is wrong advice for five of the six ways this refuses.
grok_preflight_hint() {
  [[ "${_GROK_PREFLIGHT_WHY:-profile}" == identity ]] && printf '%s\n' "Error: grok dispatch refused — could not establish the operator identity or home directory from the password database (dscl/getent). Nothing to fix in the repo; use --cli codex/agy for this dispatch." && return 0
  [[ "${_GROK_PREFLIGHT_WHY:-profile}" == runtime-socket ]] && printf '%s\n' "Error: grok dispatch refused — /var/run/docker.sock is a SYMLINK, and grok's built-in 'strict' base (which this profile extends) refuses to start when it cannot resolve that runtime-socket deny path (#785). Nothing in the sandbox profile can fix it. Remove the symlink, or turn off Docker Desktop's default-socket option that creates it, and retry. Use --cli codex/agy for this dispatch in the meantime." && return 0
  [[ "${_GROK_PREFLIGHT_WHY:-profile}" == configdir ]] && printf '%s\n' "Error: grok dispatch refused — ~/.grok is missing, or is a symlink. A symlinked config directory can be pointed into the reviewed tree, which would hand the branch both the sandbox profile and the grok binary. Replace it with a real directory." && return 0
  [[ "${_GROK_PREFLIGHT_WHY:-profile}" == containment ]] && printf '%s\n' "Error: grok dispatch refused — ~/.grok or ~/.local/bin sits INSIDE the checkout being reviewed, so the branch controls the profile and the binary. Run the review from a checkout that does not contain your home config." && return 0
  [[ "${_GROK_PREFLIGHT_WHY:-profile}" == binary ]] && printf '%s\n' "Error: grok dispatch refused — no grok executable on the pinned PATH (~/.grok/bin, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin), or the first one found resolves into the reviewed tree. Install grok in one of those, or remove the shadowing entry." && return 0
  printf '%s\n' "Error: grok dispatch refused — the operator sandbox profile is missing or does not meet the contract. This lane runs under the CUSTOM profile 'busdriver-review' because built-in profiles fail OPEN, and it must be defined in YOUR ~/.grok/sandbox.toml (a repo-local .grok/sandbox.toml would let the reviewed branch define its own containment). Copy docs/examples/grok-sandbox.toml there, then retry. Use --cli codex/agy for this dispatch in the meantime."
}

execute_review() {
  local cli="$1"
  local prompt="$2"
  local duration="${3:-1200}"

  # IMPORTANT: Caller MUST wrap this call to handle non-zero exits under set -e:
  #   execute_review ... || exit_code=$?
  #   case ${exit_code:-0} in 3) handle_builtin ;; 0) handle_pass ;; *) handle_fail ;; esac
  #
  # `none` is NOT handled here — caller intercepts before calling execute_review.
  # Codex uses the app-server protocol via _execute_codex() when the official
  # plugin is installed, falling back to direct CLI. Other CLIs use stdin piping.
  case "$cli" in
    codex)   _execute_codex "$prompt" "$duration" ;;
    # agy takes the prompt as `--print`'s ARGV VALUE. The former
    # (see _agy_argv_limit / _agy_prompt_oversize above for the size ceiling)
    # `--print /dev/stdin` idiom read fd 0 on agy v1.0.0, but 1.1.x treats the
    # value as literal prompt text: agy answers "It looks like you just sent
    # `/dev/stdin`" — prose, never JSON — so the reviewer slot failed as "Output
    # was not valid JSON", fell back to droid, and silently degraded blueprint
    # coverage below FULL (which withholds the PASS marker entirely). 1.1.4 has no
    # file-input flag and bare `--print` errors with "flag needs an argument", so
    # argv is the only delivery path. SIZE CEILING: the binding limit is NOT the
    # ~1 MB ARG_MAX the old comment cited but Linux's per-argument MAX_ARG_STRLEN
    # (32 pages - 1 = 131071 B), which getconf does not report and which applies to
    # the prompt as a single argv element. Review prompts run ~40-100 KB, so the
    # headroom is real but modest — roughly 30% at the top end, not the 10x the old
    # comment implied. Exceeding it fails loudly (E2BIG at exec) rather than
    # silently truncating — and the agy branch below pre-flights the size via
    # _agy_bytelen/_agy_prompt_oversize, so an oversize prompt is refused with a
    # actionable message rather than reaching exec at all.
    # SAFETY MODEL (#424) — --sandbox always; --dangerously-skip-permissions is
    # OPT-IN PER CALLER, never a blanket default:
    #   --sandbox                       = the CONTAINMENT layer. "Terminal
    #     restrictions enabled": shell/writes/fetch are blocked at the sandbox
    #     layer regardless of permission approval. This is dispatch.sh's readonly
    #     posture, and dispatch.sh must DROP --sandbox to get a WRITE-capable agy
    #     (its skip-permissions write path omits --sandbox) — direct in-repo
    #     evidence that --sandbox contains terminal actions even when the
    #     permission layer approves them.
    #   --dangerously-skip-permissions  = removes the APPROVAL layer only. agy
    #     drives its review through the `command`/`read_file` tools; in headless
    #     `--print` mode agy cannot prompt for tool permission, so WITHOUT this
    #     flag every tool request auto-denies ("no output produced — a tool
    #     required the read_file/command permission that headless mode cannot
    #     prompt for") and the reviewer slot dies, silently degrading blueprint
    #     coverage below FULL (which withholds the PASS marker). agy 1.1.4 has no
    #     per-tool --allowed-tools flag and reads permission allow-rules only from
    #     the user-global ~/.pi/agent/settings.json (not a repo-local one), so a
    #     scoped allow-list is not shippable plugin config — the documented remedy
    #     is this flag.
    # WHY OPT-IN: execute_review is SHARED by every review flow (litmus commit/PR
    #   review of arbitrary, possibly-untrusted diffs also routes here when agy is
    #   the CLI). Auto-approving agy's tool requests on untrusted prompt content
    #   lets a prompt-injected diff induce reads of sensitive local files whose
    #   contents surface in the reviewer output (--sandbox blocks writes/network,
    #   not this read-then-report exfil). So the flag is gated on
    #   BUSDRIVER_AGY_REVIEW_SKIP_PERMS=1, set ONLY by callers whose trust model
    #   justifies it — blueprint-review, reviewing operator-authored design docs.
    #   Unset (the shared default), agy stays --sandbox-only and degrades to droid
    #   if it can't read headless — exactly today's behavior, no widened surface.
    # Align --print-timeout with our outer duration so agy's internal 5m default
    # doesn't abort before _portable_timeout does.
    # `--add-dir "$PWD"` (#686): the reviewer must be scoped to the CWD — the
    # tree under review — because unscoped agy resolves its own remembered
    # workspace and can cite a DIFFERENT checkout with confident file:line
    # refs and no error. Same flag dispatch.sh's agy arm passes; execute_review
    # builds its own argv, so it must pass it itself.
    agy)     local _agy_perm=()
             if [[ "${BUSDRIVER_AGY_REVIEW_SKIP_PERMS:-0}" == "1" ]]; then
               _agy_perm=(--dangerously-skip-permissions)
             fi
             if _agy_wants_argv_prompt; then
               _agy_psize=$(_agy_bytelen "$prompt")
               if _agy_prompt_oversize "$_agy_psize"; then
                 echo "agy: review prompt is ${_agy_psize}B, over the argv ceiling ($(_agy_argv_limit)B) — agy >=1.1 has no file-input flag. Split the diff or route this review to codex." >&2
                 return 1
               fi
               # argv transport: the child gets the prompt as an argument and never
               # reads fd 0, so piping it would SIGPIPE the writer under pipefail
               # (rc=141 on a >64 KB prompt despite a valid review). `none` is
               # passed as an ARGUMENT so no env can forge or clear it.
               _run_review_with_retries agy "$prompt" "$duration" none \
                 agy --sandbox --add-dir "$PWD" ${_agy_perm[@]+"${_agy_perm[@]}"} --print-timeout "${duration}s" --print "$prompt"
             else
               # agy 1.0.x resolves --print's value as a PATH, so fd 0 works and
               # the argv size ceiling and exposure do not apply on this rung.
               _run_review_with_retries agy "$prompt" "$duration" pipe \
                 agy --sandbox --add-dir "$PWD" ${_agy_perm[@]+"${_agy_perm[@]}"} --print-timeout "${duration}s" --print /dev/stdin
             fi ;;
    # Review path: bare `droid exec` (default read-only mode) is the tightest
    # posture that works for stdin-piped review. Create/Edit are blocked at this
    # tier (verified via `droid exec --list-tools` on v0.131.0+); reviews emit
    # JSON verdicts and never need to mutate the repo.
    # NOTE: PR #97 (May 2026) used `--auto low` because earlier droid versions
    # failed on first read under stdin pipe ("Exec ended early: insufficient
    # permission"). Empirically verified fixed on v0.131.0. If a future droid
    # release regresses this, restore `--auto low` (accepts file-write tier as
    # the cost of stdin-pipe working).
    droid)   printf '%s' "$prompt" | _portable_timeout "$duration" droid exec 2>&1 ;;
    # Grok (xAI Grok Build) added 2026-05-26 for blueprint-review reviewer_3.
    #
    # SAFETY MODEL (must match dispatch.sh's grok case — single source of truth
    # for the threat model lives there; this is the mirrored summary. The two
    # argv lists are pinned together by tests/test-grok-sandbox-arm.sh so they
    # cannot drift):
    #   * --sandbox strict: kernel-enforced (Seatbelt/Landlock). Reads confined
    #     to CWD + system paths. Does NOT block CWD writes — its write set is
    #     CWD + ~/.grok/ + temp dirs.
    #   * --deny 'Bash(*)': shell exec denied by policy.
    #   * --deny 'Edit': write/edit tool class denied, inside the project root
    #     and outside it. Required because strict permits CWD writes and a Bash
    #     deny alone does not gate the write tool.
    #   * --deny 'MCPTool(*)': MCP is a separate permission class the Bash and
    #     Edit denies do not reach, and a write/exec-capable MCP server would
    #     bypass both under a CWD-writable strict profile. grok's own
    #     websearch/webfetch classes are unaffected.
    #   * GROK_CLAUDE_HOOKS_ENABLED=0 / GROK_CURSOR_HOOKS_ENABLED=0: hooks run
    #     outside the permission system, so no deny rule reaches them, and
    #     under strict anything grok spawns can write the CWD. Measured
    #     2026-08-19 (GROK_HOOK_DEBUG + GROK_HOOKS_LOG), grok loads NO project
    #     hook source here (`project_sources=0`), so this is defense-in-depth
    #     against a future version that does, not a live hole being plugged —
    #     see the dispatch.sh block for the full measurement and for why a
    #     marker file is not evidence. Set via `env` so an inherited value
    #     cannot re-enable them.
    #   * The grok USER-CONFIG is not part of the boundary. The pre-2026-08-19
    #     model claimed safety required "always approve" DISABLED; re-measured,
    #     shell exec and out-of-tree writes succeeded under that setting too.
    #   * Residuals, in full in the dispatch.sh block: a kernel fail-open
    #     degrades this to policy-only containment (the denies still hold, so
    #     it lands on the old `readonly` posture, not below it); strict permits
    #     CWD writes by SPAWNED processes, which matters only for hooks, and no
    #     project hook source loads here; /tmp stays writable; network egress
    #     is not blocked on macOS.
    #   * Threat surface here: blueprint-review feeds design-document content
    #     into this path, so a prompt-injected design doc is in scope. With the
    #     flags above it can no longer obtain shell or write actions; the
    #     residual is exfiltration of CWD-readable content via grok's own web
    #     tools (network egress is not blocked on macOS).
    #
    # The stderr warning below is captured by run-design-review-loop.sh into
    # the per-reviewer raw file (e.g. grok-raw.txt). It will not surface to
    # the operator in real time the way dispatch.sh's stderr does, but it
    # remains in the audit trail.
    #
    # --max-turns 150: grok counts every internal message; review prompts
    # often consume 50-100 turns; 150 is the safety margin (max_turns_exceeded
    # is destructive — whole output discarded — so err generous, not tight).
    # --prompt-file /dev/stdin: bypasses argv length limits (mirrors agy's
    # --print pattern).
    grok)    # The explicit "" is the no-override argument. The parameter exists
             # only so tests can point the check at a fixture; passing it
             # explicitly here says so at the call site, and keeps shellcheck
             # from reading a parameter no caller ever supplies (SC2119/SC2120)
             # as a sign the argument was forgotten.
             if grok_sandbox_preflight ""; then
             echo "Note: grok blueprint-review dispatch — containment is --sandbox busdriver-review (custom kernel profile; refuses to start if unenforceable) + --deny Bash/Edit/MCPTool (dispatcher-side; the grok user-config is NOT part of the boundary). Residual: network egress is not blocked on macOS. See scripts/lib/resolve-cli.sh and skills/dispatch-cli/scripts/dispatch.sh grok-case comments for the full threat model." >&2
             # The loader blanks are an assignment PREFIX on the helper call,
             # not argv words: the helper execs "$@", where `LD_PRELOAD=` would
             # be taken as the command name. They must be in the environment
             # before /usr/bin/env is exec'd, because the dynamic loader acts on
             # them while loading env itself — too early for env's own `-i`.
             LD_PRELOAD='' LD_AUDIT='' LD_LIBRARY_PATH='' \
             DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' \
             _run_review_with_retries grok "$prompt" "$duration" pipe \
               /usr/bin/env -i PATH="$_GROK_PINNED_PATH" \
               HOME="$_GROK_TRUSTED_HOME" GROK_HOME="$_GROK_TRUSTED_HOME/.grok" \
               GROK_CLAUDE_HOOKS_ENABLED=0 GROK_CURSOR_HOOKS_ENABLED=0 \
               grok --prompt-file /dev/stdin --max-turns 150 --sandbox busdriver-review --deny 'Bash(*)' --deny 'Edit' --deny 'MCPTool(*)'
             else
               grok_preflight_hint >&2
               # `[[ -n "" ]]` and not `false` or `return 1`: a keyword cannot be
               # shadowed by an exported function, and this arm's status is what
               # the caller reads.
               [[ -n "" ]]
             fi ;;
    # opencode — added 2026-07-20 as the "Auditor" / Mechanism Witness voice. The
    # MODEL is not part of this arm's contract: it comes from `.auditor.model`
    # (resolve_auditor_model above), so provider and model can change without
    # touching the containment below. What the arm guarantees is the SANDBOX; the
    # external-transmission boundary ADR 0027 gates is the same class whichever
    # third party the model resolves to.
    # Re-enabled after 41d31ef0 removed it; that removal
    # cited "never used in this project / install-target sprawl", not safety,
    # and the operator now uses opencode daily.
    #
    # THREAT MODEL: this repo is PUBLIC and forkers open PRs, so the reviewed
    # tree is NOT operator-authored. A hostile branch may try to (a) redefine the
    # reviewer to restore write/shell tools, (b) read files outside the review,
    # or (c) reach operator-connected MCP servers. Containment is THREE isolated
    # boundaries, each verified 2026-07-20 — none is a denylist, because every
    # denylist tried leaked (see below):
    #
    #   1. TOOLS — plugin-owned config `tools:{"*":false, read/glob/grep:true}`
    #      (scripts/lib/opencode-review-config.json). Deny-all-then-allow. Four
    #      probe rounds showed every ENUMERATED denylist leaking: `permission:
    #      {edit:deny}` → model shelled out; `tools:{write,edit,bash:false}` →
    #      delegated the write to a `task` SUBAGENT; +`task,webfetch:false` →
    #      reached past built-ins to `Skill "firecrawl-scrape"` and MCP tools.
    #      Only the wildcard held.
    #   2. FILESYSTEM + PROJECT CONFIG — `--dir <empty tmpdir>`. opencode roots
    #      the project there, so the reviewed tree's files AND its config-based
    #      redefinitions (`.opencode/agent/*.md`, `opencode.json[c]`, project
    #      plugins) are simply not on the path. `env -C` does NOT do this
    #      (verified: with it, the model still read a canary in the caller's cwd).
    #      ABSOLUTE-PATH reads outside `--dir` (e.g. /etc/hosts, a /tmp canary)
    #      are DENIED in headless mode (verified): opencode requires interactive
    #      approval for out-of-workspace reads and there is no TTY to grant it —
    #      and boundary 3 removes the global config where an "always approve"
    #      could otherwise pre-grant it. So the default IS deny, and the one knob
    #      that could flip it is not loaded.
    #   3b. ENV — `env -i` with a minimal allowlist (HOME, PATH, the two vars
    #      below). opencode ALSO reads `OPENCODE_CONFIG_CONTENT` (inline JSON) and
    #      `OPENCODE_CONFIG_DIR`, which OVERRIDE `OPENCODE_CONFIG` (verified: a
    #      hostile `OPENCODE_CONFIG_CONTENT` restored bash AND read an external
    #      canary). Enumerating those to `-u` is the same losing game as the tool
    #      denylist, so instead we start from an EMPTY environment and re-add only
    #      what opencode needs — any current or future OPENCODE_* override simply
    #      is not present. Auth lives in the DATA dir under $HOME and survives.
    #   3. MCP — `XDG_CONFIG_HOME=<empty tmpdir>`. The `list_mcp_resources` /
    #      `read_mcp_resource` tools SURVIVE the wildcard (they are not in the
    #      `tools:` map) and `read_mcp_resource` genuinely reads — a confidentiality
    #      channel to the operator's own servers. Those servers are configured in
    #      the user's global opencode config; pointing XDG_CONFIG_HOME at an empty
    #      dir means opencode discovers NO servers, so the tools vanish (verified:
    #      only glob/grep/read remained). Auth lives in the DATA dir, untouched.
    #
    # TRADE-OFF (accepted, and why this arm is advisory-only): with `--dir` empty
    # the voice cannot Read repository files — its entire input is the prompt.
    # Same trade the deleted gateway arbiter documented: no free-form codebase
    # search; validation is by what it is handed.
    #
    # Re-run tests/test-opencode-review-arm.sh after any opencode upgrade — this
    # arm's safety is empirical (probed), and new tool surfaces have appeared
    # across versions without notice.
    #
    # ACCEPTED RESIDUAL (operator decision, 2026-07-20) — session-env injection.
    # A hostile repo's committed settings.json can inject EXPORTED BASH FUNCTIONS
    # (BASH_FUNC_pwd%%, BASH_FUNC_env%%, …) that override even shell builtins and
    # `command`, defeating any inline PATH/builtin hardening in this arm. This is
    # NOT specific to opencode: the same injection owns codex/agy/grok, git, jq —
    # every tool the review shells out to — so defending this one arm inline would
    # be security theater. It is the documented domain of
    # hooks/gate-scripts/lib/sanitized-gate.sh (#325 / ADR 0016), which wipes
    # BASH_FUNC_*, rebuilds PATH from an allowlist, and re-derives HOME from the
    # password DB. The review-execution path does not YET run under that wrapper
    # (a separate, cross-voice change); until it does, this exposure is shared by
    # ALL voices and accepted as a documented residual, exactly like grok's
    # "not enforceable from code" note above. This arm is nonetheless the most
    # hardened of the voices against the in-scope (data-plane) threats.
    opencode)
             # HARDEN THE ARM'S OWN UTILITY PATH first. Everything below runs
             # mktemp/dirname/basename/command/env; a repo-injected PATH (a fork's
             # settings.json, #325 class) could otherwise trojan those. Pin a
             # system-only PATH for the duration of this arm — the operator's real
             # opencode install dir is added explicitly via _oc_trust (HOME-based)
             # at resolution, so a clean utility PATH costs nothing here.
             # (HOME itself: if a fork could rewrite HOME the whole session is
             # compromised — every tool trusts it — so that is the gate's env
             # sanitization boundary, #325/ADR 0016, not this arm's to re-solve.)
             local PATH="/usr/bin:/bin:/usr/sbin:/sbin"
             # NO env override for the config path. `BUSDRIVER_OPENCODE_CONFIG`
             # would be repo-INJECTABLE: a reviewed fork's `.claude/settings.json`
             # `env` block enters the operator's session (the #325 / ADR 0016
             # class), so a hostile branch could point it at a tracked JSON that
             # re-enables tools. The config is therefore ALWAYS the plugin-owned
             # file, resolved from _bd_lib_dir (fail closed if that is empty).
             if [[ -z "$_bd_lib_dir" ]]; then
               echo "busdriver: cannot resolve the plugin lib dir — refusing to dispatch the opencode Auditor (cannot locate its read-only config)." >&2
               return 1
             fi
             local _oc_cfg="${_bd_lib_dir}/opencode-review-config.json"
             # FAIL CLOSED. opencode does NOT error on a missing OPENCODE_CONFIG —
             # it silently loads the user's default config, restoring write/bash.
             # `-f "$_oc_cfg"` alone is the correct guard: an empty _bd_lib_dir
             # yields a non-existent path (`/opencode-review-config.json`) → not
             # a file → blocked. There is NO env override for this path (see the
             # "NO env override" comment above) — the only recovery is repairing
             # or reinstalling the plugin asset, NOT setting an env var.
             if [[ ! -f "$_oc_cfg" ]]; then
               echo "busdriver: opencode review config not found at '${_oc_cfg}' — refusing to dispatch unconfined (a missing config silently restores write/bash). Repair or reinstall the busdriver plugin so ${_oc_cfg} exists." >&2
               return 1
             fi
             # CANONICALIZE to absolute. We dispatch with the child CWD set to the
             # neutral dir, so a relative path would resolve against THAT dir,
             # not here — the file would be missing and opencode would fail OPEN to
             # the user default. Resolve it absolute now, while CWD is still here.
             _oc_cfg="$(cd "$(dirname "$_oc_cfg")" 2>/dev/null && pwd -P)/$(basename "$_oc_cfg")"
             if [[ ! -f "$_oc_cfg" ]]; then
               echo "busdriver: could not resolve the opencode review config to an absolute path — refusing to dispatch." >&2
               return 1
             fi
             # Derive the trusted home from the PASSWORD DATABASE FIRST (not
             # $HOME: repo-injectable) — used for the auth/cache env paths.
             # `~user` tilde expansion reads getpwnam; `id` runs absolute.
             local _oc_home _oc_user
             _oc_user="$(/usr/bin/id -un 2>/dev/null)"
             if ! _bd_valid_username "$_oc_user"; then
               # Fail CLOSED on an empty or non-plain username: the following
               # `~` expansion would fall back to the repo-injectable $HOME
               # (or a hostile name could execute as shell text).
               echo "busdriver: could not derive a valid operator user from the password database — refusing to resolve opencode from a possibly-injected \$HOME." >&2
               return 1
             fi
             _oc_home="$(eval echo "~${_oc_user}" 2>/dev/null)"
             # NO $HOME fallback — $HOME is the repo-injectable value this whole
             # block exists to distrust. If the password-DB lookup fails (a broken
             # system, not a normal state), fail CLOSED rather than trust $HOME.
             if [[ -z "$_oc_home" || ! -d "$_oc_home" ]]; then
               echo "busdriver: could not derive a trusted home from the password database — refusing to resolve opencode from a possibly-injected \$HOME." >&2
               return 1
             fi
             # Neutral cwd is created INSIDE the validated sandbox (post-
             # validation, in the run subshell): opencode's project discovery
             # walks UP and stops at the sandbox's own validated copy. Never
             # ${TMPDIR} (repo-injectable) and never a bare /tmp child
             # (world-writable — other users could plant config for the walk).
             # Binary selection and process CWD are pinned to trusted values so
             # NOTHING the reviewed repo controls can supply the executable:
             #   (a) resolve ONLY against a FIXED trusted lookup path (operator
             #       install dirs + system dirs) — NOT the caller's PATH. Filtering
             #       the caller PATH to absolute entries is not enough: an absolute
             #       entry can still point INTO the reviewed checkout (e.g. an abs
             #       node_modules/.bin), which would then supply a planted binary.
             #       There is deliberately NO env override for the binary path:
             #       BUSDRIVER_OPENCODE_BIN would be repo-injectable via a fork's
             #       settings.json (#325 class) and could point at a planted
             #       executable — the very thing this pin exists to prevent.
             #   (b) the child receives the binary ABSOLUTE + a PATH of only the
             #       binary's own dir + system dirs.
             #   (c) a subshell `cd` pins the child's PROCESS CWD to the neutral
             #       empty dir (see the dispatch below), before --dir applies.
             local _oc_bin _oc_path _oc_trust _oc_cwd=""
             _oc_trust="${_oc_home}/.opencode/bin:${_oc_home}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
             _oc_bin="$(PATH="$_oc_trust" command -v opencode 2>/dev/null)"
             if [[ -z "$_oc_bin" || "$_oc_bin" != /* || ! -x "$_oc_bin" ]]; then
               echo "busdriver: opencode binary not found on the trusted install path — cannot dispatch the Auditor voice." >&2
               /bin/rmdir "${_oc_cwd:-}" 2>/dev/null || true
               return 1
             fi
             _oc_path="$(CDPATH='' cd -- "$(dirname -- "$_oc_bin")" && pwd -P)"
             _oc_path="${_oc_path}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
             # PROMPT VIA STDIN (pipe mode), not argv. opencode reads its message
             # from fd 0 when no positional message is given (verified). A full
             # base...HEAD blueprint diff as one argv word can exceed ARG_MAX
             # (1 MB) → E2BIG before opencode starts; stdin has no such ceiling.
             # `env -i` (empty env + minimal allowlist) neutralizes the
             # OPENCODE_CONFIG_CONTENT / OPENCODE_CONFIG_DIR overrides — see
             # boundary 3b above. opencode is resolved via the re-added PATH.
             # SUBSHELL `cd` sets the child's process CWD to the neutral dir. We do
             # NOT use `env -C` — it is a GNU extension not guaranteed on every
             # BSD/macOS `env`; a subshell cd is portable. Without a neutral CWD
             # the process starts in the reviewed repo (--dir re-roots opencode's
             # PROJECT, not the OS cwd), so node/opencode startup could read
             # cwd-relative files (node_modules, local config) before --dir
             # applies. Prompt is piped on stdin (pipe mode), inherited into the
             # subshell; review output on stdout is captured by the caller.
             # Model resolved AFTER the PATH pin above, so the jq/python3 the
             # config reader shells out to comes from system dirs only, and with
             # the PASSWORD-DB home — never the repo-injectable $HOME, which would
             # let the reviewed repo choose where its own review is transmitted.
             # PATH is restated rather than inherited from the arm's pin above:
             # the config reader shells out to jq/python3, and leaving that on
             # line ORDER inside a long case arm is a reordering away from being
             # wrong. Stated here, the invariant is local and greppable.
             # It is the TOOL path (_oc_trust's system half), not the arm's
             # narrower utility pin: on a Mac whose jq/python3 come only from
             # Homebrew, a /usr/bin-only PATH finds NO parser, and the operator's
             # configured model reads as empty — which now skips the voice via the
             # guard below instead of dispatching somewhere they configured away
             # from. These dirs are root-owned system install paths, not
             # repo-writable.
             PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$_oc_home" resolve_auditor_model
             # No model → no auditor. There is no shipped default (see
             # resolve_auditor_model), so an unconfigured or unparseable
             # `.auditor.model` lands here. Skipping is correct for an ADVISORY
             # voice and is the same shape as the `missing:*` / `unsupported:*`
             # arms below: warn on stderr, return non-zero, never dispatch. An
             # empty `-m` must never reach opencode — it would silently fall back
             # to whatever model that CLI defaults to, which is precisely the
             # unasked-for provider choice this deletion exists to prevent.
             # rc 4 = SKIPPED, distinct from 1 (failed) and 3 (BUILTIN_FALLBACK).
             # Callers must be able to tell "never ran, nothing was configured"
             # from "ran and failed" — ADR 0027's ABSENT-vs-FAILED distinction for
             # this witness. Collapsing it into 1 makes blueprint-review report the
             # Mechanism Witness as FAILED for a config key the operator simply
             # never set. Reported by Codex on this change.
             # No cleanup needed on this path: $_oc_cwd is still the empty `local`
             # init here — the sandbox is not staged until inside the subshell
             # further down — so there is no temp dir to reclaim. Bailing before
             # any allocation is the whole point of guarding this early.
             if [[ -z "$_BD_AUDITOR_MODEL" ]]; then
               echo "busdriver: no usable .auditor.model in ~/.claude/busdriver.json — skipping the Mechanism Witness (advisory voice)." >&2
               return 4
             fi
             # FAIL CLOSED on the operator-owned ~/.opencode/opencode.json[c].
             # opencode loads these in EVERY environment — including this
             # sandbox — so they are a fourth config surface the three isolation
             # boundaries do not cover. An `mcp` entry there would load inside
             # the sandbox and read_mcp_resource survives the tool denylist
             # (exactly why XDG_CONFIG_HOME is redirected). Shared guard:
             # validate_opencode_home_config (single source of truth, also
             # called by dispatch.sh's opencode arm). On success it also
             # stages a validated copy at $_BD_OC_SANDBOX_HOME; the run below
             # uses THAT as HOME so opencode reads exactly the validated bytes
             # (the real ~/.opencode is never reopened — no validate-then-open
             # race on a swapped-in mcp/npm payload). Validation runs INSIDE
             # the trap-owned subshell so the staged sandbox is owned from
             # creation (an early TERM cannot orphan credential-bearing dirs).
             # shellcheck disable=SC2030,SC2031  # _oc_cwd is set inside the subshell; the post-subshell rm sees the empty local init (never an ambient value)
             ( _BD_OC_SANDBOX_HOME=""   # owned by this lane from the first statement — a trap fired between fork and here sees nothing to touch
               trap '_bd_oc_lane_cleanup "$_oc_home" "${_oc_cwd:-}"' EXIT   # best-effort cleanup even on grace-kill
               trap '_bd_oc_lane_cleanup "$_oc_home" "${_oc_cwd:-}"; exit 143' TERM
               trap '_bd_oc_lane_cleanup "$_oc_home" "${_oc_cwd:-}"; exit 130' INT
               # Pinned SYSTEM-ONLY PATH: the validator stages credentials
               # with bare mktemp/mkdir/ln/rm — _oc_path's first entry is the
               # operator-WRITABLE opencode dir, which must not shadow those
               # utilities; the system dirs carry them all.
               if ! PATH="/usr/bin:/bin:/usr/sbin:/sbin" validate_opencode_home_config "$_oc_home"; then
                 exit 1
               fi
               # Neutral cwd INSIDE the validated sandbox (post-validation):
               # opencode's project discovery walks UP from the cwd and stops
               # at the sandbox's OWN validated copy — the real home's config
               # surfaces are never reopened; the 0700 sandbox is private to
               # the operator (no other-user planting; never ${TMPDIR} — repo-
               # injectable).
               _oc_cwd="${_BD_OC_SANDBOX_HOME}/.cwd"
               /bin/mkdir -p "$_oc_cwd" 2>/dev/null || exit 1
               # Git-init the EMPTY cwd: opencode's project-config discovery
               # scans every ancestor through the worktree root (non-Git = /,
               # reaching the real home); a git repo bounds the worktree AT
               # the empty cwd. The workspace stays EMPTY — auth.json / SDK
               # symlinks are OUTSIDE the worktree and external_directory is
               # denied, so the read-enabled reviewer cannot reach them.
               # Sterile init (GIT_DIR/GIT_WORK_TREE are repo-injectable) with
               # the EXECUTION-PROBED git (the CLT shim at /usr/bin/git exists
               # but fails without CLT).
               _bd_resolve_git || { echo "busdriver: no working git found to bound the neutral cwd — refusing to dispatch." >&2; exit 1; }
               /usr/bin/env -i PATH="/usr/bin:/bin" "$_bd_git" -C "$_oc_cwd" init -q 2>/dev/null || { echo "busdriver: cannot git-init the neutral cwd — refusing to dispatch." >&2; exit 1; }
               [[ -d "$_oc_cwd/.git" ]] || { echo "busdriver: git-init did not create .git in the neutral cwd — refusing to dispatch." >&2; exit 1; }
               cd "$_oc_cwd" 2>/dev/null || exit 1
               # XDG_DATA_HOME points at the SANDBOX data dir — populated
               # with a validated auth.json copy ONLY (auth works, account
               # state absent — nothing merges config after OPENCODE_CONFIG).
               # XDG_CACHE_HOME shares the inert model/package cache.
               # (Comments BEFORE the command — after a backslash
               # continuation they would terminate the chain.)
               _run_review_with_retries opencode "$prompt" "$duration" pipe \
                 /usr/bin/env -i HOME="$_BD_OC_SANDBOX_HOME" PATH="$_oc_path" \
                   OPENCODE_CONFIG="$_oc_cfg" XDG_CONFIG_HOME="$_oc_cwd" \
                   XDG_DATA_HOME="$_BD_OC_SANDBOX_HOME/.local/share" \
                   XDG_CACHE_HOME="$_oc_home/.cache" \
                 "$_oc_bin" run --dir "$_oc_cwd" --agent busdriver-review \
                   -m "$_BD_AUDITOR_MODEL" )
             local _oc_rc=$?
              # shellcheck disable=SC2031  # post-subshell rm sees the empty local init, never the subshell's value
            /bin/rm -rf "$_oc_cwd" 2>/dev/null || true
             return "$_oc_rc" ;;
    builtin) echo "BUILTIN_FALLBACK"; return 3 ;;
    unsupported:*)
             # CLI was rejected upstream (deprecated/removed). Migration warning
             # was already emitted to stderr by resolve_role_cli; surface the
             # cause cleanly here instead of falling through to the wildcard
             # "Unsupported CLI: unsupported:amp" garbage.
             local _removed="${cli#unsupported:}"
             echo "busdriver: review CLI '$_removed' is no longer supported; use codex, agy, droid, grok, or opencode" >&2
             return 1 ;;
    missing:*)
             # CLI is configured but not installed. Same surface-clean intent as
             # unsupported:* above — let the caller see a recognizable failure
             # mode rather than a garbled wildcard match.
             local _absent="${cli#missing:}"
             echo "busdriver: review CLI '$_absent' is configured but not installed" >&2
             return 1 ;;
    *)       echo "Unsupported CLI: $cli" >&2; return 1 ;;
  esac
}

# ── Machine-readable interface (--json) ─────────────────────────
# Guard: only runs when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" = "$0" ]] && [[ "${1:-}" = "--json" ]]; then
  configured="${BUSDRIVER_REVIEW_CLI:-auto}"
  resolved=$(resolve_review_cli)
  version=""
  case "$resolved" in
    codex|agy|droid|grok|opencode) version=$(get_cli_version "$resolved") ;;
    builtin|none|missing:*|unsupported:*) version="n/a" ;;
  esac

  # Sanitize strings for JSON (strip quotes, backslashes, newlines)
  _json_safe() { tr -d '"\\\n' | head -1; }

  configured=$(echo "$configured" | _json_safe)
  resolved=$(echo "$resolved" | _json_safe)
  version=$(echo "$version" | _json_safe)

  # Report availability for all supported CLIs
  clis_json=""
  # grok and opencode included here for accurate availability metadata (not
  # auto-detect); downstream consumers inspecting `clis[resolved]` get an
  # entry when the resolved CLI is grok (e.g., via explicit
  # BUSDRIVER_REVIEW_CLI=grok or blueprint-review.reviewer_3 route) or
  # opencode (e.g., via the council.auditor / blueprint-review.auditor
  # routes). Neither is auto-detected — see Step 5's exclusion comment.
  for cli in codex agy droid grok opencode; do
    avail=$(is_cli_available "$cli" && echo true || echo false)
    ver=$(get_cli_version "$cli" | _json_safe)
    clis_json="${clis_json}\"${cli}\":{\"available\":${avail},\"version\":\"${ver}\"},"
  done
  clis_json="{${clis_json%,}}"

  printf '{"configured":"%s","resolved":"%s","version":"%s","clis":%s}\n' \
    "$configured" "$resolved" "$version" "$clis_json"
  exit 0
fi
