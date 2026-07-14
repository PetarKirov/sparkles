# `sparkles:syntax` — Design Proposal

_Audience: contributors and coding agents evaluating whether/how to build the Sparkles
syntax-highlighting library. This document is a **proposal**, not a normative spec — it
states what to build and why, grounded in the
[syntax-highlighting cluster](../../research/parsing/syntax-highlighting.md) of the
[parsing survey][survey]. For the milestoned delivery plan see [PLAN.md](./PLAN.md); for
the cross-ecosystem evidence base see the cluster's thirteen deep-dives._

## 1. Why

The [survey's capstone][sh-fit] ends on an empty slot: **nobody ships the full matrix**.
[bat] has the CLI product shape but no precise mode and no HTML; [Shiki][shiki] owns the
HTML doctrine but has no ANSI; the [tree-sitter CLI][ts-highlight] has the precise engine
but no product layer; editors keep their highlighters unreusable. Sparkles has concrete
uses on both sides of that matrix:

- **ANSI**: highlighting D snippets in terminal tooling (test-runner reports, `core-cli`
  components, an eventual `bat`-shaped pager/printer).
- **HTML**: rendering code for docs and web output (the Shiki role, self-hosted).
- **Styled runs as data**: the `terminal` app's rendering trajectory (a future
  Vulkan-based text engine) consumes resolved styled runs directly — neither escape
  codes nor markup.

The library is **engine-agnostic in the middle and pluggable at both ends**: token
producers (engines) feed one highlight-event stream; rendering backends fold that stream
into ANSI, HTML — or GPU draw data. The first engine is the **tree-sitter precise mode**
(whole-buffer CST + `highlights.scm` queries, the [tree-sitter-highlight][ts-highlight]
semantics); the TextMate-style fast mode ([syntect]) is a later engine behind the same
seam.

## 2. What — the design center

Each decision cites the prior-art page it reifies and the in-tree code it builds on.

- **One event stream as the inter-engine seam.** Engines emit
  `HighlightEvent { source(start, end) | push(label) | pop }` — offset-based (no slices
  in stream state), ordered, balanced, and **infallible**: engine failures surface
  before/around the stream, never inside it, so renderers are total (the cluster's
  [totality law][sh-problem]: the worst legal output is uncolored text). This is the
  [tree-sitter-highlight][ts-highlight] event model; TextMate scope stacks map onto
  push/pop at stack deltas, so the future fast engine needs no adaptation layer.
- **A canonical, scope-compatible label vocabulary.** Dotted names (`keyword.control`,
  `string.special.key`, ~55 entries) drawn from the convergence the survey documents:
  tree-sitter capture names [deliberately track TextMate scope names][ts-highlight], so
  **one theme layer drives both engines**. `LabelSet` interns names to `LabelId`s at
  configure time; capture-name and theme-selector resolution share one algorithm —
  **longest-dot-prefix** ([Helix][helix]'s semantics, chosen over the reference crate's
  part-subset rule for predictability; the divergence is documented).
- **Themes resolve once, then index in O(1).** `Theme` (ordered `selector → StyleSpec`
  rules) resolves against a `LabelSet` into a flat `labelId → StyleSpec` table at
  configure time — the [Helix][helix] load-time model, not per-token selector scoring.
  Two built-in themes ship as D data (dark: Catppuccin-Mocha-derived; light:
  Solarized-Light-derived; both MIT-sourced with attribution).
- **A real color type instead of encoding tricks.** `Color` is a sum type
  `{ unset, default_, palette(index), rgb }` — [bat]'s `#RRGGBBAA` alpha conventions
  (alpha 0 = palette index, alpha 1 = terminal default) parsed into structure, not
  propagated. Depth folding (`trueColor → ansi256 → ansi16`) reifies [bat]'s tiers;
  detection (`$COLORTERM`/`$TERM`) is a pure classifier + a thin env wrapper, local to
  this package until a second consumer promotes it to `core-cli`.
- **Renderers are folds; backends are additive.** `renderAnsi` (minimal SGR diffs
  between runs; reset before every newline and re-open after, so **every output line is
  independently valid** — the discipline `base.text.ansi`'s `SgrState` already models)
  and `renderHtml` (close + re-open all open spans at `\n`, the reference
  [HtmlRenderer][ts-highlight] rule; inline-style and CSS-class modes, dots→dashes class
  mapping; [Shiki][shiki]-style CSS-variable multi-theme reserved as a later mode). Both
  write to any output range via `base.text` writers.
- **The GPU backend is a design constraint today, a milestone later.** A Vulkan text
  engine consumes `byStyledSpan(events)` (the flattening fold to maximal
  innermost-wins runs) plus `ResolvedTheme` lookups — **data, not markup**. Therefore
  `StyledSpan`, `byStyledSpan`, and `ResolvedTheme` are public, documented, tested API —
  the third-backend contract — and `FontStyle` stays backend-neutral. A `toRgb(Color,
palette)` concretizer and a `byStyledLine` per-line adapter are recorded seams.
- **The precise engine ports the reference semantics 1:1.** Parse the buffer
  (tree-sitter C runtime via ImportC, [the ghostty pattern][importc]), run the
  `highlights.scm` query, walk captures with the reference event loop
  ([ends-pop-before-starts, same-node later-pattern-wins, cancellation every 100
  iterations][ts-highlight]). Text predicates (`#eq?`, `#match?`, `#any-of?` families)
  are evaluated library-side; **unknown predicates disable one pattern with a warning**
  rather than failing the language — a deliberate divergence from the reference's hard
  error, because our query supply chain spans dialects and a batch highlighter has a
  plain-text fallback.
- **Guards are a checklist, not a choice** ([the cluster's guard taxonomy][sh-problem]):
  size cap (512 MiB default; hard 2 GiB ceiling — tree-sitter's 32-bit indices), parse
  budget (500 ms via the 0.25 progress-callback API), query-cursor match limit (256,
  [Helix][helix]'s tuned value), optional query deadline and host cancellation flag.
  Degradation is visible (warnings, `Expected` errors) and never sticky-off.
- **Grammars are supplied, not vendored.** A Nix bundle (`ts-grammars`) links
  `<lang>/parser` + `<lang>/queries/` per language from `nixpkgs#tree-sitter-grammars`
  (D built from `gdamore/tree-sitter-d`, Helix's pin), exported to tests and tools via
  `SPARKLES_TS_GRAMMAR_PATH`. Query files are consumed as shipped (upstream dialect =
  the reference semantics we implement); per-language packaging quirks are normalized in
  the bundle derivation, keeping supply-chain mess out of D code.

## 3. What it builds on (reuse, don't reinvent)

- [`sparkles.base.text.writers`][base-text] — the output-range writer conventions and
  `@nogc` SGR primitives (`writeEscapeSeq`) the renderers extend.
- [`sparkles.base.text.ansi`][base-ansi] — `SgrState`/`writeSgrReset`/`byAnsiToken`: the
  per-line-reset idiom, and the round-trip harness the ANSI renderer's invariant tests
  reuse.
- [`sparkles.base.smallbuffer`](../../libs/base/index.md) — the `@nogc` event/label
  stacks and the `checkWriter` golden-test helper.
- The [`expected`](../../guidelines/idioms/expected/index.md) idiom — engine and loader
  failures are `Expected!(T, TsError)`, never exceptions on the highlight path.
- The [ImportC + pkg-config + Nix recipe][importc] and its seven in-repo precedents
  (`libs/ghostty` first among them) — the binding is `libs/tree-sitter`, a
  `sourceLibrary` with a unique shim stem, `libs "tree-sitter"` resolved from the
  flake's nixpkgs.
- The [test-runner](../../libs/test-runner/index.md) fast path + `skipTest` — grammar-
  dependent tests skip cleanly outside the devshell instead of failing or silently
  passing.

## 4. Non-goals (and why)

- **No TextMate/fast engine yet.** It is the second engine, not the first — the survey's
  [fast/precise split][sh-fit] stands, but the precise mode has the cleaner v1 supply
  chain (compiled grammars from nixpkgs vs a `.sublime-syntax` interpreter plus an
  Oniguruma binding plus a YAML subset). The event seam is designed for it; nothing else
  waits for it.
- **Injections landed (M7); no combined injections, no locals.** Injection layers
  (markdown's inline grammar, fenced code blocks, front-matter) ship in M7 via
  `highlightInjected` + the layer stack. `injection.combined` and locals
  ([def/use coloring][ts-highlight]) stay deferred — the latter a quality bonus for
  batch rendering.
- **No incremental/editor loop.** v1 is batch (parse once, highlight once) — the
  [Helix][helix] machinery (persistent trees, injection recycling) earns its keep only
  under an editor contract. The seam (`highlightTree` over a kept-alive tree,
  viewport-bounded cursors) exists and is documented, not built.
- **No detection cascade.** v1 maps fence labels/extensions via `canonicalLanguage`;
  the [Linguist][linguist]-shaped strategy cascade and content scoring are a product
  concern for the future bat-clone, not the library core.
- **No semantic tier.** The [LSP semantic-tokens][lsp-st] overlay fold is future work;
  the event stream's composition law (fast base paints, refinement overlays, failure
  invisible) already matches it.
- **Not a terminal-capability framework.** The pure color-tier classifier lives in
  `sparkles.base.term_color` (shared by `syntax` and `core-cli`); `core-cli`'s
  `TermCaps` now carries the resolved `colorDepth`. Higher-level detection cascades
  stay out of scope.

## 5. Prior-art map

Where each design decision comes from in the survey:

| Decision                                     | Prior art (survey page)                       | What to borrow                                                 |
| -------------------------------------------- | --------------------------------------------- | -------------------------------------------------------------- |
| Event stream `source/push/pop`               | [tree-sitter-highlight][ts-highlight]         | the event vocabulary; streaming, early-stop rendering          |
| Scope-compatible dotted labels               | [ts-highlight][ts-highlight] · [syntect]      | one theme layer across engines (the stated convergence)        |
| Longest-dot-prefix resolution, resolved once | [Helix][helix]                                | load-time theme tables; one algorithm for captures and themes  |
| Color tiers + palette encodings              | [bat]                                         | `ansi256_from_rgb` fold; `#RRGGBBAA` semantics (as a sum type) |
| Per-line-valid ANSI                          | [bat] · in-tree `ansi.d`                      | reset/re-open at `\n`; SGR state discipline                    |
| Per-line-valid HTML, class/inline modes      | [ts-highlight][ts-highlight] · [Shiki][shiki] | HtmlRenderer newline rule; structured output doctrine          |
| Multi-theme CSS variables (reserved)         | [Shiki][shiki]                                | `--syn-*` custom properties, `light-dark()`                    |
| Guard checklist                              | [Helix][helix] · [Shiki][shiki] · [bat]       | size cap, parse budget, match limit, cancellation              |
| Predicate posture: degrade, don't fail       | [Helix][helix] (dialect drift)                | disable pattern + warn; plain-text fallback stays reachable    |
| Grammar supply as packaged artifacts         | [Helix][helix]                                | fetch/build pipeline shape, moved into Nix                     |
| Detection deferred to a cascade later        | [Linguist][linguist]                          | the composite cascade recorded for the product layer           |
| GPU backend as styled-run consumer           | [sh-fit][sh-fit] · in-tree `terminal`         | data-not-markup third backend; public flatten fold             |

The milestones that build this — bottom-up, each independently useful — are in
[PLAN.md](./PLAN.md).

<!-- References -->

<!-- Survey pages -->

[survey]: ../../research/parsing/index.md
[sh-fit]: ../../research/parsing/syntax-highlighting.md#where-sparkles-syntax-fits
[sh-problem]: ../../research/parsing/syntax-highlighting.md#the-highlighting-problem
[ts-highlight]: ../../research/parsing/tree-sitter-highlight.md
[syntect]: ../../research/parsing/syntect.md
[bat]: ../../research/parsing/bat.md
[shiki]: ../../research/parsing/shiki.md
[helix]: ../../research/parsing/helix.md
[linguist]: ../../research/parsing/linguist.md
[lsp-st]: ../../research/parsing/lsp-semantic-tokens.md

<!-- Guidelines & in-tree sources -->

[importc]: ../../guidelines/importc-c-libraries.md
[base-text]: https://github.com/PetarKirov/sparkles/blob/3cc01cfdc8ae867f0558e43c731885a004cb0130/libs/base/src/sparkles/base/text/writers.d
[base-ansi]: https://github.com/PetarKirov/sparkles/blob/3cc01cfdc8ae867f0558e43c731885a004cb0130/libs/base/src/sparkles/base/text/ansi.d
