# `hue` notifier — Feature Requirements (interactive popups, all backends)

_**Status:** planned (component: researched) · **Date:** 2026-07-23 · **Scope:**
hue's **notifier** — interactive, collapsible floating popups available across
**all interactive backends** (GUI, the TUI previewer, and HTML). Covers the
shared component and the two concrete popups (startup info, file info)._

> [!NOTE]
> Everything here is **forward-looking design** — `not started`, with the
> component contract (`NTF`) marked `researched` (the design is captured; no
> popup code exists yet). Status legend and ID conventions: see the
> [overview](./index.md).

## Design & rationale

The reference is [`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)'s
**`notifier`**: floating, titled panels that stack in a corner, can be dismissed
or collapsed, and carry levels/icons/actions. hue adapts that into a **cross-backend
popup component** — the same content model rendered in each backend's idiom:

- a popup is a **titled floating panel** with a body, an optional **close/collapse**
  control, optional **action buttons**, and optional **actionable/expandable items**;
- closing **collapses it to a small floating icon** (it is not destroyed); activating
  the icon **expands it back** to its prior place;
- the same popup definition drives all three interactive backends — only the
  rendering/interaction primitive differs (raylib mouse, terminal keys, pure CSS).

```
  ┌─ popup (expanded) ──┐      ── close ▶──▶
  │ title     [buttons] │                      ● (floating icon)
  │ body / items ▸      │      ◀── activate ──
  └─────────────────────┘
```

This is a **shared UI primitive**, not a one-off: startup info and file info are
its first two instances, and it composes with (but is distinct from) the
[overlay](./overlays.md) layer — overlays annotate the _source_; the notifier
presents _out-of-band_ panels about the session.

## The notifier component (`NTF`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Status                 | Traces to                                                  |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ---------------------------------------------------------- |
| NTF1 | A **notifier** must present interactive floating popups over the rendered content — a titled panel with a body, modeled on snacks.nvim's `notifier`. It is a shared component; concrete popups (`NSI`, `NFI`) supply content only.                                                                                                                                                                                                                                                             | researched/not-started | proposed shared popup component                            |
| NTF2 | A popup's **close control must collapse it to a small floating icon** (corner-anchored), not destroy it; the icon persists so the popup can be recalled.                                                                                                                                                                                                                                                                                                                                       | not started            | proposed collapse state                                    |
| NTF3 | **Activating the floating icon must re-expand** the popup to its prior position/size (symmetric to `NTF2`).                                                                                                                                                                                                                                                                                                                                                                                    | not started            | proposed expand state                                      |
| NTF4 | A popup body may contain **actionable/expandable items** rendered as actionable (underline, or a `▸`/`>` disclosure marker) that **expand in place** to reveal a detail list, and collapse back (e.g. `languages: 42 ▸` → the full language list).                                                                                                                                                                                                                                             | not started            | proposed disclosure item (drives `NSI2`)                   |
| NTF5 | A popup may include labeled **action buttons**; activating a button runs its action.                                                                                                                                                                                                                                                                                                                                                                                                           | not started            | proposed button element                                    |
| NTF6 | The component must render in **every interactive backend** — the "all backends" contract: **GUI** (raylib floating panel, mouse hit-test, `sparkles:raylib-text` `drawBox` border), **TUI previewer** (box-drawing panel over the viewport, key-driven), **HTML** (a positioned panel whose collapse/expand/disclosure is **pure CSS**, no JS — the `<details>`/`:checked` idiom the twoslash HTML backend already commits to).                                                                | not started            | `gui.d`; `previewer.d`; `app.d` HTML branch (all proposed) |
| NTF7 | Popups must **anchor to a corner and stack** without overlapping (snacks-style, default top-right); multiple popups (startup + file) must coexist.                                                                                                                                                                                                                                                                                                                                             | not started            | proposed stack/layout                                      |
| NTF8 | Each popup must be **toggleable** (a key in GUI/TUI; always-rendered, CSS-toggled in HTML); the startup popup is presented on launch and can be collapsed immediately.                                                                                                                                                                                                                                                                                                                         | not started            | proposed keybindings; HTML static render                   |
| NTF9 | The notifier must **degrade gracefully**: on the non-interactive ANSI path (piped/redirected, [`MOD3`](./feature-requirements.md#output-mode-dispatch-mod)/[`MOD5`](./feature-requirements.md#output-mode-dispatch-mod)) popups are **omitted** (never injected into piped output); in the TUI previewer the popup rendering must respect the previewer's `@nogc nothrow` render/output discipline ([`NFR1`](./feature-requirements.md#non-functional-nfr)) or be explicitly carved out of it. | not started            | `emitAnsiWholeFile` (skip); `previewer.d` (`NFR1`)         |

## Startup info popup (`NSI`)

Presented on launch; collapsible to an icon (`NTF2`).

| ID   | Requirement                                                                                                                                                                                         | Status      | Traces to                                                                                                                                                                         |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NSI1 | Must show hue's **version and short commit hash**, and the active **rendering mode** (`tui` / `gui` / `html`); in GUI mode it must also show the **GPU backend version** (e.g. the raylib version). | not started | proposed build stamp (none today); `RAYLIB_VERSION`; mode dispatch ([`MOD*`](./feature-requirements.md#output-mode-dispatch-mod))                                                 |
| NSI2 | Must show the counts of **available/loaded tree-sitter languages** and **themes**; `languages: N` and `themes: N` are **actionable items** (`NTF4`) that expand to the full lists.                  | not started | `GrammarRegistry` (avail, [`ENG2`](./feature-requirements.md#highlight-engine-eng)) / `TsConfigCache` (loaded); `names`/`themes` ([`THM2`](./feature-requirements.md#themes-thm)) |
| NSI3 | The distinction between **available** (grammars in the `$SPARKLES_TS_GRAMMAR_PATH` bundle) and **loaded** (instantiated on demand) languages must be reflected in the count/list.                   | not started | `GrammarRegistry.fromEnvironment`; `TsConfigCache`                                                                                                                                |

## File info popup (`NFI`)

Toggleable per `NTF8`; its theme field tracks live theme cycling.

| ID   | Requirement                                                                                                                                                                 | Status      | Traces to                                                                                                                                                                                                                            |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| NFI1 | Must show the file **path**, the **detected language**, the **loaded tree-sitter grammar**, and the **current theme**.                                                      | not started | `sourcePath` ([`SRC1`](./feature-requirements.md#source-acquisition-src)); `canonicalLanguage` ([`LNG1`](./feature-requirements.md#language-detection-lng)); `TsConfigCache`; theme name ([`THG1`](./gui.md#live-theme-cycling-thg)) |
| NFI2 | Must show file **stats**: byte count, line count, Unicode **extended grapheme clusters (EGCs)**, and the number of **tree-sitter highlight events**.                        | not started | `source.length` (`SRC1`); `lineCount`; `byGraphemeCluster` (`sparkles.base.text.grapheme`); `events[].length` ([`ENG3`](./feature-requirements.md#highlight-engine-eng))                                                             |
| NFI3 | The **current theme** field must update when the theme is cycled live ([`THG1`](./gui.md#live-theme-cycling-thg)); the byte/line/EGC/event stats are computed once at load. | not started | `applyTheme` (GUI); stats memoized at load                                                                                                                                                                                           |

> [!NOTE]
> The **EGC** count uses UAX #29 grapheme segmentation from
> `sparkles.base.text.grapheme` (`byGraphemeCluster`, `@nogc`) — this is grapheme
> _counting_, and is independent of the deferred grapheme/east-asian **width**
> table ([`DEF7`](./feature-requirements.md) /
> [`gui.md` `FNT6`](./gui.md#font-fnt)); the popup reports a true EGC count even
> while the v1 grid still advances one cell per codepoint.

## Module coverage (notifier)

Proposed layout — no code on any branch yet.

| Source (proposed)                                              | Requirements                              |
| -------------------------------------------------------------- | ----------------------------------------- |
| shared popup component (proposed)                              | `NTF1`–`NTF5`, `NTF7`, `NTF8`             |
| `apps/hue/src/gui.d` (raylib popup layer, proposed)            | `NTF6` (GUI), `NSI*`, `NFI*` (GUI paint)  |
| `apps/hue/src/previewer.d` (TUI popup over viewport, proposed) | `NTF6` (TUI), `NTF9` (`@nogc` discipline) |
| `apps/hue/src/app.d` HTML branch (CSS-only popup, proposed)    | `NTF6` (HTML), `NTF9` (ANSI skip)         |
| build stamp (version + commit, proposed)                       | `NSI1`                                    |
| `sparkles:base` `text/grapheme.d` (`byGraphemeCluster`)        | `NFI2` (EGC count)                        |

→ [Overlay requirements](./overlays.md) · [GUI requirements](./gui.md) · [General requirements](./feature-requirements.md) · [Overview](./index.md)
