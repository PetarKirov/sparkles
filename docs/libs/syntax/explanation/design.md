# The design

`sparkles:syntax` reifies the [syntax-highlighting cluster][survey] of the
parsing survey — thirteen deep-dives distilled into one architecture. The
full rationale lives in the [design proposal][proposal]; this page is the
short version.

## One stream, many engines, many backends

The field's engines disagree on everything except their output shape:
semantic labels attached to byte ranges. So the library's spine is exactly
that — a `source`/`push`/`pop` event stream ([tree-sitter-highlight][ts-hl]'s
model, which TextMate scope stacks also map onto) — and both engines and
backends are replaceable folds around it. The tree-sitter precise mode
shipped first because its supply chain is cleanest (compiled grammars from
nixpkgs); a TextMate-style fast mode plugs into the same seam later.

## Scope-compatible names, resolved once

tree-sitter capture names deliberately track TextMate scope names — the
convergence that lets **one theme layer drive every engine**. The canonical
vocabulary merges the reference highlighter's names with Helix's theme
scopes; both capture names and theme selectors resolve by
**longest-dot-prefix** (Helix's rule) — one algorithm, run once at configure
time into flat integer-indexed tables, so the render path never matches
strings.

## Totality and guards

A highlighter never fails: its worst legal output is uncolored text. Every
fallible step returns an `Expected` the caller folds into the plain-text
fallback, and hostile input is bounded by the survey's guard checklist
(size cap, parse budget, match limit, cancellation) with visible — never
sticky-off — degradation. The same posture drives the predicate policy:
an unknown query predicate disables one pattern with a warning instead of
killing the language.

## Data before markup

`byStyledSpan` + `ResolvedTheme` — maximal styled runs plus O(1) style
lookup — are public API, not renderer internals. That is the recorded seam
for a future Vulkan/GPU text-rendering backend (the `apps/terminal`
trajectory), which consumes styled runs as data. The ANSI and HTML renderers
are just the first two folds over it.

<!-- References -->

[survey]: ../../../research/parsing/syntax-highlighting.md
[proposal]: ../../../specs/syntax/index.md
[ts-hl]: ../../../research/parsing/tree-sitter-highlight.md
