# Agent Guidelines for Sparkles

Instructions for AI agents working on the `sparkles` codebase. This file is the
single source of truth: the root `AGENTS.md` is a symlink to it, and `CLAUDE.md`
includes it. Keep it accurate — a stale fact here propagates into every agent's work.

## Project Overview

`sparkles` is a D monorepo of CLI/library utilities. The root `dub.sdl` declares
these sub-packages (plus the internal `sparkles:test-runner-impl` implementation
library backing `sparkles:test-runner` — see the runner integration notes below):

| Sub-package                     | Path                        | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci`                            | `apps/ci`                   | Repository CI helper: runs/verifies markdown examples, standalone examples, sub-package tests, and markdown link maintenance                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `release`                       | `apps/release`              | Release automation: scans tags as SemVer, summarizes commits, suggests a bump, gathers notes ($EDITOR or a CLI LLM agent), tags and publishes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `hue`                           | `apps/hue`                  | Interactive syntax-highlighting file viewer / live theme previewer over `sparkles:syntax` with subcommands (`view`, `diff`, `pr`, `gallery`, `theme`, `overlay`, `config`) powered by `sparkles:core-cli` (ANSI + HTML, plus an optional raylib `--gui` backend behind the `gui` build config, on `sparkles:raylib-text`; `--gui` also renders a render-markdown.nvim-style markdown preview — heading icons, callouts, task lists, box-bordered aligned tables via `sparkles:core-cli` — and native ANSI in ` ```ansi ` fences via an off-screen `sparkles:ghostty` VT). Also ships as an **Android NativeActivity APK** (`nix build .#hue-apk`, dev shell `nix develop .#android` — both x86_64-linux only, since the NDK/SDK ship prebuilt for that host; see `docs/specs/hue/android.md`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `terminal`                      | `apps/terminal`             | Minimal raylib-based terminal emulator built on `sparkles:ghostty` and `sparkles:raylib-text`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `terminal-benchmark`            | `apps/terminal-benchmark`   | Render-CPU benchmark harness for the `terminal` emulator (`/proc` CPU sampling; idle/render/churn scenarios)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `twoslash-extract`              | `apps/twoslash-extract`     | Batch D twoslash extractor: runs the `sparkles:twoslash-d` pipeline over an annotated D sample (or a directory, one child process per file) and writes the `.twoslash.json` payload `hue --twoslash` renders; `--verify` guards the golden fixtures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `ui-gallery`                    | `apps/ui-gallery`           | A browsable catalog of the `sparkles:ui` toolkit — widget kinds, layout, the 36 themes, the component set and the interaction machines — written as a `sparkles:ui-app` component, so one `view` serves both the terminal and the window. Also the host contract's first real consumer, and `sparkles:terminal-view`'s embedding proof (`TVW7`): the Terminal page runs real shells in VSCode-style tabs, terminal-in-terminal included. `--render`/`--render-plain` paint one frame with no backend at all                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `diagram`                       | `apps/diagram`              | A draw.io-style diagram board on `sparkles:ui-app` — an infinite world with a camera, a dense entity store, orthogonal connectors, groups, labels and a configurable Cartesian grid backdrop (`--config-file`, plus a modal `PropertyTree` settings pane over the live config — `,` or the context menu). It exists to stress the host abstraction from a direction hue and terminal cannot: neither has a camera, a world coordinate space, or a surface larger than its viewport. Its central claim is checkable by grep — no backend name appears anywhere under `apps/diagram/` (`DIA1`/`DIA2`), and `--tui` and `--gui` are the same `view`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `sparkles:base`                 | `libs/base`                 | Allocation-conscious foundation utilities: `Buffer` (four storage policies), lifetime helpers, `@nogc` text readers/writers, terminal styling, terminal capability probing (`term_caps` — size/tty/colors/unicode, the single place that decision is made), hardware parallelism (`hw_caps` — CPU quota/affinity plus memory/load/swap so a pool is not wider than the host can usefully run), styled IES, and logging                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `sparkles:build-primitives`     | `libs/build-primitives`     | Build-system and VCS primitives: `.gitignore` parsing/matching (nested + ancestor scopes) and a DbI-hook directory walker (`walkGitRepository`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sparkles:code-instrumentation` | `libs/code-instrumentation` | Code coverage ingestion library: universal coverage data model (`LineCoverage`, `FileCoverage`, `CoverageReport`), multi-format parsers over a shared record scanner (DMD `.lst`, GCC `gcov`, LCOV `.info`, V8 AST byte-range blocks, llvm-cov JSON) reporting failures as `ParseExpected`, anchored format auto-detection, and overlay planning (`CoveragePlan`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `sparkles:core-cli`             | `libs/core-cli`             | CLI argument parsing, help formatting, interactive prompts, process utilities, ANSI unstyle helpers. The UI components moved to `sparkles:ui` (`sparkles.ui.components.*`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `sparkles:diff`                 | `libs/diff`                 | Text diff engine behind hue's diff & PR viewer ([spec](../specs/hue/diff-view.md) `DVM*`): a backend-neutral diff document model (files → hunks → rows with pairing + intra-line emphasis), Myers line diff with scale guards, similarity alignment pairing (linematch-style DP), guarded word-level refinement (over its own token classes, or over boundaries a caller supplies via `refinePairTokens` — which is how hue's grammar-aware structural view reuses the LCS without the engine learning about tree-sitter), and a unified-patch parser/emitter (`ParseExpected` errors, output-range emit). `@safe pure nothrow @nogc` throughout: a flat arena of plain-data elements owned by `SharedBuffer` (CoW), texts borrowed as spans. Tree-sitter-free by design — `sparkles:base` is its only dependency                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `sparkles:dmd-fmt`              | `libs/dmd-fmt`              | D formatter being built on the DMD-lexer token spine per `docs/research/code-formatting/dmd-fmt-proposal.md` (M0–M8 delivered — decisions, spike evidence and milestone table in `docs/specs/dmd-fmt/`; v1 policy: author's-breaks + structural reindent, magic trailing comma, `.editorconfig`/dfmt-key discovery, `dmd-fmt` CLI via the `cli` dub configuration): `spine.d` lexes with `commentToken`+`whitespaceToken`, records exact byte spans, surfaces silently-consumed bytes (`#line`, shebang) as explicit directive entries, and proves byte-for-byte reconstruction plus token-equality against a plain lex and doc-lex offset correspondence; `oracle.d` reduces a parse-only AST walk to sorted offset arrays (dfmt's `ASTInformation` shape); `groups.d` proves S2 — nested group trees reconstructed from the spine plus those arrays alone (bracket matching + markers + bounded lookahead), degrading to bracket-only structure on unparseable input; `cases.d` is the markdown case runner (a fixture is a documentation page: a `::: code-group` under an `<!-- fmt id=P19 -->` directive, first fence in / later fences out, `SPARKLES_UPDATE_GOLDENS=1` to bless — see `docs/specs/dmd-fmt/testing.md`); `verify.d` is the M1 verifier — `verifyFormat` (tier-3 token equality modulo whitespace + the separate DDoc-attachment check via the doc-lex, catching whitespace-only trailing-`///` reattachment) and `checkConvergence` (bounded idempotence harness with per-step verification). DMD's frontend globals are not thread-safe, so all lexing/parsing serializes on a module lock |
| `sparkles:dmd-lsp`              | `libs/dmd-lsp`              | DMD-frontend-as-a-library semantic core (ported from VisualD `dmdserver`, Boost-1.0): one-pass in-memory analysis with structured diagnostics, the `semvisitor` type oracle (`tipAt` resolved types + ddoc, `identifierSpans` classification, `definitionAt`), on the pinned `dmdserver-dub` LanguageServer fork (dub git dep; runtime sources via `$SPARKLES_DMD_IMPORT_PATH`) — see `docs/specs/dmd-lsp/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `sparkles:docs`                 | `libs/docs`                 | Markdown-based static documentation-site (SSG) library, extracted from hue's gallery: the content-fragment builders (plain + twoslash, over `sparkles:syntax`/`sparkles:twoslash`), the page shell with theme-derived chrome, appearance toggle and breadcrumbs, the mirrored site tree with per-directory indexes, shared stylesheet assets, the recursive document set (over `sparkles:build-primitives`' glob walk), and the docs-site sidebar/`srcExclude` data schema (`sparkles:wired`) that `ci --check-docs-sidebar` / `--audit-fences` consume. hue's `gallery` subcommand is its first consumer; the planned `hue site` + API doc generator build on it (spec: `docs/specs/hue/gallery.md` `GAL*`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `sparkles:dql`                  | `libs/dql`                  | D Query Language engine: path-based aggregate addressing, typed constraint evaluation, fuzzy matching via `sparkles:fuzzy`, zero-allocation predicate filtering, and schema introspection (spec: `docs/specs/dql/SPEC.md`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `sparkles:dsv`                  | `libs/dsv`                  | Delimiter-Separated Values engine behind hue's DSV preview / data browser ([spec](../specs/hue/dsv-preview.md) `DS*`): dialect detection (delimiter/quote/header sniffing over a bounded sample, incl. the semicolon-CSV case), a tolerant RFC 4180 parser with a raw-byte-span **identity channel** per cell (ragged rows degrade, never error), and sampled typed columns. Offsets-not-copies over borrowed sources; `@safe pure nothrow @nogc` throughout; `sparkles:base` is its only dependency                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `sparkles:event-horizon`        | `libs/event-horizon`        | Completion-first (io_uring/kqueue/IOCP) event loop with a native algebraic-effect layer (three API tiers: callback, direct-style fibers, `Effect!T`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `sparkles:fuzzy`                | `libs/fuzzy`                | Bounded allocation-free fuzzy search core: Unicode-aware query/constraint parsing, Thompson-NFA globs, exact needle-deletion witnesses with source-byte positions, affine-gap ranking with a deterministic fallback, composite scoring and global top-K, fixed-point frecency/combo history, and generation-bound chunked search. Depends only on `sparkles:base` and `expected`; hue owns clocks, jobs, snapshots, and persistence (spec: `docs/specs/fuzzy/`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sparkles:ghostty`              | `libs/ghostty`              | D bindings + ImportC integration layer for `libghostty-vt` (Ghostty's terminal VT engine)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `sparkles:http`                 | `libs/http`                 | HTTP/1.1 building blocks (request parser + minimal server API) over `sparkles:event-horizon`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `sparkles:input`                | `libs/input`                | Abstract, capability-tiered input vocabulary shared by every `sparkles:ui` target: events as Regular values (a sum type over key/pointer/wheel/focus/resize, positions in the toolkit's 0-based cells) plus the tier-0/1/2 interaction ladder; `sparkles:tui` decodes its wire formats directly into it (design: `docs/specs/ui/input.md`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `sparkles:math`                 | `libs/math`                 | Small math primitives for games/graphics (early stage)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `sparkles:metadata`             | `libs/metadata`             | Dependency-free passive UDA vocabulary (`Name`, `Aliases`, `Label`, `Description`, `Range`) shared without coupling foundational libraries to CLI, serialization, UI, or query-engine policy                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `sparkles:reflection`           | `libs/reflection`           | Dependency-free structural reflection kernel: one closed `typeKindOf` classification and indexed field/property primitives (the field spine, public getter discovery incl. const-readability, the value-like wrapper rule, CTFE helpers) that consumers build their own walks from; the property tree, text writers, and query schemas all dispatch on it — structure here, policy (and each traversal) in the consumers ([docs](../libs/reflection/index.md))                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `sparkles:raylib-text`          | `libs/raylib-text`          | Reusable raylib text-rendering core shared by `apps/terminal` and `hue --gui`: a multi-face `FontSet` (real bold/italic variants, on-demand atlas growth, `--font-codepoint-map` routing), `drawGrapheme`/`drawSolid` + a per-run `drawText`, and procedural box-drawing (`drawBox`, so `─│┼╭…` connect across cells instead of using gappy font glyphs)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `sparkles:source-view`          | `libs/source-view`          | Source viewing and markdown rendering components over `sparkles:ui` (`sparkles.source_view.code`, `sparkles.source_view.markdown`): maps syntax-highlighted code and structural markdown ASTs into `sparkles:ui` `WidgetTree` nodes for backend-neutral GUI/TUI rendering parity, with fence scrolling, foldable sections, callouts, task lists, and box-bordered aligned tables                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `sparkles:syntax`               | `libs/syntax`               | Syntax highlighting: engine-agnostic highlight-event stream, scope-compatible label vocabulary, theme layer, ANSI + HTML renderers, tree-sitter precise-mode engine (design: `docs/specs/syntax/`), plus a structural markdown model (`md/model.d`, `extractMarkdown`) with an `MdDoc → HTML` emitter (`md/render_html.d`) for preview/doc renderers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `sparkles:terminal-view`        | `libs/terminal-view`        | The terminal core as an embeddable component, extracted from `apps/terminal` (spec: `docs/specs/ui-app/terminal-view.md`, `TVW`): `TerminalView` — the whole emulator as a `runApp` component (libghostty screen, per-cell raylib renderer, pty lifecycle, the byte-oracle-pinned key encoding seam, OSC color-query replies) — plus the embedding surface (`frame` at a pane size, `paintPane`, and the host-free `pump`/`decideRedraw`/`sendKey`/`notifyFocus`/`resize`/`openCore`) and `cell_paint.d`, which renders the VT screen through any `isCanvas` target so a pane works fontless in a terminal. Embedded by `apps/ui-gallery`'s Terminal page (`TVW7`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `sparkles:test-runner`          | `libs/test-runner`          | General-purpose `unittest` runner (silly successor): parallel runtime tests plus `@ctfe`, `@betterC`, `@wasm`, `@benchmark`, and `@workload` modes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `sparkles:test-utils`           | `libs/test-utils`           | Testing helpers: diff tools, temp-filesystem helpers, string helpers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `sparkles:tree-sitter`          | `libs/tree-sitter`          | D bindings for the tree-sitter C runtime: ImportC surface, RAII wrappers with `TsError` reporting, grammar dlopen (grammars supplied by the nix `ts-grammars` bundle via `$SPARKLES_TS_GRAMMAR_PATH`; all come from nixpkgs except SDLang — in-house at [`PetarKirov/tree-sitter-sdl`](https://github.com/PetarKirov/tree-sitter-sdl), `nix/packages/tree-sitter-sdl.nix` — and D, pinned to [`PetarKirov/tree-sitter-d`](https://github.com/PetarKirov/tree-sitter-d) for DUB single-file recipe injections, `nix/packages/tree-sitter-d.nix`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sparkles:tui`                  | `libs/tui`                  | Full-screen interactive terminal substrate: a 2-D cell grid with a compact packed cell (`GridT`), a retained diff compositor (`Screen`), terminal lifecycle (raw mode / alt screen / mouse), SGR-1006 input decoding, an event loop, and the terminal geometry vocabulary (`TermPosition`). Rendering core chosen by measurement — see `docs/specs/tui/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `sparkles:twoslash`             | `libs/twoslash`             | Twoslash render overlay on `sparkles:syntax`: the TypeScript-`twoslash` node model as opaque data (JSON via `sparkles:wired`) rendered as type-annotation overlays in HTML (the `.twoslash-*` contract + CSS), ANSI meta-lines, and the `hue --gui` raylib backend; `render_widgets.d` maps the node model to a `sparkles:ui` `WidgetTree` for backend-neutral GUI/TUI parity                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `sparkles:twoslash-d`           | `libs/twoslash-d`           | The D twoslash analyzer: notation parser (`^?`, `---cut---` family, `@errors:`/`@dflags:`/`@import:`, custom tags), node assembly over `sparkles:dmd-lsp` (hover-per-identifier + ddoc, queries, error nodes, two-phase cut/position resolution), and the `.twoslash.json` emitter with the D producer contract (`language`/`offsetEncoding`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `sparkles:twoslash-protocol`    | `libs/twoslash-protocol`    | The twoslash node model (`Node`/`TwoslashReturn`) + wired JSON ingest, extracted from `sparkles:twoslash` so producers (`sparkles:twoslash-d`) consume it without the render lib's `sourceLibrary` closure; owns the `language`/`offsetEncoding` payload declaration and the legacy UTF-16 offset normalization                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sparkles:ui`                   | `libs/ui`                   | Canvas-first three-level UI toolkit (state-machines / layout / widgets) — the repository's single UI stack: a DbI `isCanvas!T` backend seam, a semantic `Slot`/`Palette` style layer, a unified `Theme` (syntax rules + slots + metrics + glyphs, runtime-swappable), a flat-arena widget model, box-flow layout, the `view→layout→buildDisplayList→paint` pipeline, `components/` — the terminal component set (box/table/tree/meter/tasklist/live/…) moved here from `core-cli` — and the keymap/lantern layer (`keymap.d`/`lantern.d`/`components/lantern_view.d`: bindings-as-data over app-supplied command/scope enums plus the which-key-style guide, extracted from hue; spec: `docs/specs/ui/keymap.md`). GL-free; geometry specializes `sparkles:math`'s `Vector`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `sparkles:ui-app`               | `libs/ui-app`               | The application host for `sparkles:ui`: backend selection (`--gui`/`--tui`/`--html`, display probing, the Android answer), the shared window/font CLI and its setup order, and the frame/event loop — so an application never names a canvas. Ships three configurations (`tui`/`gui`/`full`) and a headless recording target that makes an app's own frame loop testable (design: `docs/specs/ui-app/`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `sparkles:ui-raylib`            | `libs/ui-raylib`            | `sparkles:ui`'s GPU backend adapter: `RaylibCanvas` scales the toolkit's cell-space display list to pixels over the shared `sparkles:raylib-text` `FontSet`, and `RaylibEvents` synthesizes `sparkles:input` events from raylib's polled state (press/release edges, drag, wheel, typed characters, focus/resize)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `sparkles:ui-tui`               | `libs/ui-tui`               | `sparkles:ui`'s terminal backend adapter: `GridCanvas` paints the toolkit's display list into a `sparkles:tui` cell grid (compositing fills, box-drawing borders, undercurl squiggles, clip stack), which the tui `Screen` cell-diffs to a minimal byte stream                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `sparkles:versions`             | `libs/versions`             | Design-by-Introspection versioning library (SemVer, DMD, CalVer, PyPI, Maven, Deb, …) with VERS/pURL interop                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `sparkles:vulkan`               | `libs/vulkan`               | Vulkan bindings over the target's real headers: loader discovery, branded handles, typed results, compile-time `sType`, bounded enumeration, extension/flag/name helpers and per-instance/device dispatch; Linux surface ABI comes from target-gated ImportC headers while the minimal Win32/Metal surface fragments avoid importing SDK inline bodies, and all ownership/policy stays in consumers such as `sparkles:vulkan-wsi`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `sparkles:vulkan-wsi`           | `libs/vulkan-wsi`           | Renderer bridge above native WSI: validates typed native handle pairs, enables the matching target-gated Vulkan surface extension, owns instance/surface/device/graphics+present queue selection, and brackets Wayland ICD calls with the WSI native-I/O borrow so Mesa cannot deadlock against Event Horizon's prepared read; it also owns the backend-neutral command pool, frame synchronization, swapchain decisions and deferred retirement that `sparkles:ui-sdl3` consumes through compatibility re-exports; the native triangle follows `docs/specs/window-system-integration/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `sparkles:wsi`                  | `libs/wsi`                  | Dependency-light native desktop window-system integration: unit-explicit geometry, generation-safe ids, typed errors/raw handles, lossless Regular events and a deterministic recording backend; native Wayland, X11, Win32 and AppKit lifecycle adapters share Event Horizon's only wait (Wayland/XCB over uring, User32/IOCP and CFRunLoop/kqueue), with immediate Wayland configure ack, a renderer native-I/O borrow, and IMM32 text input on Win32; XIM and remaining features follow `docs/specs/window-system-integration/`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `sparkles:wired`                | `libs/wired`                | Serialization: a compile-time-reflected wire format with a JSON surface (`fromJSON`/`toJSON`), used for opaque payload ingest (e.g. the twoslash node model)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

Each library **should** be documented under `docs/libs/<name>/` as a
[Diátaxis](https://diataxis.fr/) tree (`tutorial/`, `how-to/`, `reference/`,
`explanation/`). Today `sparkles:base`, `sparkles:code-instrumentation`, `sparkles:dmd-fmt`,
`sparkles:fuzzy`, `sparkles:syntax`, `sparkles:test-runner`,
`sparkles:twoslash`, `sparkles:ui`, and `sparkles:versions` are documented
([`docs/libs/base/`](../libs/base/index.md),
[`docs/libs/code-instrumentation/`](../libs/code-instrumentation/index.md),
[`docs/libs/dmd-fmt/`](../libs/dmd-fmt/index.md),
[`docs/libs/fuzzy/`](../libs/fuzzy/index.md),
[`docs/libs/syntax/`](../libs/syntax/index.md),
[`docs/libs/test-runner/`](../libs/test-runner/index.md),
[`docs/libs/twoslash/`](../libs/twoslash/index.md),
[`docs/libs/ui/`](../libs/ui/index.md),
[`docs/libs/versions/`](../libs/versions/index.md)); `core-cli`, `test-utils`,
`math`, `ghostty`, and `tree-sitter` do not yet have a `docs/libs/<name>/`
tree. When you add or substantially extend a library, add/extend its docs in
that location.

## Detailed Guidelines

Cross-cutting guides live in `docs/guidelines/`:

- **[Code Style](./code-style.md)** — Formatting, naming, module layout, imports
- **[D Style](./dstyle.md)** — Broader D style reference
- **[Functional & Declarative Programming](./functional-declarative-programming-guidelines.md)** — Range pipelines, UFCS, purity, lazy evaluation
- **[Design by Introspection — Intro](./design-by-introspection-00-intro.md)** & **[Guidelines](./design-by-introspection-01-guidelines.md)** — Capability traits, optional primitives, shell-with-hooks pattern
- **[Interpolated Expression Sequences](./interpolated-expression-sequences.md)** — IES syntax, metadata processing, context-aware encoding
- **[DDoc](./ddoc.md)** — Documentation comments, sections, macros, cross-referencing
- **[Writing Research Docs](./research-docs.md)** — Research catalog layout, deep-dive & index skeletons, house style, VitePress gotchas, co-located runnable samples
- **[Cutting a Release](./release.md)** — Single-monorepo versioning, pre-1.0 SemVer, annotated-tag changelog format, publishing to code.dlang.org
- **[Integrating C Libraries (ImportC)](./importc-c-libraries.md)** — Adding a C dependency via ImportC + pkg-config + Nix + dub (`sourceLibrary` gotcha)
- **[Benchmarking & Profiling](./benchmarking-and-profiling.md)** — Measuring the terminal renderer (`terminal-benchmark`, `perf`, `vtebench`/`termbench`); render- vs parse-bound; the measure→profile→fix loop
- **[Modern D Language Features](./d-language-features/index.md)** — Changelog-sourced survey (2.060–2.112) of the language features new code should reach for (plus the few still-legal legacy forms to retire); agent grounding protocol lives in the unpublished `d-language-features/AGENTS.md` (VitePress-excluded)
- **[Composable Memory Allocators](./allocators/index.md)** — Survey of `std.experimental.allocator`: the capability-by-presence protocol, `make`/`dispose`, building blocks, combinators, and composition patterns — with CI-verified runnable examples
- **Idioms** — [Expected Error Handling](./idioms/expected/index.md), [Forcing Named Arguments](./idioms/forced-named-arguments/index.md)

## Repository Layout

```
sparkles/
├── flake.nix                       # Nix flake (devshell, `ci` package, checks)
├── dub.sdl                         # Root package; declares the 48 sub-packages
├── apps/
│   ├── ci/                         # `ci` helper (executable sub-package)
│   │   ├── src/app.d               # Markdown example runner / verifier, link maintenance
│   │   ├── src/dub_deps.d          # In-tree dependency rewriting helpers
│   │   ├── dub.sdl
│   │   └── dub.selections.json
│   ├── diagram/                    # draw.io-style board on `sparkles:ui-app` (executable)
│   │   ├── src/app.d               # CLI (`--config-file`) + runApp; the only untested line
│   │   ├── src/diagram_app.d       # the component: view/handle/paint; heap-only via `create`
│   │   ├── src/world.d             # dense entity columns, flat groups, cascading edges
│   │   ├── src/camera.d            # world ⇄ screen, the zoom exponent, floor-to-−∞ rounding
│   │   ├── src/keymap.d, lantern.d # the binding table, and the guide bound to it
│   │   ├── src/grid_file.d         # `--config-file`: grid JSON, fail-closed both ways
│   │   ├── src/settings.d          # the pane's subject: the live GridConfig + board prefs
│   │   ├── src/settings_pane.d     # the modal `PropertyTree` over it (`SET`)
│   │   └── src/systems/*.d         # input.d (tools/capture/pan/zoom), render.d (op streams)
│   ├── release/                    # release automation helper (executable)
│   │   ├── src/app.d               # CLI + orchestration (stats → bump → notes → stages)
│   │   ├── src/git.d               # git/gh porcelain wrappers
│   │   ├── src/conventional.d      # conventional-commit parsing; bump.d/stages.d policy
│   │   ├── src/agents.d            # CLI LLM-agent registry (PATH-filtered)
│   │   └── src/notes.d             # $EDITOR seeding / comment stripping
│   ├── terminal/                   # raylib-based terminal emulator (executable)
│   │   ├── src/app.d               # Window/render loop, font + PTY setup
│   │   └── src/input.d             # Keyboard/mouse → libghostty-vt encoding
│   ├── terminal-benchmark/         # render-CPU benchmark harness (executable)
│   │   ├── src/app.d               # scenario runner + /proc CPU sampling
│   │   └── src/bench.d             # testable bench logic
│   └── ui-gallery/                 # the sparkles:ui catalog (executable)
│       ├── src/app.d               # CLI + runApp; --render paints one frame headless
│       ├── src/gallery.d           # the component: view/handle member templates
│       ├── src/registry.d          # the Page table + the catalog-wide test sweep
│       ├── src/state.d             # GalleryState: every machine the shell owns
│       ├── src/kit.d, render.d     # the page view vocabulary; frame → ANSI/glyphs
│       └── src/pages/*.d           # one module per catalog entry
├── libs/
│   ├── base/src/sparkles/base/
│   │   ├── lifetime.d              # recycledInstance / recycledErrorInstance (@nogc throwing)
│   │   ├── logger.d                # CoreLogger, DeltaTimeLogger, Sparkles logging wrappers
│   │   ├── prettyprint.d           # Colorized pretty-printing
│   │   ├── buffer.d               # Buffer + Storage policies, checkToString/checkWriter helpers
│   │   ├── source_uri.d            # OSC 8 source-URI hooks (editor links)
│   │   ├── styled_template.d       # IES-based styled text processing
│   │   ├── term_caps.d             # Terminal capability probing (size, tty, colors, unicode)
│   │   ├── hw_caps.d               # Hardware parallelism (CPU quota/affinity, RAM, load, swap)
│   │   ├── term_style.d            # Terminal styling/colors
│   │   └── text/                   # @nogc text package: readers.d, writers.d, errors.d, package.d
│   ├── build-primitives/src/sparkles/build_primitives/
│   │   ├── gitignore.d             # .gitignore rule parsing/matching + GitIgnoreStack (nested/ancestor scopes)
│   │   ├── dir_walk.d              # DbI-hook directory walker; walkGitRepository / GitRepositoryFilter
│   │   └── glob_walk.d             # include/exclude globs over the gitignore walk (GitGlobFilter)
│   ├── code-instrumentation/src/sparkles/code_instrumentation/
│   │   └── coverage/               # models, record scanner, formats (dmd, gcov, lcov, v8, llvm), ingest, overlay
│   ├── docs/src/sparkles/docs/     # SSG doc-site library: fragment.d, options.d, page_shell.d,
│   │                               # site_tree.d, breadcrumbs.d, assets.d, source_set.d, sidebar.d
│   ├── core-cli/src/sparkles/core_cli/
│   │   ├── args.d                  # CLI argument parsing (@CliOption, parseCliArgs)
│   │   ├── common_dirs.d           # XDG / standard directory lookup
│   │   ├── help_formatting.d       # --help output formatting
│   │   ├── prompts.d               # Interactive prompts (select/confirm/textInput + PromptPolicy)
│   │   ├── process_utils.d         # Process execution + RSS/CPU monitoring
│   │   ├── term_unstyle.d          # Strip ANSI escapes
│   │   └── key_input.d             # Raw-key session helpers (the UI components moved to sparkles:ui)
│   ├── versions/src/sparkles/versions/
│   ├── ui/src/sparkles/ui/          # canvas-first toolkit: geometry + style (Slot/Palette) + theme (one design language) + canvas (isCanvas!T) + widget + layout + state + display_list + interp/{immediate,cells,html}
│   │   └── components/             # box, header, table, live, tasklist, progress, meter, tree, layout, theme, osc_link, demo (moved from core-cli)
│   ├── ui-app/src/sparkles/ui_app/  # the application host: backend.d (pick) + gui_options.d/gui_setup.d (window+font CLI) + host.d/run.d (the loop) + tui_loop.d/gui_loop.d (arms) + record.d (headless target)
│   ├── twoslash/src/sparkles/twoslash/  # protocol (node model) + ingest (wired JSON) + overlay planner + render_html/render_ansi/render_widgets (sparkles:ui view) + style
│   │   ├── schemes/                # semver.d, dmd.d, calver_*.d, pypi.d, maven.d, deb.d, … + registry.d
│   │   ├── operations.d, ranges.d, parsing.d, traits.d, any.d
│   │   ├── purl.d, vers.d          # pURL / VERS interop
│   │   └── testing.d               # checkRoundTrip / checkRejects / checkAscending
│   ├── test-runner/src/sparkles/test_runner/   # the shim (sourceLibrary, compiled into consumers)
│   │   ├── attributes.d            # @betterC / @ctfe / @wasm / @benchmark marker UDAs
│   │   ├── discovery.d             # compile-time unittest discovery → Test[]
│   │   └── register.d              # extendedModuleUnitTester hook + extern(C) seam
│   ├── test-runner-impl/src/sparkles/test_runner/  # prebuilt impl library (internal)
│   │   ├── runner_impl.d           # extern(C) entry, CLI, mode dispatch
│   │   ├── model.d, filter.d       # Test/TestResult data model; regex include/exclude
│   │   ├── execution.d, reporting.d # parallel execution; styled result rendering
│   │   ├── bench.d                 # benchIter/blackBox, auto-scaling measurement
│   │   ├── extract.d, driver.d     # unittest-body extraction; -betterC/wasm drivers
│   │   └── ctfe_trace.d            # -ftime-trace CTFE cost attribution
│   ├── test-utils/src/sparkles/test_utils/
│   │   └── diff_tools.d, tmpfs.d, string.d, package.d
│   ├── input/src/sparkles/input/   # events.d (sum-type Event + Key/Mods/Point vocabulary), tier.d (tier-0/1/2 ladder)
│   ├── math/src/sparkles/math/     # vector.d, package.d
│   ├── raylib-text/src/sparkles/raylib_text/  # multi-face FontSet (on-demand atlas, real bold/italic) + drawGrapheme/drawSolid/drawText (shared by terminal + hue --gui)
│   └── ghostty/src/sparkles/ghostty/
│       ├── c.c                     # ImportC shim: #include <ghostty/vt.h>
│       └── package.d               # public import sparkles.ghostty.c
├── docs/
│   ├── guidelines/                 # Cross-cutting agent/style guides (this file lives here)
│   ├── libs/<name>/                # Per-library Diátaxis docs (currently: base/, versions/)
│   ├── research/                   # Background research notes
│   ├── specs/                      # Design specs
│   └── overview.md, index.md
└── nix/
    ├── dub-lock.json               # Nix-format lockfile shared by `ci` + examples (one
    │                               # registry-fetch derivation serves every consumer)
    ├── packages/
    │   ├── android/                # The Android cross build (x86_64-linux only): SDK/NDK
    │   │                           # tables, raylib/tree-sitter/libghostty-vt/grammar cross
    │   │                           # builds, libhue.so, and the nix-native APK assembler
    │   │                           # (aapt2 + zipalign + apksigner; no Gradle)
    │   ├── dub-builder/            # Vendored `buildDubPackage` (crane-style): normalises the
    │   │                           # build path and dub's mtimes so a `buildDubDeps` bundle of
    │   │                           # compiled dependencies transfers between derivations —
    │   │                           # the ~35 example builds share one closure per lib
    │   ├── fonts.nix               # `maple-mono` + the `sparkles-fonts` bundle (all platforms)
    │   └── maple-mono/             # Maple Mono with frozen OpenType features (vendored patcher)
    ├── shells/android.nix          # Android dev shell: adb/aapt2 + hue-emulator/-adb-install/-logcat
    └── shells/default.nix          # Nix dev shell
```

For module-organization and import conventions, see
[Code Style § Module Layout](./code-style.md#module-layout).

## Environment, Build & Test

The repo uses a Nix flake. `nix develop` (or `direnv`) provides the toolchain —
`dub`, `ldc`, `dmd`, `delta`, and the `ci` helper — on `PATH`. Once the toolchain
is available, prefer invoking `dub` **directly** for fast iteration:

```bash
# Build / test a sub-package (run dub directly — fast)
dub build :base
dub build :core-cli
dub test  :base
dub test  :core-cli
dub test  :versions

# Run tests matching / excluding a pattern (sparkles:test-runner; see below)
dub test :base -- -i "Buffer"
dub test :core-cli -- -e "slow"
dub test :core-cli -- -v            # verbose: full stack traces + durations
dub test :core-cli -- -t 1          # single-threaded

# Test a sub-package in another worktree without cd:
dub --root /path/to/worktree test :core-cli

# Build any artifact the way the flake does: optimized, assertions live.
dub build :twoslash-extract -b checked
```

### Dev shells: `default`, `full`, `ci`

Three shells, built from the same `mkSparklesShell` in `nix/shells/default.nix`
and differing only in their entry banner and package tier:

| Shell     | Use                                                                                                                        |
| --------- | -------------------------------------------------------------------------------------------------------------------------- |
| `default` | **Quiet — no banner.** Non-interactive contexts: agents, scripts, CI. Stray `figlet` output would pollute captured stdout. |
| `full`    | Adds `figlet` and prints a `sparkles : *` greeting on entry. For interactive use.                                          |
| `ci`      | The CI floor: no browser, no profilers, no benchmark corpora, no oracle libraries, no pre-commit tooling.                  |

`nix develop -c <cmd>` enters `default`, so agents get clean output without
asking for it:

```bash
nix develop -c dub build :core-cli
nix develop -c ci --test
```

`.envrc` picks the shell for `direnv` from an optional `DEV_SHELL`, defaulting
to the quiet one:

```
use flake ".#${DEV_SHELL:-default}"
```

To switch without editing `.envrc`, set it in a git-ignored `.env` at the repo
root — `.envrc` loads it via `dotenv_if_exists`:

```bash
# .env
DEV_SHELL=full   # opt into the greeting for direnv
```

**Adding a dependency** means choosing a tier. `ciPackages` is what CI gets;
`devPackages` adds the rest on top. Put a tool in `ciPackages` only if a CI job
actually runs it — everything there is built on every CI run.

### Flake-input store paths

The nix dev shell exports every flake input as a `/nix/store` path (minus
`self`, which would recurse / re-copy the tree):

- `$SPARKLES_FLAKE_INPUT_<NAME>` — one var per input. `<NAME>` is the flake
  input name, uppercased, `-` → `_`. Example: `dmd-src` →
  `$SPARKLES_FLAKE_INPUT_DMD_SRC` (= `${inputs.dmd-src}`, the checkout root,
  not a hand-joined subpath).
- `$SPARKLES_ALL_FLAKE_INPUTS` — JSON object
  `{ "dmd-src": "/nix/store/…", … }` keyed by the original flake input names,
  for discovery. `echo "$SPARKLES_ALL_FLAKE_INPUTS"` / parse JSON; do not
  scrape `flake.lock`.

Tests that read a pinned third-party checkout **assert** the env var is set
and the path exists (`enter nix develop`). Do not parse `dub.selections.json`
or walk `$DUB_HOME`.

Derived-package vars (`$SPARKLES_DMD_IMPORT_PATH`, `$SPARKLES_TS_GRAMMAR_PATH`,
`$JSON_TEST_SUITE`) are a different contract: they point at linkFarm /
applyPatches outputs, and their tests still **skip** when unset.

### Locating C Headers & System Dependencies

**Never search the entire `/nix/store` for header files or library paths.** Searching `/nix/store` directly is slow, matches unrelated or stale packages, and produces fragile paths.

Instead, query `pkg-config` directly for include flags, C preprocessor flags, and library paths:

```bash
# Get include flags for C preprocessor / ImportC:
pkg-config --cflags vulkan
pkg-config --cflags raylib
pkg-config --cflags tree-sitter

# Get linker flags:
pkg-config --libs vulkan
```

### Build types: `debug` to test, `checked` to ship, never `release`

Every in-repo `dub.sdl` — and every single-file example's inline recipe —
declares a `checked` build type:

```sdl
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
```

It is neither of dub's two obvious defaults, because each is wrong for a
shipped artifact:

| Build type | `assert` | `debug { }` | Use for                                             |
| ---------- | -------- | ----------- | --------------------------------------------------- |
| `debug`    | live     | **on**      | `dub test`, local iteration                         |
| `release`  | **gone** | off         | nothing — see below                                 |
| `checked`  | live     | off         | every nix artifact: apps, examples, the `ci` helper |

- **`release` implies `-release`, which deletes an assert's whole
  _expression_** — so a call written inside one silently stops happening.
  `assert(!client.connect(addr).hasError)` never connected, and the example
  hung until CI's 20-minute cap instead of failing an assertion. An assertion
  that does not run is not a cheap assertion; it is an absent one. Verify
  what a mode actually does with `libs/base/examples/build-mode-probe.d`.
- **`debug` implies `-debug`, which compiles `debug { }` blocks in.** Those
  exist to hold checks too expensive to ship (an `isSorted` over the whole
  input), so they do not belong in an artifact either — but they are exactly
  what you want while testing.
- **`checked` costs ~3% over `release`** where it was measured (`apps/twoslash-extract`,
  on the assert-heavy DMD frontend) and about half the time of `debug`.

Unit tests keep `debug`: `dub test` never passes `--build`, and the debug
blocks are the point there.

Where assertion cost genuinely matters in a hot path, the lever is
**`-checkaction=halt`** on that code (a two-byte trap, no message, no
`AssertError` machinery) — not deleting the check. Reach for it with a
measurement in hand, per package, not repo-wide.

A custom build type must be declared by the **root** package of a build:
`dub.settings.json` has no equivalent, and dub resolves `--build=<name>`
against the root recipe alone. That is why the declaration is repeated in
each example's inline recipe rather than inherited. `apps/ci/tools/add-checked-buildtype.d`
re-applies it idempotently when new packages or examples land.

`nix develop -c <cmd>` also works but is slower and can trigger a rebuild of the
`ci` package; reserve it for entering the shell or for reproducing CI exactly.

> [!IMPORTANT]
> **The bare `ci` on `PATH` can be stale.** It is a Nix-store wrapper built from
> the flake; after you change `apps/ci`, the `PATH` copy lags behind. Run the
> in-tree version with `dub run :ci -- …` or `nix run .#ci -- …` instead of bare
> `ci`. (This is a real, recurring footgun.)

> [!IMPORTANT]
> **New/untracked files are invisible to `nix develop`/flake builds until you
> `git add` them** (stage — you don't need to commit). The flake evaluates the
> git tree, which includes tracked files and uncommitted edits to them, but not
> untracked files. Symptom: a freshly created `libs/foo/dub.sdl` or new module
> "doesn't exist" / "No package file found". Fix: `git add` it.

> [!NOTE]
> **Substantial scripts and hook logic must be written in D.** Tiny glue
> (a handful of lines to invoke a binary, set up paths, or do trivial
> argument munging) is acceptable as `pkgs.writeShellScript` or inline Nix.
> Any real logic — parsing, non-trivial decisions, more than roughly 5–10
> lines, etc. — belongs in a D program. The canonical place for repo
> tooling is `apps/ci` (or a small dedicated sub-package under `apps/` when
> appropriate). Build it via the flake and invoke it with
> `lib.getExe config.packages.ci` (or the equivalent for other packages)
> from pre-commit hooks and other Nix expressions.
>
> **This applies to one-off and throwaway scripts too — not just committed
> tooling.** When you reach for a quick script (a data/table transform, a bulk
> spec edit, a repro, a PTY or integration probe), write it as a D single-file
> program (`#!/usr/bin/env dub` + `dub run --single foo.d`) rather than ad-hoc
> Python or Node. It costs about the same, runs on the same toolchain, and — the
> real leverage — can `import` the `sparkles` libraries and be promoted into
> `apps/ci`, a test, or an example when it proves useful, so the effort compounds
> in our codebase instead of evaporating. Reserve `python`/`node`/shell for a
> genuinely trivial one-liner; anything with real logic should be D.
>
> The `detailed-scope` pre-commit hook (commit-msg stage) was originally a
> large inline shell script in `nix/checks/pre-commit.nix`; it has been
> ported to a `--check-commit-scope` subcommand inside the D `ci` tool.

### Test runner (`sparkles:test-runner`)

The project uses its own runner, `sparkles:test-runner` (`libs/test-runner`,
silly's successor — same CLI, documented under
[`docs/libs/test-runner/`](../libs/test-runner/index.md)). Options after `--`:

```
-i, --include       Run tests matching regex
-e, --exclude       Skip tests matching regex
-v, --verbose       Show durations, [file:line] locations, full stack traces
-t, --threads       Number of worker threads (0 = auto)
-l, --list          List discovered tests (with attribute markers)
--no-colors        Disable colored output
--bench             Run @benchmark tests (auto-scaling ns/iter statistics) and
                    @workload tests (single-pass window deltas + wall decomposition)
--perf              With --bench: hardware perf counters (Linux perf_event;
                    macOS proc_pid_rusage fixed counters)
--perf-scaled       With --perf: keep a multiplexing group; values render as ≈ estimates
--perf-iters=N      With --bench: pin the counting-pass iteration count (reproducible totals)
--syscalls[=LIST]   With --bench: syscalls/iter via perf tracepoints (root-gated)
--metrics=LIST      With --bench: pick metric columns (glob, all, ?/help = list;
                    raw:r<hex> / pfm:<name> add µarch hardware events)
--list-metrics      List available metric columns and exit
--sort-by=KEY       With --bench: sort rows by a metric column (default median/iter)
--group-by=KEYS     With --bench: one table per group of these label keys
--bench-json FILE   With --bench: dump results as JSON (baseline snapshots)
--bench-min-time MS With --bench: per-case measurement budget in ms (default 5)
--better-c          Extract @betterC tests, compile with -betterC, run them
--wasm              Extract @wasm tests, cross-compile to wasm32, run them
--include-import P  With --better-c/--wasm: also compile module pattern P in
--no-auto-include   With --better-c/--wasm: don't compile the tests' own modules in
--require-toolchain With --better-c/--wasm: fail instead of skipping when tools are missing
--ctfe-trace FILE   Evaluate @ctfe tests under LDC -ftime-trace; per-test cost
--self-test         Also run the runner's own unittests
```

Tests opt into the special modes with marker UDAs from
`sparkles.test_runner.attributes` (`@ctfe`, `@betterC`, `@wasm`,
`@benchmark`, `@workload`); import them **unconditionally**, not under
`version (unittest)` — see the
[attribute reference](../libs/test-runner/reference/attributes.md).
`@ctfe` tests never execute at runtime: after `-i`/`-e` filtering, the
runner CTFE-evaluates the selected ones through a probe compiled with
`-o- -unittest` (semantic analysis only, needs a D compiler on `PATH`), so
filters control which tests execute and a failing `@ctfe` test can't break
the test build, `--help`, or `--list`.

The runner is two packages: `sparkles:test-runner` is a thin `sourceLibrary`
shim (discovery + registration) compiled into each test binary, and
`sparkles:test-runner-impl` is the prebuilt implementation library it links
across an `extern(C)` seam. This keeps a consumer's `dub test` close to a
vanilla build (the heavy modules are compiled once, not per-consumer).

A new sub-package integrates the runner one of two ways:

- **Default (fast path)** — add `dependency "sparkles:test-runner" path="../.."`
  to `configuration "unittest"` (apps use the appropriate relative path). This
  is also the recipe external projects use. Copy the block from `libs/versions`.
- **Cycle-safe path** — `base`, `core-cli`, and `test-utils` are in the impl
  library's dependency closure (dub's cycle detection unions across configs:
  impl → `core-cli` → `test-utils`), so they cannot depend on it. They
  source-include both packages instead:

  ```sdl
  importPaths "src" "../test-runner/src"
  configuration "unittest" {
      sourcePaths "../test-runner/src" "../test-runner-impl/src"
      importPaths "src" "../test-runner/src" "../test-runner-impl/src"
  }
  ```

  Note the split: only the **shim** is on the top-level `importPaths`; the impl's
  tree is unittest-only. A `sourcePaths` entry does not imply an import path, so
  the `unittest` block repeats both.

The `@ctfe`/`@betterC`/`@wasm`/`@benchmark`/`@workload` attributes live in the
**shim** (`libs/test-runner/src/sparkles/test_runner/attributes.d`), not the
impl. That placement is load-bearing: a module carrying them imports
`attributes` in _every_ build (e.g. `base`'s `readers.d`), so hosting them in
the impl would force its whole source tree — and, through the impl's
`sparkles:ui` dependency, that toolkit too — onto the top-level `importPaths` of
`base`/`core-cli`/`ui`/`input` and thus into the Nix source closure of every app
that depends on them.

> [!WARNING]
> **The runner does not discover unittests that live only in `package.d`**
> (same as silly). `dub test` generates a `dub_test_root.d` whose
> `allModules` list excludes `package.d`, so a module whose tests are in
> `package.d` runs **zero** tests (and silently "passes"). Put tests in
> feature modules; keep `package.d` for `public import` re-exports only.

### Run the full CI check locally

```bash
nix run .#ci -- --test --fail-fast       # dub test for every sub-package
DC=ldc2 nix run .#ci -- --test-sanitize --fail-fast  # Linux only: ASan + stackovf (the nix `ci` picks DMD on x86_64-linux)
nix run .#ci -- --test-extracted         # --better-c/--wasm for every sub-package using them
nix run .#ci -- --verify --files README.md   # verify markdown examples (see Examples below)
nix run .#ci -- --check-vcs-urls         # audit all tracked markdown for unpinned GitHub URLs
nix run .#ci -- --check-docs-sidebar     # sidebar ↔ pages consistency (VitePress)
nix run .#ci -- --smoke-apps             # launch every windowed app; require a clean exit
```

### Smoke-launching the windowed applications

`--smoke-apps` is the only thing in the repository that **runs** hue, terminal,
ui-gallery and diagram. Everything else compiles them, which is how a window
that aborted on startup — before it drew a frame — once reached `main`.

It needs the binaries built first, and finds them in `result/<app>/bin/<app>`
(the `.#all-desktop` link farm CI already produces), `apps/<app>/build/<app>`,
or `apps/<app>/build/sparkles_<app>` (what an in-tree `dub build :<app>`
leaves). Each launch is bounded to a few frames through `SPARKLES_UI_FRAMES`
(`HST21`) and must exit cleanly having painted at least one frame.

```bash
nix develop -c dub build :hue :terminal :ui-gallery :diagram
nix run .#ci -- --smoke-apps                      # all of them
nix run .#ci -- --smoke-apps --files ui-gallery   # one of them
xvfb-run -a nix run .#ci -- --smoke-apps          # headless Linux
```

A machine with no window server reports each GUI launch as **skipped**, not
failed — but the summary says when _nothing_ ran, so a job where every leg
skipped cannot be mistaken for one where the check passed.

> [!NOTE]
> An application needs no cooperation: the budget arrives through the
> environment, because the four have four different argument parsers and a
> harness that needed each of them to opt in would silently skip whichever had
> not been taught yet.

One further check exists that CI **cannot** run, because it reads the upstream
clones under `$REPOS`:

```bash
nix run .#ci -- --check-blob-paths       # do pinned blob citations name paths that exist?
```

`--check-vcs-urls` proves a GitHub URL carries a commit SHA rather than a moving
branch; it cannot tell whether the **path** after that SHA resolves. A citation
pinned to a real commit but naming a file one directory over is a 404 that only
the link checker sees — i.e. only in CI, and only when the host is not
rate-limiting. Since every surveyed upstream is already cloned locally at the
revision it was read at, `git cat-file -e <sha>:<path>` answers offline, for
thousands of citations, with no network. A citation whose repository is not
cloned is reported as **unchecked**, never as a failure, which is why this is
not a hook and not a CI job. Run it before publishing a research catalog.

### Debugging tips

- `dub test :base -- -v` and `dub test :core-cli -- -v` show full stack traces
  and per-test durations.
- `-i "name"` isolates a single test by its UDA name.
- Ensure `@nogc`/`nothrow` tests actually compile with those attributes (don't
  let an accidental allocation relax them).

## Code Style & Idioms

### Functional style with UFCS

Prefer **functional pipelines** with UFCS over `std.algorithm`/`std.range`:

```d
auto result = items
    .filter!(a => a.isValid)
    .map!(a => a.name)
    .array;
```

See [Functional & Declarative Programming Guidelines](./functional-declarative-programming-guidelines.md).

### Shortened function syntax & imports

Prefer the **shortened function form** `T fn(args) => expr;` for any function whose
body is a single expression (or `return`):

```d
bool active() const @safe pure nothrow @nogc => _active;
string sizeText(ScreenSize!ushort sz) @safe => text(sz.width, "×", sz.height, " cells");
```

A **local (in-body) `import`** forces a braced `{ … }` body and so blocks the `=>`
form. For single-expression functions, hoist the needed **module-level selective
import** (`import std.conv : text;` at module scope) so the function can use `=>`.
Reserve local imports for bodies that are already braced and where scoping a heavy
dependency to one function is worth it.

**Example programs** (`libs/*/examples/*.d`) should use **module-level selective
imports** rather than repeating the same local import in each function — one
`import std.conv : text;` at the top reads more concisely than three in-body copies,
and it lets the example's helpers use the `=>` shortened form.

### Safety attributes — annotate non-templates, infer on templates

Strive for maximum safety, but apply attributes correctly:

- **Non-templated functions:** annotate explicitly, e.g. `@safe pure nothrow @nogc`.
  A module- or scope-level `@safe pure nothrow:` block is fine for plain functions.
- **Templated functions** — and anything generic over a `Writer`, `Hook`, or other
  caller-supplied type — **let the attributes infer**. Forcing `@safe` on such a
  template rejects legitimately non-`@safe` writer/hook types it should accept.
  Reserve explicit attributes on templates for cases where the attribute is
  _intrinsic_ (e.g. `recycledErrorInstance` is deliberately `@system`).
- **Avoid `@trusted` on a whole function — never on a template.** Wrap only the
  unavoidable unsafe operation in a `@trusted` lambda/block, or sidestep it (e.g.
  the array-copy trick `char[1] a = c; put(w, a[]);` keeps a writer call `@safe`).

### Preview flags

Each sub-package's `dub.sdl` enables:

```
dflags "-preview=in" "-preview=dip1000"
```

- `-preview=in` — `in` parameters become `scope const`.
- `-preview=dip1000` — improved scope/lifetime checking for `@safe` code.

Unittest builds additionally pass `-checkaction=context -allinst` (richer assert
messages; instantiate all templates). The root `dub.sdl` has no `dflags` — they're
per-sub-package.

> [!WARNING]
> **`dip1000`/`-preview=in` clash with some Phobos functions that don't accept
> `scope`** (e.g. `std.regex.replaceAll`, reached via `unstyle`). Errors like
> "scope parameter may not be returned" mean you must relax that specific
> parameter — drop `in`/`scope` and use `const(char)[]` or pass by value.

### Error handling — `Expected` in `@nogc nothrow` code

GC exceptions are disallowed in `@safe pure nothrow @nogc` code. Use the
[`expected`](https://github.com/tchaloupka/expected) library (`~>0.4.1`, a runtime
dependency of `base` and `versions`):

- Construct with `ok(value)` / `err!ValType(error)`; check with `hasValue`/`hasError`.
- Transform/chain with `map`, `mapError`, `andThen`, `orElse`, `mapOrElse`.
- `Expected!(T, E)` is a range (a failure is empty, a success yields one element),
  so `joiner` flattens a collection of results, filtering out errors.
- For the rare path that must still `throw` in `@nogc`, use
  `recycledErrorInstance!T("message")` from `sparkles.base.lifetime`.

See **[Expected Error Handling Idioms](./idioms/expected/index.md)** for the full
guide (transform/chain/flatten patterns, Rust ↔ D comparisons, and a cheat sheet).

### `@nogc` primitives (and what breaks `@nogc`/`nothrow`)

- **Buffers** (`sparkles.base.buffer`) — one container, four policies. Use one
  instead of `appender` in `@nogc` code, and let the alias state what the buffer
  may do:

  | Alias                 | Reach for it when                                                                                                                 |
  | --------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
  | `UniqueBuffer!(T, N)` | **The default.** One owner — a local builder, a field nobody copies. Move-only, so the grow path carries no reference count.      |
  | `SharedBuffer!(T, N)` | Copies genuinely happen. The block is shared and cloned on the next write; naming it is a claim that something copies the buffer. |
  | `InlineBuffer!(T, N)` | The bound is hard and overflow is a condition to report. Deliberately not an output range — write into it with `tryWrite`.        |
  | `HeapBuffer!T`        | An inline array would be dead weight. Size it up front with `reserve`.                                                            |

  Spelling the policy out as `Buffer!(T, N, storage)` is for combinations no alias
  names, such as `InlineBuffer!(T, N, Storage.unique)`. Full design:
  [the buffer spec](../specs/base/buffer.md).

- `sparkles.base.text.writers` / `.readers` — `@nogc` integer/float/duration
  formatting and parsing. Prefer these over `.text` / `std.conv` (which GC-allocate)
  and over `std.format` in hot paths.
- `pureMalloc`/`pureFree` from `core.memory` for manual allocation; static arrays
  when the size is known at compile time.

> [!WARNING]
> `splitter(' ')` and `std.utf` operations can throw `UTFException` / allocate,
> breaking `nothrow @nogc`. Use the `text` package primitives in those paths.

```d
@safe pure nothrow @nogc
unittest
{
    UniqueBuffer!(char, 256) buf;
    buf ~= "Hello";
    buf ~= ' ';
    buf ~= "World";
    assert(buf[] == "Hello World");
}
```

### Strings, and the C boundary

**A D API takes `string` or `in char[]` — never `const(char)*`.** NUL-termination
is the callee's errand. A signature asking for a pointer states its real
requirement only in prose, and prose does not fail to compile: that is exactly how
`InitWindow(…, title.ptr)` shipped a macOS crash, since a D slice carries no
terminator and only a string literal happened to have one.

`sparkles.base.text.cstring` has one tool per lifetime, and the lifetime is the
whole question:

| Need                                    | Use                                          |
| --------------------------------------- | -------------------------------------------- |
| Hand a C string to a call, nothing more | `toTempStringz`                              |
| The buffer outlives the call (a field)  | `stringz` on it                              |
| Input has a known bound                 | `CString!N` via `toCString` / `tryToCString` |
| Name a literal as a C string            | `cstr!"…"`                                   |
| A pointer arriving _from_ C             | `CStr.fromStringz`                           |
| Append a terminator into a writer       | `writeStringz`                               |

```d
// One call, no named buffer. The temporary lives to the end of the full
// expression — past the call — so this is sound.
SetWindowTitle(title.toTempStringz.ptr);
```

> [!WARNING]
> Never bind that pointer to a variable: `auto p = s.toTempStringz.ptr;` ends the
> full expression, destroys the buffer, and leaves `p` dangling. Nothing catches
> it — `-dip1000` models escapes, not destructor timing. Name the _buffer_ instead
> (`auto z = s.toTempStringz;`). `std.string.toStringz` remains the right answer
> when the C string must outlive the call and a GC allocation is acceptable.

**Rendering.** `writeText` writes an interpolated sequence into any output range
with no markup parsing; `writeStyled` parses `{red …}` and is only for style
templates. Reach for `writeText` whenever the text is not one — a brace in a
filename is silently eaten otherwise. Outside `@nogc`, `std.conv.text(i"…")`
already does the same job.

**Testing.** Use `checkWriter!((ref b) => …)("expected")` for anything that renders
into a writer, and `checkToString` for a type with a `toString(Writer)`. Both report
a diff on mismatch and stay `@safe pure nothrow @nogc`.

See [Write `@nogc` text](../libs/base/how-to/write-nogc-text.md) and
[Test with check helpers](../libs/base/how-to/test-with-check-helpers.md).

### Contracts (DIP1009)

Use expression-based `in`/`out` contracts for pre/postconditions:

```d
void popBack()
in (_length > 0, "Cannot pop from empty buffer")
{
    _length--;
}
```

See [Code Style § Expression-based contracts](./code-style.md#expression-based-contracts-dip1009).

### Named arguments (DIP1030)

Use named arguments for struct initialization (see
[Code Style § Named arguments](./code-style.md#named-arguments-dip1030)):

```d
auto opts = PrettyPrintOptions!void(
    indentStep: 2,
    maxDepth: 8,
    maxItems: 32,
    softMaxWidth: 80,
    colored: true,
);
```

### Output ranges

Many utilities accept any output range for flexibility:

```d
ref Writer prettyPrint(T, Writer, Hook = void)(
    in T value,
    return ref Writer writer,
    in PrettyPrintOptions!Hook opt = PrettyPrintOptions!Hook()
)
{
    prettyPrintImpl(value, writer, opt, 0);
    return writer;
}

import std.array : appender;
auto w = appender!string;
prettyPrint(myValue, w);
string result = w[];
```

### Compile-time computation & template constraints

```d
// Computed at compile time via CTFE
enum string formatted = "Format me".stylizedTextBuilder(true).bold.underline.blue;

// Constrain templates for type safety
string numToString(T)(T value)
if (__traits(isUnsigned, T))
{ /* ... */ }
```

For capability-detection patterns (traits, optional primitives, fallback paths),
see [Design by Introspection Guidelines](./design-by-introspection-01-guidelines.md).

## Testing

### Placement & coverage

- Every public function should have a unit test following it.
- At minimum, one public/DDoc-ed unit test (`///`) per function.
- Keep tests in feature modules, **not** in `package.d` (see the test-runner
  warning above).
- Environment-dependent tests (perf counters, root-only interfaces, toolchain
  binaries) call `skipTest(reason)` from `sparkles.test_runner.skip` instead
  of returning early — an early `return` counts a degraded environment as a
  pass; a skip renders as a yellow `⊘` line plus an `N skipped` summary
  segment and never fails the run.

### Test attributes

Always give unittests explicit safety attributes:

- Use `@safe` or `@system` — never omit the safety attribute.
- Avoid `@trusted unittest` — tests should verify safety, not bypass it.
- Add `pure`, `nothrow`, `@nogc` whenever possible.

```d
@("Buffer.basic.creation")
@safe pure nothrow @nogc
unittest
{
    UniqueBuffer!(int, 4) buf;
    assert(buf.length == 0);
    assert(buf.empty);
}
```

### `@nogc nothrow` testing

- `recycledErrorInstance!T("msg")` throws without GC allocation.
- A `Buffer` as an output range instead of `appender`.

```d
@("prettyPrint.integers")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.lifetime : recycledErrorInstance;
    import sparkles.base.buffer : UniqueBuffer;

    UniqueBuffer!(char, 1024) buf;
    prettyPrint(42, buf);

    if (buf[] != "42")
        throw recycledErrorInstance!AssertError("Mismatch");
}
```

### Reusable check helpers

Prefer the project's helpers over hand-rolled assertions:

- **`checkToString` / `checkWriter`** (`sparkles.base.buffer`) — for types
  exposing `void toString(Writer)(ref Writer w)`. They render into a `Buffer`
  (so the test stays `@safe pure nothrow @nogc`) and report an expected/actual diff
  via a recycled `AssertError` on mismatch.
- **`checkRoundTrip` / `checkRejects` / `checkAscending`** (`sparkles.versions.testing`)
  — for version-scheme parse/format/ordering tests.
- **`checkGolden` / `blessGolden` / `gridText`** (`sparkles.test_utils.goldens`)
  — for a committed fixture file. See below.

```d
@("MyType.toString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkToString;
    checkToString(MyType(42), "MyType(42)");
}
```

(Note: a bare `check` is **not** an importable helper — it appears as an ad-hoc
local function inside some tests. Use the named helpers above.)

### Golden files

`sparkles.test_utils.goldens` is the one implementation. Do not write another —
the three that existed before it had drifted apart on both of its policies.

```d
checkGolden(rendered, dir.buildPath(name ~ ".txt"),
    "SPARKLES_UPDATE_GOLDENS=1 dub test :mine -- -i my.goldens");
```

| Rule                                      | Why                                                                                                                                                                       |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bless on `SPARKLES_UPDATE_GOLDENS=1` only | Any-non-empty means `…=0` blesses, which is the spelling people reach for to turn a variable **off**.                                                                     |
| A missing golden **fails**                | A test that writes its own expectation on first run asserted nothing on that run, and a fixture left out of a commit then passes in CI forever.                           |
| Only a plain mismatch is blessable        | A suite that verifies its output by other means must not record a run those checks rejected. `blessGolden` is the separate door; `checkGolden` compares and nothing else. |
| Pass the regeneration command             | A golden failure is read by someone who did not write the suite, and every suite is regenerated by a different `dub test` invocation.                                     |
| Compare **text**, not pixels              | A layout regression is legible in a text diff; an image comparison says only that something differs, and depends on fonts, a renderer and a platform.                     |

Rendering a laid-out widget tree? `gridText(grid)` is the shared cell-grid dump
— one line per row, trailing blanks trimmed, colour deliberately absent so a
theme change does not rewrite every fixture.

The committed suites today:

```bash
dub test :ui-gallery  -- -i render.golden    # a frame per catalog page
dub test :source-view -- -i md.goldens       # the markdown grid fixtures
dub test :hue         -- -i dsv_view.golden  # the DSV grids
dub test :dmd-fmt                            # fences inside its case pages
```

Golden **directories** need an `.editorconfig` stanza: a photographed frame's
columns are layout, not indentation, and `editorconfig-checker` rejects them
otherwise.

### Test naming (string UDAs)

```d
@("ModuleName.functionName.testCase")
@safe pure nothrow @nogc
unittest { /* ... */ }
```

## Examples & Documentation

### Where docs live

- Cross-cutting agent/style guides → `docs/guidelines/`.
- Per-library docs → `docs/libs/<name>/` as a Diátaxis tree
  (`tutorial/`, `how-to/`, `reference/`, `explanation/`). Mirror `libs/<name>/`.
- Background research → `docs/research/<topic>/` as a cross-linked catalog; follow
  [Writing Research Docs](./research-docs.md). Design specs → `docs/specs/`.

### The docs sidebar is data

The VitePress sidebar tree and the `srcExclude` list live in **JSON data files**,
not in `config.mts`:

| File                               | Holds                                             |
| ---------------------------------- | ------------------------------------------------- |
| `docs/.vitepress/sidebar.json`     | the sidebar tree (`themeConfig.sidebar` verbatim) |
| `docs/.vitepress/docs-config.json` | `srcExclude` — the pages the site does not build  |

These files are the **single source of truth**. Three consumers read them:

- `docs/.vitepress/config.mts` imports them
  (`import sidebar from './sidebar.json' with { type: 'json' }`) and passes them
  through to `themeConfig.sidebar` / `srcExclude`.
- `ci --check-docs-sidebar` (`sparkles.docs.sidebar` in `libs/docs` +
  `apps/ci/src/docs_sidebar.d`) decodes them with `sparkles:wired` and checks
  both directions: every published page is linked, and every link resolves to a page.
- `ci --audit-fences` (`apps/ci/src/fence_audit.d`) uses the same `srcExclude`
  to decide which files the site builds.

**To add a page:** add `{ "text": "…", "link": "/route" }` to the right group in
`sidebar.json` — a group is `{ "text": …, "collapsed": true, "items": [ … ] }`
and nests arbitrarily. The link is the site route (leading `/`, no `.md`, and
`/dir/` for a `dir/index.md`). Run `ci --check-docs-sidebar` afterwards; the
pre-commit hook of the same name runs on any change under `docs/`.

**Never** re-inline this data into `config.mts` and never re-derive it by parsing
`config.mts` from another language — that text-scraping is exactly what these
files replaced.

### Runnable README examples

When adding a feature, add a runnable example to `README.md` as a dub single-file
program inside a fenced `d` code block:

````markdown
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_my_feature"
    dependency "sparkles:core-cli" version="*"
+/

import sparkles.core_cli.my_module;

void main()
{
    // Example usage
}
```
````

Follow it with an `ansi`-labelled fenced block showing the expected output:

````markdown
```ansi
Expected output here
```
````

The `ansi` label is the **required convention**: `--verify` only treats an
output-labelled fence as expected output (a bare ` ``` ` fence is ignored). An
`ansi` block stores the program's output **verbatim, escape sequences included**,
so a colored example keeps its color — VitePress renders the SGR codes as real
color, and GitHub renders `ansi` blocks colored too. Paste the bytes the program
actually wrote; `--update` does that for you.

> [!NOTE]
> ` ```[Output] ` is the **legacy** spelling. It is still recognised by
> `--verify`/`--update` so old blocks keep verifying, but it stores
> **ANSI-stripped** text and therefore throws away color. Don't write new
> `[Output]` blocks; convert any you touch to `ansi` and regenerate them with
> `--update`. (` ```[Output:ansi] ` is an accepted alias for `ansi`.)

### Verifying examples

````bash
# Verify examples match their expected output
nix run .#ci -- --verify --files README.md

# Update output blocks with actual output (golden-snapshot update; writes ```ansi)
nix run .#ci -- --update --files README.md

# Just run examples and display results
nix run .#ci -- --files README.md
````

> [!NOTE]
> README examples keep `version="*"`, which resolves against the registry by
> default. To verify them against your working tree, `dub add-local <repo>` first;
> CI relies on git **tags** so dub can derive a version. (In-repo example/dub files
> instead use a relative `path=` — see the table below.)

<div v-pre>

### Dynamic output with `<!-- md-example-expected -->`

For dynamic output (timestamps, paths, durations), put a `<!-- md-example-expected -->`
HTML-comment directive between the code block and the output block. It holds a
wildcard pattern used by `--verify`, while the literal `ansi` block is kept for
readers. Use `{{_}}` to match any non-empty text:

````markdown
<!-- md-example-expected
[ {{_}} | info | {{_}} ]: Server started
-->

```ansi
[ 14:32:01 | info | app.d:12 ]: Server started
```
````

The wildcard pattern is matched against the **ANSI-stripped** output, so write it
in plain text even though the `ansi` block beside it keeps the escape sequences.

The comment is invisible in rendered markdown, so readers see the nice hardcoded
values while `--verify` uses the wildcard pattern.

</div>

### In-repo dub dependency paths

Files **inside** the repo must reference sibling sub-packages with a relative
`path=` to the repo root, not `version="*"`:

```sdl
dependency "sparkles:core-cli" path="../../.."
```

The `path` value depends on the file's depth relative to the repo root:

| File location                | `path` value |
| ---------------------------- | ------------ |
| `libs/base/dub.sdl`          | `../..`      |
| `libs/base/examples/*.d`     | `../../..`   |
| `libs/core-cli/dub.sdl`      | `../..`      |
| `libs/core-cli/examples/*.d` | `../../..`   |
| `docs/guidelines/*.d`        | `../..`      |

This applies to all in-repo `dub.sdl` configs, single-file example scripts, and
guideline runnable snippets.

**Exception — `README.md`:** README examples are copy-pasted by end users who don't
have the repo layout, so they keep `version="*"`.

## Conventions

### Commit messages

Conventional commits with **detailed scopes when practical**:

```
<type>(<scope>): <description>
```

The parser (`apps/release`) accepts any text between the parentheses; the scope
exists for humans, `git log`, and release-note archaeology. The bump policy only
looks at the _type_ (plus `!` or `BREAKING` footer).

**Prefer the most specific scope that is still short and obvious.** Good patterns:

| Form                             | Example                                                                    | Notes                                                                     |
| -------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `docs(research/{topic})`         | `docs(research/window-system-integration): add Android/NDK OS-API example` | Research catalog topic                                                    |
| `docs(guidelines/{area})`        | `docs(guidelines): ...` or `docs(guidelines/code-style): ...`              | Guideline changes                                                         |
| `{lib/app}.module` (or `sub`)    | `fix(base.buffer): saturate grownCapacity on overflow`                     | D module or leaf file                                                     |
| `{pkg}/subdir` or `{pkg}.subdir` | `feat(core-cli/examples): add animated streaming drawTable demo`           | Examples or nested area                                                   |
| `pkg.sub.module` (D style)       | `feat(core_cli.ui.table): Use unstyledLength for precise column width`     | Internal module path                                                      |
| short whole-package name         | `feat(terminal): implement text selection`                                 | Acceptable when the package is small / single-file / cohesive at the time |
| tool / config area               | `config(lychee): ...`, `ci(gh-actions): ...`                               | Cross-cutting but named                                                   |

Bare top-level scopes (`base`, `core-cli`, `docs`, `research`, `tui`, `wired`, ...) are fine for genuinely cross-cutting work or early-stage packages. When the diff is localized to one file or subdirectory, a dotted or slashed child scope is better.

- **Type** — one of the following (one example each):

| Type       | Use for                                  | Example                                                               |
| ---------- | ---------------------------------------- | --------------------------------------------------------------------- |
| `feat`     | new user-facing capability               | `feat(base.buffer): add SharedBuffer with small-buffer optimization`  |
| `fix`      | bug fix                                  | `fix(core-cli): handle empty arrays in prettyPrint`                   |
| `refactor` | behavior-preserving restructuring        | `refactor(ci): extract dub dependency helpers into a testable module` |
| `docs`     | documentation only                       | `docs(guidelines): document the ansi example-output convention`       |
| `build`    | build system / dependencies              | `build(dub): add expected as a runtime dependency of versions`        |
| `ci`       | CI/CD pipelines & tooling                | `ci(gh-actions): add DC (D compiler) dimension to the test matrix`    |
| `test`     | tests only                               | `test(base): add checkWriter for testing writer functions`            |
| `style`    | formatting / renames, no behavior change | `style(core-cli): use kebab-case names for example files`             |
| `chore`    | maintenance (lockfiles, file modes, …)   | `chore(flake.lock): update all flake inputs`                          |
| `config`   | config-file changes                      | `config(editorconfig): disable indent checking for markdown`          |

Append `!` after the scope for a breaking change (e.g. `feat(ci)!: …`).

Wrap the commit message **body** at 80 columns (the subject line stays a single
line). Use a blank line between the subject and the body.

**Backtick `@`-prefixed code tokens (and other auto-linked text).** D attributes
and UDAs — `@safe`, `@nogc`, `@trusted`, `@system`, `@property`, `@CliOption`,
etc. — are inline code, but GitHub renders an un-backticked `@name` in a commit
message, a PR/issue title or body, or any comment as a **mention**: it notifies
(and on merge, permanently credits) whoever owns that handle. `@safe`, `@system`,
and `@property` are all real GitHub accounts, so a bare `nothrow @nogc` pings
strangers and litters the thread. Always wrap them: write `` `@nogc nothrow` ``,
the `` `@safe pure nothrow @nogc` `` order, a `` `@trusted` `` block — never the
bare form. The same applies to anything else GitHub auto-links out of context: a
literal `` `#123` `` (so it isn't turned into an issue/PR reference) or a commit
`` `sha` `` you don't want rendered as a cross-link. This is purely a
commit-message / PR / issue / comment concern — `@`-tokens inside committed
source or Markdown files are not mentions and need no special treatment beyond
the usual code formatting.

### Git hygiene & atomic commits

- **Confirm the current branch before any write/amend/rebase.** A misdirected
  `--amend` silently folds work into the wrong commit. If you're on the default
  branch, create a branch first.
- **Commit as you go — only _pushing_ normally needs to be explicitly asked for.**
  Create a commit at each significant step instead of batching everything at the
  end: a clean, atomic, bisectable series is far easier to build incrementally than
  to reconstruct afterward. Don't wait for permission to commit. The exception is
  documentation-related work: once it is committed, validated, and rebased, push it
  and open the PR without waiting for confirmation.
- **Always rebase on `origin/main` before opening a PR.** Fetch `origin`, rebase the
  completed branch onto the current `origin/main`, resolve conflicts, and rerun the
  affected validation before pushing/opening. If the rebased branch was already
  pushed, update it with `--force-with-lease`, never plain `--force`.
- **Rebase with `--update-refs`.** It carries every branch that points into the
  rebased range along with the rewrite, which is what keeps a stacked PR series
  intact — without it, the lower branches still point at the pre-rebase commits
  and the stack silently comes apart. Pass the flag explicitly rather than
  relying on `rebase.updateRefs`: it is a developer's personal git config here,
  not the repository's, so a machine that does not set it rebases differently
  from one that does.
- **Back up a branch you are about to rewrite with a _tag_, never a branch.**
  This follows directly from the rule above: `--update-refs` moves branches
  pointing into the rebased range, and a backup branch is one of those — it
  dutifully follows the rewrite and preserves nothing. That is the flag working
  as designed, not a bug, and it is silent.

  ```bash
  git tag backup/<effort>-pre-rebase        # pinned; the rebase cannot move it
  git rebase --update-refs --onto <new-base> <old-base>
  # ... verify, then:
  git tag -d backup/<effort>-pre-rebase
  ```

  The reflog still holds the pre-rebase commits either way, so a lost backup
  branch is recoverable — but only if someone notices in time, and the point of
  a backup is not having to.

- **Keep commits atomic.** One logical change per commit, and each commit should
  pass build + test + lint _on its own_ so history stays bisectable. Use
  `git commit --fixup=<sha>` for tweaks that belong to an earlier commit instead
  of a fresh "address review" commit.
- **Review the branch at the end of a session** and propose tidying it with an
  interactive rebase (`git rebase -i <base>`) before it merges. Aim for:
  - **Squash fixups** into their targets — `git rebase -i --autosquash <base>`.
  - **Every commit green** — no commit that only builds/tests/lints once a later
    commit lands.
  - **Group commits by area** so related changes are adjacent.
  - **Preparation commits first** — move `.gitignore` edits, dependency
    add/remove/upgrade, config changes, and docs/scaffolding that later commits
    build on to the front of the branch.
  - Present the proposed reordering and rewrite only after the user agrees. Never
    rewrite already-pushed history without `--force-with-lease` and explicit sign-off.

### Pre-commit hooks (`prek`)

See the note in the [Environment, Build & Test](#environment-build--test)
section about implementing substantial hook logic in D rather than large
shell scripts.

Hooks run on commit and will modify or block your changes:

- **editorconfig-checker** enforces 4-space-multiple indentation — including inside
  DDoc comments (e.g. `$(LIST` / `$(ITEM` bodies).
- **prettier** reformats markdown and can corrupt literal text in tables (it has
  turned `5.004_05` into `5.004*05`); double-check tables of literal data after it runs.
- **verify-md-examples** runs the example verifier and is OOM-prone on large runs;
  bypass a single commit with `SKIP=verify-md-examples git commit …` when needed.
- **detailed-scope** (runs at `commit-msg` stage) checks for obviously useless
  scopes (`wip`, `misc`, `update`, …) and suggests more specific scopes for
  localized changes inside large packages (e.g. bare `base` when only
  `base/buffer.d` changed). It is intentionally _not_ a strict enum. See
  the "Commit messages" section above for the intended style. Bypass with
  `SKIP=detailed-scope git commit …` or `git commit --no-verify`.
- **check-vcs-urls** scans staged markdown files for `github.com`/
  `raw.githubusercontent.com` URLs and rejects any that reference a branch or
  tag instead of a 40-character commit SHA (so docs citing external source
  stay pinned to the exact revision they describe). It only runs against
  `.md` files — non-doc files (e.g. `.envrc`, other tag+hash-pinned tool
  fetches) are out of scope. `$` or `%` in the ref position is treated as a
  runtime placeholder and skipped. Bypass with
  `SKIP=check-vcs-urls git commit …` or `git commit --no-verify`; run
  `nix run .#ci -- --check-vcs-urls` to audit all tracked markdown files.
- **check-docs-sidebar** ensures the VitePress sidebar in
  `docs/.vitepress/sidebar.json` (see
  [The docs sidebar is data](#the-docs-sidebar-is-data)) is consistent with
  published pages in both
  directions: every published `docs/**/*.md` page is linked from the sidebar
  (pages → sidebar), and every sidebar `link` resolves to an existing published
  page (sidebar → pages). It respects `srcExclude` (internal grounding/QA pages
  stay out; links that only hit excluded paths are dangling) and treats
  `docs/index.md` as the implicit home page. The check is whole-tree (not just
  staged files) and runs whenever anything under `docs/` is staged. Bypass with
  `SKIP=check-docs-sidebar git commit …`; run
  `nix run .#ci -- --check-docs-sidebar` (or `dub run :ci -- --check-docs-sidebar`)
  to audit manually.

## Pitfalls Checklist

A quick scan of the gotchas above plus a few more:

- [ ] `git add` new files before `nix develop`/flake builds see them.
- [ ] Don't run bare `ci` after editing `apps/ci`; use `dub run :ci -- …` / `nix run .#ci -- …`.
- [ ] Tests in `package.d` don't run under the test runner — move them to feature modules.
- [ ] Don't force `@safe`/`@trusted` on templates; let attributes infer.
- [ ] `dip1000`/`in` can reject `scope` for some Phobos calls — relax to `const(char)[]`.
- [ ] `splitter`/`std.utf`/`.text`/`std.conv` break `nothrow @nogc` — use the `text` package.
- [ ] D APIs take `string`/`in char[]`, never `const(char)*` — terminate at the seam.
- [ ] Don't store `.ptr` off a `toTempStringz` temporary; it dangles and nothing warns.
- [ ] Example output blocks must be ` ```ansi `, never bare ` ``` ` (and no new
      ` ```[Output] ` — it strips color).
- [ ] Cross-module-but-internal symbols use `package` visibility, not `private`.
- [ ] Symbols used only as UDAs are camelCase (lowercase first letter).
- [ ] Don't search `/nix/store` for C headers/libraries — use `pkg-config --cflags <pkg>` / `pkg-config --libs <pkg>`.
- [ ] Don't put a large value type on the stack in a unittest (`MatcherWorkspace`, `DqlEngine` scratch, …). Test workers are 512 KiB and a 384 KiB watermark fails the test; heap-own it with `Unique` / `HeapBuffer`.
- [ ] Dependency version changes need matching `dub.selections.json` and
      `nix/dub-lock.json` updates.

## Dependencies

- `expected` (`~>0.4.1`) — `Expected!(T, E)` error handling; **runtime** dep of
  `base` and `versions`.
- `sparkles:test-runner` (in-tree) — unittest runner; a thin shim most
  packages pull as a `dependency`, backed by the prebuilt
  `sparkles:test-runner-impl` library (`base`/`core-cli`/`test-utils`
  source-include both — see the integration note above).
- `delta` — diff tool used by test diff output; system dependency via Nix.

D dependencies are managed via `dub.sdl` (pinned in `dub.selections.json` /
`nix/dub-lock.json`); system tools come from the Nix flake.
