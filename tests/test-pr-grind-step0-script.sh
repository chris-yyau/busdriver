#!/usr/bin/env bash
# Tests for scripts/pr-grind-step0.sh, pr-grind's Step 0 moved out of SKILL.md by #1078.
# Covers argument validation (bad input exits 2 with nothing on stdout, before any `gh` call)
# and the one new branch, the identity-call form: the URL reaches pr-head-identity.sh only
# when a second argument was passed — even an empty one, which the helper must refuse.
# `gh` and pr-head-identity.sh are stubs and the run stops at the identity refusal, before
# any fetch or worktree; nothing here talks to GitHub.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

T="$(mktemp -d -t pr-grind-step0-script.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# A plugin root holding the real script beside a stub identity helper, and a stub gh.
P="$T/plugin"
mkdir -p "$P/scripts" "$T/bin" "$T/cwd"
cp "$ROOT/scripts/pr-grind-step0.sh" "$P/scripts/"
cat >"$P/scripts/pr-head-identity.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
for a in "$@"; do printf '[%s]' "$a"; done >"$IDENT_LOG"
echo "pr-head-identity: stub refuses" >&2
exit 1
EOF
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "GH_HOST=${GH_HOST:-} $*" >>"$GH_LOG"
printf '%s\n' '{"baseRefName":"main","headRefName":"feat/x","headRefOid":"0123456789abcdef0123456789abcdef01234567","isCrossRepository":false,"url":"https://github.com/o/r/pull/12"}'
EOF
chmod +x "$P/scripts/"*.sh "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" IDENT_LOG="$T/ident.log"
STEP0="$P/scripts/pr-grind-step0.sh"

run() { # runs the script at the scratch cwd; sets OUT and RC
  OUT=$(cd "$T/cwd" && bash "$STEP0" "$@" 2>/dev/null)
  RC=$?
}

echo "== argument validation exits 2, prints nothing on stdout, and never calls gh"
bad_args() { # <label> <args...>
  local label="$1"
  shift
  rm -f "$GH_LOG"
  run "$@"
  if [ "$RC" = 2 ] && [ -z "$OUT" ] && [ ! -e "$GH_LOG" ]; then ok "$label"; else no "$label" "rc=$RC out=$OUT gh=$(cat "$GH_LOG" 2>/dev/null)"; fi
}
bad_args "no arguments"
bad_args "three arguments" 12 https://github.com/o/r/pull/12 extra
bad_args "empty PR" ""
bad_args "non-numeric PR" 12x
bad_args "leading-zero PR" 012
bad_args "zero PR" 0
bad_args "URL containing a single quote" 12 "https://github.com/o/r/pull/12'"

echo "== the identity call takes the URL form only when a second argument was passed"
ident_case() { # <label> <want argv> <args...>
  local label="$1" want="$2"
  shift 2
  rm -f "$GH_LOG" "$IDENT_LOG"
  run "$@"
  local got
  got=$(cat "$IDENT_LOG" 2>/dev/null)
  if [ "$RC" = 1 ] && [ "$got" = "$want" ]; then ok "$label"; else no "$label" "rc=$RC argv=$got"; fi
}
ident_case "PR named by number: --pr-number only" "[--pr-number][12]" 12
ident_case "PR named by URL: the URL verbatim" \
  "[--pr-number][12][--invocation-url][https://github.com/O/R/pull/12/]" 12 "https://github.com/O/R/pull/12/"
ident_case "an empty URL still reaches the helper (it is the only validator)" \
  "[--pr-number][12][--invocation-url][]" 12 ""
case "$OUT" in *"PR_BRANCH=feat/x"*) ok "  ...after printing PR_BRANCH= for the wrapper" ;; *) no "  ...after printing PR_BRANCH= for the wrapper" "$OUT" ;; esac
case "$OUT" in *WORKTREE_DIR=*|*BASE_SHA=*) no "  ...and stops before resolving a worktree" "$OUT" ;; *) ok "  ...and stops before resolving a worktree" ;; esac
[ "$(grep -c . "$GH_LOG")" = 1 ] && grep -q '^GH_HOST=github.com pr view 12 --json ' "$GH_LOG" \
  && ok "one gh pr view, pinned to github.com" || no "one gh pr view, pinned to github.com" "$(cat "$GH_LOG" 2>/dev/null)"

echo "════ pr-grind-step0-script: $PASS passed, $FAIL failed ════"
[ "$FAIL" -eq 0 ]
