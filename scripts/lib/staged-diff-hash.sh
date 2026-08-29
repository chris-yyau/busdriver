#!/usr/bin/env bash
# scripts/lib/staged-diff-hash.sh — portable SHA-256 over stdin.
# Pattern from run-review-loop.sh:31. macOS-safe (no GNU sha256sum required).
hash_stdin() {
    local _raw
    # Absolute path inside a trusted system directory: `command -v` walks PATH, which is
    # repo-injectable, and on macOS sha256sum lives in /sbin so a prepended /usr/bin:/bin
    # would not even cover it (#576).
    local _cmd=() _d
    for _d in /usr/bin /bin /sbin /usr/sbin; do
        if [ -x "$_d/sha256sum" ]; then _cmd=("$_d/sha256sum"); break; fi
        if [ -x "$_d/shasum" ]; then _cmd=("$_d/shasum" -a 256); break; fi
    done
    if [ ${#_cmd[@]} -eq 0 ]; then
        printf 'hash_stdin: no sha256sum/shasum in a trusted system directory\n' >&2
        return 127
    fi
    _raw=$("${_cmd[@]}" 2>/dev/null) || { printf 'hash_stdin: hash utility failed\n' >&2; return 1; }
    printf '%s\n' "$_raw" | cut -d' ' -f1
}
