# `sparkles:ui-app` — Feature Requirements

_**Status:** proposed — every row is **not started** or **decided** · **Date:**
2026-08-06 · **Scope:** `libs/ui-app` — the application host: backend selection
(`BKD`), the shared window/font CLI (`CLI`), the frame/event loop (`HST`), the
package graph (`APP`) and the testability obligations (`TST`)._

## Architecture (`APP`)

| ID   | Requirement                                                                                                                                                                                                                                            | Status                                                                                                                                                                         | Traces to                                 |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| APP1 | The host must be a **sibling package**, not a layer inside `sparkles:ui`. The toolkit gains no dependency and no knowledge of window systems, terminals or the host itself ([`PKG1`](../ui/feature-requirements.md)).                                  | not started                                                                                                                                                                    | `libs/ui-app/dub.sdl`                     |
| APP2 | An application depending on the host must be able to build **without naming any backend**: no `sparkles:ui-tui`, `sparkles:ui-raylib`, `raylib` or `sparkles.tui` import, and no such `dependency` in its `dub.sdl`.                                   | not started                                                                                                                                                                    | `libs/ui-app/dub.sdl`; consumer manifests |
| APP3 | The host must ship **three configurations** — `tui` (default), `gui`, `full` — where `gui` keeps `sparkles:tui` out of the dependency closure entirely, because an Android build has no terminal and must not link one.                                | not started                                                                                                                                                                    | `libs/ui-app/dub.sdl`                     |
| APP4 | Each backend arm must additionally be **conditionally compiled**: the terminal arm behind `version (Posix)` (its session type exists only there) and the GPU arm behind `version (UiAppGui)`, so every configuration type-checks on every platform.    | not started                                                                                                                                                                    | `tui_loop.d`; `gui_loop.d`                |
| APP5 | Where the host's public API is a **template** (`run`, `Host`), the version-gated arms must be proven to resolve in the **consumer's** compilation, since a version identifier set by a dependency's configuration is what makes the arm visible there. | decided — proven by the `P1.0` spike; a dependency's configuration `versions` do reach the dependent, so `APP3`'s configurations stand ([UIAPP-O2](./open-issues.md#uiapp-o2)) | `run.d`                                   |

> [!IMPORTANT]
> `APP4` is not defensive. `sparkles.ui_tui.session` imports `Terminal` and
> `PosixEvents` unconditionally, and both live behind `version (Posix):` in
> `libs/tui/src/sparkles/tui/terminal.d` and `input.d`. Without the gate, the
> `tui` and `full` configurations fail to type-check on Windows and Android —
> which is exactly the platform hue's APK build targets.

## Backend selection (`BKD`)

| ID   | Requirement                                                                                                                                                                                                                                                                    | Status      | Traces to                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ------------------------------------------ |
| BKD1 | The host owns **one** backend vocabulary: `Backend { gui, tui, html, ansi }`. `html` and `ansi` are members because the toolkit already has an HTML target ([`TGT4`](../ui/backends.md)) and a non-interactive ANSI sink; an application must not re-derive them.              | not started | `backend.d`                                |
| BKD2 | The decision must be a **pure function over an injected policy** — CLI flags, whether the GPU backend was compiled in, stdin/stdout tty-ness, display presence — so the full matrix is testable with no tty, no display and no window.                                         | not started | `backend.d` `BackendPolicy`, `pickBackend` |
| BKD3 | Environment probing (`$DISPLAY` / `$WAYLAND_DISPLAY`, `$SSH_CONNECTION` on macOS/Windows) must be a **separate, callable** function, never folded into the decision — a probe is impure, a decision is not.                                                                    | not started | `backend.d` `displayAvailable`             |
| BKD4 | The **Android fact** belongs here: on Android the surface _is_ the application, so the answer is `gui` unconditionally. It is a statement about the process model, not a display heuristic — `isTerminal` and `displayAvailable` are both false there and would answer `ansi`. | not started | `backend.d`, `version (Android)`           |
| BKD5 | `run` must accept `auto` and fall back in **both** directions: to the terminal when the GPU arm is not compiled in, and to the GPU when the platform has no terminal arm. With neither available it must report a typed failure rather than open nothing.                      | not started | `run.d`                                    |

Behavioral rules `BKD2` preserves verbatim from today's `apps/hue`:

- an explicit `--gui` wins even without GPU support — the sink reports the problem
  itself rather than the picker silently choosing something else;
- `--html` selects `html`; `--no-gui`/`--tui` force the terminal;
- otherwise: GUI when compiled in **and** stdout is a tty **and** a display is
  present; else the interactive TUI when stdin and stdout are both ttys; else `ansi`.

## Window and font CLI (`CLI`)

| ID   | Requirement                                                                                                                                                                                                                         | Status      | Traces to                                              |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------ |
| CLI1 | The window/font flags must be declared **once**: a mixin template supplies the fields, and the standalone options struct is _defined by_ that mixin. Two parallel declarations of the same vocabulary are the defect being removed. | not started | `gui_options.d` `GuiCliFields`, `GuiOptions`           |
| CLI2 | An application must be able to either embed the options struct **or** mix the fields into its own parameter struct, so an app whose flags are flat stays flat.                                                                      | not started | `gui_options.d`                                        |
| CLI3 | There is **one** set of defaults across every application — including the default point size and the default font preference list. A per-application default is not offered.                                                        | decided     | `gui_options.d`; [UIAPP-O1](./open-issues.md#uiapp-o1) |
| CLI4 | Font resolution must be one implementation covering both routes: a fontconfig preference list, or a directory scan when `--font-dir` is given (which also disables fontconfig, so a build's font selection is deterministic).       | not started | `gui_setup.d` `resolveFontPath`                        |
| CLI5 | The **setup order** is part of the contract, not the caller's problem: open the window, load the font set, resolve the point size against the real display, then size the window to the loaded cell metrics.                        | not started | `gui_setup.d` `openGuiSession`                         |
| CLI6 | Deterministic-capture and platform hooks (a pixel-size override that suppresses DPI scaling, extra font sources, a trace-log sink) must be **parameters supplied by the caller**, never environment reads inside the library.       | not started | `gui_setup.d` `GuiRequest`                             |

> [!IMPORTANT]
> `CLI5` is a genuine ordering constraint, not a style preference: cell metrics do
> not exist until the font set loads, the font set cannot load until a GL context
> exists, and the requested window size is expressed in **cells**. Any host that
> reorders these silently produces a window of the wrong size.
>
> `CLI6` matters because the pixel-size override is what makes hue's golden-frame
> screenshot captures reproducible. A capture whose font size quietly follows the
> panel's DPI is a broken oracle, not a cosmetic difference.

## The host contract (`HST`)

| ID   | Requirement                                                                                                                                                                                                                                                    | Status      | Traces to                            |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------ |
| HST1 | The loop is entered through **one** call taking a configuration, a `present` callback and a `handle` callback; both callbacks receive `ref Host`. The application never names a canvas, a window, a terminal or an event source.                               | not started | `run.d`; `host.d`                    |
| HST2 | `Host` must be a **per-backend template instantiation**, not an interface — no vtable in the frame path, and `@safe`/`@nogc`/`nothrow` inferred from the concrete backend, matching the [`isCanvas`](../ui/backends.md) discipline.                            | not started | `host.d`                             |
| HST3 | The host must offer **all three render levels**: a widget tree it lays out and paints, an appendable display-list buffer, and direct access to the concrete canvas for an application with its own renderer.                                                   | not started | `host.d`                             |
| HST4 | The per-frame display-list buffer is **owned and reused by the host**. An application never sizes, allocates or clears one.                                                                                                                                    | not started | `host.d` `ops()`                     |
| HST5 | The application must be able to **end the loop** (`quit()`) and to **request another frame** (`requestFrame()`) — the latter is what an animation or an eased transition needs on a target that otherwise blocks on input.                                     | not started | `host.d`                             |
| HST6 | The application must be able to **decline to draw** a frame (`skipFrame()`), and the host must honour it by presenting nothing: no cell diff on the terminal, and **no buffer swap** on the GPU target.                                                        | not started | `host.d`; `gui_loop.d`; `tui_loop.d` |
| HST7 | Resize must be **normalized**: the event handed to the application always carries the real surface size, on every backend, regardless of what the underlying producer reports.                                                                                 | not started | `run.d`                              |
| HST8 | The platform errands an interactive application actually performs must be on the host: pointer shape, clipboard, window title, out-of-band terminal writes, fullscreen toggle and its capability. An application must not reach past the host for them.        | not started | `host.d`                             |
| HST9 | The loop must have a declared **repaint policy** per backend: the terminal blocks on input unless a frame was requested or an idle interval is configured; the GPU target paces to its frame rate. Background work must be expressible without dropping input. | not started | `run.d`; `tui_loop.d`                |

> [!IMPORTANT]
> `HST6` exists because of a measured behavior in `apps/terminal`: when nothing is
> dirty it polls input and paces the frame **without swapping buffers**, keeping the
> last frame on screen and idle CPU near zero. A host that unconditionally begins and
> ends a frame would erase that, so the ability to decline is part of the contract
> rather than an optimization a backend may or may not honour.
>
> `HST7` exists because the GPU event synthesizer emits a resize event with a
> **zero** size by design (the caller is expected to re-query). That is a reasonable
> producer contract and a trap for every consumer; the host absorbs it once.

## Testability (`TST`)

| ID   | Requirement                                                                                                                                                                                                                                | Status      | Traces to                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | -------------------------- |
| TST1 | The host must ship a **recording target** as a supported third backend: a scripted event list in, and the frames, draw operations and platform calls the application asked for out. It requires no window and no tty.                      | not started | `record.d` `RecordingHost` |
| TST2 | Every element of the host contract must be assertable through that target — quit, requested frames, skipped frames, all three render levels, resize normalization and end-of-input.                                                        | not started | `record.d`                 |
| TST3 | The same scripted session driven through the recording target and through a live backend must produce the **same** draw-operation stream, so target parity is a test rather than a claim ([`TGT10`](../ui/backends.md), at session scope). | not started | `record.d`; `tui_loop.d`   |
| TST4 | Consumers of the host must move application decision logic **out** of modules excluded from their unittest builds. The excluded surface is tracked as a number, per application, and must fall.                                            | not started | [PLAN](./PLAN.md#phase-2)  |

## Non-goals

| Not this package's job                      | Where it belongs                                                      |
| ------------------------------------------- | --------------------------------------------------------------------- |
| Widget composition, layout, theming         | `sparkles:ui`                                                         |
| Drawing primitives, atlases, cell grids     | `sparkles:ui-raylib`, `sparkles:ui-tui`                               |
| The event vocabulary                        | `sparkles:input` ([`INP`](../ui/input.md))                            |
| Argument parsing machinery                  | `sparkles:core-cli` — the host contributes a vocabulary, not a parser |
| Document/content decisions (what to render) | the application                                                       |

## Module coverage

Every planned source file is covered by at least one requirement; see the
[traceability table](./index.md#traceability) on the overview page.
