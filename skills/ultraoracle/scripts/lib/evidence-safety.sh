#!/usr/bin/env bash
# evidence-safety.sh — single-sourced secret-scan + repo-containment gates for the
# ultraOracle evidence tooling (ADR 0007 Phase 5 Task 1). Extracted verbatim from
# build-evidence-pack.sh so build-evidence-pack.sh AND retrieve-evidence.sh inherit
# one audited copy of the boundary, with zero logic drift.
#
# REQUIRED GLOBAL: the caller MUST set GIT_ROOT to the canonicalized (pwd -P) repo
# root BEFORE calling is_secret_like / contained_path — both strip/compare against it.
#
# This file is sourced, never executed: it intentionally does NOT set shell options
# (the caller owns `set -euo pipefail`). Bash 3.2-compatible idioms throughout.

# secret-like? filename denylist + known secret-content prefixes. No override (ADR 348).
# The sk- pattern allows '-'/'_' so namespaced keys (sk-proj-…, sk-ant-api03-…) match.
# Filename denylist only (no content read) — reused by is_secret_like AND the git-diff
# pathspec filter so a tracked secret file never rides out inside the aggregated diff.
is_secret_basename() {
  # Case-INSENSITIVE so API_TOKEN / SERVICE_CREDENTIALS / Cookies.txt are caught too.
  # Scope nocasematch to this function (bash 3.2 has no ${x,,}) and restore the prior
  # setting explicitly (no eval) so no other case statement is affected and there is no
  # eval of any command string, even bash's own trusted shopt output.
  local rc=1 had_ncm=0
  shopt -q nocasematch && had_ncm=1
  shopt -s nocasematch
  # Key patterns match only SECRET-CONTEXT prefixes (api/access/private/signing/
  # encryption + key) in snake/kebab/camelCase — NOT a bare `*key*`, which would
  # over-exclude ordinary source (foreign-key.sql, keyboard, keys.json). Plus credential
  # dotfiles and *password* (conservative: an evidence pack errs toward excluding a
  # password-named file; the operator sees the exclusion in the manifest). A generic
  # key/keys basename stays attachable — its secret VALUES hit the content scan.
  case "$1" in
    .env|.env.*|*.pem|*.key|*.pfx|*.p12|id_rsa|id_dsa|id_ecdsa|id_ed25519|\
    .netrc|*.netrc|.pgpass|.npmrc|.htpasswd|passwd|shadow|*password*|*passwd*|\
    *secret*|*token*|*credential*|*cookie*|*.keystore|*.jks|\
    *api?key*|*apikey*|*access?key*|*accesskey*|*private?key*|*privatekey*|\
    *signing?key*|*signingkey*|*encryption?key*|*encryptionkey*) rc=0;;
  esac
  [ "$had_ncm" -eq 1 ] || shopt -u nocasematch
  return "$rc"
}

# True if ANY component of the path is secret-like (not just the leaf). Walks
# right-to-left via parameter expansion — no word-split/glob hazard. Catches a safe
# leaf under a secret-named dir, e.g. secrets/config.yml or .env.d/app.
is_secret_path() {
  local p="$1" comp
  while [ -n "$p" ]; do
    comp="${p##*/}"
    [ -n "$comp" ] && is_secret_basename "$comp" && return 0
    [ "$p" = "${p%/*}" ] && break
    p="${p%/*}"
  done
  return 1
}

is_secret_like() {
  # Strip the repo root first so path components ABOVE GIT_ROOT (e.g. a checkout under
  # ~/token-service or /private/secrets) cannot false-positive EVERY file. Only the
  # repo-relative portion is denylist-checked; the content scan still uses the full $p.
  local p="$1" rel="${1#"$GIT_ROOT"/}"
  is_secret_path "$rel" && return 0
  # Content scan over the WHOLE file (a token past an arbitrary byte cap must not
  # slip through); -a treats binary as text. Files are bounded by the byte budget.
  if LC_ALL=C grep -aqE \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e '(AKIA|ASIA)[0-9A-Z]{16}' \
    -e 'sk-[A-Za-z0-9_-]{20,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    -e 'gh[pousr]_[A-Za-z0-9]{30,}' -- "$p"; then
    return 0
  fi
  return 1
}

# Canonicalize a --file path and require it to live under GIT_ROOT. Echoes the
# resolved path on success; returns non-zero for anything outside the repo (absolute
# escapes, ../ traversal, symlinked siblings) so it is never attached.
contained_path() {
  local src="$1" dir base canon
  # Reject a symlinked final component: cd+pwd -P resolves intermediate dir symlinks,
  # but a repo-local link (repo/leak -> /outside/file) would otherwise canonicalize to
  # an in-repo name yet cp through to outside content. Regular evidence files only.
  [[ -L "$src" ]] && return 1
  local s="$src" sp; while [ "$s" != "/" ] && [ "${s%/}" != "$s" ]; do s="${s%/}"; done
  sp="${s%/*}"; [ "$sp" = "$s" ] && sp="."
  dir="$(cd "$sp" 2>/dev/null && pwd -P)" || return 1
  base="${s##*/}"
  canon="$dir/$base"
  [[ -L "$canon" ]] && return 1
  case "$canon" in
    "$GIT_ROOT"/*) printf '%s' "$canon"; return 0;;
    *) return 1;;
  esac
}

bytes_of() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

# Read NUL-delimited paths on stdin; emit (newline-terminated) only the non-secret
# ones. NUL input means git never C-quotes a control-char path, so a secret name with
# an embedded tab/newline can't evade the anchored denylist via a leading quote.
# Applied to git status and upstream ls-files so a secret PATH NAME is never
# transmitted even though its content is already absent.
emit_nonsecret_z() {
  local p
  while IFS= read -r -d '' p; do
    [ -n "$p" ] && is_secret_path "$p" && continue
    printf '%s\n' "$p"
  done
  return 0   # a final dropped record must not look like a pipeline failure under pipefail
}
