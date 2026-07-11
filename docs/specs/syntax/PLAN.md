# `sparkles:syntax` — Delivery Plan

_Audience: contributors implementing the library. Execution-only — milestones,
dependencies, verification, deferrals. For the design rationale and prior-art
justification read the [proposal](./index.md); for the evidence base read the
[syntax-highlighting cluster](../../research/parsing/syntax-highlighting.md)._

> [!NOTE]
> **Status: in progress.** Milestones are deliberately incremental: each is
> independently useful and each commit stays green. The core (M1–M3) delivers the two
> backends over synthetic event streams before any engine exists; the engine (M4–M6)
> plugs into the finished seam. Work can stop at any boundary.

## 1. Milestone overview

| #      | Deliverable                                                                                             | Prior art                        | Depends on |
| ------ | ------------------------------------------------------------------------------------------------------- | -------------------------------- | ---------- |
| **M1** | Core seam: `event.d` (events, `byStyledSpan`), `label.d` (vocabulary, longest-dot-prefix), `color.d`    | [ts-highlight] · [helix] · [bat] | —          |
| **M2** | Theme layer (`theme.d`, `themes.d`) + ANSI backend (`render/ansi.d`)                                    | [helix] · [bat]                  | M1         |
| **M3** | `writeHtmlEscaped` (base) + HTML backend (`render/html.d`, stylesheet emitter)                          | [ts-highlight] · [shiki]         | M1, M2     |
| **M4** | `sparkles:tree-sitter` binding (ImportC, RAII, dlopen loader) + Nix runtime & grammar bundle (json)     | [importc] · [ts-highlight]       | —          |
| **M5** | Precise engine: registry, query config, text predicates, reference event loop → end-to-end ANSI/HTML    | [ts-highlight] · [helix]         | M1–M4      |
| **M6** | Full grammar bundle (target + docs-fence languages incl. D), language normalization, library docs       | [helix] (supply chain)           | M4, M5     |
| **M7** | _(next)_ Injections: merged query, `#set!` consumption, layer stack — markdown + fenced code end-to-end | [ts-highlight] · [helix]         | M5, M6     |

M1–M3 are pure D over `sparkles:base` and prove both backends with synthetic streams.
M4 is independent of M1–M3 (only the seam types are shared) and can proceed in parallel.
M5 is the integration milestone; M6 is supply chain + docs; M7 is scheduled but not part
of this drop.

## 2. Per-milestone detail

Each milestone's outcome: modules compiling `@safe pure nothrow @nogc` where the design
allows (explicit on non-templates, inferred on templates), unit-tested in feature modules
(never `package.d`), DDoc'd per [AGENTS.md](../../guidelines/AGENTS.md). New packages:
`libs/syntax` (`sparkles:syntax`, `sourceLibrary` — its engine modules import ImportC
types) and `libs/tree-sitter` (`sparkles:tree-sitter`, `sourceLibrary`).

### M1 — core seam

- `event.d`: `LabelId` (ushort + `none` sentinel), `HighlightEvent` (flat POD:
  `kind ∈ {source, push, pop}`, `start`/`end` byte offsets, `label`), the
  `isHighlightEventRange` concept, `byStyledSpan` (lazy innermost-wins flatten to
  `StyledSpan`), package-internal `HighlightStack` over `SmallBuffer`.
- `label.d`: `standardLabels` (~55 sorted canonical dotted names — union of the
  reference crate's recognized names and Helix's theme scopes), `LabelSet` with `find`
  (exact, binary search) and `resolve` (longest-dot-prefix), `fromNames` for custom
  vocabularies.
- `color.d`: `RgbColor`, `Color` sum type (`unset`/`default_`/`palette`/`rgb`),
  `parseHexColor` (incl. `#RRGGBBAA` alpha conventions), `ColorDepth`,
  `ansi256FromRgb` (6×6×6 cube + gray ramp), `ansi16FromRgb`, pure
  `classifyColorDepth(colorterm, term)` + env-reading `detectColorDepth()`.
- Tests: `@ctfe` proof that `standardLabels` is sorted/unique and resolution works at
  compile time; `@nogc` proofs for the stream fold; golden corners for the color folds;
  `parseHexColor` accept/reject.

### M2 — theme layer + ANSI backend

- `theme.d`: `FontStyle` bitflags, `StyleSpec { fg, bg, font }`, `ThemeRule`, `Theme`,
  `resolveTheme(theme, labels) → ResolvedTheme` (flat `labelId → StyleSpec` table;
  longest-dot-prefix; whole-spec wins; last rule wins among equal selectors).
- `themes.d`: `builtinDark` / `builtinLight` as `static immutable Theme` data with
  license attribution in the module DDoc.
- `render/ansi.d`: `renderAnsi(source, events, theme, w, AnsiOptions)` over
  `byStyledSpan`; `writeStyleTransition` (minimal SGR diff between adjacent runs, single
  `\x1b[0m` to empty) and `writeSgrColor` (per-depth encodings) as independently tested
  helpers; reset before every `\n`, re-open after; `ColorDepth.none` = passthrough.
- Tests: SGR goldens at all four depths via `checkWriter`; the per-line invariant
  (re-scan output with `byAnsiToken` + `SgrState`, assert inactive state at every line
  end); `@nogc` proof. A runnable README `[Output]` example over a synthetic stream.

### M3 — HTML backend

- `sparkles.base.text.html` (new base module): `writeHtmlEscaped` (the 5 entities),
  re-exported from `sparkles.base.text`; `dub test :base` stays green.
- `render/html.d`: `renderHtml(source, events, theme, w, HtmlOptions)` consuming raw
  events (nesting preserved); all open spans closed at `\n` and re-opened after
  (per-line-valid HTML); `inlineStyles` and `cssClasses` modes (dots→dashes,
  `classPrefix "syn-"`); `writeThemeStylesheet` for class mode. `cssVariables` reserved.
- Tests: goldens for both modes; per-line balanced-span property; escaping inside
  source; `@nogc` proof.

### M4 — tree-sitter binding + Nix supply chain

- `libs/tree-sitter`: ImportC shim `tree_sitter_c.c` (`#pragma attribute(push, nogc,
nothrow)` around `#include <tree_sitter/api.h>`; unique stem), `errors.d`
  (`TsErrorCode`/`TsError`), `wrappers.d` (RAII `TsParser`/`TsTree`/`TsQuery`/
  `TsQueryCursor`; `Expected` constructors; `CancelCtx` + `extern(C)` progress callbacks
  for the 0.25 `parse_with_options` / `exec_with_options` cancellation APIs — the
  deprecated timeout APIs are never used), `loader.d` (`version (Posix)` dlopen +
  `tree_sitter_<name>` dlsym + ABI window check `[13, 15]`; clean `unsupportedPlatform`
  error elsewhere; handles never dlclosed).
- Nix: `pkgs.tree-sitter` in the devshell; new `nix/packages/ts-grammars.nix` linkFarm
  (json only at this milestone) exported as `SPARKLES_TS_GRAMMAR_PATH` from the
  shellHook (CI runs tests inside the devshell, so the variable reaches CI unchanged).
- Tests: wrapper lifecycle, query-compile-error mapping, dlopen + ABI check of json,
  parse smoke (`ts_node_string` S-expression), guard behavior (size cap, deadline
  abort + `ts_parser_reset` reuse). Grammar-dependent tests gate on the env var with
  `skipTest`.

### M5 — the precise engine

- `syntax/ts/registry.d`: `GrammarRegistry` over `SPARKLES_TS_GRAMMAR_PATH`
  (first-hit-wins search path; dlopen cache; `queryText`), `canonicalLanguage`
  fence-label normalization.
- `syntax/ts/config.d`: `TsHighlightConfig.create(grammar, highlightsScm, …)` (single
  query in v1; the injections/locals parameters and pattern-index bookkeeping are laid
  down for M7), `configure(labelSet)` capture→`LabelId` mapping via the core's resolve.
- `syntax/ts/predicates.d`: the reference text-predicate set (`#eq?`/`#not-eq?`/
  `#any-*`, `#match?` via `std.regex`, `#any-of?`/`#not-any-of?`); `#set!` parsed and
  stored; `#is-not? local` recognized/ignored; unknown predicates →
  `ts_query_disable_pattern` + warning.
- `syntax/ts/highlighter.d`: `highlight(config, source, sink, HighlightOptions)` —
  guards, parse, cursor (match limit 256; optional deadline), then the reference event
  loop (single layer): predicate-filtered peekable capture stream with `removeMatch`,
  ends-pop-before-starts at equal offsets, same-node later-pattern-wins, cancellation
  every 100 iterations, pending-event emission. Internal `parse` → `highlightTree`
  split documented as the incremental seam.
- Tests: golden event fixtures (json — no predicates; python — `#match?`; d — gdamore
  queries); nesting/zero-width/same-node-override unit cases; end-to-end file → ANSI
  and HTML; one fixture cross-checked against the `tree-sitter highlight` CLI.

### M6 — grammar bundle + docs

- `ts-grammars.nix` grows to the full language set (D via `pkgs.tree-sitter.buildGrammar`
  from the pinned `gdamore/tree-sitter-d` flake input; typescript/tsx query chains;
  markdown **and** markdown-inline bundled for M7; xml/ocaml layout quirks normalized
  in the per-language entry).
- Per-language smoke tests (load grammar + compile query + highlight a snippet;
  `skipTest`-gated) — the query-dialect canary.
- Minimal `docs/libs/syntax/` Diátaxis tree + Libraries sidebar entry; README example
  highlighting real D source.

### M7 — injections _(next drop)_

Merged query construction (injections → locals → highlights with pattern-index
boundaries), `#set!` consumption (`injection.language`/`combined`/`include-children`),
layer stack with included ranges, registry-wired language lookup; markdown +
markdown-inline end-to-end, fenced D blocks highlighted inside markdown.

## 3. Verification

- **Per milestone:** `dub test :syntax` / `:tree-sitter` / `:base` green; M4's
  include-path proof `env -u NIX_CFLAGS_COMPILE -u CPATH -u C_INCLUDE_PATH dub test
:tree-sitter --force`; `nix build .#ts-grammars` and inspect the layout.
- **Suite:** `nix run .#ci -- --test --fail-fast`; degraded-environment proof:
  `SPARKLES_TS_GRAMMAR_PATH= dub test :syntax` → grammar tests skip (⊘), suite green.
- **Idiom conformance:** attributes explicit on non-templates / inferred on templates;
  `Expected` on all fallible engine paths; `@nogc` proofs for the stream fold and both
  renderers; tests in feature modules with `@("name")` UDAs.
- **Docs:** `npm run docs:build` green; README examples via
  `nix run .#ci -- --verify --files README.md`; this spec pair becomes the library's
  design-history reference next to `docs/libs/syntax/`.

## 4. Deferrals / non-goals

Per the [proposal §4](./index.md#4-non-goals-and-why): TextMate fast mode (second
engine, own spec addendum + Oniguruma binding), locals, CSS-variable multi-theme HTML,
theme-file parsing (TOML/JSON — `Theme` is plain data; only a parser is missing),
Linguist-style detection cascade, SDLang (no tree-sitter grammar), Windows
`LoadLibrary`, incremental/editor machinery, LSP semantic-token overlay, hast-structured
output, `TermCaps.colorDepth` promotion to `core-cli`.

**Recorded accommodation (Vulkan/GPU backend):** `byStyledSpan`, `StyledSpan`, and
`ResolvedTheme` are public API and tested as the third-backend contract; `FontStyle`
stays backend-neutral; `toRgb(Color, palette)` concretization and a `byStyledLine`
per-line adapter are the two planned additions; the engine seams for interactive use
(`highlightTree` over a persistent tree, viewport-bounded cursors, budgets/cancellation,
`@nogc` hot path) all serve that milestone. Nothing in v1 may be built in a way that
demotes these to renderer-internal details.

<!-- References -->

[survey]: ../../research/parsing/index.md
[ts-highlight]: ../../research/parsing/tree-sitter-highlight.md
[helix]: ../../research/parsing/helix.md
[bat]: ../../research/parsing/bat.md
[shiki]: ../../research/parsing/shiki.md
[importc]: ../../guidelines/importc-c-libraries.md
