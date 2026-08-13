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
import json, sys, time, urllib.request, urllib.parse
PAGE_CAP, TIME_BUDGET = 20, 60      # per catalog: page count, and a start-deadline
# Be precise about what these bound, because a page cap alone bounds almost
# nothing: PAGE_CAP pages x a 30s socket timeout is ~10 minutes for ONE catalog
# at the values above, and grows with any larger cap.
# TIME_BUDGET is checked BEFORE each request, so it caps how long we keep
# STARTING new pages — it is not a total-runtime guarantee. urllib's `timeout`
# is per-socket-operation, so a response that trickles a byte at a time can
# outlive both. Residual accepted for a discovery helper: the realistic failure
# here is a pager that loops, which these do bound. If you need a hard ceiling,
# run it under `timeout 120 python3 - ...`.
CATALOGS = [("https://zenmux.ai/api/v1/models", "data", "output_modalities"),
            ("https://zenmux.ai/api/anthropic/v1/models", "data", "output_modalities"),
            ("https://zenmux.ai/api/vertex-ai/v1beta/models", "models", "outputModalities")]
want = sys.argv[1].lower() if len(sys.argv) > 1 else ""
seen, hits, reached, partial = {}, [], 0, False
for url, key, field in CATALOGS:
    entries, page_url, pages, cat_partial, cursors = [], url, 0, False, set()
    deadline = time.monotonic() + TIME_BUDGET
    # Cursor pagination: only the Anthropic catalog's payload carries `has_more`
    # today (verified live 2026-08-14 — the OpenAI-compatible and Vertex
    # payloads carry no such field), but the loop is generic rather than
    # Anthropic-specific so it stays correct if another catalog starts paging.
    # A live probe with `limit=5` still returned the full 125-row set with
    # `has_more: false`, so ZenMux's Anthropic endpoint does not paginate in
    # practice right now — but the field is part of the documented Anthropic
    # models-list contract this endpoint mirrors, and silently reading only
    # page 1 forever if that changes is exactly the "absence is not evidence
    # of absence" trap this skill exists to warn against. Bounded by PAGE_CAP
    # AND the wall-clock deadline above, so a misbehaving pager cannot hang it.
    # KNOWN RESIDUAL: an ABSENT `has_more` is read as "last page", because that
    # is exactly what the two non-paginating catalogs look like. So a truncated
    # response that DROPS the field is indistinguishable from one that never
    # had it, and would count as fully read. Closing that needs a per-catalog
    # "this one must carry has_more" expectation, which is its own staleness
    # risk. A malformed (non-bool) value IS caught below.
    while page_url and pages < PAGE_CAP and time.monotonic() < deadline:
        pages += 1
        try:
            payload = json.load(urllib.request.urlopen(page_url, timeout=30))
        except Exception as e:            # one dead catalog must not hide the other two
            print(f"! {page_url} unavailable: {e}", file=sys.stderr)
            cat_partial = True            # KEEP earlier pages: a failure on page
            break                         # 3 does not unsee pages 1-2
        page_entries = payload.get(key) if isinstance(payload, dict) else None
        if not isinstance(page_entries, list):  # counted only when usable, so a
            print(f"! {page_url} returned {key} as "
                  f"{type(page_entries).__name__}, not a list", file=sys.stderr)
            cat_partial = True            # schema change cannot masquerade as
            break                         # an empty (but "usable") answer
        entries.extend(page_entries)
        last_id = payload.get("last_id") if isinstance(payload, dict) else None
        more = payload.get("has_more", False)
        if more is False:                   # explicit false, or field absent
            page_url = None                 # (non-paginating catalogs) = done
        elif more is not True:              # present but null/str/int = malformed
            print(f"! {url}: has_more is {type(more).__name__}, not a bool — "
                  f"catalog read is PARTIAL", file=sys.stderr)
            cat_partial = True
            page_url = None
        elif isinstance(last_id, str) and last_id and last_id not in cursors:
            cursors.add(last_id)            # a repeated cursor never advances:
            sep = "&" if "?" in url else "?"  # without this it refetches the SAME
            page_url = f"{url}{sep}after_id={urllib.parse.quote(last_id)}"  # page 50x
        else:                               # no usable / non-advancing cursor
            print(f"! {url}: has_more set but last_id missing, invalid, or "
                  f"repeated — catalog read is PARTIAL", file=sys.stderr)
            cat_partial = True
            page_url = None
    if page_url is not None:                # exited on the page cap or the deadline
        print(f"! {url}: pagination stopped after {pages} page(s) "
              f"(cap or time budget) — catalog read is PARTIAL", file=sys.stderr)
        cat_partial = True
    # `reached` counts FULLY-read catalogs only. Both partial shapes must be
    # excluded, and they exit the loop differently: the cap leaves page_url set,
    # the missing-cursor case clears it. Keying on page_url alone (as the first
    # draft did) let the no-cursor case count as complete — caught by a synthetic
    # payload test, not by review. Hence the explicit per-catalog flag.
    if cat_partial:
        partial = True
    else:
        reached += 1
    for m in entries:
        if not isinstance(m, dict):       # a malformed entry must not abort the rest
            continue
        raw = m.get(field)
        outs = [o.lower() for o in raw if isinstance(o, str)] if isinstance(raw, list) else []
        for o in outs:
            seen[o] = seen.get(o, 0) + 1
        mid = m.get("id") or m.get("name")
        if want and want in outs and isinstance(mid, str) and mid:
            hits.append((mid, tuple(outs)))   # no id => not selectable, so not listed
# ALWAYS print what was actually observed, then exit non-zero if nothing was
# fully read. A model seen on a page that DID return is real positive evidence
# and stays useful even when the read was truncated — only the ABSENCE of a
# capability is unprovable from a partial read. Exiting before printing would
# throw away the half of the result that is still sound.
print(f"fully read {reached}/{len(CATALOGS)} catalogs"
      + ("  (SOME READS PARTIAL — absence below proves nothing)" if partial else ""))
print("output_modalities present right now:", dict(sorted(seen.items())))
for mid, outs in sorted(set(hits)):
    print(f"  {mid}  -> {list(outs)}")
if reached == 0:                      # every catalog down != "ZenMux has nothing"
    sys.exit("no catalog fully read — anything listed above is real, "
             "but absence proves nothing")
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
| Image **generation** | `output_modalities` has `image` | Same base URL; several are also on the Vertex endpoint |
| Image **editing** | `output_modalities` has `image` **and `input_modalities` also has `image`** — output alone does not imply the model accepts an image to edit | same endpoint |
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
