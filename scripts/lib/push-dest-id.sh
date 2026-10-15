#!/usr/bin/env bash
# scripts/lib/push-dest-id.sh — push-destination identity helpers for dispatcher
# Step 11 (#890). Sourced by dispatcher-commit-block.sh, push-failure-classify.sh,
# pr-head-identity.sh, the pr-grind "Push bail recovery" procedure and unit tests.
# Do not execute directly.
#
# bash-3.2-safe: no mapfile, no ${v,,}, no associative arrays. Character classes are
# spelled out byte by byte so a locale cannot widen them.
#
# Predicates return 0 = safe / match. Nothing here logs or prints a URL except
# _bd890_dest_id, whose output is credential-free by construction.

_BD890_LOWER=abcdefghijklmnopqrstuvwxyz
_BD890_UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
_BD890_DIGIT=0123456789

_bd890_lc() {   # ASCII-only lowercase
    printf '%s' "$1" | LC_ALL=C tr "$_BD890_UPPER" "$_BD890_LOWER"
}

# 0 when $1 is non-empty and every byte is an ASCII letter, digit or one of $2.
_bd890_charset() {
    local s=$1 extra=$2
    [ -n "$s" ] || return 1
    case $s in
        *[!"$_BD890_LOWER$_BD890_UPPER$_BD890_DIGIT$extra"]*) return 1 ;;
    esac
    return 0
}

# --- Raw push-URL record reader --------------------------------------------
# 0 = exactly one record in _BD890_ONE_URL; 1 = git failed (_BD890_GIT_RC);
# 2 = record shape refused. Callers: `_rd=0; _bd890_read_one_push_url || _rd=$?`.
_bd890_read_one_push_url() {
    local raw
    _BD890_ONE_URL=""; _BD890_GIT_RC=0
    # Sentinel 'x' keeps every trailing LF; `|| rc=$?` keeps git's status even if
    # errexit is inherited.
    raw=$(rc=0; git remote get-url --push --all origin 2>/dev/null || rc=$?; printf x; exit "$rc") \
        || { _BD890_GIT_RC=$?; return 1; }
    _bd890_one_record "${raw%x}"
}

# Pure parse of raw bytes: 0 = exactly one LF-terminated, whitespace-free record.
_bd890_one_record() {
    local raw=$1
    _BD890_ONE_URL=""
    case $raw in *$'\n') ;; *) return 2 ;; esac       # empty, or no terminating LF
    raw=${raw%$'\n'}                                  # strip exactly ONE terminator
    case $raw in ''|*[[:space:]]*) return 2 ;; esac   # blank, CR/space/tab, or a 2nd record
    _BD890_ONE_URL=$raw
}

# --- Transport URL grammar ---------------------------------------------------
# Shared by _bd890_transport_cred_ok and _bd890_endpoint_identity so the host that
# is compared is the host Git connects to. Accepts exactly:
#   https://HOST[:PORT]/PATH          no '@' anywhere, no '?', no '#'
#   ssh://[USER@]HOST[:PORT]/PATH     one optional colon-free USER
#   [USER@]HOST:PATH                  scp: split at the FIRST ':'; no '/' before it
# Sets _BD890_U_SCHEME/_USER/_HOST/_PORT/_PATH; returns 1 on anything else.
_bd890_parse_transport() {
    local url=$1 rest auth has_user=0
    _BD890_U_SCHEME="" _BD890_U_USER="" _BD890_U_HOST="" _BD890_U_PORT="" _BD890_U_PATH=""
    case $url in ''|*[[:space:]]*|*[[:cntrl:]]*|*'?'*|*'#'*) return 1 ;; esac
    case $url in
        https://*)
            rest=${url#https://}
            case $rest in *@*) return 1 ;; esac
            auth=${rest%%/*}
            [ "$auth" != "$rest" ] || return 1
            _BD890_U_PATH=${rest#*/}
            _BD890_U_SCHEME=https
            ;;
        ssh://*)
            rest=${url#ssh://}
            auth=${rest%%/*}
            [ "$auth" != "$rest" ] || return 1
            _BD890_U_PATH=${rest#*/}
            case $_BD890_U_PATH in *@*) return 1 ;; esac
            _BD890_U_SCHEME=ssh
            ;;
        *://*) return 1 ;;
        *:*)
            auth=${url%%:*}
            _BD890_U_PATH=${url#*:}
            case $auth in ''|*/*) return 1 ;; esac
            case $_BD890_U_PATH in ''|*@*) return 1 ;; esac
            _BD890_U_SCHEME=scp
            ;;
        *) return 1 ;;
    esac
    if [ "$_BD890_U_SCHEME" != https ]; then
        case $auth in
            *@*@*) return 1 ;;
            *@*) has_user=1; _BD890_U_USER=${auth%@*}; auth=${auth#*@} ;;
        esac
        if [ "$has_user" -eq 1 ]; then
            _bd890_charset "$_BD890_U_USER" '._-' || return 1
        fi
    fi
    if [ "$_BD890_U_SCHEME" != scp ]; then
        case $auth in
            *:*) _BD890_U_PORT=${auth#*:}; auth=${auth%%:*}
                 _bd890_charset "$_BD890_U_PORT" '' || return 1
                 case $_BD890_U_PORT in *[!"$_BD890_DIGIT"]*) return 1 ;; esac ;;
        esac
    fi
    _bd890_charset "$auth" '.-' || return 1
    _BD890_U_HOST=$auth
    return 0
}

# 0 = the URL is one of the three credential-free transport forms.
_bd890_transport_cred_ok() {
    _bd890_parse_transport "${1-}"
}

# Prints the canonical endpoint identity HOST[:PORT]/OWNER/NAME (lowercase, default
# port dropped, one trailing .git stripped); returns 1 when it cannot.
_bd890_endpoint_identity() {
    local path owner name port
    _bd890_parse_transport "${1-}" || return 1
    path=$_BD890_U_PATH
    while :; do case $path in /*) path=${path#/} ;; *) break ;; esac; done
    while :; do case $path in */) path=${path%/} ;; *) break ;; esac; done
    path=${path%.git}
    case $path in */*/*|*/|/*|'') return 1 ;; */*) ;; *) return 1 ;; esac
    owner=${path%%/*}
    name=${path#*/}
    [ -n "$owner" ] && [ -n "$name" ] || return 1
    port=$_BD890_U_PORT
    case $_BD890_U_SCHEME:$port in https:443|ssh:22) port="" ;; esac
    printf '%s%s/%s/%s\n' "$(_bd890_lc "$_BD890_U_HOST")" "${port:+:$port}" \
        "$(_bd890_lc "$owner")" "$(_bd890_lc "$name")"
}

# 0 = URL $1 is the PR repository $2 (host/owner/name from _bd890_pr_identity_from_env).
# Scheme is not identity (an HTTPS<->SSH alias matches); any non-default port never does.
_bd890_endpoint_matches_pr() {
    local id
    [ -n "${2-}" ] || return 1
    id=$(_bd890_endpoint_identity "${1-}") || return 1
    [ "$id" = "$2" ]
}

# --- Display identity (display and redaction only, never identity) ------------
# Prints one credential-free display string and returns 0, or prints nothing and
# returns 1. Strict: only what _bd890_parse_transport accepts is displayed. It never
# salvages a display string from credential-shaped input — every salvage rule had a
# boundary the next probe walked around (a password holding '/', '?', '#', '@' or
# whitespace) — so anything else is refused and the caller redacts it whole.
_bd890_dest_id() {
    local out
    _bd890_parse_transport "${1-}" || return 1
    if [ "$_BD890_U_SCHEME" = scp ]; then
        out=$_BD890_U_HOST:$_BD890_U_PATH
    else
        out=$_BD890_U_HOST${_BD890_U_PORT:+:$_BD890_U_PORT}/$_BD890_U_PATH
    fi
    while :; do case $out in */) out=${out%/} ;; *) break ;; esac; done
    out=${out%.git}
    case $out in ''|*@*|*'?'*|*'#'*|*://*|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;; esac
    printf '%s\n' "$out"
}

# --- PR repository tuple -------------------------------------------------------
# 0 = host/owner/name are a well-formed GitHub repository tuple. Shared with
# pr-head-identity.sh so Step 0 and the dispatcher cannot drift.
_bd890_pr_identity_valid() {
    _bd890_charset "${1-}" '.-' || return 1
    _bd890_charset "${2-}" '._-' || return 1
    _bd890_charset "${3-}" '._-' || return 1
}

# Prints host/owner/name (lowercase, one trailing .git stripped from name) from
# PR_HEAD_HOST / PR_HEAD_OWNER / PR_HEAD_NAME; returns 1 if missing or malformed.
_bd890_pr_identity_from_env() {
    local host=${PR_HEAD_HOST-} owner=${PR_HEAD_OWNER-} name=${PR_HEAD_NAME-}
    _bd890_pr_identity_valid "$host" "$owner" "$name" || return 1
    name=${name%.git}
    [ -n "$name" ] || return 1
    printf '%s/%s/%s\n' "$(_bd890_lc "$host")" "$(_bd890_lc "$owner")" "$(_bd890_lc "$name")"
}

# --- Bounded tip-lookup wrapper -----------------------------------------------
# 0 = sets _tip_wrap=(<cmd> -k 2 10) for the first candidate whose `-k` works;
# 1 = none does (no unbounded or no-`-k` fallback). Candidates default to
# `timeout gtimeout`; tests pass their own as arguments.
_bd890_select_tip_wrapper() {
    local c
    _tip_wrap=()
    [ "$#" -gt 0 ] || set -- timeout gtimeout
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || continue
        if "$c" -k 1 5 true >/dev/null 2>&1; then
            _tip_wrap=("$c" -k 2 10)
            return 0
        fi
    done
    return 1
}
