# Shiki (TypeScript / Web)

The TextMate highlighter of the JavaScript/web ecosystem: a pnpm-workspace monorepo that runs [`vscode-textmate`][vscode-textmate]-lineage tokenization — per line, over a carried grammar-state stack — through **pluggable regex engines** (Oniguruma compiled to WASM, or Oniguruma patterns transpiled to native `RegExp`), and renders **ahead-of-time HTML** with VS Code themes, CSS-variable dual themes, and per-line guards. It renders the code fences of this very documentation site (VitePress), and within [the highlighting cluster][sh] it is the web-output counterpart to [syntect] — same [TextMate model][sh-tm], different rendering target and portability story.

| Field                      | Value                                                                                                                                                         |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                   | TypeScript (ESM); optional WASM (Oniguruma); 21 packages under `packages/`                                                                                    |
| License                    | MIT (© 2021 Pine Wu, © 2023 Anthony Fu)                                                                                                                       |
| Repository                 | [`shikijs/shiki`][repo]                                                                                                                                       |
| Documentation              | [shiki.style][docs] (sources in-repo under `docs/`)                                                                                                           |
| Key authors                | Pine Wu (creator, 2018); Anthony Fu (v1.0 rewrite via Shikiji, lead maintainer)                                                                               |
| Category                   | Syntax highlighting — TextMate engine for the web (AOT/HTML)                                                                                                  |
| Algorithm / grammar class  | [TextMate scope machine][sh-tm] over `.tmLanguage.json` grammars (`@shikijs/vscode-textmate` fork); per-line regex matching + scope-stack state               |
| Lexing model               | Pluggable `RegexEngine { createScanner, createString }`: Oniguruma WASM (`vscode-oniguruma` 1.7.0 inlined) or JS `RegExp` via [`oniguruma-to-es`][onig-to-es] |
| Output                     | Themed tokens → hast → HTML (`codeToTokens` / `codeToHast` / `codeToHtml`); ANSI-input rendering exists, terminal output does not                             |
| Highlighting / theme model | VS Code JSON themes; packed `tokenizeLine2` binary metadata; multi-theme via CSS variables (`--shiki-` prefix) + `light-dark()`                               |
| Latest release             | `v4.3.1` (pinned checkout `fdff6e23` = the `v4.3.1` tag, 2026-07-03)                                                                                          |

> [!NOTE]
> This deep-dive surveys the tokenization/rendering core — `packages/{primitive,core,engine-oniguruma,engine-javascript,types,shiki}` — plus the grammar/theme data supply (`tm-grammars`/`tm-themes` via `@shikijs/langs`/`@shikijs/themes`) and the streaming package. The integration ecosystem (`transformers`, `rehype`, `markdown-it`, `monaco`, `twoslash`, `cli`, …) is referenced, not catalogued. The TextMate grammar _model_ itself is developed in the [cluster synthesis][sh-tm]; the native-ecosystem implementation of the same model is [syntect].

---

## Overview

### What it solves

Shiki's README states the pitch in one line ([`README.md`][readme]): _"A beautiful syntax highlighter based on TextMate grammar, accurate and powerful."_ The concrete problem is **build-time/server-side highlighting for the web**: docs sites, blogs, and frameworks want VS-Code-quality colors as _static HTML_ — no client-side highlighting cost, no flash of unstyled code — using the exact grammars and themes users already know from their editor. Shiki therefore consumes unmodified VS Code assets (TextMate grammars via [`tm-grammars`][tm-grammars], VS Code JSON themes via [`tm-themes`][tm-grammars]) and emits inline-styled `<pre>`/`<span>` markup or a [hast][hast] tree for further transformation.

The engine dependency is stated plainly in the docs ([`regex-engines.md`][regex-engines-md]):

> _"TextMate grammars are based on regular expressions that match tokens. More specifically, they assume that Oniguruma (a powerful regex engine written in C) will be used to interpret the regular expressions. To make this work in JavaScript, we compile Oniguruma to WebAssembly to run in the browser or Node.js."_

### Design philosophy

1. **Fidelity through reuse, not reimplementation.** Tokenization is delegated to a fork of VS Code's own engine (`@shikijs/vscode-textmate`), grammars and themes come from the VS Code ecosystem unmodified — so output matches the editor by construction. This is the same bet [syntect] makes on Sublime Text's grammar corpus, played in the web ecosystem.
2. **The environment is hostile to native code, so the regex engine is a plug.** Where [bat] simply links C Oniguruma, Shiki abstracts the engine behind a two-method interface and ships three tiers: WASM Oniguruma (maximum compatibility), JS `RegExp` transpilation (no WASM, smaller bundles), and a zero-dependency raw engine for precompiled grammars. Bundle size is a first-class design axis in a way no native highlighter has to consider.
3. **Output is a document, themed at render time — possibly for several themes at once.** Tokens carry resolved colors (or CSS variables for dual/multi-theme), and the pipeline ends in hast/HTML rather than a terminal stream. Interactivity is delegated to CSS (`light-dark()`, media queries) instead of re-highlighting.

---

## How it works

### Package architecture: bundles → `core` → `primitive`

The monorepo layers capability over a minimal center (~5.3 kLOC across the tokenizer stack; ~16.4 kLOC of package sources overall):

- **`@shikijs/primitive`** — _"Tokenizer primitives of Shiki"_ ([`package.json`][primitive-pkg]): the actual TextMate loop (`code-to-tokens-base.ts`, `code-to-tokens-themes.ts`), the `Registry` wrapper, `GrammarState`, theme normalization. No bundled languages, themes, or engines.
- **`@shikijs/core`** — _"Core of Shiki"_: the highlighter constructors (`createHighlighterCore`), the full pipeline (`codeToTokens` → `codeToHast` → `codeToHtml`), multi-theme merging, CSS-variable themes, ANSI-_input_ rendering (`code-to-tokens-ansi.ts` — for highlighting terminal dumps, not producing them).
- **`@shikijs/engine-oniguruma`** / **`@shikijs/engine-javascript`** — the two regex engines; **`@shikijs/types`** — shared types.
- **`shiki`** (main package) — convenience bundles (`bundle/full`, `bundle/web`) wiring core + engine + generated `@shikijs/langs` / `@shikijs/themes` data packages.

Grammar/theme data is **not vendored**: `@shikijs/langs` re-exports the [`tm-grammars`][tm-grammars] npm package (223 languages in the compat report; ~349 export entries) and `@shikijs/themes` re-exports [`tm-themes`][tm-grammars] (~68 themes) — a curated, separately versioned supply chain, where [bat] uses git submodules + a binary dump.

### Two regex engines (and a third, degenerate one)

The whole engine contract is two methods ([`types/src/engines.ts`][engines-ts]):

```ts
export interface RegexEngine {
  createScanner: (patterns: (string | RegExp)[]) => PatternScanner;
  createString: (s: string) => RegexEngineString;
}
```

- **Oniguruma engine** (`@shikijs/engine-oniguruma`) wraps `OnigScanner`/`OnigString` over an **inlined** `vscode-oniguruma` 1.7.0 WASM build — the reference semantics. The docs' recommendation ([`regex-engines.md`][regex-engines-md]): _"If you run Shiki on Node.js (or at build time) and bundle size or WebAssembly support is not a concern, the Oniguruma engine ensures maximum language compatibility."_
- **JavaScript engine** (`@shikijs/engine-javascript`) transpiles each Oniguruma pattern to a native `RegExp` with [`oniguruma-to-es`][onig-to-es]. The construction flags document the TextMate model's line-locality in passing ([`engine-compile.ts`][engine-compile-ts]):

  > _"Oniguruma option for `^`->`\A`, `$`->`\Z`; improves search performance without any change in meaning since TM grammars search line by line"_ (`singleline: true`)

  plus `allowOrphanBackrefs` (_"Needed since TextMate grammars merge backrefs across patterns"_), `lazyCompileLength: 3000` (_"avoids a perf penalty for precompiled grammars when constructing extremely long patterns that aren't always used"_), and a `target` option (`'auto' | 'ES2025' | 'ES2024' | 'ES2018'`) — ES2024+ uses the `RegExp` `v` (UnicodeSets) flag for a few more grammars, ES2018 falls back to `u`. The scanner (`JavaScriptScanner`) runs each compiled `RegExp` from the requested position, returns immediately on an anchored match, else keeps the closest; a `forgiving` mode skips unconvertible patterns instead of throwing. As of the pinned checkout the compat report is **223/223 languages supported, 0 mismatched** ([`engine-js-compat.md`][compat-md]; _"As of Shiki 3.9.1, all built-in languages are supported"_, [`regex-engines.md`][regex-engines-md]).

- **Raw engine** (`createJavaScriptRawEngine`) — _"Raw JavaScript regex engine that only supports precompiled grammars. This further simplifies the engine by excluding the regex compilation step. Zero dependencies."_ ([`engine-raw.ts`][engine-raw-ts]). Precompiled grammars (`@shikijs/langs-precompiled`, patterns pre-transpiled at publish time) skip `oniguruma-to-es` entirely — but the docs gate them: _"Pre-compiled languages are not yet supported, due to a known issue that affects many languages. Please use with caution."_ and they _"require support for RegExp UnicodeSets (the `v` flag), which requires ES2024 or Node.js 20+"_ ([`regex-engines.md`][regex-engines-md]).

### Tokenization: `tokenizeLine2` packed metadata over a carried stack

The heart is `_tokenizeWithTheme` in [`code-to-tokens-base.ts`][ctt-base-ts]: split the code into lines; for each line call the forked vscode-textmate's `grammar.tokenizeLine2(line, stateStack, tokenizeTimeLimit)`; carry `stateStack = result.ruleStack` to the next line. `tokenizeLine2` returns a packed `Uint32Array` of `(startIndex, metadata)` pairs — the theme is resolved _during_ tokenization, and `EncodedTokenMetadata` bit-fields decode foreground-color index and font style straight into the theme's `colorMap`. (A slower `tokenizeLine` variant returns full scope stacks; Shiki calls it only when `includeExplanation` is requested, attaching per-token scope explanations and the scope-selector matching logic.) This binary fast path is VS Code's own optimization, inherited intact.

The `Registry` subclass adds one perf-critical cache ([`registry.ts`][registry-ts]): _"cache the textmate themes as `TextMateTheme.createFromRawTheme` is expensive. Themes can switch often especially for dual-theme support."_

### `GrammarState`: forward-only streaming

TextMate state between lines is a rule-stack value, and Shiki reifies it ([`grammar-state.md`][grammar-state-md]): _"`GrammarState` is a special token that holds the grammar context and allows you to highlight from an intermediate grammar state, making it easier to highlight code snippets."_ A `GrammarState` wraps one `StateStack` **per theme**; you can extract it from a previous result (via a `WeakMap` keyed on the token array / hast root) and pass it as `grammarState`, or seed a one-off context with `grammarContextCode: 'let a:'` — the preamble is tokenized internally just to produce a starting stack. This is the checkpointing primitive for chunked highlighting: state flows strictly **top-down**, so a consumer can continue a document from a saved line boundary but can never start cold mid-file — the same constraint as [syntect]'s `ParseState` and the structural opposite of [tree-sitter-highlight]'s whole-buffer parse. The **`@shikijs/stream`** package (_"Streaming colorization for Shiki, useful for highlighting LLM outputs and other text streams"_, [`package.json`][stream-pkg]) builds exactly this: a stateful tokenizer re-tokenizing the trailing unstable region as chunks arrive.

### Multi-theme rendering: CSS variables and `light-dark()`

Single-theme output bakes resolved colors into inline styles. With a `themes: { light, dark, … }` map, `codeToTokensWithThemes` tokenizes once **per theme**, merges token streams by split-points, and emits per-token CSS variables — default prefix `--shiki-` ([`code-to-tokens.ts`][ctt-ts]) — with the default theme's color inline and the alternates as `--shiki-dark:#…` etc., switched by a media query or class. `defaultColor: 'light-dark()'` instead emits the native CSS [`light-dark()`][light-dark-mdn] function (_"You can also use `light-dark()` function to avoid manually maintaining the CSS variables"_, [`dual-themes.md`][dual-themes-md]), requiring both `light` and `dark` themes. Dark/light theming is thus resolved by the _browser_ at display time — no re-highlighting, no second document.

### Guards: per-line length and time budgets

Two knobs in [`types/src/tokens.ts`][tokens-ts] bound pathological inputs:

> _"Lines above this length will not be tokenized for performance reasons. `@default 0` (no limit)"_ (`tokenizeMaxLineLength`) — an over-long line is emitted as **one uncolored token** (`color: ''`) and the tokenizer moves on.
>
> _"Time limit in milliseconds for tokenizing a single line. `@default 500` (0.5s)"_ (`tokenizeTimeLimit`) — passed straight into `tokenizeLine2`, which abandons rule matching for that line when the budget expires.

Same failure mode as [bat]'s 16 KiB cutoff — degrade to plain text, never fail — but _time-based_ as well as length-based, and per line. (Notably the length guard defaults **off** here; bat's is always on.)

### The pipeline: `codeToTokens` → `codeToHast` → `codeToHtml`

`codeToTokens` produces `ThemedToken[][]` (a token list per line, colors resolved); `codeToHast` lifts them into a [hast][hast] tree (`<pre><code><span class="line">…`), where the **transformer** ecosystem hooks in (diff/focus/annotation decorations, line numbers, twoslash type popups); `codeToHtml` serializes. Because the intermediate form is a standard AST, downstream tooling composes with the unified/rehype world rather than with strings. Performance doctrine is documented, not implicit ([`best-performance.md`][best-perf-md]): _"The highlighter instance is expensive to create. Most of the time, you should create the highlighter instance once and reuse it"_ (singleton); call `dispose()` explicitly (_"It can't be GC-ed automatically"_); _"Avoid importing `shiki`, `shiki/bundle/full`, `shiki/bundle/web` directly"_ — compose `shiki/core` + one engine + exactly the `@shikijs/langs/*` you need (fine-grained bundles); use the lazy **shorthands** which load themes/languages on demand when highlighting can be async.

---

## Algorithm & grammar class

- **Formalism.** The [TextMate grammar model][sh-tm]: a pushdown machine over regex-defined rules (`match`, `begin`/`end`, `begin`/`while`, includes/repository) that scans **one line at a time**, accumulating a scope stack; no CFG, no tree, no lookahead across lines. All structure-tracking is the rule stack carried between lines.
- **Expressive ceiling.** Oniguruma-class regexes (backrefs, lookaround, recursion) per rule — well beyond regular languages per pattern, but classification remains _local to a line + stack context_. Constructs that require true cross-line or semantic context (heredoc terminators are handled via `while`; matched-brace context or def/use linking are not expressible) are approximated — the fidelity gap [tree-sitter-highlight]'s locals system exists to close.
- **The engine seam is semantic, not just mechanical.** Oniguruma vs `RegExp` differ in feature set and edge-case semantics; `oniguruma-to-es` closes the gap by _transpilation with explicit rules_ (orphan backrefs, `\G` anchoring, ASCII word boundaries) rather than pattern-by-pattern rewrites — the same class of divergence hazard [syntect] documents between its `onig` and `fancy-regex` back-ends, met with a compiler instead of a compatibility list.
- **Grammar supply.** `.tmLanguage.json` grammars curated in [`tm-grammars`][tm-grammars] — the VS Code ecosystem's corpus, patched centrally; Shiki inherits fixes by version bump.

## Interface & composition model

- **Layered library, factory-composed.** `createHighlighterCore({ themes, langs, engine })` receives everything as values — theme objects, grammar objects, an engine instance — so bundlers can tree-shake to exactly the used set; the batteries-included `shiki` bundles pre-wire common sets. The highlighter instance is the reuse unit (singleton doctrine above).
- **Everything async-first, sync opt-in.** Grammars/themes load via dynamic `import()`; `createHighlighter` awaits everything upfront so subsequent `codeToHtml` calls are synchronous; shorthands defer loading per call.
- **hast as the composition surface.** Transformers manipulate the token/hast stages rather than post-processing HTML strings — decorations, diff markers, and integrations (`rehype`, `markdown-it`, VitePress itself) all plug into the same AST.
- **The engine as a user-visible choice** is unique in this survey: the same grammars run on WASM Oniguruma, transpiled `RegExp`, or precompiled patterns, selected per deployment constraint (bundle size, WASM availability, startup latency).

## Performance

- **Cost center: regex scanning per line**, as in every [TextMate engine][sh-tm]. Shiki adds no algorithmic novelty at the scan level; its performance work is _around_ the scan: the packed `tokenizeLine2` fast path (no scope-string materialization), theme-object caching, compiled-`RegExp` caching in the JS scanner, `lazyCompileLength` for rarely-used giant patterns.
- **Startup is the managed axis.** Highlighter creation (grammar parsing, engine init, WASM load) is the expensive step — hence singleton + `dispose()`, fine-grained bundles, lazy shorthands, and precompiled grammars (skip transpilation entirely). This mirrors [bat]'s lazy binary assets solving the same cold-start problem in native form.
- **Pathology guards are per line and dual:** `tokenizeMaxLineLength` (length) and `tokenizeTimeLimit` (500 ms default, time) — catastrophic-backtracking damage is bounded per line, with plain-text degradation.
- **Multi-theme costs are linear in theme count** (one tokenization pass per theme), softened by the registry's theme cache; the merge into CSS variables is a token-stream zip.
- **No incrementality.** Highlighting is batch per code block; `GrammarState` enables _forward continuation_ (streams, appended chunks), not edit-local reuse. For its AOT/static use case that is the right trade — the browser never re-tokenizes at all.

## Highlighting & theme model

This is the extra spine dimension for the [syntax-highlighting cluster][sh]:

- **Label vocabulary — TextMate scope stacks, mostly invisible.** Tokens are classified by scope stacks (`source.ts meta.function entity.name.function`), but the fast path never materializes them: `tokenizeLine2` resolves theme + scopes to packed color/fontStyle metadata during the scan. Scope stacks surface only on request (`includeExplanation`), where each token lists the scopes and the theme selectors they matched.
- **Inter-unit state — the rule stack, reified.** `GrammarState` wraps the between-lines `StateStack` (per theme), extractable and re-injectable — the most explicit checkpointing API in the cluster ([syntect]'s equivalent is "clone `ParseState` + `HighlightState`"; [bat] hides it entirely; [tree-sitter-highlight] has no line state to checkpoint). Strictly forward-only.
- **Theme resolution — VS Code JSON `tokenColors`,** i.e. scope-selector rules (`scope: "keyword.control"` → `settings.foreground`) applied by specificity against the scope stack, precompiled into vscode-textmate's theme trie + `colorMap`. Same selector semantics family as [`.tmTheme`][sh-themes] (syntect), different serialization; the capture-name vocabulary of [tree-sitter-highlight] deliberately tracks these same scope names.
- **Rendering targets — HTML only, but pluripotent.** Inline styles (single theme), CSS variables per token (multi-theme), or `light-dark()`; hast in between for structured post-processing. Each `<span class="line">` is a self-contained element — the same per-line-validity property [tree-sitter-highlight]'s `HtmlRenderer` maintains by closing/reopening tags. There is **no ANSI output path** (the `ansi` "language" _reads_ ANSI dumps as input); a terminal tool takes the `ThemedToken[][]` and writes its own SGR fold — exactly the seam a dual-backend [`sparkles:syntax`][sh-fit] renderer occupies.

## Error handling & recovery

- **Input text cannot fail.** Unmatched text takes enclosing/default scopes; broken syntax mis-scopes at worst — the cluster's shared [degrade-gracefully posture][sh]. The guards convert pathological _cost_ into plain-text output (one uncolored token per over-budget line) rather than errors.
- **Failures are configuration-time:** unknown language/theme names throw `ShikiError` at load; `defaultColor: 'light-dark()'` without both themes throws at render setup ([`code-to-tokens.ts`][ctt-ts]); the JS engine in strict mode throws on unconvertible patterns at grammar load (`forgiving: true` skips them, trading silent pattern loss for robustness — mis-highlighting instead of failing).
- **Engine-mismatch risk is managed by report, not by construction:** the generated [compat table][compat-md] (223/223 at generation date) is the evidence that transpilation preserves behavior; regressions surface as mismatched languages in that report, the analogue of [bat]'s syntax-regression test suite guarding syntect/Sublime divergence.
- **The 500 ms default time limit** is the one place the cluster's engines differ on philosophy: Shiki bounds _time_ per line by default; [syntect]/[bat] bound only _length_; [tree-sitter-highlight] delegates the clock to the host entirely.

## Ecosystem & maturity

- **Adoption.** The default highlighter of the modern JS docs stack — VitePress (this site), Astro, Nuxt Content, Expressive Code, countless MDX pipelines — anywhere code is highlighted at build time.
- **History.** Created by Pine Wu (October 2018); rewritten from scratch by Anthony Fu as _Shikiji_ and merged back as **Shiki v1.0** (February 2024) — ESM-first, engine-pluggable, hast-based; the JS `RegExp` engine landed in v1.15.0 (August 2024) and adopted `oniguruma-to-es` in v1.23.0 (November 2024); `v4.3.1` at the pinned checkout.
- **Monorepo tooling:** pnpm workspace + catalogs, `tsdown`/rollup builds, vitest, 21 packages — the data packages (`langs`, `themes`, both precompiled variants) are code-generated shells over `tm-grammars`/`tm-themes`.
- **Fork surface:** Shiki maintains its own `@shikijs/vscode-textmate` fork (upstream moves at VS Code's pace and CommonJS shape) and inlines `vscode-oniguruma` — the project owns its whole engine chain.
- **Boundary:** batch/AOT by design. For live-editing highlighting in the browser, the ecosystem points at CodeMirror/[Lezer][lezer] or Monaco's own tokenizer (which `@shikijs/monaco` can replace); Shiki's own `@shikijs/stream` covers append-only streams, not edits.

---

## Strengths

- **VS Code fidelity by construction:** same grammar files, same theme files, a fork of the same tokenizer — output matches the editor pixel-for-pixel in color terms.
- **The only engine-pluggable TextMate implementation surveyed:** WASM Oniguruma ↔ transpiled `RegExp` ↔ precompiled, one grammar corpus, per-deployment choice; 223/223 language compat on the JS engine.
- **Best-in-class multi-theme story:** one pass per theme, merged tokens, CSS variables or native `light-dark()` — dark mode without re-highlighting or duplicated markup.
- **hast intermediate = real composability:** decorations, transformers, and the unified ecosystem operate on an AST, not on string output.
- **Explicit, documented performance model:** singleton + `dispose()`, fine-grained bundles, lazy shorthands, dual per-line guards — the operational knowledge is in the docs, not folklore.
- **`GrammarState` as a first-class value** — the cleanest between-lines checkpointing API in the cluster, and the substrate for streaming (LLM-output) highlighting.

## Weaknesses

- **HTML-only output:** no terminal/ANSI backend; a CLI tool must write its own SGR fold over `ThemedToken[][]`.
- **All the [TextMate model's precision limits][sh-tm]:** line-local regex classification, no structural context, no def/use consistency — approximate where [tree-sitter-highlight] is exact.
- **Startup weight:** grammar parsing + engine init (or WASM fetch) is heavy enough to need a whole documented mitigation playbook; native peers ([syntect] via [bat]'s binary dumps) cold-start faster.
- **JS-engine residual risk:** transpiled semantics are report-verified, not guaranteed; precompiled grammars are still gated behind a known issue and ES2024 `v`-flag support.
- **No incrementality at all** — batch per block; even the streaming package re-tokenizes trailing regions.
- **Fork maintenance burden:** owning `vscode-textmate` + inlined oniguruma means tracking upstream VS Code fixes manually.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                           | Trade-off                                                                              |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Reuse VS Code's tokenizer + grammar/theme corpus** (forked)     | Editor-identical output with zero grammar authorship; central fixes inherited by version bump       | Fork maintenance; bound to TextMate model limits; grammar quality is upstream's        |
| **Pluggable `RegexEngine`** (WASM / transpiled / precompiled)     | One codebase serves Node, browser, edge, bundle-size-constrained deployments                        | Three engines to keep semantically aligned; compat is report-verified, not proven      |
| **Transpile Oniguruma → `RegExp`** (`oniguruma-to-es`)            | No WASM, smaller bundles, sync init; explicit rules encode TextMate idioms (`singleline`, backrefs) | ES-version-dependent coverage (`v` flag); residual edge-case divergence risk           |
| **Packed `tokenizeLine2` metadata** (theme resolved in-scan)      | No scope-string materialization on the hot path; binary decode straight to colors                   | Scope stacks invisible by default; explanations need a second, slower tokenization     |
| **hast intermediate + transformers**                              | AST-level composition with the unified ecosystem; decorations without string surgery                | Heavier pipeline than direct string emission; hast knowledge required of integrators   |
| **Multi-theme via CSS variables / `light-dark()`**                | Theme switching is a browser/CSS concern — no re-highlight, no duplicate markup                     | One tokenization pass per theme at build; CSS-variable soup in the output              |
| **Per-line time budget (500 ms default) + optional length guard** | Bounds catastrophic-backtracking damage; never fails on input                                       | A slow line silently loses highlighting; time-based means non-deterministic under load |
| **Data as npm packages** (`tm-grammars`/`tm-themes`)              | Versioned, curated, tree-shakeable supply chain; no submodules or binary dumps in-repo              | Runtime grammar _parsing_ cost at load (vs [bat]'s pre-serialized binary assets)       |

---

## Sources

- [`README.md`][readme] — positioning line; [`LICENSE`][license] — MIT, Pine Wu 2021 / Anthony Fu 2023
- [`packages/primitive`][primitive-pkg] (`code-to-tokens-base.ts` — line loop, `tokenizeLine2`, guards; `textmate/registry.ts` — theme cache; `textmate/grammar-state.ts`) — the tokenizer core
- [`packages/engine-javascript/src/engine-compile.ts`][engine-compile-ts] + [`engine-raw.ts`][engine-raw-ts] — transpilation rules (the "line by line" comment), targets, raw engine; [`packages/types/src/engines.ts`][engines-ts] — the `RegexEngine` interface; [`packages/types/src/tokens.ts`][tokens-ts] — guard options
- [`packages/core/src/highlight/code-to-tokens.ts`][ctt-ts] — multi-theme merge, `--shiki-` prefix, `light-dark()`
- Docs (in-repo `docs/`, published at [shiki.style][docs]): [`regex-engines.md`][regex-engines-md] · [`best-performance.md`][best-perf-md] · [`grammar-state.md`][grammar-state-md] · [`dual-themes.md`][dual-themes-md] · [`engine-js-compat.md`][compat-md]
- Related deep-dives: [syntect] (same model, native) · [bat] (the CLI pipeline shape) · [tree-sitter-highlight] (the precise counterpart) · [Lezer][lezer] (the JS incremental parser world Shiki explicitly does not compete with) · [the highlighting synthesis][sh]

<!-- References -->

[repo]: https://github.com/shikijs/shiki
[docs]: https://shiki.style/
[readme]: https://github.com/shikijs/shiki/blob/main/README.md
[license]: https://github.com/shikijs/shiki/blob/main/LICENSE
[primitive-pkg]: https://github.com/shikijs/shiki/tree/main/packages/primitive
[stream-pkg]: https://github.com/shikijs/shiki/tree/main/packages/stream
[engine-compile-ts]: https://github.com/shikijs/shiki/blob/main/packages/engine-javascript/src/engine-compile.ts
[engine-raw-ts]: https://github.com/shikijs/shiki/blob/main/packages/engine-javascript/src/engine-raw.ts
[engines-ts]: https://github.com/shikijs/shiki/blob/main/packages/types/src/engines.ts
[tokens-ts]: https://github.com/shikijs/shiki/blob/main/packages/types/src/tokens.ts
[ctt-ts]: https://github.com/shikijs/shiki/blob/main/packages/core/src/highlight/code-to-tokens.ts
[ctt-base-ts]: https://github.com/shikijs/shiki/blob/main/packages/primitive/src/highlight/code-to-tokens-base.ts
[registry-ts]: https://github.com/shikijs/shiki/blob/main/packages/primitive/src/textmate/registry.ts
[regex-engines-md]: https://shiki.style/guide/regex-engines
[best-perf-md]: https://shiki.style/guide/best-performance
[grammar-state-md]: https://shiki.style/guide/grammar-state
[dual-themes-md]: https://shiki.style/guide/dual-themes
[compat-md]: https://shiki.style/references/engine-js-compat
[vscode-textmate]: https://github.com/microsoft/vscode-textmate
[onig-to-es]: https://github.com/slevithan/oniguruma-to-es
[tm-grammars]: https://github.com/shikijs/textmate-grammars-themes
[hast]: https://github.com/syntax-tree/hast
[light-dark-mdn]: https://developer.mozilla.org/en-US/docs/Web/CSS/color_value/light-dark
[syntect]: ./syntect.md
[bat]: ./bat.md
[tree-sitter-highlight]: ./tree-sitter-highlight.md
[lezer]: ./lezer.md
[sh]: ./syntax-highlighting.md
[sh-tm]: ./syntax-highlighting.md#the-textmate-grammar-model
[sh-themes]: ./syntax-highlighting.md#the-theme-format-landscape
[sh-fit]: ./syntax-highlighting.md#where-sparkles-syntax-fits
