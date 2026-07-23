# `hue` — Feature Requirements (all rendering modes)

_**Status:** living inventory · **Date:** 2026-07-23 · **Scope:** `apps/hue`
features common to every rendering mode — invocation, source acquisition,
language detection, the highlight engine, themes, color depth, output-mode
dispatch, the ANSI / HTML / terminal-previewer sinks, degradation, and
non-functional requirements. The raylib GUI is specified separately in
[gui.md](./gui.md)._

See the [overview](./index.md) for the status scheme (`not started` /
`researched` / `partial` / `full (<sha>)`), the ID scheme, and the rendering-mode
map. Requirement statements use lowercase **must** / **should** with the repo's
usual force. "Traces to" names the implementing source and, for `full` rows, the
primary commit is in the Status cell.

## Invocation & CLI (`CLI`)

Parsed by `sparkles.core_cli.args.parseCliArgs!CliParams` in `app.d`.

| ID   | Requirement                                                                                                                                                                                                                                                                  | Status               | Traces to                                 |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | ----------------------------------------- |
| CLI1 | `hue [options] [path]` must highlight `path`; with no path it highlights hue's own bundled source.                                                                                                                                                                           | full (`74d8f6a3`)    | `app.main`; `sourcePath`/`source`         |
| CLI2 | `--html` must select HTML output instead of ANSI.                                                                                                                                                                                                                            | full (`74d8f6a3`)    | `CliParams.html`                          |
| CLI3 | `--theme <name>` must select a built-in theme (default `catppuccin-mocha`).                                                                                                                                                                                                  | full (`74d8f6a3`)    | `CliParams.theme`                         |
| CLI4 | `--gui` must force the raylib window and `--no-gui` (alias `--tui`) must force terminal output; with neither, hue must autodetect (see `MOD6`). On a no-gui build, `--gui` must error out cleanly. (`--gui` force + no-gui-build error done; `--no-gui`/autodetect pending.) | partial (`e6063309`) | `CliParams.gui`; `version(HueGui)` branch |
| CLI5 | `--font`, `--font-size`, `--window-width`, `--window-height` must configure the GUI window (see `gui.md`).                                                                                                                                                                   | full (`c2b49e99`)    | `CliParams.font*`/`window*`               |
| CLI6 | `--line-numbers` / `--code-line-numbers` (both default on, disableable with `=false`) must configure the GUI gutters.                                                                                                                                                        | full (`5b862346`)    | `CliParams.lineNumbers`/`codeLineNumbers` |
| CLI7 | `--help` must print a usage/description header for the program and every option.                                                                                                                                                                                             | full (`d87397b3`)    | `HelpInfo` in `app.main`                  |

## Source acquisition (`SRC`)

| ID   | Requirement                                                                                                             | Status            | Traces to                              |
| ---- | ----------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------- |
| SRC1 | With a path argument the whole file must be read into memory as the highlight input.                                    | full (`74d8f6a3`) | `readText(sourcePath)`                 |
| SRC2 | With no path, hue must highlight its own `app.d`, embedded at compile time via `import()` so it works from any install. | full (`1c7398a0`) | `import("app.d")`; `stringImportPaths` |

## Language detection (`LNG`)

| ID   | Requirement                                                                                                    | Status            | Traces to                      |
| ---- | -------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------ |
| LNG1 | The grammar language must be derived from the file extension, canonicalized through `sparkles:syntax` aliases. | full (`74d8f6a3`) | `canonicalLanguage(extension)` |

## Highlight engine (`ENG`)

hue drives the `sparkles:syntax` precise pipeline; the engine internals are
specified in [`docs/specs/syntax`](../syntax/index.md).

| ID   | Requirement                                                                                                                                                      | Status            | Traces to                                                 |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------- |
| ENG1 | Highlighting must use the injection-aware path so markdown (and other languages with `injections.scm`) get fenced/inline content highlighted by nested grammars. | full (`9b0a4b50`) | `highlightInjected(cache, lang, source, events)`          |
| ENG2 | Grammars must be loaded from the nix bundle via `$SPARKLES_TS_GRAMMAR_PATH`; a `GrammarRegistry`/`TsConfigCache` is built once.                                  | full (`74d8f6a3`) | `GrammarRegistry.fromEnvironment`; `TsConfigCache.create` |
| ENG3 | Highlighting must produce a `HighlightEvent` stream over the source, consumed identically by every rendering mode.                                               | full (`74d8f6a3`) | `SmallBuffer!HighlightEvent events`                       |
| ENG4 | On any engine failure (no grammar, parse error) hue must fall back to a single plain-text span covering the whole source.                                        | full (`74d8f6a3`) | `res.hasError` → `HighlightEvent.sourceSpan`              |

## Themes (`THM`)

| ID   | Requirement                                                                                                                    | Status            | Traces to                         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------- | --------------------------------- |
| THM1 | The named theme must be resolved from `builtinThemes`; an unknown name must warn and fall back to `builtinDark`.               | full (`74d8f6a3`) | `builtinThemes.get(themeName, …)` |
| THM2 | The full sorted built-in theme set must be materialized once (names + parallel `Theme` values) for the live previewer and GUI. | full (`74d8f6a3`) | `names`/`themes` in `app.main`    |
| THM3 | A theme must be resolved against the standard `LabelSet` before rendering (`ResolvedTheme`).                                   | full (`74d8f6a3`) | `resolveTheme(theme, labels)`     |

## Color depth (`CLR`)

| ID   | Requirement                                                                                    | Status            | Traces to            |
| ---- | ---------------------------------------------------------------------------------------------- | ----------------- | -------------------- |
| CLR1 | ANSI output (non-interactive and previewer) must adapt to the terminal's detected color depth. | full (`74d8f6a3`) | `detectColorDepth()` |

## Output-mode dispatch (`MOD`)

Exactly one mode runs per invocation; see the [mode map](./index.md#rendering-modes).

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                           | Status            | Traces to                                   |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------- |
| MOD1 | `--gui` (explicit or autodetected) on a GUI-enabled build must dispatch to the raylib window and return its exit code.                                                                                                                                                                                                                                                | full (`e6063309`) | `if (cli.gui) version(HueGui)`              |
| MOD2 | `--gui` on a no-gui build must print a rebuild hint to stderr and exit non-zero.                                                                                                                                                                                                                                                                                      | full (`e6063309`) | `else stderr.writeln(…); return 1`          |
| MOD3 | Non-interactive (`stdout` not a tty) must emit the whole file once (HTML if `--html`, else ANSI) and exit.                                                                                                                                                                                                                                                            | full (`74d8f6a3`) | `!interactive` branch                       |
| MOD4 | An interactive tty (no `--html`) must open the live terminal previewer.                                                                                                                                                                                                                                                                                               | full (`74d8f6a3`) | `interactive` branch → `runLoop`            |
| MOD5 | If a raw-key session can't be acquired in an otherwise-interactive tty, hue must degrade to emitting the whole file as ANSI.                                                                                                                                                                                                                                          | full (`74d8f6a3`) | `sessFactory is null` → `emitAnsiWholeFile` |
| MOD6 | With no explicit mode flag (`--gui`/`--no-gui`/`--html`) on a GUI-enabled build, hue must default to the GUI window when a graphical display is available (Linux/BSD: `$DISPLAY` or `$WAYLAND_DISPLAY` set; macOS/Windows: a local, non-SSH session), and otherwise fall through to the terminal dispatch (`MOD3`–`MOD5`). On a no-gui build it always falls through. | not started       | `app.main` (display probe)                  |
| MOD7 | The mode flags must override autodetection: `--no-gui`/`--tui` forces the terminal path even with a display present; `--gui` forces the window even with no display detected (raylib surfaces any failure).                                                                                                                                                           | not started       | `app.main` (flag precedence)                |

## ANSI terminal output (`ANS`)

| ID   | Requirement                                                                                                        | Status            | Traces to                         |
| ---- | ------------------------------------------------------------------------------------------------------------------ | ----------------- | --------------------------------- |
| ANS1 | Non-interactive/piped output must render the whole file to ANSI with italics and background emission enabled.      | full (`74d8f6a3`) | `emitAnsiWholeFile`; `renderAnsi` |
| ANS2 | ` ```ansi ` fenced blocks embedded in a doc are passed through as literal SGR (the tty renders them) in ANSI mode. | full (`74d8f6a3`) | (renderer pass-through)           |

## HTML output (`HTM`)

| ID   | Requirement                                                                                                          | Status            | Traces to                             |
| ---- | -------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------- |
| HTM1 | `--html` must emit a self-contained `<style>` + `<pre class="syn-root"><code>` document with CSS-class highlighting. | full (`74d8f6a3`) | HTML branch; `renderHtml(cssClasses)` |
| HTM2 | The emitted stylesheet must carry the theme's default fg/bg on `.syn-root` (no duplicate `pre{}` color rule).        | full (`74d8f6a3`) | `writeThemeStylesheet`                |

The GUI's interactive features apply **best-effort** to HTML output too — HTML
selection is the browser's, so parity means emitting markup that copies cleanly
and (optionally) a preview/gutter:

| ID   | Requirement                                                                                                                                                                                                                         | Status              | Traces to                                                                       |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------- |
| HTM3 | Best-effort [`SEL`](./gui.md) parity: the markup must be selectable so a browser copy yields the **original source**; any gutter / line-number / decoration content must be non-selectable (`user-select: none`) so it is excluded. | partial             | plain `<pre><code>` copies to source today; non-selectable gutter awaits `HTM4` |
| HTM4 | Best-effort [`NUM`](./gui.md) parity: HTML output may render an optional **line-number gutter** (CSS counters or per-line spans), non-selectable per `HTM3`.                                                                        | not started         | proposed HTML gutter                                                            |
| HTM5 | Best-effort [`MDP`](./gui.md) parity: a markdown file may render to a **rich HTML preview** via the shared `sparkles:syntax` `MdDoc → HTML` emitter, not only highlighted source.                                                   | planned/branch-only | `DEF3` (below); syntax spec `J1`                                                |

## Interactive terminal previewer (`PRV`)

`previewer.d` — the live theme browser (the baseline the **full TUI**
([tui.md](./tui.md)) extends). Its render/output core is `@nogc nothrow`.

| ID   | Requirement                                                                                                                                                                   | Status            | Traces to                                   |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------- |
| PRV1 | The previewer must repaint a full frame, flush, read one key, and repeat until quit/select.                                                                                   | full (`74d8f6a3`) | `runLoop`                                   |
| PRV2 | ↑/↓ must cycle the selected theme (wrapping) and repaint live.                                                                                                                | full (`74d8f6a3`) | `runLoop` `Key.up`/`Key.down`               |
| PRV3 | Enter must select the theme: leave the alt screen and print the **whole** file highlighted in that theme onto the primary screen.                                             | full (`d1c4e159`) | `LoopResult.selected`; `renderFull`         |
| PRV4 | Any other key / cancel must quit and print nothing.                                                                                                                           | full (`74d8f6a3`) | `Key.cancel`/`Key.other`                    |
| PRV5 | A frame must show a header (title · theme name · index), a hint line, separators, the highlighted **viewport slice**, and a scrolling theme-list window around the selection. | full (`844680a3`) | `Previewer.buildFrame`                      |
| PRV6 | The viewport must show only the top `maxCode` lines that fit (height-derived), not the whole file, keeping the fold O(visible).                                               | full (`fd22c112`) | `firstLines`; `buildFrame` `maxCode`        |
| PRV7 | The theme backdrop must fill the viewport via back-color-erase (open theme bg, then erase), with begin/end synchronized-output markers.                                       | full (`844680a3`) | `CtlSeq.syncBegin`/`eraseDisplay`/`syncEnd` |
| PRV8 | The alt screen must be entered on start and restored (show cursor, exit alt screen) on exit; its contents are discarded.                                                      | full (`74d8f6a3`) | `enterAltScreen`/`exitAltScreen`            |

## Degradation & diagnostics (`DEG`)

| ID   | Requirement                                                                                                        | Status            | Traces to                         |
| ---- | ------------------------------------------------------------------------------------------------------------------ | ----------------- | --------------------------------- |
| DEG1 | Only degradation warnings are logged (logger level = warning); normal operation is silent.                         | full (`d87397b3`) | `initLogger(LogLevel.warning)`    |
| DEG2 | A missing grammar must warn (`no grammar for '<lang>'`) and render plain text, not fail.                           | full (`74d8f6a3`) | `warning(i"no grammar …")`        |
| DEG3 | An unknown `--theme` must warn and use the default dark theme.                                                     | full (`74d8f6a3`) | `builtinThemes.get` fallback      |
| DEG4 | Without `$SPARKLES_TS_GRAMMAR_PATH`, hue must still run — degrading to plain text for grammar-requiring languages. | full (`74d8f6a3`) | `GrammarRegistry.fromEnvironment` |

## Build and packaging (`BLD`)

How hue is compiled and shipped. The GUI backend is included in the default
build; a raylib-/ghostty-free variant stays available for terminal-only use and
minimal dependency closures.

| ID   | Requirement                                                                                                                                                                                                                                            | Status            | Traces to                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ------------------------------------------------ |
| BLD1 | The default dub configuration (`application`) must compile the GUI backend in (pulling `sparkles:raylib-text` + `sparkles:ghostty`), so a stock `dub build :hue` and the installed binary have `--gui` and the markdown preview with no special build. | not started       | `apps/hue/dub.sdl` `configuration "application"` |
| BLD2 | A `no-gui` dub configuration must build the raylib-/ghostty-free variant (today's `application` behaviour) for terminal-only installs and minimal closures.                                                                                            | not started       | `apps/hue/dub.sdl` `configuration "no-gui"`      |
| BLD3 | The nix `packages.hue` must build the GUI-enabled default; a `packages.hue-no-gui` must build the headless variant with no raylib/GL in its closure.                                                                                                   | not started       | `nix/packages/hue.nix`                           |
| BLD4 | `dub test :hue` must stay headless — linking no window/GL — regardless of the default flip; `gui.d` stays excluded from the `unittest` config.                                                                                                         | full (`e6063309`) | `apps/hue/dub.sdl` `configuration "unittest"`    |

## Non-functional (`NFR`)

| ID   | Requirement                                                                                                                                                                                                                   | Status            | Traces to                                 |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------------- |
| NFR1 | Startup (file read, parse, theme-list build) may allocate on the GC; the previewer's per-frame render/output core must be `@nogc nothrow` (a theme switch triggers no GC pause).                                              | full (`0657c94a`) | `Previewer` `@nogc` methods; `TermOut`    |
| NFR2 | Each previewer repaint must assemble into one reused `SmallBuffer` and flush with a single write; the resolved theme table is reused and only rebuilt on change.                                                              | full (`0657c94a`) | `Previewer.frame`/`styleBuf`; `themeView` |
| NFR3 | A raylib-/ghostty-free build of hue must remain available (the `no-gui` config, `BLD2`); the GUI + preview modules compile only under the GUI-enabled configs (`application`/`gui`) and the `unittest` build (minus `gui.d`). | full (`e6063309`) | `apps/hue/dub.sdl` `excludedSourceFiles`  |

## Deferred, researched & branch-only (`DEF`)

Roadmap items — planned/researched features, and modes that exist on another
branch. Library-engine roadmap (TextMate second engine, locals, injection
`combined`, incremental editor loop, UTF-16 sources) lives in the
[`sparkles:syntax` spec](../syntax/index.md); the rows below are the ones that
surface as **hue** capabilities.

| ID    | Requirement                                                                                                                                                                                                                                                                                   | Status                 | Traces to                                                              |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ---------------------------------------------------------------------- |
| DEF1  | `--twoslash <nodes.json>` mode (ANSI default / `--html` / `--gui`) — D-native Twoslash rendering.                                                                                                                                                                                             | planned/branch-only    | [twoslash.md](./twoslash.md) `TWM1`–`TWM3`                             |
| DEF2  | `--markdown <file.md>` mode — render Markdown to HTML via the shared `MdDoc → HTML` emitter.                                                                                                                                                                                                  | planned/branch-only    | [twoslash.md](./twoslash.md) `TWM4`                                    |
| DEF3  | The `MdDoc → HTML` emitter (`sparkles:syntax` `md/render_html.d`) that the `--markdown`/twoslash-docs paths need exists only on `feat/syntax-twoslash`.                                                                                                                                       | planned/branch-only    | `libs/syntax` (branch); syntax spec `J1`                               |
| DEF4  | Runtime **theme-file parsing** (load user themes: native JSON, TextMate/VSCode JSON, Helix TOML) so `--theme` can name a file, not just a built-in.                                                                                                                                           | researched/not-started | syntax spec `D6`                                                       |
| DEF5  | **CSS-variable multi-theme HTML** output mode (one document, theme switched via `:root[data-theme]` / `prefers-color-scheme`).                                                                                                                                                                | researched/not-started | syntax spec `F6`; `render/html.d`                                      |
| DEF6  | **Content-based language detection** (a Linguist-style cascade) — today the language is only the file extension / fence label.                                                                                                                                                                | not started            | syntax spec §deferred (`canonicalLanguage` only)                       |
| DEF7  | A grapheme/east-asian **width table** so wide/CJK/combining/tab characters occupy their true cell count (replacing the v1 one-column-per-codepoint metric).                                                                                                                                   | researched/not-started | [gui.md](./gui.md) `FNT6`                                              |
| DEF8  | Color-emoji rendering in the GUI (a separate rasterizer for CBDT/COLR) — raylib/stb_truetype cannot.                                                                                                                                                                                          | not started            | [gui.md](./gui.md) `FNT7`                                              |
| DEF9  | **Pluggable overlays** — a backend-agnostic overlay seam generalized from twoslash, plus new overlay kinds (source map, coverage, tracing, tree-sitter inspector, code size).                                                                                                                 | researched/not-started | [overlays.md](./overlays.md) `OVL*`                                    |
| DEF10 | **Notifier / interactive popups** — a cross-backend (GUI/TUI/HTML) snacks.nvim-style popup component (collapse-to-icon, expand, buttons, expandable items) with startup-info and file-info popups.                                                                                            | researched/not-started | [notifier.md](./notifier.md) `NTF*`/`NSI*`/`NFI*`                      |
| DEF11 | **Full-screen TUI** — grow the minimal theme-selection previewer into a terminal port of the GUI viewer: scrolling, a cell scrollbar, SGR mouse, selection → source offsets + OSC 52 copy, wrapping, line numbers, and the markdown preview (reusing the raylib-free `PreviewLine[]` layout). | researched/not-started | [tui.md](./tui.md) `TIN*`/`TSF*`/`TSB*`/`TSL*`                         |
| DEF12 | **UI component library** (proposed `sparkles:ui`) — a canvas-first, no-native-widgets library with GUI/TUI/HTML targets and three levels (abstract state machines · layout containers · `view(state)→widget` widgets), immediate/retained/SSG render modes; hue's widgets refactor onto it.   | researched/not-started | [ui-architecture.md](./ui-architecture.md) `UIA*`/`STM*`/`LAY*`/`WGT*` |
| DEF13 | **`@sparkles/hue` web integration** — a JS/TS npm package that swaps Shiki for `sparkles:syntax` in web frameworks (VitePress/Next/Solid Start) across SSG/SSR (process shell-out first) and a future wasm client-side backend.                                                               | not started            | [web-integration.md](./web-integration.md) `PKG*`/`SHL*`/`WSM*`/`FWK*` |
| DEF14 | **Content folding** — expand/collapse of code structures, markdown sections/lists, and any tree-sitter CST node (a cross-backend fold-range model + presentation-free fold-state machine, elided from the wrapped-line render).                                                               | not started            | [folding.md](./folding.md) `FLD*`/`FSR*`                               |
| DEF15 | **Tree / DAG view** — an interactive tree + DAG component (snacks.nvim-explorer-style) across GUI/TUI/HTML: file explorer, tree-sitter inspector, file outline, git graph, dependency graph; a `sparkles:ui` widget.                                                                          | not started            | [tree-view.md](./tree-view.md) `TRV*`/`DAG*`/`TVU*`                    |
| DEF16 | **Navigation** — link following & go-to: markdown anchors + local-file links, module/import & relative paths, doc-comment (`$(REF …)`/`@see`) references, and LSP go-to-definition; intra- and inter-document, cross-backend.                                                                 | not started            | [navigation.md](./navigation.md) `LNK*`/`REF*`/`LNB*`                  |

## Module coverage (general spec)

Every non-GUI source file maps to the requirements above:

| Source                     | Key symbols                                                                               | Requirements                                                                   |
| -------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `apps/hue/src/app.d`       | `CliParams`, `main`, `emitAnsiWholeFile`, mode dispatch                                   | `CLI*`, `SRC*`, `LNG1`, `ENG*`, `THM*`, `CLR1`, `MOD*`, `ANS*`, `HTM*`, `DEG*` |
| `apps/hue/src/previewer.d` | `Previewer`, `runLoop`, `buildFrame`, `renderFull`, `firstLines`, `TermOut`, `LoopResult` | `PRV*`, `NFR1`, `NFR2`                                                         |
| `apps/hue/dub.sdl`         | build configurations (`application`/`gui`/`no-gui`/`unittest`)                            | `CLI4`, `MOD1/2`, `BLD1/2/4`, `NFR3`                                           |
| `nix/packages/hue.nix`     | `packages.hue`, `packages.hue-no-gui`                                                     | `BLD3`                                                                         |

→ [GUI requirements](./gui.md) · [Overview](./index.md)
