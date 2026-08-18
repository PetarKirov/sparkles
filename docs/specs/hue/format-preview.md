# `hue` format preview — Feature Requirements (interactive backends)

_**Status:** v1 shipped (FP0–FP6; the persistent config section is the one design-only remainder) · **Date:** 2026-08-18 · **Scope:** a
toggle-able view mode that reformats the open file **in memory** through a
pluggable formatter (in-process [`sparkles:dmd-fmt`](../dmd-fmt/index.md) for D;
external formatters via an opt-in shell-out seam) and draws a **draggable
vertical column ruler** that sets the formatter's soft maximum line length,
reformatting live as it moves. hue stays read-only: the file on disk is never
touched._

> [!NOTE]
> v1 shipped on `feat/dmd-lsp/dmd-format`: the provider registry + session
> (`format_preview.d`), the in-process dmd-fmt provider (`format_dmd.d`,
> `HueDmdFmt`), the toggle/swap/restore across both backends, the draggable
> ruler (GUI hairline, TUI cell restyle), the `--format-preview` CLI family,
> one-shot sink formatting, and the event-horizon `ForkServer` execution
> backend (SPEC §17/M18) with the worker thread as fallback. Still open:
> the persistent `format` config section (waits on [config](./config.md)'s
> loader, `CFG20`) — until it lands, external formatters have no user-facing
> enablement route (the registry's allowlist parameter is wired and tested) —
> and `mapCursor`-fidelity viewport mapping. Status legend and IDs: see the
> [overview](./index.md).

## Design & rationale

Format preview decomposes the same way [folding](./folding.md) does — a
provider seam, a presentation-independent state machine, shared rendering, and
per-backend adapters that stay thin:

1. **Formatter providers** (`FPR`) — _who can format what_ — a registry keyed
   by document language. Two kinds: **in-process** (`sparkles:dmd-fmt` for D,
   compiled in under the `HueDmdFmt` version) and **external** (an argv
   template run over stdin/stdout). External formatters are a **trust
   boundary**: they run only when declared in user config (the
   [`media.md` `DGM3`](./media.md) opt-in posture).
2. **Preview state** (`FMV`) — _what is shown_ — one backend-neutral session
   per document holding the retained original buffer, the ruler column, the
   in-flight format, and the error state. The buffer swap is the
   diff-emphasis pattern: originals retained once, toggle-off is an instant
   swap, never a recompute.
3. **The ruler** (`RUL`) — _how the width is chosen_ — a vertical guide at the
   soft-max column, draggable with an `ew-resize` pointer shape, whose entire
   interaction machine (hover tolerance, drag state, clamping, coalescing) is
   defined once in cell space ([`ui-architecture` `UIA2`](./ui-architecture.md);
   the [containers spec](../ui/containers.md) splitter discipline: dedicated
   capture id per `STM11`, one composed pointer shape per frame per `DCK9`, a
   keyboard route through the same clamp per `DCK12`).

Two decisions are recorded here so they are not re-argued:

- **The preview is a buffer rewrite, not an overlay** (`FMV9`). Overlays
  ([overlays.md](./overlays.md)) decorate the source; the format preview
  replaces the displayed text and re-derives highlighting/layout through the
  standard pipeline. Only the producer-registry _shape_ is borrowed.
- **Formatting never blocks the UI thread** (`FPR9`). Requests dispatch to an
  execution backend (an event-horizon worker; later the fork server, `FPR10`)
  with **single-flight, latest-wins coalescing** — backpressure adapts to
  measured format latency instead of a hard-coded debounce, so small files
  reformat per pointer event while huge files chain at their natural cadence.
  A diff-vs-original presentation (cheap via `sparkles:diff`,
  [`DVN2`](./diff-view.md)) is recorded as future composition (`FMV10`), not
  built in v1.

## Preview mode (`FMV`)

| ID    | Requirement                                                                                                                                                                                                             | Status                                                  | Traces to                                               |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------- |
| FMV1  | hue must support a **toggle-able format preview** in `view` — off by default, in-memory only; the file on disk is **never written**.                                                                                    | full (`ca124bea5`)                                      | read-only doctrine ([`SRC`](./feature-requirements.md)) |
| FMV2  | The toggle must succeed only when a **language-matching formatter** is available; otherwise it reports why (status/toast) and stays off — never a crash (the totality law).                                             | full (`ca124bea5`)                                      | `FPR1`                                                  |
| FMV3  | Entering the preview must format at the ruler width and **re-highlight through the standard pipeline**; unparseable input still renders (the formatter is total).                                                       | full (`ca124bea5`)                                      | `DocumentPipeline.fromSource`; dmd-fmt `formatText`     |
| FMV4  | Exiting must restore the original buffer **instantly** from retained originals — a swap, never a reformat.                                                                                                              | full (`ca124bea5`)                                      | the diff-emphasis swap pattern                          |
| FMV5  | The viewport (`top`) must be preserved (clamped) across enter/exit/reformat. Cursor-accurate mapping via `mapCursor` over minimal edits is future work.                                                                 | full (`ca124bea5`) — clamped; `mapCursor` fidelity open | dmd-fmt M5 `mapCursor`                                  |
| FMV6  | Folds and search state must **recompute against the displayed buffer** on every swap (compose-at-recompute fidelity with [folding](./folding.md)).                                                                      | full (`ca124bea5`)                                      | [folding.md](./folding.md) `FLD2`                       |
| FMV7  | Both backends must show preview **status**: active formatter, current width, and any error.                                                                                                                             | full (`9f67e1d4c`+`916aa7fce`)                          | status line / chrome bar                                |
| FMV8  | CLI: `--format-preview` (with `--format-width COL`) starts `view` in preview; `--formatter NAME` picks the provider (a miss lists candidates). The one-shot ANSI/HTML sinks render the **formatted** buffer (no ruler). | full (`36b601ae5`)                                      | [`CLI`](./feature-requirements.md)                      |
| FMV9  | The preview is a **buffer rewrite, not an overlay** — it replaces the displayed text; overlay machinery is not involved.                                                                                                | full (`ca124bea5`)                                      | decision above; [overlays.md](./overlays.md)            |
| FMV10 | _Future:_ a **diff-vs-original** presentation of the same preview, reusing the diff document model.                                                                                                                     | not started                                             | [diff-view.md](./diff-view.md) `DVN2`                   |

## Formatter providers (`FPR`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                          | Status                                                                                                                     | Traces to                                         |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| FPR1  | A **formatter registry** must expose: language match, availability probe, and `format(source, path, width) → text-or-error`.                                                                                                                                                                                                         | full (`172df4a74`)                                                                                                         | proposed `format_preview.d`                       |
| FPR2  | The **in-process** provider is `sparkles:dmd-fmt` for D, compiled in under the `HueDmdFmt` version (the `application`/`no-gui`/`unittest` configurations; **never** `android`).                                                                                                                                                      | full (`66856704f`)                                                                                                         | [`sparkles:dmd-fmt`](../dmd-fmt/index.md)         |
| FPR3  | **External** providers run an argv template (`{width}`/`{path}` placeholders) over **stdin → stdout**; nonzero exit or spawn failure yields an error outcome and leaves the buffer unchanged.                                                                                                                                        | full (`172df4a74`)                                                                                                         | `core-cli` `runCaptured`                          |
| FPR4  | External formatters are **opt-in**: they run only when declared in user config (allowlist, off by default) — a trust boundary.                                                                                                                                                                                                       | partial (`172df4a74`) — the registry takes only caller-approved entries; the user-facing enablement route waits on `CFG20` | [media.md](./media.md) `DGM3` posture             |
| FPR5  | Availability is probed **lazily** on first toggle and cached per session (no startup cost).                                                                                                                                                                                                                                          | full (`172df4a74`)                                                                                                         | `isInPath`                                        |
| FPR6  | With multiple candidates the order is **deterministic** (in-process first, then config order); selection persists in config and cycles via a command.                                                                                                                                                                                | partial (`ca124bea5`+`36b601ae5`) — order, cycle and `--formatter` shipped; persistence waits on `CFG20`                   | [config.md](./config.md)                          |
| FPR7  | The ruler width maps to the formatter's **soft maximum line length**; the base config comes from `.editorconfig` discovery (dfmt keys honored), the ruler overriding only that one knob.                                                                                                                                             | full (`66856704f`+`36b601ae5`)                                                                                             | dmd-fmt M7 `configFor`                            |
| FPR8  | Formatter errors must never blank the view: the last good buffer stays, the error goes to status (`FMV7`).                                                                                                                                                                                                                           | full (`ca124bea5`)                                                                                                         | totality                                          |
| FPR9  | Formatting **never runs on the UI thread**: requests dispatch to an event-horizon execution backend with **single-flight, latest-wins coalescing** (no fixed debounce — throughput adapts to measured latency); apply/re-highlight stays on the UI thread; one-shot sinks format synchronously.                                      | full (`172df4a74`)                                                                                                         | `sparkles:event-horizon`                          |
| FPR10 | The in-process backend becomes the event-horizon **fork server** (CoW-forked child per request: initialized-once DMD globals inherited, crash isolation, lock-free parallelism); a single worker thread serialized on the formatter's global lock is the non-Posix/already-threaded fallback.                                        | full (`6de3fff6c`+`3247d25e8`)                                                                                             | `sparkles:event-horizon` `ForkServer`; dmd-fmt D4 |
| FPR11 | Results memoize in a **bounded cache**: width → content digest → shared text+highlights (width→output is a step function, so distinct widths dedupe); LRU over distinct outputs with byte + entry caps; keyed by formatter fingerprint and source identity. Hits apply synchronously; stale completions are inserted before discard. | full (`172df4a74`)                                                                                                         | proposed `FormatCache`                            |

## The column ruler (`RUL`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                | Status                                                                                                 | Traces to                                           |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------- |
| RUL1 | An active preview draws a **vertical ruler** at the width column in both interactive backends — GUI: a `RuleEdge.centerX` hairline; TUI: restyled column cells with `│` in blank cells (a vertical `rule` op is a silent no-op in `GridCanvas`; documented here so it is not "fixed" into a blank column). | full (`9f67e1d4c`+`916aa7fce`)                                                                         | `RaylibCanvas.rule`; the TUI divider paint pattern  |
| RUL2 | The ruler is **mouse-draggable**: hover within tolerance arms it, press captures under a **dedicated capture id** (`STM11`), drag reformats live.                                                                                                                                                          | full (`9f67e1d4c`+`916aa7fce`)                                                                         | [containers.md](../ui/containers.md) `STM8`/`STM11` |
| RUL3 | Hover and drag must show the **`ew-resize` pointer shape**, contributed through the one composed per-frame shape (`DCK9`) — the GUI dock-shape arguments, the TUI OSC 22 path.                                                                                                                             | full (`9f67e1d4c`+`916aa7fce`)                                                                         | `PointerShape.ewResize`                             |
| RUL4 | Drag reformatting is **coalesced latest-wins** through the single-flight backend (`FPR9`): only the newest column formats next, the UI thread never blocks, and the drawn ruler tracks the pointer at frame rate even mid-format.                                                                          | full (`172df4a74`+`9f67e1d4c`)                                                                         | `FPR9`                                              |
| RUL5 | The column is **clamped** to `[1, 300]` — the floor is 1 because the formatter is total at any width, so the gutter is a legitimate target rather than an input to defend against; the keyboard nudge (`<`/`>`) goes through the **same clamp** as the drag (`DCK12`).                                     | full (`ca124bea5`+`9f67e1d4c`)                                                                         | [containers.md](../ui/containers.md) `DCK12`        |
| RUL6 | The TUI must handle **bare pointer-move** (hover without a button) in the document pane — SGR any-motion reporting is already enabled; today those events fall through unread.                                                                                                                             | full (`916aa7fce`)                                                                                     | [tui.md](./tui.md) `TIN`                            |
| RUL7 | Pixel/cell ↔ document-column conversion goes through a **shared geometry helper** (gutter- and horizontal-scroll-aware), not re-inlined arithmetic.                                                                                                                                                        | partial (`9f67e1d4c`) — the helper exists and the ruler uses it; the pre-existing inlined sites remain | proposed `FrameGeom` helpers                        |
| RUL8 | The **entire interaction machine** — hover tolerance, drag state, clamp, coalescing, status text — is defined **once, backend-neutrally, in cell space**; backends contribute only coordinate translation, capture/shape plumbing, and paint (`UIA2`). The GuiState/workspace state split must not widen.  | full (`9f67e1d4c`)                                                                                     | [ui-architecture.md](./ui-architecture.md) `UIA2`   |

## Milestones

| Milestone | Scope                                                                                   | Status                                                       | Requirements                   |
| --------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------ |
| FP0       | Link spike: hue + `sparkles:dmd-fmt` under `HueDmdFmt`; repeated in-process format loop | full (`66856704f`)                                           | `FPR2`                         |
| FP1       | Provider registry + external seam + session + single-flight service + bounded cache     | full (`172df4a74`)                                           | `FPR1`, `FPR3`–`FPR9`, `FPR11` |
| FP2       | Toggle: commands, bindings, buffer swap/restore, status                                 | full (`ca124bea5`)                                           | `FMV1`–`FMV7`                  |
| FP3       | Ruler machine + GUI adapter                                                             | full (`9f67e1d4c`)                                           | `RUL1`–`RUL5`, `RUL7`, `RUL8`  |
| FP4       | TUI adapter                                                                             | full (`916aa7fce`)                                           | `RUL1`, `RUL3`, `RUL6`         |
| FP5       | Config + CLI + formatter selection; one-shot sinks                                      | partial (`36b601ae5`) — flags + one-shot sinks; `CFG20` open | `FMV8`, `FPR4`, `FPR6`         |
| FP6       | Fork-server execution backend (event-horizon `ForkServer`)                              | full (`6de3fff6c`+`3247d25e8`)                               | `FPR10`                        |

## Module coverage (format preview)

| Source                               | Key symbols                                                                 | Requirements           |
| ------------------------------------ | --------------------------------------------------------------------------- | ---------------------- |
| `apps/hue/src/format_preview.d`      | `FormatterRegistry`, `FormatPreviewSession`, `FormatCache`, `RulerGeom`     | `FPR*`, `FMV*`, `RUL8` |
| `apps/hue/src/format_dmd.d`          | the `HueDmdFmt` in-process provider                                         | `FPR2`, `FPR7`         |
| `apps/hue/src/gui.d`                 | GUI adapter: capture id, shape, hairline paint, chrome chip                 | `RUL1`–`RUL4`, `RUL7`  |
| `apps/hue/src/tui.d` / `workspace.d` | TUI adapter: column restyle, bare-move branch, OSC 22 shape, status         | `RUL1`, `RUL3`, `RUL6` |
| `apps/hue/src/keymap.d`              | `toggleFormatPreview`, `formatterNext`, width nudges, `formatPreviewActive` | `FMV1`, `RUL5`         |
| `libs/event-horizon/…/forkserver.d`  | `ForkServer` (zygote + CoW fork per request + shared-memory arena)          | `FPR10`                |

## Relationship to existing specs

| Piece                                              | Role in format preview                                      |
| -------------------------------------------------- | ----------------------------------------------------------- |
| [`sparkles:dmd-fmt`](../dmd-fmt/index.md)          | the D formatter (`formatText`, `configFor`, `mapCursor`)    |
| [folding.md](./folding.md)                         | the structural model this spec mirrors; composes per `FMV6` |
| [ui-architecture.md](./ui-architecture.md) `UIA2`  | one definition per visual/interaction (`RUL8`)              |
| [containers.md](../ui/containers.md) `STM8`/`DCK*` | the splitter-drag discipline the ruler reuses               |
| [config.md](./config.md)                           | the persistent `format` section (`FPR4`, `FPR6`)            |
| [lantern.md](./lantern.md)                         | the keybindings (`<leader>vf`, `<leader>vF`, `<`/`>`)       |
| [diff-view.md](./diff-view.md) `DVN2`              | the future diff presentation (`FMV10`)                      |
| [overlays.md](./overlays.md)                       | what this deliberately is **not** (`FMV9`)                  |

→ [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [Folding](./folding.md) · [Config](./config.md) · [Overview](./index.md)
