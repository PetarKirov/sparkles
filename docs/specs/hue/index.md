# `hue` — Feature Specification

_**Status:** living inventory · **Date:** 2026-07-23 · **Scope:** `apps/hue`
(`apps/hue/src/*.d`) plus the sparkles libraries it drives (`sparkles:syntax`,
`sparkles:core-cli`, `sparkles:raylib-text`, `sparkles:ghostty`)._

`hue` is an interactive syntax-highlighting file viewer and live theme previewer
over [`sparkles:syntax`](../syntax/index.md). It reads a source file (or its own
source), highlights it with the precise tree-sitter pipeline, and renders it in
one of four **rendering modes**: non-interactive **ANSI**, **HTML**, an
interactive terminal **previewer**, and an optional raylib **GUI** window with a
render-markdown.nvim-style markdown preview.

This spec is a **traceable feature inventory**: every requirement carries an ID,
a status, and a link to the code that implements it, so every part of the
codebase maps to a requirement (see [Traceability](#traceability) below).

## Documentation map

| Page                                                           | What it covers                                                                                                                                                                                                                                           |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                                       | what `hue` is · the rendering modes · the status/ID/traceability scheme · module coverage                                                                                                                                                                |
| [Feature requirements](./feature-requirements.md)              | app-wide requirements common to **all** rendering modes: invocation & CLI, source acquisition, language detection, the highlight engine, themes, color depth, output-mode dispatch, the ANSI/HTML/previewer sinks, degradation, non-functional           |
| [GUI (`--gui`) requirements](./gui.md)                         | the raylib GPU window: window/font, the wrapped-line render model, the raw & markdown-preview views, navigation, scrollbar, live theme cycling, search/goto, every markdown construct, code blocks, mouse selection & clipboard, fullscreen, debug hooks |
| [Twoslash requirements](./twoslash.md) _(planned/branch-only)_ | the `--twoslash` / `--markdown` modes and the raylib twoslash overlay — implemented on `feat/syntax-twoslash`, not yet on this branch                                                                                                                    |

## Rendering modes

`hue` dispatches to exactly one mode per invocation ([`MOD1`–`MOD5`](./feature-requirements.md#output-mode-dispatch-mod)):

| Mode          | When                                                                                                   | Entry code                                | Spec                           |
| ------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------- | ------------------------------ |
| **ANSI**      | `stdout` is not a tty, or no key session (piped/redirected)                                            | `app.emitAnsiWholeFile`                   | `ANS*`                         |
| **HTML**      | `--html`                                                                                               | `app.main` (HTML branch)                  | `HTM*`                         |
| **Previewer** | interactive tty (default)                                                                              | `previewer.runLoop`                       | `PRV*`                         |
| **GUI**       | `--gui` (needs the `gui` build configuration)                                                          | `gui.runGui`                              | [`gui.md`](./gui.md)           |
| **Twoslash**  | `--twoslash <nodes.json>` (ANSI / `--html` / `--gui`) · `--markdown <file.md>` — _planned/branch-only_ | `app.runTwoslashMode` / `runMarkdownMode` | [`twoslash.md`](./twoslash.md) |

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
`CLI/SRC/LNG/ENG/THM/CLR/MOD/ANS/HTM/PRV/DEG/NFR`; the GUI spec uses
`WIN/FNT/RND/VIW/WRP/NUM/NAV/SCB/THG/FND/MDP/COD/SEL/FSC/DBG/BOX`. Each area's
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

| Source file                  | Primary spec + areas                                                                            |
| ---------------------------- | ----------------------------------------------------------------------------------------------- |
| `apps/hue/src/app.d`         | general — `CLI`, `SRC`, `LNG`, `ENG`, `THM`, `CLR`, `MOD`, `ANS`, `HTM`, `DEG`                  |
| `apps/hue/src/previewer.d`   | general — `PRV`, `NFR`                                                                          |
| `apps/hue/src/gui.d`         | GUI — `WIN`, `FNT`, `RND`, `VIW`, `NUM`, `NAV`, `SCB`, `THG`, `FND`, `COD`, `SEL`, `FSC`, `DBG` |
| `apps/hue/src/gui_preview.d` | GUI — `RND`, `VIW`, `WRP`, `NUM`, `MDP`, `COD`                                                  |
| `apps/hue/src/gui_ansi.d`    | GUI — `MDP` (the ` ```ansi ` fence decoder)                                                     |
| `apps/hue/src/gui_text.d`    | GUI — `WRP`, `FND`, `NUM` (pure metrics/search)                                                 |
