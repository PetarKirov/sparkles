# Syntax Highlighting

The synthesis of the [parsing survey's][umbrella] highlighting cluster (waves 4–5,
thirteen deep-dives): what syntax highlighting actually asks of a parser, the
**three engine models** the field converged on — the line-local
**[TextMate scope machine](#the-textmate-grammar-model)** ([syntect], [Shiki][shiki],
consumed by [bat]), the whole-buffer **[CST-query engine](#the-cst-query-model)**
([tree-sitter-highlight], consumed incrementally by [Helix][helix]), and the
**[lexer-as-code family](#the-lexer-as-code-model)** ([Pygments][pygments],
[Chroma][chroma], [highlight.js][hljs]) — plus the three problems around the
engines: [naming what you color](#vocabulary), [deciding what a file
is](#language-detection), and [highlighting a window of a file you haven't
finished reading](#editors-and-the-window-problem). Above them all sits the
[semantic tier](#the-semantic-tier) ([LSP semantic tokens][lsp-st],
[IntelliJ][intellij]). The capstone is
[where the planned `sparkles:syntax` library fits](#where-sparkles-syntax-fits):
a [bat]-shaped tool with **two engines** (fast TextMate-style + precise
tree-sitter) and **two rendering backends** (ANSI like bat + HTML like Shiki).

> [!NOTE]
> **Scope.** This page synthesizes the thirteen cluster deep-dives: the engines
> ([syntect], [bat], [tree-sitter-highlight], [Shiki][shiki], [Pygments][pygments],
> [Chroma][chroma], [highlight.js][hljs], [`@lezer/highlight`][lezer-hl]), the
> detection layer ([Linguist][linguist]), the editor/IDE consumption patterns
> ([Helix][helix], [IntelliJ][intellij], [Vim & Emacs][vim-emacs]), and the
> semantic tier ([LSP semantic tokens][lsp-st]). Out of scope: further
> re-implementations of surveyed designs (Neovim/Zed = the [Helix][helix] shape;
> Rouge/starry-night = [Pygments][pygments]/[Shiki][shiki] in other ecosystems;
> Prism ≈ [highlight.js][hljs]) and grammar-format families without a surveyed
> consumer (Kate/GtkSourceView XML).

**Last reviewed:** July 11, 2026

---

## The highlighting problem

Syntax highlighting inverts the usual parsing contract. A parser is judged by the
**tree** it builds; a highlighter is judged by **colors on a screen**, and the tree
(if any) is an implementation detail. That inversion drives every design in the
cluster:

- **Totality beats precision.** A parser may reject input; a highlighter _never_
  can — its worst legal output is uncolored text. Every surveyed system sits in
  one [error posture][umbrella-recovery]: degrade gracefully. The interesting
  engineering is in _bounding the cost_ of hostile input — and the cluster now
  documents a complete guard taxonomy: length cutoffs ([bat]'s 16 KiB,
  [Vim][vim-emacs]'s 3 000-column `synmaxcol`), per-line time budgets
  ([Shiki][shiki]'s 500 ms), per-match regex timeouts ([Chroma][chroma]'s
  250 ms), whole-window wall clocks ([Vim][vim-emacs]'s 2 000 ms `redrawtime`),
  parse budgets and size caps ([Helix][helix]'s 500 ms / 512 MiB), host-owned
  cancellation ([tree-sitter-highlight]) — and, as the cautionary datum, no
  guards at all ([Pygments][pygments]).
- **Labels, not structure.** The output vocabulary is a set of semantic _labels_
  attached to byte ranges — [scopes, tags, tokens, captures, or legend
  entries](#vocabulary) — which a **theme** later maps to styles. Structure exists
  only to justify the labels.
- **The unit of work defines the architecture.** Per line with a carried stack
  (TextMate), per buffer with a persistent tree (CST), or per document in one
  whole-text scan (lexer-as-code): everything else — startup strategy, streaming,
  windowing, injection handling — follows from that choice.
- **Detection precedes highlighting.** Something must decide _which_ grammar
  runs; [the detection section](#language-detection) maps the two competing
  designs.
- **Distribution is half the problem.** The cluster spans four corpus strategies:
  grammars as data files ([syntect]/[bat]: Sublime packages; [Shiki][shiki]:
  npm-packaged VS Code grammars), compiled artifacts + query files
  ([tree-sitter-highlight]; made operational by [Helix][helix]'s
  fetch/build/dlopen pipeline), lexers as host-language code
  ([Pygments][pygments], [highlight.js][hljs], [IntelliJ][intellij],
  [Vim & Emacs][vim-emacs]) — and corpus _porting_ ([Chroma][chroma]'s
  machine-translation of Pygments).

## Vocabulary

The cluster's shared terms, grounded where the deep-dives develop them:

- **Scope** — a dot-separated semantic label (`string.quoted.double.ruby`) from
  the TextMate lineage; scopes form **stacks**, and themes match the stack.
  [syntect] packs one into 16 bytes; tree-sitter capture names
  [deliberately reuse][ts-highlight] the same names — the convergence that makes
  one theme layer feasible across engines.
- **Token** — a maximal run of text with one resolved style; also
  [Pygments][pygments]' word for its **hierarchical type taxonomy**
  (`Token.Keyword.Reserved` → CSS short name `kr`), the de-facto interchange
  standard of the lexer-as-code family ([Chroma][chroma] re-encodes it as
  integer ranges).
- **Capture** — the CST model's labeling primitive: a query pattern tags matched
  nodes with a highlight name, resolved by
  [longest dot-prefix match][ts-highlight] ([Helix][helix] resolves against
  theme keys at load time).
- **Tag** — [`@lezer/highlight`][lezer-hl]'s answer to open scope strings: a
  **closed vocabulary** (78 tags + 6 modifiers) of interned objects with a
  precomputed subsumption lattice and a commutative modifier algebra.
- **Legend** — [LSP semantic tokens][lsp-st]' negotiated vocabulary: 23 token
  types × 10 modifier bits, extensible per server, integer-indexed on the wire.
- **Theme** — the mapping from labels to styles. Selector-scored
  (`.tmTheme`/VS Code JSON), name-keyed with fallback (tree-sitter config,
  [IntelliJ][intellij]'s `TextAttributesKey` chains, [Helix][helix]'s TOML
  scopes), inheritance-walked ([Pygments][pygments] styles), or plain CSS
  ([highlight.js][hljs]). See [the landscape](#the-theme-format-landscape).
- **Grammar state** — the TextMate model's between-lines carry (rule/context
  stack), cloneable → **checkpointing** ([syntect]'s documented screen-window
  strategy, [Shiki][shiki]'s reified `GrammarState`). Strictly forward-only.
- **Relevance** — [highlight.js][hljs]' detection currency: matches accumulate
  grammar-authored scores; `illegal` patterns disqualify a candidate outright.
- **Injection** — an embedded-language region. TextMate embeds by grammar
  reference ([syntect]'s `embed`/`escape`); the CST model spawns nested layers
  with included ranges ([tree-sitter-highlight]), which [Helix][helix] _recycles_
  across edits.

## The TextMate grammar model

The 2004-vintage model (TextMate 1.x introduced scope-named grammars and
`.tmTheme` themes; Sublime Text's YAML `.sublime-syntax` dialect arrived with
build 3084, April 2015) that still colors most of the world's code:

- **Machine.** A pushdown interpreter over regex rules: the top context's
  patterns race against the current line; the winner emits scopes and
  pushes/pops contexts. First-match-wins ordered choice — [PEG][peg-packrat]'s
  determinism discipline, with the same inexpressiveness for ambiguity.
- **Line-locality is constitutive.** Rules match within one line; only the stack
  crosses the boundary ([Shiki][shiki]'s engine comments: _"TM grammars search
  line by line"_). Gains: per-line cost, streaming, cheap checkpointing. Costs:
  no structural context, no def/use consistency, and the signature failure mode —
  a missed `end` pattern mis-scopes everything to EOF.
- **The engine problem.** The model assumes Oniguruma. [bat] links the C library;
  [syntect] offers pure-Rust `fancy-regex` (~half speed); [Shiki][shiki] ships
  WASM Oniguruma _and_ an `oniguruma-to-es` transpiler (223/223 languages,
  report-verified). Engine divergence is a permanent correctness tax — bat
  regression-tests it; Shiki generates a compat report.

## The CST-query model

The 2018–2019 counter-model ([tree-sitter] 2018; the `tree-sitter-highlight`
crate February 2019; highlighting GitHub.com _"in several languages"_ by early
2020 per the tree-sitter docs — no GitHub-authored announcement exists):

- **Machine.** Parse the whole buffer into an error-recovered [GLR][bottom-up]
  CST, then run declarative queries — `highlights.scm`, `injections.scm`,
  `locals.scm` — whose captures attach highlight names to structurally matched
  nodes.
- **What structure buys:** ancestor-sensitive classification, true injection
  layers, and **locals** — definitions and references colored identically — the
  quality jump no line-local engine can make.
- **What the buffer costs:** no cold window — the top layer parses everything
  before the first colored byte. The reference crate's API is batch;
  **[Helix][helix] shows the editor pattern** that amortizes it: trees kept
  alive across edits (`tree.edit` + incremental reparse under a 500 ms budget),
  injection layers recycled, and highlight queries executed only over the
  viewport. [`@lezer/highlight`][lezer-hl] is the same architecture in the
  CodeMirror world, with the incremental tree maintained by [Lezer][lezer] and
  a two-parameter (`from`/`to`) viewport clip.
- **Supply chain weight:** compiled grammar artifacts + maintained query files
  per language, with query dialects drifting between consumers ([Helix][helix]'s
  `; inherits:` extensions vs the reference crate). Grammar-as-data-file
  simplicity remains the TextMate side's enduring advantage — [Helix][helix]'s
  `hx --grammar` fetch/build/dlopen pipeline is what operationalizing the
  heavier chain takes.

## The lexer-as-code model

The oldest strategy (Emacs font-lock 1992, [Pygments][pygments] 2006,
[highlight.js][hljs] 2006), where a language is a _program_, not a data file:

- **Machine.** A regex state machine authored in the host language —
  [Pygments][pygments]' `tokens` dict interpreted over a state stack,
  [highlight.js][hljs]' compiled mode trees, [IntelliJ][intellij]'s JFlex
  lexers — scanning the **whole text** at a running position (no line
  boundary at all; `re.MULTILINE` only affects anchors). Multiline constructs
  are natural; checkpointing generally isn't.
- **Unbounded expressiveness, bounded portability.** Callbacks and delegation
  handle what no data format can — and weld the corpus to the host runtime.
  [Chroma][chroma] measures the porting cost precisely: 282 of ~300 Pygments
  lexers machine-translate to XML _data_; 19 need hand-written Go; content
  detection (`analyse_text` Python code) didn't survive at all.
- **The taxonomy is the durable artifact.** Pygments' hierarchical token types
  with parent-inheriting styles (`STANDARD_TYPES` short CSS names) made themes
  complete-by-construction a decade before [`@lezer/highlight`][lezer-hl]'s
  closed tags or [IntelliJ][intellij]'s fallback-key chains solved the same
  problem by other means.

## Language detection

Something must pick the grammar. Two designs bracket the space, with the tools
in between:

- **Metadata-first — [Linguist][linguist]:** an ordered strategy cascade
  (modeline → filename → shebang → extension → XML → man page → content
  heuristics → statistical classifier) that only ever _narrows_ a candidate
  set; cheap precise signals first, statistics quarantined to last place;
  815-language registry with community-curated `heuristics.yml` tiebreakers
  for `.h`/`.m`-style collisions; user overrides (`.gitattributes`) trump
  everything.
- **Content-first — [highlight.js][hljs]:** no metadata at all; highlight the
  text with _every_ grammar, accumulate grammar-authored **relevance**, let
  `illegal` patterns disqualify candidates early, best score wins (with
  plaintext always a candidate and a `secondBest` exposing uncertainty).
- **Tool-sized versions:** [bat]'s layered mappings (globs with _negative_
  mappings → filename → extension → shebang fallback), [Pygments][pygments]'
  modeline → glob → per-lexer scored `analyse_text` (clamped, exception-proof),
  [tree-sitter][ts-highlight]'s per-grammar `file-types`/`first-line-regex`/
  `content-regex` metadata, [Helix][helix]'s marker enum (name/regex/filename/
  shebang) for injections.

The composite that falls out for a CLI: **Linguist's cascade shape**
(user override → modeline → filename → extension + heuristics table → shebang)
with **relevance-style content scoring as the last resort** — each stage
narrowing, none able to error.

## The semantic tier

True semantics — is this identifier a `parameter`? `readonly`? `deprecated`? —
needs name resolution, and the cluster documents both ways to buy it:

- **Over a protocol — [LSP semantic tokens][lsp-st]:** a compiler-grade server
  ships integer-encoded, delta-updatable token arrays (5 ints/token, relative
  positions, negotiated 23×10 legend), rendered as an **overlay on a syntactic
  base** (`augmentsSyntaxTokens`); range requests give viewport-first paint;
  failure is invisible (the base remains). Eventually consistent by design.
- **In-process — [IntelliJ][intellij]:** highlighting as latency-ordered
  passes over one persistent PSI tree — restartable integer-state lexer
  (instant), parser with inline error elements, incremental PSI-walking
  annotators (semantic), lowest-priority external tools — no wire format, no
  legend, everything in one scheduler. Twenty-five years of the layered
  architecture every multi-mode tool reinvents in miniature.

Both prove the same composition law the cluster's engines rely on: **the fast
tier paints immediately; smarter tiers refine asynchronously; failure of a
higher tier must be invisible.**

## Editors and the window problem

Neither primary model highlights an arbitrary mid-file window from scratch —
state flows top-down (checkpoint it) or comes from a whole-buffer parse (pay
for it). The editor pages document every known answer:

| Strategy                             | Mechanism                                                                                                    | System                                                                                                                 |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| **Checkpoint at line boundaries**    | Clone the carried state per line; resume from the nearest checkpoint                                         | [syntect] (documented), [Shiki][shiki] (`GrammarState`), [IntelliJ][intellij] (integer lexer states, platform-managed) |
| **Re-derive backwards**              | Search back from the window for grammar-authored sync points (`:syn sync`), bounded by `minlines`/`maxlines` | [Vim][vim-emacs] — the only cold mid-file start surveyed                                                               |
| **Render-driven laziness**           | Fontify only what redisplay reveals (1 500-char chunks); repair correctness in idle passes                   | [Emacs jit-lock][vim-emacs]                                                                                            |
| **Persistent tree + windowed query** | Parse whole-buffer incrementally once; execute highlight queries per viewport range                          | [Helix][helix], [`@lezer/highlight`][lezer-hl] (`from`/`to`), [LSP `range`][lsp-st]                                    |
| **Full feed (the anti-pattern)**     | Push every preceding line through the engine even when unprinted                                             | [bat] — the tax the others exist to avoid                                                                              |

## Cross-system comparison

The core four (the two primary models × the two product shapes):

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

The wider field (wave 5), one row per system — model family, the mechanism it
contributes, and its signature limit:

| System                         | Model family                      | What it adds to the survey                                                                      | Signature limit                                                 |
| ------------------------------ | --------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| [Pygments][pygments]           | Lexer-as-code (whole-text)        | The token taxonomy + parent-inheriting themes; per-lexer scored detection; 14-formatter fan-out | No pathology guards at all; strictly batch                      |
| [Chroma][chroma]               | Ported corpus (Pygments → Go/XML) | The porting playbook + its measured residue; per-match regex timeout (250 ms)                   | Fidelity/freshness bound by the converter; detection ≈ filename |
| [highlight.js][hljs]           | Lexer-as-code (mode trees)        | Relevance-scored content detection; `illegal` negative evidence; themes as plain CSS            | Coarse classification; N-grammar detection scans                |
| [`@lezer/highlight`][lezer-hl] | CST walk (tag-based)              | The closed tag vocabulary + modifier algebra; viewport clip as two API parameters               | Lezer-only; no locals; JS-only                                  |
| [Helix][helix]                 | CST consumption (editor)          | Persistent trees + recycled injections + windowed cursor; budget constants with rationale       | Whole-buffer parse floor; terminal-only                         |
| [Linguist][linguist]           | Detection (metadata-first)        | The strategy cascade + registry + heuristics table + override machinery                         | No confidence output; repo-workflow-shaped                      |
| [LSP semantic tokens][lsp-st]  | Semantic tier (protocol)          | Legend + 5-int delta encoding + range requests + `augmentsSyntaxTokens` overlay law             | Needs a server per language; eventually consistent              |
| [IntelliJ][intellij]           | Semantic tier (in-process)        | Latency-layered passes; restartable integer-state lexing; `TextAttributesKey` fallback chains   | Nothing extractable; per-language cost is code                  |
| [Vim & Emacs][vim-emacs]       | Editor engines (regex, windowed)  | Backward sync (`:syn sync`); render-driven laziness (jit-lock); explicit cost ceilings          | Regex precision ceilings; per-editor grammar dialects           |

Three structural reads:

1. **The engine models partition on where state lives:** carried line stack
   (TextMate family), persistent tree (CST family), single whole-text scan
   (lexer-as-code). Every other row is downstream.
2. **The problems around the engine — vocabulary, detection, windowing,
   tiering — have convergent solutions** discovered independently across
   ecosystems (fallback-chained vocabularies ×4; narrowing detection cascades
   ×3; viewport-bounded rendering ×4; fast-base-plus-async-refinement ×3).
   These recurrences, not any single system, are the survey's design guidance.
3. **Nobody ships the full matrix.** bat lacks a precise mode and HTML; Shiki
   lacks ANSI; the tree-sitter CLI lacks a TextMate fallback; editors lack
   reusable outputs. The two-engine × two-backend slot remains empty.

## The theme-format landscape

One lineage of selector-scored formats, plus the structured vocabularies that
replaced string matching:

| Format / vocabulary            | Shape                                               | Resolution semantics                                             | Native to                       | Consumed by                                                     |
| ------------------------------ | --------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------- | --------------------------------------------------------------- |
| **`.tmTheme`** (2004, plist)   | XML plist of `settings` items                       | Scope selectors scored by specificity ([syntect]'s `MatchPower`) | TextMate, Sublime Text          | [syntect], [bat] (+ its `#RRGGBBAA` terminal-palette extension) |
| **VS Code JSON**               | `tokenColors` rules + semantic token rules          | Same selector family; semantic rules outrank the syntactic base  | VS Code                         | [Shiki][shiki] (via `tm-themes`), [LSP][lsp-st] clients         |
| **tree-sitter CLI config**     | JSON map: highlight name → style                    | Name-keyed; longest dot-prefix resolution upstream               | `tree-sitter` CLI               | [tree-sitter-highlight] (`Style { ansi, css }`)                 |
| **Helix themes** (TOML)        | Scope keys + palettes, 218 bundled                  | Longest dotted-prefix against theme keys, resolved at load       | [Helix][helix]                  | Helix (opaque `Highlight` indices at runtime)                   |
| **Pygments `Style` classes**   | Python classes: token type → style string           | Parent-inheritance over the token hierarchy                      | [Pygments][pygments]            | Pygments formatters; ported wholesale by [Chroma][chroma]       |
| **Lezer `Tag` vocabulary**     | 78 closed tags + 6 modifiers (objects, not strings) | Precomputed subsumption lattice (`tag.set` walk)                 | [`@lezer/highlight`][lezer-hl]  | CodeMirror 6 `HighlightStyle`s                                  |
| **`TextAttributesKey` chains** | Per-language keys chained to platform defaults      | Fallback-chain lookup, all-or-nothing per step                   | [IntelliJ][intellij]            | JetBrains IDEs, export-to-HTML                                  |
| **Plain CSS classes**          | Stylesheets over documented class names             | The browser's cascade                                            | [highlight.js][hljs] (`hljs-*`) | Also [syntect]'s `css_for_theme`, Shiki's class mode            |
| **Generated CSS / variables**  | Per-token custom properties, `light-dark()`         | Resolution already done; the browser applies                     | The web                         | [Shiki][shiki] multi-theme output                               |

The load-bearing convergence stands: **capture names track TextMate scope
names** (tree-sitter's stated policy), so a theme keyed on `string`, `keyword`,
`function.builtin` can drive both primary engines — and the recurring
completeness trick (make every theme cover every language) has four independent
implementations: parent-walking taxonomies ([Pygments][pygments]), closed
lattices ([`@lezer/highlight`][lezer-hl]), fallback-key chains
([IntelliJ][intellij]), and negotiated legends ([LSP][lsp-st]). Terminal
reality is handled the same way everywhere it's handled at all: RGB → 256
downsampling (`ansi256_from_rgb` in [bat] and the tree-sitter CLI; redmean in
[Chroma][chroma]; plain Euclidean in [Pygments][pygments]) plus
palette-respecting encodings ([bat]'s `#RRGGBBAA`).

## Where `sparkles:syntax` fits

### The shape: two engines × two backends

The survey's conclusion is unchanged by the wider field — reinforced by it:

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
  grammar corpus as data files, instant window rendering. Wave 5 sharpens the
  windowing choice: **checkpoint grammar state at line boundaries** (the
  [syntect]/[Shiki][shiki] pattern) as the primary strategy, with
  [Vim][vim-emacs]-style grammar-authored sync points as the researched
  fallback for cold windows — and never [bat]'s full-feed tax.
- **Precise mode** is a [tree-sitter-highlight]-shaped engine consumed the
  [Helix][helix] way when interactive (persistent tree, recycled injection
  layers, viewport-bounded queries, hard budgets: parse timeout, size cap,
  match limit) and the batch way when piping.
- **The spine is the token/event stream** feeding both backends — ANSI with
  [bat]'s color tiers, HTML with per-line-valid tags and [Shiki][shiki]-style
  CSS-variable multi-theme output. The label vocabulary should follow the
  scope-compatible names both engines share, with the completeness trick
  implemented once (a fallback-walking resolver à la
  [Pygments][pygments]/[IntelliJ][intellij]).
- **Detection** is now a designed subsystem, not a bat-clone afterthought:
  Linguist's cascade shape + bat's negative mappings + a relevance-style
  content fallback ([the detection section](#language-detection)).
- **Guards are a checklist, not a choice:** per-line length _and_ time
  ([bat] + [Shiki][shiki]), per-match timeout if the regex engine backtracks
  ([Chroma][chroma]), parse budget/size cap/match limit in precise mode
  ([Helix][helix]) — with degradation visible and recoverable, never sticky-off
  without a signal ([Vim][vim-emacs]'s `redrawtime` lesson).
- **The semantic tier is a future client fold, already shaped:** implement the
  [LSP semantic tokens][lsp-st] decode (5-int legend arrays) over the shared
  token stream now; gain compiler-grade D highlighting whenever a server
  exists — the overlay law (fast base paints, semantics refines, failure
  invisible) matches the architecture for free.

### What each surveyed system contributes

| System                         | What `sparkles:syntax` takes from it                                                                                                         |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| [bat]                          | The product architecture: pipeline, decorations, lazy embedded assets, detection order + negative mappings, ANSI tiers, the 16 KiB guard     |
| [syntect]                      | Fast-mode engine semantics: contexts + ops, packed scopes, pre-linked immutable sets, lazy regexes, dumps, **cloneable state = checkpoints** |
| [tree-sitter-highlight]        | The precise-mode contract: merged queries, longest-dot-match resolution, streaming events, injections/locals, per-line-valid HTML            |
| [Shiki][shiki]                 | The HTML backend doctrine: structured output, CSS-variable multi-theme + `light-dark()`, per-line **time** budgets, reified grammar state    |
| [Pygments][pygments]           | The taxonomy/theme-inheritance design; the no-guards cautionary tale; formatter fan-out as proof of the stream seam                          |
| [Chroma][chroma]               | The corpus-porting playbook (converter + residue accounting); regex timeouts; integer-encoded taxonomy                                       |
| [highlight.js][hljs]           | Content-based detection fallback: relevance scoring, `illegal` negative evidence, keyword-hit capping, `secondBest` uncertainty              |
| [`@lezer/highlight`][lezer-hl] | Vocabulary design to study before naming anything: closed tags, subsumption as data, modifier algebra; viewport clip as API                  |
| [Helix][helix]                 | Precise-mode consumption: persistent trees, injection recycling, windowed cursor, budget constants with recorded rationale                   |
| [Linguist][linguist]           | The detection cascade + registry schema + heuristics answer key + user-override precedence                                                   |
| [LSP semantic tokens][lsp-st]  | The semantic tier's wire shape and the overlay composition law (`augmentsSyntaxTokens`)                                                      |
| [IntelliJ][intellij]           | The layered-pass reference architecture; restartable integer-state lexing; fallback-key theming                                              |
| [Vim & Emacs][vim-emacs]       | Backward sync for cold windows; render-driven laziness; explicit user-facing cost ceilings                                                   |

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

This page cites only claims grounded in the thirteen cluster deep-dives — see
each page's `Sources` for primary artifacts. Historical dates (all
primary-sourced in the grounding ledgers): TextMate 1.0 (October 2004; scoped
grammars/`.tmTheme` are 1.x-era), font-lock (1992; jit-lock default Emacs 21,
October 2001), Vim 5.0 syntax highlighting (February 1998), IntelliJ IDEA 1.0
(January 2001), Pygments 0.5 (October 2006), highlight.js (2006),
`.sublime-syntax` (April 2015), syntect (June 2016), Chroma (2017), bat v0.1.0
(April 2018), Shiki (October 2018), `tree-sitter-highlight` crate
(February 2019), GitHub.com adoption attested by the tree-sitter docs by
February 2020 (Wayback-verified; no first-party announcement), LSP 3.16
semantic tokens (December 2020), VS Code semantic default-on for TS/JS
(v1.43, 2020), `@lezer/highlight` on npm (April 2022), Shiki v1.0
(February 2024).

- Engines: [syntect] · [bat] · [tree-sitter-highlight] · [Shiki][shiki] · [Pygments][pygments] · [Chroma][chroma] · [highlight.js][hljs] · [`@lezer/highlight`][lezer-hl]
- Detection: [Linguist][linguist] · consumption: [Helix][helix] · [IntelliJ][intellij] · [Vim & Emacs][vim-emacs] · semantic tier: [LSP semantic tokens][lsp-st]
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
[pygments]: ./pygments.md
[chroma]: ./chroma.md
[hljs]: ./highlight-js.md
[lezer-hl]: ./lezer-highlight.md
[helix]: ./helix.md
[linguist]: ./linguist.md
[lsp-st]: ./lsp-semantic-tokens.md
[intellij]: ./intellij-highlighting.md
[vim-emacs]: ./vim-emacs-syntax.md
[tree-sitter]: ./tree-sitter.md
[lezer]: ./lezer.md
[rust-analyzer]: ./rust-analyzer.md
[peg-packrat]: ./theory/peg-packrat.md
[bottom-up]: ./theory/bottom-up.md
[incremental]: ./theory/incremental.md
