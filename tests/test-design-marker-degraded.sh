#!/usr/bin/env bash
# #355: a `design-reviewed: PASS` marker must NOT be honored when it sits beside a
# `design-review-coverage: DEGRADED` marker. Tests the shared predicate that turns
# the plan's line-196 prose rule into a mechanical gate check, plus the Python
# classifier mirror (_doc_reviewed in marker_ops.py).
#
# Usage: bash tests/test-design-marker-degraded.sh   (exit 0 = all pass)
# ok/no only print+count and always return 0, so the A&&B||C caveat (SC2015)
# does not apply. SC1091: the sourced lib is resolved at runtime.
# shellcheck disable=SC2312,SC2015,SC1091
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source "$(pwd)/hooks/gate-scripts/lib/resolve-repo-dir.sh"

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
honored(){ gate_design_pass_honored "$1" && echo yes || echo no; }
# Python classifier mirror: _doc_reviewed(open(f).read()).
py_reviewed(){
  python3 -S -c "
import sys; sys.path.insert(0, '$(pwd)/hooks/gate-scripts/lib')
import marker_ops
print('yes' if marker_ops._doc_reviewed(open(sys.argv[1]).read()) else 'no')
" "$1"
}

T="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

# (a) PASS, no coverage marker → honored
printf '# plan\n<!-- design-reviewed: PASS -->\n' > "$T/a.md"
[[ "$(honored "$T/a.md")" == yes ]] && ok "PASS alone honored" || no "PASS alone honored"
[[ "$(py_reviewed "$T/a.md")" == yes ]] && ok "PASS alone honored (py)" || no "PASS alone honored (py)"

# (b) PASS + FULL coverage → honored
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULL 3/3 -->\n' > "$T/b.md"
[[ "$(honored "$T/b.md")" == yes ]] && ok "PASS+FULL honored" || no "PASS+FULL honored"

# (b2) PASS + UNKNOWN coverage → NOT honored (writer authorizes only on FULL, so
# any non-FULL marker — incl. UNKNOWN/empty — must block, matching the writer)
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: UNKNOWN 0/3 -->\n' > "$T/b2.md"
[[ "$(honored "$T/b2.md")" == no ]] && ok "PASS+UNKNOWN not honored" || no "PASS+UNKNOWN not honored"
[[ "$(py_reviewed "$T/b2.md")" == no ]] && ok "PASS+UNKNOWN not honored (py)" || no "PASS+UNKNOWN not honored (py)"

# (b3) PASS + malformed coverage marker (no status token) → NOT honored (fail-closed;
# an empty status must not vacuously pass)
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: -->\n' > "$T/b3.md"
[[ "$(honored "$T/b3.md")" == no ]] && ok "PASS+malformed-coverage not honored" || no "PASS+malformed-coverage not honored"
[[ "$(py_reviewed "$T/b3.md")" == no ]] && ok "PASS+malformed-coverage not honored (py)" || no "PASS+malformed-coverage not honored (py)"
# (b4) PASS + coverage prefix at EOF (no closing) → NOT honored
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage:' > "$T/b4.md"
[[ "$(py_reviewed "$T/b4.md")" == no ]] && ok "PASS+coverage-EOF not honored (py)" || no "PASS+coverage-EOF not honored (py)"
# (b5) PASS + truncated FULL (status word but no `-->` close) → NOT honored (must be well-formed)
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULL' > "$T/b5.md"
[[ "$(honored "$T/b5.md")" == no ]] && ok "PASS+truncated-FULL not honored" || no "PASS+truncated-FULL not honored"
[[ "$(py_reviewed "$T/b5.md")" == no ]] && ok "PASS+truncated-FULL not honored (py)" || no "PASS+truncated-FULL not honored (py)"
# (b5b) PASS + newline-split coverage marker (prefix, then FULL on next line) → NOT honored
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage:\nFULL 3/3 -->\n' > "$T/b5b.md"
[[ "$(py_reviewed "$T/b5b.md")" == no ]] && ok "PASS+split-marker not honored (py)" || no "PASS+split-marker not honored (py)"
# (b6) PASS + FULLISH / FULL-UNKNOWN (exact-token guard) → NOT honored
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULLISH 3/3 -->\n' > "$T/b6.md"
[[ "$(py_reviewed "$T/b6.md")" == no ]] && ok "PASS+FULLISH not honored (py)" || no "PASS+FULLISH not honored (py)"
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULL-UNKNOWN 0/3 -->\n' > "$T/b6b.md"
[[ "$(honored "$T/b6b.md")" == no ]] && ok "PASS+FULL-UNKNOWN not honored" || no "PASS+FULL-UNKNOWN not honored"
# (b7) two markers crammed on ONE line → NOT honored (each real marker is its own
# line by the writer's contract; a line bearing two is malformed ⇒ fail-closed)
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULL 3/3 --><!-- design-review-coverage: FULL 3/3 -->\n' > "$T/b7.md"
[[ "$(honored "$T/b7.md")" == no ]] && ok "two markers on one line not honored" || no "two markers on one line not honored"
# a FULL marker sharing a line with a DEGRADED marker must block (not read as FULL)
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULL 3/3 --><!-- design-review-coverage: DEGRADED 1/3 -->\n' > "$T/b7d.md"
[[ "$(py_reviewed "$T/b7d.md")" == no ]] && ok "FULL+DEGRADED same line not honored (py)" || no "FULL+DEGRADED same line not honored (py)"
# (b7e) inline coverage marker in PROSE is ignored by the reader (writer never rewrites it)
printf '<!-- design-reviewed: PASS -->\nsee <!-- design-review-coverage: DEGRADED 1/3 --> example\n<!-- design-review-coverage: FULL 3/3 -->\n' > "$T/b7e.md"
[[ "$(honored "$T/b7e.md")" == yes ]] && ok "inline prose coverage ignored, whole-line FULL honored" || no "inline prose coverage ignored"

# (b7b) PASS + FULL but contradictory/malformed count → NOT honored (FULL ⟺ 3/3)
for bad in 'FULL 0/3' 'FULL 2/3' 'FULL garbage' 'FULL 3/33' 'FULL 3/3-extra' 'FULL 3/3/4' 'FULL 3/3.5'; do
  printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: %s -->\n' "$bad" > "$T/b7b.md"
  [[ "$(py_reviewed "$T/b7b.md")" == no ]] && ok "PASS+'$bad' not honored (py)" || no "PASS+'$bad' not honored (py)"
done
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: FULL 0/3 -->\n' > "$T/b7c.md"
[[ "$(honored "$T/b7c.md")" == no ]] && ok "PASS+FULL-0/3 not honored" || no "PASS+FULL-0/3 not honored"

# (c) PASS + DEGRADED coverage → NOT honored (the #355 case)
printf '<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: DEGRADED 1/3 reviewer_3=runtime-failed -->\n' > "$T/c.md"
[[ "$(honored "$T/c.md")" == no ]] && ok "PASS+DEGRADED not honored" || no "PASS+DEGRADED not honored"
[[ "$(py_reviewed "$T/c.md")" == no ]] && ok "PASS+DEGRADED not honored (py)" || no "PASS+DEGRADED not honored (py)"

# (d) DEGRADED marker above PASS (order-independent) → NOT honored
printf '<!-- design-review-coverage: DEGRADED 2/3 -->\n<!-- design-reviewed: PASS -->\n' > "$T/d.md"
[[ "$(honored "$T/d.md")" == no ]] && ok "DEGRADED-then-PASS not honored" || no "DEGRADED-then-PASS not honored"

# (e) no PASS marker → not honored
printf '<!-- design-reviewed: PENDING -->\n' > "$T/e.md"
[[ "$(honored "$T/e.md")" == no ]] && ok "PENDING not honored" || no "PENDING not honored"

# (f) missing file → not honored
[[ "$(honored "$T/nope.md")" == no ]] && ok "missing file not honored" || no "missing file not honored"

# (g) PASS buried in arbitrary surrounding prose + a FULL marker → honored (both engines)
printf 'lorem\n## Round-4\n<!-- design-reviewed: PASS -->\nmore text\n<!-- design-review-coverage: FULL 3/3 -->\ntail\n' > "$T/g.md"
[[ "$(honored "$T/g.md")" == yes ]] && ok "PASS in prose honored" || no "PASS in prose honored"
[[ "$(py_reviewed "$T/g.md")" == yes ]] && ok "PASS in prose honored (py)" || no "PASS in prose honored (py)"

# (h) duplicate PASS markers, one DEGRADED among them → NOT honored (any DEGRADED wins)
printf '<!-- design-reviewed: PASS -->\n<!-- design-reviewed: PASS -->\n<!-- design-review-coverage: DEGRADED 2/3 -->\n' > "$T/h.md"
[[ "$(honored "$T/h.md")" == no ]] && ok "dup PASS + one DEGRADED not honored" || no "dup PASS + one DEGRADED not honored"
[[ "$(py_reviewed "$T/h.md")" == no ]] && ok "dup PASS + one DEGRADED not honored (py)" || no "dup PASS + one DEGRADED not honored (py)"

# (i) unreadable PASS doc → fail-closed, not honored (skip if root can read anything)
if [[ "$(id -u)" != "0" ]]; then
  printf '<!-- design-reviewed: PASS -->\n' > "$T/i.md"; chmod 000 "$T/i.md"
  [[ "$(honored "$T/i.md")" == no ]] && ok "unreadable doc not honored (fail-closed)" || no "unreadable doc not honored"
  chmod 644 "$T/i.md"
else
  ok "unreadable doc case skipped (running as root)"
fi

# (j) NUL byte where a space belongs → NOT the real marker → not honored (both
# engines must agree: Bash grep is byte-faithful, Python preserves the NUL).
printf '<!-- design-reviewed: PASS\000 -->\n' > "$T/j.md"
[[ "$(honored "$T/j.md")" == no ]] && ok "NUL-forged marker not honored" || no "NUL-forged marker not honored"
[[ "$(py_reviewed "$T/j.md")" == no ]] && ok "NUL-forged marker not honored (py)" || no "NUL-forged marker not honored (py)"

# (k) Randomized parity fuzz: the Bash reader delegates to the Python predicate, so
# they must agree on ARBITRARY content — random fragments (incl. marker pieces, NUL,
# newlines) in random order/counts. Guards against the delegation ever regressing to
# a divergent native reimplementation. Deterministic seed via $RANDOM is fine here.
FRAGS=('<!-- design-reviewed: PASS -->' '<!-- design-review-coverage: DEGRADED 1/3 -->'
       '<!-- design-review-coverage: FULL 3/3 -->' '<!-- design-review-coverage: UNKNOWN 0/3 -->'
       'plain text' '<!-- design-reviewed: PENDING -->' 'PASS' 'DEGRADED')
fuzz_fail=0
for i in $(seq 1 60); do
  ff="$T/fuzz.$i.md"; : > "$ff"
  n=$(( RANDOM % 5 + 1 ))
  for _ in $(seq 1 "$n"); do
    printf '%s\n' "${FRAGS[$(( RANDOM % ${#FRAGS[@]} ))]}" >> "$ff"
    (( RANDOM % 4 == 0 )) && printf 'x\000y\n' >> "$ff"  # occasional NUL
  done
  b="$(honored "$ff")"; p="$(py_reviewed "$ff")"
  [[ "$b" == "$p" ]] || { fuzz_fail=$((fuzz_fail + 1)); no "fuzz parity #$i" "bash=$b py=$p"; }
done
[[ "$fuzz_fail" -eq 0 ]] && ok "randomized bash/python parity (60 docs)" || no "randomized parity" "$fuzz_fail mismatches"

echo "-------- $PASS passed, $FAIL failed --------"
[[ "$FAIL" -eq 0 ]]
