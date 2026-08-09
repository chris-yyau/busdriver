---
name: imagegen
description: >-
  Generate raster image assets from Claude Code by dispatching to a subscription
  CLI that owns an image tool — Codex (`image_gen`), Antigravity/Gemini
  (`generate_image`), or Grok (`image_gen`/`image_edit`). Use when a task needs
  actual pixels: logos, icons, hero art, textures, sprites, mockups, reference
  boards, or editing an existing image. Triggers include generate an image,
  make a logo, need a hero image, create an icon, design reference board,
  edit this image. NOT for charts, diagrams, or UI built in HTML/CSS/SVG —
  build those in code. Video is unavailable; see the Video section.
allowed-tools:
  - Bash(mkdir *)
  - Bash(file *)
---

# imagegen

Claude Code has no image tool. Three CLIs you already pay for do. This skill is
a **router** — it picks one, hands it an absolute output path, and gets a file
back. It deliberately carries **no prompt-craft**: each host ships its own and
theirs is better than a fourth copy (`~/.codex/skills/.system/imagegen/references/prompting.md`,
`~/.grok/bundled/skills/imagine/SKILL.md`).

**No CLI is pre-approved in `allowed-tools`.** These are general-purpose coding
agents; a `Bash(codex exec *)` grant would also pre-approve
`codex exec --dangerously-bypass-approvals-and-sandbox`. Every dispatch below
goes through the normal permission prompt, and every command carries its host's
sandbox flag. Do not add a wildcard grant for them, and do not drop the sandbox
flag to "make it work".

## Route

| Need | Provider |
|------|----------|
| Logo, icon, UI asset, **transparent background** | **codex** |
| Flat vector, fast, no frills | **agy** |
| Illustration, photo-real, or **editing an existing image** | **grok** |

Only Codex has a real transparency path (generate on a chroma key, then
`remove_chroma_key.py`). Only Grok has `image_edit`. When it doesn't matter,
use **codex** — it produced the cleanest mark on an identical prompt.

## Commands (verified 2026-08-09)

Always pass an **absolute** `$OUT`, and always tell the agent to reply with the
path only — that reply is how you learn where the file actually landed.

**Never paste the brief into the command literal.** A brief containing a
backtick, `$(…)`, `$VAR`, or a quote is evaluated by *your* shell before the
provider ever starts. Write the brief to a file with the **Write** tool, then
read it into a variable — expanding a variable inside double quotes is not
re-evaluated, so this is injection-free for any content (a heredoc is not: a
line equal to the delimiter ends it, and the rest parses as shell).

Dispatch from a fresh temp directory outside any checkout — never from the asset
tree or a repository. See Threat model for why.

**Step 1 — write the brief with the Write tool**, to a scratch path *outside* the
asset tree (your scratchpad, not `assets/`): prompt text should never end up
beside a served or committed image. Do this first: shell variables do not survive
between Bash calls, so everything below has to run as one call, and the brief has
to exist before it starts.

**Step 2 — one Bash call:**

```bash
BRIEF=/abs/scratch/brief.txt      # written in step 1
OUT=/abs/assets/hero.png
PROVIDER=codex                    # codex | agy | grok | grok-edit  — exactly one
SRC=                              # required only for grok-edit: absolute path of the source image
CODEX_SANDBOX_CHECKED=            # set to 1 ONLY after reading the codex note in the
                                  # codex) branch below; empty keeps that route closed

# Must exit, not return: a `return` inside a helper only leaves the helper, so a
# failed check would fall through into the dispatch. On the way out, sweep the working
# directories — quota failures and rejected output would otherwise leave .imagegen.*
# litter, sometimes holding large partial images, inside the asset tree. The one thing
# never swept is a verified asset that simply could not be published: that is the only
# copy, so it is reported instead.
# Clear everything die() reads: these are ordinary names an exported variable from the
# calling environment could already hold, and an early failure would then sweep an
# inherited $WORK/$TAKE path or take the preservation branch on an inherited $VERIFIED.
WORK= TAKE= ASSET= STAMP= VERIFIED= FINAL= FMT=

# $VERIFIED is set only once the magic-number check has passed, so a partial file left
# by a failed provider — or an output the check REJECTED — is swept, not preserved.
die() {
  echo "$1" >&2
  if [ -n "$VERIFIED" ] && [ -f "$ASSET" ]; then
    echo "verified asset kept at $ASSET" >&2
  else
    rm -rf ${WORK:+"$WORK"} ${TAKE:+"$TAKE"}
  fi
  exit 1
}

# Without this, Ctrl-C or a kill leaves the working directory and a partial image
# behind, since neither die() nor the success path runs. Note bash DEFERS a trap while
# a foreground command is running: cleanup happens once the provider exits, not the
# instant you interrupt, and signalling this shell alone does not stop the provider.
trap 'die "interrupted"' INT TERM

case "$OUT" in /*) ;; *) die "refuse: \$OUT must be absolute";; esac

# Read the brief BEFORE creating anything, so a typo'd path fails without leaving
# directories behind. This has to precede the mkdir below, not merely the dispatch.
PROMPT=$(cat "$BRIEF") || die "unreadable brief: $BRIEF"
[ -n "$PROMPT" ] || die "empty brief: $BRIEF"

DIR=$(dirname "$OUT")
mkdir -p "$DIR" || die "cannot create $DIR"
# ASSUMPTION: the asset directory is yours alone. Publication cannot be made race-proof
# against another writer — POSIX ln has no portable --no-target-directory, so a directory
# raced into place at $OUT would quietly receive $OUT/asset.png. The mode-bit test below
# is a cheap sanity check that catches the obvious case; it is NOT proof, since it does
# not inspect ACLs (macOS or POSIX.1e), which can grant another account write access
# while these bits stay clear. If you cannot vouch for the directory, do not publish
# into it — and note that anyone who can write it controls its contents with or
# without this script.
# Fail CLOSED: a discarded find(1) failure — no find on PATH, -perm rejected, the
# directory unreadable — produces the same empty output as a private directory, so
# silence alone must not be read as proof. Only a find that EXITED 0 and printed
# nothing counts; stderr is folded into the capture so a warning cannot pass as clean.
PERM=$(find "$DIR" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) -print 2>&1) \
  || die "cannot inspect $DIR (find: ${PERM:-no output}) — refusing to publish"
[ -z "$PERM" ] || die "refuse: $DIR is not provably private (find: $PERM)"
# -e alone returns false for a dangling symlink, which a provider would then write through
[ -e "$OUT" ] || [ -L "$OUT" ] && die "refuse: $OUT exists — use a versioned sibling (hero-v2.png)"

# $WORK goes in the system temp dir, NOT beside $OUT. Verified: with $WORK inside a
# git checkout, `codex exec -s workspace-write -C "$WORK"` still wrote to the
# REPOSITORY ROOT — it resolves its workspace from the enclosing repo, so a workdir
# under your project hands a general-purpose agent write access to the whole checkout.
# Outside any repo there is nothing to discover, and the empty cwd holds nothing of
# yours. The verified file is copied out afterwards, by you.
WORK=$(mktemp -d) || die "mktemp failed"
# mktemp honours $TMPDIR, which could itself sit inside a checkout — so don't assume,
# check. Fail CLOSED: only an explicit "not a git repository" counts as proof. A
# nonzero status alone does not, because GIT_DIR / GIT_CEILING_DIRECTORIES in the
# environment, or a missing git, produce failures that would otherwise read as "safe".
command -v git >/dev/null 2>&1 || die "git not found — cannot prove \$WORK is outside a repository"
# LC_ALL=C so the "not a git repository" match below survives a localized git.
GITOUT=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CEILING_DIRECTORIES \
  LC_ALL=C git -C "$WORK" rev-parse --show-toplevel 2>&1); GITRC=$?
if [ "$GITRC" -eq 0 ]; then
  die "refuse: \$TMPDIR is inside a git checkout ($GITOUT) — codex would take that repo as its workspace"
elif ! printf '%s' "$GITOUT" | grep -qi 'not a git repository'; then
  die "cannot prove \$WORK is outside a repository (git said: $GITOUT)"
fi
ASSET="$WORK/asset.png"; STAMP="$WORK/.start"

# Grok reports a path instead of saving for you; that reply is a claim, not proof —
# it can read your disk, so it could name any image on it. Resolve the path with
# `cd -P` (a lexical prefix test is defeated by `.../sessions/../../secret.png`),
# require it inside grok's own session output, and require it to postdate $STAMP.
grok_take() {   # sets $ASSET (and $TAKE, for cleanup) to a copy the provider cannot reach
  local root workr gen dir
  # Grok files its session output under the URL-encoded RESOLVED cwd, so a unique $WORK
  # gives this dispatch a private subtree. Scoping to it — not to all of ~/.grok/sessions —
  # is what stops a concurrent grok session's image from being picked up.
  root=$(cd -P "$HOME/.grok/sessions" 2>/dev/null && pwd -P) || { echo "no grok session root"; return 1; }
  workr=$(cd -P "$WORK" 2>/dev/null && pwd -P) || return 1
  root="$root/$(printf '%s' "$workr" | sed 's|/|%2F|g')"
  gen=$(printf '%s' "$1" | grep -oE '/[^[:space:]]+\.(png|jpe?g)' | tail -1)
  # An empty reply is the common failure (quota, error) — without this, dirname ""
  # yields "." and the check would silently resolve against the current directory.
  [ -n "$gen" ] || { echo "grok returned no path (quota exhausted? rerun with 2>&1 to see): $1"; return 1; }
  dir=$(cd -P "$(dirname "$gen")" 2>/dev/null && pwd -P) || { echo "grok reported no usable path: $1"; return 1; }
  gen="$dir/$(basename "$gen")"
  case "$gen" in "$root"/*) ;; *) echo "not a grok session output: $gen"; return 1;; esac
  [ -f "$gen" ] && [ ! -L "$gen" ] || { echo "not a regular file: $gen"; return 1; }
  [ -n "$(find "$gen" -newer "$STAMP" -print -quit 2>/dev/null)" ] || { echo "stale, not from this run: $gen"; return 1; }
  # Never copy into $WORK: the provider could write there, so any check-then-cp on a
  # path it knows is a race it can win with a symlink. Copy into a directory created
  # AFTER the provider exited, whose name it never saw.
  TAKE=$(mktemp -d "$(dirname "$OUT")/.imagegen-take.XXXXXX") || { echo "mktemp failed"; return 1; }
  ASSET="$TAKE/asset.png"
  cp "$gen" "$ASSET"
}

# Exactly ONE provider runs. A failed dispatch stops here: a CLI can exit non-zero
# after leaving a partial-but-recognizable image behind, which the magic-number check
# below would happily accept.
case "$PROVIDER" in

codex)
  # Fail CLOSED unless you have checked the config yourself. Verified on this machine:
  # with `[projects."/"] trust_level = "trusted"` in codex's config, BOTH
  # -s workspace-write AND -s read-only wrote a file into an unrelated git checkout —
  # the flag below was decoration. Sniffing the TOML for that entry is not a boundary
  # (quoting, whitespace, dotted keys and `sandbox_workspace_write.writable_roots` all
  # evade a grep), so this asks for an explicit acknowledgement instead.
  [ -n "$CODEX_SANDBOX_CHECKED" ] || die "refuse: codex route is closed until you set CODEX_SANDBOX_CHECKED=1 at the top of this block, after confirming ${CODEX_HOME:-\$HOME/.codex}/config.toml neither trusts \"/\" nor widens writable_roots. Or use PROVIDER=agy."
  # needs </dev/null and --skip-git-repo-check outside a git repo
  codex exec -s workspace-write -C "$WORK" --skip-git-repo-check \
    "Use the imagegen skill to create: $PROMPT. Copy the final file to $ASSET. Reply with only the absolute path." </dev/null \
    || die "codex dispatch failed" ;;

agy)    # no --cwd; it inherits the process cwd, so enter $WORK in a subshell
  ( cd "$WORK" && agy -p "Use generate_image to create: $PROMPT. Save it to $ASSET. Reply with only the absolute path." \
    --sandbox --add-dir "$WORK" --print-timeout 5m ) \
    || die "agy dispatch failed" ;;

grok|grok-edit)
  # grok needs NO shell: image_gen writes into its own session dir and reports the
  # path, so allow exactly one tool and do the copy yourself.
  # Preflight BEFORE spending balance: grok_take's session-root encoder maps only `/`,
  # while a real URL encoder would also touch space, %, #, ? and non-ASCII — so an
  # unsupported $HOME or workdir could never validate. Grok-only; codex and agy never
  # see this path, so logo@2x.png is fine for them.
  case "$HOME$(cd -P "$WORK" && pwd -P)" in
    *[!A-Za-z0-9/._-]*) die "grok needs [A-Za-z0-9/._-] in \$HOME and \$OUT's directory" ;;
  esac
  : > "$STAMP" || die "cannot create $STAMP"   # per invocation: a retry must not accept the previous image
  if [ "$PROVIDER" = grok-edit ]; then
    # absolute, or image_edit resolves it against --cwd "$WORK" and finds nothing
    case "$SRC" in /*) ;; *) die "grok-edit needs an absolute \$SRC";; esac
    [ -f "$SRC" ] || die "no such source: $SRC"
    RAW=$(grok -p "Use image_edit on the image at $SRC: $PROMPT, keep everything else identical. Do not copy or move any files. Reply with only the absolute path of the file image_edit produced." \
      --sandbox workspace --permission-mode default --allow image_edit --disable-web-search --cwd "$WORK") || die "grok dispatch failed"
  else
    RAW=$(grok -p "Use image_gen to create: $PROMPT. Do not copy or move any files. Reply with only the absolute path of the file image_gen produced." \
      --sandbox workspace --permission-mode default --allow image_gen --disable-web-search --cwd "$WORK") || die "grok dispatch failed"
  fi
  # the reply is prose + path on one line; take the last path-looking token, never the whole reply
  grok_take "$RAW" || die "grok output rejected" ;;

*) die "unknown \$PROVIDER: $PROVIDER" ;;
esac

# Take the result out of the provider's reach, onto $OUT's filesystem (link() cannot
# cross devices). $TAKE is created AFTER the provider exited and it never saw the name,
# so there is no path here it can have raced. grok_take already did this; for codex and
# agy the file is still sitting in $WORK.
if [ -z "$TAKE" ]; then
  [ -f "$ASSET" ] && [ ! -L "$ASSET" ] || die "no regular asset produced"
  TAKE=$(mktemp -d "$(dirname "$OUT")/.imagegen-take.XXXXXX") || die "mktemp failed"
  cp "$ASSET" "$TAKE/asset.png" || die "could not take the asset out of $WORK"
  ASSET="$TAKE/asset.png"
fi
rm -rf "$WORK"; WORK=

# file(1) succeeds on missing paths, on text, and through symlinks — none of which is
# an image. Require a real regular file AND a raster magic number.
[ -f "$ASSET" ] && [ ! -L "$ASSET" ] || die "no regular asset produced"
# Providers ignore the extension you ask for and are not even consistent between runs
# — the same agy prompt returned PNG once and JPEG the next time. Never publish under a
# lying extension (consumers pick decoding and transparency from the filename), but do
# not throw away a good image either: publish under its TRUE format and say so.
case "$(file -b "$ASSET")" in
  PNG\ image*)  FMT=png ;;
  JPEG\ image*) FMT=jpg ;;
  *) die "not a raster image: $(file -b "$ASSET")" ;;
esac
# file(1) reads the header only, so a 1x1 placeholder passes it. Require real
# dimensions as a cheap floor. This still cannot prove the PIXELS are what you asked
# for — a truncated body or a valid-but-wrong image passes; look at the result.
# tail, not head: JPEG's file(1) line puts JFIF `density 300x300` BEFORE the pixel
# dimensions, so head would read the density and pass a 1x1 image. Verified on both
# formats: PNG "…, 1024 x 1024, …" and JPEG "…density 300x300, …, 1024x1024, …".
DIMS=$(file -b "$ASSET" | grep -oE '[0-9]+ ?x ?[0-9]+' | tail -1)
IMGW=${DIMS%%[ x]*}; IMGH=${DIMS##*[ x]}   # BOTH sides: 512x1 is a placeholder too

VERIFIED=1    # a decodable image of a real type: worth keeping even if what follows fails

# Only a degenerate result is rejected. Any larger floor guesses at your intent — 16x16
# favicons and 8x8 sprites are legitimate asks — so this catches the 1-pixel placeholder
# and nothing else. $VERIFIED is already set, so even this rejection keeps the file for
# you to look at rather than deleting it.
[ "${IMGW:-0}" -ge 2 ] 2>/dev/null && [ "${IMGH:-0}" -ge 2 ] 2>/dev/null \
  || die "degenerate image (${DIMS:-no dimensions})"
case "$OUT" in *.png|*.jpg|*.jpeg) FINAL="${OUT%.*}.$FMT" ;; *) FINAL="$OUT.$FMT" ;; esac
[ "$FINAL" = "$OUT" ] || echo "note: provider returned $FMT — publishing as $FINAL"
[ -e "$FINAL" ] || [ -L "$FINAL" ] && die "refuse: $FINAL exists — use a versioned sibling"

# Publish with ln, not mv. link() fails with EEXIST atomically, so a concurrent
# writer can never be clobbered — whereas `mv -n` is a check-then-rename on some
# implementations and loses that race. $ASSET now lives in $TAKE, created beside $OUT
# and therefore on the same filesystem — that is why the hard link works. ($WORK is in
# the system temp dir and may be on another device; nothing is linked from there.)
ln "$ASSET" "$FINAL" || die "could not publish to $FINAL (already exists?)"
# ln into a DIRECTORY (or a symlink to one) succeeds by creating $FINAL/asset.png, so
# confirm a regular file landed at $FINAL BEFORE discarding the copy that is still ours.
[ -f "$FINAL" ] || die "ln did not produce a file at $FINAL (a directory there?)"
rm -f "$ASSET"
rm -rf "$WORK" ${TAKE:+"$TAKE"}    # the grok path puts $ASSET in its own take dir
```

## Threat model — what the flags do and don't confine

Each command runs a **general-purpose coding agent**, not an image endpoint. Be
precise about what the sandbox flags buy:

| | Confines |
|---|---|
| codex `-s workspace-write` | writes, to the workspace — **but only if codex's project trust says so.** Verified on this machine: with `[projects."/"] trust_level = "trusted"` in `~/.codex/config.toml`, both `-s workspace-write` AND `-s read-only` happily wrote a file into an unrelated git checkout. Check that entry before treating the flag as a boundary |
| agy `--sandbox` | terminal execution; `--add-dir` *adds* a writable dir, it does not revoke access to the cwd |
| grok `--sandbox workspace` | writes, to cwd + temp + `~/.grok` |
| grok `--permission-mode default --allow image_gen` | **the default decision for tools this command did not name.** `--allow` adds auto-approval, it does not deny anything else, and pinning the mode only overrides the *default* — per-tool allow rules already configured in `~/.grok/config.toml` still load and still apply. So this narrows what the flags themselves grant; it does not audit your config. Read-only tools and read-only shell run regardless |

Grok still comes out tightest on writes: it needs no shell to save, so nothing
in these commands grants it one. Never substitute `--always-approve` (auto-approves
*every* tool — a general-purpose agent with shell on your machine) and never
re-add a `Bash(cp *)` grant to "help it save" — it does not need to save, and
that rule would reach every path the write sandbox allows, including `~/.grok`.
If your `~/.grok/config.toml` carries broad allow rules, these commands inherit
them; that file is operator-owned and worth reading once.

**No profile confines reads, and none can confine network** — the image tool
is a cloud API call, so egress is inherent to the feature. Treat every dispatch
as "this agent can read what it can reach and talk to a server." Beyond grok's
allow-list, the remaining controls are procedural — real, but not enforced:

1. **The brief is always Claude-authored.** Never place scraped copy, issue
   bodies, page content, or raw user text in `$BRIEF`. Summarize it yourself.
2. **Dispatch from an empty `mktemp -d`**, never a checkout holding secrets,
   `.env` files, or customer data, and never the asset directory itself. For
   codex and agy — which do save the file themselves — an empty cwd is what
   keeps their write scope free of anything of yours to overwrite.
3. **`--disable-web-search` on grok** removes its web fetch tool; the brief
   already carries any facts, so nothing is lost.
4. **Verify the output** (below) — a wrong or fabricated file is the failure
   mode you will actually hit.

Dropping a sandbox flag to "make it work" is not a fix; it removes the one
write confinement you have.

## Why the verification in that block is not optional

The reply is not evidence. Verification happens on `$ASSET` — inside the fresh
working directory for codex and agy, inside the post-dispatch take directory for
grok — *before* anything is published to `$OUT`. Those directories were empty
moments earlier, so a file existing there at all is evidence this dispatch
produced it. Verifying `$OUT` instead would prove nothing when something already
lived at that path: a provider that fails without writing leaves the old file
passing the check, and you ship the previous asset as the new one.

What it catches: a missing file, text or SVG dressed as an image, a symlink, a
type that contradicts the extension, a placeholder-sized image. What it cannot
catch: a truncated body, or a perfectly valid image of the wrong thing. **Look
at the result** — `Read` the published file — before wiring it into a build.

This is not ceremony. Both failures below were observed:

- **The agent will claim success it didn't achieve.** With shell denied, Grok
  could not copy the generated file, so it hand-wrote an SVG, named it `.png`,
  and replied with the path as if it had worked.
- **The extension lies, and inconsistently.** `image_edit` asked for
  `sb-edit.png` returned a JPEG; the *same* agy prompt returned PNG on one run
  and JPEG on the next. So the block reads the real type from `file` and
  publishes under it — ask for `hero.png` and you may get `hero.jpg`, with a
  printed note. **Read the final path from that note; don't assume `$OUT`.**

## Gotchas

- **codex hangs without `</dev/null`** — it waits on stdin.
- **codex outside a git repo** fails with `Not inside a trusted directory`; add `--skip-git-repo-check`.
- **codex saves to `$CODEX_HOME/generated_images/` first.** The prompt must say *copy to `$OUT`*, or the asset is left outside the project.
- **agy needs `toolPermission` looser than `strict`** in `~/.gemini/antigravity-cli/settings.json`; under `strict` the image tool is auto-denied in headless mode ("a tool required the `command` permission"). Keep `--sandbox`.
- **Don't deny shell to codex or agy.** Both save by copying a file; block that and you get the fabrication above, not a clean failure — their sandbox flag is the control, not a tool denylist. Grok is the exception: it never needs shell, which is why its commands grant none.
- **Grok has a spendable balance.** When it runs out the CLI prints `API error (status 402 …): Grok Build usage balance exhausted` on **stderr** and stdout is empty — so a dispatch that swallows stderr looks like a silent no-op. Route to codex/agy; only `image_edit` has no substitute.
- **Two minutes per image, one dispatch per image.** Each command carries a single `$OUT`, so an 8-section page is 8 dispatches and ~15 minutes. Budget for it up front; there is no batch form.
- **Quoting:** the brief-file `$PROMPT` above is mandatory, not stylistic — it is the only form that survives a brief containing quotes, backticks, or `$`. Do not "simplify" it back into the command literal or a heredoc.

## Wiring

`imagegen-frontend-web`, `imagegen-frontend-mobile`, and `image-to-code` are
prompt-direction skills written for hosts that already have an image tool.
They say *"if image generation is available"* — with this skill, it is. Read the
direction skill for the brief, then dispatch each image through a command above.

## Video

**Not available.** agy has no video tool; Codex's `imagegen` is raster-only;
Grok has `image_to_video` / `reference_to_video` but the call fails on this
account:

> Zero Data Retention teams must provide output.upload_url for video generation.

The tool exposes no `upload_url` parameter, so unblocking it means disabling ZDR
for the Grok team — a retention-policy change, not a wiring change. Don't do
that for b-roll. For website motion use `motion-foundations` / `motion-patterns`
(CSS/Motion beats a generated mp4 for UI). If real video is ever needed, the
escape hatch is `agent-tools` (inference.sh → Veo), which bills per call.
