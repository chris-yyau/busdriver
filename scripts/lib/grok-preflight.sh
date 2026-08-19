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

# Identity and home are derived UNCONDITIONALLY, fixture override included.
# They used to sit inside the `-z "$file"` branch below, so under a fixture
# `$home` stayed empty — which was invisible until the profile-BODY rules grew
# a dependency on it: the home-secret deny requirement then tested `/.ssh`,
# found nothing, and skipped itself in exactly the harness that exists to prove
# it fires. A body rule must be checkable by the body harness.
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

if [[ -z "$file" ]]; then
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
    # Must be a real BINARY, not merely an executable file, and the magic
    # ALONE does not establish that: a shell payload prefixed with `\x7fELF\n`
    # carries the right first four bytes, gets ENOEXEC from the kernel, and is
    # then handed to /bin/sh by execvp — the wrapper path this check exists to
    # close (Codex, PR #704). So validate the HEADER, not just its first word.
    #
    # Read the bytes rather than asking file(1): `file` is an optional package,
    # absent from a stock Ubuntu 24.04, and depending on it made every valid
    # grok install refuse as `WHY=binary` on such a host. `od` is coreutils.
    #
    # `-f` first: an executable FIFO named grok passes -x and is not a
    # directory, and reading it would block the gate forever.
    [[ -f "$target" ]] || why binary
    # Read then squeeze, rather than piping into `tr`: in a pipeline the
    # substitution reports TR's status, so a failed `od` would arrive as
    # success with an empty string. The length check below would still catch
    # it, but a status that cannot be trusted is not worth keeping around.
    hdr="$(/usr/bin/od -An -tx1 -N20 -- "$target" 2>/dev/null)" || why binary
    hdr="${hdr//[[:space:]]/}"
    [[ ${#hdr} -eq 40 ]] || why binary
    case "${hdr:0:8}" in
      7f454c46)
        # ELF: EI_CLASS in {32,64}, EI_DATA in {LE,BE}, EI_VERSION = 1, and
        # e_type (bytes 16..17, byte order per EI_DATA) is EXEC or DYN. A text
        # payload cannot satisfy all four by accident - every one of those
        # offsets would have to hold a byte that is not printable ASCII.
        #
        # Mind which byte is which; the first version of this got it wrong in
        # two ways at once and refused EVERY real ELF binary. `hdr` is the hex
        # of the first 20 bytes with the spaces stripped, so byte N sits at hex
        # offset 2N: EI_CLASS is byte 4 (:8), EI_DATA byte 5 (:10), EI_VERSION
        # byte 6 (:12), and e_type is bytes 16..17 (:32 and :34). Selecting the
        # byte order from :12 reads EI_VERSION - always 01 - so every image took
        # the little-endian arm; and swapping a two-byte field means exchanging
        # the BYTES (:34 then :32), not the nibbles inside them.
        case "${hdr:8:2}"  in 01|02) : ;; *) why binary ;; esac
        case "${hdr:12:2}" in 01)    : ;; *) why binary ;; esac
        case "${hdr:10:2}" in
          01) etype="${hdr:34:2}${hdr:32:2}" ;;
          02) etype="${hdr:32:2}${hdr:34:2}" ;;
          *)  why binary ;;
        esac
        case "$etype" in 0002|0003) : ;; *) why binary ;; esac ;;
      feedface|feedfacf)
        # Mach-O thin, big-endian on disk: filetype at bytes 12..15 must be
        # MH_EXECUTE (2).
        case "${hdr:24:8}" in 00000002) : ;; *) why binary ;; esac ;;
      cefaedfe|cffaedfe)
        # Mach-O thin, little-endian: same field, byte-swapped.
        case "${hdr:24:8}" in 02000000) : ;; *) why binary ;; esac ;;
      cafebabe|cafebabf)
        # Universal (FAT) header, stored big-endian - `cafebabf` is the 64-bit
        # variant (FAT_MAGIC_64), which differs only in the fat_arch table and
        # not in the two fields read here. The magic is SHARED with Java
        # `.class`, so discriminate on what follows: bytes 8..11 are the first
        # arch's cputype, and the only ones this lane can execute are x86_64
        # (0x01000007) and arm64 (0x0100000c). In a .class those bytes are the
        # constant-pool count and its first tag, which cannot take either value:
        # a count of 0x0100 with tag 0x07/0x0c would mean 256 entries whose
        # first is a CONSTANT_Class/Double, and the byte BEFORE it (the major
        # version's low byte) would have to be 0x00 - no released class-file
        # version is 0.
        case "${hdr:16:8}" in 01000007|0100000c) : ;; *) why binary ;; esac ;;
      bebafeca|bfbafeca)
        # The same two headers byte-swapped (FAT_CIGAM / FAT_CIGAM_64). The swap
        # is not confined to the magic - every u32 in the header is stored in
        # the opposite order, cputype included, so the values to match are the
        # reversed ones. Applying the big-endian encodings here (the first
        # version of this arm did) refuses every valid byte-swapped image.
        case "${hdr:16:8}" in 07000001|0c000001) : ;; *) why binary ;; esac ;;
      *) why binary ;;
    esac
    # RESIDUAL, stated rather than implied: only the kernel decides what loads,
    # so no userspace header check is proof. What this rules out is every
    # ACCIDENT and every casual wrapper; a file crafted to satisfy the header
    # and still be shell-interpretable is out of scope, because placing one on
    # the operator's own pinned PATH already requires write access to their
    # home — the same boundary the sandbox profile itself rests on.
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

# Those ten are WORKSPACE-anchored. The home-secret entries are not, and until
# now NOTHING validated them: a profile that kept the shipped `/Users/YOU/.ssh`
# placeholder, or dropped those lines while editing, passed this gate having
# denied nothing for the operator's real credentials -- while the profile's own
# header and this repo's docs claimed home secrets were kernel-denied. And the
# relative globs do not cover the gap: `id_rsa` and `credentials` match neither
# `**/*.pem` nor `**/*.key`. Reported independently by Codex and Greptile
# (both P1) on PR #704.
#
# Two details make this correct rather than merely stricter:
#
#   * `$home` is the IDENTITY-VERIFIED home derived above, NOT $HOME, so the
#     required entry cannot be relocated by exporting HOME -- the same reason
#     the rest of this script never trusts $HOME.
#
#   * a path is required only when it EXISTS. The shipped example instructs
#     operators to delete absolute entries for paths they do not have, because
#     on Linux a deny path that cannot be bound makes grok refuse to start;
#     demanding an entry for an absent directory would fail closed for no
#     protective gain. EXTRA entries are always allowed -- only the applicable
#     ones are required.
#
# The `/**` companion is required for the directories for the same measured
# reason as `**/.claude`: a bare directory glob denies only the directory path
# itself, not its contents.
for secret in .ssh .aws; do
  if [[ -e "$home/$secret" ]]; then
    printf '%s\n' "$deny" | /usr/bin/grep -qF "\"$home/$secret\"" || why profile
    printf '%s\n' "$deny" | /usr/bin/grep -qF "\"$home/$secret/**\"" || why profile
  fi
done
if [[ -e "$home/.netrc" ]]; then
  printf '%s\n' "$deny" | /usr/bin/grep -qF "\"$home/.netrc\"" || why profile
fi

printf 'HOME=%s\n' "$home"
printf 'PATH=%s\n' "$pinned"
exit 0
