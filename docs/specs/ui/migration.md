# `sparkles:ui` migration — Feature Requirements (`MIG`)

_**Status:** planned · **Date:** 2026-07-29 · **Scope:** consolidating the
repository's two parallel UI stacks into `sparkles:ui`, and porting `apps/hue`
onto it — the sequencing, the compatibility rules, and the milestone plan._

## Design & rationale

Two things must happen, and they are independent of each other only in principle:

1. **`sparkles:core-cli` currently contains a second UI stack** — box, table,
   tree, meter, progress, task list, live region, header, layout helpers,
   hyperlinks and a terminal theme. It is mature and widely used, but it is a
   parallel vocabulary: its theme has no relationship to the toolkit's slots, it
   has its own `BorderStyle` enum meaning something different, and it uses a
   grapheme-correct width authority the toolkit does not. It belongs in
   `sparkles:ui`, restructured into view models and views; `core-cli` should be
   about command-line arguments.

2. **`apps/hue` implements ~30 visual components, of which six use the toolkit.**
   The rest are written once per backend. It is the toolkit's first real
   consumer and its port is what proves the design.

The constraint throughout is that the repository stays green: the CI helper, the
release tool and the test runner all render terminal UI today and must keep
working at every commit.

## Consolidation (`MIG1`–`MIG5`)

| ID   | Requirement                                                                                                                                                                                                                | Status      | Traces to                           |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------- |
| MIG1 | Terminal **capability probing** moves to `sparkles:base`, and the terminal's **cell-geometry types** move to `sparkles:tui`, so no UI package depends on `core-cli` for either.                                            | not started | [`PKG3`](./feature-requirements.md) |
| MIG2 | `core-cli`'s UI components move into `sparkles:ui`, **restructured** as presentation-free view models plus widget views rather than transplanted as string producers.                                                      | not started | [widgets.md](./widgets.md) `VMD`    |
| MIG3 | Existing consumers must keep working: the string-producing entry points remain available as **thin adapters** over the widget path, so the CI helper, release tool and test-runner reporting need no simultaneous rewrite. | not started | adapter shims                       |
| MIG4 | `core-cli`'s **help output** must be expressed as widgets, so the last UI concern leaves the package and help rendering gains the same theming and capability gating as everything else.                                   | not started | `core_cli.help_formatting`          |
| MIG5 | The toolkit must adopt the repository's **grapheme-correct width authority** rather than its own codepoint count, resolving the current disagreement between the layout pass and the cell backend.                         | not started | [`LAY5`](./layout.md)               |

## hue port (`MIG6`–`MIG10`)

| ID    | Requirement                                                                                                                                                                                                                       | Status      | Traces to                                        |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------ |
| MIG6  | hue's per-backend rendering must be replaced by **one widget tree per screen**. hue retains only argument parsing, document loading, the syntax pipeline, input handling and its views.                                           | not started | [hue UI architecture](../hue/ui-architecture.md) |
| MIG7  | hue's frame-loop state must become a **single owned view-state value** with the interaction state machines this toolkit provides, replacing peer locals and mutating closures.                                                    | not started | [principles.md](./principles.md) `PRN1`, `PRN7`  |
| MIG8  | hue's document model must become **composable content kinds** rendered by re-entrant views, so nested content (a document embedding a richer block, a popup embedding a document) reuses one code path instead of duplicating it. | not started | [widgets.md](./widgets.md) `WGT2`                |
| MIG9  | Each ported component must **delete** its per-backend predecessors in the same change, so the duplication count strictly decreases and no third copy is created.                                                                  | not started | `MIG6`                                           |
| MIG10 | Behavior differences between backends that exist only because the implementations were separate must be **resolved to one behavior**, not preserved.                                                                              | not started | [principles.md](./principles.md) `PRN8`          |

## Sequencing

Ordered by dependency; each step is independently green.

| Step | Scope                                                                                                              | Requirements                                                                                                          |
| ---- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| 1    | Package graph: capability probing and cell geometry relocate; cycle-safe dub integration; `ui` becomes a `library` | `MIG1`, [`PKG3`](./feature-requirements.md), [`PKG5`](./feature-requirements.md), [`PKG6`](./feature-requirements.md) |
| 2    | Theme unification, with lockstep tests green throughout                                                            | [`THM6`](./theme.md)                                                                                                  |
| 3    | `core-cli` UI components move and are restructured; consumers migrated; help as widgets                            | `MIG2`–`MIG5`                                                                                                         |
| 4    | Layout capabilities the components need                                                                            | [`LAY4`](./layout.md)–[`LAY10`](./layout.md)                                                                          |
| 5    | Input package and hit identity                                                                                     | [`INP`](./input.md)                                                                                                   |
| 6    | Widget model hardening and the component catalog                                                                   | [`WGT`](./widgets.md), [`STM`](./state-machines.md)                                                                   |
| 7    | Backend adapter packages; HTML as a first-class target                                                             | [`TGT4`](./backends.md), [`TGT6`](./backends.md)                                                                      |
| 8    | hue: composition core, then chrome, then content, then tree and folding                                            | `MIG6`–`MIG10`                                                                                                        |

## Compatibility & verification

- **Parity harness first.** Capture per-backend goldens before the layout engine
  changes, and diff after every step; it is the primary safety net.
- **Lockstep tests** guard the theme consolidation — any palette or metric drift
  fails the build rather than silently changing appearance.
- **Runnable documentation examples** cover the moved components and must be
  re-verified, along with their documentation pages.
- **Headless rendering** through the recording canvas keeps every step testable
  without a window or a terminal.
- The **no-GPU build configuration** must keep building at every commit.

## Module coverage

This spec governs moves rather than a module set; per-module ownership after each
move is recorded in the destination spec's coverage table.

## Relationship to existing specs

| Piece                                                      | Role                                                                                 |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| [feature-requirements.md](./feature-requirements.md) `PKG` | the target package graph this migration reaches                                      |
| [hue feature spec](../hue/index.md)                        | the consumer being ported, and its requirement inventory                             |
| [hue UI architecture](../hue/ui-architecture.md)           | hue's own consumption requirements after this spec supersedes its library-level ones |
| [AGENTS.md](../../guidelines/AGENTS.md)                    | package table and test-runner integration recipes to update                          |

→ [Overview](./index.md) · [Feature requirements](./feature-requirements.md) · [Principles](./principles.md)
