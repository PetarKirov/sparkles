# Syntax Highlighting

The synthesis of the [parsing survey's][umbrella] wave-4 cluster: what syntax
highlighting actually asks of a parser, the **two models** the field converged on —
the line-local **[TextMate scope machine](#the-textmate-grammar-model)** ([syntect],
[Shiki][shiki], consumed by [bat]) and the whole-buffer
**[CST-query engine](#the-cst-query-model)** ([tree-sitter-highlight]) — the
[vocabulary](#vocabulary) they share, the
[theme-format landscape](#the-theme-format-landscape) that connects them, and
[where the planned `sparkles:syntax` library fits](#where-sparkles-syntax-fits):
a [bat]-shaped tool with **two engines** (fast TextMate-style + precise
tree-sitter) and **two rendering backends** (ANSI like bat + HTML like Shiki).

> [!NOTE]
> **Scope.** This page synthesizes the four cluster deep-dives ([syntect], [bat],
> [tree-sitter-highlight], [Shiki][shiki]). Out of scope: **semantic highlighting**
> from full compiler front-ends (LSP `semanticTokens`, [rust-analyzer]-grade name
> resolution — a third precision tier the cluster's engines deliberately stop short
> of), editors' in-process re-implementations of either model (Vim regex syntax,
> Emacs font-lock, Neovim/Helix/Zed query engines), and classic batch generators
> (Pygments, highlight.js — regex-family engines without the scope-stack model's
> rigor).

**Last reviewed:** July 11, 2026

---

## The highlighting problem

Syntax highlighting inverts the usual parsing contract. A parser is judged by the
**tree** it builds; a highlighter is judged by **colors on a screen**, and the tree
(if any) is an implementation detail. That inversion drives every design choice in
the cluster:

- **Totality beats precision.** A parser may reject input; a highlighter _never_
  can — its worst legal output is uncolored text. Every surveyed system therefore
  sits in one [error posture][umbrella-recovery]: degrade gracefully. The
  interesting engineering is in _bounding the cost_ of hostile input (bat's
  16 KiB line cutoff, Shiki's per-line time budget, tree-sitter's cancellation
  flag), not in error messages.
- **Labels, not structure.** The output vocabulary is a flat-ish set of semantic
  _labels_ attached to byte ranges — [scopes](#vocabulary) or capture names — which
  a **theme** later maps to styles. Structure exists only to justify the labels.
- **The unit of work defines the architecture.** The TextMate model pays **per
  line** and carries a stack between lines; the CST model pays **per buffer** and
  answers any window from the tree. Everything else — startup strategy, streaming,
  window-scrolling behavior, injection handling — follows from that one choice.
- **Distribution is half the problem.** A highlighter is only as good as its
  grammar corpus: the four systems represent three corpus strategies — Sublime
  packages as data files ([syntect]/[bat]), VS Code grammars as npm packages
  ([Shiki][shiki]), compiled grammar artifacts + query files
  ([tree-sitter-highlight]).

## Vocabulary

The cluster's shared terms, each grounded where the deep-dives develop it:

- **Scope** — a dot-separated semantic label (`string.quoted.double.ruby`) from
  the TextMate lineage. Scopes form **stacks**: at any text position, the active
  scopes of every enclosing construct apply, and themes match against the stack.
  Implementation extreme: [syntect] packs a scope into 16 bytes of interned
  atoms for instruction-level prefix tests. Tree-sitter's grammar metadata
  [deliberately reuses][ts-highlight] TextMate scope names (`source.js`, matching
  Linguist), which is what keeps one theme layer feasible across models.
- **Token** — a maximal run of text with one resolved style. TextMate engines
  emit tokens per line ([Shiki][shiki]'s `ThemedToken[][]`, [syntect]'s
  `(Style, &str)` runs); the CST engine emits **events** (`Source` spans between
  `HighlightStart`/`HighlightEnd`) that a renderer folds into tokens.
- **Capture** — the CST model's labeling primitive: an S-expression query pattern
  tags matched nodes with a **highlight name** (`function.method.builtin`),
  resolved to the consumer's vocabulary by [longest dot-prefix
  match][ts-highlight].
- **Theme** — the mapping from labels to styles. Two selector families:
  scope-selector matching with specificity scoring (`.tmTheme`, VS Code JSON) and
  name-keyed lookup (tree-sitter CLI config). See
  [the theme-format landscape](#the-theme-format-landscape).
- **Grammar state** — the TextMate model's between-lines carry: the rule/context
  stack (plus syntect's `HighlightState` style stack). Cloneable →
  **checkpointing**: resume highlighting from a saved line boundary
  ([syntect]'s documented screen-window strategy, [Shiki][shiki]'s reified
  `GrammarState`). Strictly forward-only — no engine can start cold mid-file.
- **Injection** — an embedded-language region (JS in HTML, SQL in a heredoc).
  TextMate embeds grammars by reference inside rules ([syntect]'s
  `embed`/`escape`); the CST model spawns nested **layers** parsed with
  [included ranges][ts-highlight], lazily or combined.

## The TextMate grammar model

The 2004-vintage model (TextMate 1.x introduced scope-named grammars and
`.tmTheme` themes; Sublime Text's YAML `.sublime-syntax` dialect arrived with
build 3084, April 2015) that still colors most of the world's code:

- **Machine.** A pushdown interpreter over regex rules: the top context's
  patterns are raced against the current line; the winner emits scopes and
  pushes/pops/sets contexts. First-match-wins ordered choice — the same
  determinism discipline as [PEG][peg-packrat], with the same inexpressiveness
  for ambiguity.
- **Line-locality is constitutive, not incidental.** Rules match within one line;
  only the stack crosses the boundary. [Shiki][shiki]'s engine-transpilation
  comments state it flatly (_"TM grammars search line by line"_), and it is why
  `^`/`$` can be rewritten to `\A`/`\Z` with _"no change in meaning"_. The gains:
  per-line cost, trivial parallelism across files, natural streaming, cheap
  checkpointing. The costs: no structural context, no def/use consistency, and
  the signature failure mode — a missed `end` pattern mis-scopes everything to
  EOF.
- **Power per rule, poverty per model.** Individual regexes are Oniguruma-class
  (lookaround, backrefs, recursion) — far beyond regular — but classification
  can only see _this line + the stack_. Sublime's dialect pushes the envelope
  (`branch_point` cross-line speculation, implemented at [syntect]'s HEAD with
  op replay); the fundamental ceiling stands.
- **The engine problem.** The model assumes Oniguruma. Every implementation
  answers differently: [bat] links the C library (`regex-onig`); [syntect] offers
  pure-Rust `fancy-regex` (~half speed, _"just as correct"_ per its tests);
  [Shiki][shiki] ships WASM Oniguruma _and_ an `oniguruma-to-es` transpiler to
  native `RegExp` (223/223 languages, report-verified). Engine divergence is a
  permanent correctness tax — bat regression-tests it; Shiki generates a compat
  report.

## The CST-query model

The 2018–2019 counter-model ([tree-sitter] 2018; the `tree-sitter-highlight`
crate February 2019; highlighting GitHub.com _"in several languages"_ by early
2020 per the tree-sitter docs — no GitHub-authored announcement exists):

- **Machine.** Parse the whole buffer into an error-recovered
  [GLR][bottom-up] CST, then run declarative **queries** — `highlights.scm`,
  `injections.scm`, `locals.scm` — whose captures attach highlight names to
  structurally matched nodes. Rendering folds a lazy
  [event stream][ts-highlight].
- **What structure buys.** Ancestor-sensitive classification (a `(call_expression
function: (identifier))` is a function _because of where it sits_), true
  injection layers with innermost-wins ordering, and **locals** — definition and
  references colored identically via query-declared scopes — the visible quality
  jump no line-local engine can make.
- **What the buffer costs.** No cold window: the top layer parses everything
  before the first colored byte, so `--line-range=1:50` of a huge file pays a
  full parse ([tree-sitter-highlight]'s headline constraint). The underlying
  runtime is [incremental][incremental], but the highlight crate's API is batch —
  edit-local re-highlighting belongs to editors driving the runtime directly.
- **Supply chain weight.** Each language needs a _compiled grammar artifact_
  (C source → native/WASM) plus maintained query files, and query dialects drift
  between editors. Grammar-as-data-file simplicity is the TextMate side's
  enduring advantage.

## Cross-system comparison

| Dimension         | [syntect]                                              | [bat]                                                  | [tree-sitter-highlight]                                         | [Shiki][shiki]                                                |
| ----------------- | ------------------------------------------------------ | ------------------------------------------------------ | --------------------------------------------------------------- | ------------------------------------------------------------- |
| Role              | TextMate engine (library)                              | CLI product over syntect                               | CST-query engine (library + CLI)                                | TextMate engine + HTML renderer (web)                         |
| Grammar source    | `.sublime-syntax` files (Sublime corpus)               | syntect's, pre-serialized (`syntaxes.bin`)             | Compiled grammar + `highlights/injections/locals.scm`           | `.tmLanguage.json` via `tm-grammars` npm                      |
| Unit of work      | Line                                                   | Line                                                   | **Whole buffer** (per layer)                                    | Line                                                          |
| Inter-line state  | `ParseState` + `HighlightState` (cloneable)            | syntect's, hidden (full feed, no checkpoints)          | None — all state derives from the tree                          | `GrammarState` (reified, per-theme, extractable)              |
| Precision         | Approximate (line + stack)                             | = syntect                                              | **Structural** + locals (def/use coloring)                      | Approximate (line + stack)                                    |
| Pathology guards  | None (documented, delegated)                           | 16 KiB line cutoff (always on)                         | Cancellation flag (host-owned clock)                            | Per-line length (opt-in) + **time budget** (500 ms default)   |
| Theme format      | `.tmTheme` (selector scoring)                          | `.tmTheme` + `#RRGGBBAA` palette encodings             | Name-keyed JSON config, `Style { ansi, css }`                   | VS Code JSON; multi-theme CSS variables + `light-dark()`      |
| Output targets    | ANSI (24-bit helper) + HTML (inline or classes + CSS)  | ANSI only (truecolor/256/palette tiers)                | Streaming events → HTML (per-line-valid) + CLI ANSI             | HTML/hast only (inline, classes, CSS vars)                    |
| Incremental story | Checkpoint state per line (documented, consumer's job) | None                                                   | Batch API over an incremental runtime                           | Forward-only continuation (`GrammarState`, `@shikijs/stream`) |
| Startup strategy  | Embedded bincode dumps + lazy regexes (~23 ms)         | `include_bytes!` dumps, `OnceCell`, per-theme laziness | Query compilation per language, config shareable across threads | Singleton highlighter, fine-grained bundles, lazy imports     |

Two structural reads of that table:

1. **The models partition cleanly on one axis** — where state lives. Line +
   carried stack (three systems) vs tree + no carried state (one). Every row
   below "unit of work" is downstream of that.
2. **Nobody ships both engines.** bat is locked to syntect; Shiki has no ANSI
   path; tree-sitter's CLI has no TextMate fallback for the long tail of
   languages that have a Sublime grammar but no maintained queries. The
   two-engine, two-backend slot is empty — that is the [`sparkles:syntax`
   opening](#where-sparkles-syntax-fits).

## The theme-format landscape

Four formats, one lineage — and a name-vocabulary that deliberately converged:

| Format                        | Shape                                                       | Selector semantics                                                        | Native to              | Consumed by                                                      |
| ----------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------- | ---------------------------------------------------------------- |
| **`.tmTheme`** (2004, plist)  | XML plist of `settings` items                               | Scope selectors scored by specificity ([syntect]'s `MatchPower`)          | TextMate, Sublime Text | [syntect], [bat] (its only theme format)                         |
| **VS Code JSON**              | `tokenColors` rules + workbench colors                      | Same scope-selector family, JSON syntax                                   | VS Code                | [Shiki][shiki] (via `tm-themes`)                                 |
| **tree-sitter CLI config**    | JSON map: highlight name → style                            | **Name-keyed** — longest dot-prefix resolution does the matching upstream | `tree-sitter` CLI      | [tree-sitter-highlight] CLI (`Style { ansi, css }`)              |
| **Generated CSS / variables** | Stylesheet from a theme, or per-token CSS custom properties | Resolution already done; the browser applies                              | The web                | [syntect]'s `css_for_theme`, [Shiki][shiki]'s multi-theme output |

The load-bearing convergence: **capture names track TextMate scope names**
(tree-sitter's stated policy — _"We strive to match the scope names used by
popular TextMate grammars and by the Linguist library"_). A theme keyed on
`string`, `keyword`, `function.builtin` can therefore drive both models. The
terminal adds one more wrinkle both native systems solve identically: RGB themes
must degrade to 256-color (`ansi256_from_rgb` in both [bat] and the tree-sitter
CLI) and, in bat's case, express _palette-respecting_ themes via `#RRGGBBAA`
alpha-channel encodings — a de-facto `.tmTheme` extension for terminals.

## Where `sparkles:syntax` fits

### The shape: two engines × two backends

The survey's conclusion is an architecture with **four corners and one spine**:

```
   grammars (.sublime-syntax)  grammars (compiled) + queries (.scm)
              │                              │
       ┌──────┴──────┐               ┌───────┴───────┐
       │  fast mode  │               │ precise mode  │
       │ (TextMate,  │               │ (tree-sitter, │
       │  per line)  │               │ whole buffer) │
       └──────┬──────┘               └───────┬───────┘
              └──────────┬───────────────────┘
                 shared token/event stream
                 + shared theme layer (scope-compatible names)
              ┌──────────┴───────────────────┐
       ┌──────┴──────┐               ┌───────┴───────┐
       │ ANSI backend│               │  HTML backend │
       │  (bat-like) │               │ (Shiki-like)  │
       └─────────────┘               └───────────────┘
```

- **Fast mode** is a [syntect]-shaped engine: per-line stateful tokenization,
  grammar corpus as data files, instant window rendering with checkpointed
  state. It is the default for `cat`-style invocation and huge files.
- **Precise mode** is a [tree-sitter-highlight]-shaped engine (the D binding
  path already exists — see [the D substrate](#the-d-substrate)): whole-buffer
  parse, query-driven captures, locals and injections — opt-in (`--precise`)
  where fidelity beats latency, e.g. small files, HTML export, documentation
  pipelines.
- **The spine is the token/event stream.** Both engines reduce to _(byte range,
  label, resolved style)_ per line — [tree-sitter-highlight]'s events fold into
  exactly the per-line token lists TextMate engines emit natively, and both
  [HtmlRenderer][ts-highlight] and [Shiki][shiki] prove the per-line-validity
  invariant the backends need. One theme layer serves both because the label
  vocabularies converged (scope-compatible names).
- **Two backends, both first-class:** an ANSI fold with [bat]'s color tiers
  (truecolor / 256 via `ansi256_from_rgb`-equivalent / palette / default-color,
  italics gating) and an HTML emitter with per-line-valid tags, class-based or
  inline styles, and CSS-variable multi-theme output à la [Shiki][shiki]
  (including `light-dark()`). The tree-sitter CLI's `Style { ansi, css }` dual
  representation is the proof that one theme entry can carry both targets.

The empirically validated product rules that come with the shape: never fail on
content; guard the engine boundary by **length and time** (bat's 16 KiB _and_
Shiki's 500 ms, per line); lazy pre-serialized grammar assets for startup
([bat]'s dumps — for which `sparkles:base`'s allocation-conscious I/O is a
natural fit); layered detection with negative mappings + first-line fallback;
checkpoint grammar state at line boundaries instead of bat's full-feed tax —
the strategy [syntect]'s own `HighlightState` docs describe and [Shiki][shiki]
productizes. And the shared streaming caveat as a design constraint: **neither
model highlights an arbitrary mid-file window from scratch** — state flows
top-down (checkpoint it) or comes from a whole-buffer parse (pay for it).

### What each surveyed system contributes

| System                  | What `sparkles:syntax` takes from it                                                                                                                                                                  |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [bat]                   | The product architecture: controller→printer pipeline, decorations as components, lazy embedded assets, detection order + negative mappings, ANSI color tiers, the 16 KiB guard, pager negotiation    |
| [syntect]               | The fast-mode engine semantics: contexts + `ScopeStackOp`s, packed scope atoms, pre-linked immutable grammar sets, lazy regexes, binary dumps, **cloneable state = checkpointing**, `css_for_theme`   |
| [tree-sitter-highlight] | The precise-mode contract: merged three-query configuration, longest-dot-prefix name resolution, streaming events, injection layers, locals, host-owned cancellation, per-line-valid HTML             |
| [Shiki][shiki]          | The HTML backend doctrine: hast-style structured output, multi-theme CSS variables + `light-dark()`, per-line **time** budgets, reified grammar state, engine-compat verification by generated report |

### The D substrate

The [D landscape][d-landscape] page maps the local ground: `d_tree_sitter`
provides FFI bindings to the tree-sitter C runtime (the precise-mode entry
point); `libdparse` offers a ready-made D tokenizer should a hand-written
D-language fast path ever be wanted; and the in-tree baseline —
`sparkles.base.text`'s `@nogc` zero-copy readers/writers, `SmallBuffer`,
`Expected`-based error handling, and `sparkles:ghostty`'s VT layer — is exactly
the allocation-conscious substrate a per-line tokenizer and an SGR/HTML fold
want to sit on. The fast-mode engine itself (a `.sublime-syntax` /
`.tmLanguage.json` interpreter in D) is the genuinely new build; this cluster is
its specification. The design itself lands later in `docs/specs/`, next to the
[`sparkles:parsing` proposal][comparison-fit].

---

## Sources

This page cites only claims grounded in the four cluster deep-dives — see each
page's `Sources` for primary artifacts: [syntect] · [bat] ·
[tree-sitter-highlight] · [Shiki][shiki]. Historical dates: TextMate 1.0
(October 2004; scoped grammars/`.tmTheme` are 1.x-era), `.sublime-syntax`
(Sublime Text 3 build 3084, April 2015), syntect (June 2016), bat v0.1.0
(April 2018), Shiki (October 2018), `tree-sitter-highlight` crate
(February 2019), GitHub.com adoption attested by the tree-sitter docs by
February 2020 (Wayback-verified; no first-party announcement), Shiki v1.0
(February 2024).

- Cluster deep-dives: [syntect] · [bat] · [tree-sitter-highlight] · [Shiki][shiki]
- Survey context: [the umbrella][umbrella] · [comparison][comparison] · [concepts][concepts]
- Theory: [PEG / ordered choice][peg-packrat] · [bottom-up / GLR][bottom-up] · [incremental][incremental]
- The inward turn: [the D landscape][d-landscape]

<!-- References -->

[umbrella]: ./index.md
[umbrella-recovery]: ./index.md#taxonomy
[comparison]: ./comparison.md
[comparison-fit]: ./comparison.md#where-a-sparkles-parser-would-fit
[concepts]: ./concepts.md
[d-landscape]: ./d-landscape.md
[syntect]: ./syntect.md
[bat]: ./bat.md
[tree-sitter-highlight]: ./tree-sitter-highlight.md
[ts-highlight]: ./tree-sitter-highlight.md
[shiki]: ./shiki.md
[tree-sitter]: ./tree-sitter.md
[rust-analyzer]: ./rust-analyzer.md
[peg-packrat]: ./theory/peg-packrat.md
[bottom-up]: ./theory/bottom-up.md
[incremental]: ./theory/incremental.md
