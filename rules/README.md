# Rules

A small, hand-written canon of always-loaded rules under `common/`. These are
language-agnostic invariants and principles, installed into `~/.claude/rules/`
so they apply to every project.

```
rules/
├── common/
│   ├── investigate-before-acting.md   # read / reproduce / scope before acting
│   ├── validate-before-building.md    # evidence before building; reach for what exists
│   ├── tool-discipline.md             # right tool; question vs. instruction
│   └── policy.md                      # non-negotiable invariants (secrets, injection, …)
└── install.sh
```

Everything else lives where it belongs, not here:

- **Procedural guidance** → on-demand skills (`skills/`).
- **Mechanically checkable rules** → the hook gates (defense-in-depth: secrets,
  for example, are both an ambient invariant in `policy.md` *and* enforced by
  the seatbelt / litmus scanners).

Keeping the always-loaded set to these four files keeps the agent's constitution
tiny and auditable.

## Installation

```bash
./install.sh          # replaces ~/.claude/rules/common/ with the canon
```

`install.sh` does a *clean* install of `common/` — it stages the copy and swaps
it in atomically, guards against writing outside `$HOME`, and won't delete its
own source. Prefer it.

If you copy by hand instead, note this is **additive** (it won't remove retired
files from an older install — re-run `./install.sh` for a clean replace):

```bash
mkdir -p ~/.claude/rules/common
cp -r rules/common/. ~/.claude/rules/common/
```

**Upgrading from the old multi-language ruleset?** `install.sh` cleanly replaces
`common/`, but the retired language packs live in separate
`~/.claude/rules/<language>/` directories it never touches. Delete any you
previously installed (for example `~/.claude/rules/typescript`) so they stop
being loaded.

## Rules vs Skills

- **Rules** are the short, always-loaded invariants and principles here.
- **Skills** (`skills/`) provide deep, on-demand reference material for specific
  tasks (e.g. `python-patterns`, `golang-testing`).

Rules tell you *what* to do; skills tell you *how*.

## History

This directory previously vendored ~70 ECC rule files across a `common/` layer
and eleven language-specific packs (typescript, python, golang, …). Those were
retired: a synced, eager-loaded ruleset is a prompt-supply-chain surface into
the agent's constitution, and most of it merely restated training data. The four
files above are the invariants that must stay **ambient** — design-time, with no
scannable artifact — so they cannot be relocated to a skill or a gate.
