#!/usr/bin/env bash
# test-careful-guard-truncation.sh
# Regression for #377 residual 1: a recursive rm wrapped DEEPER than
# gitcmd_detect._all_chunks expands (its _depth < 6 bound) was never surfaced,
# so careful-guard's structured scan returned "safe" for a command it had not
# fully read — and the raw-text grep fallback does NOT backstop it, because the
# fallback only runs when the scanner fails to produce a verdict at all.
#
# Measured before the fix: 7-level eval nesting => guard ALLOWED.
#
# The fix is a truncation SIGNAL (gitcmd_detect.extraction_truncated), not a
# raw-text heuristic — "extraction hit its bound with payloads left unexpanded"
# is a fact the extractor knows, where the raw-text backstop family had to guess
# (and drew a fresh adversarial finding on every iteration in #376).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GUARD="hooks/gate-scripts/careful-guard.sh"
LIB_DIR="$(pwd)/hooks/gate-scripts/lib"

pass=0 fail=0
check() { # name expected actual
  if [[ "$3" == "$2" ]]; then echo "PASS: $1"; pass=$((pass+1))
  else echo "FAIL: $1 — expected $2 got $3"; fail=$((fail+1)); fi
}

# Wrappers so call sites hold no command substitution at all.
check_unit() { # name expected depth-key
  local got
  got=$(awk -v d="$3" '$1==d{print $2}' <<<"$unit")
  check "$1" "$2" "$got"
}
check_cmd() { # name expected command
  local got
  got=$(verdict "$3")
  check "$1" "$2" "$got"
}
check_nested() { # name expected depth
  local cmd got
  cmd=$(nested "$3")
  got=$(verdict "$cmd")
  check "$1" "$2" "$got"
}

# ── unit: the signal mirrors _all_chunks' own bound ──────────────────────────
echo "── extraction_truncated (unit) ──"
unit=$(PYTHONPATH="$LIB_DIR" python3 - <<'PY'
import shlex
import gitcmd_detect as g

def nest(n, inner="rm -rf /etc"):
    c = inner
    for _ in range(n):
        c = "eval " + shlex.quote(c)
    return c

# Depths at/below the bound are fully expanded; beyond it, payloads are left.
for d in range(0, 10):
    print(d, "TRUNCATED" if g.extraction_truncated(nest(d)) else "COMPLETE")
# A flat command has nothing left over, regardless of how destructive it is.
print("flat", "TRUNCATED" if g.extraction_truncated("rm -rf /etc") else "COMPLETE")
PY
)
for d in 0 1 2 3 4 5 6; do
  check_unit "depth $d fully expanded" "COMPLETE" "$d"
done
for d in 7 8 9; do
  check_unit "depth $d reports truncation" "TRUNCATED" "$d"
done
check_unit "flat command" "COMPLETE" flat

# ── e2e: the guard actually fires (and actually stays quiet) ─────────────────
echo "── careful-guard end-to-end ──"
verdict() { # <command> -> ask|allow
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" \
    | bash "$GUARD" \
    | grep -q '"permissionDecision":"ask"' && echo ask || echo allow
}
nested() { # <depth>
  python3 -c '
import shlex, sys
c = "rm -rf /etc"
for _ in range(int(sys.argv[1])): c = "eval " + shlex.quote(c)
print(c)' "$1"
}

# The #377 hole itself. Depth 6 was already caught; depth 7 was ALLOWED.
check_nested "depth 6 nested rm (was already caught)" ask   6
check_nested "depth 7 nested rm (the #377 fail-open)"  ask   7
check_nested "depth 8 nested rm"                       ask   8

# Over-warning is safe here, but not free — ordinary work must stay silent.
check_cmd "plain ls"                  allow 'ls -la'
check_cmd "git status"                allow 'git status --short'
check_cmd "npm build"                 allow 'npm run build'
check_cmd "safe-artifact rm"          allow 'rm -rf node_modules'
check_cmd "shallow bash -c, harmless" allow 'bash -c "echo hello"'
check_cmd "one substitution"          allow 'echo $(git rev-parse HEAD)'

# Still caught the ordinary way — the new signal must not have displaced it.
check_cmd "flat destructive rm"       ask   'rm -rf /etc'

# Deep substitutions DO warn, and that is correct rather than a false positive:
# the signal now comes from _all_chunks' own traversal, so it reports exactly
# "this walk hit its bound with payloads left unexpanded". Over-warning is the
# documented safe direction for an advisory guard. Two earlier attempts tried to
# suppress this by re-deriving depth in a parallel walker, and each drifted from
# the real accounting — Codex caught both (a substitution-wrapped eval chain was
# wrongly cleared, and the re-walk went exponential).
deep_subst() { # <depth> — harmless, fully analyzable at any depth
  # shellcheck disable=SC2016  # python source: $ / %s must not expand in bash
  python3 -c '
import sys
c = "echo hi"
for _ in range(int(sys.argv[1])): c = "echo $(%s)" % c
print(c)' "$1"
}
check_cmd_dyn() { # name expected <generator output>
  check "$1" "$2" "$(verdict "$3")"
}
check_cmd_dyn "deep subst warns (bound was hit)"  ask "$(deep_subst 7)"
check_cmd_dyn "deeper subst warns"                ask "$(deep_subst 12)"
# Shallow substitutions must stay silent — the bound is only hit when deep.
check_cmd_dyn "shallow subst stays quiet"       allow "$(deep_subst 2)"
# A payload hiding INSIDE a substitution must be caught. Codex's second finding:
# walking substitution bodies at the parent's depth (rather than +1, as
# _all_chunks does) cleared this — the eval chain went dark but nothing said so.
check_cmd_dyn "eval-6 wrapped in a substitution" ask \
  "echo \$($(nested 6))"

# Control-keyword coverage — the payoff of stacking this on the keyword-bypass
# fix. Before that fix careful-guard cleared a destructive rm hidden behind a
# reserved word (split_segments makes the command word `then`/`do`, so
# _shell_payloads extracted nothing). Codex flagged it here; it is fixed once at
# the detector level (_command_argv) and this guard inherits it via _all_chunks.
check_cmd "rm behind then"       ask 'if true; then rm -rf /etc; fi'
check_cmd "rm behind do (loop)"  ask 'for f in a; do rm -rf /etc; done'
check_cmd "rm in a case arm"     ask 'case x in x) rm -rf /etc;; esac'
check_cmd "eval-rm behind then"  ask 'if true; then eval "rm -rf /etc"; fi'
# (No "benign keyword + literal rm" case here: careful-guard scans EVERY token
#  for `rm`, not just the command word, so `echo then rm -rf /etc` over-warns on
#  the literal rm on main too — that is this advisory guard's intended bias, not
#  a keyword-handling effect.)

echo "---"
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
