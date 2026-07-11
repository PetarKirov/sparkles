# Helix (Rust)

How a production editor actually consumes tree-sitter — the pattern [tree-sitter-highlight]'s batch API doesn't show: parse trees kept **alive across edits** (`tree.edit` + incremental reparse with a 500 ms timeout), injection layers **reused** between updates, and highlighting computed **only for the viewport** through a range-bounded cursor. At the pinned checkout the engine lives in helix-editor's own [`tree-house`][tree-house-repo] crate (_"A robust and cozy highlighter library for tree-sitter"_); Helix itself contributes the integration, the grammar-distribution pipeline (`hx --grammar`), a 342-language config, and the theme layer.

| Field                      | Value                                                                                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | Rust; editor MPL-2.0, engine in the `tree-house` crate (0.4.x) by the Helix maintainers                                                                                   |
| License                    | MPL-2.0 (Helix); `tree-house` per its repo                                                                                                                                |
| Repository                 | [`helix-editor/helix`][repo] (+ [`helix-editor/tree-house`][tree-house-repo], extracted 2025 — _"Switch out the highlighter for the `tree-house` crate"_, `CHANGELOG.md`) |
| Documentation              | [docs.helix-editor.com][docs] (in-repo `book/`), `docs/{architecture,vision}.md`                                                                                          |
| Key authors                | Blaž Hrastnik (creator); Pascal Kuthe, Michael Davis (maintainers; `tree-house` authors)                                                                                  |
| Category                   | Syntax highlighting — editor consumption of tree-sitter (incremental + windowed)                                                                                          |
| Algorithm / grammar class  | [tree-sitter][ts-highlight] GLR CSTs per injection layer, kept persistent; merged highlights+locals queries; `query_iter` machinery                                       |
| Lexing model               | Grammar-inherited; grammars are native shared libraries **dlopen'd at runtime**, fetched/built by `hx --grammar`                                                          |
| Output                     | A range-bounded highlight **cursor** (`HighlightEvent { Refresh, Push }` + `next_event_offset`) folded per grapheme into terminal styles                                  |
| Highlighting / theme model | Capture names → theme scopes by longest dotted-prefix match at load time (`Highlight` = opaque index into the theme's style vector)                                       |
| Latest release             | 25.07 line (pin `14d6bc0f`, 2026-07-06, 25.07+971; workspace 25.7.1); `tree-house` 0.4.0 via crates.io (repo pin `750cff2`)                                               |

> [!NOTE]
> This deep-dive surveys the **consumption architecture**: `helix-core/src/syntax.rs` (the in-repo wrapper + query/theme wiring), `helix-loader/src/grammar.rs` (grammar distribution), the render loop's windowing, and the engine internals in `tree-house` (grounded against the crate sources / the cloned `tree-house` repo — **external to the Helix repo**, and the ledger marks which is which). The reference crate it replaces is [tree-sitter-highlight]; the runtime itself is [tree-sitter]. Editor peers (Neovim, Zed) follow the same shape and are referenced only.

---

## Overview

### What it solves

[tree-sitter-highlight] parses the whole buffer per call and streams events once — fine for batch, wrong for an editor where the buffer changes every keystroke and only ~50 lines are visible. Helix's stack answers both halves: **temporal** reuse (trees edited and re-parsed incrementally, injection layers recycled) and **spatial** bounding (highlight queries executed only over the viewport's byte range). The project's ambitions make the constraint explicit ([`docs/vision.md`][vision-md]):

> _"Whether it's a 200 MB XML file, a megabyte of minified javascript on a single line, or Japanese text encoded in ShiftJIS, you should be able to open it and edit it without problems."_

### Design philosophy

1. **The tree is editor state.** `Syntax` lives on the `Document`; every applied transaction converts the `ChangeSet` into tree-sitter `InputEdit`s and re-parses **synchronously inline** with a hard budget (`PARSE_TIMEOUT = 500 ms` — _"half a second is pretty generous"_, [`syntax.rs:518`][syntax-rs]). On any engine error, Helix logs _"TS parser failed, disabling TS for the current buffer"_ and drops to unhighlighted editing — the editor outlives the highlighter.
2. **Query where the eyes are.** The highlighter is constructed per redraw over `viewport_byte_range` — the doc comment notes the deliberate decoupling _"instead of using a view directly to enable rendering syntax highlighted docs anywhere (eg. picker preview)"_ ([`editor.rs`][editor-rs]) — so highlight cost tracks the window, never the file (the [jit-lock discipline][vim-emacs], with a tree instead of regex state).
3. **Engineering limits are named constants with war stories.** A 512 MiB parse cap (_"TS uses 32 (signed) bit indices so this limit must never be raised above 2GiB"_, [`tree-house parse.rs:18-23`][th-parse-rs]), and `TREE_SITTER_MATCH_LIMIT = 256` with a comment recording that unbounded matching _"caused tree-sitter motions to take multiple seconds… in medium-sized rust files (3k loc)"_ while _"Neovim chose 64… too low for some languages (breaks Erlang record fields)"_ ([`tree-house lib.rs:310-328`][th-lib-rs]) — cross-editor tuning knowledge, in source.

---

## How it works

### Keeping the tree alive

`helix_core::Syntax` wraps `tree_house::Syntax` — a `Slab` of layers, each a `LayerData { language, parse_tree, ranges, injections, flags, parent, locals }`. On edit, `generate_edits` ([`syntax.rs:706-779`][syntax-rs]) walks the `ChangeSet` (retain/delete/insert) into `InputEdit`s — all `Point`s set to `Point::ZERO`; Helix drives tree-sitter **purely by byte offset** — and the engine applies them **in reverse order** (_"If we applied them in order then edit 1 would disrupt the positioning of edit 2"_, [`parse.rs`][th-parse-rs]) before `parse_with_timeout` re-parses each touched layer against its old tree (the incremental path), pruning layers no longer reachable (`prune_dead_layers`).

### Injection layers, recycled

Per layer, the injection query re-runs after edits with three reuse mechanisms ([`injections_query.rs`][th-inj-rs]): existing injection ranges are **mapped through the edits** (O(M+N)) so unchanged embedded regions keep their layers; `reuse_injection` matches a prior same-language layer covering the range and keeps its parse tree; and **combined injections** are tracked per scope in a map so scattered fragments still parse as one document. Ranges honor `injection.include-children` via `intersect_ranges` — the same directive vocabulary as [tree-sitter-highlight], re-implemented for persistence. Language resolution is an enum of markers (`Name`, `Match` — longest regex, e.g. Markdown fences — `Filename`, `Shebang`) resolved by the in-repo `Loader`. Injections are load-bearing beyond color ([`book/src/guides/injection.md`][book-injection]): _"within an injected region Helix also uses the injected language's own indentation, textobjects, and comment tokens"_.

### The windowed cursor

The in-repo API ([`syntax.rs:593-600`][syntax-rs]):

```rust
pub fn highlighter<'a>(&'a self, source: RopeSlice<'a>, loader: &'a Loader,
                       range: impl RangeBounds<u32>) -> Highlighter<'a>
```

The engine's iterator is a **cursor, not an event stream**: `next_event_offset() -> u32` tells the renderer where the highlight state next changes; `advance()` returns `HighlightEvent::{Refresh, Push}` — _"Refresh: Reset the active set of highlights… Push: Add more highlights which build on the existing highlights"_ — over a stack of active highlights ([`highlighter.rs`][th-highlighter-rs]). The render loop drives it grapheme-by-grapheme, folding active highlights into one terminal `Style`. Precedence is documented and deliberately ecosystem-aligned: _"prefer the last one which matched. This matches the precedence of Neovim, Zed, and tree-sitter-cli"_ — with the user-facing rule "same span: last match wins; nested nodes: innermost wins" ([`book/src/guides/highlights.md`][book-highlights]). `highlights.scm` + `locals.scm` compile into one query per language; queries support **`; inherits:`** directives (tsx → typescript → ecma), recursively spliced and _"compiled against each inheriting grammar"_.

### Capture → theme, resolved at load

Helix resolves capture names against the active theme **once, at configuration time** (`reconfigure_highlights`, [`syntax.rs:241-266`][syntax-rs]): longest dotted-prefix match of each capture against theme scope keys (`function.builtin.static` → `function.builtin` — [`book/src/themes.md`][book-themes]), producing an opaque `Highlight` index into a parallel `Vec<Style>`. The hot path never touches strings — the same integer-index discipline as [tree-sitter-highlight]'s `configure()`, wired directly into a theme file format (TOML scopes + palettes, 218 bundled themes, truecolor detection and terminal light/dark querying).

### Grammar distribution: `hx --grammar`

Grammars are **native shared libraries dlopen'd at runtime** ([`grammar.rs`][grammar-rs]): `languages.toml` declares 303 grammars by git remote + revision; `hx --grammar fetch` shallow-clones them in parallel, `hx --grammar build` compiles `parser.c` (+ scanner) with `cc` at `-O3 -fPIC -shared` into `runtime/grammars/<name>.so`, timestamp-gated; `get_language` dlopens on demand. A security note guards the seam: builds refuse attacker-controlled git sources from untrusted workspace configs. This is the heaviest grammar supply chain in the survey made _operational_ — 342 language configs and 1 190 query files ship in-repo, grammars arrive as compiled artifacts on demand.

---

## Algorithm & grammar class

- **[tree-sitter][ts-highlight]'s model, made persistent:** GLR CSTs per layer with incremental edit/reparse; classification via the same `.scm` capture queries. Helix/tree-house add no parsing theory — they add _lifecycle_: which trees survive, which layers recycle, when parsing is allowed to cost time.
- **The locals system is fully implemented** (a dedicated `locals.rs`), and further query families (indents, textobjects, tags, rainbows) run on the same `query_iter` machinery — the CST as an editor-wide substrate, not just a color source.
- **Error posture inherited:** recovered trees highlight through breakage; engine failures (timeout, size, incompatible grammar — a typed `Error` enum) disable highlighting per buffer rather than degrade correctness.

## Interface & composition model

- **A wrapper-and-engine split the survey should note:** the editor holds policy (timeout value, viewport ranges, theme resolution, config) while `tree-house` holds mechanism (layers, parsing, cursors) — extracted 2025 precisely so the mechanism is reusable (_"robust and cozy"_) outside Helix.
- **Configuration as data:** `languages.toml` (language → grammar, file-types, injection regex, comment tokens…) + `runtime/queries/<lang>/*.scm` + TOML themes — everything a language needs, no plugins; `; inherits:` keeps query dialects composable.
- **The cursor API fits renderers:** `next_event_offset` lets the caller interleave highlighting with its own iteration (graphemes, diagnostics, selections) instead of adapting to an event stream — a genuinely different, render-loop-shaped contract than [tree-sitter-highlight]'s iterator.

## Performance

- **Temporal: incremental everything** — trees edited not rebuilt, injection layers mapped/reused through edits, dead layers pruned; the steady-state edit cost is the changed region plus query re-runs on touched layers.
- **Spatial: viewport-bounded queries** — highlight cost per redraw scales with the window; whole-buffer _parse_ cost remains (paid incrementally), which is the model's floor.
- **Budgets everywhere:** 500 ms parse timeout (then disable per buffer), 512 MiB size cap, match limit 256, 32-bit ranges chosen to _"save memory/improve cache efficiency"_ — the most explicitly budgeted precise-mode deployment surveyed.
- **Synchronous parse on the main loop** is the accepted trade (bounded by the timeout) — no background-parse complexity, at the cost of worst-case keystroke latency equal to the budget.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — capture names, resolved to theme indices at load:** longest-dotted-prefix matching (as [tree-sitter-highlight]) against _theme keys_ rather than a consumer name list — themes are the vocabulary owner, captures fall back gracefully.
- **Inter-unit state — the persistent layer tree:** all highlight state derives from live trees; nothing is checkpointed per line because any range can be queried at any time — the tree _is_ the checkpoint (contrast [syntect]'s cloned states and [Vim's backward sync][vim-emacs]).
- **Theme resolution — TOML scopes → `Vec<Style>`,** opaque `Highlight` indices on the hot path, an RGB-packed fast path for dynamic colors, terminal capability handling (truecolor detection, light/dark via mode 2031).
- **Rendering targets — the terminal render loop** (grapheme-folded styles); no HTML. The exportable designs are the cursor contract, the layer lifecycle, and the load-time scope resolution.

## Error handling & recovery

- **Per-buffer disablement as the failure ceiling:** any engine error → log + `syntax = None` → plain editing continues; re-opening re-tries. Highlighting is a feature that can fail; the editor is not.
- **Budgets convert pathology into policy:** oversized file → no TS; slow parse → timeout error → disable; runaway query → match-limit truncation (documented trade against correctness for exotic grammars).
- **Broken code highlights fine** (recovered CSTs); _stale_ highlighting between parse and redraw is bounded by the synchronous update discipline.

## Ecosystem & maturity

- **The post-2020 editor pattern, best documented here:** Neovim and Zed share the shape (persistent trees + windowed queries + last-match precedence — the precedence comment cites all three); Helix is the most self-contained specimen (no plugin layer, everything in-repo or in tree-house).
- **Scale of the bundled corpus:** 342 language configs, 303 grammars, 1 190 query files, 218 themes — maintained by the editor community, with query dialect (`; inherits:`, custom families) diverging from the reference crate's — the drift [tree-sitter-highlight]'s page flags, seen from the other side.
- **`tree-house` (0.4.x, 2025-extracted)** is young as a standalone crate but carries Helix's years of production tuning; MPL-2.0 editor, permissive engine.

---

## Strengths

- **The missing consumption pattern, demonstrated:** edit-persistent trees + recycled injection layers + viewport-bounded querying — what "precise mode in an interactive tool" actually requires beyond the reference crate.
- **Budgets as first-class engineering** (timeout/size/match-limit with recorded rationale) — directly liftable numbers and failure policies.
- **A render-loop-shaped cursor API** (`next_event_offset`/`advance`) that composes with other per-position concerns.
- **Operational grammar pipeline** (`hx --grammar` fetch/build/dlopen, security-gated) — the compiled-grammar supply chain made usable.
- **Load-time theme resolution** — string matching off the hot path, themes own the vocabulary.

## Weaknesses

- **Whole-buffer parse remains the floor** — incremental and budgeted, but a cold 200 MB file still can't have precise highlighting (the vision doc's own test case gets _editing_, not colors, past the cap).
- **Synchronous parsing on the interactive path** — up to 500 ms keystroke stalls by design before disablement.
- **Engine externalized:** the interesting internals now live in a separate young crate — architectural clarity at the cost of in-repo self-containedness (and survey grounding must span two repos).
- **Terminal-only rendering;** no reusable output backend.
- **Query dialect divergence** from the reference crate and other editors continues — the ecosystem's standing coordination problem.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                    | Trade-off                                                                      |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Persistent trees on the document, synchronous update**   | Simplest correct lifecycle; highlight state always matches the buffer                        | Keystroke latency bounded only by the 500 ms budget; no async parse pipeline   |
| **Viewport-bounded highlighter per redraw**                | Cost tracks the window; enables highlighting in pickers/previews                             | Iterator rebuilt per frame; parse cost unaffected                              |
| **Injection-layer reuse (range mapping + tree recycling)** | Embedded-language cost survives edits instead of re-parsing every fragment                   | The subtlest code in the engine; correctness depends on precise range mapping  |
| **`HighlightEvent::{Refresh, Push}` cursor**               | Renderer-driven interleaving with other per-position state                                   | Departs from the reference event model — consumers can't be shared             |
| **Byte-only `InputEdit`s (`Point::ZERO`)**                 | Rope-native, avoids row/column bookkeeping entirely                                          | Grammars/queries relying on point positions get degenerate values              |
| **Grammars as dlopen'd shared libraries, built on demand** | Real corpus operability: fetch/build per user, no vendored binaries                          | A C toolchain at user machines; dlopen trust surface (hence the security gate) |
| **Match limit 256 / size cap 512 MiB / timeout 500 ms**    | Editor latency proteced against grammar/file pathology, with recorded cross-editor rationale | Exotic-language query truncation; huge files lose precise mode entirely        |
| **Extract the engine to `tree-house`**                     | Reusable, testable mechanism; Helix keeps policy                                             | Two-repo architecture; crate youth; grounding spans repos                      |

---

## Sources

- In-repo (pin `14d6bc0f`): [`helix-core/src/syntax.rs`][syntax-rs] — `PARSE_TIMEOUT` + wrapper, `generate_edits`, `highlighter(range)`, `reconfigure_highlights`, query compilation + `read_query`; `helix-core/src/syntax/config.rs` — `languages.toml` model; [`helix-loader/src/grammar.rs`][grammar-rs] — fetch/build/dlopen + security note; `helix-view/src/{document,theme}.rs` — apply-path + theme resolution; `helix-term/src/ui/{document,editor}.rs` — viewport range + grapheme fold; [`docs/vision.md`][vision-md], `docs/architecture.md`, [`book/src/guides/{highlights,injection}.md`][book-highlights], [`book/src/themes.md`][book-themes]; `CHANGELOG.md` — the tree-house switch
- Engine (external — [`helix-editor/tree-house`][tree-house-repo], crate 0.4.0; repo clone pinned `750cff2`): [`highlighter/src/lib.rs`][th-lib-rs] — `Syntax`/layers, `TREE_SITTER_MATCH_LIMIT` rationale, `Error`; [`highlighter/src/parse.rs`][th-parse-rs] — 512 MiB cap, reverse edit application, timeout; [`highlighter/src/highlighter.rs`][th-highlighter-rs] — cursor API, precedence comment; [`highlighter/src/injections_query.rs`][th-inj-rs] — mapping/reuse/combined injections
- Related deep-dives: [tree-sitter] + [tree-sitter-highlight] (the runtime and the reference crate) · [Vim & Emacs][vim-emacs] (the windowing predecessors) · [IntelliJ][intellij] (the other editor reference architecture) · [the synthesis][sh]

<!-- References -->

[repo]: https://github.com/helix-editor/helix
[docs]: https://docs.helix-editor.com/
[tree-house-repo]: https://github.com/helix-editor/tree-house
[syntax-rs]: https://github.com/helix-editor/helix/blob/master/helix-core/src/syntax.rs
[grammar-rs]: https://github.com/helix-editor/helix/blob/master/helix-loader/src/grammar.rs
[editor-rs]: https://github.com/helix-editor/helix/blob/master/helix-term/src/ui/editor.rs
[vision-md]: https://github.com/helix-editor/helix/blob/master/docs/vision.md
[book-highlights]: https://github.com/helix-editor/helix/blob/master/book/src/guides/highlights.md
[book-injection]: https://github.com/helix-editor/helix/blob/master/book/src/guides/injection.md
[book-themes]: https://github.com/helix-editor/helix/blob/master/book/src/themes.md
[th-lib-rs]: https://github.com/helix-editor/tree-house/blob/master/highlighter/src/lib.rs
[th-parse-rs]: https://github.com/helix-editor/tree-house/blob/master/highlighter/src/parse.rs
[th-highlighter-rs]: https://github.com/helix-editor/tree-house/blob/master/highlighter/src/highlighter.rs
[th-inj-rs]: https://github.com/helix-editor/tree-house/blob/master/highlighter/src/injections_query.rs
[tree-sitter]: ./tree-sitter.md
[ts-highlight]: ./tree-sitter-highlight.md
[syntect]: ./syntect.md
[vim-emacs]: ./vim-emacs-syntax.md
[intellij]: ./intellij-highlighting.md
[sh]: ./syntax-highlighting.md
