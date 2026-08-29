#!/usr/bin/env python3
"""Property check for `carries_key` — driven by test-disable-all-hooks-r1.sh.

The named fixtures in that suite pin the shapes review actually found. This
covers the space between them: randomly built dict/list nests, to random depth,
half of them carrying the key at a random position, each round-tripped through
`json.dumps`/`json.loads` so the escaped spellings are generated rather than
enumerated (`json.dumps(ensure_ascii=True)` emits `\\uXXXX` for the non-ASCII
sibling keys, which is exactly the evasion the parser-based scan exists to stop).

Exits 0 when every case classified correctly, 1 with the failing case printed.
Seeded from argv[2] when given, so a failure is reproducible.
"""

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scan_disable_all_hooks import KEY, carries_key  # noqa: E402

# Deliberately adjacent to KEY: near-misses must NOT count, or a scan that
# matched loosely would pass this check while flagging innocent documents.
DECOYS = ["disableallhooks", "DisableAllHooks", "disableAllHook", "xdisableAllHooks", "hooks", "é"]


def _leaf(rng, plant):
    """A terminal node: the key with a random value under it, or a bare value."""
    leaf = rng.choice([1, "s", None, True, 1.5])
    return {KEY: leaf} if plant else leaf


def _dict_node(rng, depth, plant):
    node = {}
    for _ in range(rng.randint(1, 4)):
        node[rng.choice(DECOYS)] = build(rng, depth - 1, False)
    if not plant:
        return node
    # Either the key itself, or deeper down one branch — both must be found.
    if rng.random() < 0.5:
        node[KEY] = build(rng, depth - 1, False)
    else:
        node[rng.choice(DECOYS)] = build(rng, depth - 1, True)
    return node


def _list_node(rng, depth, plant):
    items = [build(rng, depth - 1, False) for _ in range(rng.randint(1, 4))]
    if plant:
        items.insert(rng.randrange(len(items) + 1), build(rng, depth - 1, True))
    return items


def build(rng, depth, plant):
    """Build a random JSON document; place KEY exactly where `plant` says."""
    if depth <= 0:
        return _leaf(rng, plant)
    # `not plant` first, so the draw is taken only when it can decide something —
    # a planted branch must keep descending, exactly as the single condition did.
    if not plant and rng.random() < 0.3:
        return _leaf(rng, plant)
    if rng.random() < 0.5:
        return _dict_node(rng, depth, plant)
    return _list_node(rng, depth, plant)


def main(argv):
    rounds = int(argv[1]) if len(argv) > 1 else 400
    seed = int(argv[2]) if len(argv) > 2 else random.randrange(2**32)
    rng = random.Random(seed)

    for _ in range(rounds):
        plant = rng.random() < 0.5
        doc = build(rng, rng.randint(0, 6), plant)
        # Round-trip: the scanner only ever sees decoded documents, and dumping
        # with ensure_ascii generates the \uXXXX spellings rather than listing them.
        decoded = json.loads(json.dumps(doc, ensure_ascii=True))
        if carries_key(decoded) is not plant:
            print(
                "seed=%d planted=%s classified=%s doc=%s"
                % (seed, plant, carries_key(decoded), json.dumps(doc, ensure_ascii=True)[:400]),
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
