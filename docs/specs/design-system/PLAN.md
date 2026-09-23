# Delivery plan

_**Date:** 2026-09-21 · The milestone tracker. Requirements live in
[`SPEC.md`](./SPEC.md) and the topic pages; this page owns order, gates and
exclusions only._

Order follows [target sequencing](./index.md#target-sequencing): TUI → Web →
GUI → mobile. First consumers: `ui-gallery` and the docs site; `hue` and
`diagram` after; OS-following (`sparkles:appearance`) later.

| Milestone | Deliverable                                                                                                                                                                                                                                                 | Obligations                                    | Gate (acceptance)                                                                                                       | Excludes                                              | Status                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **M0**    | Stage 0: this tree, [decisions](./decisions.md), and the `sparkles.ui.tokens` draft (paths, states, capabilities, profiles, border projection) compiling with tests                                                                                         | `TOK2`, `TOK5`, `CAP1`, `CAP9`, `GLY2`         | spec accepted by the owner; `dub test :ui -- -i ui.tokens` green; `ci --check-docs-sidebar` green                       | any migration of existing types                       | in progress                                                                                                                                                                   |
| **M1**    | Token vocabulary in code: `Slot` regrouped into tiers with the `TOK3` roles added, `resolve(slot, states)`, `Palette` metrics renamed (`TOK8`), every component declares `slots` with `O3` tests                                                            | `TOK1`, `TOK3`–`TOK8`, `TOK10`                 | `O3` over every `components/*.d`; every existing golden unchanged (the rest state is the old behaviour)                 | file format; CSS                                      | in progress — roles, renames, declarations (ui), state overlays done; per-state attrs/metrics and the hand-swapping components pending                                        |
| **M2**    | `TargetCapabilities` declared by `ui-tui` (from `TermCaps`), `ui-raylib` and `html_semantic`; chrome half of `TGT5` closed; `ui-gallery --profile`; degradation report                                                                                      | `CAP1`, `CAP2`, `CAP4`–`CAP6`, `CAP8`          | `baseline` render of every gallery page as verified fences (`O1`); `CAP4` parity scenario                               | new probes (M6)                                       | in progress — declarations for the three targets, the degradation report, `--profile`/`--degradations` and the `baseline` goldens done; the `CAP2` table audit and `OQ1` open |
| **M3**    | Glyph channel: `GlyphSet` with charsets per role, marks, `projectBorder` wired into `ui-tui`, sub-cell rules/thumbs; `O7` exhaustive tables; the public style-guide pages under `docs/design-system/` with `O1` fences for three profiles                   | `GLY1`–`GLY3`, `GLY2a`, `GLY8`, `ACC3`, `ACC4` | fences verified in CI; `ACC4` focus-visibility sweep at `baseline`                                                      | text sizing, images                                   | not started                                                                                                                                                                   |
| **M4**    | **Sparkles v1 (TUI):** the palette/type/glyph exercise, values authored, `O2` passing, default in `ui-gallery`                                                                                                                                              | `SPK1`–`SPK3`, `SPK5`, `ACC1`, `ACC2`          | `O2` conformance table published for all 37 themes; Sparkles `required` and green                                       | web/GUI verification of the values                    | not started                                                                                                                                                                   |
| **M5**    | Theme file: DTCG loader/saver over `sparkles:wired`, exports of every built-in checked in, `hue --theme <file>` / `ui-gallery --theme <file>`                                                                                                               | `FMT1`–`FMT6`, `SPK6`                          | `O4`: upstream examples load; malformed corpus rejected with paths; 37 round trips                                      |                                                       | not started                                                                                                                                                                   |
| **M6**    | Web: `cssName`-driven emitter in `sparkles:docs`, callouts tokenised, VitePress mapping block + committed generated stylesheet with `O6`; `html_semantic` on slot-path classes; `ch`-based breakpoints                                                      | `WEB1`–`WEB6`, `SPK4`                          | `npm run docs:build` on the generated file; `O6` green; the site renders Sparkles                                       | interactive web beyond tier-0 CSS                     | not started                                                                                                                                                                   |
| **M7**    | Terminal capability probing, one slice per row: `hyperlinks`, `clipboard`, `syncOutput`, `hoverMotion`, `keyRelease`, `focusEvents`, `bracketedPaste`, `extendedUnderline`, `pointerShape`, `notifications`, `colorSchemeNotify`, `cellPixelSize`, `images` | `CAP3`, `CAP7`                                 | per row: an `O5` transcript test for ≥ 2 emulators + tmux; the consumer component degrades visibly when the flag is off | `textSizing` (gated on the text-sizing proposal's M0) | not started                                                                                                                                                                   |
| **M8**    | Keyboard vocabulary: the overlay table, reserved-key check, `--keys`; adopted by `ui-gallery`, `hue`, `diagram`                                                                                                                                             | `KBD1`–`KBD6`                                  | `bindingsAt` over the universal rows identical across the three apps                                                    |                                                       | not started                                                                                                                                                                   |
| **M9**    | GUI enhancements: smooth (`subCellScroll`) scrolling, proportional docs runs (`GLY7`), radius/shadow/alpha honoured, Sparkles checked unchanged on the window                                                                                               | `TOK7` (honour side), `GLY7`                   | `hue --gui` screenshot A/B against the TUI goldens for the same pages                                                   | mobile                                                | not started                                                                                                                                                                   |
| **M10**   | Mobile: touch targets and safe areas as tokens; Android `hue` on Sparkles                                                                                                                                                                                   | (new IDs when specified)                       | —                                                                                                                       |                                                       | not started                                                                                                                                                                   |

## Standing gates

- **Nerd Font version** follows the flake's nixpkgs; a bump that moves code
  points must update the checked-in icon table (`GLY4`) in the same change.
- **No milestone leaves a failing test as its deliverable.** A TDD red test
  is committed with its green in the same PR.
- **Publication** (`ci --check-docs-sidebar`, `docs:build`, prettier) is
  reported separately from semantic acceptance.

## Handoff section

_Updated at each interruption; one section, not a diary._

- **Checked revision:** `feat/design-system-m2`, on top of `1dae8a98d` (PR #508 merged).
- **Done (M0, M1):** the tree, `tokens.d`, `TargetCapabilities` over
  `base`/`input`; `TOK3` roles, `TOK8` metric paths, `TOK6` declarations,
  `TOK4`/`TOK5` state overlays.
- **Done (M2, this branch):** `terminalCapabilities`/`declaredCapabilities`;
  `GridCanvas.capabilities` honoured (ASCII chrome, link ids, styled
  underlines) with `gridCapabilities` as the unchanged default; the live TUI
  declares `sessionCapabilities`; constants for raylib and both HTML writers;
  `sparkles.ui.degradation` (`CAP6`) with each row checked against the grid
  painter; `ui-gallery --profile`/`--degradations`; every page's `baseline`
  render as a golden (`O1`); the `CAP4` parity scenario.
- **Unverified / open:** the `CAP2` audit (every table row a field, every field
  consumed); `OQ1` (how the TUI learns `nerdFont`) moves to M3 with the icon
  table; the live TUI's input half and its OSC 8 / SGR 4:3 rows are assumed
  (D27) until M7. From M1: per-state attributes and metrics; `actionBar` and
  the scrollbar onto overlays; `TOK6` for twoslash/source-view/hue.
- **Blockers:** none. M4 needs the brand design exercise (after M1–M3, D23).
- **Next executable action:** M3 — the glyph channel: `GlyphSet` charsets per
  role, `projectBorder` replacing the grid's own corner table, and the text-run
  glyphs (tree guides, table rules, dividers) the `baseline` goldens still show.

→ [Overview](./index.md) · [Testing](./testing.md)
