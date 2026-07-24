#!/usr/bin/env bash
# tests/test-codex-nudge-precreate.sh
#
# Verifies hooks/gate-scripts/codex-nudge-precreate.sh — the NON-GATING PostToolUse
# hook that fires the `@codex review` nudge right after a SUCCESSFUL `gh pr create`,
# so Codex gets its full pre-merge window (ADR 0024 revisit #1 / issue #473). Only
# `gh` is stubbed — it serves the authoritative PR resolution (`pr view --json
# number,headRefOid,url`, no positional → current-branch PR), the active probe
# (graphql), and records `pr comment` (body + PR number). Every other script
# (codex-nudge-if-expected → codex-retrigger, codex-active-repo) runs for real.
#
# Contract asserted: the hook NEVER writes stdout and always exits 0; posts exactly
# ONE `@codex review` — on the AUTHORITATIVELY-resolved current-branch PR (not a
# decoy URL echoed in the output) — on a confirmed-successful create in a
# Codex-active repo; reads the created-PR URL from EITHER tool_output OR
# tool_response; and posts NOTHING on a FAILED create (already-exists / non-zero
# exit), an inactive repo, the kill switch, a cross-repo URL, or a non-create.
#
# shellcheck disable=SC2312  # test harness: masked returns of grep/cat/payload-builders are intentional
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/gate-scripts/codex-nudge-precreate.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
if [[ ! -f "$HOOK" ]]; then fail "missing $HOOK"; echo "Results: 0 passed, 1 failed"; exit 1; fi
command -v jq >/dev/null 2>&1 || { fail "jq required for this test"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP_BASE=$(mktemp -d)
cleanup() { rm -rf "$TMP_BASE"; return 0; }
trap cleanup EXIT
mk() { mktemp -d "$TMP_BASE/XXXXXX"; }

PR=515
HEAD=abcdef0123456789abcdef0123456789abcdef01
SLUG=testowner/testrepo
URL="https://github.com/$SLUG/pull/$PR"

ACTIVE_JSON='{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]},"reactions":{"nodes":[]}}]}}}}'
INACTIVE_JSON='{"data":{"repository":{"pullRequests":{"nodes":[{"reviews":{"nodes":[]},"reactions":{"nodes":[]}}]}}}}'

# gh stub. Dispatch on argv:
#   pr comment  → append --body to $GH_BODYFILE, and the PR positional to $GH_CMT_PR
#   pr view (no positional) → {number,headRefOid,url} JSON = the current-branch PR
#   api graphql …pullRequests( → $ACTIVE_FIXTURE (codex-active-repo.sh probe)
#   api …/pulls|issues …       → empty (no prior engagement)
make_gh_stub() {
  cat > "$1/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "comment" ]]; then
  prev=""; for a in "$@"; do [[ "$prev" == "--body" ]] && printf '%s\n' "$a" >> "${GH_BODYFILE:?}"; prev="$a"; done
  # first non-flag positional after `comment` is the PR number
  for a in "${@:3}"; do case "$a" in -*) ;; *) printf '%s\n' "$a" >> "${GH_CMT_PR:?}"; break ;; esac; done
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  num="${GH_PR_NUMBER:?}"; case "${3:-}" in ''|-*) ;; *) num="$3" ;; esac   # echo the requested PR
  printf '{"number":%s,"headRefOid":"%s","url":"https://github.com/%s/pull/%s","state":"%s"}\n' \
    "$num" "${HEAD_FIXT:?}" "${GH_SLUG:?}" "$num" "${GH_STATE:-OPEN}"
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  case "$*" in
    *graphql*)    case "$*" in *'pullRequests('*) [[ -n "${ACTIVE_FIXTURE:-}" ]] && cat "$ACTIVE_FIXTURE" ;; esac ;;
    */reviews*)   printf '%s' "${REVIEW_LOGINS:-}" ;;
    */reactions*) printf '%s' "${REACTION_LOGINS:-}" ;;
  esac
  exit 0
fi
exit 0
STUB
  chmod +x "$1/gh"
}

setup_case() {
  REPO=$(mk); BIN=$(mk); BODY="$(mk)/bodies"; CMTPR="$(mk)/cmtpr"; : > "$BODY"; : > "$CMTPR"
  ( cd "$REPO"
    git init -q
    git config user.email t@t.t; git config user.name t
    git commit -q --allow-empty -m init
    git remote add origin "https://github.com/$SLUG.git" ) >/dev/null 2>&1
  make_gh_stub "$BIN"
  AF="$(mk)/af"; printf '%s' "$ACTIVE_JSON" > "$AF"
}

# run_hook <cmd> <tool-output-json-object> [extra VAR=val ...]
#   <tool-output-json-object> is a jq expression building the response container,
#   referencing $out (the output text). Use $TOJSON_OUTPUT or $TOJSON_RESPONSE.
run_hook() {
  local payload="$2"; shift 2   # $1 (a human-readable cmd label) is intentionally ignored
  set +e
  OUT=$(printf '%s' "$payload" | env PATH="$BIN:$PATH" \
        GH_BODYFILE="$BODY" GH_CMT_PR="$CMTPR" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
        REVIEW_LOGINS="" REACTION_LOGINS="" "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
  set -e
  N=$(grep -c '@codex review' "$BODY" 2>/dev/null || true); [[ -n "$N" ]] || N=0
  B=$(cat "$BODY" 2>/dev/null || true)
  CMT=$(cat "$CMTPR" 2>/dev/null || true)
}

# payload builders (tool_output vs tool_response; optional exit_code)
pl_output()   { jq -n --arg cwd "$REPO" --arg cmd "$1" --arg out "$2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_output:{output:$out}}'; }
pl_output_ec(){ jq -n --arg cwd "$REPO" --arg cmd "$1" --arg out "$2" --argjson ec "$3" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_output:{output:$out,exit_code:$ec}}'; }
pl_response() { jq -n --arg cwd "$REPO" --arg cmd "$1" --arg out "$2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_response:{stdout:$out}}'; }
# exit_code as a NON-numeric string (harness reported something unparseable)
pl_output_ecstr(){ jq -n --arg cwd "$REPO" --arg cmd "$1" --arg out "$2" --arg ec "$3" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_output:{output:$out,exit_code:$ec}}'; }

# ── Case 1: success + active → one `@codex review` on the resolved PR ──
setup_case
run_hook "gh pr create --fill" "$(pl_output 'gh pr create --fill' "$URL")"
if [[ "$RC" == 0 && -z "$OUT" ]]; then ok "success+active: silent approve"; else fail "success+active: rc=$RC stdout='$OUT'"; fi
if [[ "$N" == 1 && "$CMT" == "$PR" ]]; then ok "success+active: one nudge on PR $PR"; else fail "success+active: N=$N cmt='$CMT' body='$B'"; fi

# ── Case 2: created-PR URL delivered via tool_response (not tool_output) → fires ──
setup_case
run_hook "gh pr create --fill" "$(pl_response 'gh pr create --fill' "$URL")"
if [[ "$RC" == 0 && "$N" == 1 && "$CMT" == "$PR" ]]; then ok "tool_response shape: nudge fires"; else fail "tool_response: N=$N cmt='$CMT'"; fi

# ── Case 2c: `gh pr create --head <other-branch>` prints a PR (888) whose head is
#            NOT the checked-out branch (gh-resolved current PR is 515) → fail-safe
#            MISS (the printed URL is not this branch's, so the guard skips) ──
setup_case
run_hook "gh pr create --head feature --fill" "$(pl_output 'gh pr create --head feature --fill' "https://github.com/$SLUG/pull/888")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "--head create (PR != current branch): no nudge (fail-safe miss)"; else fail "--head: N=$N cmt='$CMT'"; fi

# ── Case 2d: trailing branch switch — `gh pr create --fill && git switch main`.
#            PostToolUse fires post-command, so gh pr view resolves main (PR 600),
#            but gh printed the CREATED PR's URL (515) → guard skips → fail-safe
#            MISS. Proves the hook never targets an unrelated PR after a switch. ──
setup_case
run_hook "gh pr create --fill && git switch main" "$(pl_output 'gh pr create --fill && git switch main' "$URL")" GH_PR_NUMBER=600
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "post-create branch switch: no nudge (fail-safe miss, never unrelated)"; else fail "branch-switch: N=$N cmt='$CMT'"; fi

# ── Case 3: FAILED create echoing an existing PR URL → NO post ──
setup_case
run_hook "gh pr create --fill || true" "$(pl_output 'gh pr create --fill || true' "pull request already exists: $URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "failed-create (already exists): no nudge"; else fail "already-exists: N=$N body='$B'"; fi

# ── Case 3b: create reported non-zero exit → NO post ──
setup_case
run_hook "gh pr create --fill" "$(pl_output_ec 'gh pr create --fill' "$URL" 1)"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "failed-create (exit 1): no nudge"; else fail "exit1: N=$N body='$B'"; fi

# ── Case 4: inactive repo → NO post (none stays non-gating) ──
setup_case
printf '%s' "$INACTIVE_JSON" > "$AF"
run_hook "gh pr create --fill" "$(pl_output 'gh pr create --fill' "$URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "inactive repo: no nudge"; else fail "inactive: N=$N body='$B'"; fi

# ── Case 5: kill switch → NO post ──
setup_case
run_hook "gh pr create --fill" "$(pl_output 'gh pr create --fill' "$URL")" PR_GRIND_CODEX_RETRIGGER=0
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "kill switch: no nudge"; else fail "kill-switch: N=$N body='$B'"; fi

# ── Case 6: cross-repo — output names a DIFFERENT repo than the resolved PR → NO post ──
setup_case
run_hook "gh pr create -R otherowner/otherrepo --fill" "$(pl_output 'gh pr create -R otherowner/otherrepo --fill' "https://github.com/otherowner/otherrepo/pull/9")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "cross-repo URL: no nudge (resolved PR not in output keys)"; else fail "cross-repo: N=$N body='$B'"; fi

# ── Case 7: DECOY — a stray same-repo PR URL (999) echoed with the real branch PR
#            URL (515); target is the gh-resolved current branch (515) → nudge 515,
#            decoy 999 ignored (target chosen BEFORE output is consulted) ──
setup_case
run_hook "gh pr create --fill" "$(pl_output 'gh pr create --fill' "https://github.com/$SLUG/pull/999
Created: $URL")"
if [[ "$RC" == 0 && "$N" == 1 && "$CMT" == "$PR" ]]; then ok "decoy URL: nudges gh-resolved branch PR $PR, ignores decoy 999"; else fail "decoy: N=$N cmt='$CMT' body='$B'"; fi

# ── Case 7b: ADVERSARIAL ([high] target-integrity) — gh's output suppressed, a
#            compound prints ONE forged URL of an UNRELATED open PR (888). Target is
#            the gh-resolved current branch (515), whose URL never appears → NO
#            nudge, and the unrelated PR 888 is NEVER commented on ──
setup_case
run_hook "gh pr create --fill 2>/dev/null || printf" "$(pl_output 'gh pr create 2>/dev/null || printf' "https://github.com/$SLUG/pull/888")"
if [[ "$RC" == 0 && "$N" == 0 && -z "$CMT" ]]; then ok "forged unrelated URL: no nudge, unrelated PR untouched"; else fail "forged: N=$N cmt='$CMT'"; fi

# ── Case 8: non-create command → NO post, silent ──
setup_case
run_hook "gh pr view $PR --json state" "$(pl_output "gh pr view $PR --json state" "$URL")"
if [[ "$RC" == 0 && "$N" == 0 && -z "$OUT" ]]; then ok "non-create command: silent, no nudge"; else fail "non-create: N=$N stdout='$OUT'"; fi

# ── Case 9: successful create but NO PR URL in output → NO post ──
setup_case
run_hook "gh pr create --draft" "$(pl_output 'gh pr create --draft' "Creating draft pull request...")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "create without URL in output: no nudge"; else fail "no-url: N=$N body='$B'"; fi

# ── Case 10: the current branch's PR is not OPEN (a failed/again create; PR
#            closed) → NO post (state==OPEN guard) ──
setup_case
run_hook "gh pr create --fill || printf" "$(pl_output 'gh pr create --fill || printf' "$URL")" GH_STATE=CLOSED
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "current-branch PR not OPEN: no nudge (state guard)"; else fail "closed-state: N=$N cmt='$CMT' body='$B'"; fi

# ── Case 11: harness reports a NON-numeric exit code → NO post (fail-closed) ──
setup_case
run_hook "gh pr create --fill" "$(pl_output_ecstr 'gh pr create --fill' "$URL" "abc")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "unparseable exit code: no nudge (fail-closed)"; else fail "unparseable-exit: N=$N body='$B'"; fi

# ── Case 12: JSON bool exit_code (false) → suspect → NO post ──
setup_case
run_hook "gh pr create --fill" "$(pl_output_ec 'gh pr create --fill' "$URL" false)"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "bool exit_code (false): no nudge (suspect)"; else fail "bool-ec: N=$N body='$B'"; fi

# ── Case 13: fractional exit_code (0.5) → suspect → NO post ──
setup_case
run_hook "gh pr create --fill" "$(pl_output_ec 'gh pr create --fill' "$URL" 0.5)"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "fractional exit_code (0.5): no nudge (suspect)"; else fail "float-ec: N=$N body='$B'"; fi

# ── Case 14: ssh://git@github.com origin form → canonicalizes → nudge fires ──
setup_case
( cd "$REPO"; git remote set-url origin "ssh://git@github.com/$SLUG.git" ) >/dev/null 2>&1
run_hook "gh pr create --fill" "$(pl_output 'gh pr create --fill' "$URL")"
if [[ "$RC" == 0 && "$N" == 1 && "$CMT" == "$PR" ]]; then ok "ssh:// origin: nudge fires (canon handles ssh scheme)"; else fail "ssh-origin: N=$N cmt='$CMT'"; fi

# ── Case 15: stacked-scheme origin (ssh://https://github.com/…) → rejected → NO post ──
setup_case
( cd "$REPO"; git remote set-url origin "ssh://https://github.com/$SLUG.git" ) >/dev/null 2>&1
run_hook "gh pr create --fill" "$(pl_output 'gh pr create --fill' "$URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "stacked-scheme origin: no nudge (rejected)"; else fail "stacked-scheme: N=$N cmt='$CMT'"; fi

# ── Case 16: a newline in cwd must NOT shift the JSON-framed PARSE fields. Without
#            framing the second line ("/etc") would bleed into OUT_KEYS and HOOK_CWD
#            would resolve the real repo; with json framing cwd decodes to the full
#            newline-bearing path, which fails to resolve → NO nudge, never a wrong repo ──
setup_case
payload=$(jq -n --arg cwd "$REPO"$'\n'"/etc" --arg cmd 'gh pr create --fill' --arg out "$URL" \
  '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_output:{output:$out}}')
set +e
OUT=$(printf '%s' "$payload" | env PATH="$BIN:$PATH" \
      GH_BODYFILE="$BODY" GH_CMT_PR="$CMTPR" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
      REVIEW_LOGINS="" REACTION_LOGINS="" bash "$HOOK" 2>/dev/null)
RC=$?
set -e
N=$(grep -c '@codex review' "$BODY" 2>/dev/null || true); [[ -n "$N" ]] || N=0
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "newline in cwd: no nudge (json framing prevents field shift)"; else fail "newline-cwd: N=$N"; fi

# ── Case 17: a cwd ending in a TRAILING newline must survive decode (the \x01
#            sentinel stops $(...) from stripping it into a different path) → the
#            full "$REPO\n" fails to resolve → NO nudge, never a different repo ──
setup_case
payload=$(jq -n --arg cwd "$REPO"$'\n' --arg cmd 'gh pr create --fill' --arg out "$URL" \
  '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_output:{output:$out}}')
set +e
OUT=$(printf '%s' "$payload" | env PATH="$BIN:$PATH" \
      GH_BODYFILE="$BODY" GH_CMT_PR="$CMTPR" GH_PR_NUMBER="$PR" GH_SLUG="$SLUG" HEAD_FIXT="$HEAD" ACTIVE_FIXTURE="$AF" \
      REVIEW_LOGINS="" REACTION_LOGINS="" bash "$HOOK" 2>/dev/null)
RC=$?
set -e
N=$(grep -c '@codex review' "$BODY" 2>/dev/null || true); [[ -n "$N" ]] || N=0
# The \x01 sentinel preserves the trailing newline through $(...) (so it is NOT
# silently stripped into a different path); the newline-bearing cwd is then
# rejected outright by the fail-safe guard → NO nudge.
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "trailing-newline cwd: no nudge (preserved by sentinel, then rejected as ambiguous)"; else fail "trailing-newline-cwd: N=$N"; fi

# ── LONE-CREATE integrity gate (issue #473 hardening) ──
# ── Case 18: a command that navigates AFTER the create (`… && cd B`) → NO post ──
setup_case
run_hook "gh pr create --fill && cd /tmp" "$(pl_output 'gh pr create --fill && cd /tmp' "$URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "compound after create (&& cd): no nudge (not lone-create)"; else fail "post-cd: N=$N cmt='$CMT'"; fi

# ── Case 19: a command that re-points origin BEFORE the create → NO post ──
setup_case
run_hook "x" "$(pl_output 'git remote set-url origin https://github.com/e/v && gh pr create --fill' "$URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "re-point origin before create: no nudge (not lone-create)"; else fail "pre-remote: N=$N cmt='$CMT'"; fi

# ── Case 20: a substitution in the create segment → NO post ──
setup_case
# shellcheck disable=SC2016  # the $(id) is LITERAL command text for the payload, not meant to expand
run_hook "x" "$(pl_output 'gh pr create --title "$(id)" --fill' "$URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "substitution in create: no nudge (not lone-create)"; else fail "subst: N=$N cmt='$CMT'"; fi

# ── Case 21: a lone create with a leading `cd <literal>` IS allowed → nudge ──
setup_case
run_hook "x" "$(pl_output "cd $REPO && gh pr create --fill" "$URL")"
if [[ "$RC" == 0 && "$N" == 1 && "$CMT" == "$PR" ]]; then ok "leading cd <literal> && create: nudge (lone-create allows a plain cd prefix)"; else fail "cd-prefix: N=$N cmt='$CMT'"; fi

# ── Case 22: a `bash -c '…'` wrapper hiding a compound (create; re-point; printf)
#            → NO post (the create must be a DIRECT gh invocation, not wrapped) ──
setup_case
run_hook "x" "$(pl_output "bash -c 'gh pr create --fill; git remote set-url origin https://github.com/e/v; printf x'" "$URL")"
if [[ "$RC" == 0 && "$N" == 0 ]]; then ok "bash -c wrapper hiding a compound: no nudge (not a direct gh create)"; else fail "wrapper: N=$N cmt='$CMT'"; fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
