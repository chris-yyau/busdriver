#!/usr/bin/env bash
# #685 — Gate 1 (design review) docs-only carve-out in pre-commit-gate.sh.
#
# The defect: on a documentation PR, every remediation a reviewer asks for is an
# edit to the design doc, that edit re-arms a review token, and the token then
# blocked the `git commit` that would land the fix. The loop had no exit that did
# not route through an operator `touch`.
#
# The carve-out lets a commit whose STAGED SET is entirely design documents past
# Gate 1 (and on to litmus). It reads the set from git, never from the command,
# and the command itself must be a bare single-segment `git commit -m …` —
# staging happens in its own call.
#
# Both branches of every guard are exercised. A carve-out whose refusal path
# never fires is a carve-out that refuses nothing.
#   Step 1  — commit_scope.py: which command shapes yield a knowable set.
#   Step 1b — differential: what it claims IS what git would commit, over a
#             generated command grammar as well as hand-picked cases.
#   Step 2  — the gate end-to-end: docs-only allowed, anything else still blocked.
#
# Every token is armed inside a SCRATCH repo, never this one.
#
# SC2016: several fixtures pass a LITERAL $(…) / ${…} to the parser on purpose —
# the whole point is that shell-active text must be refused, so it must not
# expand here.
# shellcheck disable=SC2312,SC2015,SC2016
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
R="$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
SCOPE="$ROOT/hooks/gate-scripts/lib/commit_scope.py"
GATE="$ROOT/hooks/gate-scripts/pre-commit-gate.sh"

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
eq(){ [[ "$2" = "$3" ]] && ok "$1" || no "$1" "want=$3 got=$2"; }

TMPS=()
cleanup(){ local d; for d in "${TMPS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done; }
trap cleanup EXIT

# Sets $NEWREPO. Deliberately NOT `d="$(mkrepo)"`: command substitution runs the
# function in a SUBSHELL, where the `exit 1` below would kill only that subshell,
# `TMPS+=` would be discarded (nothing ever cleaned up), and an empty result would
# leave every `git -C "$d"` here pointing at the REAL repository — where this
# script's `reset` and `add` would hit the operator's own index.
NEWREPO=""
mkrepo(){
    local d
    d="$(mktemp -d)" || { printf 'FATAL: mktemp -d failed\n' >&2; exit 1; }
    [[ -n "$d" && -d "$d" ]] || { printf 'FATAL: mktemp -d gave no directory\n' >&2; exit 1; }
    TMPS+=("$d")
    git -C "$d" init -q || { printf 'FATAL: git init failed in %s\n' "$d" >&2; exit 1; }
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    # Pin BOTH program-running settings locally, BEFORE the first commit. Without
    # this, a scratch repo inherits the operator's GLOBAL core.hooksPath and
    # core.fsmonitor — commit_scope.py would then correctly refuse every
    # acceptance fixture on a machine that has either, and the initial commit
    # would run a global hook. Individual cases override these deliberately.
    git -C "$d" config core.hooksPath "$d/.git/hooks"
    git -C "$d" config core.fsmonitor false
    # Local config cannot UNSET a global key, so the fixture also gets its own
    # HOME (see scope()); these two only cover the fixture's OWN git calls.
    git -C "$d" config commit.gpgSign false
    git -C "$d" config core.pager false
    mkdir -p "$d/fakehome"
    git -C "$d" commit -q --allow-empty -m init
    NEWREPO="$d"
}
# Scratch repo with the standard fixture tree; sets $NEWREPO.
fresh(){
    mkrepo
    local r="$NEWREPO"
    mkdir -p "$r/docs/plans" "$r/src"
    printf '# plan\n'  >"$r/docs/plans/p.md"
    printf '# plan2\n' >"$r/docs/plans/q.md"
    printf 'x\n'       >"$r/src/impl.py"
}

payload(){ jq -cn --arg c "$1" --arg cwd "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }
# commit_scope.py verdict: "REFUSE", or the newline-joined path set.
# The helper resolves git config TWICE — once sanitized, once with
# GIT_CONFIG_GLOBAL/SYSTEM dropped, which reads the OPERATOR's real global file.
# Point HOME at the fixture's own empty home so both passes see fixture-controlled
# config: otherwise a machine with a global core.pager, gpg.<fmt>.program or
# core.hooksPath makes every acceptance case refuse, and the suite reports the
# operator's setup rather than the code.
scope(){
    payload "$1" "$2" \
      | env HOME="$2/fakehome" XDG_CONFIG_HOME="$2/fakehome/.config" \
            GIT_CONFIG_SYSTEM=/dev/null \
            python3 -I "$SCOPE" "$2" "$2" .claude 2>/dev/null || printf 'REFUSE'
}

# Gate verdict on a git-commit command.
verdict(){
    local out
    out="$(payload "$1" "$2" | bash "$GATE" 2>/dev/null)"
    case "$out" in
        *"Design review required before committing"*) printf 'design-block' ;;
        *'"decision"'*) printf 'past-gate1' ;;
        *) printf 'no-decision: %s' "$out" ;;
    esac
}

echo "── (Step 1) commit_scope.py — which shapes yield a knowable set ───"

fresh; t="$NEWREPO"
git -C "$t" add docs/plans/p.md

eq "bare commit over a staged doc → that doc" \
   "$(scope "git commit -m 'docs: fix'" "$t")" "docs/plans/p.md"
eq "message with spaces survives (shlex, not split)" \
   "$(scope "git commit -m 'docs: fix the review finding'" "$t")" "docs/plans/p.md"
eq "attached -m form"    "$(scope "git commit -mfix" "$t")"          "docs/plans/p.md"
eq "--message= form"     "$(scope "git commit --message=fix" "$t")"  "docs/plans/p.md"
eq "-q is allowed"       "$(scope "git commit -q -m fix" "$t")"      "docs/plans/p.md"
# Conventional commits are the counterweight: a parser that refused every
# parenthesis or `#` would refuse nearly every commit this repo makes.
eq "conventional-commit scope in the message → accepted" \
   "$(scope "git commit -m 'fix(design-gate): drop the drain'" "$t")" "docs/plans/p.md"
eq "issue reference in the message → accepted" \
   "$(scope "git commit -m 'docs: close #685'" "$t")" "docs/plans/p.md"
eq "quoted && in the message → accepted, not a separator" \
   "$(scope "git commit -m 'docs: add && commit'" "$t")" "docs/plans/p.md"
eq "QUOTED bracket in the message → accepted (literal)" \
   "$(scope "git commit -m 'fix [gate]: x'" "$t")" "docs/plans/p.md"

# ── The refusals. Each is a shape whose real file set this helper cannot see. ──
eq "chained git add → refuse (stage in its own call)" \
   "$(scope "git add docs/plans/q.md && git commit -m x" "$t")" "REFUSE"
eq "anything chained at all → refuse" \
   "$(scope "true && git commit -m x" "$t")" "REFUSE"
eq "trailing chained command → refuse" \
   "$(scope "git commit -m x && echo done" "$t")" "REFUSE"
eq "-a commits files never staged → refuse" "$(scope "git commit -am fix" "$t")" "REFUSE"
eq "--all → refuse"        "$(scope "git commit --all -m fix" "$t")"   "REFUSE"
eq "--amend → refuse"      "$(scope "git commit --amend -m fix" "$t")" "REFUSE"
eq "--only → refuse"       "$(scope "git commit --only -m fix" "$t")"  "REFUSE"
eq "--no-verify → refuse"  "$(scope "git commit --no-verify -m fix" "$t")" "REFUSE"
eq "pathspec operand → refuse" \
   "$(scope "git commit -m fix -- docs/plans/p.md" "$t")" "REFUSE"
eq "bare commit opens core.editor → refuse" "$(scope "git commit" "$t")" "REFUSE"
eq "-q alone, still no message → refuse"    "$(scope "git commit -q" "$t")" "REFUSE"
eq "git -C elsewhere → refuse"   "$(scope "git -C /other commit -m fix" "$t")" "REFUSE"
eq "absolute git path → refuse"  "$(scope "/usr/bin/git commit -m fix" "$t")" "REFUSE"
# `\b` in a regex matches before a hyphen, so `commit-x` — which a repo-local
# alias (`commit-x = !git commit -a`) can define to do anything — read as a commit.
eq "aliasable subcommand git commit-x → refuse" \
   "$(scope "git commit-x -m fix" "$t")" "REFUSE"
eq "unquoted brace expansion smuggles a flag → refuse" \
   "$(scope "git commit -m {msg,-a}" "$t")" "REFUSE"
eq "unquoted glob in the message → refuse" "$(scope "git commit -m fix*" "$t")" "REFUSE"
eq "command substitution in the MESSAGE → refuse" \
   "$(scope 'git commit -m "$(git add src/impl.py)"' "$t")" "REFUSE"
eq "backtick substitution in the message → refuse" \
   "$(scope 'git commit -m "`git add src/impl.py`"' "$t")" "REFUSE"
eq "parameter expansion in the message → refuse" \
   "$(scope 'git commit -m "$MSG"' "$t")" "REFUSE"
# A QUOTED separator is a git OPERAND (a pathspec), not a separator — the shape
# that defeated a shlex(punctuation_chars=True) tokenizer.
eq "quoted separator is an operand → refuse" \
   "$(scope "git commit -m x ';' more" "$t")" "REFUSE"
eq "escaped separator is data too → refuse" \
   "$(scope "git commit -m x \; more" "$t")" "REFUSE"
eq "pipe operator → refuse"      "$(scope "git commit -m x | tee /dev/null" "$t")" "REFUSE"
eq "backgrounding & → refuse"    "$(scope "git commit -m x & true" "$t")" "REFUSE"
eq "subshell → refuse"           "$(scope "(git commit -m x)" "$t")" "REFUSE"
eq "redirection → refuse"        "$(scope "git commit -m x > /dev/null" "$t")" "REFUSE"
eq "unbalanced quote → refuse"   "$(scope "git commit -m 'the operator" "$t")" "REFUSE"
eq "newline in the command → refuse" \
   "$(scope "$(printf 'git commit -m x\ntrue')" "$t")" "REFUSE"
eq "not a commit at all → refuse" "$(scope "git status" "$t")" "REFUSE"

# Nothing staged: there is no set to judge, so no carve-out.
fresh; e="$NEWREPO"
eq "empty index → refuse" "$(scope "git commit -m x" "$e")" "REFUSE"

# Operands are not read from the command, so a subdirectory cwd is not
# load-bearing — but the anchor is kept and must fire.
fresh; sd="$NEWREPO"; mkdir -p "$sd/sub"; git -C "$sd" add docs/plans/p.md
eq "hook cwd is a subdirectory → refuse" \
   "$(payload "git commit -m x" "$sd/sub" | python3 -I "$SCOPE" "$sd" "$sd/sub" .claude 2>/dev/null || printf 'REFUSE')" \
   "REFUSE"

# A git hook can stage files between this decision and the commit.
fresh; h="$NEWREPO"; git -C "$h" add docs/plans/p.md
# Pin core.hooksPath: this machine may carry a GLOBAL one, in which case a file
# dropped into .git/hooks is ignored by git AND (correctly) by the helper — the
# fixture has to write where git would actually look.
eq "no hooks → accepted" "$(scope "git commit -m x" "$h")" "docs/plans/p.md"
for hook in pre-commit commit-msg post-index-change prepare-commit-msg; do
    printf '#!/bin/sh\nexit 0\n' >"$h/.git/hooks/$hook"; chmod +x "$h/.git/hooks/$hook"
    eq "ANY hook refuses, not a name denylist ($hook)" "$(scope "git commit -m x" "$h")" "REFUSE"
    rm -f "$h/.git/hooks/$hook"
done
eq "hooks removed → accepted again" "$(scope "git commit -m x" "$h")" "docs/plans/p.md"

# The gate runs with GIT_CONFIG_GLOBAL/SYSTEM neutralized (ADR 0016) while the
# commit it authorizes runs with the operator's real config, so a GLOBAL
# core.hooksPath is invisible to the sanitized resolution and live at commit time.
# Both resolutions must be consulted.
fresh; hg="$NEWREPO"; git -C "$hg" add docs/plans/p.md
# Drop mkrepo's LOCAL pin: a local core.hooksPath overrides the global one, which
# would make this fixture prove nothing.
git -C "$hg" config --unset core.hooksPath
mkdir -p "$hg/globalhooks"
printf '[core]\n\thooksPath = %s/globalhooks\n' "$hg" >"$hg/fakehome/.gitconfig"
printf '#!/bin/sh\nexit 0\n' >"$hg/globalhooks/pre-commit"; chmod +x "$hg/globalhooks/pre-commit"
# HOME points at a config carrying the hooksPath; GIT_CONFIG_GLOBAL=/dev/null is
# exactly what sanitized-gate.sh exports, so pass 1 is BLIND to it. Only the
# second, unsanitized pass can see the hook — which is the whole point.
sanitized_scope(){
    payload "git commit -m x" "$1" \
      | env HOME="$1/fakehome" XDG_CONFIG_HOME="$1/fakehome/.config" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
            python3 -I "$SCOPE" "$1" "$1" .claude 2>/dev/null || printf 'REFUSE'
}
eq "hook reachable ONLY via a global core.hooksPath the gate cannot see → refuse" \
   "$(sanitized_scope "$hg")" "REFUSE"
rm -f "$hg/globalhooks/pre-commit"
eq "same config, no hook in it → accepted" \
   "$(sanitized_scope "$hg")" "docs/plans/p.md"

# Git's default global file is $XDG_CONFIG_HOME/git/config (falling back to
# $HOME/.config/git/config), read ALONGSIDE ~/.gitconfig above. hooks.json now
# re-imports XDG_CONFIG_HOME for this gate specifically so an operator whose
# XDG_CONFIG_HOME diverges from $HOME/.config still has that file seen by the
# second (unsanitized) pass — point it somewhere OTHER than "$HOME/.config" so
# this fixture cannot pass by accident via the ~/.gitconfig case above.
fresh; hx="$NEWREPO"; git -C "$hx" add docs/plans/p.md
git -C "$hx" config --unset core.hooksPath
mkdir -p "$hx/xdghome/git" "$hx/xdghooks"
printf '[core]\n\thooksPath = %s/xdghooks\n' "$hx" >"$hx/xdghome/git/config"
printf '#!/bin/sh\nexit 0\n' >"$hx/xdghooks/pre-commit"; chmod +x "$hx/xdghooks/pre-commit"
xdg_sanitized_scope(){
    payload "git commit -m x" "$1" \
      | env HOME="$1/fakehome" XDG_CONFIG_HOME="$1/xdghome" \
            GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
            python3 -I "$SCOPE" "$1" "$1" .claude 2>/dev/null || printf 'REFUSE'
}
eq "hook reachable ONLY via XDG_CONFIG_HOME/git/config → refuse" \
   "$(xdg_sanitized_scope "$hx")" "REFUSE"
rm -f "$hx/xdghooks/pre-commit"
eq "same XDG config, no hook in it → accepted" \
   "$(xdg_sanitized_scope "$hx")" "docs/plans/p.md"

# core.fsmonitor names a program git runs during diff/ls-files and again at commit.
fresh; fm="$NEWREPO"; git -C "$fm" add docs/plans/p.md
eq "no fsmonitor → accepted" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"
git -C "$fm" config core.fsmonitor "$fm/watchman-hook.sh"
eq "core.fsmonitor names a program → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config core.fsmonitor false
eq "core.fsmonitor false → accepted" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"
# `true` selects git's BUILT-IN daemon, not a program. This repository sets it, so
# refusing it disabled the carve-out in the repository it was written for.
git -C "$fm" config core.fsmonitor true
eq "core.fsmonitor true (built-in daemon) → accepted" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"

git -C "$fm" config core.fsmonitor " true "
eq "core.fsmonitor with quoted whitespace is a PATHNAME → refuse" \
   "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config --unset core.fsmonitor
# Other programs git may run during the commit.
eq "no pager configured → accepted" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"
git -C "$fm" config core.pager "sh -c 'git add src/impl.py'"
eq "core.pager names a program → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config core.pager false
eq "core.pager false (the off switch) → accepted" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"
git -C "$fm" config pager.commit "less"
eq "pager.commit names a program → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config --unset pager.commit
git -C "$fm" config gpg.program "/tmp/evil"
eq "gpg.program names a program → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config --unset gpg.program
# The whole gpg.* and hook.* namespaces refuse: a signer is reachable from
# commit.gpgSign without gpg.program, and a config-based hook runs with an EMPTY
# hooks directory, so the filesystem check cannot see it.
git -C "$fm" config gpg.ssh.defaultKeyCommand "/tmp/evil"
eq "gpg.ssh.defaultKeyCommand → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config --unset gpg.ssh.defaultKeyCommand
# Negative control, and it is the important one: this machine signs commits
# (gpg.format=ssh, commit.gpgSign=true). An earlier revision refused the whole
# gpg.* namespace and would have disabled the carve-out for every signing
# operator while closing nothing — signing runs gpg/ssh-keygen from PATH, the
# accepted ambient residual, not a repo-configurable program.
git -C "$fm" config commit.gpgSign true
git -C "$fm" config gpg.format ssh
git -C "$fm" config gpg.ssh.allowedSignersFile "$fm/allowed_signers"
eq "a signing operator's config → accepted" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"
git -C "$fm" config gpg.ssh.program "/tmp/evil"
eq "gpg.<format>.program names a program → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config --unset gpg.ssh.program
git -C "$fm" config --unset commit.gpgSign
git -C "$fm" config --remove-section gpg.ssh
git -C "$fm" config --remove-section gpg
git -C "$fm" config hook.pre-commit.command "git add src/impl.py"
eq "config-based hook.<name>.command → refuse" "$(scope "git commit -m x" "$fm")" "REFUSE"
git -C "$fm" config --remove-section hook.pre-commit
eq "programs cleared → accepted again" "$(scope "git commit -m x" "$fm")" "docs/plans/p.md"

# A committed settings.json `env` block is the ADR 0016 injection channel into the
# session the real `git commit` runs in — and it is live from CHECKOUT, not from
# being committed, so the carve-out must stand down when one is present.
fresh; se="$NEWREPO"; git -C "$se" add docs/plans/p.md
mkdir -p "$se/.claude"
eq "no settings.json → accepted" "$(scope "git commit -m x" "$se")" "docs/plans/p.md"
printf '{"permissions":{}}\n' >"$se/.claude/settings.json"
eq "settings.json without env → accepted" "$(scope "git commit -m x" "$se")" "docs/plans/p.md"
printf '{"env":{"GIT_INDEX_FILE":"/tmp/other"}}\n' >"$se/.claude/settings.json"
eq "settings.json with an env block → refuse" "$(scope "git commit -m x" "$se")" "REFUSE"
printf 'not json\n' >"$se/.claude/settings.json"
eq "unparseable settings.json → refuse" "$(scope "git commit -m x" "$se")" "REFUSE"
rm -f "$se/.claude/settings.json"
printf '{"env":{"FOO":"1"}}\n' >"$se/.claude/settings.local.json"
eq "settings.local.json with an env block → refuse" "$(scope "git commit -m x" "$se")" "REFUSE"
rm -f "$se/.claude/settings.local.json"
# A project-registered PreToolUse hook runs alongside this gate and can rewrite
# the approved command via updatedInput, or stage files after the index sample.
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x"}]}]}}\n' >"$se/.claude/settings.json"
eq "settings.json registering hooks → refuse" "$(scope "git commit -m x" "$se")" "REFUSE"
printf '{"enabledPlugins":{"x":true}}\n' >"$se/.claude/settings.json"
eq "settings.json enabling plugins (which may register hooks) → refuse" \
   "$(scope "git commit -m x" "$se")" "REFUSE"
printf '{"extraKnownMarketplaces":{"x":{}}}\n' >"$se/.claude/settings.json"
eq "settings.json adding a marketplace → refuse" "$(scope "git commit -m x" "$se")" "REFUSE"
rm -f "$se/.claude/settings.json"
eq "settings files removed → accepted again" "$(scope "git commit -m x" "$se")" "docs/plans/p.md"

# A FIFO at settings.json passes os.path.exists() and, opened blocking, hangs
# the gate until a writer connects — under this gate's 10s PreToolUse timeout
# that hang reads as ALLOW (see commit_scope.py's _MAX_PATHS comment), so a
# planted FIFO would be a bypass, not just a stall. `timeout` here distinguishes
# a genuine hang (would print TIMEOUT, exit 124) from prompt refusal, so the
# O_NONBLOCK + fstat guard firing before any read is actually proven rather
# than a masked-by-`|| REFUSE` timeout looking identical to a real refusal.
# `timeout` is GNU-only and absent from stock macOS/BSD, so requiring it outright
# made this suite unrunnable there. The repo already solves this: source
# _portable_timeout (timeout → gtimeout → a perl alarm fallback, which exists
# everywhere) rather than hard-requiring one binary.
#
# Exit-code classification is exhaustive on purpose. An earlier `else → REFUSE`
# catch-all called every non-{0,124} code a successful refusal — including 125/126
# (timeout itself failed, or could not exec) and 128+N signal deaths — so the test
# could report a pass without commit_scope.py ever having refused anything.
# commit_scope.py's documented no-carve-out code is exactly 1; nothing else is a
# refusal.
# shellcheck source=scripts/lib/resolve-cli.sh disable=SC1091
source "$ROOT/scripts/lib/resolve-cli.sh" 2>/dev/null || true
if command -v mkfifo >/dev/null 2>&1 && declare -F _portable_timeout >/dev/null 2>&1; then
    mkfifo "$se/.claude/settings.json"
    # Assignment PREFIXES, not `env`: _portable_timeout is a shell function and
    # `env` execs a binary, so the `env` form returns 127. The whole thing runs
    # in a command substitution, so the assignments cannot leak.
    fifo_out=$(HOME="$se/fakehome" XDG_CONFIG_HOME="$se/fakehome/.config" \
               GIT_CONFIG_SYSTEM=/dev/null \
               _portable_timeout 5 python3 -I "$SCOPE" "$se" "$se" .claude \
               < <(payload "git commit -m x" "$se") 2>/dev/null)
    # Capture the rc into a variable FIRST: `$?` inside the elif chain below
    # would be the status of the preceding `[[` test, not of the timed run.
    fifo_rc=$?
    case "$fifo_rc" in
        0)   fifo_verdict="accepted:$fifo_out" ;;   # the gate read a FIFO and vouched for it
        1)   fifo_verdict="REFUSE" ;;               # the documented no-carve-out code
        124) fifo_verdict="TIMEOUT" ;;              # the hang this guard exists to prevent
        *)   fifo_verdict="UNEXPECTED-rc$fifo_rc" ;;
    esac
    eq "FIFO at settings.json path → refused promptly, not a hang" "$fifo_verdict" "REFUSE"
    rm -f "$se/.claude/settings.json"
else
    no "FIFO regression test could not run" "needs mkfifo and _portable_timeout; refusing to report a pass this host never exercised"
fi

# A hostile git config can HANG git, and a hang is a bypass here: the gate runs
# under a 10s PreToolUse timeout whose expiry emits no decision, i.e. ALLOW.
# `[include] path = <fifo>` blocks `git config` until a writer connects. The
# shared subprocess deadline must turn that into a prompt refusal.
if command -v mkfifo >/dev/null 2>&1 && declare -F _portable_timeout >/dev/null 2>&1; then
    fresh; hang="$NEWREPO"; git -C "$hang" add docs/plans/p.md
    git -C "$hang" config --unset core.hooksPath
    mkdir -p "$hang/fakehome/.config/git"
    mkfifo "$hang/hangtrap"
    printf '[include]\n\tpath = %s/hangtrap\n' "$hang" >"$hang/fakehome/.config/git/config"
    hang_out=$(HOME="$hang/fakehome" XDG_CONFIG_HOME="$hang/fakehome/.config" \
               GIT_CONFIG_SYSTEM=/dev/null \
               _portable_timeout 9 python3 -I "$SCOPE" "$hang" "$hang" .claude \
               < <(payload "git commit -m x" "$hang") 2>/dev/null)
    hang_rc=$?
    case "$hang_rc" in
        0)   hang_verdict="accepted:$hang_out" ;;
        1)   hang_verdict="REFUSE" ;;
        124) hang_verdict="TIMEOUT" ;;
        *)   hang_verdict="UNEXPECTED-rc$hang_rc" ;;
    esac
    eq "git config that hangs on an include → refused within the budget, not a hang" \
       "$hang_verdict" "REFUSE"
    rm -f "$hang/hangtrap"
else
    no "hang-budget regression test could not run" "needs mkfifo and _portable_timeout; refusing to report a pass this host never exercised"
fi

# _settings_inert must check `.claude` even when state_dir names something else:
# Claude Code always merges <repo>/.claude/settings*.json regardless of the
# caller's own state_dir bookkeeping (BUSDRIVER_STATE_DIR — always ".claude" on
# the sole production call path, since sanitized-gate.sh's `env -i` strips that
# var before the gate runs; a caller that legitimately passes something else
# must not thereby blind the check to the directory Claude Code actually reads).
mkdir -p "$se/other-state"
printf '{"env":{"GIT_INDEX_FILE":"/tmp/other"}}\n' >"$se/.claude/settings.json"
eq "hostile .claude/settings.json refused even under an unrelated state_dir" \
   "$(payload "git commit -m x" "$se" \
      | env HOME="$se/fakehome" XDG_CONFIG_HOME="$se/fakehome/.config" \
            GIT_CONFIG_SYSTEM=/dev/null \
            python3 -I "$SCOPE" "$se" "$se" other-state 2>/dev/null || printf 'REFUSE')" \
   "REFUSE"
rm -f "$se/.claude/settings.json"

# The caller runs the design-doc predicate once per path, each forking python3 and
# git, inside a hook registered with a 10-SECOND timeout — and a timed-out
# PreToolUse hook emits NO decision, which reads as allow. The set is bounded
# fail-CLOSED rather than risking that.
fresh; pb="$NEWREPO"
# fresh already provides p.md and q.md, so 18 more makes exactly the bound.
for i in $(seq 1 18); do printf '# d%s\n' "$i" >"$pb/docs/plans/d$i.md"; done
git -C "$pb" add docs/plans >/dev/null 2>&1
eq "20 staged docs (at the bound) → accepted" \
   "$(scope "git commit -m x" "$pb" | wc -l | tr -d ' ')" "20"
printf '# d19\n' >"$pb/docs/plans/d19.md"; git -C "$pb" add docs/plans/d19.md >/dev/null 2>&1
eq "21 staged docs (over the bound) → refuse" "$(scope "git commit -m x" "$pb")" "REFUSE"

echo "── (Step 1b) differential: the claimed set IS git's real set ─────"

# `git diff --cached` is the only authority on what a commit would carry.
diffcheck(){                        # <repo> <label>
    local r="$1" claimed actual
    claimed="$(scope "git commit -m x" "$r" | LC_ALL=C sort)"
    actual="$(git -C "$r" diff --cached --name-only --no-renames 2>/dev/null | LC_ALL=C sort)"
    eq "claim == git's real index :: $2" "$claimed" "$actual"
}
fresh; d1="$NEWREPO"; git -C "$d1" add docs/plans/p.md;                     diffcheck "$d1" "one doc"
fresh; d2="$NEWREPO"; git -C "$d2" add docs/plans/p.md docs/plans/q.md;     diffcheck "$d2" "two docs"
fresh; d3="$NEWREPO"; git -C "$d3" add src/impl.py;                         diffcheck "$d3" "impl file"
fresh; d4="$NEWREPO"; git -C "$d4" add .;                                   diffcheck "$d4" "everything"

# A staged RENAME reports only its destination unless rename detection is off, so
# `src/impl.py` → `docs/plans/impl.md` would present as a lone design document
# while the commit deletes implementation code.
fresh; rn="$NEWREPO"
git -C "$rn" add src/impl.py >/dev/null 2>&1
git -C "$rn" commit -qm base >/dev/null 2>&1
git -C "$rn" mv src/impl.py docs/plans/impl.md >/dev/null 2>&1
case "$(scope "git commit -m x" "$rn")" in
    *src/impl.py*) ok "a staged rename reports its SOURCE too (--no-renames)" ;;
    *)             no "a staged rename reports its SOURCE too" "claim=[$(scope "git commit -m x" "$rn")]" ;;
esac

# A staged SYMLINK whose working-tree path is later a regular document: the
# caller's predicate resolves the working tree, i.e. the file git is NOT committing.
fresh; sy="$NEWREPO"
ln -s ../../src/impl.py "$sy/docs/plans/sneaky.md"
git -C "$sy" add docs/plans/sneaky.md >/dev/null 2>&1
rm -f "$sy/docs/plans/sneaky.md"; printf '# innocent\n' >"$sy/docs/plans/sneaky.md"
eq "staged symlink, regular file in the worktree → refuse" \
   "$(scope "git commit -m x" "$sy")" "REFUSE"

# BOTH modes are checked, not just the new one. A staged DELETION has no index
# entry at all, so an `ls-files --stage` version skipped it and a deleted symlink
# named like a document passed as one.
fresh; dl="$NEWREPO"
ln -s ../../src/impl.py "$dl/docs/plans/component.md"
git -C "$dl" add docs/plans/component.md src/impl.py >/dev/null 2>&1
git -C "$dl" commit -qm base >/dev/null 2>&1
git -C "$dl" rm -q docs/plans/component.md >/dev/null 2>&1
eq "staged DELETION of a symlink named like a doc → refuse" \
   "$(scope "git commit -m x" "$dl")" "REFUSE"
# Negative control: deleting a REAL document is a document change, and passes.
fresh; dr="$NEWREPO"
git -C "$dr" add docs/plans/p.md >/dev/null 2>&1
git -C "$dr" commit -qm base >/dev/null 2>&1
git -C "$dr" rm -q docs/plans/p.md >/dev/null 2>&1
eq "staged deletion of a real document → accepted" \
   "$(scope "git commit -m x" "$dr")" "docs/plans/p.md"

# Generated sweep over the command grammar. The hand-picked list is only as good
# as what someone thought to write down, and twice it was not: the shell-active
# message and the adjacent control operator both passed a review whose examples
# were chosen by the same person who wrote the parser. Every command the helper
# ACCEPTS must still claim exactly git's index. Deterministic — fixed vocabulary.
fresh; g="$NEWREPO"; git -C "$g" add docs/plans/p.md src/impl.py
EXPECTED="$(git -C "$g" diff --cached --name-only --no-renames | LC_ALL=C sort)"
GEN_ACCEPT=0; GEN_REFUSE=0; GEN_BAD=0
while IFS= read -r gc; do
    [[ -n "$gc" ]] || continue
    claimed="$(scope "$gc" "$g")"
    if [[ "$claimed" = "REFUSE" ]]; then GEN_REFUSE=$((GEN_REFUSE + 1)); continue; fi
    if [[ "$(printf '%s' "$claimed" | LC_ALL=C sort)" != "$EXPECTED" ]]; then
        GEN_BAD=$((GEN_BAD + 1))
        no "generated: claim == git's real index" "cmd=$gc claim=[$claimed]"
    fi
    GEN_ACCEPT=$((GEN_ACCEPT + 1))
done < <(python3 - <<'GENEOF'
import itertools
heads = ["git commit", "git commit-x", "git -C . commit", "/usr/bin/git commit",
         "git add docs/plans/q.md && git commit"]
opts = ["", " -q", " -a", " --amend", " --no-verify", " --only", " -- docs/plans/p.md"]
msgs = ["", " -m x", " -m 'fix(scope): a b'", " -m 'a && b'", ' -m "$(git add src/impl.py)"',
        " -m {msg,-a}", " -m fix*", " -m 'fix [gate]: x'", " --message=x", " -mx",
        " -m x ';' more", " -m x | tee /dev/null", " -m x > /dev/null", " -m x & true"]
print("\n".join(h + o + m for h, o, m in itertools.product(heads, opts, msgs)))
GENEOF
)
if [[ "$GEN_BAD" -eq 0 ]]; then
    ok "generated sweep: claim == git's index on every accepted command"
fi
# Assert the PARTITION, not only the invariant. "Every accepted command claims the
# current index" is true by construction, so a regression that started accepting
# `-a` or a chained add would leave GEN_BAD at zero and pass. Pinning the counts
# makes any change in what the parser accepts a deliberate edit to this line.
eq "generated sweep partition: accepted"  "$GEN_ACCEPT" "12"
eq "generated sweep partition: refused"   "$GEN_REFUSE" "478"

echo "── (Step 2) the gate — Gate 1 fires unless the set is all docs ────"

# (a) docs-only staged commit, review pending → past Gate 1.
fresh; a="$NEWREPO"
# Mirror THIS repository's real config: core.fsmonitor=true. The first revision of
# the fsmonitor check refused a boolean and would have disabled the carve-out here
# while every scratch-repo test still passed.
git -C "$a" config core.fsmonitor true
bash "$R" arm "$a/docs/plans/p.md" >/dev/null 2>&1 || true
git -C "$a" add docs/plans/p.md
eq "armed + docs-only staged commit → past Gate 1" \
   "$(verdict "git commit -m 'docs: fix'" "$a")" "past-gate1"

# (b) the carve-out must FALL THROUGH to Gate 2, not exit — litmus still runs.
out="$(payload "git commit -m 'docs: fix'" "$a" | bash "$GATE" 2>/dev/null)"
case "$out" in
    *"Design review required"*) no "carve-out falls through to Gate 2" "still on Gate 1" ;;
    *'"decision"'*)             ok "carve-out falls through to Gate 2 (a later gate still decided)" ;;
    *)                          no "carve-out falls through to Gate 2" "no decision emitted: $out" ;;
esac

# (c) announced on stderr — a gate that widens silently is unauditable.
err="$(payload "git commit -m 'docs: fix'" "$a" | bash "$GATE" 2>&1 >/dev/null)"
case "$err" in
    *"#685"*) ok "carve-out is announced on stderr" ;;
    *)        no "carve-out is announced on stderr" "got: $err" ;;
esac

# (d) one implementation file in the set and the block returns in full.
git -C "$a" add src/impl.py
eq "armed + mixed set → design-block" "$(verdict "git commit -m x" "$a")" "design-block"
git -C "$a" reset -q; git -C "$a" add src/impl.py
eq "armed + impl only → design-block" "$(verdict "git commit -m x" "$a")" "design-block"

# (e) refusal shapes reach the block, not the carve-out.
git -C "$a" reset -q; git -C "$a" add docs/plans/p.md
eq "armed + -a → design-block"           "$(verdict "git commit -am x" "$a")" "design-block"
eq "armed + chained add → design-block"  "$(verdict "git add docs/plans/q.md && git commit -m x" "$a")" "design-block"
git -C "$a" reset -q
eq "armed + nothing staged → design-block" "$(verdict "git commit -m x" "$a")" "design-block"

# (f) the block message must teach the two-step exit, or the loop still dead-ends.
msg="$(payload "git add docs/plans/p.md && git commit -m x" "$a" | bash "$GATE" 2>/dev/null)"
case "$msg" in
    *"SEPARATE calls"*) ok "block message names the two-step exit" ;;
    *)                  no "block message names the two-step exit" "got: ${msg:0:200}" ;;
esac

# (g) a symlinked doc escaping the design-doc location is not a design doc.
git -C "$a" reset -q
ln -s ../../src/impl.py "$a/docs/plans/link.md"
git -C "$a" add docs/plans/link.md >/dev/null 2>&1
eq "armed + symlinked doc → design-block" "$(verdict "git commit -m x" "$a")" "design-block"
rm -f "$a/docs/plans/link.md"; git -C "$a" reset -q

# (h) with NO review pending the gate never reaches Gate 1's branch at all —
#     proves the carve-out is not what is allowing (a).
fresh; c="$NEWREPO"; git -C "$c" add docs/plans/p.md
eq "no token armed → past Gate 1" "$(verdict "git commit -m x" "$c")" "past-gate1"

echo
printf "PASS: %d  FAIL: %d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
