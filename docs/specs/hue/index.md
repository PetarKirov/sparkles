---
status: accepted
owner: sparkles:hue
reviewed: 2026-08-05
---

# `hue` — Feature Specification

## Abstract

`sparkles:hue` is a syntax-highlighting viewer for source code, markdown,
tabular data and diffs. One program stands in for cat in a pipeline, pages
long output, renders static HTML, and runs as an interactive viewer in a
terminal, a desktop window or an Android app. Each document is described once,
independently of where it is drawn, so every output shows the same content.
Where the terminal and the window can both offer a behavior, they must behave
identically, and a difference is a defect rather than a variation. Every
requirement carries an identifier, a status and a link to the code that
implements it, so the specification maps the application in both directions.

## Introduction

People read code and text in many places: piped through a shell, paged in a
terminal, published on a web page, opened in a window, held on a phone. Each
place usually brings its own tool. One prints with colors, another pages,
another previews markdown, and yet another reviews a diff. Each tool draws the
same file its own way, with its own keys, themes and search.

Sharing a highlighter does not close that gap. Tools that use one highlighting
engine still differ in everything around it: how lines wrap, how search
matches, how selection and scrolling behave, and how a markdown table or a CSV
file is laid out. A viewer written separately for each output drifts on every
axis the outputs do not share, such as whether search ignores case. A
specification organized by output cannot even state that two of them must
agree.

hue separates what a document is from where it is drawn. Loading a file, a
directory, a URL or standard input yields a document of one
[content kind](../../glossary.md#content-kind): highlighted source, a markdown
document, a table of delimiter-separated values, a diff, or a code sample
annotated with type information. Content kinds compose, so a markdown file may
embed a code block that carries its own annotations. Each content kind
produces a single tree of widgets in the [`sparkles:ui`](../ui/index.md)
toolkit. A backend of that toolkit paints the tree as ANSI text, HTML, a
terminal cell grid, or a GPU window, so the contract is that hue owns no
rendering code of its own. Viewer requirements are therefore grouped by the
[interaction tier](../../glossary.md#interaction-tier) they need: static
output, a live event loop, or positions finer than a terminal cell. Where a
backend cannot reach a tier, the requirement states how it degrades, and any
other difference is a defect.

This tree specifies hue the application: its command line, how it acquires and
classifies input, the behavior of each content kind, its keymap and
configuration, its interactive views, and its packaging for Android. The
libraries hue drives own their internals in their own specifications,
including [`sparkles:syntax`](../syntax/index.md),
[`sparkles:ui`](../ui/index.md), [`sparkles:fuzzy`](../fuzzy/SPEC.md),
`sparkles:diff` and `sparkles:dsv`. A hue requirement stops at the library
entry point hue calls. hue is a viewer and does not edit the documents it
shows, apart from the review operations that the diff and pull-request view
specifies: staging hunks, inline edits, review comments and conflict
resolution. Compatibility with cat-like tools is scoped by use, not by parity:
options that carry common use cases are specified, and the rest are deferred
explicitly.

The documentation map that follows gives one entry per page. App-wide
requirements shared by every output live in the feature requirements; viewer
behavior, scoped by interaction tier, lives in the viewer page; and what only
one backend can structurally offer, such as fonts, touch or terminal mouse
protocols, lives in the GUI, TUI and Android pages. Each remaining page
specifies one feature or component. This page also defines the status scheme,
the requirement ID scheme and the traceability rule that every page follows,
and maps each source file to the requirements that own it. How far each area
has been delivered is tracked in [PLAN.md](./PLAN.md).

## Documentation map

| Page                                              | What it covers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | what `hue` is · the rendering modes · the status/ID/traceability scheme · module coverage                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [Delivery status](./PLAN.md)                      | how far each area of this specification has been delivered: the milestone summary the pages' own status lines detail                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| [Feature requirements](./feature-requirements.md) | app-wide requirements common to **all** rendering modes: invocation & CLI, source acquisition, concatenation & stdin, line ranges, text normalization & safety, language detection, the highlight engine, themes, color policy, output-mode dispatch, width & wrapping, the ANSI/HTML/previewer sinks, degradation, non-functional                                                                                                                                                                                                                                                                        |
| [Viewer](./viewer.md)                             | every viewer requirement that is **not** specific to one backend, scoped by the interaction tier it needs (`passive`, `interactive`, `precise`), together with the recorded GUI/TUI divergences and how each is resolved                                                                                                                                                                                                                                                                                                                                                                                  |
| [Document chrome](./chrome.md)                    | the decorations drawn **around** the content — header, grid, rule, snip, the line-number gutter and the git change column — as one composable `--style` set implemented as `sparkles:ui` widgets, so the same set renders in ANSI, HTML, TUI and GUI                                                                                                                                                                                                                                                                                                                                                      |
| [Pager & streaming](./pager.md)                   | hue's place in the shell: when it pages (and why its own TUI is the pager rather than a spawned `less`), rendering **pre-formatted** input so `$MANPAGER` / `git core.pager` work, and following input that has not finished arriving (`tail -f`, `less +F`)                                                                                                                                                                                                                                                                                                                                              |
| [GUI (`--gui`) requirements](./gui.md)            | the raylib GPU window: window/font, the wrapped-line render model, the raw & markdown-preview views, navigation, scrollbar, live theme cycling, search/goto, every markdown construct, code blocks, mouse selection & clipboard (incl. ANSI-block selection, table grid selection — sub-cell / row / column / rectangular — and copy modes: ANSI raw/strip, table TSV/markdown), fullscreen, debug hooks                                                                                                                                                                                                  |
| [TUI requirements](./tui.md)                      | the full-screen **terminal** viewer — the GUI viewer painted in cells: scrolling, a cell scrollbar, SGR mouse, incremental search, wrapping, line numbers, the markdown preview, and drag-selection → OSC 52 copy. A GUI→TUI parity map. Extends the `PRV` previewer                                                                                                                                                                                                                                                                                                                                      |
| [Android](./android.md)                           | the GUI sink as a **NativeActivity APK**: raylib `PLATFORM_ANDROID`, the nix-native dual-ABI build (no Gradle), fontconfig-free fonts, soname-dlopen'd grammars, the asset bundle, touch interaction (drag/fling, tap, long-press, pinch, toolbar), lifecycle, on-device goldens, and the honest desktop-parity checklist                                                                                                                                                                                                                                                                                 |
| [F-Droid release](./fdroid.md)                    | how the Android port **reaches** a phone: the release artifact, its identity and version mapping, how it is signed outside nix, and the self-hosted F-Droid repository it is served from                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [Configuration](./config.md)                      | a persistent, user-editable JSON configuration for the whole app — appearance, panes, behaviour, and a **rebindable keymap** over `keymap.Command` — layered defaults → user file → project file → environment → CLI, each layer a sparse overlay. The only route to preferences on Android, where no command line exists.                                                                                                                                                                                                                                                                                |
| [Content folding](./folding.md)                   | expand/collapse of code structures, markdown sections/lists, and **any tree-sitter CST node** — a cross-backend fold-range model + fold-state machine, elided from the wrapped-line render                                                                                                                                                                                                                                                                                                                                                                                                                |
| [Format preview](./format-preview.md)             | a toggle-able **format preview**: in-memory reformatting through pluggable formatters (in-process `sparkles:dmd-fmt` for D, opt-in external shell-outs) driven by a **draggable column ruler** that sets the soft max line length and reformats live — read-only, backend-neutral interaction machine, coalesced off-thread formatting                                                                                                                                                                                                                                                                    |
| [Tree / DAG view](./tree-view.md)                 | an interactive **tree and DAG** component (snacks.nvim-explorer-style): file explorer, tree-sitter inspector, file outline, git graph, dependency graph — a `sparkles:ui` widget across GUI/TUI/HTML                                                                                                                                                                                                                                                                                                                                                                                                      |
| [Tab view](./tab-view.md)                         | a **tab view** component (tab bar + active-tab state machine) — open files as tabs, and VitePress-style code groups — a `sparkles:ui` widget across GUI/TUI/HTML                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| [Gallery & multi-document nav](./gallery.md)      | rendering a **set** of documents: the static **HTML gallery** (index + per-file pages, prev/next header, physical-line gutter, selection domains) and interactive prev/next + index view in the GUI/TUI. The gallery is the HTML flavor of the [file explorer](./tree-view.md)                                                                                                                                                                                                                                                                                                                            |
| [Diff & PR view](./diff-view.md)                  | viewing **diffs** (two files, piped unified patch, git revisions) and **pull requests** (via a DbI **forge seam** — GitHub first, then GitLab/Gitea/Forgejo/Codeberg) across all four sinks: a `sparkles:diff` engine library, unified + side-by-side layouts, layered formatting-noise handling (word-level, formatting-only hunks, structural tree-sitter diff, commutative-container equivalence, rendered-preview diff), hunk/file navigation, and a **write surface**: hunk/line staging, inline editing, content-anchored comments with proposed suggestions, and 3-way conflict viewing/resolution |
| [DSV preview](./dsv-preview.md)                   | **Delimiter-Separated Values** (CSV/TSV/PSV) as a content kind: the dialect sniffer (delimiter · quote · header, incl. stdin/`.txt` content detection), the `sparkles:dsv` engine (RFC 4180 identity-channel parser, typed columns, projection compute), the grid preview in every sink, the **data-browser** tier (multi-key sort, filter bar + header menus, column hide/reorder), the copy deltas (`source` dialect re-emit, pristine byte reproduction), and a 100 MB / 1M-row scale target                                                                                                           |
| [Navigation](./navigation.md)                     | **link following & go-to** — markdown anchors + local-file links, module/import & relative paths, doc-comment (`$(REF …)`/`@see`) references, and LSP go-to-definition; intra- and inter-document, cross-backend                                                                                                                                                                                                                                                                                                                                                                                          |
| [Images & diagrams](./media.md)                   | **media rendering** — raster images (`![](…)`), diagram fences (mermaid, graphviz), and LaTeX math via one media-block mechanism; GUI texture · terminal graphics protocol · HTML `<img>`/`<svg>`                                                                                                                                                                                                                                                                                                                                                                                                         |
| [Twoslash requirements](./twoslash.md)            | the `--twoslash` / `--markdown` modes and the raylib twoslash overlay — the **first overlay** of hue's pluggable overlay layer                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| [Overlay requirements](./overlays.md)             | the **pluggable overlay** framework generalized from twoslash, plus the additional overlay kinds: source map, code coverage, tracing, tree-sitter inspector, function code size                                                                                                                                                                                                                                                                                                                                                                                                                           |
| [Lantern](./lantern.md)                           | the **key guide** — a which-key-inspired panel that lights up after a prefix and lists what can follow it — over hue's **one binding table** (`KEY`) and the `<space>` **leader map** (`LMP`). The table is what makes the keymap enumerable, and so is also [`CFG6`](./config.md)'s prerequisite                                                                                                                                                                                                                                                                                                         |
| [Picker](./picker.md)                             | the **fuzzy finder** behind `<leader>f` / `<leader>s` / `<leader>g` / `<leader>/` — a query constraint language, frecency-aware composite ranking, budgeted searches over the `sparkles:event-horizon` work-stealing pool, and the sources (files, grep, recent, git, themes, lines, keymaps) — on the `sparkles:fuzzy` engine                                                                                                                                                                                                                                                                            |
| [Notifier requirements](./notifier.md)            | the cross-backend **interactive popup** component (snacks.nvim-style: collapse to a floating icon, expand back, buttons, expandable items) and the startup-info / file-info popups                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [UI architecture](./ui-architecture.md)           | how hue consumes the **canvas-first toolkit** [`sparkles:ui`](../ui/index.md) — the port inventory (which visuals are widgets, which are still per-backend) and hue's own consumption requirements. The toolkit's own `STM`/`LAY`/`WGT`/`TGT` requirements live in [docs/specs/ui](../ui/index.md)                                                                                                                                                                                                                                                                                                        |
| [Transformer pipeline](./pipeline.md)             | the **pluggable pipeline** (parse → transform → compile, à la unified.js/markdown-it/babel) that unifies hue's processing: highlighting/overlays/folding/navigation/media as transform plugins, the renderers as compilers                                                                                                                                                                                                                                                                                                                                                                                |
| [Open implementation issues](./open-issues.md)    | concrete hue gaps deferred from the normative specs: GUI-state ownership, app-owned duplicate painters, and the native pointer-grab blocker                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| [Web integration](./web-integration.md)           | the **`@sparkles/hue` npm package** — a Shiki drop-in for JS frameworks (VitePress/Next/Solid Start) via SSG/SSR process shell-out, and a wasm client-side backend                                                                                                                                                                                                                                                                                                                                                                                                                                        |

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

## CLI & Subcommands

`hue` provides a clean subcommand hierarchy built on `sparkles:core-cli` with `@Flatten` composition:

| Subcommand         | Description                                                      | Key Options                                                                     |
| ------------------ | ---------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `view` _(default)_ | View and syntax-highlight a file, directory, or twoslash overlay | `[paths]`, `--markdown`, `--raw`, `--patch`, `@Flatten("Output Sinks")`         |
| `diff`             | Diff two files or git revisions with structural awareness        | `[targets]`, `--staged`, `@Flatten("Diff Options")`, `@Flatten("Output Sinks")` |
| `pr`               | Open a GitHub/GitLab pull request as a diff session              | `<pr>`, `@Flatten("Diff Options")`, `@Flatten("Output Sinks")`                  |
| `gallery`          | Batch render a directory into a static HTML syntax/theme gallery | `[dir]`, `--out`, `--twoslash`, `--markdown`, `--raw`, `--recursive`            |
| `theme`            | Inspect and list built-in color themes                           | `--list`, `[name]`                                                              |
| `overlay`          | Inspect registered document overlays (twoslash, coverage, trace) | `--list`, `[kind]`                                                              |
| `config`           | Display resolved configuration, fonts, and theme settings        | `--show`                                                                        |

**Universal options** (`--log-level`, `--theme`, `--background`) live on the root command alongside flattened GUI and overlay options.

## Rendering modes & Sinks

Rendering subcommands (`view`, `diff`, `pr`) resolve to exactly one active backend sink per invocation ([`MOD1`–`MOD7`](./feature-requirements.md#output-mode-dispatch-mod)):

| Mode     | Flag                                   | When                                                           | Entry code        | Spec                          |
| -------- | -------------------------------------- | -------------------------------------------------------------- | ----------------- | ----------------------------- |
| **ANSI** | `--backend=ansi`                       | `stdout` is not a tty or piped/redirected                      | `app.runAnsiSink` | `ANS*`                        |
| **HTML** | `--html` / `--backend=html`            | `--html` passed or html backend requested                      | `app.runHtmlSink` | `HTM*`                        |
| **TUI**  | `--tui` / `--no-gui` / `--backend=tui` | Interactive tty with no display or explicit terminal request   | `app.runTuiSink`  | [`tui.md`](./tui.md) · `PRV*` |
| **GUI**  | `--gui` / `--backend=gui`              | Display available on GUI-enabled build, or forced with `--gui` | `app.runGuiSink`  | [`gui.md`](./gui.md)          |

> [!NOTE]
> For a **markdown** file every sink renders the render-markdown **decorated
> preview** by default (general [`MOD8`](./feature-requirements.md)) — ANSI
> (`ANS3`), HTML (`HTM5`), the terminal previewer ([`MDP-T`](./tui.md)), and the
> GUI ([`MDP`](./gui.md)) — over the shared `MdDoc` model and widget view; `--raw`
> forces highlighted source. A **DSV** file (CSV/TSV/…) likewise renders the
> **grid preview** by default in every sink ([dsv-preview.md](./dsv-preview.md)
> `DSK3`, general `MOD10`).

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
spec uses `KEY/LTN/LMP`, the picker spec `PIK/PKQ/PKR/PKS/PKL/PKM`, and the DSV
spec `DSK/DSD/DSM/DSG/DSB/DSS/DSF/DSC/DSN/DSZ`. Each area's mnemonic is
expanded at its section heading.

## Traceability

Every source file under `apps/hue/src/` is covered by at least one requirement.
The **Module coverage** table at the foot of each spec lists each file (and its
key symbols) against the requirement IDs that own it, so coverage is auditable
in both directions: requirement → code (the "Traces to" column of every row) and
code → requirement (the coverage tables). The shared libraries `hue` drives are
traced at the boundary — the requirement names the sparkles library and the
concrete entry point `hue` calls; the library's own internals are specified in
its own docs.

| Source file                      | Primary spec + areas                                                                                                                                                       |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/hue/src/app.d`             | general — `CLI`, `SRC`, `LNG`, `ENG`, `THM`, `CLR`, `MOD`, `ANS`, `HTM`, `DEG`                                                                                             |
| `libs/docs` (`sparkles:docs`)    | general — `SRC4`–`SRC6`, `HTM4`, `HTM6`–`HTM8`; [gallery](./gallery.md) — `GAL1`–`GAL4`, `GAL6`–`GAL8`, `GAL12`, `GAL14` (the doc-site library the gallery extracted into) |
| `apps/hue/src/previewer.d`       | general — `PRV`, `NFR`                                                                                                                                                     |
| `apps/hue/src/gui.d`             | GUI — `WIN`, `FNT`, `RND`, `VIW`, `NUM`, `NAV`, `SCB`, `THG`, `FND`, `COD`, `SEL`, `FSC`, `DBG`                                                                            |
| `apps/hue/src/gui_preview.d`     | GUI — `VIW`, `MDP` (the document model; rendering is the shared widget views)                                                                                              |
| `apps/hue/src/viewer_model.d`    | GUI/TUI — `RND`, `WRP`, `NUM`, `FND` (the shared document-pipeline Whole; ui/migration `MIG9`)                                                                             |
| `apps/hue/src/gui_ansi.d`        | GUI — `MDP` (the ` ```ansi ` fence decoder)                                                                                                                                |
| `apps/hue/src/gui_text.d`        | GUI — `WRP`, `FND`, `NUM` (pure metrics/search)                                                                                                                            |
| `apps/hue/src/table_select.d`    | GUI — `TBL1`, `TBL2`, `TBL5` (presentation-free smart-drag + serializers)                                                                                                  |
| `apps/hue/src/tui.d`             | [TUI](./tui.md) — `TIN`, `TSF`, `TSB`, `TSL`, `MDP-T`; general — `PRV` (the shipped viewer)                                                                                |
| `apps/hue/src/ansi_model.d`      | GUI — `MDP12`; general — `NFR3` (ghostty-free presentation types shared by both painters)                                                                                  |
| `apps/hue/src/gui_canvas.d`      | [ui/backends](../ui/backends.md) — `TGT6` (the raylib canvas adapter)                                                                                                      |
| `apps/hue/src/tui_canvas.d`      | [ui/backends](../ui/backends.md) — `TGT6` (the cell-grid canvas adapter)                                                                                                   |
| `apps/hue/src/twoslash_tui.d`    | [twoslash](./twoslash.md) — `TWM`/`TWO`/`TWH`; [gallery](./gallery.md) — `GNV1`, `GNV2`                                                                                    |
| `apps/hue/src/android_glue.d`    | [Android](./android.md) — `AND2`, `AND4`, `AND6`, `AND9` (hue's layout and policies over `sparkles:android`: logcat tag, owned asset dirs, debug env, clipboard entry)     |
| `apps/hue/src/android_paths.d`   | [Android](./android.md) — `AND2`, `AND9` (pure, host-tested: the extracted-asset layout, manifest-entry safety, `hue-debug.env`)                                           |
| `apps/hue/src/gui_touch.d`       | [Android](./android.md) — `AND6` (`TouchScroller`: tap / drag+fling / long-press / gesture cancel)                                                                         |
| `apps/hue/src/keymap.d`          | [lantern](./lantern.md) — `KEY` (the one binding table every backend resolves through), `LMP` (the map it holds)                                                           |
| `apps/hue/src/lantern.d`         | [lantern](./lantern.md) — `LTN1`–`LTN4`, `LTN9`–`LTN12` (the prefix state machine and its wall-clock delay)                                                                |
| `apps/hue/src/lantern_view.d`    | [lantern](./lantern.md) — `LTN5`–`LTN8`, `LTN14` (the panel as one widget tree, both backends)                                                                             |
| `apps/hue/tools/capture-modes.d` | [ui/backends](../ui/backends.md) — `TGT10` (the cross-backend parity harness)                                                                                              |
| `apps/hue/tools/tui-ab.d`        | [gui](./gui.md) — `DBG*` (the TUI A/B oracle: a terminal frame IS its bytes)                                                                                               |
| `apps/hue/tools/gui-ab.d`        | [gui](./gui.md) — `DBG1` (the window A/B oracle: two builds' captures compared, each side captured twice so a race cannot read as a difference)                            |
