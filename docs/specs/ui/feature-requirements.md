# `sparkles:ui` — Library-wide Feature Requirements

_**Status:** living inventory · **Date:** 2026-08-05 · **Scope:** requirements
common to the whole toolkit — the architecture (`UIA`), the package graph and
its build constraints (`PKG`), and non-functional properties (`NFR`)._

## Architecture (`UIA`)

| ID   | Requirement                                                                                                                                                                                                                                                                                    | Status      | Traces to                                                                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------- |
| UIA1 | The toolkit must be **canvas-first**: the library owns semantic behavior and widget composition, while target adapters provide drawing, native-input translation, device measurement and declared capabilities. No native OS widget may replace a toolkit widget on any target.                | full        | `canvas.d` `isCanvas`; `ui-raylib`; `ui-tui`                                     |
| UIA2 | It must be structured in **three levels** — state machines (`STM`), layout (`LAY`), widgets (`WGT`) — each usable independently, each lower level free of presentation.                                                                                                                        | partial     | `state.d`; `layout.d`; `widget.d`                                                |
| UIA3 | The backend contract must be a **capability concept** (`isCanvas!T`, checked structurally with `__traits(compiles)`), not an interface or class hierarchy — so attributes infer, there is no vtable cost, and a backend need not inherit anything.                                             | full        | `canvas.d` `isCanvas`                                                            |
| UIA4 | The pipeline must be **`view() → layout() → buildDisplayList() → paint(canvas)`**, with every stage before `paint` `@safe` and free of GPU/terminal state, so the whole toolkit is testable through a recording canvas with no window and no tty.                                              | full        | `layout.d`; `display_list.d`; `interp/immediate.d`; `canvas.d` `RecordingCanvas` |
| UIA5 | A widget must name a **semantic slot**, never a concrete color. Appearance is resolved from the [theme](./theme.md) during display-list construction.                                                                                                                                          | full        | `style.d` `Slot`; `display_list.d` `resolveVisual`                               |
| UIA6 | The **same widget definition must render on every target** unchanged; only the canvas and the interpreter differ. Where a target cannot honour a feature, it must degrade through a **declared** capability set, not silently.                                                                 | partial     | [backends.md](./backends.md) `TGT5`                                              |
| UIA7 | The toolkit must be **presentation-complete for a real application** — chrome (headers, status bars, scrollbars, gutters, inputs, toasts), content (rich text, tables, trees, lists), and containers (panels, popups, scroll views) — so a consumer needs no per-backend rendering of its own. | not started | [widgets.md](./widgets.md) `WGT7`+                                               |

## Package graph (`PKG`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                  | Status            | Traces to                                                                         |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------------------------- |
| PKG1 | **Backends adapt to `sparkles:ui`, never the reverse.** `libs/ui` must not depend on any backend package (`raylib-text`, `tui`, a GPU library) nor on `core-cli`.                                                                                                                                                                                                            | full              | `libs/ui/dub.sdl`                                                                 |
| PKG2 | `sparkles:ui` depends only on `sparkles:base`, `sparkles:input`, `sparkles:math` and `expected` (the last two both already `base`'s own). Concrete canvases live in sibling packages — `sparkles:ui-tui`, `sparkles:ui-raylib` — so every consumer picks the backends it wants. Every dependency must be **declared**, not inherited through another package's import paths. | not started       | proposed `libs/ui-tui`, `libs/ui-raylib`                                          |
| PKG3 | Terminal **capability probing** belongs to `sparkles:base` (it is an environment query, not a UI concern); the terminal's **cell-geometry types** belong to `sparkles:tui`. Neither may pull `core-cli` into a UI dependency chain.                                                                                                                                          | full (`31fb39c5`) | `base.term_caps`; `tui.geometry`                                                  |
| PKG4 | `sparkles:core-cli` is scoped to **CLI concerns** — argument parsing, help, prompts, process utilities. Its UI components move into `sparkles:ui`; its help output is expressed as widgets.                                                                                                                                                                                  | partial           | [migration.md](./migration.md) `MIG2` (components moved; help still string-based) |
| PKG5 | Packages that `core-cli` depends on must take the **cycle-safe integration path** — `sparkles:math` on `importPaths` rather than as a `dependency`, and the test-runner shim/impl source-included rather than depended upon. This applies to `ui` and `input` once `core-cli` depends on them.                                                                               | not started       | `libs/ui/dub.sdl`; `libs/input/dub.sdl`                                           |
| PKG6 | `sparkles:ui` is a `library`, not a `sourceLibrary` — its component set is too large to recompile inside every consumer.                                                                                                                                                                                                                                                     | not started       | `libs/ui/dub.sdl`                                                                 |

> [!IMPORTANT]
> `PKG5` is not hypothetical. Dub unions dependencies across configurations, so
> once **`core-cli` depends on `sparkles:ui`** (which `PKG4` requires, for help
> output), a real `sparkles:math` dependency closes
> `core-cli → ui → math → (math's unittest) → test-runner → impl → core-cli`, and
> `ui`'s own `dependency "sparkles:test-runner"` closes
> `ui → test-runner → impl → core-cli → ui`. `sparkles:core-cli` already
> documents and solves the first by making `../math/src` import-only, and
> `base`/`core-cli`/`test-utils` solve the second by source-including the runner.
> `ui` and `input` need both.
>
> Note the pressure does **not** come from the test runner's own use of these
> components: it reaches them by introspection (`__traits(compiles, …)`), never
> by dependency — precisely because `base` and `core-cli` source-include the
> runner when testing themselves. That guard must survive the move
> ([`MIG6`](./migration.md)).

### Target graph

```
base          → expected                        (+ terminal capability probing)
math          → (base, test-runner in unittest)
input         → base, math (import-only)
ui            → base, input, expected, math (import-only)
ui-tui        → ui, tui
ui-raylib     → ui, raylib-text
tui           → base, input, math (import-only)
raylib-text   → base, raylib-d
syntax        → base, ui, tree-sitter
core-cli      → base, ui, expected
```

## Non-functional (`NFR`)

| ID   | Requirement                                                                                                                                                                                                                                                     | Status      | Traces to                                                       |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------- |
| NFR1 | Layout and display-list construction must be `@safe pure nothrow` and run in `O(n)` over the node count.                                                                                                                                                        | partial     | `layout.d`; `display_list.d`                                    |
| NFR2 | The widget arena, display list and per-frame scratch buffers must have a **`@nogc` path** via `SmallBuffer`, so a per-frame rebuild allocates nothing steady-state. The node and operation types are chosen so this swap is non-breaking.                       | not started | `widget.d`; `display_list.d`; [`UI-O4`](./open-issues.md#ui-o4) |
| NFR3 | Every stage before `paint` must be exercisable with **no GPU context and no terminal**, through the recording canvas.                                                                                                                                           | full        | `canvas.d` `RecordingCanvas`                                    |
| NFR4 | A full-screen relayout plus display-list construction must complete in **under 1 ms** for a tree of 2 000 nodes (a full terminal of decorated content), measured by a `@benchmark` test. Incremental relayout is deferred until that budget is actually missed. | researched  | [layout.md](./layout.md) `LAY13`                                |
| NFR5 | The toolkit must carry a **parity harness**: the same widget tree rendered through every backend, with the HTML target usable as a browser ground-truth oracle, and theme values asserted in lockstep against the stylesheet they mirror.                       | partial     | `interp/html.d`; twoslash CSS lockstep tests                    |

> [!IMPORTANT]
> `NFR2` has a **prerequisite outside this package**, and it is the reason the row
> has stayed "not started" rather than being a small mechanical swap. A `DrawOp`
> contains a borrowed text slice, and `SmallBuffer` cannot safely hold an element
> type with references today: its inline slots are `void`-initialized, and its heap
> block is allocated outside the GC's scanned memory, so a buffer that outgrows its
> inline storage can have the text its operations point at collected. This is why
> `RecordingCanvas` uses a GC array and says so in its documentation.
>
> The fix belongs to `sparkles:base` and is specified as
> [P0.2](../ui-app/PLAN.md#phase-0); the ownership question it raises for this
> package is [`UI-O4`](./open-issues.md#ui-o4).

## Module coverage

| Source file                              | Requirements                   |
| ---------------------------------------- | ------------------------------ |
| `libs/ui/dub.sdl`                        | `PKG1`, `PKG2`, `PKG5`, `PKG6` |
| `libs/ui/src/sparkles/ui/package.d`      | `UIA2`, `UIA4`                 |
| `libs/ui/src/sparkles/ui/canvas.d`       | `UIA1`, `UIA3`, `NFR3`         |
| `libs/ui/src/sparkles/ui/layout.d`       | `UIA4`, `NFR1`                 |
| `libs/ui/src/sparkles/ui/display_list.d` | `UIA4`, `UIA5`, `NFR1`, `NFR2` |
| `libs/ui/src/sparkles/ui/widget.d`       | `UIA2`, `NFR2`                 |
| `libs/ui/src/sparkles/ui/interp/html.d`  | `UIA6`, `NFR5`                 |

## Relationship to existing specs

| Piece                                            | Role                                                                                    |
| ------------------------------------------------ | --------------------------------------------------------------------------------------- |
| [principles.md](./principles.md) `PRN`           | the architectural rules these requirements operationalise                               |
| [backends.md](./backends.md) `TGT`               | the concrete targets satisfying `UIA1`/`UIA3`/`UIA6`                                    |
| [migration.md](./migration.md) `MIG`             | how `PKG3`/`PKG4` are executed without breaking consumers                               |
| [hue UI architecture](../hue/ui-architecture.md) | hue's consumption of this toolkit (this spec supersedes its library-level requirements) |
| [AGENTS.md](../../guidelines/AGENTS.md)          | the monorepo's package table and test-runner integration recipes                        |

→ [Overview](./index.md) · [Principles](./principles.md) · [Layout](./layout.md) · [Backends](./backends.md)
