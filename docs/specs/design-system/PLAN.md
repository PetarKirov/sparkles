# Delivery plan

_**Date:** 2026-09-21 · The milestone tracker. Requirements live in
[`SPEC.md`](./SPEC.md) and the topic pages; this page owns order, gates and
exclusions only._

Order follows [target sequencing](./index.md#target-sequencing): TUI → Web →
GUI → mobile. First consumers: `ui-gallery` and the docs site; `hue` and
`diagram` after; OS-following (`sparkles:appearance`) later.

| Milestone | Deliverable                                                                                                                                                                                                                                                 | Obligations                                    | Gate (acceptance)                                                                                                       | Excludes                                              | Status                                                                                                                                                                                                                                                                                               |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **M0**    | Stage 0: this tree, [decisions](./decisions.md), and the `sparkles.ui.tokens` draft (paths, states, capabilities, profiles, border projection) compiling with tests                                                                                         | `TOK2`, `TOK5`, `CAP1`, `CAP9`, `GLY2`         | spec accepted by the owner; `dub test :ui -- -i ui.tokens` green; `ci --check-docs-sidebar` green                       | any migration of existing types                       | in progress                                                                                                                                                                                                                                                                                          |
| **M1**    | Token vocabulary in code: `Slot` regrouped into tiers with the `TOK3` roles added, `resolve(slot, states)`, `Palette` metrics renamed (`TOK8`), every component declares `slots` with `O3` tests                                                            | `TOK1`, `TOK3`–`TOK8`, `TOK10`                 | `O3` over every `components/*.d`; every existing golden unchanged (the rest state is the old behaviour)                 | file format; CSS                                      | in progress — roles, renames, declarations (ui), state overlays done; per-state attrs/metrics and the hand-swapping components pending                                                                                                                                                               |
| **M2**    | `TargetCapabilities` declared by `ui-tui` (from `TermCaps`), `ui-raylib` and `html_semantic`; chrome half of `TGT5` closed; `ui-gallery --profile`; degradation report                                                                                      | `CAP1`, `CAP2`, `CAP4`–`CAP6`, `CAP8`          | `baseline` render of every gallery page as verified fences (`O1`); `CAP4` parity scenario                               | new probes (M6)                                       | done — PR #511                                                                                                                                                                                                                                                                                       |
| **M3**    | Glyph channel: `GlyphSet` with charsets per role, marks, `projectBorder` wired into `ui-tui`, sub-cell rules/thumbs; `O7` exhaustive tables; the public style-guide pages under `docs/design-system/` with `O1` fences for three profiles                   | `GLY1`–`GLY3`, `GLY2a`, `GLY8`, `ACC3`, `ACC4` | fences verified in CI; `ACC4` focus-visibility sweep at `baseline`                                                      | text sizing, images                                   | done on `feat/design-system-m3` except the sub-cell hairline rule (`GLY2a`), per-role theme preferences beyond marks (`GLY1`) and per-focusable `ACC4` placement                                                                                                                                     |
| **M4**    | **Sparkles v1 (TUI):** the palette/type/glyph exercise, values authored, `O2` passing, default in `ui-gallery`                                                                                                                                              | `SPK1`–`SPK3`, `SPK5`, `ACC1`, `ACC2`          | `O2` conformance table published for all 37 themes; Sparkles `required` and green                                       | web/GUI verification of the values                    | not started                                                                                                                                                                                                                                                                                          |
| **M5**    | Theme file: DTCG loader/saver over `sparkles:wired`, exports of every built-in checked in, `hue --theme <file>` / `ui-gallery --theme <file>`                                                                                                               | `FMT1`–`FMT6`, `SPK6`                          | `O4`: upstream examples load; malformed corpus rejected with paths; 37 round trips                                      |                                                       | not started                                                                                                                                                                                                                                                                                          |
| **M6**    | Web: `cssName`-driven emitter in `sparkles:docs`, callouts tokenised, VitePress mapping block + committed generated stylesheet with `O6`; `html_semantic` on slot-path classes; `ch`-based breakpoints                                                      | `WEB1`–`WEB6`, `SPK4`                          | `npm run docs:build` on the generated file; `O6` green; the site renders Sparkles                                       | interactive web beyond tier-0 CSS                     | not started                                                                                                                                                                                                                                                                                          |
| **M7**    | Terminal capability probing, one slice per row: `hyperlinks`, `clipboard`, `syncOutput`, `hoverMotion`, `keyRelease`, `focusEvents`, `bracketedPaste`, `extendedUnderline`, `pointerShape`, `notifications`, `colorSchemeNotify`, `cellPixelSize`, `images` | `CAP3`, `CAP7`                                 | per row: an `O5` transcript test for ≥ 2 emulators + tmux; the consumer component degrades visibly when the flag is off | `textSizing` (gated on the text-sizing proposal's M0) | in progress — the battery, parser and output mapping (`base.term_replies`), `Terminal.probe`, decoders that never read a reply as keys, focus reports and bracketed paste negotiated, and the unqueryable rows (links, clipboard, notifications, pointer shape, styled underlines) on another answer |
| **M8**    | Keyboard vocabulary: the overlay table, reserved-key check, `--keys`; adopted by `ui-gallery`, `hue`, `diagram`                                                                                                                                             | `KBD1`–`KBD6`                                  | `bindingsAt` over the universal rows identical across the three apps                                                    |                                                       | not started                                                                                                                                                                                                                                                                                          |
| **M9**    | GUI enhancements: smooth (`subCellScroll`) scrolling, proportional docs runs (`GLY7`), radius/shadow/alpha honoured, Sparkles checked unchanged on the window                                                                                               | `TOK7` (honour side), `GLY7`                   | `hue --gui` screenshot A/B against the TUI goldens for the same pages                                                   | mobile                                                | not started                                                                                                                                                                                                                                                                                          |
| **M10**   | Mobile: touch targets and safe areas as tokens; Android `hue` on Sparkles                                                                                                                                                                                   | (new IDs when specified)                       | —                                                                                                                       |                                                       | not started                                                                                                                                                                                                                                                                                          |

## Standing gates

- **Nerd Font version** follows the flake's nixpkgs; a bump that moves code
  points must update the checked-in icon table (`GLY4`) in the same change.
- **No milestone leaves a failing test as its deliverable.** A TDD red test
  is committed with its green in the same PR.
- **Publication** (`ci --check-docs-sidebar`, `docs:build`, prettier) is
  reported separately from semantic acceptance.

## Handoff section

_Updated at each interruption; one section, not a diary._

- **Checked revision:** `feat/tui-paste-focus`, on top of PR #526 (the battery,
  merged).
- **Done (M0–M2):** tokens, state overlays, target declarations, the
  degradation report, `ui-gallery --profile`/`--degradations`.
- **Done (M3):** `sparkles.ui.glyphs` — tiers, the one-cell
  fallback ladder, `projectGlyph`, the status marks (`GLY1`, `GLY3`, `ACC3`);
  dotted families and `boxGlyphs` with an exhaustive `O7` table (`GLY2`); the
  grid painter projects every glyph it writes, text runs included (D30); the
  style guide under `docs/design-system/` imports each gallery page's frame and
  report at all three profiles from the goldens `dub test :ui-gallery` checks
  (`O1`, `CAP5`); the `ACC4` region sweep; `ColorDepth.none` fixed to emit no
  color in `sparkles:base`.
- **Done (after M3):** `ui-gallery` switches its profile live (`}`/`{`),
  narrowing the host with `meet` and never above where it started (#513);
  emulator presets (`CAP10`, D32) — measured emulators' recorded replies,
  mapped by `fromReplies`, previewed with `ui-gallery --emulator` (#514);
  foot, and tmux and zellij under real hosts, measured headlessly (foot in
  `cage` on the wlroots headless backend, Ghostty under `xvfb-run`), their
  probe reports checked in and re-read by test; multiplexer presets are the
  meet over their hosts, with DA1's sixel dropped under a multiplexer (D33,
  `CAP7` partial). The image ladder's cell rungs (`GLY9` partial, D34): a
  block or braille raster in the terminal and in a narrowed window. Its
  protocol rung for kitty (`IMG5`): the opt-in `images` probe (`CAP3`'s first
  query row) and placements beside the grid, checked live in kitty; sixel
  (`sparkles.tui.sixel`), checked live in foot, with `CSI 16 t` for the cell
  size. Octants (`GLY9` full): `blockOctantGlyphs`, generated with the rest
  of `sparkles.base.text.unicode_tables` by `libs/base/tools/gen_unicode_tables.d`,
  the 26 borrowed characters checked by name. M7's battery (D35): one
  vocabulary, parser and output mapping in `base.term_replies`, fed by
  `Terminal.probe` and by the presets alike; six real terminals' raw replies
  through the live parser (`O5`); decoders that drop late replies. Focus
  reports and bracketed paste negotiated when answered, decoded to
  `FocusEvent` and to `PasteEvent` chunks (`INP21`, D36) that `terminal-view`
  hands its shell bracketed; the terminal no longer claims either unasked.
- **Unverified / open:** the sub-cell hairline rule (`GLY2a`); per-role glyph
  preferences beyond marks (`GLY1`); `ACC4` for every focusable inside pages;
  the `CAP2` table audit; the icon table (`GLY4`). From M1: per-state
  attributes/metrics; `actionBar` and the scrollbar onto overlays.
- **Blockers:** none. M4 needs the brand design exercise (owner, D23).
- **Next executable actions:** (1) a consumer that degrades visibly per
  probed row (M7's gate); (2) Windows Terminal and the Linux console need a
  person at the machine; (3) M4, once the owner's design session has
  happened.

→ [Overview](./index.md) · [Testing](./testing.md)
