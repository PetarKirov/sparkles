# `hue` — Feature Specification

_**Status:** living inventory · **Date:** 2026-08-05 · **Scope:** `apps/hue`
(`apps/hue/src/*.d`) plus the sparkles libraries it drives (`sparkles:syntax`,
`sparkles:core-cli`, `sparkles:raylib-text`, `sparkles:ghostty`)._

`hue` is an interactive syntax-highlighting file viewer and live theme previewer
over [`sparkles:syntax`](../syntax/index.md). It reads a source file (or its own
source), highlights it with the precise tree-sitter pipeline, and renders it in
one of four **rendering modes**: non-interactive **ANSI**, **HTML**, an
interactive terminal **previewer**, and an optional raylib **GUI** window with a
render-markdown.nvim-style markdown preview.

This spec is a **traceable feature inventory** and the **source of truth** for
hue: every requirement carries an ID, a status, and a link to the code that
implements it, so every part of the codebase maps to a requirement (see
[Traceability](#traceability) below).

## Design sources

The design and rationale for the two large hue efforts live in GitHub issues,
whose normative requirements are folded into these specs (the specs supersede the
issues as the requirement of record):

| Issue                                                     | Title                                                                                                                      | Folded into                                       |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| [#121](https://github.com/PetarKirov/sparkles/issues/121) | hue: raylib GPU rendering backend (`--gui`) — styled runs as data on `sparkles:syntax` + the shared `sparkles:raylib-text` | [gui.md](./gui.md) (§ Design & scope, milestones) |
| [#120](https://github.com/PetarKirov/sparkles/issues/120) | `sparkles:twoslash` — D-native Twoslash (umbrella)                                                                         | [twoslash.md](./twoslash.md)                      |
| [#122](https://github.com/PetarKirov/sparkles/issues/122) | Render-side 1/2 — `sparkles:syntax` as a Shiki replacement (SSG HTML, playground, VitePress)                               | [twoslash.md](./twoslash.md) `RS1*`               |
| [#123](https://github.com/PetarKirov/sparkles/issues/123) | Render-side 2/2 — twoslash × `sparkles:syntax` via `apps/hue` (HTML + ANSI)                                                | [twoslash.md](./twoslash.md) `TWM*`/`TWO*`/`TWH*` |

## Related specs

hue's visuals are built on the canvas-first UI toolkit, which has its own
requirement tree:

| Spec                                  | Owns                                                                                                                        |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| [`sparkles:ui`](../ui/index.md)       | the toolkit — state machines (`STM`), layout (`LAY`), widgets (`WGT`/`VMD`), backends (`TGT`), theme (`THM`), input (`INP`) |
| [ui/layout.md](../ui/layout.md)       | the layout-model decision record                                                                                            |
| [ui/migration.md](../ui/migration.md) | the sequencing of hue's port onto the toolkit                                                                               |

hue-side requirements referencing those areas live in
[ui-architecture.md](./ui-architecture.md).

## Documentation map

| Page                                                            | What it covers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                                        | what `hue` is · the rendering modes · the status/ID/traceability scheme · module coverage                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| [Feature requirements](./feature-requirements.md)               | app-wide requirements common to **all** rendering modes: invocation & CLI, source acquisition, concatenation & stdin, line ranges, text normalization & safety, language detection, the highlight engine, themes, color policy, output-mode dispatch, width & wrapping, the ANSI/HTML/previewer sinks, degradation, non-functional                                                                                                                                                                                                                                                                          |
| [Document chrome](./chrome.md) _(design)_                       | the decorations drawn **around** the content — header, grid, rule, snip, the line-number gutter and the git change column — as one composable `--style` set implemented as `sparkles:ui` widgets, so the same set renders in ANSI, HTML, TUI and GUI. Replaces the three private gutters hue paints today                                                                                                                                                                                                                                                                                                   |
| [Pager & streaming](./pager.md) _(design)_                      | hue's place in the shell: when it pages (and why its own TUI is the pager rather than a spawned `less`), rendering **pre-formatted** input so `$MANPAGER` / `git core.pager` work, and following input that has not finished arriving (`tail -f`, `less +F`)                                                                                                                                                                                                                                                                                                                                                |
| [GUI (`--gui`) requirements](./gui.md)                          | the raylib GPU window: window/font, the wrapped-line render model, the raw & markdown-preview views, navigation, scrollbar, live theme cycling, search/goto, every markdown construct, code blocks, mouse selection & clipboard (incl. ANSI-block selection, table grid selection — sub-cell / row / column / rectangular — and copy modes: ANSI raw/strip, table TSV/markdown), fullscreen, debug hooks                                                                                                                                                                                                    |
| [TUI requirements](./tui.md) _(full viewer shipped: T1–T4)_     | the full-screen **terminal** viewer — the GUI viewer painted in cells: scrolling, a cell scrollbar, SGR mouse, incremental search, wrapping, line numbers, the markdown preview, and drag-selection → OSC 52 copy (all shipped). A GUI→TUI parity map. Extends the shipped `PRV` previewer                                                                                                                                                                                                                                                                                                                  |
| [Android](./android.md) _(shipped v0: AND1–AND10)_              | the GUI sink as a **NativeActivity APK**: raylib `PLATFORM_ANDROID`, the nix-native dual-ABI build (no Gradle), fontconfig-free fonts, soname-dlopen'd grammars, the asset bundle, touch interaction (drag/fling, tap, long-press, pinch, toolbar), lifecycle, on-device goldens, and the honest desktop-parity checklist                                                                                                                                                                                                                                                                                   |
| [Configuration](./config.md) _(design: CFG1–CFG12)_             | a persistent, user-editable JSON configuration for the whole app — appearance, panes, behaviour, and a **rebindable keymap** over `keymap.Command` — layered defaults → user file → project file → environment → CLI, each layer a sparse overlay. The only route to preferences on Android, where no command line exists.                                                                                                                                                                                                                                                                                  |
| [Content folding](./folding.md) _(planned)_                     | expand/collapse of code structures, markdown sections/lists, and **any tree-sitter CST node** — a cross-backend fold-range model + fold-state machine, elided from the wrapped-line render                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [Tree / DAG view](./tree-view.md) _(planned)_                   | an interactive **tree and DAG** component (snacks.nvim-explorer-style): file explorer, tree-sitter inspector, file outline, git graph, dependency graph — a `sparkles:ui` widget across GUI/TUI/HTML                                                                                                                                                                                                                                                                                                                                                                                                        |
| [Tab view](./tab-view.md) _(planned)_                           | a **tab view** component (tab bar + active-tab state machine) — open files as tabs, and VitePress-style code groups — a `sparkles:ui` widget across GUI/TUI/HTML                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [Gallery & multi-document nav](./gallery.md) _(shipped: G0–G3)_ | rendering a **set** of documents: the static **HTML gallery** (index + per-file pages, prev/next header, physical-line gutter, selection domains) and interactive prev/next + index view in the GUI/TUI. Superseded in part by the [file explorer](./tree-view.md), whose HTML flavor the gallery becomes                                                                                                                                                                                                                                                                                                   |
| [Diff & PR view](./diff-view.md) _(planned)_                    | viewing **diffs** (two files, piped unified patch, git revisions) and **pull requests** (via a DbI **forge seam** — GitHub first, then GitLab/Gitea/Forgejo/Codeberg) across all four sinks: a `sparkles:diff` engine library, unified + side-by-side layouts, layered formatting-noise handling (word-level, formatting-only hunks, structural tree-sitter diff, commutative-container equivalence, rendered-preview diff), hunk/file navigation — then a **write surface**: hunk/line staging, inline editing, content-anchored comments with proposed suggestions, and 3-way conflict viewing/resolution |
| [Navigation](./navigation.md) _(planned)_                       | **link following & go-to** — markdown anchors + local-file links, module/import & relative paths, doc-comment (`$(REF …)`/`@see`) references, and LSP go-to-definition; intra- and inter-document, cross-backend                                                                                                                                                                                                                                                                                                                                                                                            |
| [Images & diagrams](./media.md) _(planned)_                     | **media rendering** — raster images (`![](…)`), diagram fences (mermaid, graphviz), and LaTeX math via one media-block mechanism; GUI texture · terminal graphics protocol · HTML `<img>`/`<svg>`                                                                                                                                                                                                                                                                                                                                                                                                           |
| [Twoslash requirements](./twoslash.md) _(planned/branch-only)_  | the `--twoslash` / `--markdown` modes and the raylib twoslash overlay — the **first overlay** of hue's pluggable overlay layer; implemented on `feat/syntax-twoslash`, not yet on this branch                                                                                                                                                                                                                                                                                                                                                                                                               |
| [Overlay requirements](./overlays.md) _(planned)_               | the **pluggable overlay** framework generalized from twoslash, plus the additional overlay kinds: source map, code coverage, tracing, tree-sitter inspector, function code size                                                                                                                                                                                                                                                                                                                                                                                                                             |
| [Lantern](./lantern.md) _(shipped: LT0–LT3)_                    | the **key guide** — a which-key-inspired panel that lights up after a prefix and lists what can follow it — over hue's **one binding table** (`KEY`) and the `<space>` **leader map** (`LMP`). The table is what makes the keymap enumerable, and so is also [`CFG6`](./config.md)'s prerequisite                                                                                                                                                                                                                                                                                                           |
| [Picker](./picker.md) _(design)_                                | the **fuzzy finder** behind `<leader>f` / `<leader>s` / `<leader>g` / `<leader>/` — a query constraint language, frecency-aware composite ranking, budgeted searches over the `sparkles:event-horizon` work-stealing pool, and the sources (files, grep, recent, git, themes, lines, keymaps) — on a new `sparkles:fuzzy` engine                                                                                                                                                                                                                                                                            |
| [Notifier requirements](./notifier.md) _(planned)_              | the cross-backend **interactive popup** component (snacks.nvim-style: collapse to a floating icon, expand back, buttons, expandable items) and the startup-info / file-info popups                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [UI architecture](./ui-architecture.md) _(architecture)_        | how hue consumes the **canvas-first toolkit** [`sparkles:ui`](../ui/index.md) — the port inventory (which visuals are widgets, which are still per-backend) and hue's own consumption requirements. The toolkit's own `STM`/`LAY`/`WGT`/`TGT` requirements now live in [docs/specs/ui](../ui/index.md)                                                                                                                                                                                                                                                                                                      |
| [Transformer pipeline](./pipeline.md) _(architecture)_          | the **pluggable pipeline** (parse → transform → compile, à la unified.js/markdown-it/babel) that unifies hue's processing: highlighting/overlays/folding/navigation/media as transform plugins, the renderers as compilers                                                                                                                                                                                                                                                                                                                                                                                  |
| [Open implementation issues](./open-issues.md)                  | concrete hue gaps deferred from the normative specs: GUI-state ownership, app-owned duplicate painters, and the native pointer-grab blocker                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [Web integration](./web-integration.md) _(planned)_             | the **`@sparkles/hue` npm package** — a Shiki drop-in for JS frameworks (VitePress/Next/Solid Start) via SSG/SSR process shell-out, then a future wasm client-side backend                                                                                                                                                                                                                                                                                                                                                                                                                                  |

## Rendering modes

`hue` dispatches to exactly one mode per invocation ([`MOD1`–`MOD7`](./feature-requirements.md#output-mode-dispatch-mod)):

| Mode          | When                                                                                                   | Entry code                                | Spec                           |
| ------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------- | ------------------------------ |
| **ANSI**      | `stdout` is not a tty, or no key session (piped/redirected)                                            | `app.emitAnsiWholeFile`                   | `ANS*`                         |
| **HTML**      | `--html`                                                                                               | `app.main` (HTML branch)                  | `HTM*`                         |
| **Previewer** | interactive tty with no display (e.g. SSH), or `--no-gui`/`--tui`                                      | `previewer.runLoop`                       | [`tui.md`](./tui.md) · `PRV*`  |
| **GUI**       | default on a GUI-enabled build when a display is detected, or forced with `--gui`                      | `gui.runGui`                              | [`gui.md`](./gui.md)           |
| **Twoslash**  | `--twoslash <nodes.json>` (ANSI / `--html` / `--gui`) · `--markdown <file.md>` — _planned/branch-only_ | `app.runTwoslashMode` / `runMarkdownMode` | [`twoslash.md`](./twoslash.md) |

> [!NOTE]
> For a **markdown** file every sink renders the render-markdown **decorated
> preview** by default (general [`MOD8`](./feature-requirements.md)) — ANSI
> (`ANS3`), HTML (`HTM5`), the terminal previewer ([`MDP-T`](./tui.md)), and the
> GUI ([`MDP`](./gui.md)) — over the shared `MdDoc` model and widget view; `--raw`
> forces highlighted source.

## Status scheme

Every requirement row carries one **Status**:

| Status             | Meaning                                                                                                                                                                                 |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **not started**    | no implementation yet.                                                                                                                                                                  |
| **researched**     | design/notes exist (in code comments or a sibling doc), but no implementation.                                                                                                          |
| **partial**        | implemented with a documented limitation or missing sub-case (the row's notes say what is missing).                                                                                     |
| **full (`<sha>`)** | fully implemented; `<sha>` is the primary commit (the "commit hash evidence"). Where several commits contributed, the earliest feature commit is cited and later refinements are noted. |

> [!NOTE]
> The cited SHAs are **pre-merge branch commits** on `feat/hue-preview-polish`
> and a few earlier merges. Some are `fixup!` targets that fold into their base
> commit on autosquash — the base commit is cited. Hashes will be finalized when
> the branch is squashed/rebased and merged; treat them as evidence-of-work, not
> permanently stable identifiers.

## ID scheme

Requirement IDs are `<AREA><n>` — a short area mnemonic plus a number, unique
within a document (e.g. `ENG3`, `MDP7`, `SEL2`). The general spec uses
`CLI/SRC/CAT/RNG/TXT/LNG/ENG/THM/CLR/MOD/CHR/WID/PGR/BGM/ANS/HTM/PRV/DEG/NFR`; the
chrome spec uses `STY/CHW/CHG` and the pager spec `PAG/PIN/STR`; the GUI spec uses
`WIN/FNT/RND/VIW/WRP/NUM/NAV/SCB/THG/FND/MDP/COD/SEL/FSC/DBG/BOX`; the lantern
spec uses `KEY/LTN/LMP` and the picker spec `PIK/PKQ/PKR/PKS/PKL/PKM`. Each area's
mnemonic is expanded at its section heading.

## Traceability

Every source file under `apps/hue/src/` is covered by at least one requirement.
The **Module coverage** table at the foot of each spec lists each file (and its
key symbols) against the requirement IDs that own it, so coverage is auditable
in both directions: requirement → code (the "Traces to" column of every row) and
code → requirement (the coverage tables). The shared libraries `hue` drives are
traced at the boundary — the requirement names the sparkles library and the
concrete entry point `hue` calls; the library's own internals are specified in
its own docs.

| Source file                        | Primary spec + areas                                                                                                             |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `apps/hue/src/app.d`               | general — `CLI`, `SRC`, `LNG`, `ENG`, `THM`, `CLR`, `MOD`, `ANS`, `HTM`, `DEG`                                                   |
| `apps/hue/src/source_set.d`        | general — `SRC4`–`SRC6`; [gallery](./gallery.md) — `GAL1`, `GAL8`                                                                |
| `apps/hue/src/gallery.d`           | general — `HTM4`, `HTM6`–`HTM8`; [gallery](./gallery.md) — `GAL2`–`GAL4`, `GAL6`, `GAL7`                                         |
| `apps/hue/src/previewer.d`         | general — `PRV`, `NFR`                                                                                                           |
| `apps/hue/src/gui.d`               | GUI — `WIN`, `FNT`, `RND`, `VIW`, `NUM`, `NAV`, `SCB`, `THG`, `FND`, `COD`, `SEL`, `FSC`, `DBG`                                  |
| `apps/hue/src/gui_preview.d`       | GUI — `VIW`, `MDP` (the document model; rendering is the shared widget views)                                                    |
| `apps/hue/src/viewer_model.d`      | GUI/TUI — `RND`, `WRP`, `NUM`, `FND` (the shared document-pipeline Whole; ui/migration `MIG9`)                                   |
| `apps/hue/src/gui_ansi.d`          | GUI — `MDP` (the ` ```ansi ` fence decoder)                                                                                      |
| `apps/hue/src/gui_text.d`          | GUI — `WRP`, `FND`, `NUM` (pure metrics/search)                                                                                  |
| `apps/hue/src/table_select.d`      | GUI — `TBL1`, `TBL2`, `TBL5` (presentation-free smart-drag + serializers)                                                        |
| `apps/hue/src/tui.d`               | [TUI](./tui.md) — `TIN`, `TSF`, `TSB`, `TSL`, `MDP-T`; general — `PRV` (the shipped viewer)                                      |
| `apps/hue/src/ansi_model.d`        | GUI — `MDP12`; general — `NFR3` (ghostty-free presentation types shared by both painters)                                        |
| `apps/hue/src/gui_canvas.d`        | [ui/backends](../ui/backends.md) — `TGT6` (the raylib canvas adapter)                                                            |
| `apps/hue/src/tui_canvas.d`        | [ui/backends](../ui/backends.md) — `TGT6` (the cell-grid canvas adapter)                                                         |
| `apps/hue/src/twoslash_tui.d`      | [twoslash](./twoslash.md) — `TWM`/`TWO`/`TWH`; [gallery](./gallery.md) — `GNV1`, `GNV2`                                          |
| `apps/hue/src/android_glue.d`      | [Android](./android.md) — `AND2`, `AND4`, `AND9` (the NDK surface: logcat sink, asset extraction, debug env, clipboard entry)    |
| `apps/hue/src/android_clipboard.d` | [Android](./android.md) — `AND6` (the JNI `ClipboardManager` bridge, over an ImportC'd `<jni.h>`)                                |
| `apps/hue/src/android_paths.d`     | [Android](./android.md) — `AND2`, `AND9` (pure, host-tested: the extracted-asset layout, manifest-entry safety, `hue-debug.env`) |
| `apps/hue/src/gui_touch.d`         | [Android](./android.md) — `AND6` (`TouchScroller`: tap / drag+fling / long-press / gesture cancel)                               |
| `apps/hue/src/keymap.d`            | [lantern](./lantern.md) — `KEY` (the one binding table every backend resolves through), `LMP` (the map it holds)                 |
| `apps/hue/src/lantern.d`           | [lantern](./lantern.md) — `LTN1`–`LTN4`, `LTN9`–`LTN12` (the prefix state machine and its wall-clock delay)                      |
| `apps/hue/src/lantern_view.d`      | [lantern](./lantern.md) — `LTN5`–`LTN8`, `LTN14` (the panel as one widget tree, both backends)                                   |
| `apps/hue/tools/capture-modes.d`   | [ui/backends](../ui/backends.md) — `TGT10` (the cross-backend parity harness)                                                    |
