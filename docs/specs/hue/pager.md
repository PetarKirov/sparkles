# `hue` as a pager — Feature Requirements (`PAG`/`PIN`/`STR`)

_**Status:** design · **Date:** 2026-08-08 · **Scope:** hue's place in the shell
— when it pages, what it pages **with**, how it renders input that arrives
already formatted (`$MANPAGER`, `git core.pager`, a `--help` dump), and how it
follows input that has not finished arriving (`tail -f`, `less +F`). Registered
as [`CLI19`](./feature-requirements.md)/[`CLI25`](./feature-requirements.md)._

## Why this exists

[bat](https://github.com/sharkdp/bat)'s pager story is a large part of what
makes it a `cat` replacement people actually alias: `bat` on a long file behaves
like `less`, on a short one like `cat`, and `export MANPAGER="sh -c 'col -bx |
bat -l man -p'"` gives you highlighted man pages. bat gets there by **shelling
out to `less`** — `pager.rs` and `less.rs` between them resolve `$BAT_PAGER`,
`$PAGER`, sniff the `less` version to decide which flags are safe, and fall back
to a bundled `minus`.

hue should not copy that. hue **already has** the thing bat is shelling out to
acquire: a full-screen terminal viewer ([tui.md](./tui.md)) with scrolling, a
scrollbar, mouse, search, selection and OSC 52 copy — strictly more than `less`
offers, painted from the same widget views as the window. Spawning `less` to
scroll a document hue can already scroll would be an odd thing for hue to do.

So the doctrine is: **hue's own TUI is hue's pager**, `--pager=<cmd>` is the
escape hatch for people who want their own, and the genuinely new work is not
paging at all — it is teaching hue to render input that is _already formatted_,
so it can sit where `less` sits in `$MANPAGER` and `git config core.pager`.

## Design & rationale

### Paging is a sink choice, not a subprocess (`PAG2`)

hue already picks a backend once ([`MOD6`](./feature-requirements.md)
`pickBackend`) and dispatches to one of four sinks. "Page this" is a **fifth
input to that decision**, not a new stage bolted after the ANSI sink:

| Condition                                         | Result                                     |
| ------------------------------------------------- | ------------------------------------------ |
| stdout not a tty                                  | ANSI sink, whole document (`MOD3`)         |
| tty, render fits the viewport, `--paging=auto`    | ANSI sink, whole document — the `cat` feel |
| tty, render exceeds the viewport, `--paging=auto` | TUI sink                                   |
| `--paging=always`                                 | TUI sink regardless of length              |
| `--paging=never` / `-P`                           | ANSI sink regardless of length             |
| `--pager=<cmd>` set                               | ANSI sink, piped to `<cmd>`                |

The one new fact this requires is **how tall the render is**, which the
`ViewerModel` relayout already computes for the scrollbar. Nothing else in the
dispatch changes, which is the point: hue gains bat's most-loved behaviour by
routing an existing decision differently rather than by growing a pager.

### `--gui` and paging are orthogonal

A display-backed launch opens the window, which is by construction paged. The
paging decision only ever selects between hue's two **terminal** sinks; on a
GUI-enabled autodetected launch it is not consulted. `--paging=always` does not
imply `--tui`.

### The real work: pre-formatted input (`PIN`)

To be `$MANPAGER`, `core.pager` or the sink of `hue --help | hue`, hue must
render bytes that are **already styled** — SGR sequences from `git diff`, and
`man`'s ancient backspace overstrike (`_\bt` for underline, `t\bt` for bold).
Today hue would highlight those bytes as source text, which is wrong twice over:
the escapes show up as content, and the content shows up unstyled.

hue is unusually well placed here. `ansi_model.d` and the off-screen ghostty VT
already decode SGR into hue's presentation cells — that is how ` ```ansi ` fences
render in the markdown preview ([`MDP12`](./gui.md)). A **pre-formatted content
kind** is therefore that decoder pointed at the whole input instead of at one
fence, plus a small overstrike pass. That is a genuinely small feature that
unlocks two of bat's headline integrations, which is exactly the trade this
scope is meant to favour.

It also composes with the sanitizer: a document hue is deliberately interpreting
as ANSI is precisely the region where [`TXT2`](./feature-requirements.md) must
_not_ neutralize escapes, and the content kind is what tells it so.

### Streaming is the same seam, not finished (`STR`)

`tail -f logfile | hue` and `less +F` are the same feature seen from two sides:
input that has not ended. hue's frame loop is already event-driven
(`sparkles:event-horizon` supplies `pollAdd` and `Ticker`), so following a
growing fd costs a registration rather than a poll loop. The
honest limitation is highlighting: tree-sitter is re-run over the accumulated
text on append, so a partial construct at the tail may highlight oddly until the
next chunk lands. Incremental reparse is a `sparkles:syntax` roadmap item and
stays there.

### Deliberate omissions

| Not doing                       | Why                                                                                                                                                              |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `less` version detection        | bat sniffs `less --version` to decide which flags are safe. hue passes `-R` when it spawns a pager named `less` with no flags of its own, and otherwise nothing. |
| A bundled pager (bat's `minus`) | hue's TUI is the bundled pager.                                                                                                                                  |
| `$LESSOPEN` / `$LESSCLOSE`      | Input preprocessing is a real feature but a separate one — deferred as [`DEF26`](./feature-requirements.md).                                                     |
| Output-is-input cycle detection | bat's `clircle` guard against `bat file > file`. Worth revisiting; not load-bearing for the pager doctrine.                                                      |

## Paging (`PAG`)

| ID   | Requirement                                                                                                                                                                                                                                                                                              | Status      | Traces to                                                |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------- |
| PAG1 | `--paging=auto\|never\|always` must select whether a terminal launch pages, with `-P` an alias for `never` and `-pp` implying it ([`STY5`](./chrome.md)). The default is `auto`.                                                                                                                         | not started | `CliParams.paging`; `pickBackend`                        |
| PAG2 | Under `auto`, hue must page when stdout is a tty **and** the laid-out render is taller than the viewport, and emit the whole document to ANSI otherwise — so short files feel like `cat` and long ones like `less`. The height comes from the existing `ViewerModel` relayout, not a second measurement. | not started | `viewer_model` layout height; `pickBackend`              |
| PAG3 | Paging must mean **hue's own TUI** ([tui.md](./tui.md)) over the same document, not a spawned process: no bundled pager, no `less`-version detection.                                                                                                                                                    | not started | `runTuiSink` reached from the paging decision            |
| PAG4 | `--pager=<cmd>`, `$HUE_PAGER` or `$PAGER` (in that precedence) must instead pipe the ANSI emit to `<cmd>`. When the command is bare `less`, hue must add `-R`; otherwise the user's arguments are passed through untouched. A pager that fails to spawn must warn and fall through to `PAG3`.            | not started | proposed `pager.d` `spawnPager`                          |
| PAG5 | Under a pager (internal or external) hue must behave as if `--color=always --decorations=always`, since stdout is a pipe but the eventual consumer is a terminal.                                                                                                                                        | not started | `CLR2`/`STY4` policy resolution                          |
| PAG6 | `--set-terminal-title` must set the terminal title to the document's title for the lifetime of a paged session and restore it on exit.                                                                                                                                                                   | not started | `sparkles:tui` lifecycle; OSC 2                          |
| PAG7 | hue must be documented and shaped as a drop-in for `$PAGER`, `$MANPAGER` and `git config core.pager` — which requires `PIN1`, `CAT2` (stdin), `STY5` (`-p`) and `PAG5`, and nothing else. The README must carry the three recipes.                                                                       | not started | `README.md`; `PIN1`; [`CAT2`](./feature-requirements.md) |

## Pre-formatted input (`PIN`)

| ID   | Requirement                                                                                                                                                                                                                                                                     | Status      | Traces to                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------- |
| PIN1 | hue must recognize a **pre-formatted** content kind — input that is already styled — and render it by decoding rather than highlighting it, in every sink. It is a `ContentKind` beside code / markdown / twoslash / diff, produced by the pipeline like any other.             | not started | `document.ContentKind.preformatted`; `MOD9` doctrine |
| PIN2 | SGR-styled input must be decoded through the existing `ansi_model.d` path (the off-screen ghostty VT that ` ```ansi ` fences already use), not a second parser.                                                                                                                 | not started | `ansi_model.d`; [`MDP12`](./gui.md)                  |
| PIN3 | `man`-style backspace overstrike (`x\bx` = bold, `_\bx` = underline) must be decoded to the equivalent styling, so `$MANPAGER` works without `col -bx`.                                                                                                                         | not started | proposed `overstrike.d` (pure, `@nogc`)              |
| PIN4 | Detection must be automatic for non-tty stdin that contains SGR or overstrike sequences, and forceable with `--preformatted`; `--language`/`-l` must still win, so `-l man` or `-l diff` overrides the sniff.                                                                   | not started | `looksPreformatted`; `LNG2` cascade                  |
| PIN5 | A pre-formatted document must be exempt from ANSI stripping and sanitizing ([`TXT2`/`TXT3`](./feature-requirements.md)) — hue is interpreting those bytes on purpose — while every **other** content kind stays subject to them.                                                | not started | `TXT2`; `ContentKind` gating                         |
| PIN6 | Selection and copy over a pre-formatted document must yield the **decoded text** by default, with the escape-preserving variant reachable through the existing `--ansi-copy=raw\|strip` toggle ([`CLI10`](./feature-requirements.md)), which already names exactly this choice. | not started | `CliParams.ansiCopy`; [`SEL7`](./gui.md)             |

## Streaming & follow (`STR`)

| ID   | Requirement                                                                                                                                                                                                                                                                     | Status      | Traces to                                      |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------- |
| STR1 | `-u`/`--unbuffered` must render input incrementally as it arrives rather than waiting for EOF, so `tail -f logfile \| hue -u` shows lines as they are written.                                                                                                                  | not started | proposed `stream.d`; `DocumentPipeline.append` |
| STR2 | The interactive sinks must offer a **follow** mode (`F`, after `less +F`): the viewport pins to the tail as content arrives, and any navigation key releases it. Following must be entered automatically under `-u` on a tty and reported in the status line.                   | not started | `tui.d`; `keymap.d`                            |
| STR3 | Appended input must be registered with the event loop (`sparkles:event-horizon` `pollAdd`), never polled on a timer, so a quiet stream costs no wakeups.                                                                                                                        | not started | `sparkles:event-horizon`; the TUI frame loop   |
| STR4 | Highlighting under streaming must be re-run over the accumulated text on append and may be imperfect at the tail while a construct is incomplete; line numbers, wrapping and search must stay correct regardless. Incremental reparse is out of scope here (`sparkles:syntax`). | not started | `sparkles:syntax` incremental roadmap          |
| STR5 | A growing **file** target should be followed as well as a growing pipe, so `hue -u ./build.log` matches `tail -f ./build.log \| hue -u`.                                                                                                                                        | not started | `stream.d` file watch                          |

## Module coverage

| Source (proposed)           | Key symbols                                           | Requirements          |
| --------------------------- | ----------------------------------------------------- | --------------------- |
| `apps/hue/src/pager.d`      | `PagingMode`, `shouldPage`, `spawnPager`              | `PAG1`–`PAG6`         |
| `apps/hue/src/overstrike.d` | `decodeOverstrike` (pure, `@nogc`)                    | `PIN3`                |
| `apps/hue/src/document.d`   | `ContentKind.preformatted`, `looksPreformatted`       | `PIN1`, `PIN4`–`PIN5` |
| `apps/hue/src/ansi_model.d` | the existing SGR → cell decoder, reused whole         | `PIN2`                |
| `apps/hue/src/stream.d`     | incremental append, follow state, the fd registration | `STR1`–`STR5`         |

→ [Feature requirements](./feature-requirements.md) · [Document chrome](./chrome.md) · [TUI](./tui.md) · [Overview](./index.md)
