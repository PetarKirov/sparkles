# `hue` configuration — Feature Requirements (`CFG`)

_**Status:** design · **Date:** 2026-08-03 · **Scope:** a persistent,
user-editable configuration for the whole of `apps/hue` — appearance, panes,
behaviour, overlays and keybindings — its file format and layering, and how it
relates to the ~28 CLI options and the runtime toggles that exist today._

## Why this exists

hue's configuration surface is real and entirely **ephemeral**. Today it is:

| Surface                                                                  | Count    | Lifetime         |
| ------------------------------------------------------------------------ | -------- | ---------------- |
| CLI options (`@CliOption`)                                               | ~28      | one invocation   |
| Runtime toggles (`l`, `c`, `y`, `t`, `Tab`, `e`, `Ctrl-±`, theme arrows) | ~10      | until exit       |
| Keybindings (`keymap.commandFor`)                                        | ~45 keys | hardcoded        |
| Environment variables (`HUE_GUI_*`)                                      | 13       | test/debug hooks |

Three consequences, each observed rather than hypothetical:

1. **Every preference is retyped.** A user who wants Maple Mono at 13 pt with a
   32-cell tree and line numbers off passes four flags on every launch. On
   Android there is no command line at all, so those preferences are
   **unreachable** — the APK ships whatever the defaults are.
2. **Runtime toggles evaporate.** `y`, `t`, `l`, `c` and the theme arrows all
   change state the user then loses on exit, which makes them feel like
   experiments rather than settings.
3. **Keybindings cannot be changed.** `keymap.d` made the policy pure and
   testable, which is what makes it configurable at all — but the table is
   still compiled in.

## Design & rationale

### The schema is a D type, not a document (`CFG1`)

`sparkles:wired` reflects a D aggregate to and from JSON at compile time, with
`@WireName`/`@WireCase` for spelling, `@WireOptional` for absence, `@WireRepr`
for enums-by-name, and `@WireConvert` for value transforms. So the configuration
**is** a struct; JSON is its surface, not a parallel artefact:

```d
struct HueConfig
{
    Appearance appearance;
    Panes      panes;
    Behaviour  behaviour;
    Keymap     keys;
}
```

That is the whole point of choosing wired over a hand-written parser: there is
**no second place** where a field's name, type or default is written, so the
schema cannot drift from the code that reads it. Adding a setting is adding a
field.

It also means the JSON Schema published for editor completion (`CFG9`) is
_generated_ from the same reflection, never hand-maintained.

### Layering: defaults → file → environment → CLI (`CFG2`)

Precedence is lowest to highest:

1. **Compiled defaults** — the struct's field initialisers, which are already
   the documented defaults today.
2. **Config file** — `$XDG_CONFIG_HOME/hue/config.json` via
   `sparkles.core_cli.common_dirs.configDir` (macOS and Windows get their
   native locations from the same helper).
3. **Project file** — the nearest `.hue.json` walking up from the target, so a
   repository can pin a tab width or an exclude list for everyone working in it.
4. **Environment** — the existing `HUE_GUI_*` hooks keep winning over the file,
   because they exist to make a golden capture deterministic and must override
   whatever a developer has configured.
5. **CLI options** — highest, unchanged. A flag always wins.

Each layer is a **sparse overlay**: absence means "inherit", not "reset to
default". With `@WireOptional` this is the natural encoding — a `Nullable`-shaped
field distinguishes _unset_ from _set to the default value_, which a plain
struct cannot.

> [!IMPORTANT]
> The distinction matters for a real case: `--line-numbers=false` and "not
> mentioned" must differ, or a project file could never turn a setting **off**
> that the user's own config turned on.

### The sections (`CFG3`–`CFG6`)

| ID     | Section      | Contents                                                                                                                                                     |
| ------ | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CFG3` | `appearance` | `theme`, `background` mode, fonts (`family`, `bold`, `italic`, `boldItalic`, `size`), `window` (`width`, `height` in cells)                                  |
| `CFG4` | `panes`      | `tree` (`width`, `showDotfiles`, `showIgnored`, `include[]`, `exclude[]`), `viewer` (`lineNumbers`, `codeLineNumbers`, `tabWidth`, `listWhitespace`, `wrap`) |
| `CFG5` | `behaviour`  | `defaultView` (preview\|raw), `ansiCopy` (raw\|strip), `tableCopy` (tsv\|markdown), `overlays[]`, `gallery.out`                                              |
| `CFG6` | `keys`       | binding table — see below                                                                                                                                    |

The grouping follows what a user thinks they are changing, **not** how the code
is organised: `tabWidth` is a viewer setting even though it is consumed deep in
the raw-source renderer.

### Keybindings (`CFG6`)

`keymap.d` already reduced the policy to `(KeyEvent, KeyContext) → Command`.
Configuration replaces the hardcoded table with a loaded one:

```json
{
  "keys": {
    "normal": { "j": "viewDown", "k": "viewUp", "ctrl+c": "copySelection" },
    "tree": { "l": "treeActivate", "shift+r": "treeReroot" },
    "foldArmed": { "1-9": "foldLevel" }
  }
}
```

- **Commands are named by effect**, matching the `Command` enum — `viewDown`,
  not `KEY_J`. `@WireRepr(Repr.name)` gives the enum's spelling for free, so the
  accepted set is exactly the enum and an unknown name is a _decode_ error with a
  position, not a silent no-op.
- **Contexts are the map keys** (`normal`, `tree`, `input`, `foldArmed`),
  mirroring `KeyContext` rather than inventing a second vocabulary.
- **Chords parse to `Key` + `Mods`** (`ctrl+c`, `shift+r`) through
  `@WireConvert`, so the wire form stays human-writable while the in-memory form
  stays the `sparkles:input` vocabulary.
- **A user table is an overlay, not a replacement.** Rebinding `j` leaves the
  other 44 bindings alone; `"j": null` unbinds. Replacing wholesale is the
  common way a config format strands users after an upgrade adds a command.

### What stays out of the file (`CFG7`)

Deliberately **not** configurable, each for a stated reason:

| Excluded                                                   | Why                                                                                                            |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `--html`, `--out`, `--overlay`, `--twoslash`, target paths | these describe _this invocation's work_, not a preference                                                      |
| `--gui` / `--no-gui` / `--tui`                             | backend selection is environment detection plus an explicit override; persisting it defeats the auto-detection |
| `HUE_GUI_*`                                                | test hooks; making them configuration would make goldens depend on a developer's file                          |
| `SPARKLES_TS_GRAMMAR_PATH`                                 | a packaging concern owned by nix                                                                               |

A configuration file that can express "always output HTML" is a footgun, not a
feature.

### Inspecting the layers (`CFG10`)

Five layers that silently override each other are a debugging problem, not a
feature. `git` solved this with `--show-origin`, and `hue --show-config` copies
it: every effective setting, prefixed with **where it came from**.

```console
$ hue --show-config
default                                     appearance.background=full
default                                     panes.viewer.codeLineNumbers=true
file:/home/petar/.config/hue/config.json    appearance.theme=builtin-dark
file:/home/petar/.config/hue/config.json    appearance.font.family=Maple Mono
file:/home/petar/code/sparkles/.hue.json    panes.viewer.tabWidth=4
file:/home/petar/code/sparkles/.hue.json    panes.tree.exclude=[result, result-*]
env:HUE_GUI_FONTSIZE                        appearance.font.size=20
cli:--tree-width                            panes.tree.width=40
keys:tree                                   shift+r=treeReroot
```

The origin is the answer to the question the layering otherwise makes hard:
_why is my setting not taking effect?_ — because a project file, an
environment hook, or a flag is above it. Without this, `CFG2`'s five layers are
a maintenance liability; with it they are inspectable.

**Every effective setting is listed, including defaults**, so the output is a
complete picture rather than a diff. `--show-config --changed` can filter to
non-default origins if that proves noisy.

### Three flags, three jobs (`CFG10`, `CFG11`, `CFG13`)

They are easy to confuse and deliberately distinct:

| Flag             | Job                                                           | Writes a file? |
| ---------------- | ------------------------------------------------------------- | -------------- |
| `--show-config`  | report the effective state **and where each value came from** | no             |
| `--write-config` | emit a **commented starting file** to fill in                 | yes (new)      |
| `--save-config`  | persist the **runtime toggles** of this session (`CFG11`)     | yes (updates)  |

`--show-config` answers _why is this value what it is_; `--write-config`
answers _how do I begin_; `--save-config` answers _keep what I just did_. One
diagnoses, one scaffolds, one captures.

All three render from the **same resolved configuration value**, so the file a
user starts from, the state hue reports, and the state it persists cannot
disagree — the property that mattered about keeping them one code path, which
does not require them to be one flag.

`--write-config` is where the comments live: it generates the file, so it may
annotate every setting with its default and a one-line description drawn from
the same reflection that produces the schema (`CFG9`). That is also what makes
the JSONC recommendation below work — hue never rewrites a file it did not
generate, so a user's own comments survive.

### Errors are located, never silent (`CFG8`)

A malformed config must report **file, line, column and the offending value**,
and hue must **continue with defaults** rather than refusing to start — a
viewer that will not open because of a typo in a preference is worse than one
that ignores the preference and says so.

`sparkles.wired.json`'s `JsonError` already carries position; this requirement
is that hue _surfaces_ it (a startup warning through the existing degradation
channel) rather than swallowing it.

## Requirements

| ID      | Requirement                                                                                                                                                                                                                                              | Status      |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| `CFG1`  | The schema is a D aggregate reflected by `sparkles:wired`; JSON is its surface. No hand-written parser and no second declaration of any field.                                                                                                           | not started |
| `CFG2`  | Layering defaults → user file → project file → environment → CLI, each layer a **sparse overlay** where absence means inherit.                                                                                                                           | not started |
| `CFG3`  | `appearance`: theme, background mode, the four font faces, font size, window size.                                                                                                                                                                       | not started |
| `CFG4`  | `panes`: tree width/visibility filters/globs; viewer line numbers, code line numbers, tab width, whitespace rendering.                                                                                                                                   | not started |
| `CFG5`  | `behaviour`: default view, ansi-copy and table-copy modes, overlay defaults, gallery output dir.                                                                                                                                                         | not started |
| `CFG6`  | `keys`: per-context binding tables over the `Command` enum, applied as an **overlay** on the built-in map; `null` unbinds.                                                                                                                               | not started |
| `CFG7`  | Per-invocation concerns (output format, target, backend choice, test hooks) are **not** configurable.                                                                                                                                                    | not started |
| `CFG8`  | A malformed config reports file/line/column and hue continues with defaults.                                                                                                                                                                             | not started |
| `CFG9`  | A JSON Schema is **generated** from the same reflection for editor completion — never hand-maintained.                                                                                                                                                   | not started |
| `CFG10` | `hue --show-config` lists every effective setting **with the origin that supplied it** (`default`, a file path, an env var, or the CLI flag) — the layering made observable, after `git config --show-origin --list`. Reports only; writes nothing.      | not started |
| `CFG11` | Runtime toggles (`l`, `c`, `y`, `t`, theme, font size) may be **persisted on request** (`hue --save-config`), so an experiment can become a setting without hand-editing.                                                                                | not started |
| `CFG12` | Android reads the same file from the app's data dir, which is the only way those preferences are reachable there at all.                                                                                                                                 | not started |
| `CFG13` | `hue --write-config` emits a **commented starting file** — every setting with its default and a one-line description drawn from the same reflection as the schema (`CFG9`). Renders from the same resolved value as `CFG10`, so the two cannot disagree. | not started |

## Milestones

| Milestone | Scope                                                                     | Requirements            |
| --------- | ------------------------------------------------------------------------- | ----------------------- |
| C1        | The struct + wired round-trip + located errors                            | `CFG1`, `CFG8`          |
| C2        | Layering and the sparse-overlay merge                                     | `CFG2`                  |
| C3        | Appearance / panes / behaviour sections wired to their consumers          | `CFG3`–`CFG5`, `CFG7`   |
| C4        | Configurable keymap over the `Command` enum                               | `CFG6`                  |
| C5        | `--show-config`, `--write-config`, `--save-config`, generated JSON Schema | `CFG9`–`CFG11`, `CFG13` |
| C6        | Android config path                                                       | `CFG12`                 |

## Open questions

1. **Format.** JSON is the brief, and `sparkles:wired` speaks it natively. But
   JSON has no comments, and `--write-config` (`CFG13`) exists precisely to
   emit an annotated file. Options: accept JSON-with-comments on read (a lexer
   concession), ship `.jsonc`, or drop the annotations and let `--show-config`
   carry the explanation instead. **Recommendation: JSONC on read, strict JSON
   on write.** `--write-config` then emits comments a user keeps, hue never
   rewrites a file it did not generate, and `--save-config` (`CFG11`) — the one
   command that _does_ rewrite — must therefore preserve unknown text or refuse.
   That last consequence is the part to settle before implementing, not after.
2. **Themes.** `appearance.theme` names a built-in today. Whether a user may
   _define_ a theme in the config, or only reference one, is a larger question
   that belongs with `sparkles:syntax`'s theme layer rather than here.
3. **`CFG11` and precedence.** If a runtime toggle is persisted while a CLI flag
   set that same value, saving must write the _toggled_ value, not the flag —
   otherwise the save silently bakes in a one-off invocation. Needs stating as a
   rule before implementation.

## Relationship to existing specs

| Piece                                                         | Role                                                          |
| ------------------------------------------------------------- | ------------------------------------------------------------- |
| [`feature-requirements.md`](./feature-requirements.md) `CLI*` | the flags this layers under; every `CLI` option keeps winning |
| [`android.md`](./android.md) `AND*`                           | why `CFG12` is not optional — no command line exists there    |
| `apps/hue/src/keymap.d`                                       | the pure policy `CFG6` makes table-driven                     |
| `sparkles:wired`                                              | the reflection that makes `CFG1` and `CFG9` one mechanism     |
| `sparkles.core_cli.common_dirs`                               | the platform-correct locations for `CFG2`                     |
