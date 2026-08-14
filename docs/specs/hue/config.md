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
| Keybindings (`keymap.hueBindings`)                                       | ~60 rows | hardcoded table  |
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
   testable, and [lantern](./lantern.md) made it a table — which is what makes
   it configurable at all — but the table is still compiled in. Note that a
   user table must overlay `hueBindings` **row by row**: the guide reads the
   same table, so a wholesale replacement would leave the panel describing
   bindings the user no longer has.

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
| `CFG5` | `behaviour`  | `defaultView` (preview\|raw), `ansiCopy` (raw\|strip), `tableCopy` (tsv\|markdown), `overlays[]`, `gallery.out`, `grammarPaths[]`                            |
| `CFG6` | `keys`       | binding table — see below                                                                                                                                    |

The grouping follows what a user thinks they are changing, **not** how the code
is organised: `tabWidth` is a viewer setting even though it is consumed deep in
the raw-source renderer.

### Keybindings (`CFG6`)

`keymap.d` already reduced the policy to `(KeyEvent, KeyContext) → Command`,
and [lantern](./lantern.md) `KEY1` turned it into an actual **table**
(`hueBindings`) that every backend resolves through — so the thing this section
assumed exists now does. Configuration overlays it:

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

### Grammar search paths compose, they do not override (`CFG14`)

`SPARKLES_TS_GRAMMAR_PATH` looks like packaging — nix sets it to the store path
of the grammar bundle — and that reading is what first put it in the excluded
list. It is wrong. A user building a tree-sitter grammar for a language the
bundle does not carry is **extending hue**, not repackaging it, and today the
only way to say so is an environment variable: unavailable in a desktop
launcher, and on **Android unreachable entirely**, which is where an
unsupported language is most likely to be met.

So `behaviour.grammarPaths` is a list of additional directories, and it is the
one place `CFG2`'s scalar rule does **not** apply:

> For a search path, "the higher layer wins" would mean a user's extra grammar
> _replaces_ the bundle and highlighting collapses to nothing. The layers
> **compose** instead — configured paths are searched first, then the
> environment's, then the built-in default.

Searched first, not last, so a user can shadow a bundled grammar with a newer
build of it — the reason to point at your own copy in the first place.

This composition is the exception, so it is stated where it is easy to find
rather than inferred; the same shape will apply to any future list-valued
setting (theme directories, overlay plugins) and should not be re-argued each
time.

### What stays out of the file (`CFG7`)

Deliberately **not** configurable, each for a stated reason:

| Excluded                                                   | Why                                                                                                            |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `--html`, `--out`, `--overlay`, `--twoslash`, target paths | these describe _this invocation's work_, not a preference                                                      |
| `--gui` / `--no-gui` / `--tui`                             | backend selection is environment detection plus an explicit override; persisting it defeats the auto-detection |
| `HUE_GUI_*`                                                | test hooks; making them configuration would make goldens depend on a developer's file                          |

A configuration file that can express "always output HTML" is a footgun, not a
feature.

### Inspecting the layers (`CFG10`)

Five layers that silently override each other are a debugging problem, not a
feature. `git` solved this with `--show-origin`, and `hue config show` copies
it: every effective setting, prefixed with **where it came from**.

```console
$ hue config show
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
complete picture rather than a diff. `hue config show --changed` can filter to
non-default origins if that proves noisy.

### Three actions, three jobs (`CFG10`, `CFG11`, `CFG13`)

They are easy to confuse and deliberately distinct:

| Action             | Job                                                           | Writes a file? |
| ------------------ | ------------------------------------------------------------- | -------------- |
| `hue config show`  | report the effective state **and where each value came from** | no             |
| `hue config write` | emit a **commented starting file** to fill in                 | yes (new)      |
| `hue config save`  | persist the **runtime toggles** of this session (`CFG11`)     | yes (updates)  |

`hue config show` answers _why is this value what it is_; `hue config write`
answers _how do I begin_; `hue config save` answers _keep what I just did_. One
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

**Verified against the library** (`libs/wired/src/sparkles/wired/json/error.d`),
because a spec that assumes a dependency's capability is a spec that discovers
at implementation time that it does not have it. `JsonError` carries rather more
than this requirement asks for:

| Field                      | Gives `CFG8`                                                                   |
| -------------------------- | ------------------------------------------------------------------------------ |
| `offset`, `line`, `column` | the position — 1-based, derived eagerly so the error does not borrow the input |
| `path`                     | the `$…` value path from the root to the failing location                      |
| `targetType`               | the D type being decoded into, as a compile-time literal                       |
| `valueSummary`             | the offending value                                                            |
| `filePath`, `cause`        | which file, and an errno-style cause for the read stages                       |

So `CFG8` is a matter of _rendering_ a value hue already receives — `path` and
`targetType` mean the message can name the setting (`$.panes.viewer.tabWidth`),
not merely a line number.

## Requirements

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                      | Status      |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- |
| `CFG1`  | The schema is a D aggregate reflected by `sparkles:wired`; JSON is its surface. No hand-written parser and no second declaration of any field.                                                                                                                                                                                                                                                   | not started |
| `CFG2`  | Layering defaults → user file → project file → environment → CLI, each layer a **sparse overlay** where absence means inherit.                                                                                                                                                                                                                                                                   | not started |
| `CFG3`  | `appearance`: theme, background mode, the four font faces, font size, window size.                                                                                                                                                                                                                                                                                                               | not started |
| `CFG4`  | `panes`: tree width/visibility filters/globs; viewer line numbers, code line numbers, tab width, whitespace rendering.                                                                                                                                                                                                                                                                           | not started |
| `CFG5`  | `behaviour`: default view, ansi-copy and table-copy modes, overlay defaults, gallery output dir.                                                                                                                                                                                                                                                                                                 | not started |
| `CFG6`  | `keys`: per-context binding tables over the `Command` enum, applied as an **overlay** on `hueBindings` ([lantern](./lantern.md) `KEY12`); `null` unbinds. The guide enumerates the same table, so a rebinding is described correctly without a second declaration.                                                                                                                               | not started |
| `CFG7`  | Per-invocation concerns (output format, target, backend choice, test hooks) are **not** configurable.                                                                                                                                                                                                                                                                                            | not started |
| `CFG8`  | A malformed config reports file/line/column and hue continues with defaults.                                                                                                                                                                                                                                                                                                                     | not started |
| `CFG9`  | A JSON Schema is **generated** from the same reflection for editor completion — never hand-maintained.                                                                                                                                                                                                                                                                                           | not started |
| `CFG10` | `hue config show` (or `hue config --show`) lists every effective setting **with the origin that supplied it** (`default`, a file path, an env var, or the CLI flag) — the layering made observable, after `git config --show-origin --list`. Reports only; writes nothing.                                                                                                                       | not started |
| `CFG11` | Runtime toggles (`l`, `c`, `y`, `t`, theme, font size) may be **persisted on request** (`hue config save`), so an experiment can become a setting without hand-editing.                                                                                                                                                                                                                          | not started |
| `CFG12` | Android reads the same file from the app's data dir, which is the only way those preferences are reachable there at all.                                                                                                                                                                                                                                                                         | not started |
| `CFG13` | `hue config write` emits a **commented starting file** — every setting with its default and a one-line description drawn from the same reflection as the schema (`CFG9`). Renders from the same resolved value as `CFG10`, so the two cannot disagree.                                                                                                                                           | not started |
| `CFG14` | `behaviour.grammarPaths[]` adds tree-sitter grammar directories. Search paths **compose** rather than override — configured, then `SPARKLES_TS_GRAMMAR_PATH`, then the built-in default — the one documented exception to `CFG2`'s scalar layering.                                                                                                                                              | not started |
| `CFG15` | `diff`: default layout, whitespace/noise toggles, structural engagement, preview-diff default, diff-copy mode — the persistent home of the [diff-view.md](./diff-view.md) runtime toggles (`DVL3`/`DVL8`/`DVN1`/`DVN3`); the review-command family joins the `Command` enum under `keys` (`CFG6`).                                                                                               | not started |
| `CFG16` | `forges`: the **host → adapter map** (self-hosted GitLab/Gitea/Forgejo/Codeberg instances have arbitrary hosts — [`DPR7`](./diff-view.md) requires it user-extendable) plus per-forge token sources. On Android this file is the **only** route ([`CFG12`], [`AND11`](./android.md)) — token storage there is plain-text, documented as such.                                                    | not started |
| `CFG18` | `lantern`: the key guide's `enabled`, `delayMs`, `placement` (`classic`/`helix`) and `leader` key ([lantern](./lantern.md) `LTN14`/`LTN15`). The delay in particular is a taste setting — it is the whole difference between a guide that teaches and one that interrupts.                                                                                                                       | not started |
| `CFG19` | `picker`: the default layout, the grep mode, and the **frecency store's** location. The store is machine-managed state rather than a preference ([picker](./picker.md) `PKR5`), and the setting exists so it can be moved off a small or network-mounted `$XDG_STATE_HOME`.                                                                                                                      | not started |
| `CFG17` | `diff.types`: the type overlay ([`DVT`](./diff-view.md)) — `auto`/`off`, the bound on concurrently live analyzer processes, and the **worktree cache root** where old revisions are materialized (`DVT2`). The cache is machine-managed state, not preferences: hue prunes its own worktrees, and the setting exists so a user can relocate it off a small or network-mounted `$XDG_CACHE_HOME`. | not started |

## Milestones

| Milestone | Scope                                                                           | Requirements                   |
| --------- | ------------------------------------------------------------------------------- | ------------------------------ |
| C1        | The struct + wired round-trip + located errors                                  | `CFG1`, `CFG8`                 |
| C2        | Layering and the sparse-overlay merge                                           | `CFG2`                         |
| C3        | Appearance / panes / behaviour sections wired to their consumers                | `CFG3`–`CFG5`, `CFG7`, `CFG14` |
| C4        | Configurable keymap over the `Command` enum, plus lantern/picker settings       | `CFG6`, `CFG18`, `CFG19`       |
| C5        | `hue config show`, `hue config write`, `hue config save`, generated JSON Schema | `CFG9`–`CFG11`, `CFG13`        |
| C6        | Android config path                                                             | `CFG12`                        |

## Open questions

1. **Format.** JSON is the brief, and `sparkles:wired` speaks it natively. But
   JSON has no comments, and `hue config write` (`CFG13`) exists precisely to
   emit an annotated file. Options: accept JSON-with-comments on read (a lexer
   concession), ship `.jsonc`, or drop the annotations and let `hue config show`
   carry the explanation instead. **Recommendation: JSONC on read, strict JSON
   on write.** `hue config write` then emits comments a user keeps, hue never
   rewrites a file it did not generate, and `hue config save` (`CFG11`) — the one
   command that _does_ rewrite — must therefore preserve unknown text or refuse.
   That last consequence is the part to settle before implementing, not after.

   **The "lexer concession" is not one.** `sparkles.wired.json.reader` already
   exposes `allowComments` (and `allowTrailingCommas`) as reader options,
   defaulting to strict RFC 8259. So reading JSONC is a flag at the call site,
   not a change to `sparkles:wired` — which removes the only implementation cost
   weighing against the recommendation. What remains open is purely the
   `--save-config` rewrite policy, which is a **design** decision and still has
   to be made before `C5`.

2. **Themes.** `appearance.theme` names a built-in today. Whether a user may
   _define_ a theme in the config, or only reference one, is a larger question
   that belongs with `sparkles:syntax`'s theme layer rather than here.
3. **`CFG1` and `CFG2` pull in opposite directions, and `C1` has to resolve it.**
   `CFG2` wants each layer to be a **sparse overlay** — a `Nullable`-shaped
   field, so _unset_ differs from _set to the default_. `CFG1` wants the
   compiled defaults to be **the struct's field initialisers**, so there is no
   second declaration of any field. A field cannot be both: `Nullable!int width`
   has no initialiser to read a default from.

   Three ways out, and the choice shapes the struct `C1` writes:

   | Option                                                      | Cost                                                                              |
   | ----------------------------------------------------------- | --------------------------------------------------------------------------------- |
   | Two types — resolved `HueConfig` + sparse `HueOverlay`      | every field declared twice; exactly what `CFG1` exists to prevent                 |
   | One sparse type + a separate defaults table                 | defaults leave the declaration; `--write-config`'s "default" column drifts        |
   | One plain type, **derive** the sparse overlay by reflection | one declaration; costs a small mapping template (`T` → `Nullable!T`, recursively) |

   **Recommendation: derive it.** `sparkles:wired` is already compile-time
   reflection over the same aggregate, so the overlay type is the same trick
   applied once more, and it keeps the single-declaration property that makes
   `CFG9`'s generated schema honest. Verified as feasible: `wired`'s codec
   handles `Nullable!T`/`Optional!T`/`Ternary` (`json/codec.d`), so a derived
   overlay decodes without further work.

4. **`CFG11` and precedence.** If a runtime toggle is persisted while a CLI flag
   set that same value, saving must write the _toggled_ value, not the flag —
   otherwise the save silently bakes in a one-off invocation. Needs stating as a
   rule before implementation.

## Relationship to existing specs

| Piece                                                         | Role                                                                   |
| ------------------------------------------------------------- | ---------------------------------------------------------------------- |
| [`feature-requirements.md`](./feature-requirements.md) `CLI*` | the flags this layers under; every `CLI` option keeps winning          |
| [`android.md`](./android.md) `AND*`                           | why `CFG12` is not optional — no command line exists there             |
| `apps/hue/src/keymap.d`                                       | the table `CFG6` overlays — made one by [lantern](./lantern.md) `KEY1` |
| [`lantern.md`](./lantern.md) `KEY12`                          | the overlay requirement, stated from the keymap's side                 |
| `sparkles:wired`                                              | the reflection that makes `CFG1` and `CFG9` one mechanism              |
| `sparkles.core_cli.common_dirs`                               | the platform-correct locations for `CFG2`                              |
