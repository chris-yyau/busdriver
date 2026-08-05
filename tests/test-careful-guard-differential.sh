#!/usr/bin/env bash
# test-careful-guard-differential.sh
#
# The other suites pin ONE spelling per case, written by hand after a review
# round found it. That is how every defect in this parser reached review: the
# fixture set only ever contained the shapes someone had already thought of, so
# a spelling COMPOSED of two known-safe transforms went unread.
#
# This suite generates the compositions instead of enumerating them. It takes a
# handful of destructive commands, applies every combination of N obfuscating
# transforms that BASH ITSELF reassembles into the same command, and asserts the
# guard still asks. The transforms are the ones the guard normalises for -
# quoting, escapes, empty expansions, line continuations, path prefixes - so a
# composition that slips through is a real bypass, not a fixture quirk.
#
# The oracle is bash, not a second copy of the guard's beliefs: every generated
# spelling is handed to `bash -n` before it is asserted on, and the transforms
# are only ones whose reassembly is a documented bash rule. That keeps this a
# DIFFERENTIAL test (bash says these are the same command; does the guard?)
# rather than a restatement of the implementation. A spelling bash cannot even
# parse is a broken FIXTURE, and it fails here rather than quietly passing.
#
# BOUNDED on purpose: two transforms deep over a fixed seed set, so the run
# stays a few seconds. It is a net, not a proof - a fuzzer with a budget large
# enough to be a proof would not belong in a pre-commit suite.
set -uo pipefail
# Resolve the suite directory BEFORE cd-ing: a relative `dirname "$0"` read
# after the cd points at the new cwd, the source silently finds nothing, `check`
# is undefined, and the suite exits 0 with fail=0 — a false PASS in a file whose
# whole job is to prevent one. Same convention as the sibling suites.
_HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
cd "$_HERE/.." || exit 1

# shellcheck disable=SC2034  # read by the sourced harness below
GUARD="hooks/gate-scripts/careful-guard.sh"
pass=0 fail=0
# shellcheck source=tests/lib/careful-guard-harness.sh
# shellcheck disable=SC1091  # the source= path above needs `shellcheck -x`
. "$_HERE/lib/careful-guard-harness.sh" || exit 1

# Commands the guard MUST warn about in their plain spelling. Each is checked
# plain first, so a seed that stopped being destructive fails loudly here rather
# than silently weakening every composition built on it.
# `rm -rf /etc`, not `rm -rf build`: the rm classifier deliberately allows a
# recursive delete of a build ARTIFACT, so that spelling is not a seed at all.
SEEDS=(
  'truncate -s 0 audit.log'
  'psql -c "TRUNCATE users"'
  'rm -rf /etc'
)

# Each transform rewrites the COMMAND WORD of a seed into a spelling bash
# reassembles to the same name. `%s` is the command word.
#
# Every one of these is a documented bash rule, not a guess:
#   quote split      - adjacent quoted and unquoted text is ONE word
#   backslash        - a backslash before an ordinary character is dropped
#   ANSI-C hex       - $'\x74' is the character t
#   empty expansion  - an unset parameter expands to nothing and the halves meet
#   positional list  - with no arguments, $@ expands to nothing at all
#   backtick         - `true` substitutes to the empty string
#   absolute path    - the guard reads the basename, bash runs the same binary
#   line continuation- a backslash-newline is deleted before tokenising
# The splice point is index 1 — after the first character — so a two-letter
# command word works as well as a nine-letter one. A fixed deeper offset silently
# produced garbage for `rm`, which is its own lesson about generated fixtures.
# shellcheck disable=SC2016  # every expansion below must reach the guard UNexpanded
transform() { # <name> <command-word> -> spelling
  local t=$1 w=$2 head=${2:0:1} tail=${2:1}
  case "$t" in
    plain)     printf '%s' "$w" ;;
    quote)     printf '%s"%s"' "$head" "$tail" ;;
    backslash) printf '%s\\%s' "$head" "$tail" ;;
    empty)     printf '%s${EMPTY}%s' "$head" "$tail" ;;
    posparam)  printf '%s$@%s' "$head" "$tail" ;;
    backtick)  printf '%s`true`%s' "$head" "$tail" ;;
    contin)    printf '%s\\\n%s' "$head" "$tail" ;;
    *)         return 1 ;;
  esac
}

TRANSFORMS=(plain quote backslash empty posparam backtick contin)

# ANSI-C needs the character code, which the case above cannot compute portably
# in one printf. Build it separately.
ansic_spelling() { # <command-word> -> $'\x..<rest>'
  local w=$1 first
  printf -v first '%02x' "'${w:0:1}"
  printf '$%s\\x%s%s%s' "'" "$first" "${w:1}" "'"
}

# The `bash -n` oracle, wrapping the shared harness check. A fixture bash cannot
# parse proves nothing about the guard, so it fails as a fixture error.
_raw_check=$(declare -f check)
eval "_harness_check() ${_raw_check#*"()"}"
check() { # name expected command
  if ! bash -n <<<"$3" 2>/dev/null; then
    echo "FAIL: $1 — fixture is not valid bash"; fail=$((fail+1)); return
  fi
  _harness_check "$@"
}

echo "── seeds warn in their plain spelling ──"
for seed in "${SEEDS[@]}"; do
  check "seed: $seed" ask "$seed"
done

echo
echo "── one transform ──"
for seed in "${SEEDS[@]}"; do
  word=${seed%% *}
  rest=${seed#* }
  for t in "${TRANSFORMS[@]}"; do
    [[ "$t" == plain ]] && continue
    spelled=$(transform "$t" "$word") || continue
    check "$t: $word" ask "$spelled $rest"
  done
  spelled=$(ansic_spelling "$word") || exit 1
  check "ansic: $word" ask "$spelled $rest"
  # An absolute path is a transform of the whole word rather than a splice.
  check "abspath: $word" ask "/usr/bin/$seed"
done

echo
echo "── two transforms composed ──"
# The composition that matters: a transform applied to the OUTPUT of another.
# This is the class every round of review kept finding, because a fixture set
# written one shape at a time never contains it.
for seed in "${SEEDS[@]}"; do
  word=${seed%% *}
  rest=${seed#* }
  for a in "${TRANSFORMS[@]}"; do
    [[ "$a" == plain || "$a" == contin ]] && continue
    inner=$(transform "$a" "$word") || continue
    for b in quote backslash empty posparam backtick; do
      [[ "$b" == "$a" ]] && continue
      # Splice the second transform in AFTER the first, at a point that is
      # still inside the reassembled name.
      spelled="${inner}"
      case "$b" in
        quote)     spelled="\"${inner:0:1}\"${inner:1}" ;;
        backslash) spelled="\\${inner}" ;;
        empty)     spelled="\${EMPTY}${inner}" ;;
        posparam)  spelled="\$@${inner}" ;;
        backtick)  spelled="\`true\`${inner}" ;;
      esac
      check "$a+$b: $word" ask "$spelled $rest"
    done
  done
done

echo
echo "── the transforms must not warn on a BENIGN command ──"
# The same generator run over harmless command words. A transform that makes
# `echo` look destructive would show up here as a false positive, which is what
# keeps this suite from being satisfiable by simply warning on everything.
for word in echo printf git; do
  for t in "${TRANSFORMS[@]}"; do
    [[ "$t" == plain ]] && continue
    spelled=$(transform "$t" "$word") || continue
    check "benign $t: $word" allow "$spelled hello"
  done
done

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
