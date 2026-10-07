#!/usr/bin/env bash
# tests/test-890-push-destination-units.sh — unit tables for #890 (design
# docs/plans/2026-10-01-issue-890-explicit-push-destination.md):
#   - scripts/lib/push-dest-id.sh: transport grammar, endpoint identity, display
#     identity, PR tuple, tip wrapper, raw push-URL record reader
#   - scripts/pr-head-identity.sh: accept / reject shapes (fixture JSON, never gh)
#   - scripts/lib/push-failure-classify.sh: arms, winning evidence, redaction, cap
# No network: the reader rows use temp repos and only `git remote get-url`.
#
# shellcheck disable=SC2329,SC2317,SC2016  # test_* and helpers are invoked dynamically;
# single-quoted snippets run in child shells on purpose
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib"
IDENTITY="$REPO_ROOT/scripts/pr-head-identity.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
# Fixture repos must not inherit a caller's repository or injected config.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS
for _v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_' || true); do unset "$_v"; done
unset _v
export GIT_CONFIG_COUNT=0

SANDBOX_ROOT=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

# shellcheck source=/dev/null
. "$LIB/push-dest-id.sh" || { echo "FAIL: cannot source push-dest-id.sh"; exit 1; }
# shellcheck source=/dev/null
. "$LIB/push-failure-classify.sh" || { echo "FAIL: cannot source push-failure-classify.sh"; exit 1; }

BAD=0
ck() {   # ck <label> <command...> — records a failure instead of returning early
    local label=$1; shift
    if ! "$@"; then echo "  mismatch: $label"; BAD=1; fi
}
eq() { [ "$1" = "$2" ] || { printf '    got [%s] want [%s]\n' "$1" "$2"; return 1; }; }
not() { ! "$@" >/dev/null; }
has() { case $1 in *"$2"*) return 0 ;; esac; printf '    [%.200s] lacks [%s]\n' "$1" "$2"; return 1; }

test_transport_grammar() {
    local u
    for u in 'user:secret@h:o/r' 'git@h:o/r@x' 'ssh://user:secret@h/o/r' \
             'https://x-access-token:T@h/o/r' 'https://h/o/r?t=1' 'git@h:o/r#x' \
             'git://h/o/r' 'http://h/o/r' 'file:///srv/r.git' '/srv/r.git' '' \
             'https://h/o r' 'ssh://@h/o/r' 'https://h:44x/o/r' 'https://[::1]/o/r'; do
        ck "refuse $u" not _bd890_transport_cred_ok "$u"
    done
    for u in 'git@h:o/r' 'h:o/r' 'ssh://git@h/o/r' 'ssh://h:22/o/r' 'https://h/o/r'; do
        ck "allow $u" _bd890_transport_cred_ok "$u"
    done
}

test_endpoint_identity() {
    local a b
    id() { _bd890_endpoint_identity "$1" || echo FAIL; }
    while IFS='|' read -r a b; do
        ck "$a == $b" eq "$(id "$a")" "$(id "$b")"
        ck "$a resolves" not eq "$(id "$a")" FAIL
    done <<'ROWS'
https://h/o/r/|https://h/o/r
https://h/o/r|https://h/o/r.git/
https://h:443/o/r|https://h/o/r
ssh://git@h:22/o/r|git@h:o/r
https://h/o/r|git@h:o/r.git
https://H/O/R|git@h:o/r
ROWS
    ck "wiki path" eq "$(id https://h/o/r/wiki/)" FAIL
    ck "8443 != 443" not eq "$(id https://h:443/o/r)" "$(id https://h:8443/o/r)"
    for a in 'git@h:o/r#x' 'ssh://git@h/o/r#x' 'user:secret@h:o/r' 'https://h/o' 'https://h//'; do
        ck "refused $a" eq "$(id "$a")" FAIL
    done
    ck "matches PR" _bd890_endpoint_matches_pr 'ssh://git@github.com/Bd890-Fixture/repo.git' github.com/bd890-fixture/repo
    ck "https alias matches" _bd890_endpoint_matches_pr 'https://github.com/bd890-fixture/repo' github.com/bd890-fixture/repo
    ck "8443 never matches" not _bd890_endpoint_matches_pr 'https://github.com:8443/bd890-fixture/repo' github.com/bd890-fixture/repo
    ck "ssh :2222 never matches" not _bd890_endpoint_matches_pr 'ssh://git@github.com:2222/bd890-fixture/repo' github.com/bd890-fixture/repo
    ck "path origin never matches" not _bd890_endpoint_matches_pr "$SANDBOX_ROOT/remote.git" github.com/bd890-fixture/repo
    ck "other owner" not _bd890_endpoint_matches_pr 'git@github.com:evil/repo.git' github.com/bd890-fixture/repo
    ck "empty tuple" not _bd890_endpoint_matches_pr 'git@github.com:evil/repo.git' ''
}

test_display_identity() {
    local a b out glob_ok
    while IFS='|' read -r a b; do
        out=$(_bd890_dest_id "$a") || out=NZ
        ck "dest_id $a" eq "$out" "$b"
        if [ "$out" != NZ ]; then
            glob_ok=1
            case $out in *'?'*|*'#'*|*://*@*|*'@'*':'*|*':'*'@'*) glob_ok=0 ;; esac
            ck "glob $out" eq "$glob_ok" 1
        fi
    done <<'ROWS'
https://github.com/o/r.git/|github.com/o/r
https://github.com:8443/o/r|github.com:8443/o/r
ssh://git@github.com:22/o/r.git|github.com:22/o/r
git@github.com:o/r.git|github.com:o/r
https://x-access-token:T@github.com/o/r.git/|NZ
https://u:p@ss@h/x|NZ
https://h/o/r?token=T#f|NZ
https://github.com/o/r?x@y|NZ
https://user:SECRET?x@github.com/o/r.git|NZ
https://user:SECRET#x@github.com/o/r|NZ
https://u:p@github.com?x/o/r|NZ
https://u:SE/CRET@h/o|NZ
https://user:SECRET/foo?x@github.com/o/r.git|NZ
https://user:SECRET|NZ
user:secret@github.com:o/r|NZ
x-access-token:T@github.com/o/r.git|NZ
git@github.com:|NZ
|NZ
ROWS
}

test_pr_identity_from_env() {
    local out
    out=$(PR_HEAD_HOST=GitHub.com PR_HEAD_OWNER=Org PR_HEAD_NAME=Repo.git _bd890_pr_identity_from_env) || out=NZ
    ck "lowercase + .git" eq "$out" github.com/org/repo
    local h o n
    while IFS='|' read -r h o n; do
        ck "reject $h|$o|$n" not env PR_HEAD_HOST="$h" PR_HEAD_OWNER="$o" PR_HEAD_NAME="$n" \
            bash -c '. "$1"; _bd890_pr_identity_from_env' bash "$LIB/push-dest-id.sh"
    done <<'ROWS'
|o|r
h||r
h|o|
h:443|o|r
h|o/x|r
h|o|a%2Fb
h|o|a b
h|o+x|r
<PR_HEAD_HOST — literal from pr-head-identity.sh stdout>|o|r
h|o|.git
ROWS
}

test_tip_wrapper() {
    local fake="$SANDBOX_ROOT/no-k-timeout"
    printf '#!/bin/sh\ncase "$1" in -k) exit 125 ;; esac\nexit 0\n' >"$fake"
    chmod +x "$fake"
    _tip_wrap=(stale)
    ck "no -k wrapper → skip" not _bd890_select_tip_wrapper "$fake"
    ck "array emptied" eq "${#_tip_wrap[@]}" 0
    ck "absent → skip" not _bd890_select_tip_wrapper /nonexistent/timeout
    if _bd890_select_tip_wrapper; then
        ck "wrapper shape" eq "${_tip_wrap[*]:1}" "-k 2 10"
        # A SIGTERM-ignoring child returns within the limit (short durations here).
        local start end rc=0
        start=$(date +%s)
        ( "${_tip_wrap[0]}" -k 1 1 bash -c 'trap "" TERM; sleep 30' ) >/dev/null 2>&1 || rc=$?
        end=$(date +%s)
        # 137 = KILLed after the ignored TERM; it must have run (>=1s) and been
        # stopped (<=6s) — a wrapper that fails at once satisfies neither.
        ck "SIGTERM-ignoring child killed" eq "$rc" 137
        ck "SIGTERM-ignoring child ran" test $((end - start)) -ge 1
        ck "SIGTERM-ignoring child bounded" test $((end - start)) -le 6
    else
        echo "  note: no -k timeout on this host; ran-branch rows skipped"
    fi
}

# Raw-record reader: each shape runs with errexit off and on.
reader_row() {   # reader_row <label> <want_rc> <want_url> <repo-setup...>
    local label=$1 want_rc=$2 want_url=$3 repo mode out
    shift 3
    # Fail closed: an empty $repo would make `cd ""` a no-op and run the setup —
    # git config writes included — in the caller's repository.
    repo=$(mktemp -d "$SANDBOX_ROOT/reader.XXXXXX") && [ -n "$repo" ] && [ -d "$repo" ] \
        || { ck "$label: fixture dir" false; return 0; }
    git -C "$repo" init -q || { ck "$label: git init" false; return 0; }
    (cd "$repo" && "$@") >/dev/null 2>&1 || { ck "$label: fixture setup" false; return 0; }
    for mode in +e -e; do
        out=$(cd "$repo" && bash -c '
            set '"$mode"'
            . "$1"
            _rd=0; _bd890_read_one_push_url || _rd=$?
            printf "%s|%s|%s" "$_rd" "$_BD890_ONE_URL" "$_BD890_GIT_RC"
        ' bash "$LIB/push-dest-id.sh")
        ck "$label ($mode) rc" eq "${out%%|*}" "$want_rc"
        out=${out#*|}
        ck "$label ($mode) url" eq "${out%%|*}" "$want_url"
        if [ "$want_rc" = 1 ]; then
            local direct=0
            (cd "$repo" && git remote get-url --push --all origin) >/dev/null 2>&1 || direct=$?
            ck "$label git rc carried" eq "${out#*|}" "$direct"
        else
            ck "$label git rc 0" eq "${out#*|}" 0
        fi
    done
}

test_reader_table() {
    reader_row "one url" 0 'ssh://git@github.com/o/r.git' git remote add origin 'ssh://git@github.com/o/r.git'
    reader_row "two pushurls" 2 '' sh -c 'git remote add origin u0 && git config --add remote.origin.pushurl u1 && git config --add remote.origin.pushurl u2'
    reader_row "two urls" 2 '' sh -c 'git remote add origin u1 && git config --add remote.origin.url u2'
    reader_row "empty pushurl beside valid" 2 '' sh -c 'git remote add origin u0 && git config --add remote.origin.pushurl u1 && git config --add remote.origin.pushurl ""'
    reader_row "trailing space" 2 '' sh -c 'git remote add origin u0 && git config remote.origin.pushurl "u1 "'
    reader_row "leading space" 2 '' sh -c 'git remote add origin u0 && git config remote.origin.pushurl " u1"'
    reader_row "CR" 2 '' sh -c 'git remote add origin u0 && git config remote.origin.pushurl "$(printf "u1\r")"'
    reader_row "tab" 2 '' sh -c 'git remote add origin u0 && git config remote.origin.pushurl "$(printf "u1\tX")"'
    reader_row "no origin" 1 '' true
    # Pure parse rows (no Git).
    local raw rc
    rc=0; _bd890_one_record $'u\n' || rc=$?
    ck "pure one" eq "$rc:$_BD890_ONE_URL" "0:u"
    for raw in $'u1\nu2\n' $'u\n\n' $'\nu\n' $'u \n' $' u\n' $'u\r\n' $'u\tX\n' '' 'u' $'\n' $'u\n\nu2\n'; do
        rc=0; _bd890_one_record "$raw" || rc=$?
        ck "pure refuse $(printf %q "$raw")" eq "$rc:$_BD890_ONE_URL" "2:"
    done
}

IDENTITY_META='{"url":"https://github.com/Bd890-Fixture/Repo/pull/7","isCrossRepository":false,"headRepositoryOwner":{"login":"bd890-fixture"},"headRepository":{"name":"repo"},"baseRefName":"main","headRefName":"fix","headRefOid":"0123456789abcdef0123456789abcdef01234567"}'

identity() {   # identity <json> <args...> → stdout; rc in IDENTITY_RC
    local meta=$1; shift
    IDENTITY_RC=0
    IDENTITY_OUT=$(printf '%s' "$meta" | bash "$IDENTITY" "$@" 2>"$SANDBOX_ROOT/identity.err") || IDENTITY_RC=$?
}

test_pr_head_identity() {
    local want=$'PR_HEAD_HOST=github.com\nPR_HEAD_OWNER=bd890-fixture\nPR_HEAD_NAME=repo'
    identity "$IDENTITY_META" --pr-number 7
    ck "number-only accept" eq "$IDENTITY_RC:$IDENTITY_OUT" "0:$want"
    identity "$IDENTITY_META" --pr-number 7 --invocation-url 'https://github.com/bd890-fixture/repo/pull/7'
    ck "url accept" eq "$IDENTITY_RC:$IDENTITY_OUT" "0:$want"
    identity "$IDENTITY_META" --pr-number 7 --invocation-url 'https://github.com/BD890-fixture/Repo/pull/7/'
    ck "mixed-case + slash accept" eq "$IDENTITY_RC:$IDENTITY_OUT" "0:$want"

    local iu
    for iu in 'https://github.com/bd890-fixture/repo/pull/7/files' \
              'https://github.com/bd890-fixture/repo/pull/7?w=1' \
              'https://github.com/bd890-fixture/repo/pull/7//' \
              'https://github.com/bd890-fixture/repo/extra/pull/7' \
              'https://github.com/bd890-fixture/repo.git/pull/7' \
              'https://github.com/bd890-fixture/other/pull/7' \
              'https://github.com/bd890-fixture/repo/pull/8' \
              'https://github.com:443/bd890-fixture/repo/pull/7' \
              'http://github.com/bd890-fixture/repo/pull/7' \
              'https://gitlab.com/bd890-fixture/repo/pull/7' \
              "https://github.com/bd890-fixture/re'po/pull/7"; do
        identity "$IDENTITY_META" --pr-number 7 --invocation-url "$iu"
        ck "reject invocation $iu" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    done

    local m
    for m in '"isCrossRepository":true' '"isCrossRepository":"false"' '"isCrossRepository":null' '"isCrossRepositoryX":false'; do
        identity "${IDENTITY_META/\"isCrossRepository\":false/$m}" --pr-number 7
        ck "reject fork flag $m" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    done
    identity "$IDENTITY_META" --pr-number 8
    ck "reject number mismatch" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    identity "${IDENTITY_META/\"login\":\"bd890-fixture\"/\"login\":\"evil\"}" --pr-number 7
    ck "reject owner mismatch" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    identity "${IDENTITY_META/\"name\":\"repo\"/\"name\":\"other\"}" --pr-number 7
    ck "reject name mismatch" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    identity "${IDENTITY_META/Repo\/pull/re%2Fpo\/pull}" --pr-number 7
    ck "reject charset" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    identity 'not json' --pr-number 7
    ck "reject non-json" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    identity "$IDENTITY_META" --pr-number 07
    ck "reject leading zero" eq "$IDENTITY_RC:$IDENTITY_OUT" "1:"
    ck "one stderr line" eq "$(wc -l <"$SANDBOX_ROOT/identity.err" | tr -d ' ')" 1
}

classify() {   # classify <lines...> → PUSH_* set
    push_failure_classify "$(printf '%s\n' "$@")"
}

test_classifier_arms() {
    classify ' ! [rejected]        main -> main (fetch first)' "error: failed to push some refs to 'x'"
    ck "history fetch first" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push non-fast-forward; local commit preserved"
    ck "history keeps parenthetical" has "$PUSH_DIAG" "(fetch first)"
    classify ' ! [remote rejected] main -> main (non-fast-forward)'
    ck "history-class remote rejected" eq "$PUSH_BAIL_CATEGORY" judgment
    ck "history prefix" eq "$PUSH_BAIL_PREFIX" "git push non-fast-forward; local commit preserved"
    classify "fatal: Authentication failed for 'https://github.com/o/r.git/'" ' ! [rejected] main -> main (fetch first)'
    ck "history beats auth" eq "$PUSH_BAIL_PREFIX" "git push non-fast-forward; local commit preserved"
    # The history parenthetical is git's final one, not text inside a hook's reason.
    classify ' ! [remote rejected] main -> main (policy says (fetch first) requires approval)'
    ck "inner (fetch first) is a hook" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push rejected; local commit preserved"
    # The reason must be exactly git's own, whole, right after <dst>: refs hold no
    # whitespace, so any other text there is the server's.
    classify ' ! [remote rejected] main -> main (policy says) (fetch first)'
    ck "trailing (fetch first) after server text is a hook" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push rejected; local commit preserved"
    classify ' ! [remote rejected] abc123 -> main (policy mentions (remote failed to report status))'
    ck "quoted unknown reason is a hook" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push rejected; local commit preserved"

    local phrase
    for phrase in "fatal: unable to access 'https://h/o/r/': The requested URL returned error: 403" \
                  "fatal: unable to access 'https://h/o/r/': The requested URL returned error: 502" \
                  'fatal: unable to access x: Failed to connect to h port 443' \
                  'ssh: connect to host h port 22: Connection refused' \
                  'ssh: connect to host h port 22: Connection timed out' \
                  'fatal: unable to access x: Operation timed out' \
                  'fatal: the remote end hung up unexpectedly' \
                  'fatal: unable to access x: Recv failure: Connection reset by peer' \
                  "fatal: Authentication failed for 'https://h/o/r/'" \
                  'git@github.com: Permission denied (publickey).' \
                  "fatal: 'missing' does not appear to be a git repository" \
                  'fatal: Could not read from remote repository.' \
                  'fatal: unable to access x: Could not resolve host: h' \
                  'fatal: The current branch x has no upstream branch.' \
                  'remote: Permission to o/r.git denied to u.' \
                  'remote: Write access to repository not granted.' \
                  'remote: Repository not found.'; do
        classify "$phrase"
        ck "env: $phrase" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "env|git push auth/network/config"
    done
}

test_classifier_hook_guards() {
    local prose
    for prose in 'remote: Connection refused' 'remote: Recv failure' 'remote: Authentication failed' \
                 'remote: remote failed to report status' 'remote: policy says (fetch first)' \
                 'remote: Permission to owner/repo.git denied' 'remote: deploy timeout on network'; do
        classify "$prose" ' ! [remote rejected] main -> main (pre-receive hook declined)'
        ck "hook guard: $prose" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push rejected; local commit preserved"
    done
    classify " ! [remote rejected] refs/heads/main -> refs/heads/main (cannot lock ref 'refs/heads/main': is at x)" 'remote: Connection refused'
    ck "cannot lock ref" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push rejected; local commit preserved"
    ck "cannot lock ref keeps the label only" eq "$PUSH_DIAG" '! [remote rejected] refs/heads/main -> refs/heads/main (cannot lock ref)'
    classify 'remote: error: hook declined to update refs/heads/main'
    ck "remote-prose hook" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push rejected; local commit preserved"
    classify 'remote: GH006 test-hook network timeout' ' ! [remote rejected] feature/network-timeout -> feature/network-timeout (pre-receive hook declined)'
    ck "network in hook text" eq "$PUSH_BAIL_PREFIX" "git push rejected; local commit preserved"
    classify 'remote: Connection refused'
    ck "remote prose alone is not env" eq "$PUSH_BAIL_CATEGORY|$PUSH_BAIL_PREFIX" "judgment|git push failed; local commit preserved"
}

test_classifier_unknown_outcome() {
    local want='git push outcome unknown — compare remote tip of full_ref to NEW_COMMIT_SHA before any push/reset; do not auto-retry; see skills/pr-grind/SKILL.md section Push bail recovery'
    classify ' ! [remote failure]   main -> main (remote failed to report status)'
    ck "unknown category" eq "$PUSH_BAIL_CATEGORY" env
    ck "unknown exact prefix" eq "$PUSH_BAIL_PREFIX" "$want"
    ck "unknown keeps parenthetical" has "$PUSH_DIAG" '(remote failed to report status)'
    classify 'fatal: the remote end hung up unexpectedly' ' ! [remote failure]   main -> main (remote failed to report status)'
    ck "hung-up + remote failure → unknown" eq "$PUSH_BAIL_PREFIX" "$want"
    classify 'remote: remote failed to report status'
    ck "prose never unknown" not eq "$PUSH_BAIL_PREFIX" "$want"
}

test_classifier_pipefail_and_cap() {
    local out rc big payload
    # Drain-safe arm checks: early token plus >64KB trailing payload.
    payload=$(head -c 70000 /dev/zero | tr '\0' 'a')
    out=$(bash -c '
        set -euo pipefail
        . "$1"
        push_failure_classify "$(printf "%s\n%s\n" " ! [rejected] main -> main (fetch first)" "remote: $2")"
        printf "%s|%s" "$PUSH_BAIL_CATEGORY" "$(printf "%s" "$PUSH_DIAG" | wc -c | tr -d " ")"
    ' bash "$LIB/push-failure-classify.sh" "$payload" 2>&1) && rc=0 || rc=$?
    ck "drain-safe rc" eq "$rc" 0
    ck "drain-safe arm" eq "${out%%|*}" judgment
    ck "drain-safe cap" test "${out#*|}" -le 1500

    # Zero-match / multi-match under errexit+pipefail.
    out=$(bash -c 'set -euo pipefail; . "$1"; push_failure_classify "error: failed to push some refs"; printf "%s|%s" "$PUSH_BAIL_CATEGORY" "$PUSH_DIAG"' \
        bash "$LIB/push-failure-classify.sh" 2>&1) && rc=0 || rc=$?
    ck "zero-match rc" eq "$rc" 0
    ck "zero-match default" eq "$out" "judgment|no git status row (push output withheld)"
    out=$(bash -c 'set -euo pipefail; . "$1"; push_failure_classify "$(printf "fatal: a\nfatal: b\nremote: x\nremote: y\nremote: z\n")"; printf ok' \
        bash "$LIB/push-failure-classify.sh" 2>&1) && rc=0 || rc=$?
    ck "multi-match survives" eq "$rc:$out" "0:ok"

    # ~200KB remote: line with the winning status LAST.
    big="remote: $(head -c 200000 /dev/zero | tr '\0' 'x') tail"
    classify "$big" ' ! [remote rejected] main -> main (pre-receive hook declined)'
    ck "200KB: marker kept" has "$PUSH_DIAG" '[remote rejected]'
    ck "200KB: reason kept" has "$PUSH_DIAG" '(pre-receive hook declined)'
    ck "200KB: capped" test "$(printf '%s' "$PUSH_DIAG" | wc -c)" -le 1500

    # Long refname: marker and parenthetical survive the middle shortening.
    local ref
    ref="refs/heads/$(head -c 3000 /dev/zero | tr '\0' 'r')"
    classify " ! [rejected] $ref -> $ref (fetch first)"
    ck "long ref: marker" has "$PUSH_DIAG" '[rejected]'
    ck "long ref: parenthetical" has "$PUSH_DIAG" '(fetch first)'
    ck "long ref: truncation mark" has "$PUSH_DIAG" '…[truncated]'
    ck "long ref: capped" test "$(printf '%s' "$PUSH_DIAG" | wc -c)" -le 1500

    # Parenthetical alone larger than the budget → marker + faithful prefix + mark.
    local words
    words=$(printf 'déclinée %.0s' $(seq 1 400))
    classify " ! [remote rejected] main -> main (pre-receive hook declined: $words)"
    ck "huge reason: marker" has "$PUSH_DIAG" '[remote rejected]'
    ck "huge reason: withheld" eq "$PUSH_DIAG" '! [remote rejected] main -> main (reason withheld)'
    ck "huge reason: capped" test "$(printf '%s' "$PUSH_DIAG" | wc -c)" -le 1500
    ck "huge reason: valid UTF-8" eq "$(printf '%s' "$PUSH_DIAG" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo ok)" ok

    # Single line: one JSON string with no raw newline.
    classify 'remote: a' 'remote: b' ' ! [remote rejected] main -> main (hook declined)'
    ck "flattened" eq "$(printf '%s' "$PUSH_DIAG" | wc -l | tr -d ' ')" 0
}

no_secret() { case $PUSH_DIAG in *BD890SYNTHTOKEN*|*x-access-token*|*"pa'"*) return 1 ;; esac; }
NO_ROW='no git status row (push output withheld)'
HOOK_WITHHELD='remote hook declined (hook text withheld; see the push output)'

# The diagnostic is an allowlist: git's own client status row, or the matched env
# phrase, or fixed text. Free text (fatal:/error: prose, remote: lines) is never
# copied, so a credential split across tokens or lines has nothing to leak through.
test_classifier_allowlist() {
    classify "fatal: unable to access 'https://x-access-token:BD890SYNTHTOKEN@github.com/o/r.git/': The requested URL returned error: 403"
    ck "403 env" eq "$PUSH_BAIL_CATEGORY" env
    ck "403 diag is the phrase" eq "$PUSH_DIAG" 'returned error: 403'
    local tok
    for tok in "https://u:pa'BD890SYNTHTOKEN@h/o/r.git" "https://h/o/r?token=pa'BD890SYNTHTOKEN"; do
        classify "fatal: unable to access '$tok': The requested URL returned error: 403"
        ck "wrapped apostrophe phrase" eq "$PUSH_DIAG" 'returned error: 403'
    done
    classify 'git@github.com: Permission denied (publickey).'
    ck "OpenSSH phrase" eq "$PUSH_DIAG" 'Permission denied (publickey)'
    classify 'fatal: Permission to https://u:BD890SYNTHTOKEN@h/o/r denied to u.'
    ck "permission phrase is fixed" eq "$PUSH_DIAG" 'Permission to (repository) denied'
    classify 'remote: Permission to https://user:BD890SYNTHTOKEN BD890SYNTHTOKEN denied' 'BD890SYNTHTOKEN@host/o/r'
    ck "split permission phrase" no_secret

    classify ' ! [remote rejected] main -> main (pre-receive hook declined)' \
        'remote: see https://u:BD890SYNTHTOKEN@h/x?token=BD890SYNTHTOKEN' 'remote: hello world'
    ck "hook row only" eq "$PUSH_DIAG" '! [remote rejected] main -> main (pre-receive hook declined)'
    # The status reason is server text: only git's own reasons are kept.
    classify ' ! [remote rejected] main -> main (policy https://user:BD890SYNTHTOKEN BD890SYNTHTOKEN rejected)' 'BD890SYNTHTOKEN@h/o/r'
    ck "server reason withheld" eq "$PUSH_DIAG" '! [remote rejected] main -> main (reason withheld)'
    classify ' ! [rejected]        main -> main (fetch first)'
    ck "history row normalized" eq "$PUSH_DIAG" '! [rejected] main -> main (fetch first)'
    classify 'remote: error: hook declined to update refs/heads/main BD890SYNTHTOKEN'
    ck "remote-prose hook is fixed text" eq "$PUSH_DIAG" "$HOOK_WITHHELD"
    classify 'error: failed to push some refs'
    ck "no status row is fixed text" eq "$PUSH_DIAG" "$NO_ROW"
    classify ' ! [rejected] https://u:BD890SYNTHTOKEN@h/x -> main (fetch first)'
    ck "status row is redacted" eq "$PUSH_DIAG" '! [rejected] [redacted-url] -> main (fetch first)'

    # Every probe that leaked through free text in an earlier revision.
    local digits; digits=$(printf '%01800d' 0)
    for tok in 'https://u:BD890SYNTHTOKEN@h/x' 'https://h/x?token=BD890SYNTHTOKEN' \
               'BD890SYNTHTOKEN@h.example:path' 'https://u:BD890SYNTHTOKEN/foo?x@github.com/o/r.git' \
               'https://u:BD890SYNTHTOKEN BD890SYNTHTOKEN BD890SYNTHTOKEN@h/o/r' \
               'https://alice:443/BD890SYNTHTOKEN SECOND@github.com:o/r.git' \
               "'https://user:$digits BD890SYNTHTOKEN SECOND@github.com/o/r.git'"; do
        classify "error: push to $tok failed"
        ck "error prose: $tok" no_secret
        classify "remote: see $tok" ' ! [remote rejected] main -> main (hook declined)'
        ck "remote prose: $tok" no_secret
    done
    classify "fatal: Authentication failed for 'https://user:BD890SYNTHTOKEN" 'remote: BD890SYNTHTOKEN' "remote: LAST@github.com/o/r.git'"
    ck "multiline auth" no_secret
    ck "multiline auth phrase" eq "$PUSH_DIAG" 'Authentication failed'
    classify 'remote: https://user:START' 'remote: BD890SYNTHTOKEN' 'remote: END@github.com/o/r.git'
    ck "multiline remote, no row" no_secret
    classify 'remote: https://user:START' 'remote: BD890SYNTHTOKEN' 'remote: END@github.com/o/r.git' 'error: failed to push some refs'
    ck "multiline remote, error line" no_secret
}

# Token and span redaction, applied to the status row and the env phrase.
redact() { PUSH_DIAG=$(_pfc_redact_line "$(_pfc_bound_line "$1" 1300)"); }

test_redact_line() {
    local tok
    for tok in 'https://u:BD890SYNTHTOKEN@h/x' 'https://h/x?token=BD890SYNTHTOKEN' 'https://h/x#BD890SYNTHTOKEN' \
               'BD890SYNTHTOKEN@h.example:path' 'x-access-token:BD890SYNTHTOKEN@github.com/o/r.git' \
               'https://u:pa,ssBD890SYNTHTOKEN@h/x' 'https://h/x?token=a,b;BD890SYNTHTOKEN' \
               '(https://u:BD890SYNTHTOKEN@h/x)' "https://u:pa'BD890SYNTHTOKEN@h/o/r.git" \
               "https://h/o/r?token=pa'BD890SYNTHTOKEN" "'https://h/x?t=a'BD890SYNTHTOKEN" \
               "'https://h/o/r'):BD890SYNTHTOKEN" "'https://u:BD890SYNTHTOKEN@h/o/r" \
               'https://u:BD890SYNTHTOKEN?x@github.com/o/r.git' 'https://u:BD890SYNTHTOKEN#x@h/o/r' \
               'https://u:BD890SYNTHTOKEN/foo?x@github.com/o/r.git' \
               'https://u:BD890SYNTHTOKEN BD890SYNTHTOKEN@github.com/o/r.git' \
               "'https://u:BD890SYNTHTOKEN BD890SYNTHTOKEN@github.com/o/r.git'"; do
        redact "error: push to $tok failed"
        ck "redact $tok" no_secret
    done
    redact 'error: x-access-token:BD890SYNTHTOKEN@github.com/o/r.git'
    ck "scheme-less → [redacted-url]" eq "$PUSH_DIAG" 'error: [redacted-url]'
    redact "error: 'https://h/x?t=a'BD890SYNTHTOKEN"
    ck "wrapper tail → [redacted-url]" eq "$PUSH_DIAG" 'error: [redacted-url]'
    redact "error: 'https://h/o/r',"
    ck "allowlisted wrapper kept" eq "$PUSH_DIAG" "error: 'h/o/r',"
    # Two URL-shaped tokens are one span, even when each fragment is a clean
    # transport on its own: whitespace can split one credential URL into two.
    redact "error: 'https://h/o/r', \"https://h/o/r\")"
    ck "two URLs → one span" eq "$PUSH_DIAG" 'error: [redacted-url]'
    redact 'fatal: https://alice:443/BD890SYNTHTOKEN SECOND@github.com:o/r.git'
    ck "two clean fragments secret" no_secret
    redact "error: 'https://h/o/r"
    ck "unbalanced quote → [redacted-url]" eq "$PUSH_DIAG" 'error: [redacted-url]'
    redact 'git@github.com: Permission denied (publickey).'
    # Strict display: a token the transport grammar rejects is withheld whole.
    ck "OpenSSH prefix withheld" eq "$PUSH_DIAG" '[redacted-url] Permission denied (publickey).'
    redact 'error: see git@github.com:o/r.git'
    ck "scp dest-id kept" eq "$PUSH_DIAG" 'error: see github.com:o/r'
    redact "fatal: unable to access 'https://github.com/o/r.git?access_token=FIRST@BD890SYNTHTOKEN': denied"
    ck "query @ secret" no_secret
    redact "fatal: unable to access 'https://user:BD890SYNTHTOKEN BD890SYNTHTOKEN BD890SYNTHTOKEN@github.com/o/r.git': denied"
    ck "quoted interior shape" eq "$PUSH_DIAG" 'fatal: unable to access [redacted-url] denied'
    redact 'error: push to https://u:BD890SYNTHTOKEN BD890SYNTHTOKEN BD890SYNTHTOKEN@h/o/r failed'
    ck "unquoted interior shape" eq "$PUSH_DIAG" 'error: push to [redacted-url] failed'
    # The bound drops whole tokens BEFORE redaction; when it drops the first
    # URL-shaped fragment, its marker must still open the span.
    local digits; digits=$(printf '%01800d' 0)
    redact "fatal: unable to access 'https://user:$digits BD890SYNTHTOKEN SECOND@github.com/o/r.git': failed"
    ck "bounded interior secret" no_secret
}

test_classifier_redaction_fail_closed() {
    # Without the dest-id helper, URL-shaped tokens are withheld, never copied.
    local out
    out=$(bash -c '
        . "$1"
        unset -f _bd890_dest_id
        push_failure_build_diag " ! [rejected] https://u:BD890SYNTHTOKEN@h/x -> main (fetch first)" history
        printf "%s" "$PUSH_DIAG"
    ' bash "$LIB/push-failure-classify.sh")
    ck "no helper → withheld" eq "$out" '! [rejected] [redacted-url] -> main (fetch first)'
}

failed=0
discovered=0
for t in $(declare -F | awk '/ test_/{print $3}' | sort); do
    discovered=$((discovered + 1))
    BAD=0
    if "$t" && [ "$BAD" -eq 0 ]; then
        echo "PASS: $t"
    else
        echo "FAIL: $t"
        failed=1
    fi
done
[ "$discovered" -gt 0 ] || { echo "FAIL: test discovery produced ZERO tests"; exit 1; }
exit "$failed"
