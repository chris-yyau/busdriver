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

Dispatch from the asset directory, not from a checkout — see Threat model.

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

# Must exit, not return: a `return` inside a helper only leaves the helper, so a
# failed check would fall through into the dispatch.
die() { echo "$1" >&2; exit 1; }

case "$OUT" in /*) ;; *) die "refuse: \$OUT must be absolute";; esac
mkdir -p "$(dirname "$OUT")"
# ASSUMPTION: the asset directory is yours alone. Publication cannot be made race-proof
# against another writer — POSIX ln has no portable --no-target-directory, so a directory
# raced into place at $OUT would quietly receive $OUT/asset.png. The mode-bit test below
# is a cheap sanity check that catches the obvious case; it is NOT proof, since it does
# not inspect ACLs (macOS or POSIX.1e), which can grant another account write access
# while these bits stay clear. If you cannot vouch for the directory, do not publish
# into it — and note that anyone who can write it controls its contents with or
# without this script.
[ -n "$(find "$(dirname "$OUT")" -maxdepth 0 \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ] \
  && die "refuse: $(dirname "$OUT") is group- or world-writable"
# -e alone returns false for a dangling symlink, which a provider would then write through
[ -e "$OUT" ] || [ -L "$OUT" ] && die "refuse: $OUT exists — use a versioned sibling (hero-v2.png)"

# Dispatch into a fresh empty directory, never the asset directory. The provider's
# write sandbox is scoped to its cwd, so an empty cwd means there is nothing of
# yours in reach to overwrite. YOU move the verified file into place afterwards.
# $WORK sits BESIDE $OUT, not in /tmp, so the final mv is a same-filesystem rename
# (atomic). A cross-device mv is copy-then-delete and can leave a partial $OUT that
# then blocks every retry.
# Read the brief BEFORE creating anything, so a typo'd path fails without leaving
# empty .imagegen.* directories littered beside your assets.
PROMPT=$(cat "$BRIEF") || die "unreadable brief: $BRIEF"
[ -n "$PROMPT" ] || die "empty brief: $BRIEF"

WORK=$(mktemp -d "$(dirname "$OUT")/.imagegen.XXXXXX") || die "mktemp failed"
ASSET="$WORK/asset.png"; STAMP="$WORK/.start"

# Grok reports a path instead of saving for you; that reply is a claim, not proof —
# it can read your disk, so it could name any image on it. Resolve the path with
# `cd -P` (a lexical prefix test is defeated by `.../sessions/../../secret.png`),
# require it inside grok's own session output, and require it to postdate $STAMP.
grok_take() {   # sets $ASSET to a copy the provider cannot reach
  local root workr gen dir take
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
  take=$(mktemp -d "$(dirname "$OUT")/.imagegen-take.XXXXXX") || { echo "mktemp failed"; return 1; }
  ASSET="$take/asset.png"
  cp "$gen" "$ASSET"
}

# Exactly ONE provider runs. A failed dispatch stops here: a CLI can exit non-zero
# after leaving a partial-but-recognizable image behind, which the magic-number check
# below would happily accept.
case "$PROVIDER" in

codex)  # needs </dev/null and --skip-git-repo-check outside a git repo
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

# file(1) succeeds on missing paths, on text, and through symlinks — none of which is
# an image. Require a real regular file AND a raster magic number.
[ -f "$ASSET" ] && [ ! -L "$ASSET" ] || die "no regular asset produced"
# Providers ignore the extension you ask for — image_edit returned a JPEG named .png.
# Require the magic number to match $OUT's extension; consumers pick decoding and
# transparency behaviour from the filename, so a mislabelled file is a live bug.
case "$(file -b "$ASSET")___${OUT##*.}" in
  PNG\ image*___png|JPEG\ image*___jpg|JPEG\ image*___jpeg) ;;
  *) die "format/extension mismatch: $(file -b "$ASSET") for .${OUT##*.} — rename \$OUT or regenerate";;
esac

# Publish with ln, not mv. link() fails with EEXIST atomically, so a concurrent
# writer can never be clobbered — whereas `mv -n` is a check-then-rename on some
# implementations and loses that race. $WORK is on the same filesystem as $OUT
# (that is why it sits beside it), so the hard link always works.
ln "$ASSET" "$OUT" || die "could not publish to $OUT (already exists?) — asset kept at $ASSET"
# ln into a DIRECTORY (or a symlink to one) succeeds by creating $OUT/asset.png, so
# confirm a regular file landed at $OUT BEFORE discarding the copy that is still ours.
[ -f "$OUT" ] || die "ln did not produce a file at $OUT (a directory there?) — asset kept at $ASSET"
rm -f "$ASSET"
rm -rf "$WORK" "$(dirname "$ASSET")"    # the grok path puts $ASSET in its own take dir
```

## Threat model — what the flags do and don't confine

Each command runs a **general-purpose coding agent**, not an image endpoint. Be
precise about what the sandbox flags buy:

| | Confines |
|---|---|
| codex `-s workspace-write` | writes, to the workspace |
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

The reply is not evidence. Verification happens in `$WORK`, before the `mv`:
that directory was empty a moment ago, so a
file existing there at all is evidence this dispatch produced it. Verifying
`$OUT` instead proves nothing when something already lived at that path — a
provider that fails without writing leaves the old file passing the check, and
you ship the previous asset as the new one.

This is not ceremony. Both failures below were observed:

- **The agent will claim success it didn't achieve.** With shell denied, Grok
  could not copy the generated file, so it hand-wrote an SVG, named it `.png`,
  and replied with the path as if it had worked.
- **The extension lies.** `image_edit` asked for `sb-edit.png` returned a JPEG
  with a `.png` name. Read the real type from `file` before wiring the asset
  into a build.

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
