# TUI components — delivery plan

_Audience: contributors implementing the suite. Execution-only — milestones,
dependencies, verification, deferrals. For the inventory, per-item status, and design
rationale read the [spec](./index.md); item numbers (A1…E5) refer to its §2._

> [!NOTE]
> **Status: in progress.** Several items landed while this plan was being drawn up
> (the `table.d` overhaul, `alignField`, `terminalWidth`, `ProgressLine`); the
> checklists below reflect the tree as of 2026-07-10. Each milestone lands together
> with its first in-repo consumer so the API is pressure-tested immediately — nothing
> gets built ahead of a real client.

## 1. Milestone overview

| #      | Deliverable                                                                                                              | Items          | Depends on | Status  |
| ------ | ------------------------------------------------------------------------------------------------------------------------ | -------------- | ---------- | ------- |
| **M0** | Foundations finish: `term_caps.d`, `terminalSize()`, `truncateField`, theme/glyph hoist                                  | A1, A2, A4, A5 | —          | partial |
| **M1** | Terminal control + live rendering: `term_control`, live region, task list; adopt in `release` pre-flight/stages and `ci` | A3, D1–D3, D5  | M0         | open    |
| **M2** | Interactive prompts + `release` adoption (bump select, publish confirm, receipt)                                         | C1–C4          | M0 (A1)    | open    |
| **M3** | Table follow-ups: consumer wiring, title/footer, streaming, validate-all overload                                        | B (table)      | M0 (A2)    | open    |
| **M4** | Data display: meter/bar, tree view, horizontal composition                                                               | E1, E2, E4, D4 | M0         | open    |

M1 before M2: the multi-minute silent pre-flight is the worst current UX and D3 is
reusable by `ci` immediately, while prompts only polish already-working interactions.
M3's consumer-wiring bullet is independent enough to cherry-pick early if a `release`
UI pass happens first.

## 2. Per-milestone detail

### M0 — Foundations finish

- [x] `Align` + `alignField` in `base.text.width` (landed)
- [x] `terminalWidth()` sync query, POSIX + Windows (landed; superseded by the next item)
- [ ] A2: `ScreenSize!ushort terminalSize()`; add `core-cli → sparkles:math` dependency;
      migrate `test-runner-impl/reporting.d`, delete `apps/ci`'s private duplicate,
      unify the SIGWINCH `Handler` on `ScreenSize`, drop `terminalWidth()`
- [ ] A1: rename `term_size.d` → `term_caps.d`; add `isTerminal`, `TermCaps`,
      `detectTermCaps` (hoist `prepareConsole` from `test-runner-impl/runner_impl.d`);
      update the `term-size` example and AGENTS.md layout table
- [ ] A5: `truncateField` in `base.text.width`; rewire `box.d`'s private
      `ellipsizeTitle` onto it
- [ ] A4: hoist a shared border-charset preset mechanism out of `table.d` so
      `BoxProps`/`drawHeader` select the same presets; semantic styles + status-glyph
      vocabulary with ASCII fallbacks keyed off `TermCaps.unicode`; unify the
      `colored`/`useColors`/`noColours` parameter spelling
- Verification: `dub test :core-cli`, `dub test :base`, `dub test :math` (watch the
  test-runner-impl source-include arrangement for unittest-config cycles);
  `nix run .#ci -- --test` before commit.

### M1 — Terminal control + live rendering

- [ ] A3: `sparkles.base.term_control` — move `AnsiControl` (zero external importers)
      as `CtlSeq`, add erase variants, `writeCursor*`, `DecMode` set/reset (spec §4)
- [ ] D1: live region (spec §5 blueprint: DEC-2026-framed repaint, height tracking,
      static channel, non-TTY append mode, RAII restore guard, resize per tick)
- [ ] D2: wire `spinnerFrame`/`ProgressLine` (already pure producers) into D1; retire
      the ad-hoc CR + erase-line framing in the test runner
- [ ] D3: task list (pending/running/ok/failed/skipped rows, groups, per-row detail)
- [ ] D5 prerequisite: streaming variant of `runCaptured` in `process_utils`
      (line-callback or range); bounded tail pane can follow later
- [ ] Consumers: `release` pre-flight + stages become a live checklist (progress
      callbacks through `runPreflight`); `ci` per-example verification adopts D3/D4
- Verification: golden tests for the non-TTY append path (deterministic); manual/cast
  check for the TTY path; `SIGINT` during a live region leaves the cursor visible.

### M2 — Interactive prompts

- [ ] C1 `select` (numbered, default, descriptions, re-prompt loop)
- [ ] C2 `confirm` (`[y/N]`, destructive-action variant)
- [ ] C3 `input` (validation/parse callback loop)
- [ ] C4 resolution policy (`interactive`/`takeDefault`/`fail`) on every prompt,
      driven by `--auto` and `TermCaps.tty`
- [ ] Consumers: `release` bump prompt shows candidate versions (patch/minor/major →
      concrete `vX.Y.Z`) with the suggestion and policy reason; confirm gate before
      push/publish stages; closing receipt box with `oscLink` to the GitHub release
- Verification: prompts are testable by injecting an input range; `release --auto`
  and piped-stdin behavior covered by unit tests.

### M3 — Table follow-ups

- [ ] Consumer wiring: `release` stats adopt `columnAligns`, `headerRows`, and
      `maxWidth: terminalSize().width`; bench + `ci` tables likewise
- [ ] Title/footer parity with `drawBox`
- [ ] Lazy/streaming rendering (parity with `drawBoxLines`/`drawBoxChunks`)
- [ ] `validateTable` overload returning all errors
- [ ] As needed: per-cell align/valign override, `Align.decimal`, writer overload
- [ ] Structural: split `table/grid.d` (pure resolution) from `table/render.d` when
      title/footer or streaming land

### M4 — Data display

- [ ] E1 meter/bar (`█▏…` eighth-cell precision) + D4 determinate progress bar on top
- [ ] E2 tree view (flat `Node[]` + pure `flatten()` per the tree-view case study);
      first consumer: `release` area breakdown
- [ ] E4 horizontal block composition (line-zipping over `visibleWidth`-padded blocks)
- [ ] E3 key-value convenience wrapper only if the borderless-table form proves clumsy

## 3. Deferred / explicitly out of scope

- F1 `gridBox` layout container (share the slot-grid machinery when a consumer appears)
- F2 full-screen TUI loop (alt screen + raw-mode input decoding)
- Terminal queries (DA1/CPR/kitty probes), scroll regions, kitty keyboard/graphics
- terminfo (no-terminfo consensus per the survey), cell-grid diff compositor
- Windows resize _events_ (sync `terminalSize()` covers Windows already)
- E5 sparkline, S4 table auto-merge, DbI table cell content, fully-`@nogc` table
  internals
