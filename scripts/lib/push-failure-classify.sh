#!/usr/bin/env bash
# scripts/lib/push-failure-classify.sh — classify git-push stderr for dispatcher Step 11 (#890).
# Sourced by dispatcher-commit-block.sh and unit tests. Do not execute directly.
#
# This library owns the diagnostic end to end: arm → winning evidence → redaction →
# UTF-8-safe byte cap. The dispatcher only appends its trusted trailer.
#
# Sets (caller-visible):
#   PUSH_DIAG          — bounded, redacted, single-line diagnostic for the bail reason
#   PUSH_BAIL_CATEGORY — env | judgment
#   PUSH_BAIL_PREFIX   — short reason prefix (without trailing diagnostic)
# shellcheck disable=SC2034 # the three outputs above are read by the caller

# Redaction needs _bd890_dest_id. SCRIPT_LIB first (the dispatcher's own lib dir),
# else this file's directory, so it works standalone and from a test copy.
if ! declare -F _bd890_dest_id >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "${SCRIPT_LIB:-$(dirname "${BASH_SOURCE[0]}")}/push-dest-id.sh" 2>/dev/null || true
fi

_PFC_MAX_DIAG=1500
_PFC_TRUNC='…[truncated]'
_PFC_TRUNC_URL='…[truncated-url]'
_PFC_NO_ROW='no git status row (push output withheld)'
_PFC_HOOK_WITHHELD='remote hook declined (hook text withheld; see the push output)'

# Client status rows. `^remote:` prose never matches these.
# Row shape is "! [status] <src> -> <dst> (<reason>)" and ref names hold no
# whitespace, so the reason is everything after <dst>. It must be exactly git's own:
# text a hook puts there — "(policy says) (fetch first)" — is never evidence.
_PFC_HISTORY_RE='^[[:space:]]*! \[(rejected|remote rejected)\][[:space:]]+[^[:space:]]+ -> [^[:space:]]+ \((non-fast-forward|fetch first)\)[[:space:]]*$'
_PFC_UNKNOWN_RE='^[[:space:]]*! (\[remote failure\]|\[[^]]*\][[:space:]]+[^[:space:]]+ -> [^[:space:]]+ \(remote failed to report status\)[[:space:]]*$)'
_PFC_REMOTE_REJECTED_RE='^[[:space:]]*! \[remote rejected\]'
_PFC_CLIENT_ROW_RE='^[[:space:]]*! \['
# Phrase-level env (closed list). Matched only on client lines (not remote:/hint:).
_PFC_ENV_CLIENT_RE='returned error: (401|403|50[0234])|Permission to .+ denied|Write access to repository not granted|Connection timed out|Operation timed out|Failed to connect|Connection refused|the remote end hung up unexpectedly|Connection reset by peer|Recv failure|Authentication failed|Permission denied \(publickey\)|does not appear to be a git repository|Could not read from remote|Could not resolve host|no upstream branch'
# Retained remote permission phrases: count on remote: lines too, but only because
# no client remote-rejected row matched (that arm is tested first).
_PFC_ENV_REMOTE_RE='Permission to .+ denied|Write access to repository not granted|Repository not found'
_PFC_REMOTE_HOOK_RE='^remote:.*hook declined'

_PFC_UNKNOWN_PREFIX='git push outcome unknown — compare remote tip of full_ref to NEW_COMMIT_SHA before any push/reset; do not auto-retry; see skills/pr-grind/SKILL.md section Push bail recovery'

_pfc_bytes() {
    printf '%s' "$1" | wc -c | tr -d ' '
}

# UTF-8-safe byte prefix: cut, then drop any partial sequence (same repair as the
# dispatcher's Litmus findings bound).
_pfc_utf8_prefix() {
    local cut
    cut=$(printf '%s' "$1" | LC_ALL=C head -c "$2") || true
    if command -v iconv >/dev/null 2>&1; then
        printf '%s' "$cut" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
    else
        printf '%s' "$cut" | LC_ALL=C tr -d '\200-\377' || true
    fi
}

# Bound one line by dropping WHOLE whitespace-delimited tokens from its middle, so
# the front (marker) and the back (decisive parenthetical) survive and no token —
# a URL in particular — is ever cut in half before redaction.
_pfc_bound_line() {
    printf '%s\n' "$1" | LC_ALL=C awk -v L="$2" -v T=" $_PFC_TRUNC " -v TU=" $_PFC_TRUNC_URL " '
        length($0) <= L { print; next }
        {
            n = split($0, t, /[ \t\v\f\r]+/)
            front = ""; i = 1
            while (i <= n && length(front) + length(t[i]) + 1 <= L / 2) {
                front = front (front == "" ? "" : " ") t[i]; i++
            }
            back = ""; j = n
            while (j >= i && length(back) + length(t[j]) + 1 <= L / 2) {
                back = t[j] (back == "" ? "" : " ") back; j--
            }
            # A dropped URL-shaped token marks the gap, so the span rule in
            # _pfc_redact_line still opens where that token used to be.
            m = T
            for (k = i; k <= j; k++) if (t[k] ~ /:\/\/|@/) { m = TU; break }
            print front m back
        }' || true
}

# Redaction of one token → _PFC_TOK. Delimiter is whitespace only; see the design's
# token grammar (URL shape, quote-wrapper allowlist, _bd890_dest_id backstop).
_pfc_redact_token() {
    local tok=$1 q lead="" trail="" cand inner last id
    _PFC_TOK=$tok
    # Every '@' token is a candidate, not only URL/scp shapes: whitespace splitting
    # can leave a password fragment such as "SECOND@host/o/r" that matches neither,
    # and a candidate the display helper rejects is redacted whole.
    case $tok in
        *://*|*@*) ;;
        *) return 0 ;;
    esac
    cand=$tok
    q=${tok:0:1}
    case $q in
        "'"|'"'|'`')
            inner=${tok:1}
            case $inner in
                *"$q") cand=${inner%"$q"}; trail=$q ;;
                *"$q"[:,\)\]])
                    last=${inner: -1}
                    cand=${inner%"$q$last"}; trail=$q$last ;;
                *) _PFC_TOK='[redacted-url]'; return 0 ;;
            esac
            lead=$q
            ;;
    esac
    if ! declare -F _bd890_dest_id >/dev/null 2>&1 || ! id=$(_bd890_dest_id "$cand"); then
        _PFC_TOK='[redacted-url]'; return 0
    fi
    case $id in
        *'?'*|*'#'*|*://*@*|*'@'*':'*|*':'*'@'*) _PFC_TOK='[redacted-url]'; return 0 ;;
    esac
    _PFC_TOK=$lead$id$trail
}

# Redact the joined, bounded diagnostic, copying whitespace runs byte for byte.
# Span rule: when it holds two or more URL-shaped tokens (a dropped one's truncation marker
# included), everything from the first to the last becomes one [redacted-url].
# Whitespace inside a password splits one URL into fragments that can each look
# clean and leaves plain words between them that no token rule can recognise, so
# the span is unconditional: two clean URLs on one line are over-redacted.
_pfc_redact_line() {
    local s=$1 out="" ws tok i n first=-1 last=-1
    local -a ws_runs=() toks=() shown=()
    while [ -n "$s" ]; do
        ws=${s%%[![:space:]]*}
        s=${s#"$ws"}
        tok=${s%%[[:space:]]*}
        s=${s#"$tok"}
        ws_runs+=("$ws"); toks+=("$tok")
    done
    n=${#toks[@]}
    for ((i = 0; i < n; i++)); do
        shown+=("${toks[i]}")
        [ -n "${toks[i]}" ] || continue
        case ${toks[i]} in
            "$_PFC_TRUNC_URL") [ "$first" -ge 0 ] || first=$i; last=$i; continue ;;
            *://*|*@*) [ "$first" -ge 0 ] || first=$i; last=$i ;;
        esac
        _pfc_redact_token "${toks[i]}"
        shown[i]=$_PFC_TOK
    done
    for ((i = 0; i < n; i++)); do
        if [ "$first" -lt "$last" ] && [ "$i" -ge "$first" ] && [ "$i" -le "$last" ]; then
            [ "$i" -ne "$first" ] || out=$out${ws_runs[i]}'[redacted-url]'
            continue
        fi
        out=$out${ws_runs[i]}${shown[i]}
    done
    printf '%s' "$out"
}

# Canonical status row: "! [status] <src> -> <dst> (<label>)". Ref names cannot
# hold whitespace, so everything after <dst> is the reason, which is SERVER text;
# only git's own reasons are kept and anything else becomes "(reason withheld)".
_pfc_canon_row() {
    printf '%s\n' "$1" | LC_ALL=C awk '
        {
            k = 0
            for (i = 1; i <= NF; i++) if ($i == "->") { k = i; break }
            if (k == 0) { for (i = 1; i <= NF && substr($i, 1, 1) != "("; i++) h = h (h == "" ? "" : " ") $i; print h; exit }
            for (i = 1; i <= k + 1 && i <= NF; i++) h = h (h == "" ? "" : " ") $i
            r = ""
            for (i = k + 2; i <= NF; i++) r = r (r == "" ? "" : " ") $i
            if (r == "") label = ""
            else if (r == "(fetch first)" || r == "(non-fast-forward)" || r == "(remote failed to report status)" \
                  || r == "(pre-receive hook declined)" || r == "(hook declined)" || r == "(update hook declined)") label = r
            else if (index(r, "(cannot lock ref") == 1) label = "(cannot lock ref)"
            else label = "(reason withheld)"
            print h (label == "" ? "" : " " label)
            exit
        }' || true
}

# Env phrase with its free-text slot replaced: "Permission to .+ denied" carries a
# repository path (or whatever the line held) and is reported without it.
_pfc_canon_phrase() {
    case $1 in
        [Pp][Ee][Rr][Mm][Ii][Ss][Ss][Ii][Oo][Nn]' '[Tt][Oo]' '*) printf '%s' 'Permission to (repository) denied' ;;
        *) printf '%s' "$1" ;;
    esac
}

_pfc_flatten() {
    printf '%s' "$1" | LC_ALL=C tr '\r\t\n' '   ' || true
}

# push_failure_build_diag <raw_output> [<arm>] — sets PUSH_DIAG only.
# arm: history | unknown | hook | env | default (omitted = default).
# The diagnostic is an ALLOWLIST, not a redacted copy: git's own client status row
# for the arm, or the matched env phrase, or fixed text. fatal:/error: prose and
# remote: lines are never copied — a credential split across tokens or lines by
# whitespace has no token-level signature, so no redaction rule can be complete
# over free text (each earlier rule had a probe that walked around it).
push_failure_build_diag() {
    local raw="$1" arm="${2:-default}"
    local evidence="" phrase=""
    # Extractors are failure-tolerant: under set -euo pipefail a zero-match grep
    # exits 1 and a multi-match | head can SIGPIPE.
    case $arm in
        history)
            evidence=$(printf '%s\n' "$raw" | grep -E "$_PFC_HISTORY_RE" | head -n 1) || true
            ;;
        unknown)
            evidence=$(printf '%s\n' "$raw" | grep -E "$_PFC_UNKNOWN_RE" | head -n 1) || true
            ;;
        hook)
            evidence=$(printf '%s\n' "$raw" | grep -E "$_PFC_REMOTE_REJECTED_RE" | head -n 1) || true
            ;;
        env)
            phrase=$(printf '%s\n' "$raw" | grep -vE '^(remote|hint):' | grep -oiE "$_PFC_ENV_CLIENT_RE" | head -n 1) || true
            [ -n "$phrase" ] || phrase=$(printf '%s\n' "$raw" | grep -oiE "$_PFC_ENV_REMOTE_RE" | head -n 1) || true
            ;;
    esac
    [ -n "$evidence$phrase" ] || evidence=$(printf '%s\n' "$raw" | grep -E "$_PFC_CLIENT_ROW_RE" | head -n 1) || true

    local diag
    if [ -n "$phrase" ]; then
        diag=$(_pfc_redact_line "$(_pfc_bound_line "$(_pfc_flatten "$(_pfc_canon_phrase "$phrase")")" 1300)")
    elif [ -n "$evidence" ]; then
        diag=$(_pfc_redact_line "$(_pfc_bound_line "$(_pfc_canon_row "$(_pfc_flatten "$evidence")")" 1300)")
    elif [ "$arm" = hook ]; then
        diag=$_PFC_HOOK_WITHHELD
    else
        diag=$_PFC_NO_ROW
    fi
    if [ "$(_pfc_bytes "$diag")" -gt "$_PFC_MAX_DIAG" ]; then
        diag=$(_pfc_utf8_prefix "$diag" $((_PFC_MAX_DIAG - 16)))$_PFC_TRUNC
    fi
    PUSH_DIAG=$diag
}

push_failure_classify() {
    local push_output="$1" arm
    # Drain-safe grep (>/dev/null, not -q). Arm order is fixed; first match wins.
    if printf '%s\n' "$push_output" | grep -E "$_PFC_HISTORY_RE" >/dev/null; then
        arm="history"
        PUSH_BAIL_CATEGORY="judgment"
        PUSH_BAIL_PREFIX="git push non-fast-forward; local commit preserved"
    elif printf '%s\n' "$push_output" | grep -E "$_PFC_UNKNOWN_RE" >/dev/null; then
        arm="unknown"
        PUSH_BAIL_CATEGORY="env"
        PUSH_BAIL_PREFIX=$_PFC_UNKNOWN_PREFIX
    elif printf '%s\n' "$push_output" | grep -E "$_PFC_REMOTE_REJECTED_RE" >/dev/null; then
        arm="hook"
        PUSH_BAIL_CATEGORY="judgment"
        PUSH_BAIL_PREFIX="git push rejected; local commit preserved"
    elif printf '%s\n' "$push_output" | grep -vE '^(remote|hint):' | grep -iE "$_PFC_ENV_CLIENT_RE" >/dev/null \
        || printf '%s\n' "$push_output" | grep -iE "$_PFC_ENV_REMOTE_RE" >/dev/null; then
        arm="env"
        PUSH_BAIL_CATEGORY="env"
        PUSH_BAIL_PREFIX="git push auth/network/config"
    elif ! printf '%s\n' "$push_output" | grep -E "$_PFC_CLIENT_ROW_RE" >/dev/null \
        && printf '%s\n' "$push_output" | grep -E "$_PFC_REMOTE_HOOK_RE" >/dev/null; then
        arm="hook"
        PUSH_BAIL_CATEGORY="judgment"
        PUSH_BAIL_PREFIX="git push rejected; local commit preserved"
    else
        arm="default"
        PUSH_BAIL_CATEGORY="judgment"
        PUSH_BAIL_PREFIX="git push failed; local commit preserved"
    fi
    push_failure_build_diag "$push_output" "$arm"
}
