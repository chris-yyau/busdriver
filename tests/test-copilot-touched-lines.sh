#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$REPO_ROOT/scripts/lib/copilot-touched-lines.py"

# t1: simple file with hunk
out=$(printf 'diff --git a/foo.txt b/foo.txt\n+++ b/foo.txt\n@@ -10,3 +12,4 @@\n' | python3 "$PARSER")
echo "$out" | jq -e '. == [{"path":"foo.txt","start":12,"end":15}]' >/dev/null || { echo "FAIL t1: $out"; exit 1; }

# t2: zero-length defaulted hunk
out=$(printf 'diff --git a/b.txt b/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n' | python3 "$PARSER")
echo "$out" | jq -e '. == [{"path":"b.txt","start":1,"end":1}]' >/dev/null || { echo "FAIL t2: $out"; exit 1; }

# t3: rename — `+++ b/newname` differs from `diff --git a/oldname b/newname`. Parser uses b/.
out=$(printf 'diff --git a/old.txt b/new.txt\n+++ b/new.txt\n@@ -1 +1 @@\n' | python3 "$PARSER")
echo "$out" | jq -e '.[0].path == "new.txt"' >/dev/null || { echo "FAIL t3 (rename): $out"; exit 1; }

# t4: spaces in path
out=$(printf 'diff --git a/dir/foo bar.txt b/dir/foo bar.txt\n+++ b/dir/foo bar.txt\n@@ -1 +1,2 @@\n' | python3 "$PARSER")
echo "$out" | jq -e '.[0].path == "dir/foo bar.txt"' >/dev/null || { echo "FAIL t4 (spaces): $out"; exit 1; }

# t5: empty in → []
[ "$(printf '' | python3 "$PARSER")" = "[]" ] || { echo "FAIL t5"; exit 1; }

# t6: malformed survives
out=$(printf 'random\n@@ malformed @@\n' | python3 "$PARSER")
[ "$out" = "[]" ] || { echo "FAIL t6: $out"; exit 1; }

# t7: multi-file with mixed
out=$(printf 'diff --git a/a.txt b/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\ndiff --git a/c.txt b/c.txt\n+++ b/c.txt\n@@ -5 +5,3 @@\n' | python3 "$PARSER")
echo "$out" | jq -e 'length == 2 and .[0].path == "a.txt" and .[1].path == "c.txt"' >/dev/null || { echo "FAIL t7: $out"; exit 1; }

echo "All copilot-touched-lines tests passed"
