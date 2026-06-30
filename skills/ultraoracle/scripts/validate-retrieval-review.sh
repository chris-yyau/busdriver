#!/usr/bin/env bash
# validate-retrieval-review.sh — ADR 0007 Phase 5 Round-2 validator. Fail-CLOSED on an
# Oracle ORACLE_RETRIEVAL_REVIEW that is malformed, mis-typed, has a non-enum verdict,
# carries no claims, or carries any uncited claim. An UNCERTAIN verdict is structurally
# valid (advisory-only downstream) — it is NOT rejected here.
set -euo pipefail
REVIEW_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --review-file) REVIEW_FILE="$2"; shift 2;;
    -h|--help) echo "usage: validate-retrieval-review.sh --review-file <json>" >&2; exit 0;;
    *) echo "error: unknown arg '$1'" >&2; exit 2;;
  esac
done
[[ -n "$REVIEW_FILE" && -r "$REVIEW_FILE" ]] || { echo "error: --review-file required/readable" >&2; exit 2; }

jq -e . "$REVIEW_FILE" >/dev/null 2>&1 || { echo "error: review JSON invalid — failing closed" >&2; exit 3; }

rtype="$(jq -r '.review_type // empty' "$REVIEW_FILE")"
[ "$rtype" = "ORACLE_RETRIEVAL_REVIEW" ] || { echo "error: review_type not ORACLE_RETRIEVAL_REVIEW ('$rtype')" >&2; exit 4; }

verdict="$(jq -r '.verdict // empty' "$REVIEW_FILE")"
case "$verdict" in PASS|FAIL|UNCERTAIN) : ;; *) echo "error: verdict not in PASS|FAIL|UNCERTAIN ('$verdict')" >&2; exit 5;; esac

# claims MUST be a non-empty ARRAY. `jq '.claims|length'` on a STRING returns its
# character count, so a string claims value (`"claims":"hello"`) would otherwise pass a
# bare length>=1 check — assert the type first and fail closed on anything but an array.
nclaims="$(jq 'if (.claims|type)=="array" then (.claims|length) else 0 end' "$REVIEW_FILE")"
case "$nclaims" in ''|*[!0-9]*) echo "error: claims count unreadable — failing closed" >&2; exit 6;; esac
[ "$nclaims" -ge 1 ] || { echo "error: claims missing/empty/not-an-array — failing closed" >&2; exit 6; }

# A claim is VALID only if it is an OBJECT with a non-empty string `.claim` AND a non-empty
# `.evidence` array whose every element is a non-empty string citation. Everything else —
# a non-object element, a null/empty claim text, string/empty/object-element evidence — is
# counted invalid => fail closed (exit 7). jq `and` short-circuits, so the leading
# type=="object" guard makes `.claim`/`.evidence` access safe even for a bare-string element
# (it returns false and is selected as invalid rather than throwing). The integer guard
# converts any jq read failure into the typed exit 7, not a raw `[ : integer expected` crash.
invalid="$(jq '[.claims[]? | select(
    ( (type=="object")
      and ((.claim|type)=="string") and ((.claim|length)>0)
      and ((.evidence|type)=="array") and ((.evidence|length)>0)
      and (all(.evidence[]; (type=="string") and (length>0)))
    ) | not)] | length' "$REVIEW_FILE")"
case "$invalid" in ''|*[!0-9]*) echo "error: claim validation unreadable — failing closed" >&2; exit 7;; esac
[ "$invalid" -eq 0 ] || { echo "error: $invalid malformed/uncited claim(s) — failing closed" >&2; exit 7; }

# NOTE — citation EXISTENCE is intentionally NOT verified here. This validator enforces
# the structural shape (cited array-of-claims). Whether a cited "path:line" actually
# exists in the retrieved evidence is the downstream design-review ARBITER's job — per
# ADR 0007 Phase 4 the arbiter validates Oracle claims against the codebase before any
# PASS/FAIL. Re-checking existence here would duplicate that and couple the validator to
# the manifest format. (Boundary is pinned by a test below.)
echo "OK $verdict"
