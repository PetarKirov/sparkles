---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Decisions and open questions

## Abstract

This page records the choices behind the `sparkles:ui` design system: for each,
the question, the alternatives weighed, the choice, the condition under which it
should be reopened, and its state. It also lists the questions still open. The
requirements cite these rows by ID, so a reader can find why a rule exists
before changing it.

## Introduction

A decision's state is `proposed`, `accepted` or `superseded`: a decision state,
not an implementation state. Rows marked `accepted` were accepted by the
repository owner: the scoping rows in the scoping session of 2026-09-20/21 that
produced this specification, and D49–D54 on 2026-10-05. Rows marked `proposed` were
made while delivering a milestone and await the owner's acceptance.

D50–D54 decide what the design system owns and what it consumes from
`sparkles:base` ([base/text](../base/text/SPEC.md)), the
[font library](../font/SPEC.md) and [text layout](../text-layout/SPEC.md):
width profiles and long clusters, wrapping, the glyph channel's width,
proportional paragraphs, scaled footprints and font roles.

A choice cell states the outcome; where the reasoning needs more than a
sentence, it follows the table as a note keyed by the decision's ID. Open
questions follow the notes. The requirements live in [SPEC.md](./SPEC.md) and
its sibling pages, and delivery order in [PLAN.md](./PLAN.md).

## Decisions

| ID  | Question                                                                                                                | Alternatives                                                                                                                                                                                               | Choice                                                                                                                                                                                                            | Revisit when                                                                                                                   | State    |
| --- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | -------- |
| D1  | What is the deliverable?                                                                                                | spec only; style guide only; code only                                                                                                                                                                     | spec (`docs/specs/design-system/`) **and** public style guide **and** code (token types in `sparkles:ui`) **and** a DTCG file format; lockstep tests where a mirror exists                                        | —                                                                                                                              | accepted |
| D2  | One design language, or a framework for many?                                                                           | one Sparkles look parameterised by scheme; a Textual-CSS-style framework where any theme restyles all chrome                                                                                               | **both**: a framework for expressing design systems as data (a `hue` user swapping themes at runtime) and one concrete design system, **Sparkles**                                                                | —                                                                                                                              | accepted |
| D3  | Where does the Sparkles brand start?                                                                                    | derive from the docs site's indigo/cyan accent; evolve "Midnight Aurora" by hand; start from scratch                                                                                                       | **from scratch**: the site look is interim, not a seed                                                                                                                                                            | —                                                                                                                              | accepted |
| D4  | Docs sites and the brand                                                                                                | VitePress keeps its own look; VitePress follows Sparkles                                                                                                                                                   | both docs sites (VitePress and `sparkles:docs`) **follow Sparkles**; the framework declares the CSS custom properties, Sparkles defines their values                                                              | —                                                                                                                              | accepted |
| D5  | Token structure                                                                                                         | flat slots; primitive→semantic→component tiers                                                                                                                                                             | **semantic and component tiers** (primitives permitted underneath); components declare the slots they use as data                                                                                                 | —                                                                                                                              | accepted |
| D6  | Interaction state                                                                                                       | extra slots per state; a state dimension on resolution                                                                                                                                                     | **a dimension** with a fixed precedence (`TOK5`)                                                                                                                                                                  | a state that cannot be expressed as an override of `rest`                                                                      | accepted |
| D7  | Units                                                                                                                   | cells only; px only; both with per-target declaration                                                                                                                                                      | **cell is universal**; px-typed metrics carry a defined projection and a target declares honour/project (`TOK7`)                                                                                                  | —                                                                                                                              | accepted |
| D8  | Capability model                                                                                                        | three tiers as data; per-feature flags                                                                                                                                                                     | **flags as data, tiers as documented capability profiles** (`CAP1`, `CAP5`)                                                                                                                                       | —                                                                                                                              | accepted |
| D9  | Undetectable capabilities                                                                                               | scope the design system to what `TermCaps` answers; let the spec run ahead                                                                                                                                 | the spec **may** name any capability, **and** `TermCaps`/`sparkles:tui` are extended to answer every one (`CAP3`); the design system declares intent, the libraries implement, tests verify                       | —                                                                                                                              | accepted |
| D10 | Nerd Font                                                                                                               | baseline everywhere; optional everywhere; pin a specific release                                                                                                                                           | **baseline on GUI/Web, optional on TUI**; the version is **whatever the flake's pinned nixpkgs ships** (3.5.0 when decided), with no separate pin (`GLY4`)                                                        | a nixpkgs bump that moves code points (regenerate the icon table)                                                              | accepted |
| D11 | Themes below the contrast floors                                                                                        | fail the build; auto-nudge tones at resolve time; tag                                                                                                                                                      | **tag, don't fail**: only Sparkles (and themes declaring `required`) must pass (`ACC2`)                                                                                                                           | —                                                                                                                              | accepted |
| D12 | DTCG's role                                                                                                             | export only; authoring + interchange; defer                                                                                                                                                                | **authoring + interchange**: DTCG is `THM9`'s file format, loaded via `sparkles:wired` (`FMT`). The edition to pin is the DTCG stable format at first-loader time                                                 | the loader lands (pin the edition here)                                                                                        | accepted |
| D13 | Cells in DTCG                                                                                                           | `dimension` with a non-standard unit; `$extensions` unit; `number`                                                                                                                                         | **`number` for cell metrics**, `dimension`/`px` for px metrics (`FMT1`)                                                                                                                                           | DTCG adds a generic unit                                                                                                       | accepted |
| D14 | Syntax rules in DTCG                                                                                                    | `typography` composite; `color` + attrs extension                                                                                                                                                          | `color` tokens with `$extensions.dev.sparkles.attrs` (`FMT6`), a **hypothesis** until the loader exists                                                                                                           | first loader                                                                                                                   | proposed |
| D15 | Border weight on cells                                                                                                  | always a 1-cell light rule; weight → glyph set; sub-cell via block elements                                                                                                                                | **weight → glyph set for boxes, and sub-cell edges via block elements for rules/thumbs** (`GLY2`, `GLY2a`)                                                                                                        | —                                                                                                                              | accepted |
| D16 | Where do application-domain tokens live?                                                                                | an open slot registry apps extend; a closed enum in `sparkles:ui` with domain namespaces                                                                                                                   | **closed enum with domain namespaces** (`TOK10`): the display list needs a closed index                                                                                                                           | a third application domain wants its own tokens                                                                                | accepted |
| D17 | Which application is the reference?                                                                                     | hue; ui-gallery; a new app                                                                                                                                                                                 | **`ui-gallery`, in the Storybook role**: its `--render` output is the style guide (`O1`)                                                                                                                          | —                                                                                                                              | accepted |
| D18 | Consumer order                                                                                                          | hue first; docs first                                                                                                                                                                                      | **`ui-gallery` and the docs site first**, `hue`/`diagram` after, OS-following (`sparkles:appearance`) last                                                                                                        | —                                                                                                                              | accepted |
| D19 | Target order                                                                                                            | GUI first (richest); Web first (best practice)                                                                                                                                                             | **TUI → responsive Web → GUI → mobile**; nothing out of scope, only sequenced                                                                                                                                     | —                                                                                                                              | accepted |
| D20 | Keyboard                                                                                                                | cite `KEY` only; own a full HIG                                                                                                                                                                            | **own a minimal default vocabulary** as one overlay table (`KBD`)                                                                                                                                                 | —                                                                                                                              | accepted |
| D21 | Detection ownership                                                                                                     | one probing module; split by source                                                                                                                                                                        | environment-derived answers in `sparkles:base`, query-derived in `sparkles:tui` (`CAP3`); `base` **must not** grow a pty conversation                                                                             | —                                                                                                                              | accepted |
| D22 | May a state override change metrics?                                                                                    | colors/attributes only; metrics too                                                                                                                                                                        | **metrics too** (`TOK5`): a pressed inset or a hover-widened thumb is a state, and a relayout is the cost                                                                                                         | a metric override that cannot be expressed as a per-frame relayout                                                             | accepted |
| D23 | Brand exercise before or after the code migration?                                                                      | design first, so the code has real values; migrate first, so the exercise has real components                                                                                                              | **code migration (M1–M3) first**; the Sparkles values are designed against rendered components                                                                                                                    | —                                                                                                                              | accepted |
| D24 | `BorderStyle.double`                                                                                                    | leave the enum at solid/dotted/dashed; add `double_`                                                                                                                                                       | **added** (`double_`, since `double` is a keyword): `═║╔╗╚╝` on cells, CSS `double` in HTML, two nested strokes on the GPU (`doubleBorderEdges`)                                                                  | —                                                                                                                              | accepted |
| D25 | Unify `TermCaps` and `TargetCapabilities`?                                                                              | one struct in `ui`; one struct in `base`; a shared core factored into `base`                                                                                                                               | **shared core**: `OutputCapabilities` lives in `base`, `TermCaps` embeds it, and `TargetCapabilities` composes it with `InputCapabilities`                                                                        | a capability that is neither emit nor input nor target-only                                                                    | accepted |
| D26 | What does a canvas nobody declared anything to paint for?                                                               | the conservative `.init` (`CAP1`'s rule); the canvas's own reach                                                                                                                                           | **its own reach** for the grid (`gridCapabilities`); `.init` stays the answer for a target that declares nothing through `declaredCapabilities`                                                                   | —                                                                                                                              | accepted |
| D27 | The live TUI's rows no probe answered                                                                                   | declare them `false`; keep the existing output until the probe                                                                                                                                             | **keep the existing output**, each a named debt in `sessionCapabilities` that its M7 probe row removes                                                                                                            | each M7 probe row                                                                                                              | accepted |
| D28 | Where is the degradation report computed?                                                                               | by each painter as it paints; from the display list and the declaration                                                                                                                                    | **from `(ops, caps)`** (`degradationsOf`), target-neutral and testable without a backend; each row is paired with a test that the grid painter does what the row claims                                           | a substitution only a painter can know about                                                                                   | accepted |
| D29 | How does the TUI learn `nerdFont` (`OQ1`)?                                                                              | config + `$NERD_FONT`-style env + flag; a font probe; opt-in only                                                                                                                                          | **opt-in only**: `nerdFont` is `false` on a terminal until the application's own configuration says otherwise                                                                                                     | a de-facto environment signal emerges                                                                                          | accepted |
| D30 | Where are glyphs capped — in components, or at the canvas?                                                              | each component picks per target; the canvas projects every glyph                                                                                                                                           | **at the canvas** (`projectGlyph` in the painter): a component asks for the richest glyph it wants, and one ladder caps it per target at paint time                                                               | a glyph whose fallback depends on context (a meter fill vs an accent bar)                                                      | accepted |
| D31 | A border both heavy and rounded, on a cell target                                                                       | keep the weight (heavy, square) and lose the radius; keep the radius (light arcs) and lose the weight                                                                                                      | **the radius wins**, reported as `weight-dropped`                                                                                                                                                                 | a heavy-arc glyph set in fonts                                                                                                 | accepted |
| D32 | What may an emulator preset claim?                                                                                      | every flag the emulator is known to support; only what the query battery measured; the measured flags over a shared floor                                                                                  | **the measured replies over a shared floor** (`CAP10`): a preset may show less than its emulator can, never more                                                                                                  | the M7 probes answer a column the battery does not (links, OSC 52, focus)                                                      | proposed |
| D33 | What does a multiplexer's preset claim, when its answers depend on the host terminal?                                   | the row measured detached; one preset per multiplexer × host; the meet over every host measured                                                                                                            | **the meet over every host measured**, and under a multiplexer DA1's sixel attribute is not a passthrough (`CAP7`)                                                                                                | a multiplexer whose DA1 tracks its host, or M7's probe running under one                                                       | proposed |
| D34 | A window draws images itself: what does it declare for `images`, and what is a window narrowed to a capability profile? | `none` (the vocabulary is terminal protocols); a separate `rasters` flag; a new `pixels` member                                                                                                            | **`ImageProtocol.pixels`, the top of the image order**; protocols stay mutually unordered                                                                                                                         | a target that composites some formats natively but not others                                                                  | proposed |
| D35 | How do a probe's answers become a declaration, for a live terminal and for a preset?                                    | a mapping per consumer; one mapping for everything, input modes included; one mapping for what may be emitted, input modes to the negotiator                                                               | **one mapping for what may be emitted** (`base.term_replies.applyReplies`), shared by the live probe and the presets; input-mode answers are applied only by whoever negotiates the mode                          | a terminal session that negotiates paste or focus                                                                              | proposed |
| D36 | How does a bracketed paste travel through `sparkles:input`? (was OQ8)                                                   | a `string` in the event; a reference-counted `SharedBuffer`; a handle into a paste store; a bracket of markers around key events; inline chunks                                                            | **inline chunks** (`INP21`): `PasteEvent { InlineBuffer!(char, 40) text; bool last; }`, split between code points                                                                                                 | a consumer that needs the whole paste at once more often than chunk by chunk                                                   | proposed |
| D37 | When the surface switches scheme, what does a theme become?                                                             | a naming rule (`-dark` ↔ `-light`); a light/dark field on every theme; a sibling table                                                                                                                     | **a sibling table as data** (`sparkles.ui.theme_schemes`), each pair checked against the themes' own backgrounds                                                                                                  | the themes carry their own sibling (the Sparkles theme file, M5)                                                               | proposed |
| D38 | How does a probe learn whether the terminal clusters graphemes?                                                         | the mode 2027 answer; a test cluster's width by cursor report; either                                                                                                                                      | **either**: 2027 available, or a ZWJ family printed at the line's start comes back two cells wide (`CSI 6 n`, in the battery before the DA1 fence)                                                                | a terminal whose cluster width depends on the cluster, not on clustering                                                       | proposed |
| D39 | Is the probe opt-in or on by default?                                                                                   | opt-in per application; on by default with an opt-out                                                                                                                                                      | **on by default** (`RunConfig.probeTerminal`, `TerminalRequest.probe`); a harness that owns the byte stream turns it off                                                                                          | a host where the battery's bytes are visible (a terminal that prints unknown queries, like Apple Terminal, is already skipped) | proposed |
| D40 | What visible consumer degrades when `syncOutput` is off?                                                                | gate the 2026 markers on the flag; a visible substitution; none                                                                                                                                            | **none, by design**: the frame markers are always written                                                                                                                                                         | a terminal that prints or misreads the markers                                                                                 | proposed |
| D41 | What vouches for styled underlines (`extendedUnderline`)?                                                               | `$TERM_PROGRAM` or `$TERM` names; a DECRQSS round-trip after setting SGR `4:3`; `XTGETTCAP` `Su`; `XTGETTCAP` `Smulx` and `Setulc`                                                                         | **`Smulx` and `Setulc`, both answered**; unanswered means straight, in the text's colour                                                                                                                          | a multiplexer that relays the host's `XTGETTCAP`, or an emulator that draws styled underlines and answers neither name         | proposed |
| D42 | How are the rows no query answers (links, clipboard, notifications, pointer shape) decided?                             | a `$TERM_PROGRAM` allow-list; keep emitting as long as it is harmless; the user opts in; the terminal's own `XTVERSION` name through a table                                                               | **the `XTVERSION` name through a cited table** (`base.term_identity.knownTerminals`), counting only default configurations                                                                                        | a terminal that answers `XTVERSION` with another's name; an emulator added to the corpus that needs a row                      | proposed |
| D43 | How do the clipboard, pointer-shape and notification rows degrade visibly?                                              | gate every sequence on its row; send everything and ignore the rows; per errand                                                                                                                            | **per errand**: the pointer shape is gated, the clipboard write is not but the row decides what the user is told, and notifications wait for an application that needs one                                        | an application that needs a desktop notification; a terminal whose OSC 52 write does harm                                      | proposed |
| D44 | How are key releases and hover decided on a terminal?                                                                   | assume neither (a tty has no key-up, `INP16`); probe each; negotiate what the application asks for                                                                                                         | **negotiate what the application asks for**: kitty flag 2 where releases were asked for and the protocol was found; hover exactly where 1003 was asked for                                                        | a terminal that recognizes 1003 and sends no motion; an application that wants releases without the kitty protocol             | proposed |
| D45 | Does a terminal declare `precisePointer` where it can report pixel coordinates (mode 1016)?                             | negotiate 1016 and decode pixels into cells plus a remainder; switch the TUI arm to `PointerUnit.pixels` where an application asks for pixels; leave it off until a terminal consumer needs sub-cell input | **off, until a consumer needs it**                                                                                                                                                                                | a terminal component that hit-tests below a cell (a pixel-thumb scrollbar, a canvas drawn with sixel or kitty images)          | proposed |
| D46 | What does a per-state override hold, when components report states instead of swapping slots?                           | literal colours (and attributes) per state; an alias to another slot (and attributes); either                                                                                                              | **an alias to another slot, per channel, plus attributes** (`Palette.stateAlias`, `StateColors.attrs`)                                                                                                            | a state whose look is no other slot's (then a literal per channel, which `StateColors` still carries)                          | proposed |
| D47 | Is `Space` universal when an application also needs it as a leader or a pan key?                                        | one meaning everywhere (no leader on `Space`); per application; a fixed row set plus focus rows owned by the focused control                                                                               | **fixed rows plus focus rows**: `Enter` and `Space` act on the focused control where it has those actions, and the application **may** bind them otherwise                                                        | an application whose focused control and its own `Space` binding both claim the key at once                                    | proposed |
| D48 | Who handles `Ctrl-C` on a terminal, where raw mode turns `ISIG` off?                                                    | every application binds it to quit; the host restores `ISIG`; the host quits on it unless the keyboard is grabbed                                                                                          | **the host quits on it, unless the keyboard is grabbed** (`HostState.grabKeyboard`); applications never bind it                                                                                                   | an application that must confirm before quitting (unsaved work), which would need the interrupt delivered as a request         | proposed |
| D49 | What face does an application's own chrome draw in?                                                                     | the cell font everywhere (cells are universal, `TOK7`); a proportional interface face at a type scale where the target has one                                                                             | **a proportional interface face** (`FontRole.ui`, `GLY10`) at four steps in density-independent px; layout stays in cells                                                                                         | a target that can shape proportional text without cells                                                                        | accepted |
| D50 | How does the grid draw a cluster on a terminal that does not cluster, and a cluster longer than a cell holds?           | a toolkit fold beside base's widths; a per-scalar compatibility helper in base; a named per-scalar width profile. Long clusters: truncate; fold; overflow storage                                          | **a named width profile and overflow storage**: such a terminal is driven under base/text's `terminalUnclustered`, which expresses the fold (`GLY6`); a long cluster is kept whole and exhaustion fails (`GLY12`) | a terminal whose cluster width depends on the cluster, not on clustering (D38); a grid cell model without inline bytes         | accepted |
| D51 | Who owns text wrapping: base or the toolkit?                                                                            | the toolkit's breaker (`sparkles.ui.wrap`), since the measurer is caller-supplied; base's solvers and cell wrapping under the toolkit's policy                                                             | **base owns the pure solvers and cell wrapping** (base/text `WRAP-BOUND1`); `LAY10` and `LAY14` keep the policy and call base                                                                                     | a wrapping policy that base's solver interface cannot express                                                                  | accepted |
| D52 | Does a width profile's ambiguous-width choice apply to the glyph channel?                                               | apply it to every character; exempt the glyph channel                                                                                                                                                      | **exempt the glyph channel**: it is one grid cell under every width profile, and base/text names the exempt set by range (`GLY3`)                                                                                 | a terminal that draws a glyph-channel character wide under its ambiguous-wide setting                                          | accepted |
| D53 | Who lays out proportional docs text in a window (`GLY7`)?                                                               | an interim implementation in `raylib-text`; text-layout's `shapedFlow` paragraph                                                                                                                           | **text-layout**: a `shapedFlow` paragraph inside the widget's cell rect, gated on text-layout TL-M3; no interim implementation                                                                                    | text-layout cannot lay out a docs paragraph within a frame                                                                     | accepted |
| D54 | Who owns scaled text footprints, and what is a font role's value?                                                       | footprints computed by the design system; footprints in base/text. Roles as a family name; roles in the font library; roles in the design system as request, chain and routes                              | **footprints in base/text; roles in the design system**, each role's value a font request, a fallback chain and code-point routes                                                                                 | a role that needs something a request, a chain and routes cannot express                                                       | accepted |

## Notes

**D10.** 3.5.0 was the version nixpkgs shipped at the flake's pin when the
decision was made.

**D13.** DTCG's `dimension` allows only `px` and `rem`, and a non-standard unit
would fail every off-the-shelf tool.

**D25.** `OutputCapabilities` names the emit affordances abstractly and lives in
`base` beside `ColorDepth`. `TermCaps` embeds it (`alias this`) plus the raw
terminal input modes. `InputCapabilities` gains `focusEvents`/`pasteEvents` and
`fromTerminal`, the one modes-to-axes adapter. `TermCaps.colors` becomes a view
of `colorDepth` (`PRN9`: no cached second opinion).

**D26.** The grid's own reach is Unicode, true color, links and styled
underlines, so every existing `paintGrid` caller is unchanged.

**D27.** Input stayed `TerminalSession.capabilities`, and `hyperlinks` and
`extendedUnderline` stayed on while color was. Declaring them off before a probe
answered would have regressed every capable terminal.

**D29.** No environment variable is a standard, and a wrong `true` paints `?`
where a Unicode mark would have read. The mark ladder makes `false` cheap: a
Nerd Font icon a theme asks for lands on its Unicode mark.

**D30.** `CAP4` keeps the theme and the widget tree target-free, and a
component cannot forget to degrade.

**D31.** The shape is what identifies a panel. Every rounded `hue` panel
(picker, settings, DSV columns) is 2 px so the window strokes it visibly; in a
terminal they stay `╭╮╰╯`.

**D32.** The floor is what `enhanced` already assumes of any emulator of the
last decade: Unicode, the half blocks, an SGR cell mouse with hover, and nothing
else. Every protocol flag comes from a reply or stays off. The replies are
stored verbatim and mapped by `fromReplies`, which reads answers, not names, so
the M7 probes feed the same function.

**D33.** tmux 3.6a lists sixel in DA1 inside Ghostty, which draws no sixel,
while zellij 0.45.1's kitty-graphics answer follows its host (`OK` in Ghostty,
refused in foot) because it is a round trip. The preset is what an application
may assume without knowing the host; the host-dependent claims are the runtime
probe's to make.

**D34.** A window's own pixels reach whatever a protocol does, so
`meet(pixels, kitty)` is `kitty`. A window previewing `full` still draws the
real image, while one previewing `enhanced` meets to `none` and draws the cell
raster the terminal would, by the same routine. One field keeps `GLY9`'s rung a
function of the declaration alone.

**D35.** The shared mapping covers depth, sync, graphemes, scheme reports,
images and cell size, so a preset is what the probe would declare. Input-mode
answers (bracketed paste, focus, the kitty keyboard) are recorded, because
`TermCaps`' mode fields mean negotiated; when this was decided, the terminal
enabled neither 2004 nor 1004, while a preset previews an application that
would. Late replies are the input decoders' to drop: a control string is never
a keystroke.

**D36.** `Event` stays pointer-free and at 64 bytes: a `string` and a
`SharedBuffer` both made `SumType` assignment `@system` (measured). The choice
follows the native window layer's own pattern for committed text, and a paste
of any length is more chunks. Mode 2004 is then negotiated like 1004 (D35).

**D37.** The built-ins pair up only loosely by name (`rose-pine` /
`rose-pine-dawn`, `dark-plus` / `light-plus`), and catppuccin's three dark
flavours share one light sibling. A theme with no sibling stays itself, and the
application says so rather than leaving a light terminal dark in silence.

**D38.** The mode alone misses kitty and tmux, which do not recognize it and
cluster all the same. The measurement is the layout the cells actually follow,
a multiplexer's where one sits in between (zellij: six cells under Ghostty,
which clusters). A terminal that answered `reset` is asked (DECSET 2027). The
one reply a key can spell (a modified legacy F3 is also `CSI 1 ; m R`) is taken
only once, inside the probe window.

**D39.** The environment alone cannot see synchronized output, scheme reports,
images, focus, paste or clustering. Because clustering selects the grid's width
profile (D50), an unprobed session would fold for every terminal. A peer that
answers nothing costs the probe's second.

**D40.** A terminal that does not recognize mode 2026 ignores a private mode it
does not know. Without the markers, the only difference is that a large frame
may be seen half-drawn: tearing, not a different picture. The flag is a
declaration a preset and a report can show, and M7's gate for this row is its
`O5` transcript test, not a component.

**D41.** The style and the underline's own colour are separate capabilities,
and kitty, Ghostty and foot answer both (measured headless). DECRQSS is not a
witness: Ghostty reports `4` for the curly underline it draws. A name is
identity, not an answer (`CAP3`). XTerm drops `4:3` without drawing any
underline, so the conservative side is the visible one. Alacritty (no reply)
and tmux and zellij (no reply, or a refusal) lose a style they may have; a
preset may show less, never more (D32).

**D42.** The name is still an answer: the terminal gives it, where
`$TERM_PROGRAM` is whatever a shell, an `ssh` hop or a multiplexer carried in.
Each table row is a terminal, a feature, the first version and a link to the
source line that does it, read at the measured tag. XTerm's OSC 52 is off by
default, so XTerm earns only the pointer shape. A multiplexer answers with its
own name and forwards to a host it cannot vouch for, so it earns nothing
(`CAP7`, D33); Alacritty gives no name, so it earns nothing though it draws
links. OSC 8 was measured harmless where unsupported (XTerm prints only the
text), but a declaration says what the target does, not what it tolerates.

**D43.** The pointer shape is sent every frame, and a terminal that drops it
loses nothing visible. A copy is the user's own action, and a terminal may keep
OSC 52 without having named itself (Alacritty), so the write goes out and hue
says "Copy sent; this terminal may not keep it". When an application needs a
notification, its fallback (an in-app toast) is the visible degradation. A
window declares the clipboard and the pointer shape, which it carries itself.

**D44.** Key releases: where `RunConfig.keyRelease` asked (as a window already
honours it) and the probe found the kitty keyboard protocol, kitty flag 2 is set
on the entry `open` pushed (`CSI = 15 ; 1 u`, so the one pop restores), and the
decoder reads `mods:type` on every key form; elsewhere the stream stays presses.
Hover: every measured terminal answers `DECRQM 1003` as recognized, and tmux and
zellij, which do not answer, implement it (tmux `MODE_MOUSE_ALL`, zellij
`AnyEventTracking`), so the request is the answer. `TuiHost.capabilities`
reports the session's declared input instead of a static cell pointer.

**D45.** Mode 1016 is recognized by kitty, Ghostty, foot and XTerm (`DECRQM`,
measured; Alacritty answers `0`), but nothing on the terminal reads sub-cell
input. The grid paints whole-cell scrollbar thumbs, and
`scrollbarThumbIntersectsCell` counts both cells of a straddling thumb. diagram
and ui-gallery ask for `PointerUnit.pixels` for their windows; honouring that on
the terminal would rework their TUI arms for no visible gain.

**D46.** An override means "in this state, take that slot's rest colour". A
theme stays single-sourced: the active tab follows whatever the theme makes
`chrome.accent`, and the override is the theme file's `{chrome.accent}` (M5).
Aliases read their target at rest, so they cannot chain (`TOK1`). The alias is
per channel because one base slot can need two targets: a pressed action-bar
segment takes its label from `chrome.accent` and its band from
`chrome.focused`. A **variant** is not a state: it picks the base slot (a capped
tab body is `chrome.accent`, an uncapped one `chrome`). A rich span that names
its own slot resolves at rest, so a selected row's `gutter` guides are not a
selected tab label. The shipped table is `addComponentStates`; every profile
golden was unchanged by it.

**D47.** `q`/`Esc`/`?`/`Tab`/`Shift-Tab`/`/` mean the same thing in every
context. A checkbox or a boolean row of a property tree needs `Enter` and
`Space`; with no such control focused, hue binds its leader and diagram its pan
to `Space`. `firstRebound` skips the focus rows; they are checked in context,
through `universalMeanings`.

**D48.** Raw mode delivers `Ctrl-C` as a key, so leaving it to each application
had left it to none of them, and restoring `ISIG` would kill an embedded shell's
interrupt with the application. A component holds `HostState.grabKeyboard` when
it hands the keyboard to something needing `Ctrl-C` itself (ui-gallery's
focused terminal pane), and the key is delivered as any other while it is held.
hue copies with `y` and `Cmd-C`.

**D49.** The repository owner chose this after a side-by-side of the terminal
against its mockups: chrome in the cell font read as a terminal UI. Layout stays
in cells, since a run's px extent rounds up to whole cells, so the cell decision
holds for geometry and a terminal keeps the same rows and columns. The bundled
face is Roboto: Android's system faces are variable fonts a raylib atlas cannot
draw in bold, and the desktop takes its own `sans-serif` first.

**D50.** base/text defines two width profiles with the same advances, so layout
is identical on every terminal: a ZWJ family takes two grid cells, and so does
`❤️`. They differ only in emission. `terminalKitty`, the default, emits a
cluster whole. `terminalUnclustered` (base/text `TXT-CELL5`) emits a
multi-scalar cluster as its leading scalar padded with spaces to the clustered
advance, or as a one-cell substitute when the leading scalar alone would be
wider. A terminal with neither mode 2027 nor measured clustering (D38) is driven
under `terminalUnclustered`, and the toolkit's fold — draw a cluster as its
leading scalar so cursor and drawing agree — is exactly that profile's emission
rule. base/text's `TXT-MIG1` (one width authority per caller) still holds: the
fold survives as a named profile, not as a compatibility helper. A cluster
longer than a TUI cell's 16 inline bytes is kept whole through owned overflow
storage (base/text `TXT-CELL8`), and exhausting it fails explicitly rather than
truncating. This retires the earlier behaviour in which such a cluster folded on
every target ([testing.md](./testing.md#evidence-ledger)). base/text records
the same outcome as its D-TXT-11 and D-TXT-12
([base/text decisions](../base/text/decisions.md)).

**D51.** The toolkit's breaker landed in `sparkles.ui.wrap` on the argument
that the measurer is caller-supplied. Base's wrapping contract
([wrapping](../base/text/wrapping.md), `WRAP-BOUND1`) answers that argument: the
solvers are generic over measurement and carry no font or UI dependency, and
every grid-cell advance comes from the width profile (`WRAP-CELL4`). The
toolkit keeps the policy — wrap or cut, the width, which width profile — and
calls base. `LAY5`, `LAY10` and `LAY14` keep their evidence for the delivered
code, pending base's cutover ([base/text PLAN](../base/text/PLAN.md#_6-m5-concrete-clean-cutovers)).

**D52.** A width profile's ambiguous-wide choice applies to text. Box drawing,
block elements and the sub-cell ladder, status marks and Private Use Area icons
are measured and drawn as one grid cell under every width profile. base/text
names that exempt set by range (`TXT-CELL7`, its D-TXT-13) so measurement and
painting agree, and `GLY3` cites it. Without the exemption, a user who sets
ambiguous characters wide would see every box border and mark double in width
while the layout assumed one.

**D53.** Proportional text in a window, such as docs prose in a sans face, is a
text-layout `shapedFlow` paragraph laid out inside the widget's cell rect.
Painting, hit-testing and selection use its one cluster result (text-layout
`TL-025`). The work is gated on text-layout TL-M3, which is itself gated on
font M4 and M7; there is no interim `raylib-text` implementation, because a
second paragraph engine would have to be removed again and would disagree with
text-layout's hit-testing in the meantime. text-layout records the same outcome
as [`TLD-008`](../text-layout/decisions.md#tld-008-toolkit-proportional-prose-is-a-shaped-flow-consumer).

**D54.** base/text owns scaled grid-cell footprints
([`TXT-SIZE1`–`TXT-SIZE5`](../base/text/SPEC.md#_6-4-scaled-grid-cell-footprints),
its D-TXT-14): a run's integer scale and fractional width are part of the cell
model, as grid-cell advances at a scale. `GLY5` and the `textSizing` capability
consume them, and whether a terminal honours kitty's OSC 66 stays a capability
question of the design system (OQ5). text-layout's statement that cell and
terminal sizing is a distinct consumer contract points at base/text
([`TLD-009`](../text-layout/decisions.md#tld-009-terminal-text-sizing-belongs-to-base)).
The design system owns font roles. A role's token value is a font request (font
`FTD4`), a fallback chain (`FTD5`) and code-point routes (`FTD6`, for example
the Private Use Area routed to a Nerd Font face). The font specification never
learns the word "role"; it gains only a pointer to its consumer.

## Open questions

| ID  | Question                                                                                                                                                                                                                                                                               | Affects           | Resolver / decision point                  |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------ |
| OQ2 | The Sparkles values: palette, sans face, glyph preferences. A design session, not a code task.                                                                                                                                                                                         | `SPK1`–`SPK5`, M4 | owner, after M1–M3 (D23)                   |
| OQ4 | CSS state variants: suffixed properties (`WEB1`) or emitted pseudo-class rules? Suffixes keep the mapping one-to-one; pseudo-classes are idiomatic.                                                                                                                                    | `WEB1`, `WEB4`    | M6                                         |
| OQ5 | Does the terminal honour OSC 66? The text-sizing proposal says `ghostty` at the pinned SHA does not, so `textSizing` is `false` for `apps/terminal` until it does. Footprints are base/text's ([`TXT-SIZE1`–`TXT-SIZE5`](../base/text/SPEC.md#_6-4-scaled-grid-cell-footprints), D54). | `GLY5`, `CAP2`    | text-sizing proposal M0                    |
| OQ6 | `sparkles:appearance` (OS scheme/accent/contrast) is deferred; when it lands, does `colorSchemeNotify` move there or stay a `tui` probe feeding it?                                                                                                                                    | `CAP2`            | platform-ui-guidelines proposal acceptance |

→ [Overview](./index.md)
