#!/usr/bin/env bash
# PostToolUse hook: auto-format Go files with gofmt and run go vet after edits
# Only fires on .go files. Fail-open.

set -euo pipefail
trap 'exit 0' ERR

# Read hook data from stdin
HOOK_DATA=$(cat 2>/dev/null || true)
[ -z "$HOOK_DATA" ] && exit 0

# Fast pre-filter: skip non-.go files without spawning python3
case "$HOOK_DATA" in
    *'.go"'*) ;;
    *) exit 0 ;;
esac

# Extract file path from tool input
FILE_PATH=$(printf '%s' "$HOOK_DATA" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    print(inp.get('file_path', ''))
except Exception:
    print('')
" 2>/dev/null || true)

# Only process .go files
case "$FILE_PATH" in
    *.go) ;;
    *) exit 0 ;;
esac

# Skip if file doesn't exist
[ ! -f "$FILE_PATH" ] && exit 0

# Run gofmt (in-place)
if command -v gofmt &> /dev/null; then
    gofmt -w "$FILE_PATH" 2>/dev/null || true
fi

# Run goimports if available (superset of gofmt)
if command -v goimports &> /dev/null; then
    goimports -w "$FILE_PATH" 2>/dev/null || true
fi

# Run go vet on the package containing the file
PKG_DIR=$(dirname "$FILE_PATH")
if command -v go &> /dev/null; then
    vet_output=$(cd "$PKG_DIR" && go vet ./... 2>&1) || true
    if [ -n "$vet_output" ]; then
        echo "$vet_output" >&2
    fi
fi

exit 0
