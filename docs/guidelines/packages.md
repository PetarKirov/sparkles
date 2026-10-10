# Package Catalog

The detailed map behind the compact table in [Agent Guidelines](./AGENTS.md#project-overview):
what each sub-package declared in the root `dub.sdl` is, and where its modules live.
The authoritative list is the `subPackage` entries in `dub.sdl`; per-library docs
live under `docs/libs/<name>/` and specs under `docs/specs/`.

## Sub-packages

- **`ci`** (`apps/ci`) — Repository CI helper: runs/verifies markdown examples, standalone examples, sub-package tests, and markdown link maintenance
- **`shader-compile`** (`apps/shader-compile`) — The `EFX20` pipeline: compiles a dub package's single-source D shaders — the `@compute` modules of its `shaders` configuration (for `sparkles:ui`: `libs/ui/shaders/effects.d` + `sparkles.ui.effect_shaders` over `sparkles:shaders`) — with the dcompute-enabled LDC (`ldc2-vulkan`: dlang.nix's `ldc-vulkan`, the `sparkles/vulkan-shaders` branch; in the dev shell, and `nix run .#shader-compile` wraps it) to SPIR-V, validates and optimises it, cross-compiles every `@fragment` entry point with spirv-cross to GLSL 330 and ES 100, proves each with glslang, and writes `*.frag` to `--out`. Runs as `sparkles:ui`'s `gpu-effects` pre-generate step (`--if-stale`: a stamp of input hashes, so a fresh build needs no compiler) into the git-ignored `libs/ui/generated/shaders/`; nothing generated is committed, and Nix builds it once (`.#ui-shaders`). Phobos-only on purpose: `core-cli` depends on `sparkles:ui`
- **`release`** (`apps/release`) — Release automation: scans tags as SemVer, summarizes commits, suggests a bump, gathers notes ($EDITOR or a CLI LLM agent), tags and publishes
- **`hue`** (`apps/hue`) — Interactive syntax-highlighting file viewer / live theme previewer over `sparkles:syntax` with subcommands (`view`, `diff`, `pr`, `gallery`, `theme`, `overlay`, `config`) powered by `sparkles:core-cli` (ANSI + HTML, plus an optional raylib `--gui` backend behind the `gui` build config, on `sparkles:raylib-text`; `--gui` also renders a render-markdown.nvim-style markdown preview — heading icons, callouts, task lists, box-bordered aligned tables via `sparkles:core-cli` — and native ANSI in ` ```ansi ` fences via an off-screen `sparkles:ghostty` VT). Also ships as an **Android NativeActivity APK** (`nix build .#hue-apk`, dev shell `nix develop .#android` — both x86_64-linux only, since the NDK/SDK ship prebuilt for that host; see `docs/specs/hue/android.md`)
- **`nix-eval`** (`apps/nix-eval`) — Demo CLI for `sparkles:nix`: evaluates a Nix expression or flake output and pretty-prints the value
- **`terminal`** (`apps/terminal`) — Minimal raylib-based terminal emulator built on `sparkles:ghostty` and `sparkles:raylib-text`
- **`terminal-benchmark`** (`apps/terminal-benchmark`) — Render-CPU benchmark harness for the `terminal` emulator (`/proc` CPU sampling; idle/render/churn scenarios)
- **`twoslash-extract`** (`apps/twoslash-extract`) — Batch D twoslash extractor: runs the `sparkles:twoslash-d` pipeline over an annotated D sample (or a directory, one child process per file) and writes the `.twoslash.json` payload `hue --twoslash` renders; `--verify` guards the golden fixtures
- **`ui-gallery`** (`apps/ui-gallery`) — A browsable catalog of the `sparkles:ui` toolkit — widget kinds, layout, the 36 themes, the component set and the interaction machines — written as a `sparkles:ui-app` component, so one `view` serves both the terminal and the window. Also the host contract's first real consumer, and `sparkles:terminal-view`'s embedding proof (`TVW7`): the Terminal page runs real shells in VSCode-style tabs, terminal-in-terminal included. `--render`/`--render-plain` paint one frame with no backend at all
- **`diagram`** (`apps/diagram`) — A draw.io-style diagram board on `sparkles:ui-app` — an infinite world with a camera, a dense entity store, orthogonal connectors, groups, labels and a configurable Cartesian grid backdrop (`--config-file`, plus a modal `PropertyTree` settings pane over the live config — `,` or the context menu). It exists to stress the host abstraction from a direction hue and terminal cannot: neither has a camera, a world coordinate space, or a surface larger than its viewport. Its central claim is checkable by grep — no backend name appears anywhere under `apps/diagram/` (`DIA1`/`DIA2`), and `--tui` and `--gui` are the same `view`
- **`sparkles:android`** (`libs/android`) — NativeActivity glue for the Android apps (hue, the terminal): the activity handle, data dirs and content rect, the logcat sink, the APK asset bundle (manifest-driven extraction keyed by `bundle-hash`, streaming asset copies), and JNI bridges into framework classes — clipboard, typed text (`KeyCharacterMap`, IME commits), the soft keyboard, HTTP(S) downloads (`HttpURLConnection`), `ACTION_VIEW` intents, a wake lock, runtime permissions. Short JNI calls run on one attached worker thread (`withJni`), since `sparkles:ui-app` frames run on fibers ART refuses to attach. Everything platform-bound is `version (Android)`; on a host the package is its pure helpers (`bundle.d`), so any library can depend on it unconditionally
- **`sparkles:base`** (`libs/base`) — Allocation-conscious foundation utilities: `Buffer` (four storage policies), lifetime helpers, `@nogc` text readers/writers, terminal styling, terminal capability probing (`term_caps` — size/tty/colors/unicode, the single place that decision is made), hardware parallelism (`hw_caps` — CPU quota/affinity plus memory/load/swap so a pool is not wider than the host can usefully run), styled IES, logging, the shared I/O error vocabulary (`io.errors`), and the capability VFS (`vfs` — directory handles with compile-time rights, the component walk, tree removal, atomic write, and the in-memory `MemVfs`; spec: `docs/specs/base/vfs/`)
- **`sparkles:build-primitives`** (`libs/build-primitives`) — Build-system and VCS primitives: `.gitignore` parsing/matching (nested + ancestor scopes), a DbI-hook directory walker (`walkGitRepository`), and `git_env` — the scrubbed environment (`runGit`) a git child needs, so an inherited `GIT_DIR` cannot redirect a call that names its own repository
- **`sparkles:code-instrumentation`** (`libs/code-instrumentation`) — Code coverage ingestion library: universal coverage data model (`LineCoverage`, `FileCoverage`, `CoverageReport`), multi-format parsers over a shared record scanner (DMD `.lst`, GCC `gcov`, LCOV `.info`, V8 AST byte-range blocks, llvm-cov JSON) reporting failures as `ParseExpected`, anchored format auto-detection, and overlay planning (`CoveragePlan`)
- **`sparkles:core-cli`** (`libs/core-cli`) — CLI argument parsing, help formatting, interactive prompts, process utilities, ANSI unstyle helpers. The UI components moved to `sparkles:ui` (`sparkles.ui.components.*`)
- **`sparkles:diff`** (`libs/diff`) — Text diff engine behind hue's diff & PR viewer ([spec](../specs/hue/diff-view.md) `DVM*`): a backend-neutral diff document model (files → hunks → rows with pairing + intra-line emphasis), Myers line diff with scale guards, similarity alignment pairing (linematch-style DP), guarded word-level refinement (over its own token classes, or over boundaries a caller supplies via `refinePairTokens` — which is how hue's grammar-aware structural view reuses the LCS without the engine learning about tree-sitter), and a unified-patch parser/emitter (`ParseExpected` errors, output-range emit). `@safe pure nothrow @nogc` throughout: a flat arena of plain-data elements owned by `SharedBuffer` (CoW), texts borrowed as spans. Tree-sitter-free by design — `sparkles:base` is its only dependency
- **`sparkles:dmd-fmt`** (`libs/dmd-fmt`) — D formatter being built on the DMD-lexer token spine per `docs/research/code-formatting/dmd-fmt-proposal.md` (M0–M8 delivered — decisions, spike evidence and milestone table in `docs/specs/dmd-fmt/`; v1 policy: author's-breaks + structural reindent, magic trailing comma, `.editorconfig`/dfmt-key discovery, `dmd-fmt` CLI via the `cli` dub configuration): `spine.d` lexes with `commentToken`+`whitespaceToken`, records exact byte spans, surfaces silently-consumed bytes (`#line`, shebang) as explicit directive entries, and proves byte-for-byte reconstruction plus token-equality against a plain lex and doc-lex offset correspondence; `oracle.d` reduces a parse-only AST walk to sorted offset arrays (dfmt's `ASTInformation` shape); `groups.d` proves S2 — nested group trees reconstructed from the spine plus those arrays alone (bracket matching + markers + bounded lookahead), degrading to bracket-only structure on unparseable input; `cases.d` is the markdown case runner (a fixture is a documentation page: a `::: code-group` under an `<!-- fmt id=P19 -->` directive, first fence in / later fences out, `SPARKLES_UPDATE_GOLDENS=1` to bless — see `docs/specs/dmd-fmt/testing.md`); `verify.d` is the M1 verifier — `verifyFormat` (tier-3 token equality modulo whitespace + the separate DDoc-attachment check via the doc-lex, catching whitespace-only trailing-`///` reattachment) and `checkConvergence` (bounded idempotence harness with per-step verification). DMD's frontend globals are not thread-safe, so all lexing/parsing serializes on a module lock
- **`sparkles:dmd-lsp`** (`libs/dmd-lsp`) — DMD-frontend-as-a-library semantic core (ported from VisualD `dmdserver`, Boost-1.0): one-pass in-memory analysis with structured diagnostics, the `semvisitor` type oracle (`tipAt` resolved types + ddoc, `identifierSpans` classification, `definitionAt`), on the pinned `dmdserver-dub` LanguageServer fork (dub git dep; runtime sources via `$SPARKLES_DMD_IMPORT_PATH`); target profiles analyze as LDC too, and `@compute` shader modules as the dcompute LDC's device build (`$SPARKLES_LDC_IMPORT_PATH`, the package's dub device configuration, LDC's device-code rules) — see `docs/specs/dmd-lsp/`
- **`sparkles:doc-view`** (`libs/doc-view`) — The document viewer extracted from hue ([spec](../specs/hue/ui-architecture.md) `UIA14`, [docs](../libs/doc-view/index.md)): `DocumentPipeline` (read → detect → highlight → parse a file into a `Document` — code, markdown, DSV, diff, twoslash), `ViewerModel` (the laid-out widget tree and display list, views, wrapping, folding, search, the `NAV5` scroll anchor), the markdown/DSV/diff models, VitePress `@include` resolution (`VIW5`/`VIW7`), and `DocViewPane` — the viewer as an embeddable `sparkles:ui-raylib` pane with its own keys, reload-on-change and image display, which `sparkles:terminal` opens files in (`TDV`). Raylib-free except the pane and ghostty-free except the ansi-fence decoder, each compiled where the consumer links that backend (`Have_*`)
- **`sparkles:docs`** (`libs/docs`) — Markdown-based static documentation-site (SSG) library, extracted from hue's gallery: the content-fragment builders (plain + twoslash, over `sparkles:syntax`/`sparkles:twoslash`), the page shell with theme-derived chrome, appearance toggle and breadcrumbs, the mirrored site tree with per-directory indexes, shared stylesheet assets, the recursive document set (over `sparkles:build-primitives`' glob walk), and the docs-site sidebar/`srcExclude` data schema (`sparkles:wired`) that `ci --check-docs-sidebar` / `--audit-fences` consume. hue's `gallery` subcommand is its first consumer; the planned `hue site` + API doc generator build on it (spec: `docs/specs/hue/gallery.md` `GAL*`)
- **`sparkles:dql`** (`libs/dql`) — D Query Language engine: path-based aggregate addressing, typed constraint evaluation, fuzzy matching via `sparkles:fuzzy`, zero-allocation predicate filtering, and schema introspection (spec: `docs/specs/dql/SPEC.md`)
- **`sparkles:dsv`** (`libs/dsv`) — Delimiter-Separated Values engine behind hue's DSV preview / data browser ([spec](../specs/hue/dsv-preview.md) `DS*`): dialect detection (delimiter/quote/header sniffing over a bounded sample, incl. the semicolon-CSV case), a tolerant RFC 4180 parser with a raw-byte-span **identity channel** per cell (ragged rows degrade, never error), and sampled typed columns. Offsets-not-copies over borrowed sources; `@safe pure nothrow @nogc` throughout; `sparkles:base` is its only dependency
- **`sparkles:event-horizon`** (`libs/event-horizon`) — Completion-first (io_uring/kqueue/IOCP) event loop with a native algebraic-effect layer (three API tiers: callback, direct-style fibers, `Effect!T`)
- **`sparkles:font`** (`libs/font`) — Font files parsed in D over borrowed bytes, with no C library: faces and collections, the table directory with checksums, typed views of `head`/`hhea`/`maxp`/`OS/2`/`post`/`hmtx`/`fvar`/`avar`/`STAT`, character maps chosen in HarfBuzz's order with lenient checks and coverage ranges, `name` records decoded through base's codecs, and glyph names from `post` and the `CFF` charset. Milestone M1 of `docs/specs/font`; malformed data returns a `FontError`, nothing allocates
- **`sparkles:font-oracle`** (`libs/font-oracle`) — Test-only: checks `sparkles:font` against HarfBuzz, through hand-declared prototypes, over every bundled font (`$SPARKLES_FONTS_PATH`), so that `sparkles:font` itself links no C library
- **`sparkles:fuzzy`** (`libs/fuzzy`) — Bounded allocation-free fuzzy search core: Unicode-aware query/constraint parsing, Thompson-NFA globs, exact needle-deletion witnesses with source-byte positions, affine-gap ranking with a deterministic fallback, composite scoring and global top-K, fixed-point frecency/combo history, and generation-bound chunked search. Depends only on `sparkles:base` and `expected`; hue owns clocks, jobs, snapshots, and persistence (spec: `docs/specs/fuzzy/`)
- **`sparkles:ghostty`** (`libs/ghostty`) — D bindings + ImportC integration layer for `libghostty-vt` (Ghostty's terminal VT engine)
- **`sparkles:http`** (`libs/http`) — HTTP/1.1 building blocks (request parser + minimal server API) over `sparkles:event-horizon`
- **`sparkles:input`** (`libs/input`) — Abstract, capability-tiered input vocabulary shared by every `sparkles:ui` target: events as Regular values (a sum type over key/pointer/wheel/focus/resize, positions in the toolkit's 0-based cells) plus the tier-0/1/2 interaction ladder; `sparkles:tui` decodes its wire formats directly into it (design: `docs/specs/ui/input.md`)
- **`sparkles:math`** (`libs/math`) — Small math primitives for games/graphics (early stage)
- **`sparkles:metadata`** (`libs/metadata`) — Dependency-free passive UDA vocabulary (`WireName`, `WireCase`, `WireRepr` and the format tags, `CaseStyle`, `Aliases`, `Label`, `Description`, `Range`) shared without coupling foundational libraries to CLI, serialization, UI, or query-engine policy
- **`sparkles:nix`** (`libs/nix`) — D bindings for the Nix C API (`libnix{util,store,expr,fetchers,flake,main}-c`) — ImportC raw layer + high-level RAII/`Expected` wrappers (eval, store, flakes)
- **`sparkles:reflection`** (`libs/reflection`) — Dependency-free structural reflection kernel: one closed `typeKindOf` classification and indexed field/property primitives (the field spine, public getter discovery incl. const-readability, the value-like wrapper rule, CTFE helpers) that consumers build their own walks from; the property tree, text writers, and query schemas all dispatch on it — structure here, policy (and each traversal) in the consumers ([docs](../libs/reflection/index.md))
- **`sparkles:raylib-text`** (`libs/raylib-text`) — Reusable raylib text-rendering core shared by `apps/terminal` and `hue --gui`: a multi-face `FontSet` (real bold/italic variants, on-demand atlas growth, `--font-codepoint-map` routing), `drawGrapheme`/`drawSolid` + a per-run `drawText`, and procedural box-drawing (`drawBox`, so `─│┼╭…` connect across cells instead of using gappy font glyphs)
- **`sparkles:shaders`** (`libs/shaders`) — Single-source shader vocabulary: GLSL-shaped `vec2`/`vec3`/`vec4` (native `__vector`s under LDC where the size is a power of two, a lookalike struct otherwise), the `v2`/`v3`/`v4` constructors, UFCS component reads, and the GLSL built-ins (`floor`, `mod`, `dot`, `clamp`, `mix`, …) with the specification's semantics on the CPU. In a dcompute build (`-mdcompute-targets`, which predefines `LDC_DCompute`) its `@compute`/`@fragment`/`@input`/`@uniform`/`Sampler2D` are LDC's real `ldc.dcompute` symbols; otherwise inert stand-ins, so an ordinary build sees plain D. Dependency-free
- **`sparkles:source-view`** (`libs/source-view`) — Source viewing and markdown rendering components over `sparkles:ui` (`sparkles.source_view.code`, `sparkles.source_view.markdown`): maps syntax-highlighted code and structural markdown ASTs into `sparkles:ui` `WidgetTree` nodes for backend-neutral GUI/TUI rendering parity, with fence scrolling, foldable sections, callouts, task lists, and box-bordered aligned tables
- **`sparkles:syntax`** (`libs/syntax`) — Syntax highlighting: engine-agnostic highlight-event stream, scope-compatible label vocabulary, theme layer, ANSI + HTML renderers, tree-sitter precise-mode engine (design: `docs/specs/syntax/`), plus a structural markdown model (`md/model.d`, `extractMarkdown`) with an `MdDoc → HTML` emitter (`md/render_html.d`) for preview/doc renderers
- **`sparkles:terminal-view`** (`libs/terminal-view`) — The terminal core as an embeddable component, extracted from `apps/terminal` (spec: `docs/specs/ui-app/terminal-view.md`, `TVW`): `TerminalView` — the whole emulator as a `runApp` component (libghostty screen, per-cell raylib renderer, pty lifecycle, the byte-oracle-pinned key encoding seam, OSC color-query replies) — plus the embedding surface (`frame` at a pane size, `paintPane`, and the host-free `pump`/`decideRedraw`/`sendKey`/`notifyFocus`/`resize`/`openCore`) and `cell_paint.d`, which renders the VT screen through any `isCanvas` target so a pane works fontless in a terminal. Embedded by `apps/ui-gallery`'s Terminal page (`TVW7`)
- **`sparkles:test-runner`** (`libs/test-runner`) — General-purpose `unittest` runner (silly successor): parallel runtime tests plus `@ctfe`, `@betterC`, `@wasm`, `@benchmark`, and `@workload` modes
- **`sparkles:test-utils`** (`libs/test-utils`) — Testing helpers: diff tools, temp-filesystem helpers, string helpers
- **`sparkles:tree-sitter`** (`libs/tree-sitter`) — D bindings for the tree-sitter C runtime: ImportC surface, RAII wrappers with `TsError` reporting, grammar dlopen (grammars supplied by the nix `ts-grammars` bundle via `$SPARKLES_TS_GRAMMAR_PATH`; all come from nixpkgs except SDLang — in-house at [`PetarKirov/tree-sitter-sdl`](https://github.com/PetarKirov/tree-sitter-sdl), `nix/packages/tree-sitter-sdl.nix` — and D, pinned to [`PetarKirov/tree-sitter-d`](https://github.com/PetarKirov/tree-sitter-d) for DUB single-file recipe injections, `nix/packages/tree-sitter-d.nix`)
- **`sparkles:tui`** (`libs/tui`) — Full-screen interactive terminal substrate: a 2-D cell grid with a compact packed cell (`GridT`), a retained diff compositor (`Screen`), terminal lifecycle (raw mode / alt screen / mouse), SGR-1006 input decoding, an event loop, and the terminal geometry vocabulary (`TermPosition`). Rendering core chosen by measurement — see `docs/specs/tui/`
- **`sparkles:twoslash`** (`libs/twoslash`) — Twoslash render overlay on `sparkles:syntax`: the TypeScript-`twoslash` node model as opaque data (JSON via `sparkles:wired`) rendered as type-annotation overlays in HTML (the `.twoslash-*` contract + CSS), ANSI meta-lines, and the `hue --gui` raylib backend; `render_widgets.d` maps the node model to a `sparkles:ui` `WidgetTree` for backend-neutral GUI/TUI parity
- **`sparkles:twoslash-d`** (`libs/twoslash-d`) — The D twoslash analyzer: notation parser (`^?`, `---cut---` family, `@errors:`/`@dflags:`/`@import:`, custom tags), node assembly over `sparkles:dmd-lsp` (hover-per-identifier + ddoc, queries, error nodes, two-phase cut/position resolution), and the `.twoslash.json` emitter with the D producer contract (`language`/`offsetEncoding`)
- **`sparkles:twoslash-protocol`** (`libs/twoslash-protocol`) — The twoslash node model (`Node`/`TwoslashReturn`) + wired JSON ingest, extracted from `sparkles:twoslash` so producers (`sparkles:twoslash-d`) consume it without the render lib's `sourceLibrary` closure; owns the `language`/`offsetEncoding` payload declaration and the legacy UTF-16 offset normalization
- **`sparkles:ui`** (`libs/ui`) — Canvas-first three-level UI toolkit (state-machines / layout / widgets) — the repository's single UI stack: a DbI `isCanvas!T` backend seam, a semantic `Slot`/`Palette` style layer, a unified `Theme` (syntax rules + slots + metrics + glyphs, runtime-swappable), a flat-arena widget model, box-flow layout, the `view→layout→buildDisplayList→paint` pipeline, `components/` — the terminal component set (box/table/tree/meter/tasklist/live/…) moved here from `core-cli` — and the keymap/lantern layer (`keymap.d`/`lantern.d`/`components/lantern_view.d`: bindings-as-data over app-supplied command/scope enums plus the which-key-style guide, extracted from hue; spec: `docs/specs/ui/keymap.md`). The built-in effects run as tier-0 CPU transforms by default, and gain their generated GPU halves only in the opt-in `gpu-effects` configuration (selected beside every `ui-raylib` dependency, and which needs `ldc2-vulkan`). GL-free; geometry specializes `sparkles:math`'s `Vector`
- **`sparkles:ui-app`** (`libs/ui-app`) — The application host for `sparkles:ui`: backend selection (`--gui`/`--tui`/`--html`, display probing, the Android answer), the shared window/font CLI and its setup order, and the frame/event loop — so an application never names a canvas. Ships three configurations (`tui`/`gui`/`full`) and a headless recording target that makes an app's own frame loop testable (design: `docs/specs/ui-app/`)
- **`sparkles:ui-raylib`** (`libs/ui-raylib`) — `sparkles:ui`'s GPU backend adapter: `RaylibCanvas` scales the toolkit's cell-space display list to pixels over the shared `sparkles:raylib-text` `FontSet`, and `RaylibEvents` synthesizes `sparkles:input` events from raylib's polled state (press/release edges, drag, wheel, typed characters, focus/resize)
- **`sparkles:ui-tui`** (`libs/ui-tui`) — `sparkles:ui`'s terminal backend adapter: `GridCanvas` paints the toolkit's display list into a `sparkles:tui` cell grid (compositing fills, box-drawing borders, undercurl squiggles, clip stack), which the tui `Screen` cell-diffs to a minimal byte stream
- **`sparkles:versions`** (`libs/versions`) — Design-by-Introspection versioning library (SemVer, DMD, CalVer, PyPI, Maven, Deb, …) with VERS/pURL interop
- **`sparkles:vulkan`** (`libs/vulkan`) — Vulkan bindings over the target's real headers: loader discovery, branded handles, typed results, compile-time `sType`, bounded enumeration, extension/flag/name helpers and per-instance/device dispatch; Linux surface ABI comes from target-gated ImportC headers while the minimal Win32/Metal surface fragments avoid importing SDK inline bodies, and all ownership/policy stays in consumers such as `sparkles:vulkan-wsi`
- **`sparkles:vulkan-wsi`** (`libs/vulkan-wsi`) — Renderer bridge above native WSI: validates typed native handle pairs, enables the matching target-gated Vulkan surface extension, owns instance/surface/device/graphics+present queue selection, and brackets Wayland ICD calls with the WSI native-I/O borrow so Mesa cannot deadlock against Event Horizon's prepared read; it also owns the backend-neutral command pool, frame synchronization, swapchain decisions and deferred retirement that `sparkles:ui-sdl3` consumes through compatibility re-exports; the native triangle follows `docs/specs/window-system-integration/`
- **`sparkles:wsi`** (`libs/wsi`) — Dependency-light native desktop window-system integration: unit-explicit geometry, generation-safe ids, typed errors/raw handles, lossless Regular events and a deterministic recording backend; native Wayland, X11, Win32 and AppKit lifecycle adapters share Event Horizon's only wait (Wayland/XCB over uring, User32/IOCP and CFRunLoop/kqueue), with immediate Wayland configure ack, a renderer native-I/O borrow, and IMM32 text input on Win32; XIM and remaining features follow `docs/specs/window-system-integration/`
- **`sparkles:wired`** (`libs/wired`) — Serialization: a compile-time-reflected wire format with a JSON surface (`fromJSON`/`toJSON`), used for opaque payload ingest (e.g. the twoslash node model)
- **`sparkles:ui-sdl3`** (`libs/ui-sdl3`) — SDL3 window system for `sparkles:ui`: window, input source, and the Vulkan surface (frame machinery from `sparkles:vulkan-wsi`)
- **`sparkles:test-runner-impl`** (`libs/test-runner-impl`) — internal: the prebuilt implementation library behind the `sparkles:test-runner` shim

## Module map

```
sparkles/
├── flake.nix                       # Nix flake (devshell, `ci` package, checks)
├── dub.sdl                         # Root package; declares every sub-package
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
│   ├── nix-eval/                   # `sparkles:nix` demo (executable)
│   │   └── src/app.d               # Eval an expr/flake output, recursively render the Value
│   ├── shader-compile/             # D shaders -> SPIR-V (custom LDC) -> GLSL (spirv-cross), stamped
│   │   └── src/app.d               # dub describe -> the `@compute` unit, the pipeline, the --if-stale stamp
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
│   │   ├── glob_walk.d             # include/exclude globs over the gitignore walk (GitGlobFilter)
│   │   └── git_env.d               # runGit / gitChildEnvironment: a git child never inherits GIT_DIR
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
│   ├── shader/src/sparkles/shaders/ # attributes.d (device symbols or stand-ins), types.d (vec2/3/4, v2/v3/v4),
│   │                               # math.d (GLSL built-ins), testing.d (the tests, host-only), compute_mode.d (the `@compute` scanner)
│   ├── ui/shaders/                 # effects.d: the @fragment entry points (device-only, outside sourcePaths);
│   │   └── (../generated/shaders/) # the GLSL the `gpu-effects` build derives from them — git-ignored
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
│   ├── font/src/sparkles/font/     # face.d (open, directory), tables.d, cmap.d, names.d, glyph_names.d, errors.d; test/ fixtures + mutation corpus
│   ├── font-oracle/                # test-only: HarfBuzz differential over the bundled fonts
│   ├── raylib-text/src/sparkles/raylib_text/  # multi-face FontSet (on-demand atlas, real bold/italic) + drawGrapheme/drawSolid/drawText (shared by terminal + hue --gui)
│   ├── ghostty/src/sparkles/ghostty/
│   │   ├── c.c                     # ImportC shim: #include <ghostty/vt.h>
│   │   └── package.d               # public import sparkles.ghostty.c
│   └── nix/src/sparkles/nix/
│       ├── c.c                     # ImportC shim: #include <nix_api_*.h> (whole Nix C API)
│       ├── error.d, strings.d      # NixError/NixResult/NixContext/checkCall; string-sink bridge
│       ├── library.d, value.d      # initNix/settings; Value handle + ValueType
│       ├── store.d, eval.d         # Store/StorePath; EvalState + value extraction/construction
│       └── flake.d, session.d      # flake settings/ref/lock/outputs; NixSession facade
├── docs/
│   ├── guidelines/                 # Cross-cutting agent/style guides (this file lives here)
│   ├── libs/<name>/                # Per-library Diátaxis docs
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
