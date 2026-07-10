# Spec: `core-cli` TUI component suite

**Status:** living inventory · **Date:** 2026-07-10 · **Scope:** `sparkles:core-cli`
UI layer (`libs/core-cli/src/sparkles/core_cli/`) plus its `sparkles:base` seams
(`term_style`, `text/*`, and the new terminal-control module below).

The single source of truth for the TUI component inventory: what exists, what is
missing, per-item status, and the designs already agreed. Co-development of
`core-cli` through its in-repo consumers (`release`, `ci`, the test runner) is an
explicit goal, so every item names its first consumer. Execution order lives in
[the delivery plan](./PLAN.md); the span-capable table has its own accepted spec in
[`table.md`](../table.md) (landed). The evidence base is the
[TUI library survey](../../../research/tui-libraries/index.md) — in particular the
[table-span](../../../research/tui-libraries/table-span-case-study.md) and
[tree-view](../../../research/tui-libraries/tree-view-case-study.md) case studies,
and the per-library terminal-control findings summarized in §4 below.

## Decision ledger

| Area              | Decision                                                                                                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Terminal size     | `ScreenSize!ushort terminalSize()` replaces `terminalWidth()`; `ScreenSize` comes from `sparkles:math` (new `core-cli → math` dependency; `math`'s library config is runtime-dep-free)  |
| Capability module | Rename `term_size.d` → `term_caps.d`: the central "what can this terminal do" module (size, tty, color policy, console prep); hoist `prepareConsole` from `test-runner-impl`            |
| Control sequences | New `sparkles.base.term_control` (sibling of `term_style`, which deliberately omits non-SGR control); libvaxis-style hardcoded sequences, **no terminfo**; `AnsiControl` moves there    |
| Live rendering    | Log-update pattern (cursor-up N + erase-line), frames wrapped in DEC 2026 synchronized-output markers; a "static" channel graduates finished lines into scrollback; non-TTY policy enum |
| Renderer policy   | Components stay pure producers into output ranges; the color/TTY _decision_ is made once at the edge (the existing `bool colored` parameter convention is preserved, not replaced)      |
| Table             | See [`table.md`](../table.md) — accepted and landed; remaining follow-ups tracked in §2.B below                                                                                         |

## 1. Component baseline

What exists today (and is _not_ in question below):

| Module                                                                   | Provides                                                                                                                                                                                |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ui/box.d`                                                               | `drawBox`: title/footer, min/max width, title-overflow modes (expand/wrap/ellipsis), style-safe wrapping, lazy line/chunk streaming                                                     |
| `ui/table.d`                                                             | Span-capable `drawTable` (dense `Cell[][]`, sparse `Placement[]`, `string[][]` sugar), per-column `Align`/`VAlign`, header rules, glyph presets, width caps + wrapping, `validateTable` |
| `ui/header.d`                                                            | `drawHeader`: divider/banner styles, width-capped column-aware wrapping                                                                                                                 |
| `ui/osc_link.d`                                                          | OSC 8 hyperlinks (plain/styled), `visibleWidth`-transparent                                                                                                                             |
| `ui/progress.d`                                                          | `spinnerFrame`, `@nogc` `ProgressLine` (spinner + `done/total` + elapsed); `AnsiControl` (to be moved, see §4)                                                                          |
| `term_size.d`                                                            | `terminalWidth()` (sync, POSIX + Windows, `0 = unknown`), `setTermWindowSizeHandler` (SIGWINCH push)                                                                                    |
| `term_unstyle.d`, `process_utils.d`                                      | ANSI stripping; process execution + monitoring (`runCaptured` is capture-at-exit only — see D5)                                                                                         |
| `base`: `text/width.d`                                                   | Kitty-TSP cell widths, `Align` + `alignField` (ANSI-transparent pad/align, output-range + string forms)                                                                                 |
| `base`: `text/wrap.d`, `ansi.d`                                          | Style-preserving wrap engine with chunk streaming; ANSI tokenization + `SgrState` re-emission (parsing only, no emission)                                                               |
| `base`: `term_style.d`, `styled_template.d`, `prettyprint.d`, `logger.d` | SGR styling, styled IES, colorized pretty-printing, logging                                                                                                                             |

This substrate (grapheme-correct widths, style-safe wrapping, SGR state tracking) is
stronger than what most surveyed TUI libraries sit on; the gaps are in the component
layer, not the text engine.

## 2. Inventory

Status legend: **landed** · **partial** (exists, incomplete or in the wrong layer) ·
**open** · **deferred**.

### A. Foundations

| #   | Item                          | Status  | Notes                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --- | ----------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | Terminal capability detection | partial | The policy exists as private `prepareConsole` in `test-runner-impl/runner_impl.d` (`--no-colours` → `$NO_COLOR` → `isatty`; Windows UTF-8 code page + VT enable). Hoist into `term_caps.d` as `detectTermCaps` (§3). `terminalWidth() != 0` already covers tty-ness for the wrapping use case                                                                                                                                     |
| A2  | Terminal size                 | partial | `terminalWidth()` landed (sync, cross-platform). Remaining: `terminalSize()` returning `ScreenSize!ushort` (height is fetched and discarded on both platforms today); unify the SIGWINCH `Handler` on `ScreenSize`; store-only signal handler + poll model (A2b). Windows resize _events_: deferred                                                                                                                               |
| A3  | Control-sequence emission     | open    | Design agreed — §4. `AnsiControl` (4 members, zero importers outside `progress.d`) moves to `sparkles.base.term_control` and grows cursor movement, erase variants, DEC modes                                                                                                                                                                                                                                                     |
| A4  | Theme / glyph presets         | partial | `TableGlyphs` + `stylePresets` (rounded/square/ascii/double/heavy) landed _inside_ `table.d`; hoist a shared border-charset mechanism so `BoxProps`/`drawHeader` select the same presets, keyed off `term_caps` unicode detection. Still open: semantic styles (success/warning/error/accent/muted), status-glyph vocabulary (`✔ ✖ ⚠ ○ ⠸ ┄` + ASCII fallbacks), unifying the `colored`/`useColors`/`noColours` parameter spelling |
| A5  | Text field utilities          | partial | `alignField` + `Align` landed in `base.text.width` (pads, never cuts — by design). Remaining: the symmetric `truncateField` (visible-cell truncation ending in `…`, styles reset before the ellipsis); `box.d`'s private `ellipsizeTitle` then becomes a thin wrapper. Optional: `writeFill(w, ch, n)` to deduplicate the `repeat(…).to!string` fill runs in box/header/table                                                     |

### B. Existing-component feature gaps

**`drawTable`** — overhauled per [`table.md`](../table.md); implements the case
study's principles 1–8 (slot grid, dense + sparse authoring, defined overlap errors,
pure coverage/junction resolution, colspan width distribution, rowspan + `VAlign`).
Remaining follow-ups, by value:

1. **Consumer wiring** (highest payoff, trivial): `release` stats tables adopt
   `columnAligns` (right-align counts), `headerRows: 1`, and
   `maxWidth: terminalSize().width`; same for `ci` and bench tables.
2. Title/footer parity with `drawBox` (today a banner header must be stacked above a
   frameless table).
3. Lazy/streaming rendering (parity with `drawBoxLines`/`drawBoxChunks`).
4. Output-range/writer overload (case-study principle 9; internals may still
   allocate — full `@nogc` is a v3 concern, not worth a redesign now).
5. Small: per-_cell_ align/valign override (only per-column exists), `Align.decimal`
   for numeric columns, `validateTable` overload surfacing _all_ errors (the list is
   computed and dropped today), S4 content-equality auto-merge (only with a real
   consumer).
6. Structural: at ~1.5 k lines with a private layout engine, a split into
   `table/grid.d` (pure resolution) + `table/render.d` is warranted once title/footer
   or streaming land.

**`drawBox` / `drawHeader`** — minor: padding control and content alignment inside
boxes; border charset via the hoisted A4 presets (border _color_ is a theme concern —
`BoxProps` holds bare `dchar`s); `drawHeader` banner width defaulting to
`terminalSize().width`.

**`oscLink`** — complete; only unification with `base/source_uri.d` (a second OSC 8
implementation) is worth considering.

### C. Interactive prompts — all open

The release tool hand-rolls `ask`/`promptBump`/`promptAgent` with inconsistent
behavior (one re-prompts on invalid input, one silently swallows it). Extract:

| #   | Component | Shape                                                                                                                                                  |
| --- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| C1  | `select`  | Numbered options with descriptions, rendered default, re-prompt loop; line-based by default, with an optional raw-mode arrow-key cursor mode (§F note) |
| C2  | `confirm` | `[y/N]` with default; styled destructive-action variant (push/publish gates)                                                                           |
| C3  | `input`   | Free text with a validation/parse callback loop                                                                                                        |
| C4  | Policy    | Every prompt takes a resolution mode — `interactive` / `takeDefault` / `fail` — so `--auto` and non-TTY stdin are handled uniformly, not per call site |

First consumer: `release` (bump select with candidate versions, publish confirm).

### D. Live / progress components

| #   | Component            | Status  | Notes                                                                                                                                                                                              |
| --- | -------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Live region          | open    | The core primitive; blueprint in §5. Depends on A3, `terminalSize()`, `truncateField`                                                                                                              |
| D2  | Spinner              | partial | `spinnerFrame` + `ProgressLine` landed as pure producers; the redraw framing (currently ad-hoc CR + erase-line in the test runner) moves into D1                                                   |
| D3  | Task list            | open    | Rows with pending/running/ok/failed/skipped states, groups, per-row detail; the `release` pre-flight/stages checklist and `ci`'s per-example runs. Needs progress callbacks through `runPreflight` |
| D4  | Progress bar         | open    | Determinate counterpart of D2; shares the E1 meter primitive                                                                                                                                       |
| D5  | Subprocess tail pane | open    | Bounded last-N-lines view under a task row (the nix/bazel pattern); needs a _streaming_ variant of `runCaptured` in `process_utils`                                                                |

### E. Data display

| #   | Component              | Status   | Notes                                                                                                                                                                                                                          |
| --- | ---------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| E1  | Meter / bar            | open     | `meter(value, max, width)` with `█▏…` eighth-cell precision; release type/area breakdowns                                                                                                                                      |
| E2  | Tree view              | open     | Research done ([tree-view case study](../../../research/tui-libraries/tree-view-case-study.md)): flat `Node[]`, pure `flatten()`. Consumers: release area breakdown (today faked with indented table rows), `ci` file listings |
| E3  | Key-value list         | partial  | Mostly absorbed by the table overhaul (`border: false, columnSeparators: false` + right-aligned label column); at most a thin convenience wrapper remains                                                                      |
| E4  | Horizontal composition | open     | Join rendered blocks side by side (line-zipping over `visibleWidth`-padded blocks); dashboard layouts                                                                                                                          |
| E5  | Sparkline              | deferred | No confirmed consumer                                                                                                                                                                                                          |

### F. Long-term / out of scope

- **`gridBox` layout container** (S5 placement of arbitrary blocks): deliberately
  share the slot-grid + junction machinery from `table.d` rather than grow a second
  model. Deferred until a consumer appears.
- **Full-screen TUI loop** (alt screen, general `Event`/`Backend` framework, an
  app-owned event loop): still out of scope — no consumer; `apps/terminal` is an
  emulator, not a client. `sparkles.core_cli.key_input` (added for C1) is a
  narrow, deliberate exception to the _raw-mode input decoding_ half of this
  line, not a reversal of it: a closed `Key { up, down, enter, cancel, other }`
  vocabulary consumed only by `select`'s cursor mode, not a general `KeyEvent`
  type or input framework — see `docs/research/tui-libraries/comparison.md`'s
  Phase 4 roadmap for what a real event system would look like.
- **Explicitly not building:** terminfo (the survey's no-terminfo, query-first
  consensus — see §4); terminal _queries_ (DA1/CPR/kitty probes need raw-mode
  response reading; `term_caps` stays env + ioctl until an interactive component
  forces it); kitty keyboard/graphics; a cell-grid diff compositor (the in-scope
  consumers need log-update, not a framebuffer).

## 3. Design: `term_caps.d` (A1 + A2)

Rename `term_size.d` → `term_caps.d`; one home for size, tty-ness, color policy,
and console preparation (they all interrogate the same stdout handle under the same
`version (Posix)` / `version (Windows)` plumbing).

```d
module sparkles.core_cli.term_caps;

import sparkles.math : ScreenSize;

/// Current terminal size in cells; a zero component means "unknown on that axis"
/// (not a tty, redirected, or the OS query failed). Replaces `terminalWidth()`.
ScreenSize!ushort terminalSize() @safe nothrow @nogc;

/// Resize notification (POSIX SIGWINCH). Target design: the signal handler only
/// stores the new size atomically; consumers poll `terminalSize()` per tick.
alias Handler = void delegate(ScreenSize!ushort size) nothrow @nogc;
void setTermWindowSizeHandler(Handler handler);

/// Is this stream attached to a terminal? (isatty / GetConsoleMode)
bool isTerminal(StdStream stream = StdStream.stdout) @safe nothrow @nogc;

/// One-shot capability snapshot — the single place the color/glyph decision is
/// made; renderers keep taking explicit bools/options.
struct TermCaps
{
    bool tty;                 /// stdout is a terminal
    bool colors;              /// tty && !$NO_COLOR && !TERM=dumb (|| CLICOLOR_FORCE)
    bool unicode;             /// LANG/LC_* UTF-8 heuristic (Windows: CP set to UTF-8)
    ScreenSize!ushort size;
}

/// Detect caps and prepare the console. Hoisted from the test runner's private
/// `prepareConsole`: on Windows sets the UTF-8 code page and enables virtual-
/// terminal processing; colors stay off when VT can't be enabled.
TermCaps detectTermCaps(bool noColors = false);
```

Migration: `test-runner-impl/reporting.d` (`terminalWidth` → `terminalSize().width`),
`runner_impl.d` (`prepareConsole` → thin call into `detectTermCaps`), `apps/ci`
(private duplicate `terminalWidth` deleted), the `term-size` example, and the
AGENTS.md repo-layout line. Pre-1.0 with all consumers in-repo: no deprecation shims.

## 4. Design: `sparkles.base.term_control` (A3)

Grounded in the survey (best references: **libvaxis** — hardcoded `ctlseqs`, no
terminfo, exact DEC mode table; **Ratatui's `Backend` trait** — the minimal-complete
operation list; **Mosaic** — inline rendering + sync-output framing + non-TTY policy;
**Ink/Bubble Tea** — the log-update repaint pattern). `base` is the home because
`term_style` (SGR emission) lives there and `progress.d`'s doc already declares the
split; `AnsiControl` currently has zero importers, so the move is free.

```d
module sparkles.base.term_control;

/// Fixed sequences (hardcoded, no terminfo — the libvaxis model).
enum CtlSeq : string
{
    carriageReturn  = "\r",
    eraseLine       = "\x1b[2K",     // EL 2
    eraseToEnd      = "\x1b[0K",     // EL 0
    eraseDisplay    = "\x1b[2J",     // ED 2
    eraseBelow      = "\x1b[0J",     // ED 0 — stale-line cleanup on shrink
    cursorHome      = "\x1b[H",
    hideCursor      = "\x1b[?25l",
    showCursor      = "\x1b[?25h",
    enterAltScreen  = "\x1b[?1049h",
    exitAltScreen   = "\x1b[?1049l",
    syncBegin       = "\x1b[?2026h", // DEC 2026: wrap every repaint frame
    syncEnd         = "\x1b[?2026l",
}

/// Parameterized sequences: writer functions per the `writers.d` idiom
/// (`@nogc`, output-range), not GC string builders.
void writeCursorUp(Writer)(ref Writer w, uint n);             // CSI n A
void writeCursorDown(Writer)(ref Writer w, uint n);           // CSI n B
void writeCursorColumn(Writer)(ref Writer w, uint col);       // CSI col G
void writeCursorTo(Writer)(ref Writer w, uint row, uint col); // CUP

/// Named DEC private modes (libvaxis's table): one set/reset pair covers future
/// needs (bracketed paste, in-band resize, …) without new API.
enum DecMode : ushort
{
    altScreen = 1049, bracketedPaste = 2004, syncOutput = 2026,
    unicodeCore = 2027, colorScheme = 2031, inBandResize = 2048,
}
void writeModeSet(Writer)(ref Writer w, DecMode m);   // CSI ? m h
void writeModeReset(Writer)(ref Writer w, DecMode m); // CSI ? m l
```

Out of scope for A3 (each a separate later decision): terminal queries (require
reading responses), scroll regions (DECSTBM — only Ratatui exposes them; no consumer),
kitty protocols, cell-grid diff rendering.

## 5. Design: live region (D1)

The survey converges on one blueprint for a live region _inside_ normal scrollback
(no alt screen), assembled from Mosaic + Ink + Ratatui:

- **Repaint:** `syncBegin` → cursor-up(previous height) → per line: render (clamped
  to `terminalSize().width` via `truncateField` — wrapped lines break the cursor
  arithmetic), `eraseToEnd` → `eraseBelow` when the new frame is shorter → `syncEnd`.
  Track the previous render height in _terminal rows_.
- **Static channel:** lines that graduate into scrollback (Ink's `<Static>`,
  Ratatui's `insert_before`, Mosaic's `StaticEffect`) — a completed task becomes a
  permanent `✔` line above the live section. This is exactly the release
  pre-flight/stages checklist shape.
- **Non-TTY policy** (Mosaic's `NonInteractivePolicy`): append-only snapshots when
  piped; gated by `TermCaps.tty`.
- **Restore guard:** `scope(exit)`/RAII emitting `showCursor` + `syncEnd` (+
  `exitAltScreen` if ever used), so a crash never leaves the cursor hidden
  (libvaxis's panic handler).
- **Resize:** re-read `terminalSize()` per repaint tick; `ScreenSize` equality gives
  a free "changed since last tick" check.

Spinner (D2), task list (D3), progress bar (D4), and the subprocess tail (D5) are
clients of this primitive and stay pure producers themselves.

## 6. Consumers / traceability

| Consumer          | Items exercised                                                                                                                                                            |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `release`         | C1–C4 (bump select, publish confirm), D1–D3 (pre-flight/stages checklist), B.1 (stats table alignment/header/width), E1–E2 (type/area breakdowns), receipt box + `oscLink` |
| `ci`              | D1/D3/D4 (per-example verification progress), B.1, A1 (piped-output degradation)                                                                                           |
| test runner       | Already consumes `ProgressLine`, `drawTable`, `terminalWidth`, and hosts the `prepareConsole` logic A1 hoists                                                              |
| `docs`/`examples` | Every component lands with a runnable example (`ci --verify`)                                                                                                              |
