---
name: zenmux
description: >-
  Reach the ZenMux gateway for a capability Claude Code does not have natively —
  image generation, speech/TTS, transcription, video, embeddings, rerank, or a
  model from another vendor — using one key across many providers. Use when the
  user says zenmux, or asks for a modality the local tools cannot produce. NOT
  the default lane for text or code: opencode-go owns that routing.
compatibility: >-
  Requires a billing credential in $ZENMUX_API_KEY. The model catalogs below are
  public and need no key — only the generation calls do. See "Where the key
  lives" for the placement trade-off; do not echo, log, or commit the value.
---

# ZenMux

One gateway over many vendors' models, three protocols, one key. Its value here
is **coverage of modalities the local subscription tools don't have** — not text,
which already routes through opencode-go.

## Never hardcode a model id — and never trust one catalog

ZenMux exposes a **separate catalog per protocol**, and each one is a partial
view. Query all three and union them:

| Protocol | Catalog | List key | Modality field |
|---|---|---|---|
| OpenAI-compatible | `https://zenmux.ai/api/v1/models` | `data` | `output_modalities` |
| Anthropic | `https://zenmux.ai/api/anthropic/v1/models` | `data` | `output_modalities` |
| Vertex AI | `https://zenmux.ai/api/vertex-ai/v1beta/models` | `models` | `outputModalities` |

```bash
python3 - speech <<'PY'          # ← argument = the capability you need
import json, sys, urllib.request
CATALOGS = [("https://zenmux.ai/api/v1/models", "data", "output_modalities"),
            ("https://zenmux.ai/api/anthropic/v1/models", "data", "output_modalities"),
            ("https://zenmux.ai/api/vertex-ai/v1beta/models", "models", "outputModalities")]
want = sys.argv[1].lower() if len(sys.argv) > 1 else ""
seen, hits, reached = {}, [], 0
for url, key, field in CATALOGS:
    try:
        entries = json.load(urllib.request.urlopen(url, timeout=30))[key]
        reached += 1
    except Exception as e:            # one dead catalog must not hide the other two
        print(f"! {url} unavailable: {e}", file=sys.stderr)
        continue
    for m in entries:
        outs = [o.lower() for o in (m.get(field) or [])]
        for o in outs:
            seen[o] = seen.get(o, 0) + 1
        if want and want in outs:
            hits.append((m.get("id") or m.get("name"), tuple(outs)))
if reached == 0:                      # every catalog down != "ZenMux has nothing"
    sys.exit("all catalogs unreachable — discovery failed, draw no conclusion")
print(f"reached {reached}/{len(CATALOGS)} catalogs")
print("output_modalities present right now:", dict(sorted(seen.items())))
for mid, outs in sorted(set(hits)):
    print(f"  {mid}  -> {list(outs)}")
PY
```

No key needed. Two deliberate properties, both of which cost a round of review to
get right:

- **It prints the modality vocabulary before filtering.** Do not assume which
  strings this field uses — published docs and the live API have disagreed, and
  guessing a value that is not in use returns zero rows, which reads exactly like
  "ZenMux cannot do this". Run it once with no argument to see what exists, then
  filter.
- **A failing catalog is reported and skipped, not fatal — but all three failing
  is.** These are independent endpoints, so aborting on the first timeout would
  hide the other two. Total failure exits non-zero, because an empty result from
  a dead network must never be read as "ZenMux does not offer this".

### Field names differ per catalog — do not assume one shape

Entries carry more than modality, but the OpenAI/Anthropic catalogs and the
Vertex one use **different key names**, so code written against one raises
`KeyError` or silently reads `None` on the other:

| | OpenAI + Anthropic | Vertex AI |
|---|---|---|
| id | `id` | `name` |
| modality in/out | `input_modalities` / `output_modalities` | `inputModalities` / `outputModalities` |
| size | `context_length` | `inputTokenLimit` / `outputTokenLimit` |
| reasoning | `capabilities.reasoning` (bool) | `thinking` (bool) |
| price | `pricings` | `pricings` |

Only `pricings` and the publish timestamp are common. Always use `.get()` with a
per-catalog fallback, as the query above does for the modality field.

## Categories

`output_modalities` values seen in the API: `text`, `image`, `speech`,
`transcription`, `embeddings`. The web catalog at <https://zenmux.ai/models>
additionally groups **Audio**, **Video**, and **Rerank**.

| Need | Filter on | Protocol / endpoint |
|---|---|---|
| Text / chat | `text` | `POST https://zenmux.ai/api/v1/chat/completions` (also Anthropic + Vertex shapes) |
| **Reasoning** | `text` **plus** `capabilities.reasoning == true` (Vertex: `thinking`) — measured 2026-08-14, 43 text-output models have it **false**, so filtering on `text` alone will hand you a non-reasoning model | same endpoint |
| Image generation / edit | `image` | Same base URL; several are also on the Vertex endpoint |
| Text → speech (TTS) | `speech` | OpenAI-compatible |
| Speech → text | `transcription` | OpenAI-compatible; takes `audio` input |
| Embeddings | `embeddings` | `/v1/embeddings` |
| Rerank | *(not in the three catalogs — see below)* | check <https://zenmux.ai/models> |
| Video generation | *(not in the three catalogs — see below)* | Vertex AI protocol: async `generate_videos()` → poll `operations.get()` → `operation.response.generated_videos` |

Auth on every authenticated call: `Authorization: Bearer $ZENMUX_API_KEY`.

## Where the key lives — a real trade-off, not a recommendation

`$ZENMUX_API_KEY` is a **billing** credential, so placement is a choice between
reach and exposure, and neither option is free:

| Placement | Consequence |
|---|---|
| `~/.zshrc` | Interactive shells only. Agent-spawned and script shells are non-interactive, so they get a 401 — verified, `zsh -c env` does not see it. |
| `~/.zshenv` | Every zsh sees it, which is what makes this skill usable from an agent — **and** it exports a billing credential into every descendant process, including unrelated agents, hooks, and CI-ish commands. |
| Per-invocation | Narrowest exposure, no persistence — but you must supply it each time. |

`.zshenv` is what makes agent-driven use work at all; that reach *is* the
exposure. If that trade is unacceptable for your account, keep the key out of the
environment and pass it per invocation instead — the discovery query above needs
no key, so only the generation calls are affected.

Never echo, log, or commit the value; a leaked key here bills real money.

## The catalogs are incomplete — absence is not proof

Measured 2026-08-14: the three catalogs union to **170 distinct models**, while
the web catalog advertises **191**. Image and embeddings matched exactly; speech,
transcription, video, and rerank were all **under-reported or entirely missing**
from the API while the site listed them.

So: a capability missing from an API query is **not** evidence ZenMux lacks it.
Check <https://zenmux.ai/models> before telling the user something is unavailable.
This bit once already — a single-catalog query showed zero speech models and the
conclusion "ZenMux has no TTS" was wrong.

## Boundaries

- **Not for text or code routing.** opencode-go is the configured lane; sending
  text here is a cost and consistency regression, not a fallback.
- **Prefer subscription tools for images.** `imagegen` dispatches to Codex, agy,
  and Grok at zero marginal cost. ZenMux bills per call — reach for it when those
  cannot produce what is needed, not by default.
- **Third-party transmission.** Every prompt sent here leaves the account for an
  external gateway. Apply the same provenance and confidentiality check as any
  other external dispatch surface.
