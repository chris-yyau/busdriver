#!/usr/bin/env bash
# scripts/lib/staged-diff-hash.sh — portable SHA-256 over stdin.
# Pattern from run-review-loop.sh:31. macOS-safe (no GNU sha256sum required).
hash_stdin() {
    local _raw
    if command -v sha256sum >/dev/null 2>&1; then
        _raw=$(sha256sum 2>/dev/null) || { printf 'hash_stdin: sha256sum failed\n' >&2; return 1; }
    elif command -v shasum >/dev/null 2>&1; then
        _raw=$(shasum -a 256 2>/dev/null) || { printf 'hash_stdin: shasum failed\n' >&2; return 1; }
    else
        printf 'hash_stdin: neither sha256sum nor shasum found\n' >&2
        return 127
    fi
    printf '%s\n' "$_raw" | cut -d' ' -f1
}
