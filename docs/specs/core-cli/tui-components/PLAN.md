# TUI components — delivery plan

_Audience: contributors implementing the suite. Execution-only — milestones,
dependencies, verification, deferrals. For the inventory, per-item status, and design
rationale read the [spec](./index.md); item numbers (A1…E5) refer to its §2._

> [!NOTE]
> **Status: M0–M4 substantially landed** (feat/release-tool, 2026-07-10); the
> unchecked boxes below are the remaining follow-ups. Each milestone landed
> together with its first in-repo consumer so the API was pressure-tested
> immediately — nothing was built ahead of a real client.

## 1. Milestone overview

| #      | Deliverable                                                                                                                                                                                      | Items          | Depends on | Status                     |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------- | ---------- | -------------------------- |
| **M0** | Foundations finish: `term_caps.d`, `terminalSize()`, `truncateField`, theme/glyph hoist                                                                                                          | A1, A2, A4, A5 | —          | done (A4 naming pass open) |
| **M1** | Terminal control + live rendering: `term_control`, live region, task list; adopt in `release` pre-flight/stages and `ci`                                                                         | A3, D1–D3, D5  | M0         | done (`ci` adoption open)  |
| **M2** | Interactive prompts + `release` adoption (bump select, publish confirm, receipt)                                                                                                                 | C1–C4          | M0 (A1)    | done                       |
| **M3** | Table follow-ups: consumer wiring, title/footer, streaming, validate-all overload                                                                                                                | B (table)      | M0 (A2)    | done except streaming      |
| **M4** | Data display: meter/bar, tree view, horizontal composition                                                                                                                                       | E1, E2, E4, D4 | M0         | done                       |
| **M5** | Consumer adoption + table streaming: ci live builds/--test checklist, tail pane, decimal + bench wiring, table split + lines/writer/chunks, per-cell align, kvList, runner progress, naming pass | remainder      | M0–M4      | done                       |

## 2. Per-milestone detail

### M0 — Foundations finish

- [x] `Align` + `alignField` in `base.text.width`
- [x] A2: `ScreenSize!ushort terminalSize()` (width **and** height, POSIX + Windows);
      SIGWINCH `Handler` unified on `ScreenSize`; `test-runner-impl/reporting.d`
      migrated; `apps/ci`'s private duplicate deleted; `terminalWidth()` dropped.
      `sparkles:math` is wired via **importPaths**, not a dub dependency — a real
      dependency edge closes a cycle through math's unittest configuration
      (math → test-runner → test-runner-impl → core-cli); `Vector`/`ScreenSize`
      are all-template so import-only suffices (the test-runner shim idiom)
- [x] A1: `term_size.d` → `term_caps.d`; `isTerminal(StdStream)`, `TermCaps`,
      `detectTermCaps` (hoisted `prepareConsole`, generalized with `TERM=dumb` +
      `CLICOLOR_FORCE`); the runner delegates through its `__traits(compiles)` gate
- [x] A5: `truncateField` in `base.text.width` (grapheme-accurate, style-reset
      before the ellipsis); `box.d`'s `ellipsizeTitle` rewired onto it
- [x] A4: `ui/theme.d` — `BorderStyle` selector shared by box/header/table (reusing
      the table preset registry), `StatusGlyphs` with ASCII fallbacks, `Semantic`
      roles, `makeTheme(TermCaps)`
- [x] A4 residue (M5): unify the `colored`/`useColors`/`noColours` parameter spelling
      across `base`/`test-runner-impl`

### M1 — Terminal control + live rendering

- [x] A3: `sparkles.base.term_control` — `CtlSeq` (absorbing `AnsiControl`), erase
      variants, `writeCursor*`, `DecMode` set/reset (spec §4)
- [x] D1: `ui/live.d` `LiveRegion` (spec §5: DEC-2026-framed repaint, height
      tracking, `printAbove` static channel, non-TTY append mode, destructor-backed
      restore, width re-read per repaint; injected sink → byte-exact tests)
- [x] D3: `ui/tasklist.d` — pure `renderTaskLine`/`renderTaskList` + `TaskReporter`
      driver (graduating transitions, multi-line failure details, spinner ticks)
- [x] D5 prerequisite: `runStreaming` in `process_utils` (merged-pipe line sink,
      never throws); the bounded tail _pane_ remains future work
- [x] Consumer: `release` pre-flight + stages are live checklists; ci output lines
      pulse the spinner via `PreflightProgress.output`; skipped stages shown
- [x] D2 residue, reality-checked in M5 (nothing to retire — the runner had no live progress at all; it gained one instead): retire the test runner's ad-hoc CR + erase-line framing in favour
      of `LiveRegion`
- [x] Consumer (M5): `ci` per-example verification adopts the task list / progress bar

### M2 — Interactive prompts

- [x] C1 `select`, C2 `confirm`, C3 `textInput` — line-based, re-prompt loops,
      `Expected` returns (EOF is an error, never an accidental default)
- [x] C4 `PromptPolicy` (`interactive`/`takeDefault`/`fail`) on every prompt;
      injectable `PromptIo` seam drives the unit tests
- [x] Consumers: `release` bump select with concrete candidate versions + the
      tally that produced the suggestion; confirm gate describing the outward
      stages before push/publish; closing receipt box with `oscLink` to the
      GitHub release and the next command as footer

### M3 — Table follow-ups

- [x] Title/footer parity with `drawBox`: spliced into the borders via new
      `TableGlyphs.titlePrefix`/`titleSuffix` (preset variants), ellipsis-truncated
      on narrow frames, plain lines when `border: false`
- [x] `validateTableAll` (every error in placement order)
- [x] Consumer wiring: `release` stats adopt `columnAligns`, `headerRows`, titles,
      and `maxWidth: terminalSize().width`
- [x] Bench + `ci` tables likewise (M5) (needs `TableProps` plumbing through
      `renderCells`'s capability gate)
- [x] Lazy/streaming rendering (M5) (parity with `drawBoxLines`/`drawBoxChunks`)
- [x] As needed (M5): per-cell align/valign override, `Align.decimal`, writer overload
- [x] Structural (M5): split `table/grid.d` (pure resolution) from `table/render.d`
      when streaming lands

### M4 — Data display

- [x] E1 `ui/meter.d` — eighth-cell bars, count/max + fraction forms, ASCII
      fallback; D4 `ProgressBar` (meter + right-justified counter) on top
- [x] E2 `ui/tree.d` — `renderTree` over flat pre-ordered `(label, depth)` nodes
      (tree-view case study); first consumer: `release` area breakdown guides
- [x] E4 `ui/layout.d` — `hjoin`, visible-width line-zipping
- [x] Consumer: `release` type breakdown gains a count-proportional bar column
- [x] E3 key-value convenience wrapper (M5: `kvList`) only if the borderless-table form proves
      clumsy

## 3. Deferred / explicitly out of scope

- F1 `gridBox` layout container (share the slot-grid machinery when a consumer appears)
- F2 full-screen TUI loop (alt screen + raw-mode input decoding)
- Terminal queries (DA1/CPR/kitty probes), scroll regions, kitty keyboard/graphics
- terminfo (no-terminfo consensus per the survey), cell-grid diff compositor
- Windows resize _events_ (sync `terminalSize()` covers Windows already)
- E5 sparkline, S4 table auto-merge, DbI table cell content, fully-`@nogc` table
  internals
