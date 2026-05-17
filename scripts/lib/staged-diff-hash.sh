#!/usr/bin/env bash
# scripts/lib/staged-diff-hash.sh — portable SHA-256 over stdin.
# Pattern from run-review-loop.sh:31. macOS-safe (no GNU sha256sum required).
set -u
hash_stdin() {
    (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1
}
