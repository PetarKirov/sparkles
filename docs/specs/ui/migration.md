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

## Consolidation (`MIG1`–`MIG7`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                               | Status                   | Traces to                                 |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | ----------------------------------------- |
| MIG1 | Terminal **capability probing** moves to `sparkles:base`, and the terminal's **cell-geometry types** move to `sparkles:tui`, so no UI package depends on `core-cli` for either.                                                                                                                                                                                           | full (`31fb39c5`)        | `base.term_caps`; `tui.geometry`          |
| MIG2 | `core-cli`'s UI components move into `sparkles:ui` and are **restructured** as presentation-free view models plus widget views — in three separate steps, not one (see the phase note below).                                                                                                                                                                             | partial (2a; 2b started) | [widgets.md](./widgets.md) `VMD`          |
| MIG3 | Existing consumers must keep working at every step. The **adapter direction flips mid-migration**: string emitters stay canonical while they are the only implementation, and become thin adapters over the widget path only once that path exists.                                                                                                                       | not started              | adapter shims                             |
| MIG4 | `core-cli`'s **help output** must be expressed as widgets, so the last UI concern leaves the package and help rendering gains the same theming and capability gating as everything else.                                                                                                                                                                                  | not started              | `core_cli.help_formatting`                |
| MIG5 | The toolkit must adopt the repository's **grapheme-correct width authority** rather than its own codepoint count, resolving the current disagreement between the layout pass and the cell backend.                                                                                                                                                                        | not started              | [`LAY5`](./layout.md)                     |
| MIG6 | The test runner's use of the moved components must stay **introspection-guarded**. `base`/`core-cli`/`test-utils` source-include the runner rather than depending on it, and in those builds the toolkit is absent — so it detects the components with `__traits(compiles, …)` and degrades. The move retargets those guards; it must not make the imports unconditional. | full (`M3a`)             | `test_runner.reporting` `hasUiComponents` |
| MIG7 | `sparkles:core-cli` is a **published package**, so the move is a breaking change for external consumers. Compatibility shims under the old module names are **not possible** (see below); the break is instead documented in the changelog and the module mapping published.                                                                                              | full (`M3a`)             | `docs/specs/ui/migration.md`; changelog   |

### Why `sparkles.core_cli.ui.*` cannot be a compatibility shim

The obvious kindness — leave `sparkles.core_cli.ui.box` behind as a
`public import sparkles.ui.components.box` — **does not compile**, and the reason
is worth recording because it is not obvious.

Keeping that shim means `sparkles:core-cli` hosts a package named
`sparkles.core_cli.ui` _while its own modules import `sparkles.ui._`* (prompts
needs the theme and the live region). From inside package `sparkles.core_cli`,
the name `sparkles.ui.components.theme`then resolves through the nearer`sparkles.core_cli.ui`, and the compiler reports the symbols as missing:

```
prompts.d: Error: module `sparkles.ui.components.theme` import `Semantic` not found
```

It reproduces with a plain selective import and with `static import` alike, and
it disappears the moment the shim package is removed. The collision is between
the _package names_, so no import style avoids it: a package cannot both shadow
`sparkles.ui` and depend on it.

Since `core-cli` must import the toolkit (`PKG4` keeps prompts and help there),
the shims lose. External consumers get a documented break and a module mapping —
`sparkles.core_cli.ui.X` → `sparkles.ui.components.X` — which is a mechanical
find-and-replace.

### The three phases of `MIG2`, and why they cannot be one

The tempting shape — "move the components and make the old string functions thin
adapters over the new widget path" — is **inverted**, because at the moment of
the move there is no widget path to adapt to.

The existing emitters are ANSI-transparent string producers: they accept
pre-styled text, measure it with the grapheme-correct visible width, preserve
colors and hyperlinks across wrapped rows, and reset style before a frame. To
express that as widgets requires styled runs within a node
([`WGT6`](./widgets.md)), a link concept ([`WGT21`](./widgets.md)), the track
sizer ([`LAY9`](./layout.md)) and width-aware measurement with wrapping
([`LAY4`](./layout.md)/[`LAY5`](./layout.md)) — **all of which land later**.

So `MIG2` is three steps, each independently green:

| Phase | Scope                                                                                                                                                                                | Canonical implementation |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------ |
| 2a    | **Mechanical move** — modules relocate, imports rewrite, imports rewrite. Output must be **byte-identical**; goldens unchanged.                                                      | the string emitters      |
| 2b    | **View-model extraction** — the presentation-free half (grid model, column widths, tree flattening, meter fill) is separated out and tested with no renderer. Emitters call into it. | the string emitters      |
| 2c    | **Widget views** — added on top once the layout and widget capabilities exist; the emitters become adapters that render a widget tree through the cell backend.                      | the widget tree          |

Phase 2a must not attempt any restructuring: a move that also changes behavior
has no reliable oracle, because the goldens are the oracle.

## hue port (`MIG8`–`MIG12`)

| ID    | Requirement                                                                                                                                                                                                                       | Status      | Traces to                                        |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------ |
| MIG8  | hue's per-backend rendering must be replaced by **one widget tree per screen**. hue retains only argument parsing, document loading, the syntax pipeline, input handling and its views.                                           | not started | [hue UI architecture](../hue/ui-architecture.md) |
| MIG9  | hue's frame-loop state must become a **single owned view-state value** with the interaction state machines this toolkit provides, replacing peer locals and mutating closures.                                                    | not started | [principles.md](./principles.md) `PRN1`, `PRN7`  |
| MIG10 | hue's document model must become **composable content kinds** rendered by re-entrant views, so nested content (a document embedding a richer block, a popup embedding a document) reuses one code path instead of duplicating it. | not started | [widgets.md](./widgets.md) `WGT2`                |
| MIG11 | Each ported component must **delete** its per-backend predecessors in the same change, so the duplication count strictly decreases and no third copy is created.                                                                  | not started | `MIG8`                                           |
| MIG12 | Behavior differences between backends that exist only because the implementations were separate must be **resolved to one behavior**, not preserved.                                                                              | not started | [principles.md](./principles.md) `PRN8`          |

## Sequencing

Ordered by dependency; each step is independently green.

| Step | Scope                                                                                                         | Requirements                                                             |
| ---- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| 0    | **Capture per-backend goldens** — the oracle every later step is checked against                              | [`TGT10`](./backends.md)                                                 |
| 1    | Package graph: capability probing and cell geometry relocate                                                  | `MIG1`, [`PKG3`](./feature-requirements.md)                              |
| 2    | Cycle-safe dub integration; `ui` becomes a `library`                                                          | [`PKG5`](./feature-requirements.md), [`PKG6`](./feature-requirements.md) |
| 3    | Theme unification — syntax, slot and metric channels; the glyph channel is **declared** here and filled in 4a | [`THM6`](./theme.md)                                                     |
| 4a   | `core-cli` UI components **move mechanically**; byte-identical output; deprecation shims                      | `MIG2`, `MIG3`, `MIG6`, `MIG7`                                           |
| 4b   | View-model extraction from the moved components                                                               | `MIG2`, [`VMD`](./widgets.md)                                            |
| 5    | Layout capabilities the components need                                                                       | [`LAY4`](./layout.md)–[`LAY10`](./layout.md)                             |
| 6    | Input package and hit identity                                                                                | [`INP`](./input.md)                                                      |
| 7    | Widget model hardening and the component catalog                                                              | [`WGT`](./widgets.md), [`STM`](./state-machines.md)                      |
| 4c   | Widget views for the moved components; the string emitters become adapters                                    | `MIG2`, `MIG3`, `MIG4`                                                   |
| 8    | Backend adapter packages; HTML as a first-class target                                                        | [`TGT4`](./backends.md), [`TGT6`](./backends.md)                         |
| 9    | hue: composition core, then chrome, then content, then tree and folding                                       | `MIG8`–`MIG12`                                                           |

> [!IMPORTANT]
> Step **4c is deliberately out of numeric order.** The widget views for the moved
> components cannot be written until steps 5–7 supply the layout and widget
> capabilities they need. Steps 4a and 4b land early because they are mechanical
> and unblock everything else; 4c waits. This is `MIG3`'s adapter-direction flip
> made concrete.
>
> Step **0 precedes the theme work**, not just the layout work: theme unification
> and the component move can both shift rendered output, so the goldens must
> predate both.

## Compatibility & verification

- **Parity harness first.** Capture per-backend goldens at step 0 — before the
  theme work, not just before the layout work — and diff after every step; it is
  the primary safety net.
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
