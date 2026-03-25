---
name: three-layer-knowledge
description: Three-layer knowledge framework for evaluating technologies and approaches — tried-and-true vs new-and-hyped vs first-principles
targets: busdriver:brainstorming, busdriver:writing-plans
type: supplement
source: gstack shared infrastructure
added: 2026-03-24
---

# Three-Layer Knowledge Framework

> Load alongside `busdriver:brainstorming` and `busdriver:writing-plans` when evaluating technology choices.

## The Three Layers

### Layer 1: Tried and True
Established solutions with years of production use, large communities, and known failure modes.

- **Trust level:** High — default to these unless there's a reason not to
- **Examples:** PostgreSQL, Redis, React, Express, Django, Go stdlib
- **When to use:** When reliability matters more than novelty
- **Risk:** May be "boring" but boring is usually correct

### Layer 2: New and Popular
Recent technologies gaining traction. May have genuine advantages but also hype-driven adoption.

- **Trust level:** Medium — scrutinize for mania before adopting
- **Scrutiny questions:**
  - Is the adoption driven by real technical advantages or social proof?
  - What's the failure mode if the project loses momentum?
  - Are there production postmortems from teams at your scale?
  - What does the migration path look like if it doesn't work out?
- **Examples:** New frameworks, trending libraries, recently-launched services
- **When to use:** When the technical advantage is clear AND you've answered the scrutiny questions

### Layer 3: First Principles
Novel approaches derived from understanding the underlying problem deeply. No existing solution fits.

- **Trust level:** Prize above all — but verify the premise
- **When to use:** When Layers 1 and 2 genuinely don't solve the problem
- **Validation:** The first-principles approach must demonstrate why existing solutions fail, not just why the new approach is elegant
- **Risk:** Easy to mistake "I don't know about the existing solution" for "no existing solution exists"

## How to Apply

When proposing technology choices during brainstorming or planning:

1. Classify each choice by layer
2. For Layer 1: state it and move on
3. For Layer 2: answer the scrutiny questions explicitly
4. For Layer 3: explain why Layers 1 and 2 fail before proposing
5. If mixing layers in one project, flag the risk surface: "PostgreSQL (L1) + [new ORM] (L2) — risk is concentrated in the ORM layer"
