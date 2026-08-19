#!/bin/bash
# grok-preflight.sh — the grok sandbox preflight, as a standalone script.
#
# INVOKED ONLY BY resolve-cli.sh's grok_sandbox_preflight, as
# `/usr/bin/env -i /bin/bash -p <this file> [<profile-path-override>]`, so it
# runs with no inherited environment and no inherited shell functions. Nothing
# here may assume anything from the caller.
#
# WHY A SEPARATE FILE. This body used to be a quoted heredoc inside the
# caller's `$( )`. macOS /bin/bash 3.2 mis-parses that construct once the body
# contains enough quoting, and it does so SILENTLY in the worst way: the syntax
# error is reported hundreds of lines later at an unrelated `case` arm, and a
# Homebrew bash 5 running `bash -n` reports nothing at all. That is the #595
# fail-open shape. A plain file has no such parse hazard.
#
# It lives beside resolve-cli.sh under the installed plugin root, so it carries
# exactly the same trust as its caller — NOT the trust of the checkout being
# reviewed, which is the whole point of the checks below.
#
# Contract: prints `HOME=<home>` and `PATH=<pinned>` and exits 0 when the
# operator's sandbox profile is present and meets the contract; otherwise
# prints `WHY=<identity|configdir|containment|binary|profile>` and exits 1.
# The caller turns that reason into a remediation message.

set -u
PATH=/usr/bin:/bin
file="${1:-}"

# Every refusal names its CAUSE. One generic "profile is missing" for all of
# them sent operators to copy an example file that cannot fix a symlinked
# ~/.grok, a checkout that contains it, or a grok binary resolving into the
# reviewed tree.
why() {
  printf 'WHY=%s\n' "$1"
  exit 1
}

# follow a symlink chain without readlink -f (GNU-only); bounded so a loop
# cannot hang
resolve_link() {
  p="$1"; n=0
  while [[ -L "$p" ]] && [[ "$n" -lt 32 ]]; do
    t="$(/usr/bin/readlink "$p")" || return 1
    if [[ "${t#/}" != "$t" ]]; then p="$t"; else p="$(/usr/bin/dirname -- "$p")/$t"; fi
    n=$((n + 1))
  done
  # Still a symlink at the bound means the chain was NOT resolved. Returning the
  # partial answer would hand back a path that looks safe while exec follows the
  # remaining hops to somewhere else entirely.
  [[ -L "$p" ]] && return 1
  printf '%s\n' "$p"
}

home=""
pinned=""

if [[ -z "$file" ]]; then
  user="$(/usr/bin/id -un 2>/dev/null)" || why identity
  [[ -n "$user" ]] || why identity
  # no shell metacharacters, and none of bash's `~+` / `~-` / `~+1` directory-
  # stack forms, which expand to PWD/OLDPWD instead of an account home
  [[ "$user" == *[!A-Za-z0-9._-]* ]] && why identity
  [[ "$user" =~ ^[-+]?[0-9]*$ ]] && why identity

  # password database directly — no `eval echo ~user`, no interpreter version
  # floor: dscl on macOS, getent on Linux, refuse if neither is present
  if [[ -x /usr/bin/dscl ]]; then
    home="$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')" || why identity
  elif [[ -x /usr/bin/getent ]]; then
    home="$(/usr/bin/getent passwd "$user" 2>/dev/null | /usr/bin/cut -d: -f6)" || why identity
  else
    why identity
  fi
  [[ -n "$home" ]] || why identity
  [[ "${home#/}" != "$home" ]] || why identity
  [[ -d "$home" ]] || why identity

  # the config DIRECTORY must not be a symlink: pointing ~/.grok into the
  # reviewed tree makes the profile AND the bin/grok the PATH pin trusts
  # repo-controlled while every individual file stays a regular file
  [[ -L "$home/.grok" ]] && why configdir
  [[ -d "$home/.grok" ]] || why configdir
  file="$home/.grok/sandbox.toml"
  pinned="$home/.grok/bin:$home/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

  # the checkout ROOT, found by walking up for a `.git` — NOT `git rev-parse`,
  # which honours the injectable GIT_DIR / GIT_WORK_TREE. Run from a
  # subdirectory of a checkout rooted at $HOME, $PWD alone would clear ~/.grok
  # while the branch still owns it.
  # The child's OWN working directory, not a value passed in: $PWD is an
  # ordinary shell variable and can be reassigned without changing directory,
  # so a forged one would have the containment checks compare ~/.grok against
  # the wrong root. The child inherits the real cwd from the process.
  root="$(pwd -P)" || why containment
  [[ -n "$root" ]] || why containment
  walk="$root"
  while [[ -n "$walk" ]] && [[ "$walk" != "/" ]]; do
    if [[ -e "$walk/.git" ]]; then root="$walk"; break; fi
    walk="${walk%/*}"
  done

  # EVERY directory on the pinned PATH must sit outside that tree — not just the
  # two home-derived ones. A checkout rooted at ~/.local would supply
  # .local/bin/grok, and one rooted at /opt/homebrew or /usr/local would supply
  # any interpreter a `#!/usr/bin/env node` grok wrapper resolves through the
  # same PATH. A directory that does not exist is fine; nothing runs from it.
  # The CONFIG DIRECTORY itself, first and unconditionally. The loop below walks
  # the pinned PATH, whose home entries are `$home/.grok/bin` and
  # `$home/.local/bin` — neither of which need exist, and a non-existent one is
  # skipped. That would leave `$home/.grok`, the directory holding the profile
  # this whole check is about, never compared against the checkout: a tree
  # containing the operator home could then supply its own sandbox.toml while a
  # system-installed grok launched happily.
  cfgreal="$(cd -P -- "$home/.grok" 2>/dev/null && pwd -P)" || why containment
  [[ -n "$cfgreal" ]] || why containment
  [[ "${cfgreal%/}/" == "${root%/}/"* ]] && why containment

  pathrest="$pinned:"
  while [[ -n "$pathrest" ]]; do
    d="${pathrest%%:*}"; pathrest="${pathrest#*:}"
    [[ -n "$d" ]] || continue
    [[ -e "$d" ]] || continue
    real="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || why containment
    [[ -n "$real" ]] || why containment
    [[ "${real%/}/" == "${root%/}/"* ]] && why containment
  done

  # a grok EXECUTABLE must exist on the pinned PATH, and must not resolve back
  # into the reviewed tree. Tested as a file, not via `command -v`: that
  # consults shell functions, while /usr/bin/env searches PATH only.
  #
  # Only the FIRST match is considered, and it must be safe. Skipping an unsafe
  # candidate to find a safe one later would validate a binary that never runs:
  # env execs the first grok on the same PATH, so a repo-controlled ~/.grok/bin
  # entry would execute while the check blessed /usr/bin.
  found=""
  rest="$pinned:"
  while [[ -n "$rest" ]]; do
    p="${rest%%:*}"; rest="${rest#*:}"
    [[ -n "$p" ]] || continue
    [[ -x "$p/grok" ]] || continue
    [[ -d "$p/grok" ]] && continue
    target="$(resolve_link "$p/grok")" || why binary
    real="$(cd -P -- "$(/usr/bin/dirname -- "$target")" 2>/dev/null && pwd -P)" || why binary
    [[ -n "$real" ]] || why binary
    [[ "${real%/}/" == "${root%/}/"* ]] && why binary
    # Must be a real BINARY, not merely an executable file. A script's
    # interpreter is resolved at exec time — `#!/usr/bin/env node` picks
    # whatever `node` that same PATH finds first — and an executable text file
    # with NO shebang is handed to /bin/sh by execvp, so "does not start with
    # #!" is not the test. Ask what the file actually IS: application/* is a
    # binary image, text/* is a wrapper. grok ships as a real executable, so
    # requiring one costs nothing and bounds the check at a single file.
    # `-f` first: an executable FIFO named grok passes -x and is not a
    # directory, and reading it would block the gate forever.
    [[ -f "$target" ]] || why binary
    # An ALLOWLIST of native image types, not the `application/` prefix:
    # `file` calls anything it cannot identify application/octet-stream,
    # including a shebang-less shell program with one control byte in it — and
    # execvp hands exactly that to /bin/sh on ENOEXEC. Mach-O covers macOS; the
    # three ELF spellings cover Linux across `file` versions.
    #
    # A universal binary reports ONE LINE PER ARCHITECTURE, each prefixed with
    # `(for architecture …):`, so the prefixes are stripped and EVERY line must
    # be allowlisted — a single non-native slice is a refusal.
    kinds="$(/usr/bin/file -b --mime-type -- "$target" 2>/dev/null | /usr/bin/sed 's/^.*:[[:space:]]*//')" || why binary
    [[ -n "$kinds" ]] || why binary
    printf '%s\n' "$kinds" | /usr/bin/grep -qvE '^(application/x-mach-binary|application/x-executable|application/x-pie-executable|application/x-sharedlib)$' && why binary
    found=1; break
  done
  [[ -n "$found" ]] || why binary
fi

# a symlinked profile can point back into the reviewed tree
[[ -f "$file" ]] || why profile
[[ -L "$file" ]] && why profile

block="$(/usr/bin/awk '
  /^[[:space:]]*\[profiles\.busdriver-review\][[:space:]]*$/ { inblk = 1; next }
  /^[[:space:]]*\[/                                          { inblk = 0 }
  inblk
' "$file")" || why profile
[[ -n "$block" ]] || why profile

# strip comments, but only a `#` that starts outside a double-quoted string —
# otherwise a deny entry of "#" truncates the array and the checks below read
# the leftovers. A backslash escapes the next character inside a string.
block="$(printf '%s\n' "$block" | /usr/bin/awk '{
  out = ""; inq = 0
  for (i = 1; i <= length($0); i++) {
    c = substr($0, i, 1)
    if (inq && c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
    if (c == "\"") inq = !inq
    else if (c == "#" && !inq) break
    out = out c
  }
  print out
}')" || why profile

# keys matched bare, double-quoted and single-quoted: TOML accepts all three
printf '%s\n' "$block" | /usr/bin/grep -qE "^[[:space:]]*[\"']?extends[\"']?[[:space:]]*=[[:space:]]*\"strict\"" || why profile
printf '%s\n' "$block" | /usr/bin/grep -qE "^[[:space:]]*[\"']?restrict_network[\"']?[[:space:]]*=[[:space:]]*true" || why profile
# read_write grants writable paths; read_only grants extra readable ones —
# `read_only = ["/"]` would defeat the CWD-only confinement
printf '%s\n' "$block" | /usr/bin/grep -qE "^[[:space:]]*[\"']?read_(write|only)[\"']?[[:space:]]*=" && why profile
# \uXXXX / \UXXXXXXXX escapes spell a key around any textual matcher, and a
# multiline string can carry the required globs as text while deny = []
printf '%s\n' "$block" | /usr/bin/grep -qi '\\u' && why profile
printf '%s\n' "$block" | /usr/bin/grep -qF '"""' && why profile
printf '%s\n' "$block" | /usr/bin/grep -qF "'''" && why profile

deny="$(printf '%s\n' "$block" | /usr/bin/awk '
  /^[[:space:]]*["\x27]?deny["\x27]?[[:space:]]*=/ { indeny = 1 }
  indeny { print }
  indeny && /\]/ { exit }
')" || why profile
[[ -n "$deny" ]] || why profile
# double-quoted entries only: a TOML literal string can carry the quote
# characters INSIDE the value, so `deny = ['"**/.grok"']` denies a path whose
# name contains quotes while satisfying a search for `"**/.grok"`
printf '%s\n' "$deny" | /usr/bin/grep -q "'" && why profile
# and no backslash: TOML basic strings decode escapes, so `"\"**/.grok\""`
# is a glob whose value CONTAINS quote characters — it denies nothing while its
# source still reads like the required entry. Refusing the escape character
# outright kills that whole encoding class; the shipped profile has none.
[[ "$deny" == *\\* ]] && why profile

for req in '"**/.grok"' '"**/.grok/**"' '"**/.claude"' '"**/.claude/**"' \
           '"**/.cursor"' '"**/.cursor/**"' \
           '"**/.env"' '"**/.env.*"' '"**/*.pem"' '"**/*.key"'; do
  printf '%s\n' "$deny" | /usr/bin/grep -qF "$req" || why profile
done

printf 'HOME=%s\n' "$home"
printf 'PATH=%s\n' "$pinned"
exit 0
