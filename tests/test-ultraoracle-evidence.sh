#!/usr/bin/env bash
# tests/test-ultraoracle-evidence.sh
#
# Verifies skills/ultraoracle/scripts/build-evidence-pack.sh — ADR 0007 Phase 1/2.
# The script decides the Oracle review-type LABEL from what was actually attached,
# so the security-critical behaviors are: (1) summary-only packs stay
# ORACLE_SUMMARY_REVIEW and are never upgraded (ADR settling check #2); (2)
# secret-like files are excluded with no override — including via the generated git
# diff (no unfiltered-diff transmission path); (3) the byte budget is honored;
# (4) retrieval-loop (Phase 5) is rejected so nothing can claim ORACLE_RETRIEVAL_REVIEW.
#
# Needs a real git repo (the script reads HEAD/status/diff), so each run builds a
# throwaway repo under a temp dir and runs the script with CWD inside it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/ultraoracle/scripts/build-evidence-pack.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[[ -f "$SCRIPT" ]] || { fail "build-evidence-pack.sh missing at $SCRIPT"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q
git config user.email t@t.t; git config user.name t
echo "real source" > app.sh
echo "SECRET" > .env
echo "key" > deploy.pem
git add -A 2>/dev/null || true
git commit -qm init 2>/dev/null || true
echo "question text" > q.txt

run() { ( cd "$TMP" && bash "$SCRIPT" "$@" ); }

# Test 1: no raw files attached => ORACLE_SUMMARY_REVIEW (not upgraded).
out="$(run --mode repo --out-dir "$TMP/p1" --question-file "$TMP/q.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]]; then ok "summary-only stays SUMMARY"; else fail "t1 expected SUMMARY got '$out'"; fi

# Test 2: a real repo file attached => ORACLE_REPO_ATTACHED_REVIEW.
out="$(run --mode repo --out-dir "$TMP/p2" --question-file "$TMP/q.txt" --file "$TMP/app.sh" | tail -n1)"
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]]; then ok "raw file => REPO_ATTACHED"; else fail "t2 expected REPO_ATTACHED got '$out'"; fi

# Test 3: secret-like files excluded — not copied, manifest records exclusion,
#         and with ONLY secrets requested the label must NOT upgrade.
out="$(run --mode repo --out-dir "$TMP/p3" --question-file "$TMP/q.txt" \
        --file "$TMP/.env" --file "$TMP/deploy.pem" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] \
   && ! ls "$TMP/p3/files/"* >/dev/null 2>&1 \
   && grep -q "secret_excluded" "$TMP/p3/manifest.txt"; then
  ok "secret-like files excluded, label not upgraded"
else
  fail "t3 secrets leaked or label upgraded (got '$out')"
fi

# Test 4: byte budget skips an oversized file (stays SUMMARY since nothing attaches).
head -c 5000 /dev/zero | tr '\0' 'x' > "$TMP/big.txt"
out="$(run --mode repo --out-dir "$TMP/p4" --question-file "$TMP/q.txt" \
        --byte-budget 100 --file "$TMP/big.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "budget_skipped" "$TMP/p4/manifest.txt"; then
  ok "over-budget file skipped"
else
  fail "t4 budget not enforced (got '$out')"
fi

# Test 5: retrieval-loop rejected (Phase 5), non-zero, no label on stdout.
set +e
rl_out="$(run --mode retrieval-loop --out-dir "$TMP/p5" 2>/dev/null)"; rl_rc=$?
set -e
if [[ "$rl_rc" -ne 0 && -z "$rl_out" ]]; then
  ok "retrieval-loop rejected, no label emitted"
else
  fail "t5 retrieval-loop not rejected (rc=$rl_rc out='$rl_out')"
fi

# Test 6: manifest carries the auditable fields.
if grep -q "^run_id: " "$TMP/p2/manifest.txt" \
   && grep -q "^git_sha: " "$TMP/p2/manifest.txt" \
   && grep -q "^label: " "$TMP/p2/manifest.txt"; then
  ok "manifest records run_id/git_sha/label"
else
  fail "t6 manifest missing audit fields"
fi

# Test 7: a secret in a TRACKED file's working-tree diff must not ride out via
#         git-diff.txt — the generated git context is gated too (HIGH #1).
( cd "$TMP" && printf 'token = "sk-ant-api03-%s"\n' "$(printf 'A%.0s' {1..40})" >> app.sh )
run --mode repo --out-dir "$TMP/p7" --question-file "$TMP/q.txt" >/dev/null
if [[ ! -f "$TMP/p7/git-diff.txt" ]] && grep -q "git_diff (generated)" "$TMP/p7/manifest.txt"; then
  ok "secret in git diff excluded (no unfiltered-diff path)"
else
  fail "t7 git-diff.txt with secret was not excluded"
fi
( cd "$TMP" && git checkout -q -- app.sh )

# Test 8: namespaced key formats are caught (regex breadth — HIGH #2).
printf 'k=sk-proj-%s\n' "$(printf 'B%.0s' {1..30})" > "$TMP/cfg.txt"
out="$(run --mode repo --out-dir "$TMP/p8" --question-file "$TMP/q.txt" --file "$TMP/cfg.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "secret_excluded: .*cfg.txt" "$TMP/p8/manifest.txt"; then
  ok "sk-proj- key file excluded"
else
  fail "t8 namespaced key not caught (got '$out')"
fi

# Test 9: a --file outside the repo is rejected (path containment), label stays SUMMARY.
OUTSIDE="$(mktemp)"; echo "external content" > "$OUTSIDE"
out="$(run --mode repo --out-dir "$TMP/p9" --question-file "$TMP/q.txt" --file "$OUTSIDE" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "path_excluded" "$TMP/p9/manifest.txt"; then
  ok "out-of-repo --file rejected"
else
  fail "t9 out-of-repo file attached (got '$out')"
fi
rm -f "$OUTSIDE"

# Test 10: a secret AFTER 64KB of padding is still caught (whole-file scan).
{ head -c 70000 /dev/zero | tr '\0' 'x'; printf '\nAKIA%s\n' "$(printf 'C%.0s' {1..16})"; } > "$TMP/late.txt"
out="$(run --mode repo --out-dir "$TMP/p10" --question-file "$TMP/q.txt" --file "$TMP/late.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "secret_excluded: .*late.txt" "$TMP/p10/manifest.txt"; then
  ok "secret past 64KB caught"
else
  fail "t10 late secret slipped through (got '$out')"
fi

# Test 11: --out-dir outside the repo is rejected (write-boundary) AND emits no label.
OUTDIR="$(mktemp -d)"
set +e
out="$( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$OUTDIR/pack" --question-file "$TMP/q.txt" 2>/dev/null )"; rc=$?
set -e
if [[ "$rc" -ne 0 && -z "$out" ]]; then ok "out-of-repo --out-dir rejected, no label"; else fail "t11 out-dir rc=$rc out='$out'"; fi
rm -rf "$OUTDIR"

# Test 12: a trailing value-flag with no argument fails closed (no set -u crash).
set +e
( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$TMP/p12" --file >/dev/null 2>&1 ); rc=$?
set -e
if [[ "$rc" -eq 2 ]]; then ok "trailing --file fails closed (usage)"; else fail "t12 trailing --file rc=$rc (expected 2)"; fi

# Test 13: a repo-local symlink pointing outside the repo is rejected (no cp-through).
EXT="$(mktemp)"; echo "external secretless content" > "$EXT"
( cd "$TMP" && ln -sf "$EXT" leak.txt )
out="$(run --mode repo --out-dir "$TMP/p13" --question-file "$TMP/q.txt" --file "$TMP/leak.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "path_excluded" "$TMP/p13/manifest.txt"; then
  ok "repo-local symlink to outside rejected"
else
  fail "t13 symlink escape attached (got '$out')"
fi
rm -f "$EXT" "$TMP/leak.txt"

# Test 14: a rejected out-of-repo --out-dir leaves nothing behind.
OUTDIR2="$(mktemp -d)"
set +e
( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$OUTDIR2/pack" --question-file "$TMP/q.txt" >/dev/null 2>&1 )
set -e
if [[ ! -e "$OUTDIR2/pack" ]]; then ok "rejected out-dir leaves nothing behind"; else fail "t14 out-dir created outside repo"; fi
rm -rf "$OUTDIR2"

# Test 15: a tracked secret-NAMED file's change is excluded from git-diff.txt by
#          pathspec, even when its value matches no token regex (HIGH boundary).
( cd "$TMP" && echo "plainvalue" > app.token && git add app.token && git commit -qm tok \
   && echo "changed-secret" >> app.token && echo "ordinary change" >> app.sh )
run --mode repo --out-dir "$TMP/p15" --question-file "$TMP/q.txt" >/dev/null
if grep -q "app.sh" "$TMP/p15/git-diff.txt" 2>/dev/null \
   && ! grep -q "app.token" "$TMP/p15/git-diff.txt" 2>/dev/null; then
  ok "secret-named file excluded from git diff"
else
  fail "t15 secret-named file leaked into git diff"
fi
( cd "$TMP" && git checkout -q -- app.sh app.token )

# Test 16: upstream-audit inventories a git work tree (indexed/sanitized name) and
#          skips a non-repo dir.
NOREPO="$(mktemp -d)"
run --mode upstream-audit --out-dir "$TMP/p16" --question-file "$TMP/q.txt" \
    --upstream "$TMP" --upstream "$NOREPO" >/dev/null
if ls "$TMP/p16"/upstream-1_*.txt >/dev/null 2>&1 \
   && ! ls "$TMP/p16"/upstream-2_*.txt >/dev/null 2>&1 \
   && grep -q "upstream_inventory" "$TMP/p16/manifest.txt"; then
  ok "upstream git repo inventoried, non-repo skipped"
else
  fail "t16 upstream-audit inventory wrong"
fi
rm -rf "$NOREPO"

# Test 17: a secret-like path NAME is stripped from git-status.txt metadata.
( cd "$TMP" && echo "x" > .env.local && echo "status change" >> app.sh )
run --mode repo --out-dir "$TMP/p17" --question-file "$TMP/q.txt" >/dev/null
if grep -q "app.sh" "$TMP/p17/git-status.txt" 2>/dev/null \
   && ! grep -q ".env.local" "$TMP/p17/git-status.txt" 2>/dev/null; then
  ok "secret-like path name stripped from git status"
else
  fail "t17 secret path name leaked into git status"
fi
( cd "$TMP" && rm -f .env.local && git checkout -q -- app.sh )

# Test 18: a safe leaf under a SECRET-NAMED directory is excluded (path-component check).
mkdir -p "$TMP/secrets"
echo "harmless looking" > "$TMP/secrets/config.yml"
out="$(run --mode repo --out-dir "$TMP/p18" --question-file "$TMP/q.txt" --file "$TMP/secrets/config.yml" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] && grep -q "secret_excluded: .*secrets/config.yml" "$TMP/p18/manifest.txt"; then
  ok "file under secret-named dir excluded"
else
  fail "t18 secret-named dir not caught (got '$out')"
fi

# Test 19: a --question-file larger than the byte budget fails closed.
head -c 5000 /dev/zero | tr '\0' 'q' > "$TMP/bigq.txt"
set +e
out="$( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$TMP/p19" --question-file "$TMP/bigq.txt" --byte-budget 100 2>/dev/null )"; rc=$?
set -e
if [[ "$rc" -eq 4 && -z "$out" ]]; then ok "oversized question-file fails closed, no label"; else fail "t19 budget rc=$rc out='$out'"; fi

# Test 20: STAGED changes are captured in git-diff.txt (git diff HEAD, not bare git diff).
( cd "$TMP" && echo "staged line" >> app.sh && git add app.sh )
run --mode repo --out-dir "$TMP/p20" --question-file "$TMP/q.txt" >/dev/null
if grep -q "staged line" "$TMP/p20/git-diff.txt" 2>/dev/null; then
  ok "staged changes captured in diff"
else
  fail "t20 staged change missing from diff"
fi
( cd "$TMP" && git checkout -q -- app.sh 2>/dev/null; git reset -q HEAD app.sh 2>/dev/null; git checkout -q -- app.sh 2>/dev/null )

# Test 21: a repo CHECKED OUT under a secret-named ancestor dir does NOT false-exclude
#          its files (is_secret_like must only check the repo-relative portion).
mkdir -p "$TMP/token-ws"
( cd "$TMP/token-ws" && git init -q && git config user.email t@t.t && git config user.name t \
   && echo "real" > normal.sh && git add -A && git commit -qm i )
echo "q" > "$TMP/token-ws/q.txt"
out="$( cd "$TMP/token-ws" && bash "$SCRIPT" --mode repo --out-dir "$TMP/token-ws/p" \
        --question-file "$TMP/token-ws/q.txt" --file "$TMP/token-ws/normal.sh" | tail -n1 )"
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]]; then
  ok "file under secret-named ANCESTOR not false-excluded"
else
  fail "t21 ancestor false-positive (got '$out')"
fi

# Test 22: a pre-existing --out-dir is rejected (defends against planted child symlinks
#          in an untrusted checkout that could redirect writes outside the repo).
mkdir -p "$TMP/p22exists"
set +e
out="$( cd "$TMP" && bash "$SCRIPT" --mode repo --out-dir "$TMP/p22exists" --question-file "$TMP/q.txt" 2>/dev/null )"; rc=$?
set -e
if [[ "$rc" -eq 4 && -z "$out" ]]; then ok "pre-existing out-dir rejected, no label"; else fail "t22 rc=$rc out='$out'"; fi

# Test 23: a quoted/space secret-named path is stripped from git-status.txt.
( cd "$TMP" && echo "x" > "my secret.txt" && echo "status23" >> app.sh )
run --mode repo --out-dir "$TMP/p23" --question-file "$TMP/q.txt" >/dev/null
if grep -q "app.sh" "$TMP/p23/git-status.txt" 2>/dev/null \
   && ! grep -qi "secret" "$TMP/p23/git-status.txt" 2>/dev/null; then
  ok "quoted secret path stripped from git status"
else
  fail "t23 quoted secret path leaked"
fi
( cd "$TMP" && rm -f "my secret.txt"; git checkout -q -- app.sh )

# Test 24: a rename from a secret path to a NON-secret path leaks NEITHER the old path
#          NOR the file CONTENT (both rename halves excluded — cubic P1).
( cd "$TMP" && mkdir -p secrets && echo "MARKER24SECRETBODY" > secrets/old.txt && git add secrets/old.txt \
   && git commit -qm s && git mv secrets/old.txt visible24.txt )
run --mode repo --out-dir "$TMP/p24" --question-file "$TMP/q.txt" >/dev/null
if ! grep -q "secrets/old.txt" "$TMP/p24/git-diff.txt" 2>/dev/null \
   && ! grep -q "visible24.txt" "$TMP/p24/git-diff.txt" 2>/dev/null \
   && ! grep -q "MARKER24SECRETBODY" "$TMP/p24/git-diff.txt" 2>/dev/null; then
  ok "secret rename: both endpoints and content excluded from diff"
else
  fail "t24 secret rename leaked an endpoint or content into diff"
fi
( cd "$TMP" && git checkout -q -- . 2>/dev/null; git reset -q --hard HEAD >/dev/null 2>&1 )

# Test 25: attached file names are REPO-RELATIVE (no absolute checkout path leaked).
run --mode repo --out-dir "$TMP/p25" --question-file "$TMP/q.txt" --file "$TMP/app.sh" >/dev/null
leak25=0; have25=0
for f in "$TMP/p25/files/"*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in *_app.sh) have25=1;; esac
  case "${f##*/}" in *private*|*Volumes*|*Users*|*tmp*) leak25=1;; esac
done
if [ "$have25" -eq 1 ] && [ "$leak25" -eq 0 ]; then
  ok "attachment name is repo-relative"
else
  fail "t25 absolute path leaked (have=$have25 leak=$leak25)"
fi

# Test 26: upstream inventory strips a secret-named tracked file.
( cd "$TMP" && echo "k" > api.token && git add api.token && git commit -qm tok2 )
run --mode upstream-audit --out-dir "$TMP/p26" --question-file "$TMP/q.txt" --upstream "$TMP" >/dev/null
INV=""; for f in "$TMP/p26"/upstream-1_*.txt; do [ -f "$f" ] && { INV="$f"; break; }; done
if [ -n "$INV" ] && grep -q "app.sh" "$INV" && ! grep -q "api.token" "$INV"; then
  ok "upstream inventory strips secret-named file"
else
  fail "t26 upstream secret strip failed (inv=$INV)"
fi
( cd "$TMP" && git rm -q api.token >/dev/null 2>&1 && git commit -qm rmtok >/dev/null 2>&1 )

# Test 27: case-variant secret names (API_TOKEN, Cookies.txt) are excluded.
echo "k1" > "$TMP/API_TOKEN"; echo "k2" > "$TMP/Cookies.txt"
out="$(run --mode repo --out-dir "$TMP/p27" --question-file "$TMP/q.txt" \
        --file "$TMP/API_TOKEN" --file "$TMP/Cookies.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]] \
   && ! ls "$TMP/p27/files/"* >/dev/null 2>&1 \
   && grep -q "secret_excluded: .*API_TOKEN" "$TMP/p27/manifest.txt" \
   && grep -q "secret_excluded: .*Cookies.txt" "$TMP/p27/manifest.txt"; then
  ok "case-variant secret names excluded"
else
  fail "t27 case-variant secret not caught (got '$out')"
fi
rm -f "$TMP/API_TOKEN" "$TMP/Cookies.txt"

# Test 28: secret-context key basenames excluded, ordinary "key" names NOT over-excluded.
echo "k" > "$TMP/API_KEY"; echo "k" > "$TMP/api-key.json"; echo "k" > "$TMP/private_key.json"
echo "code" > "$TMP/keyboard.sh"
out="$(run --mode repo --out-dir "$TMP/p28" --question-file "$TMP/q.txt" \
        --file "$TMP/API_KEY" --file "$TMP/api-key.json" --file "$TMP/private_key.json" \
        --file "$TMP/keyboard.sh" | tail -n1)"
have_kbd=0; for f in "$TMP/p28/files/"*; do case "${f##*/}" in *keyboard.sh) have_kbd=1;; esac; done
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]] && [ "$have_kbd" -eq 1 ] \
   && grep -q "secret_excluded: .*API_KEY" "$TMP/p28/manifest.txt" \
   && grep -q "secret_excluded: .*api-key.json" "$TMP/p28/manifest.txt" \
   && grep -q "secret_excluded: .*private_key.json" "$TMP/p28/manifest.txt"; then
  ok "secret-context key names excluded, keyboard.sh kept (no over-match)"
else
  fail "t28 key-name handling wrong (got '$out' have_kbd=$have_kbd)"
fi
rm -f "$TMP/API_KEY" "$TMP/api-key.json" "$TMP/private_key.json" "$TMP/keyboard.sh"

# Test 29: ordinary "key"-containing names are NOT over-excluded (cubic overmatch guard).
echo "a" > "$TMP/schema-foreign-key.sql"; echo "b" > "$TMP/primary_key_index.sql"; echo "c" > "$TMP/keys.json"
out="$(run --mode repo --out-dir "$TMP/p29" --question-file "$TMP/q.txt" \
        --file "$TMP/schema-foreign-key.sql" --file "$TMP/primary_key_index.sql" --file "$TMP/keys.json" | tail -n1)"
n29=0; for f in "$TMP/p29/files/"*; do [ -e "$f" ] && n29=$((n29+1)); done
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]] && [ "$n29" -eq 3 ]; then
  ok "foreign-key/primary_key/keys.json not over-excluded"
else
  fail "t29 ordinary key names over-excluded (n=$n29 out='$out')"
fi
rm -f "$TMP/schema-foreign-key.sql" "$TMP/primary_key_index.sql" "$TMP/keys.json"

# Test 30: upstream inventory filename uses the BASENAME, not the absolute path.
run --mode upstream-audit --out-dir "$TMP/p30" --question-file "$TMP/q.txt" --upstream "$TMP" >/dev/null
leak30=0
for f in "$TMP/p30"/upstream-*.txt; do
  [ -e "$f" ] || continue
  case "${f##*/}" in *private*|*Volumes*|*Users*|*folders*) leak30=1;; esac
done
if [ "$leak30" -eq 0 ]; then ok "upstream inv filename is basename-only"; else fail "t30 absolute path in inv filename"; fi

# Test 31: the pack dir itself is excluded from git-status.txt (no self-listing when
#          the state dir is not gitignored).
run --mode repo --out-dir "$TMP/p31" --question-file "$TMP/q.txt" >/dev/null
if ! grep -q "p31/" "$TMP/p31/git-status.txt" 2>/dev/null; then
  ok "pack dir excluded from git status"
else
  fail "t31 pack dir self-listed in git status"
fi

# Test 32: camelCase key names + .netrc credential file are excluded.
echo "k" > "$TMP/apiKey.ts"; echo "k" > "$TMP/accessKey"; echo "k" > "$TMP/.netrc"
echo "code" > "$TMP/monkey.js"
out="$(run --mode repo --out-dir "$TMP/p32" --question-file "$TMP/q.txt" \
        --file "$TMP/apiKey.ts" --file "$TMP/accessKey" --file "$TMP/.netrc" --file "$TMP/monkey.js" | tail -n1)"
have_monkey=0; for f in "$TMP/p32/files/"*; do case "${f##*/}" in *monkey.js) have_monkey=1;; esac; done
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]] && [ "$have_monkey" -eq 1 ] \
   && grep -q "secret_excluded: .*apiKey.ts" "$TMP/p32/manifest.txt" \
   && grep -q "secret_excluded: .*accessKey" "$TMP/p32/manifest.txt" \
   && grep -q "secret_excluded: .*.netrc" "$TMP/p32/manifest.txt"; then
  ok "camelCase keys + .netrc excluded, monkey.js kept"
else
  fail "t32 camelCase/.netrc handling wrong (got '$out' monkey=$have_monkey)"
fi
rm -f "$TMP/apiKey.ts" "$TMP/accessKey" "$TMP/.netrc" "$TMP/monkey.js"

# Test 33: a verbatim COPY of an (unmodified) secret-pathed file to a safe name keeps
#          the secret content out of git-diff.txt (--find-copies-harder).
( cd "$TMP" && mkdir -p sdir && echo "COPYMARKER33" > sdir/secret.env && git add sdir/secret.env \
   && git commit -qm se && cp sdir/secret.env copied33.txt && git add copied33.txt )
run --mode repo --out-dir "$TMP/p33" --question-file "$TMP/q.txt" >/dev/null
if ! grep -q "COPYMARKER33" "$TMP/p33/git-diff.txt" 2>/dev/null \
   && ! grep -q "copied33.txt" "$TMP/p33/git-diff.txt" 2>/dev/null; then
  ok "copy of secret file: content excluded from diff"
else
  fail "t33 secret copy leaked content/path into diff"
fi
( cd "$TMP" && git reset -q --hard HEAD >/dev/null 2>&1; git rm -q -r --cached sdir >/dev/null 2>&1; rm -rf sdir copied33.txt; git commit -qm cleanup33 >/dev/null 2>&1 || true )

# Test 34: a tracked working-tree change (real diff) with NO --file makes the consult
#          ORACLE_REPO_ATTACHED_REVIEW — a git-diff carries raw repo source, not a summary.
( cd "$TMP" && echo "diff34 change" >> app.sh )
out="$(run --mode repo --out-dir "$TMP/p34" --question-file "$TMP/q.txt" | tail -n1)"
if [[ "$out" == "ORACLE_REPO_ATTACHED_REVIEW" ]] && [ -s "$TMP/p34/git-diff.txt" ] \
   && grep -q "^attached_file_count: 0" "$TMP/p34/manifest.txt" \
   && grep -q "^diff_evidence: 1" "$TMP/p34/manifest.txt"; then
  ok "git-diff alone => REPO_ATTACHED, manifest records diff_evidence=1 with 0 files"
else
  fail "t34 diff-only consult mislabeled or manifest inconsistent (got '$out')"
fi
( cd "$TMP" && git checkout -q -- app.sh )

# Test 35: a CLEAN worktree with no --file stays ORACLE_SUMMARY_REVIEW (no repo artifacts).
( cd "$TMP" && git checkout -q -- . 2>/dev/null; git reset -q --hard HEAD >/dev/null 2>&1 )
out="$(run --mode repo --out-dir "$TMP/p35" --question-file "$TMP/q.txt" | tail -n1)"
if [[ "$out" == "ORACLE_SUMMARY_REVIEW" ]]; then
  ok "clean worktree, no files => SUMMARY"
else
  fail "t35 clean consult mislabeled (got '$out')"
fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
