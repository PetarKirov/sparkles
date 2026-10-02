# Configuration and the settings page (`TCF`, `TSP`)

_**Status:** proposed · **Date:** 2026-10-02 · **Owner:** `apps/terminal`
(the schema and its layers); `sparkles:ui` (the settings pane, lifted from hue)
· **Scope:** one configuration value for the terminal on every platform, the
files it is read from, and the page that edits it._

## Why

The desktop terminal is configured by eight flags; the Android app by
`~/.termux/termux.properties` (only its `extra-keys`), `colors.properties` and
`font.ttf`. Everything this tree adds — the exit policy, link and paste
behaviour, notifications, the light and dark schemes, tabs — needs a home,
and on Android that home must be editable from inside the app, because there
is no command line.

hue solved the same problem ([`CFG`](../hue/config.md)): a D aggregate
reflected by `sparkles:wired`, layered as sparse overlays, with located errors,
`show`/`write`, and a property-tree settings pane. This page adopts that
design and records only what differs.

## Design

### One value, reflected (`TCF1`)

`TerminalConfig` is a D aggregate; its JSON is what `sparkles:wired` makes of
it. No field is declared twice, so the file, `terminal config show`, the
settings page and the generated starter file cannot disagree. Sections, by what
a user thinks they are changing:

| Section         | Contents                                                                                                                                            |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `appearance`    | `font` (family, size, faces, `fontDir[]`, `codepointMap[]`), `colors` (`dark`, `light`: fg, bg, cursor, palette[16]), `followSystem`, `chromeTheme` |
| `extraKeys`     | `visible` (`auto`/`always`/`never`), `layout` (Termux syntax)                                                                                       |
| `behaviour`     | `onExit`, `scrollback`, `restore`                                                                                                                   |
| `links`         | `tap`, `longPress`, `schemes[]`                                                                                                                     |
| `paste`         | `confirm`                                                                                                                                           |
| `clipboard`     | `osc52.write`, `osc52.read`                                                                                                                         |
| `notifications` | `enabled`, `when` (`unseen`/`always`/`never`)                                                                                                       |
| `tabs`          | `showStrip` (`auto`/`always`)                                                                                                                       |
| `lantern`       | `enabled`, `delayMs`, `leader`                                                                                                                      |
| `keys`          | the binding overlay ([`TKM`](./keymap.md)), as hue's `CFG6`                                                                                         |

### The layers (`TCF2`)

Lowest to highest; each layer is a **sparse overlay** (absence inherits):

1. **Compiled defaults** — the field initializers.
2. **Termux compatibility** — `~/.termux/termux.properties` `extra-keys` →
   `extraKeys.layout`; `colors.properties` → `appearance.colors` **pinned**
   (one scheme for both dark and light, `followSystem = false`, [D16](./decisions.md));
   `font.ttf` → `appearance.font`. nix-on-droid's `terminal.*` options write
   these files, so they keep working unchanged.
3. **The file** — `config.json` (JSONC on read, strict JSON on write, as hue):
   `$XDG_CONFIG_HOME/sparkles-terminal/` on Linux, the native location on
   macOS (`common_dirs.configDir`), `<home>/.config/sparkles-terminal/` on
   Android.
4. **CLI** — the desktop flags, highest. Android has none.

The file sits above the Termux layer so a user who has both gets what the app's
own settings page wrote. `termux-reload-settings` ([NOD21](./android.md#android-integration))
re-runs the whole resolution, not only the Termux files.

## Requirements (`TCF`)

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                    | Status      | Traces to                               |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | --------------------------------------- |
| `TCF1` | The configuration must be one D aggregate (`TerminalConfig`) whose JSON form is produced and read by `sparkles:wired`; no field's name, type or default may be declared in a second place. Violation: a field present in `config show` output, the starter file or the settings page but not in the aggregate, or vice versa (a reflection test enumerates all three).                                                         | not started | proposed `apps/terminal/src/settings.d` |
| `TCF2` | Resolution must apply defaults → Termux layer → `config.json` → CLI, each a sparse overlay: a setting absent from a layer inherits; a setting present with the default value overrides a lower layer's non-default. Violation: a fixture where the Termux layer sets a value and the file sets the default, resolving to the Termux value.                                                                                     | not started | hue `settings_overlay` pattern          |
| `TCF3` | The Termux layer must map exactly `extra-keys`, `colors.properties` and `font.ttf` as above, and a present `colors.properties` must set `followSystem = false`. An absent Termux file contributes nothing (it does not reset). Violation: a reload after deleting `colors.properties` that leaves the old colours ([NOD11](./android.md#requirements)'s rule).                                                                 | not started | `extraKeysFrom`, `parseTermuxColors`    |
| `TCF4` | A malformed file must not stop the app: it resolves without that layer, and a warning naming the file, line, column, the `$`-path and the offending value goes to the log ([`TPG`](./pages.md)) and, once, to a toast. A file that fails only in one value drops only that value. Violation: a typo that prevents start, or a silent fallback.                                                                                 | not started | `sparkles:wired` `JsonError`            |
| `TCF5` | `terminal config show` must print every effective setting with the layer that supplied it (`default`, `termux:<file>`, `file:<path>`, `cli:<flag>`); `terminal config write` must emit a commented starting file from the same resolved value. Desktop only; Android shows the same through the settings page's origin column (`TSP4`).                                                                                        | not started | hue `CFG10`, `CFG13`                    |
| `TCF6` | The JSONC reader (comments and trailing commas blanked in place, so error positions match the file) must be shared with hue, not copied: it moves from hue to `sparkles:wired`.                                                                                                                                                                                                                                                | not started | hue `settings_io.stripJsonc`            |
| `TCF7` | `extraKeys.visible`: `auto` (default) shows the row while the soft keyboard is shown and hides it while a hardware keyboard is attached and the soft keyboard is hidden; `always` and `never` are literal. A downward swipe on the row hides it until an upward swipe from the bottom edge or the `toggleExtraKeys` command shows it; that runtime state is not persisted. Hidden means zero height: the pane takes the space. | not started | `DroidTerminal.geometry`                |
| `TCF8` | A change that the running app can apply (colours, font, extra keys, link/paste/clipboard/notification policy, lantern) must take effect without a restart, whether it came from the settings page, `termux-reload-settings` or a changed file read on reload. Settings that cannot apply live (none known) must say so in the page.                                                                                            | not started | `TerminalView.recolor`                  |

## The settings page (`TSP`)

The editing surface is hue's settings pane ([`SET`](../hue/config.md#the-settings-pane-set)),
lifted into `sparkles:ui` ([D27](./decisions.md)) so hue and the terminal share
one component.

| ID     | Requirement                                                                                                                                                                                                                                                                                | Status      | Traces to                      |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ------------------------------ |
| `TSP1` | One settings-pane component in `sparkles:ui`, generic over the subject, resolving keys through a table its host supplies. hue moves onto it with its `SET1`–`SET8` behaviour and tests unchanged; the terminal mounts the same component over `TerminalConfig`.                            | not started | hue `SettingsPaneT`            |
| `TSP2` | Edits apply live (`TCF8`), are range-checked, refusable inline and undoable, exactly as hue's `SET2`/`SET3`.                                                                                                                                                                               | not started | `PropertyTree`, `editProperty` |
| `TSP3` | Saving writes only the paths the user touched in this session to `config.json` (hue's `SET4`/`SET5` rule); a value supplied by the Termux layer or the CLI that the user did not touch must not be baked into the file. Closing without saving keeps the running state and writes nothing. | not started | hue `saveUserConfig`           |
| `TSP4` | Each leaf shows the layer that supplies its effective value (`TCF5`'s origins), and a leaf shadowed by a higher layer says so, so a user editing a colour that `colors.properties` pins learns why nothing changes.                                                                        | not started | hue `Origins!T`                |
| `TSP5` | The page is operable by touch alone: tap selects a row, a second tap edits; booleans and enums change on tap; text edits through the soft keyboard; Back (or `Esc`/`q`, [`KBD1`](../design-system/keyboard.md)) closes; scrolling is a drag. Every target is at least 48 dp.               | open        | [design](./design.md)          |
| `TSP6` | The page is reachable from the lantern and the MENU key on every platform, and from the leader on the desktop ([`TKM`](./keymap.md)). Its layout (full-screen page vs modal panel, per form factor) is chosen from the mockups.                                                            | open        | [design](./design.md)          |

→ [Overview](./index.md) · [Keymap](./keymap.md) · [hue `CFG`](../hue/config.md)
