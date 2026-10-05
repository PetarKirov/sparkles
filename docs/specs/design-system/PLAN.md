---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Delivery plan

## Abstract

This page is the one milestone tracker for the `sparkles:ui` design system: the
order in which its requirements are delivered, the gate each milestone must
pass, what each excludes, and where delivery stands. Requirements live in
[SPEC.md](./SPEC.md) and the topic pages; this page owns order, gates,
exclusions and progress only.

## Introduction

Order follows [target sequencing](./index.md#target-sequencing): TUI, then Web,
then GUI, then mobile. The first consumers are `ui-gallery` and the docs site;
`hue` and `diagram` follow, and OS-following (`sparkles:appearance`) comes last
(D18). Milestones here are design-system milestones (M0–M10). Where a gate
depends on another specification's milestone, the family is named: font M4 and
M7 ([font PLAN](../font/PLAN.md)),
[text-layout TL-M3](../text-layout/PLAN.md#_5-tl-m3-real-contextual-shaped-flow),
and [base/text M5](../base/text/PLAN.md#_6-m5-concrete-clean-cutovers).

## Milestones

| Milestone | Deliverable                                                                                                                                                                                                                                                 | Obligations                                    | Gate (acceptance)                                                                                                       | Excludes                                                   | Status                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **M0**    | Stage 0: this tree, [decisions](./decisions.md), and the `sparkles.ui.tokens` draft (paths, states, capabilities, profiles, border projection) compiling with tests                                                                                         | `TOK2`, `TOK5`, `CAP1`, `CAP9`, `GLY2`         | spec accepted by the owner; `dub test :ui -- -i ui.tokens` green; `ci --check-docs-sidebar` green                       | any migration of existing types                            | in progress                                                                                                                   |
| **M1**    | Token vocabulary in code: `Slot` regrouped into tiers with the `TOK3` roles added, `resolve(slot, states)`, `Palette` metrics renamed (`TOK8`), every component declares `slots` with `O3` tests                                                            | `TOK1`, `TOK3`–`TOK8`, `TOK10`                 | `O3` over every `components/*.d`; every existing golden unchanged (the rest state is the old behaviour)                 | file format; CSS                                           | done; metrics per state admitted (D22), no consumer                                                                           |
| **M2**    | `TargetCapabilities` declared by `ui-tui` (from `TermCaps`), `ui-raylib` and `html_semantic`; chrome half of `TGT5` closed; `ui-gallery --profile`; degradation report                                                                                      | `CAP1`, `CAP2`, `CAP4`–`CAP6`, `CAP8`          | `baseline` render of every gallery page as verified fences (`O1`); `CAP4` parity scenario                               | new probes (M7)                                            | done (PR #511)                                                                                                                |
| **M3**    | Glyph channel: `GlyphSet` with charsets per role, marks, `projectBorder` wired into `ui-tui`, sub-cell rules/thumbs; `O7` exhaustive tables; the public style-guide pages under `docs/design-system/` with `O1` fences for three capability profiles        | `GLY1`–`GLY3`, `GLY2a`, `GLY8`, `ACC3`, `ACC4` | fences verified in CI; `ACC4` focus-visibility sweep at `baseline`                                                      | text sizing, images                                        | done except the leftovers below                                                                                               |
| **M4**    | **Sparkles v1 (TUI):** the palette/type/glyph exercise, values authored, `O2` passing, default in `ui-gallery`                                                                                                                                              | `SPK1`–`SPK3`, `SPK5`, `ACC1`, `ACC2`          | `O2` conformance table published for all 37 themes; Sparkles `required` and green                                       | web/GUI verification of the values                         | not started                                                                                                                   |
| **M5**    | Theme file: DTCG loader/saver over `sparkles:wired`, exports of every built-in checked in, `hue --theme <file>` / `ui-gallery --theme <file>`                                                                                                               | `FMT1`–`FMT6`, `SPK6`                          | `O4`: upstream examples load; malformed corpus rejected with paths; 37 round trips                                      |                                                            | not started                                                                                                                   |
| **M6**    | Web: `cssName`-driven emitter in `sparkles:docs`, callouts tokenised, VitePress mapping block + committed generated stylesheet with `O6`; `html_semantic` on slot-path classes; `ch`-based breakpoints                                                      | `WEB1`–`WEB6`, `SPK4`                          | `yarn docs:build` on the generated file; `O6` green; the site renders Sparkles                                          | interactive web beyond tier-0 CSS                          | not started                                                                                                                   |
| **M7**    | Terminal capability probing, one slice per row: `hyperlinks`, `clipboard`, `syncOutput`, `hoverMotion`, `keyRelease`, `focusEvents`, `bracketedPaste`, `extendedUnderline`, `pointerShape`, `notifications`, `colorSchemeNotify`, `cellPixelSize`, `images` | `CAP3`, `CAP7`                                 | per row: an `O5` transcript test for ≥ 2 emulators + tmux; the consumer component degrades visibly when the flag is off | `textSizing` (gated on the text-sizing proposal's M0, OQ5) | done, `textSizing` excluded (PRs #512–#561)                                                                                   |
| **M8**    | Keyboard vocabulary: the overlay table, reserved-key check, `--list-keys`; adopted by `ui-gallery`, `hue`, `diagram`                                                                                                                                        | `KBD1`–`KBD7`                                  | `bindingsAt` over the universal rows identical across the three apps                                                    |                                                            | done for `KBD1`, `KBD3`, `KBD6`, `KBD7`; `KBD2`, `KBD4` partial; `KBD5` not started                                           |
| **M9**    | GUI enhancements: smooth (`subCellScroll`) scrolling, proportional docs paragraphs (`GLY7`), font roles (`GLY11`), radius/shadow/alpha honoured, Sparkles checked unchanged on the window                                                                   | `TOK7` (honour side), `GLY7`, `GLY10`, `GLY11` | `hue --gui` screenshot A/B against the TUI goldens for the same pages; `GLY7` also gated on text-layout TL-M3           | mobile                                                     | in progress: `GLY10` and `TOK7` delivered; `GLY7` gated on text-layout TL-M3; `GLY11` on font M7; `subCellScroll` not started |
| **M10**   | Mobile: touch targets and safe areas as tokens; Android `hue` on Sparkles                                                                                                                                                                                   | (new IDs when specified)                       | —                                                                                                                       |                                                            | not started                                                                                                                   |

**M7 notes.** The query battery, parser and output mapping live in
`base.term_replies`; `Terminal.probe` runs by default (D39); decoders never read
a reply as keys. Focus reports, bracketed paste and grapheme clustering are
negotiated; clustering is measured and selects the grid's width profile (D38,
`GLY6`). Styled underlines come from `XTGETTCAP` (D41), synchronized output has
no visible consumer (D40), and the rows no query answers follow the terminal's
`XTVERSION` name (D42) with their consumers per errand (D43). Key releases are
negotiated over the kitty keyboard protocol and hover is declared where 1003
was asked for (D44); `precisePointer` is off on a terminal (D45).

**M8 notes.** `sparkles.ui.keymap_universal` holds the fixed and focus rows,
the reserved chords, `@means` and `writeKeyTable`. hue, ui-gallery and diagram
carry the conformance test (`KBD7`, `keymap.universalRowsAndReservedKeys`
over the one `universalKeys` table) and print their effective tables. The TUI
host quits on `Ctrl-C` unless the keyboard is grabbed (D47, D48).

**M9 notes.** `GLY7` is a text-layout `shapedFlow` paragraph inside the
widget's cell rect (D53). Its gate is text-layout TL-M3, which is itself gated
on font M4 and M7; there is no interim implementation. `GLY11`'s fallback chains
and code-point routes come from font M7.

## Standing gates

- **Nerd Font version** follows the flake's nixpkgs; a bump that moves code
  points **must** update the checked-in icon table (`GLY4`) in the same change.
- **No milestone leaves a failing test as its deliverable.** A TDD red test
  is committed with its green in the same PR.
- **Publication** (`ci --check-docs-sidebar`, `docs:build`, prettier) is
  reported separately from semantic acceptance.
- **base/text cutover.** `LAY5`, `LAY10` and `LAY14` keep their evidence for
  the delivered code until base/text M5 moves those callers onto base's
  measuring, fitting and wrapping (D51); `GLY6`'s fold and `GLY12` follow the
  same cutover of the TUI grid (D50).

## Handoff section

_One section describing the state, updated at each interruption._

- **Checked revision:** `feat/ui-keymap-universal`, on top of PR #576.
- **Delivered:** M1, M2, M7 and M8 as their rows state; M3 except its
  leftovers. Beyond M3: the live capability-profile switch in `ui-gallery`
  (`}`/`{`, narrowing with `meet`); emulator presets from the `O5` corpus
  (`CAP10`, D32, D33); the image ladder, cell rungs and the kitty and sixel
  protocol rungs (`GLY9`, `IMG5`, D34); the interface face and chrome type
  scale (`GLY10`, D49); density-scaled radius and shadow (`TOK7`).
- **Open:** the sub-cell hairline rule (`GLY2a`); per-role glyph preferences
  beyond marks (`GLY1`); `ACC4` for every focusable inside pages; the `CAP2`
  table audit; the icon table (`GLY4`); metrics per state (no consumer); the
  scrollbar's `trackLit` is a paint choice, not a state; the inspector
  header's spans choose their slot per span; the twoslash, source-view and hue
  views' slot declarations (`TOK6`).
- **Gated elsewhere:** `GLY7` on text-layout TL-M3 (← font M4/M7); `GLY11` on
  font M7; `GLY12` and the `terminalUnclustered` form of `GLY6` on base/text
  M5's TUI-grid cutover; `GLY5` on the text-sizing proposal's M0 and base/text's
  scaled footprints (OQ5, D54); `LAY10`/`LAY14` evidence on base/text M5 (D51).
- **Blockers:** none. M4 needs the brand design exercise (owner, D23, OQ2).
- **Next executable actions**, in the owner's order: (1) M5, the theme file —
  state overrides are aliases, so they are DTCG aliases there; (2) M3's
  leftovers; (3) M6, web; then `KBD5`'s Readline keys with the text-input
  component. Beside them: iTerm2, WezTerm and Apple Terminal into the `O5`
  corpus (macOS, and WezTerm headless), Windows Terminal and the Linux console
  with a person at the machine; M4 once the owner's design session has
  happened; `GLY7` once text-layout TL-M3 lands.

→ [Overview](./index.md) · [Testing](./testing.md)
