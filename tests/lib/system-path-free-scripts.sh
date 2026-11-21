#!/usr/bin/env bash
# tests/lib/system-path-free-scripts.sh — blueprint-review entry scripts without the #816 block.
#
# init-design-review.sh and run-design-review-loop.sh put /usr/bin:/bin ahead of the caller's
# PATH (BD816-SYSTEM-PATH), so a PATH shim for a tool in those directories (cp, mkdir, mv,
# uname, ...) no longer reaches them. Tests that inject faults or fake a platform that way run
# these copies instead; tests/test-review-entry-system-path.sh covers the block itself.
#
# system_path_free_scripts <repo> <dest>: copies skills/blueprint-review/{scripts,prompts} to
# <dest>/{scripts,prompts} (the loop reads ../prompts) and removes the block from both entry
# scripts (a checkout without the block is copied as is). Exits the calling test if a marker
# survives.
system_path_free_scripts() {
  local repo=$1 dest=$2 f
  mkdir -p "$dest" || exit 1
  cp -R "$repo/skills/blueprint-review/scripts" "$dest/scripts" || exit 1
  cp -R "$repo/skills/blueprint-review/prompts" "$dest/prompts" || exit 1
  for f in init-design-review.sh run-design-review-loop.sh; do
    sed '/^# BD816-SYSTEM-PATH-BEGIN$/,/^# BD816-SYSTEM-PATH-END$/d' \
      "$repo/skills/blueprint-review/scripts/$f" > "$dest/scripts/$f" || exit 1
    if grep -q 'BD816-SYSTEM-PATH' "$dest/scripts/$f"; then
      echo "FATAL: could not remove the #816 PATH block from $f"; exit 1
    fi
  done
}
