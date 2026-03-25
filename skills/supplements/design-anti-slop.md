---
name: design-anti-slop
description: "Explicit AI design cliché blacklist — opt-in supplement for frontend-design skill to prevent generic AI-generated UI patterns"
targets: document-skills:frontend-design, busdriver:frontend-patterns
type: supplement
opt_in: true
source: gstack /design-consultation
added: 2026-03-24
---

# Design Anti-Slop Patterns

> **Opt-in supplement.** Load alongside `document-skills:frontend-design` or `busdriver:frontend-patterns` when the user wants to avoid generic AI-generated design patterns. Not loaded by default — invoke explicitly or when the user mentions "avoid AI slop", "make it unique", "don't make it generic".

## AI Design Clichés to Avoid

These patterns are the hallmark of AI-generated UI. They're not always wrong, but they signal "nobody designed this":

### Layout Anti-Patterns
- **3-column icon grid** — Three features with icons in a row. The most common AI layout. Use asymmetric layouts, bento grids, or cards with varying sizes instead.
- **Centered everything** — Every section centered with uniform spacing. Real designs have intentional asymmetry and visual hierarchy.
- **Hero → Features → CTA → Footer** — The exact same section order every AI generates. Break the pattern.

### Visual Anti-Patterns
- **Purple gradients** — The default "modern" AI color choice. Be more specific about your palette.
- **Uniform border-radius** — Every element has the same rounded corners. Vary corner radius by element type and importance.
- **Gradient buttons** — Especially purple-to-blue. Flat colors with clear contrast often work better.
- **Decorative blobs** — Floating gradient shapes with no purpose. Every visual element should earn its place.

### Typography Anti-Patterns
- **Inter for everything** — Inter is fine, but it's the AI default. Consider alternatives.
- **Roboto as body text** — Same — technically fine but signals "AI picked this."
- **Oversized hero text with thin weight** — 72px light weight headlines. Choose appropriate sizes and weights.

## What to Do Instead

- Study the specific domain — a fintech app should look different from a creative tool
- Reference 2-3 real sites in the same space for calibration
- Use the user's `.impeccable.md` design context if it exists
- When in doubt, simpler is better — a well-executed minimal design beats an over-decorated AI one
