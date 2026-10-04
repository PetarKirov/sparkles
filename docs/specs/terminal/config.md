---
status: accepted
owner: sparkles:terminal
reviewed: 2026-10-03
---

# Configuration and the settings page (`TCF`, `TSP`)

## Introduction

People change a terminal's fonts and colours, what a tap on a link does, how
pastes and clipboard requests are guarded, and which keys the terminal claims.
On the desktop a configuration file and command-line flags serve; on Android
there is no command line, so the app must be configurable from inside itself.
On Android the app also replaces the Termux app that nix-on-droid users
configured through files under `~/.termux/`, and those files must keep working.

The difficulty is keeping one truth. A setting that is declared in a struct,
described in a starter file, printed by a command and edited on a page drifts
as soon as any of the four is written by hand. Two sources of configuration,
Termux's files and the app's own, also need a precedence the user can see.

The configuration is therefore one D aggregate, reflected rather than
restated: the serialization library `sparkles:wired` derives the JSON file,
the printed form, the starter file and the settings page from the struct. The
hue code viewer configures itself the same way ([`CFG`](../hue/config.md)).
The sources stack as [sparse overlays](../../glossary.md#sparse-overlay):
compiled defaults, then Termux's files, then the app's own file, then the
desktop's command-line flags. The settings page writes the app's own file and
shows which layer supplied every value.

This page covers the configuration value, the files it is read from, and the
page that edits it. `apps/terminal` owns the schema and its layers; the
settings pane component belongs to `sparkles:ui`, lifted from hue so both
applications share one copy ([D27](./decisions.md)). What each setting does
is specified with the behaviour it governs: links and the clipboard in
[Protocols](./protocols.md), keys in [Keymap](./keymap.md), tabs and panes in
[Sessions](./sessions.md). The Termux layer reads only what nix-on-droid
writes: the key layout in `termux.properties`, `colors.properties` and
`font.ttf`. The rest of `termux.properties` is out of scope, because the app
does not have the Termux features it configures.

[Design](#design) describes the value and its layers. The obligations follow
in [Requirements](#requirements-tcf) and [The settings page](#the-settings-page-tsp),
each with a status table; the evidence is in [Testing](./testing.md).

## Design

### One value, reflected

`TerminalConfig` is a D aggregate, and its JSON is what `sparkles:wired` makes
of it. Its sections follow what a user thinks they are changing:

| Section         | Contents                                                                                                                                            |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appearance`    | `font` (family, size, faces, `fontDir[]`, `codepointMap[]`), `colors` (`dark`, `light`: fg, bg, cursor, palette[16]), `followSystem`, `chromeTheme` |
| `extraKeys`     | `visible` (`auto`/`always`/`never`), `layout` (Termux syntax)                                                                                       |
| `behaviour`     | `onExit`, `scrollback`, `restore`                                                                                                                   |
| `links`         | `tap`, `longPress`, `schemes[]`                                                                                                                     |
| `paste`         | `confirm`                                                                                                                                           |
| `clipboard`     | `osc52.write`, `osc52.read`                                                                                                                         |
| `notifications` | `enabled`, `when` (`unseen`/`always`/`never`)                                                                                                       |
| `ui`            | `buttonLabels`, `overlayStyle`, `selectionMenu`, `tabsOpener`, `paneChrome`                                                                         |
| `open`          | `target`, `intercept`                                                                                                                               |
| `lantern`       | `enabled`, `delayMs`, `leader`                                                                                                                      |
| `keys`          | the binding overlay ([`TKM`](./keymap.md)), as hue's `CFG6`                                                                                         |

### The layers

From lowest to highest, each layer a sparse overlay in which an absent setting
inherits:

1. **Compiled defaults:** the field initializers.
2. **Termux compatibility:** the `extra-keys` entry of
   `~/.termux/termux.properties` sets `extraKeys.layout`;
   `colors.properties` sets `appearance.colors` and pins it, one scheme for
   both dark and light with `followSystem = false` ([D16](./decisions.md));
   `font.ttf` sets `appearance.font`. nix-on-droid's `terminal.*` options
   write these files, so they keep working unchanged.
3. **The file:** `config.json`, read as JSONC and written as strict JSON, as
   hue does. It lives in `$XDG_CONFIG_HOME/sparkles-terminal/` on Linux, the
   native location on macOS (`common_dirs.configDir`), and
   `<home>/.config/sparkles-terminal/` on Android.
4. **The command line:** the desktop flags, highest. Android has none.

The file sits above the Termux layer, so a user who has both gets what the
app's own settings page wrote. `termux-reload-settings`
([NOD21](./android.md#android-integration)) re-runs the whole resolution, not
only the Termux files.

## Requirements (`TCF`)

**TCF1: One reflected value.** The configuration **must** be one D aggregate,
`TerminalConfig`, whose JSON form `sparkles:wired` produces and reads. No
field's name, type or default **may** be declared a second time. Violation: a
field present in `config show`'s output, the starter file or the settings page
but absent from the aggregate, or the reverse; a reflection test enumerates
all three.

**TCF2: Layer resolution.** Resolution **must** apply the compiled defaults,
the Termux layer, `config.json` and the command line, in that order, each as a
sparse overlay. A setting absent from a layer inherits; a setting present with
the default value still overrides a lower layer. Violation: a fixture where
the Termux layer sets a value and the file sets the default, resolving to the
Termux value.

**TCF3: The Termux layer.** The Termux layer **must** map exactly
`extra-keys`, `colors.properties` and `font.ttf` as [the layers](#the-layers)
list them, and a present `colors.properties` **must** set
`followSystem = false`. An absent Termux file contributes nothing and resets
nothing. Violation: a reload after deleting `colors.properties` that keeps
the old colours, against [NOD11](./android.md#requirements).

**TCF4: Malformed files.** A malformed file **must not** stop the app.
Resolution proceeds without that layer, and a warning naming the file, line,
column, `$`-path and offending value goes to the log ([`TPG`](./pages.md))
and, once, to a toast. A file that fails in one value drops only that value.
Violation: a typo that prevents start, or a silent fallback.

**TCF5: Show and write.** `terminal config show` **must** print every
effective setting with the layer that supplied it: `default`,
`termux:<file>`, `file:<path>` or `cli:<flag>`. `terminal config write`
**must** emit a commented starter file from the same resolved value. Both are
desktop commands; on Android the settings page shows the same origins
(`TSP4`).

**TCF6: One JSONC reader.** The JSONC reader, which blanks comments and
trailing commas in place so that error positions match the file, **must** be
the one hue uses, from `sparkles:wired`, not a copy.

**TCF7: Extra-keys visibility.** `extraKeys.visible` **must** control the
[extra-keys row](../../glossary.md#extra-keys-row). `auto`, the default, shows
it while the soft keyboard is shown and hides it while a hardware keyboard is
attached and the soft keyboard is hidden; `always` and `never` mean what they
say. A downward swipe on the row hides it until an upward swipe from the
bottom edge or the `toggleExtraKeys` command shows it again, and that state
is not saved. A hidden row has zero height, and the pane takes the space.

**TCF8: Live changes.** A change the running app can apply **must** take
effect without a restart, whether it came from the settings page,
`termux-reload-settings` or a changed file read on reload. That covers the
colours, the font, the extra keys, the link, paste, clipboard and notification
policies, and the key guide. A setting that cannot apply live **must** say so
on the page.

**TCF9: Button labels.** `ui.buttonLabels` (`iconText` by default, `text` or
`icon`) **must** apply to every button and menu item the app draws: the
selection menu, confirmations, the [exit prompt](../../glossary.md#exit-prompt),
the file-link card, context menus and page headers. An icon-only button keeps
its label as its accessible name and tooltip. Menus show keyboard-shortcut
hints in every mode ([D35](./decisions.md)).

**TCF10: Overlay style.** `ui.overlayStyle` (`anchored` by default, or
`sheet`) **must** choose how every confirmation and action
[surface](../../glossary.md#surface) shown over a pane is placed: the link and
file-link cards, the paste guard and the OSC 52 read confirmation. One setting
governs them all, so the app never mixes the two ([D34](./decisions.md)). An
anchored card **must not** cover its subject, meaning the link, path,
selection or prompt line it refers to, nor the soft keyboard or the extra-keys
row. When no position satisfies that, that one occurrence is shown as a sheet.

_Rationale:_ The sheet is the anchored style's own fallback, so the rule
against mixing holds: a user who chose sheets never sees a card.

**TCF11: Selection menu style.** `ui.selectionMenu` **must** choose the touch
selection menu ([`TSE5`](./selection.md)): `sheet`, a bottom sheet with a
swipeable action row (mockup S2); `card`, an anchored card of labelled actions
(B1); `compact`, an anchored pill of icon-only actions (B4); or `auto`, the
default, which is the sheet on a phone and the card on a large screen
(`TCF14`). It is independent of `ui.overlayStyle`. The desktop always uses the
right-click menu (X1). A change applies to the next selection.

**TCF12: Tabs opener.** `ui.tabsOpener` **must** choose the
[opener](../../glossary.md#opener) of the tree of tabs and panes
([`TSS13`](./sessions.md)): `pill`, `rail`, or `auto`, the default, which is
the pill on a phone in portrait and the rail in landscape, on a large screen
(`TCF14`) and on the desktop.

**TCF13: Pane chrome.** `ui.paneChrome` **must** choose how panes are marked
and labelled ([`TSS11`](./sessions.md)): `reveal`, the default, `header` or
`framed`.

**TCF14: Large screens.** A screen whose smallest width is at least 600
[dp](https://developer.android.com/training/multiscreen/screendensities)
**must** get the large-screen `auto` choices ([D47](./decisions.md)): the rail
in both orientations under `ui.tabsOpener = auto`, and the anchored card under
`ui.selectionMenu = auto`, as on the desktop. Violation: a tablet in portrait
showing the pill or the selection sheet.

_Rationale:_ 600 dp is Android's conventional tablet threshold (`sw600dp`). On
such a screen a portrait window is wide enough for the rail, and a card leaves
the selection's context in view where a sheet would cover half of it.

### Status (`TCF`)

| ID      | Status                                                                                                                   | Traces to                                                                                        |
| ------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `TCF1`  | full                                                                                                                     | `TerminalConfig`, `leafCount`                                                                    |
| `TCF2`  | full                                                                                                                     | `loadTerminalConfig`, `applyCli`                                                                 |
| `TCF3`  | full                                                                                                                     | `termuxLayer`                                                                                    |
| `TCF4`  | full                                                                                                                     | `readJsoncFileTolerant`, `configWarning`, `locateWirePath`, `WorkspaceHost.reportConfigWarnings` |
| `TCF5`  | full                                                                                                                     | `renderConfigShow`, `renderStarterConfig`                                                        |
| `TCF6`  | full                                                                                                                     | `stripJsonc`, `readJsoncFile`, `renderStarterSections`                                           |
| `TCF7`  | full                                                                                                                     | `extraKeysShown`, `swipeKeyRow`, `TermCommand.toggleExtraKeys`                                   |
| `TCF8`  | partial: the font family and styled faces apply at the next start; the size applies live                                 | `loadSettings`, `TerminalView.recolor`, `applyToWorkspace`                                       |
| `TCF9`  | partial: an icon-only button has no tooltip or accessible name, which `sparkles:ui` widgets do not carry                 | `chrome.button`, [design](./design.md)                                                           |
| `TCF10` | partial: the paste guard and the link card follow it; the OSC 52 read is always a sheet; the file-link card is `TDV12`'s | `placeOne`, `SurfaceContext.style`                                                               |
| `TCF11` | full                                                                                                                     | `SelectionUi.useAndroid`, `ActionMenu`, `menuStyle`                                              |
| `TCF12` | full                                                                                                                     | `usesPill`, `WorkspaceHost.tabsOpener`                                                           |
| `TCF13` | full                                                                                                                     | `paneBoxes`, `WorkspaceHost.paneChrome`                                                          |
| `TCF14` | full                                                                                                                     | `largeScreen`, `menuStyle`, `DroidTerminal.view` (`phonePortrait`)                               |

## The settings page (`TSP`)

The editing surface is hue's settings pane
([`SET`](../hue/config.md#the-settings-pane-set)), lifted into `sparkles:ui`
so that hue and the terminal share one component.

**TSP1: One settings pane.** One settings-pane component in `sparkles:ui`
**must** serve both applications: generic over the subject, it resolves keys
through a table its host supplies. hue mounts it with its `SET1`–`SET8`
behaviour and tests unchanged; the terminal mounts it over `TerminalConfig`.

**TSP2: Edits.** An edit **must** apply live (`TCF8`) and be range-checked,
refusable inline and undoable, as hue's `SET2` and `SET3` specify.

**TSP3: Autosave.** Each committed edit **must** be written to `config.json`
at once, recording only the paths the user touched, as hue's `SET5` does: a
value the Termux layer or the command line supplied is never copied into the
file unless edited. A "Saved" toast offers **Undo**, which is the property
tree's own history (`PRT`), not a second stack. There is no Save button
([D36](./decisions.md)).

**TSP4: Provenance.** Each leaf **must** show the layer that supplies its
effective value, using `TCF5`'s origins. Once the user edits a leaf whose
value came from a `~/.termux` file, the leaf **must** say **"overrides
colors.properties"**, naming the file concerned.

_Rationale:_ The edit lands in `config.json`, which wins over the Termux
layer. Without the note, the user cannot tell why the Termux file stopped
mattering.

**TSP5: Touch editing.** The page **must** be operable by touch alone.
Sections are header rows. Leaves carry inline controls chosen by type: a
toggle for `bool`, a segmented control for a small enum, a dropdown for a
larger one, a stepper for a `@Range` number and a swatch for a colour. An
aggregate or array is a drill-in row that previews its values. A leaf with a
description shows it on one line beneath, and a changed leaf shows a marker
and a reset. Text is edited through the soft keyboard, and Back, `Esc` or `q`
([`KBD1`](../design-system/keyboard.md)) closes the page. Every target is at
least 48 dp. Layout: mockup G3 ([design](./design.md)).

**TSP6: Reaching the page.** The page **must** be a full-screen page on a
phone and a modal panel on the desktop, reachable from the
[key guide](../../glossary.md#key-guide) and the MENU key on every platform
and from the [leader](../../glossary.md#leader) on the desktop
([`TKM`](./keymap.md)).

**TSP7: Order.** Every section **must** start expanded, and sections and
leaves **must** appear in the declaration order of `TerminalConfig`'s fields,
so that reordering the struct reorders the page. There is no second ordering
table ([D36](./decisions.md)).

**TSP8: Key bindings.** Key bindings **must** be editable on the page through
a capture editor shared with hue ([hue `SET9`](../hue/config.md)). The row
shows the chord; activating it waits for the next chord, or for each key of a
sequence in turn, and shows it live. A chord already bound offers **Swap**,
**Bind both** or **Cancel**; a reserved key
([`KBD3`](../design-system/keyboard.md)) is refused with the reason; `Esc`
cancels the capture rather than binding `Esc`. On a phone the extra-keys row
latches Ctrl and Alt for it. The result is written as the `keys` overlay
(`TKM8`). Layout: mockup G4.

### Status (`TSP`)

| ID     | Status                                                                                                                                                                 | Traces to                                                                                  |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `TSP1` | full                                                                                                                                                                   | `SettingsPane`, `SettingsPage`, `TerminalSettingsStore`                                    |
| `TSP2` | full                                                                                                                                                                   | `editProperty`, `terminalApplyRules`, `applyToWorkspace`, `applyConfig`                    |
| `TSP3` | full                                                                                                                                                                   | `SettingsToast`, `changedPaths`, `undoLast`, `SettingsPage`                                |
| `TSP4` | full                                                                                                                                                                   | `LeafProvenance`, `originAt`, `RowState`                                                   |
| `TSP5` | partial: the swatch opens the hex line editor, not a picker; an array's elements are edited, never added or removed                                                    | `inlineEditorFor`, `sectionRow`, `SettingsPage`; [`PRT36`–`PRT40`](../ui/property-tree.md) |
| `TSP6` | full                                                                                                                                                                   | `SettingsPage`, `openGuideAtLeader`, `openSettings`                                        |
| `TSP7` | full                                                                                                                                                                   | `sectionItems`, `PropertyNode.section`                                                     |
| `TSP8` | partial: hue does not mount the editor (`SET9`); a capture settles at the first key that opens no other keys, so a sequence under an unbound prefix cannot be captured | `ChordCapture`, `rebind`, `bindingRows`; [`PRT41`](../ui/property-tree.md)                 |

→ [Overview](./index.md) · [Keymap](./keymap.md) · [hue `CFG`](../hue/config.md)
