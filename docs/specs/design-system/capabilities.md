---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Capabilities (`CAP`)

## Abstract

`sparkles:ui` renders to terminals, GPU windows and web pages that differ in
what they can draw and what input they report. Each target declares those
abilities as one flag per feature. This page specifies what each flag means and
what reads it, and requires that a flag that is off yields a published
substitution, listed in the frame's degradation report, never a silent loss;
the [glyphs page](./glyphs.md) says what each substitution is. Detection
belongs to `sparkles:base` and `sparkles:tui`, which read the environment and
send a bounded query battery, a fixed set of terminal queries with a timeout.
Three capability profiles give tests fixed reference points, the lowest being
a dumb terminal that draws only monochrome ASCII. Emulator presets, built from
replies recorded from real terminals, preview them from any host.

## Introduction

A terminal may have true color but no hyperlinks, an SGR mouse but no hover
motion, a Nerd Font or only ASCII. A window has none of those limits but cannot
receive a terminal's protocols at all. A pipe can draw only text. The design
system has to render one theme for all of them, and it has to know, per target,
which of the theme's requests can be honoured.

Popular libraries summarise this as a ladder of tiers, such as baseline,
enhanced and full. A single support level lies the moment a real terminal has
one feature of a tier and lacks another. The repository's own research
([concepts](../../research/platform-ui-guidelines/concepts.md)) and the input
side's capability axes ([`IXB10`](../ui/interaction-review.md),
`InputCapabilities`) reach the same conclusion.

The contract therefore uses **per-feature flags as the data**. Every flag is a
field of one declaration, and every field exists because something reads it.
The three tiers survive only as
[capability profiles](../../glossary.md#capability-profile): named constant flag
sets that tests and the style guide use, so that "what does this look like on a
dumb terminal" has one answer. Terminal flags come from the environment and
from a bounded query battery, and where a flag is off, the frame's degradation
report names what was drawn instead.

This page owns the declaration, the profiles, the presets and the rule that
nothing is dropped silently. Detection is implemented by `sparkles:base`
(environment-derived answers, `term_caps`) and `sparkles:tui` (query-derived
answers); the design system declares intent and the libraries implement it
(D9, D21). What each glyph or text request becomes under a missing flag is
[glyphs.md](./glyphs.md)'s; how wide text is on a grid is base/text's
[width profile](../../glossary.md#width-profile), a separate notion from a
capability profile. Following the operating system's appearance is deferred to
`sparkles:appearance`.

The requirements come first, then the capability table (one row per field),
the capability profiles, and the emulator presets. Oracles and evidence live in
[testing.md](./testing.md), delivery order in [PLAN.md](./PLAN.md), and the
reasoning in [decisions.md](./decisions.md).

## Contract at a glance

1. A target declares one `TargetCapabilities` value; a field it omits takes the
   conservative default.
2. Every capability the design system names is a field, and every field has a
   consumer.
3. Detection **may** only lower a capability on environment evidence; raising one
   needs an answer from the terminal.
4. A capability is applied per target when the display list is built, never
   from a process-wide terminal snapshot.
5. A missing capability yields a published substitution in the degradation
   report, never a silent drop.
6. The capability profiles are monotone: `baseline ⊆ enhanced ⊆ full`.

## The decision: flags, not tiers

The two outlines that seeded this tree both framed capability as three tiers,
and their feature inventories (color depth, Unicode width, box drawing and
block elements, the OSC and DEC-mode protocols, multiplexer passthrough,
non-tty modes) are absorbed into the capability table below. The contract keeps
the three tiers only as **capability profiles**: named constant flag sets used
by tests and the style guide (D8).

| ID      | Requirement                                                                                                                                                                                                                                                                                                | Status  | Traces to                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CAP1`  | A target **must** declare a **`TargetCapabilities`** value as data the toolkit inspects. A field a backend omits **must** take its conservative default (`false` / `none`).                                                                                                                                | partial | `tokens.d` `TargetCapabilities`, `terminalCapabilities`, `declaredCapabilities`; `ui_tui.session` `sessionCapabilities`; `ui_raylib` `raylibCapabilities`; `interp.html` `htmlCapabilities`, `interp.html_semantic` `semanticHtmlCapabilities`                                                                                                                                                                                                                                                                                                    |
| `CAP2`  | Every capability the design system names **must** be a field of `CAP1`'s type, and a token or component that degrades on a capability **must** name that field. A capability no token or component reads **must** be removed.                                                                              | partial | `degradation.d` `@needs` (every substitution cites a real field, checked at compile time). Pending: the table-vs-field audit                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `CAP3`  | Every terminal-detectable row **must** be **answerable by the toolchain**, onto the same `TermCaps` value: environment-derived answers by `sparkles:base`, query-derived answers by `sparkles:tui`. A query **must** have a bounded timeout and a DA1 sentinel, so a non-responding terminal never blocks. | partial | `base.term_caps`; `base.term_replies` `queryBattery`, `parseReplies`, `applyReplies`; `base.term_identity.knownTerminals`; `Terminal.probe`, `RunConfig.probeTerminal`; tests `term_replies.*`, `integration.pty.probe*`, `integration.pty.probeRecordedTerminals`, `term_replies.transcripts.corpus`, `ui.emulators.rowsAreTheirTranscripts`, `integration.pty.graphemeClustersAreNegotiated`, `integration.pty.focusReportsAreNegotiatedAndDecoded`, `integration.pty.bracketedPasteIsOnePaste`, `ui_tui.session.declaresOnlyWhatWasNegotiated` |
| `CAP4`  | The theme **must** never be **gated on a terminal snapshot**: capability application **must** happen per target at display-list build time.                                                                                                                                                                | full    | `ui_tui.grid_canvas` test `tui_canvas.capabilities.theThemeIsNotGatedOnATerminal`                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `CAP5`  | Every token projection and every component **must** have a defined rendering under each **capability profile**: `baseline`, `enhanced`, `full`. The `baseline` render of every gallery page **must** be a CI-verified fence ([`O1`](./testing.md)).                                                        | full    | `ui-gallery --render --profile`; `apps/ui-gallery/test/data/profiles/<page>/` (`O1`); the style guide `docs/design-system/catalog/` imports those files                                                                                                                                                                                                                                                                                                                                                                                           |
| `CAP6`  | A capability the target lacks **must** resolve to a **published substitution**, never be dropped. The substitution is data recorded in the frame's degradation report.                                                                                                                                     | full    | `degradation.d` `degradationsOf` (chrome and glyph rows); `ui-gallery --degradations`; every catalog page shows the three reports                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `CAP7`  | Under a **multiplexer**, a capability the multiplexer does not pass through **must** be reported `false` unless a query positively confirms passthrough. Environment sniffing **may** only lower a capability, never raise one.                                                                            | partial | `fromReplies` drops DA1's sixel under a multiplexer, test `ui.emulators.multiplexerImagesNeedAConfirmedRoundTrip`. Pending: detection in `base.term_caps`                                                                                                                                                                                                                                                                                                                                                                                         |
| `CAP8`  | A **non-tty** stdout, `$NO_COLOR`, `TERM=dumb` and `$CLICOLOR_FORCE` **must** keep their `detectTermCaps` semantics, and the resulting capability set **must** be exactly the `baseline` profile with `colorDepth` as detected.                                                                            | full    | `base.term_caps.detectTermCaps`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `CAP9`  | Capability profiles **must** be **monotone**: `baseline ⊆ enhanced ⊆ full` field-wise, so a `bool` can only turn on and an enum only widen. A test over the three constants **must** check it.                                                                                                             | full    | `tokens.d` `subsetOf`, test `ui.tokens.profiles.monotone`; `ui_gallery.render.profilesOnlyEverLoseThings`                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `CAP10` | An **emulator preset must** be a measured emulator's recorded replies to the query battery, mapped to flags by the mapping a live probe uses. A preset **must** claim only what the battery asks, over a shared floor, and is a preview and fixture, never detection.                                      | full    | `sparkles.ui.emulators`; tests `ui.emulators.table`, `ui.emulators.neverClaimTheUnmeasured`, `ui.emulators.presetsAreAPartialOrder`, `ui_gallery.gallery.emulatorBoundsTheProfileSwitch`, `ui.emulators.rowsAreTheirTranscripts`, `ui.emulators.cellSizeAndFocusWhereEveryRowAnswered`                                                                                                                                                                                                                                                            |

**CAP1 notes.** `TargetCapabilities` composes
`sparkles.base.term_caps.OutputCapabilities` (what may be emitted: color depth,
glyph coverage, links, clipboard, images and the rest),
`sparkles.input.capability.InputCapabilities` (the input axes, `IXB10`), and
the target-only axes (`subCellScroll`, `proportionalText`,
`radius`/`shadow`/`alpha`, `reducedMotion`). A terminal's two halves come from
one `TermCaps` snapshot (`caps.output`, `fromTerminal(caps)`); a window or HTML
sink declares constants. This is the chrome half that
[`TGT5`](../ui/backends.md) left in prose (D25).

**CAP2 notes.** Violation: a projection rule in [glyphs.md](./glyphs.md), or a
component's degradation prose, naming a capability with no field.

**CAP3 notes.** The environment-derived answers read `$TERM`, `$COLORTERM`,
`$NO_COLOR`, `$TERM_PROGRAM` and tmux or screen presence. The query battery asks
for kitty graphics, the kitty keyboard flags, `DECRQM` 2004/2026/2027/2031/1004,
`XTGETTCAP` `RGB`/`Tc`/`Smulx`/`Setulc`, `XTVERSION`, the cell size
(`CSI 16 t`), a test cluster's width by cursor report, and ends with a DA1
fence. One mapping applies the replies to `TermCaps`: depth, synchronized
output, grapheme clustering (mode 2027 or the measured width, D38), scheme
reports, images, cell pixel size, and styled underlines where both `Smulx` and
`Setulc` answered (D41). Links, clipboard, notifications and pointer shape follow
the name the terminal gives in `XTVERSION`, through a cited table (D42).
`Terminal.probe` runs by default (D39). Input-mode answers are applied only
where negotiated (D35): focus reports, bracketed paste, colour-scheme reports
(`INP22`, D37) and grapheme clustering where the terminal answered `reset`.
Paste and focus decode to `FocusEvent` and `PasteEvent` chunks (`INP21`, D36).
A test per row verifies the implementation against a scripted pty peer
([`testing.md` O5](./testing.md)). The `O5` corpus holds the battery's own
replies from kitty 0.48.2, Ghostty 1.3.1, foot 1.25.0, XTerm 403,
Alacritty 0.16.1, and tmux 3.6a and zellij 0.45.1 each under a bare pty, foot
and Ghostty, captured headless in `libs/base/test/data/term_replies/`.

**CAP4 notes.** This restates the [`THM8`](../ui/theme.md) warning as a
contract. One process rendering a cell target and an HTML target from the same
theme produces ASCII borders on the first only if the first declared
`unicode = false`, and never affects the second. Violation: the parity harness
rendering ASCII chrome into HTML because stdout was not a tty.

**CAP5 notes.** The style guide shows all three profiles, and
`ui-gallery --render --profile <p>` produces them.

**CAP6 notes.** The substitution names which glyph set, which attribute, or
which fallback-ladder rung was drawn, the way anchored overlays report their
triggers ([`TRG3`](../ui/popup.md)). Violation: a feature the theme requested
that neither renders nor appears in the report.

**CAP7 notes.** A multiplexer is recognised by `$TMUX`, `$STY`, or
`TERM=screen*`/`tmux*`. The capabilities at risk are images, OSC 52 without
`set-clipboard`, OSC 66, mode 2031 and the kitty keyboard.

**CAP8 notes.** Output to a pipe carries no escape sequence the profile
forbids.

**CAP10 notes.** The mapping is `fromReplies` over
`base.term_replies.applyReplies` (D35). The battery asks about color depth,
modes 2004, 2026, 2027 and 2031, the kitty keyboard and graphics protocols, and
the DA1 sixel attribute; the shared floor is D32's, and everything else stays
off. Presets form a partial order, not a ladder, and narrowing to one is
`meet`. `ui-gallery --emulator <e>` paints for one, and the live profile switch
narrows within it.

## The capability table

One row per field of `TargetCapabilities`. _Detects_ names the owner of the
answer for the TUI target; GUI and HTML targets declare constants. _Consumed
by_ names what degrades; the row exists only because of that column (`CAP2`).

The **output** rows are fields of `OutputCapabilities` in `sparkles:base`. A
logger or a plain CLI tool needs `hyperlinks` and `progress` as much as a
full-screen UI does, and none should link a toolkit to ask. The **`input.*`**
rows are `InputCapabilities` axes that a terminal derives from its negotiated
modes through `fromTerminal`: the mode is the terminal's fact, the axis is the
target-neutral one, and only the axis is consumed. The remaining rows exist
only on `TargetCapabilities`.

| Field                       | Meaning                                                           | Protocol / source                                                              | Detects        | Consumed by                                                                            |
| --------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------- | -------------------------------------------------------------------------------------- |
| `colorDepth`                | `none` / `ansi16` / `ansi256` / `trueColor`                       | SGR 38/48; `$COLORTERM`, `$TERM`                                               | `base`         | every color token; `ACC3` marks below `ansi256`                                        |
| `unicode`                   | non-ASCII glyphs at all                                           | locale, `$TERM`                                                                | `base`         | `GLY1` charset floor                                                                   |
| `blocks`                    | block-element tier: `none`/`half`/`quadrant`/`sextant`/`octant`   | font coverage; unknowable by query — configured, default `half` when `unicode` | config, `tui`  | sub-cell rules and thumbs (`GLY2`, `GLY8`), image raster rung (`GLY9`)                 |
| `braille`                   | U+2800 block renders as a 2×4 grid                                | font coverage; configured                                                      | config         | sparklines/charts (`GLY8`)                                                             |
| `nerdFont`                  | Nerd Font PUA glyphs available                                    | unknowable by query — configured; `true` on GUI/Web (bundled)                  | config         | icons, tree guides, powerline separators (`GLY4`)                                      |
| `hyperlinks`                | OSC 8                                                             | `XTVERSION` name, `knownTerminals` (D42)                                       | `base` + `tui` | `link.*` (`WGT21`), `osc_link.d`                                                       |
| `clipboard`                 | OSC 52 write                                                      | `XTVERSION` name, `knownTerminals` (D42)                                       | `tui`          | copy affordances (hue `TSL`)                                                           |
| `notifications`             | OSC 99 (kitty), OSC 9 / 777 fallbacks                             | `XTVERSION` name, `knownTerminals` (D42)                                       | `tui`          | toast (`WGT16`) out-of-focus escalation                                                |
| `pointerShape`              | OSC 22                                                            | `XTVERSION` name, `knownTerminals` (D42)                                       | `tui`          | hover cursors on links, splitters, text                                                |
| `textSizing`                | the terminal honours OSC 66 (kitty text sizing)                   | query (kitty ≥ 0.40, foot); Ghostty: none                                      | `tui`          | headings (`GLY5`), at base/text's scaled cell footprints; layout-preserving fallback   |
| `images`                    | `none` / `kitty` / `sixel` / `iterm2` / `pixels` (a window's own) | DA1 sixel bit; kitty query; `$TERM_PROGRAM`; a GUI declares `pixels`           | `tui`          | `WGT22` image ladder (`GLY9`); `pixels` is the top of the order (D34)                  |
| `syncOutput`                | mode 2026 synchronized output                                     | DECRQM 2026                                                                    | `tui`          | frame emission (tear-free); required for smooth-scroll rungs                           |
| `input.maxPointers`         | SGR 1006 button events ⇒ one pointer                              | `TermCaps.mouseSgr`                                                            | `tui`          | pointer tier (`INP`)                                                                   |
| `input.hover`               | mode 1003 any-motion ⇒ hover                                      | `TermCaps.anyMotion`: set where 1003 was asked for (D44)                       | `tui`          | `hover` interaction state (`TOK4`)                                                     |
| `input.precisePointer`      | mode 1016 pixel coordinates ⇒ sub-cell positions                  | `TermCaps.pixelMouse` (DECRQM 1016); off on a terminal (D45)                   | `tui`          | none on a terminal (D45)                                                               |
| `input.keyRelease`          | kitty keyboard protocol (CSI u) release/repeat                    | `TermCaps.kittyKeyboard`: flag 2, where asked and `CSI ? u` answered (D44)     | `tui`          | held-key interactions (`INP16`)                                                        |
| `input.focusEvents`         | mode 1004 ⇒ focus in/out events                                   | `TermCaps.focusReporting` (DECRQM 1004)                                        | `tui`          | blur dimming, `chromeFocused`                                                          |
| `input.pasteEvents`         | mode 2004 ⇒ a paste is one event                                  | `TermCaps.bracketedPaste` (DECRQM 2004)                                        | `tui`          | text input (`WGT14`)                                                                   |
| `colorSchemeNotify`         | mode 2031 / OSC 11 query                                          | DECRQM 2031; OSC 11 reply                                                      | `tui`          | scheme auto-select (deferred to `sparkles:appearance`)                                 |
| `progress`                  | OSC 9;4 (ConEmu / Windows Terminal)                               | `$TERM_PROGRAM`, `$WT_SESSION`                                                 | `base`         | meter (`WGT19`) taskbar mirror                                                         |
| `extendedUnderline`         | SGR 4:3 curly + 58 underline color                                | XTGETTCAP `Smulx` and `Setulc` (D41)                                           | `tui`          | diagnostics undercurl, `link.underline` (`plain-underline`)                            |
| `cellPixelSize`             | CSI 16 t answers                                                  | query                                                                          | `tui`          | image scaling, sub-cell geometry                                                       |
| `graphemeClusters`          | a cluster laid out as one character                               | DECRQM 2027; a test cluster's width by cursor report (D38)                     | `tui`          | the grid's width profile: `terminalKitty` whole, `terminalUnclustered` folded (`GLY6`) |
| `subCellScroll`             | scroll offsets finer than a cell                                  | GUI/Web constant                                                               | —              | `ScrollView` smooth scrolling                                                          |
| `proportionalText`          | a non-monospace face for `FontRole.docs` and `FontRole.ui`        | GUI: the host, when it loaded the interface faces; Web constant                | —              | docs paragraphs inside cell rects (`GLY7`); the chrome type scale (`GLY10`)            |
| `radius`, `shadow`, `alpha` | sub-cell box chrome honoured                                      | GUI/Web constant                                                               | —              | `TOK7` honour-or-project declaration                                                   |
| `input.tier`                | the interaction ladder                                            | a tty is `interactive`; a pipe `passive`                                       | `fromTerminal` | unchanged                                                                              |
| `reducedMotion`             | the user prefers no animation                                     | a flag or environment variable; the OS preference is deferred                  | host           | `ACC5`                                                                                 |

`textSizing` answers only whether the terminal honours OSC 66
([OQ5](./decisions.md#open-questions)). The footprint a scaled run occupies, its
integer scale and fractional width, is base/text's scaled grid-cell footprint
([`TXT-SIZE1`–`TXT-SIZE5`](../base/text/SPEC.md#_6-4-scaled-grid-cell-footprints)),
so the design system and the grid agree on the cells a heading consumes (D54).
`graphemeClusters` selects base/text's
[width profile](../../glossary.md#width-profile) for the grid. Both profiles
have the same advances and differ only in emission: `terminalKitty` emits a
cluster whole, `terminalUnclustered` folds it to its leading scalar padded to
the clustered advance (base/text `TXT-CELL5`, `GLY6`, D50).

## Capability profiles

| Capability profile | Intent                                                                | Flag values                                                                                                                                             |
| ------------------ | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `baseline`         | a pipe, `TERM=dumb`, a serial console: usable in monochrome and ASCII | `colorDepth = none`, `unicode = false`, everything else `false`/`none`; `tier = static`                                                                 |
| `enhanced`         | any xterm-compatible emulator of the last decade                      | `ansi256`, `unicode`, `blocks = half`, `mouse`, `bracketedPaste`, `focusEvents`, `hyperlinks`; no images, no text sizing, no kitty keyboard             |
| `full`             | kitty / Ghostty / WezTerm / foot with a Nerd Font                     | `trueColor`, `blocks = octant`, `braille`, `nerdFont`, every OSC and mode row `true`, `images = kitty`, `syncOutput`, `keyRelease`, `extendedUnderline` |

## Emulator presets

Each preset is read by `fromReplies` (`CAP10`) from the rows recorded for it,
through the mapping a live probe uses. Where the `O5` corpus reaches — kitty,
Ghostty, foot, XTerm, Alacritty, and tmux and zellij under a bare pty, foot
and Ghostty — a row is the battery's own replies as that terminal sent them
(`libs/base/test/data/term_replies/`), generated from the recording and
re-read against it by test. iTerm2, Apple Terminal and WezTerm keep their rows
from the capability case study's
[empirical response matrix (§16)](https://github.com/PetarKirov/sparkles/blob/9ee7df44ef8870dea57925c057ca939a0764b502/docs/research/tui-libraries/capability-detection-case-study.md),
an earlier battery that did not ask about focus, the cell size or a cluster's
width.

Grapheme clustering is either answer (D38). kitty and tmux do not recognize mode
2027 and lay a ZWJ family out in two cells all the same, while zellij lays it
out in six under every host, clustering ones included. Every preset also has
Unicode, the half blocks and an SGR cell mouse with hover (D32). No preset has
braille, octants or Nerd Font icons, because no query answers them.

Links, clipboard writes, notifications and the pointer shape come from the name
a row's terminal answered `XTVERSION` with (D42). kitty, Ghostty and foot have
all four, and XTerm the pointer shape; tmux and zellij answer for themselves,
and Alacritty gives no name. Styled underlines are claimed only where
`XTGETTCAP` answers both `Smulx` and `Setulc` (D41): kitty, Ghostty and foot.

| Preset           | Measured                               | Color | Sync (2026) | Graphemes (D38) | Scheme (2031) | Images | Paste (2004) | Focus (1004) | Cell size | Key release | Styled underline | By name (D42) |
| ---------------- | -------------------------------------- | ----- | ----------- | --------------- | ------------- | ------ | ------------ | ------------ | --------- | ----------- | ---------------- | ------------- |
| `xterm`          | XTerm 403, Linux                       | 24bit | —           | —               | —             | —      | ✓            | ✓            | ✓         | —           | —                | pointer shape |
| `apple-terminal` | Apple Terminal, macOS 26.3             | 24bit | —           | —               | —             | —      | —            | not asked    | not asked | —           | not asked        | not asked     |
| `iterm2`         | iTerm2 3.6.10                          | 24bit | ✓           | —               | ✓             | kitty  | ✓            | not asked    | not asked | ✓           | not asked        | not asked     |
| `alacritty`      | Alacritty 0.16.1                       | 24bit | ✓           | —               | —             | —      | ✓            | ✓            | —         | ✓           | —                | —             |
| `foot`           | foot 1.25.0                            | 24bit | ✓           | ✓               | ✓             | sixel  | ✓            | ✓            | ✓         | ✓           | ✓                | all four      |
| `wezterm`        | WezTerm 2025-10-14                     | 24bit | ✓           | ✓               | —             | kitty  | ✓            | not asked    | not asked | —           | not asked        | not asked     |
| `kitty`          | kitty 0.48.2                           | 24bit | ✓           | ✓               | ✓             | kitty  | ✓            | ✓            | ✓         | ✓           | ✓                | all four      |
| `ghostty`        | Ghostty 1.3.1                          | 24bit | ✓           | ✓               | ✓             | kitty  | ✓            | ✓            | ✓         | ✓           | ✓                | all four      |
| `tmux`           | tmux 3.6a: bare pty, foot, Ghostty     | 24bit | —           | ✓               | ✓             | —      | ✓            | ✓            | ✓         | —           | —                | —             |
| `zellij`         | zellij 0.45.1: bare pty, foot, Ghostty | 24bit | ✓           | —               | ✓             | —      | —            | —            | —         | ✓           | —                | —             |

A **multiplexer** answers for itself, and some of its answers follow the
terminal it is attached to (D33). tmux lists sixel in DA1 under every host,
Ghostty included, which draws no sixel. Under a multiplexer that attribute is
therefore an advertisement, not a confirmed passthrough, and `CAP7` drops it.
zellij answers the kitty graphics query `OK` in Ghostty and refuses it in foot:
a real round trip, which counts. A multiplexer's preset is what holds under
every host it was measured in (their `meet`), so neither claims images.

Two matrix rows take no preset: the bare pty (no emulator, which is `baseline`)
and GNU screen 4.00.03, a 2006 build below the shared floor. Windows Terminal
and the Linux console are unmeasured; a row for a terminal is one
`query-probe.d --raw` run in it.

GUI and HTML targets are not capability profiles; they declare their own
constants. `subCellScroll`, `proportionalText`, `radius`, `shadow` and `alpha`
are on, and the terminal-protocol rows are meaningless and `false`.

→ [Overview](./index.md) · [Specification](./SPEC.md) · [Glyphs](./glyphs.md)
