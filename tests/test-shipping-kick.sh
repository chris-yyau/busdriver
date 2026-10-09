#!/usr/bin/env bash
# Tests for scripts/shipping-kick.py (ADR 0055).
#
# The kicker is copied into $TMP/scripts next to a STUB needs-shipping.py that prints the
# classifier line from $FIX/cls and exits with $FIX/cls.rc, so each gate is driven
# directly. A stub `gh` on PATH serves fixtures and logs every call. Part 3 runs the
# template's structural-check commands on a scratch git repo.
#
# Usage: bash tests/test-shipping-kick.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY=/usr/bin/python3
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
t() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/scripts"
cp scripts/shipping-kick.py "$TMP/scripts/"
# Collapse the UNKNOWN re-read delay in the copy only; the retry logic is what is tested.
sed -i.bak 's/^UNKNOWN_RETRIES, UNKNOWN_SLEEP = 3, 10$/UNKNOWN_RETRIES, UNKNOWN_SLEEP = 3, 0/' "$TMP/scripts/shipping-kick.py"
grep -qx 'UNKNOWN_RETRIES, UNKNOWN_SLEEP = 3, 0' "$TMP/scripts/shipping-kick.py" || { echo "FAIL: could not zero UNKNOWN_SLEEP in the test copy"; exit 1; }
cat > "$TMP/scripts/needs-shipping.py" <<'CLS'
import os, sys
fix = os.environ["FIX"]
open(fix + "/cls_args", "w").write(" ".join(sys.argv[1:]))
sys.stdout.write(open(fix + "/cls").read())
sys.exit(int(open(fix + "/cls.rc").read()))
CLS

HEAD=3df45264627e7ff8bf8cacc05a025723929b62d3
TIP=0e1270c5c81c44f7a62f796d7efde58f7eb2d358
OTHER=1111111111111111111111111111111111111111
URL=https://github.com/o/r/pull/42#issuecomment-1

# Stub gh. Fixtures under $FIX: user, comments[2], status (one line per read), headnow,
# repo, prot (full `gh api -i` output), postresp; any <name>.rc sets that call's exit
# code; err is copied to stderr on every call.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FIX/calls"
printf '%s|%s\n' "${GH_HOST:-}" "${GH_REPO:-}" > "$FIX/gh_env"
[ -f "$FIX/err" ] && cat "$FIX/err" >&2
rc_of() { cat "$FIX/$1.rc" 2>/dev/null || echo 0; }
case "$*" in
  "api user") cat "$FIX/user"; exit "$(rc_of user)" ;;
  "api --paginate --jq .[] repos/o/r/issues/42/comments")
    n=$(grep -c '^api --paginate' "$FIX/calls")
    if [ "$n" -gt 1 ] && [ -f "$FIX/comments2" ]; then cat "$FIX/comments2"; exit "$(rc_of comments2)"; fi
    cat "$FIX/comments"; exit "$(rc_of comments)" ;;
  "pr view 42 -R o/r --json mergeStateStatus")
    n=$(grep -c 'json mergeStateStatus$' "$FIX/calls")
    s=$(sed -n "${n}p" "$FIX/status"); [ -n "$s" ] || s=$(tail -1 "$FIX/status")
    printf '{"mergeStateStatus":"%s"}\n' "$s"; exit 0 ;;
  "pr view 42 -R o/r --json headRefOid") printf '{"headRefOid":"%s"}\n' "$(cat "$FIX/headnow")"; exit 0 ;;
  "api repos/o/r") cat "$FIX/repo"; exit 0 ;;
  "api -i repos/o/r/branches/"*"/protection") echo "$3" >> "$FIX/prot_paths"; cat "$FIX/prot"; exit "$(rc_of prot)" ;;
  "api -X POST repos/o/r/issues/42/comments -F body=@-") cat > "$FIX/posted"; cat "$FIX/postresp"; exit "$(rc_of post)" ;;
esac
echo "stub: unexpected gh $*" >&2
exit 99
STUB
chmod +x "$TMP/bin/gh"

P_OK='{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":15368},{"context":"Code security","app_id":15368}]}}'
# prot <json-body> [status-line]: a `gh api -i` response.
prot() { printf '%s\nContent-Type: application/json; charset=utf-8\n\n%s' "${2:-HTTP/2.0 200 OK}" "$1" > "$FIX/prot"; }
# cls: the classifier line; C_STATUS C_REF C_SKILLS C_AC C_FI C_AUTH C_X override fields.
cls() { printf 'shipping mergeStateStatus=%s base_ref=%s base_tip=%s skills=%s agent_config_edited=%s files_incomplete=%s author=%s cross_repo=%s\n' \
  "${C_STATUS:-CLEAN}" "${C_REF:-main}" "$TIP" "${C_SKILLS:-verify-site}" "${C_AC:-0}" "${C_FI:-0}" "${C_AUTH:-op-user}" "${C_X:-0}" > "$FIX/cls"; }
marker() { printf '{"user":{"login":"%s"},"body":"done <!-- busdriver-shipping-kick head=%s --> x","html_url":"%s"}\n' "$1" "$2" "$3"; }

new_case() {
  FIX="$TMP/case$((PASS + FAIL))"; mkdir -p "$FIX"; export FIX; : > "$FIX/calls"
  echo '{"login":"op-user"}' > "$FIX/user"
  cls; echo 10 > "$FIX/cls.rc"
  : > "$FIX/comments"
  echo CLEAN > "$FIX/status"
  echo "$HEAD" > "$FIX/headnow"
  echo '{"private":true}' > "$FIX/repo"
  prot "$P_OK"
  printf '{"html_url":"%s"}\n' "$URL" > "$FIX/postresp"
}

# run_kick: always with a hostile ambient GH_HOST / GH_REPO.
run_kick() {
  out=$(PATH="$TMP/bin:$PATH" GH_HOST=evil.example GH_REPO=x/y "$PY" -I "$TMP/scripts/shipping-kick.py" o/r 42 "$HEAD" 2>/dev/null); rc=$?
}
posted() { grep -q '^api -X POST' "$FIX/calls"; }
single_line_no_body() {
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || return 1
  case "$out" in *"Ship this PR"*|*"busdriver-shipping-kick"*|*"@cursor"*) return 1 ;; esac
}
# check <label> <rc> <exact line|prefix:...> <post attempted 0|1>
check() {
  local ok=1
  run_kick
  [ "$rc" = "$2" ] || ok=0
  case "$3" in prefix:*) [ "${out#"${3#prefix:}"}" != "$out" ] || ok=0 ;; *) [ "$out" = "$3" ] || ok=0 ;; esac
  if [ "$4" = 1 ]; then posted || ok=0; else ! posted || ok=0; fi
  single_line_no_body || ok=0
  [ "$(cat "$FIX/gh_env")" = "github.com|" ] || ok=0
  if [ "$ok" = 1 ]; then pass "$1"; else fail "$1 (rc=$rc out=$out, want rc=$2 out=$3 posted=$4)"; fi
}

echo "── exit 0 ───────────────────────────────────────────────────"
new_case
check "kicks once" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
t "classifier gets repo, PR and head" [ "$(cat "$FIX/cls_args")" = "o/r 42 $HEAD" ]
t "exactly one POST" [ "$(grep -c '^api -X POST' "$FIX/calls")" = 1 ]
BODY="$TMP/body0"; cp "$FIX/posted" "$BODY"

new_case; marker someone "$HEAD" u1 > "$FIX/comments"
check "a non-operator marker is ignored" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
new_case; echo BEHIND > "$FIX/status"
check "BEHIND kicks and reports BEHIND" 0 "kicked: $URL mergeStateStatus=BEHIND" 1
new_case; printf 'UNKNOWN\nCLEAN\n' > "$FIX/status"
check "UNKNOWN then CLEAN kicks" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
new_case; echo '{"login":"Op-User"}' > "$FIX/user"
check "logins compare case-insensitively" 0 "kicked: $URL mergeStateStatus=CLEAN" 1

echo "── exit 4 ───────────────────────────────────────────────────"
new_case; marker op-user "$HEAD" "$URL-9" > "$FIX/comments"
check "operator marker → already kicked" 4 "already kicked: $URL-9" 0
new_case; { for i in $(seq 150); do printf '{"user":{"login":"bot%s"},"body":"hi","html_url":"u%s"}\n' "$i" "$i"; done; marker op-user "$HEAD" "$URL-9"; } > "$FIX/comments"
check "marker after 150 comments (second page)" 4 "already kicked: $URL-9" 0
new_case; marker op-user "$HEAD" "$URL-9" > "$FIX/comments"; C_X=1 cls; echo DIRTY > "$FIX/status"
check "dedupe beats eligibility and status" 4 "already kicked: $URL-9" 0
new_case; marker op-user "$HEAD" "$URL-9" > "$FIX/comments"; C_AC=1 cls
check "marker with agent-config" 4 "already kicked: $URL-9; also: agent-config" 0
new_case; echo 1 > "$FIX/post.rc"; echo '{"message":"boom"}' > "$FIX/postresp"; marker op-user "$HEAD" "$URL-9" > "$FIX/comments2"
check "post fails but the marker landed" 4 "already kicked: $URL-9" 1
new_case; marker op-user "$OTHER" "$URL-9" > "$FIX/comments"
check "a marker for another head does not dedupe" 0 "kicked: $URL mergeStateStatus=CLEAN" 1

echo "── exit 3 ───────────────────────────────────────────────────"
new_case; C_X=1 cls; check "cross-repo alone" 3 "not eligible: cross-repo" 0
new_case; C_AUTH=someone cls; check "author alone" 3 "not eligible: author" 0
new_case; C_AUTH=- cls; check "author - alone" 3 "not eligible: author" 0
new_case; C_FI=1 cls; check "files-incomplete alone" 3 "not eligible: files-incomplete" 0
new_case; C_X=1 C_AC=1 cls; check "cross-repo + agent-config" 3 "not eligible: cross-repo,agent-config" 0
new_case; C_AUTH=someone C_FI=1 C_AC=1 cls; check "author + files-incomplete + agent-config, in order" 3 "not eligible: author,files-incomplete,agent-config" 0
new_case; C_AC=1 cls; check "agent-config alone, every other gate passing" 3 "not eligible: agent-config mergeStateStatus=CLEAN" 0
t "agent-config alone is decided after the protection read" [ -s "$FIX/prot_paths" ]
new_case; C_AC=1 cls; echo BEHIND > "$FIX/status"
check "agent-config alone reports the live status, not the classifier's" 3 "not eligible: agent-config mergeStateStatus=BEHIND" 0

echo "── exit 2 ───────────────────────────────────────────────────"
for s in BLOCKED DIRTY DRAFT; do
  new_case; echo "$s" > "$FIX/status"; check "status $s" 2 "not kicked: mergeStateStatus=$s" 0
  new_case; echo "$s" > "$FIX/status"; C_AC=1 cls; check "status $s + agent-config" 2 "not kicked: mergeStateStatus=$s; also: agent-config" 0
done
new_case; echo UNKNOWN > "$FIX/status"
check "UNKNOWN after 3 re-reads" 2 "not kicked: mergeStateStatus=UNKNOWN" 0
t "UNKNOWN read 4 times" [ "$(grep -c 'json mergeStateStatus$' "$FIX/calls")" = 4 ]

PC="not kicked: protection precondition"
prot_case() { # prot_case <label> <expected condition> <setup command...>
  local label=$1 cond=$2; shift 2
  new_case; "$@"; check "$label" 2 "$PC ($cond)" 0
  new_case; "$@"; C_AC=1 cls; check "$label + agent-config" 2 "$PC ($cond); also: agent-config" 0
}
public() { echo '{"private":false}' > "$FIX/repo"; }
p404() { prot '{"message":"Branch not protected"}' 'HTTP/2.0 404 Not Found'; echo 1 > "$FIX/prot.rc"; }
pj() { prot "$1"; }
prot_case "public repository" "repository is not private" public
prot_case "protection 404" "404: base branch not protected" p404
prot_case "enforce_admins off" "enforce_admins not enabled" pj '{"enforce_admins":{"enabled":false},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":15368}]}}'
prot_case "required_status_checks null" "required_status_checks absent" pj '{"enforce_admins":{"enabled":true},"required_status_checks":null}'
prot_case "strict off" "strict not enabled" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":false,"checks":[{"context":"build","app_id":15368}]}}'
prot_case "empty checks" "no required checks" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[]}}'
prot_case "check with app_id null" "a required check is not pinned to GitHub Actions" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":null}]}}'
prot_case "check pinned to another app" "a required check is not pinned to GitHub Actions" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":1234}]}}'
prot_case "check name with a backtick" "a required check name is unusable" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"bu`ild","app_id":15368}]}}'
prot_case "check name with a comma" "a required check name is unusable" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"test (a, b)","app_id":15368}]}}'
new_case; C_REF=release/1.2 cls; run_kick
t "protection path percent-encodes the slash" grep -qx 'repos/o/r/branches/release%2F1.2/protection' "$FIX/prot_paths"

echo "── exit 5 ───────────────────────────────────────────────────"
new_case; C_SKILLS=- cls; check "skills=-" 5 "not kicked: no usable verify skill name" 0
new_case; C_SKILLS=- C_AC=1 cls; check "skills=- + agent-config" 5 "not kicked: no usable verify skill name; also: agent-config" 0

echo "── exit 6 ───────────────────────────────────────────────────"
new_case; printf 'error: gh api failed\nsecond line\n' > "$FIX/cls"; echo 1 > "$FIX/cls.rc"
check "classifier exit 1 carries its reason" 6 "stale or not shipping-routed (classifier exit 1: gh api failed second line): re-run /pr-grind" 0
new_case; echo merge > "$FIX/cls"; echo 0 > "$FIX/cls.rc"
check "classifier exit 0" 6 "stale or not shipping-routed (classifier exit 0): re-run /pr-grind" 0
new_case; C_REF='a/../b' cls
check "classifier line failing validation" 6 "stale or not shipping-routed (classifier line failed validation): re-run /pr-grind" 0
new_case; C_REF=_release cls
check "leading-underscore base name passes validation" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
new_case; echo "$OTHER" > "$FIX/headnow"
check "head moved before the post" 6 "stale or not shipping-routed (head moved before the post): re-run /pr-grind" 0

echo "── exit 1 ───────────────────────────────────────────────────"
new_case; echo 1 > "$FIX/user.rc"; printf 'line one\nline two\n' > "$FIX/err"
check "gh api user fails (multi-line stderr stays one line)" 1 "prefix:error: " 0
new_case; echo 1 > "$FIX/comments.rc"; check "comment listing fails" 1 "prefix:error: " 0
new_case; echo 'not json' > "$FIX/comments"; check "unparseable comment listing" 1 "prefix:error: " 0
new_case; prot '{"message":"boom"}' 'HTTP/2.0 500 Internal Server Error'; echo 1 > "$FIX/prot.rc"
check "protection read fails (500)" 1 "prefix:error: " 0
new_case; echo 1 > "$FIX/post.rc"; : > "$FIX/postresp"; echo 1 > "$FIX/comments2.rc"; : > "$FIX/comments2"
check "post fails and the re-read fails" 1 "error: delivery unknown; check PR #42 before posting anything" 1
out=$("$PY" -I "$TMP/scripts/shipping-kick.py" o/r 42 abc 2>/dev/null); rc=$?
t "bad arguments → error, exit 1" [ "$rc" = 1 ]

echo "── exit 7 ───────────────────────────────────────────────────"
new_case; echo 1 > "$FIX/post.rc"; : > "$FIX/postresp"
check "post fails, marker not found" 7 "prefix:post failed: " 1
t "exit 7 line ends with the re-run instruction" [ "${out%; re-run /pr-grind}" != "$out" ]

echo "── comment body ─────────────────────────────────────────────"
b() { grep -qF -- "$1" "$BODY"; }
for frag in \
  "@cursor Ship this PR with pstack Shipping (poteto-mode playbooks/shipping.md)." \
  "First read \`gh pr view 42 -R o/r --json headRefOid\`; if the head is not $HEAD" \
  "Require \`git --version\` to report 2.38 or newer" \
  "git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main $TIP $HEAD" \
  "git fetch --unshallow origin" \
  "Verify with EVERY skill listed: /verify-site." \
  "git show $TIP:<path>" \
  "one line naming the skill, the commit it was loaded from, M and $HEAD" \
  "baseRefName main and state OPEN" \
  "git merge-base --is-ancestor origin/main $HEAD" \
  "gh api -X PUT repos/o/r/pulls/42/update-branch -f expected_head_sha=$HEAD" \
  "\`git rev-parse H^1\` equals $HEAD" \
  "\`git merge-base --is-ancestor H^2 origin/main\` succeeds" \
  "\`git rev-list --parents -n 1 H\` prints H followed by exactly two parent SHAs" \
  "\`git rev-parse H^{tree}\` equals \`git merge-tree --write-tree $HEAD H^2\`" \
  "The required checks are: build, Code security." \
  "decide from the listed buckets, not the exit code" \
  "\"no required checks reported\"" \
  "First, a \`fail\` or \`cancel\` bucket" \
  "a required check missing from the list, or a \`pending\` bucket means wait" \
  "gh pr merge 42 -R o/r --squash --delete-branch --match-head-commit H" \
  "the kicked head $HEAD, H," \
  "Never repeat the marker line below, and never write \`@cursor\`"; do
  t "body has: $frag" b "$frag"
done
t "body ends with the marker" [ "$(tail -1 "$BODY")" = "<!-- busdriver-shipping-kick head=$HEAD -->" ]
t "body has no patch-id" bash -c '! grep -q patch-id "$1"' _ "$BODY"
t "gh pr update-branch appears once, as 'never'" [ "$(grep -o 'gh pr update-branch' "$BODY" | wc -l | tr -d ' ')" = 1 ]
t "...and that occurrence is the 'never' phrase" b "never \`gh pr update-branch\`"
for ph in '<N>' '<owner/repo>' '<SHA>' '<base_tip>' '<base_ref>' '%('; do
  t "no unfilled placeholder $ph" bash -c '! grep -qF -- "$1" "$2"' _ "$ph" "$BODY"
done
new_case; C_SKILLS=verify-a,verify-b cls; run_kick
t "every skill is listed" grep -qF "Verify with EVERY skill listed: /verify-a, /verify-b." "$FIX/posted"

echo "── structural check (template commands, scratch repo) ───────"
G="$TMP/git"; git init -q "$G"
gx() { git -C "$G" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
mk() { echo "$1" > "$G/$1"; gx add "$1"; gx commit -q -m "$1"; gx rev-parse HEAD; }
B0=$(mk a)
gx checkout -q -b side "$B0"; S=$(mk s)
gx checkout -q -b head "$B0"; SHA=$(mk h)
gx checkout -q -b mainline "$B0"; B1=$(mk b)
gx update-ref refs/remotes/origin/main "$B1"
merge_of() { gx checkout -q --detach "$1"; shift; gx merge -q --no-ff --no-edit "$@" >/dev/null; gx rev-parse HEAD; }
GOOD=$(merge_of "$SHA" "$B1")
EXTRA=$(gx checkout -q --detach "$GOOD"; echo x > "$G/extra"; gx add extra; gx commit -q --amend --no-edit; gx rev-parse HEAD)
BADP1=$(merge_of "$B1" "$SHA")
OCTO=$(merge_of "$SHA" "$B1" "$S")
NOTBASE=$(merge_of "$SHA" "$S")
# structural <H> <SHA>: the template's four checks, verbatim.
structural() {
  (cd "$G" && H=$1 && SHA=$2 &&
    [ "$(git rev-parse "$H^1")" = "$SHA" ] &&
    git merge-base --is-ancestor "$H^2" origin/main &&
    [ "$(git rev-list --parents -n 1 "$H" | wc -w | tr -d ' ')" = 3 ] &&
    [ "$(git rev-parse "$H^{tree}")" = "$(git merge-tree --write-tree "$SHA" "$H^2")" ])
}
nparents() { gx rev-list --parents -n 1 "$1" | awk '{print NF - 1}'; }
t "fixture GOOD has 2 parents" [ "$(nparents "$GOOD")" = 2 ]
t "fixture OCTO has 3 parents" [ "$(nparents "$OCTO")" = 3 ]
t "fixture EXTRA keeps GOOD's parents" [ "$(gx rev-parse "$EXTRA^@" | tr '\n' ' ')" = "$(gx rev-parse "$GOOD^@" | tr '\n' ' ')" ]
t "fixture BADP1 has first parent B1" [ "$(gx rev-parse "$BADP1^1")" = "$B1" ]
t "fixture NOTBASE has second parent S" [ "$(gx rev-parse "$NOTBASE^2")" = "$S" ]
t "accepts a real --no-ff merge of head and base" structural "$GOOD" "$SHA"
rejects() { if structural "$1" "$SHA"; then return 1; fi; }
t "rejects a merge whose tree carries an extra edit" rejects "$EXTRA"
t "rejects a merge whose first parent is not the head" rejects "$BADP1"
t "rejects a three-parent merge" rejects "$OCTO"
t "rejects a merge whose second parent is not on the base" rejects "$NOTBASE"
t "ancestry: behind head is not up to date" bash -c '! git -C "$1" merge-base --is-ancestor origin/main "$2"' _ "$G" "$SHA"
t "ancestry: a head containing the base tip is up to date" git -C "$G" merge-base --is-ancestor origin/main "$GOOD"

echo
echo "shipping-kick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
