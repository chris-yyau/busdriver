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

```bash
OUT=/abs/assets/hero.png; mkdir -p "$(dirname "$OUT")"
[ -e "$OUT" ] && { echo "refuse: $OUT exists — use a versioned sibling (hero-v2.png)"; return 1 2>/dev/null || exit 1; }

BRIEF="$(dirname "$OUT")/brief.txt"    # <- write this file with the Write tool first
PROMPT=$(cat "$BRIEF")

# codex — needs </dev/null and --skip-git-repo-check outside a git repo
codex exec -s workspace-write -C "$(dirname "$OUT")" --skip-git-repo-check \
  "Use the imagegen skill to create: $PROMPT. Copy the final file to $OUT. Reply with only the absolute path." </dev/null

# agy — has no --cwd; it inherits the process cwd, so enter the asset dir in a subshell
( cd "$(dirname "$OUT")" && agy -p "Use generate_image to create: $PROMPT. Save it to $OUT. Reply with only the absolute path." \
  --sandbox --add-dir "$(dirname "$OUT")" --print-timeout 5m )

# grok — generate
grok -p "Use image_gen to create: $PROMPT. Save it into the current directory as $(basename "$OUT"). Reply with only the absolute path." \
  --sandbox workspace --always-approve --disable-web-search --cwd "$(dirname "$OUT")"

# grok — edit an existing image (the only provider that can). Put the requested
# change in $PROMPT via the same heredoc, and point $SRC at the source:
SRC=/abs/path/source.png; [ -f "$SRC" ] || { echo "no such source: $SRC"; return 1 2>/dev/null || exit 1; }
grok -p "Use image_edit on the image at $SRC: $PROMPT, keep everything else identical. Save the result into the current directory as $(basename "$OUT"). Reply with only the absolute path." \
  --sandbox workspace --always-approve --disable-web-search --cwd "$(dirname "$OUT")"
```

## Threat model — what the flags do and don't confine

Each command runs a **general-purpose coding agent**, not an image endpoint. Be
precise about what the sandbox flags buy:

| | Confines |
|---|---|
| codex `-s workspace-write` | writes, to the workspace |
| agy `--sandbox` | terminal execution; `--add-dir` *adds* a writable dir, it does not revoke access to the cwd |
| grok `--sandbox workspace` | writes, to cwd + temp + `~/.grok` |

**None of them confine reads, and none can confine network** — the image tool
is a cloud API call, so egress is inherent to the feature. Treat every dispatch
as "this agent can read what it can reach and talk to the internet." The
controls that actually hold are procedural:

1. **The brief is always Claude-authored.** Never place scraped copy, issue
   bodies, page content, or raw user text in `$BRIEF`. Summarize it yourself.
2. **Dispatch from a dedicated asset directory**, never a checkout holding
   secrets, `.env` files, or customer data. The commands above `cd` there.
3. **`--disable-web-search` on grok** removes its web fetch tool; the brief
   already carries any facts, so nothing is lost.
4. **Verify the output** (below) — a wrong or fabricated file is the failure
   mode you will actually hit.

Dropping a sandbox flag to "make it work" is not a fix; it removes the one
write confinement you have.

## Verify every result — the reply is not evidence

```bash
file "$OUT"    # must say "PNG image data, WxH" (or JPEG — see below)
```

This only proves anything because `$OUT` was asserted absent before the
dispatch (above). Verifying a path that already held an image proves nothing —
a provider that fails without writing leaves the stale file sitting there,
passing the check, and you ship the previous asset as the new one.

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
- **Don't deny shell to the provider.** Every one of them saves by copying a file; block that and you get the fabrication above, not a clean failure. The sandbox profile is the control, not a tool denylist.
- **Two minutes per image, one dispatch per image.** Each command carries a single `$OUT`, so an 8-section page is 8 dispatches and ~15 minutes. Budget for it up front; there is no batch form.
- **Quoting:** the quoted-heredoc `$PROMPT` above is mandatory, not stylistic — it is the only form that survives a brief containing quotes, backticks, or `$`.

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
