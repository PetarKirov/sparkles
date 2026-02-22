# TUI Libraries Catalog

A breadth-first survey of terminal user interface (TUI) libraries across programming languages. This catalog covers rendering models, architecture patterns, and abstraction levels to inform the design of TUI capabilities for Sparkles.

## Rust

| Library                   | Rendering Model | Architecture    | Abstraction | Status       | Links                                                                                 |
| ------------------------- | --------------- | --------------- | ----------- | ------------ | ------------------------------------------------------------------------------------- |
| **[Ratatui](ratatui.md)** | Immediate       | App-driven loop | Mid-level   | Active       | [repo](https://github.com/ratatui/ratatui) · [docs](https://ratatui.rs)               |
| **[Cursive](cursive.md)** | Retained        | Callback-based  | High-level  | Maintained   | [repo](https://github.com/gyscos/cursive) · [docs](https://docs.rs/cursive)           |
| **Crossterm**             | N/A (backend)   | Imperative      | Low-level   | Active       | [repo](https://github.com/crossterm-rs/crossterm) · [docs](https://docs.rs/crossterm) |
| **Termion**               | N/A (backend)   | Imperative      | Low-level   | Maintained   | [repo](https://github.com/redox-os/termion)                                           |
| **Termwiz**               | Immediate       | Imperative      | Mid-level   | Active       | [repo](https://github.com/wez/wezterm/tree/main/termwiz)                              |
| **Dioxus TUI**            | Retained        | React-like      | High-level  | Experimental | [repo](https://github.com/DioxusLabs/dioxus)                                          |

## Python

| Library                   | Rendering Model | Architecture      | Abstraction | Status       | Links                                                                                                                  |
| ------------------------- | --------------- | ----------------- | ----------- | ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| **[Textual](textual.md)** | Retained        | CSS + widgets     | High-level  | Active       | [repo](https://github.com/Textualize/textual) · [docs](https://textual.textualize.io)                                  |
| **Rich**                  | Immediate       | Render-to-console | Mid-level   | Active       | [repo](https://github.com/Textualize/rich) · [docs](https://rich.readthedocs.io)                                       |
| **Urwid**                 | Retained        | Widget tree       | Mid-level   | Maintained   | [repo](https://github.com/urwid/urwid) · [docs](https://urwid.org)                                                     |
| **npyscreen**             | Retained        | Form-based        | High-level  | Unmaintained | [repo](https://github.com/npcole/npyscreen)                                                                            |
| **prompt_toolkit**        | Retained        | Component-based   | Mid-level   | Active       | [repo](https://github.com/prompt-toolkit/python-prompt-toolkit) · [docs](https://python-prompt-toolkit.readthedocs.io) |
| **curses** (stdlib)       | Immediate       | Imperative        | Low-level   | Stable       | [docs](https://docs.python.org/3/library/curses.html)                                                                  |

## JavaScript / TypeScript

| Library           | Rendering Model     | Architecture         | Abstraction | Status       | Links                                             |
| ----------------- | ------------------- | -------------------- | ----------- | ------------ | ------------------------------------------------- |
| **[Ink](ink.md)** | Retained            | React components     | High-level  | Active       | [repo](https://github.com/vadimdemedes/ink)       |
| **Blessed**       | Retained            | Widget tree          | High-level  | Unmaintained | [repo](https://github.com/chjj/blessed)           |
| **Neo-blessed**   | Retained            | Widget tree          | High-level  | Low activity | [repo](https://github.com/embarklabs/neo-blessed) |
| **Terminal Kit**  | Hybrid              | Imperative + widgets | Mid-level   | Maintained   | [repo](https://github.com/cronvel/terminal-kit)   |
| **Yoga (layout)** | N/A (layout engine) | Flexbox              | Low-level   | Active       | [repo](https://github.com/nicolo-ribaudo/yoga)    |

## Neovim / Lua

| Library                           | Rendering Model            | Architecture              | Abstraction | Status | Links                                                                                                      |
| --------------------------------- | -------------------------- | ------------------------- | ----------- | ------ | ---------------------------------------------------------------------------------------------------------- |
| **[Snacks.nvim](snacks-nvim.md)** | Retained (buffers/windows) | Event-driven plugin suite | High-level  | Active | [repo](https://github.com/folke/snacks.nvim) · [docs](https://github.com/folke/snacks.nvim/tree/main/docs) |

## Go

| Library                        | Rendering Model | Architecture    | Abstraction | Status     | Links                                              |
| ------------------------------ | --------------- | --------------- | ----------- | ---------- | -------------------------------------------------- |
| **[Bubble Tea](bubbletea.md)** | Immediate       | Elm / MVU       | Mid-level   | Active     | [repo](https://github.com/charmbracelet/bubbletea) |
| **Lip Gloss**                  | N/A (styling)   | Builder pattern | Mid-level   | Active     | [repo](https://github.com/charmbracelet/lipgloss)  |
| **Bubbles**                    | Immediate       | MVU components  | Mid-level   | Active     | [repo](https://github.com/charmbracelet/bubbles)   |
| **[tview](tview.md)**          | Retained        | Widget tree     | High-level  | Active     | [repo](https://github.com/rivo/tview)              |
| **gocui**                      | Retained        | View-based      | Mid-level   | Maintained | [repo](https://github.com/jroimartin/gocui)        |
| **tcell**                      | N/A (backend)   | Imperative      | Low-level   | Active     | [repo](https://github.com/gdamore/tcell)           |
| **Termbox-go**                 | N/A (backend)   | Imperative      | Low-level   | Archived   | [repo](https://github.com/nsf/termbox-go)          |

## Haskell

| Library               | Rendering Model | Architecture                  | Abstraction | Status | Links                                                                                            |
| --------------------- | --------------- | ----------------------------- | ----------- | ------ | ------------------------------------------------------------------------------------------------ |
| **[Brick](brick.md)** | Retained        | Pure functional / declarative | High-level  | Active | [repo](https://github.com/jtdaugherty/brick) · [docs](https://hackage.haskell.org/package/brick) |
| **Vty**               | Immediate       | Imperative                    | Low-level   | Active | [repo](https://github.com/jtdaugherty/vty)                                                       |

## C / C++

| Library                       | Rendering Model   | Architecture            | Abstraction | Status     | Links                                                                             |
| ----------------------------- | ----------------- | ----------------------- | ----------- | ---------- | --------------------------------------------------------------------------------- |
| **[Notcurses](notcurses.md)** | Retained (planes) | Imperative + planes     | Mid-level   | Active     | [repo](https://github.com/dankamongmen/notcurses) · [docs](https://notcurses.com) |
| **ncurses**                   | Immediate         | Imperative              | Low-level   | Stable     | [docs](https://invisible-island.net/ncurses/)                                     |
| **[FTXUI](ftxui.md)**         | Immediate         | Functional components   | Mid-level   | Active     | [repo](https://github.com/ArthurSonzogni/FTXUI)                                   |
| **[ImTui](imtui.md)**         | Immediate         | Dear ImGui for terminal | Mid-level   | Maintained | [repo](https://github.com/ggerganov/imtui)                                        |
| **CDK**                       | Retained          | Widget-based            | High-level  | Maintained | [docs](https://invisible-island.net/cdk/)                                         |
| **Termbox2**                  | N/A (backend)     | Imperative              | Low-level   | Active     | [repo](https://github.com/termbox/termbox2)                                       |

## D

| Library           | Rendering Model | Architecture         | Abstraction | Status       | Links                                      |
| ----------------- | --------------- | -------------------- | ----------- | ------------ | ------------------------------------------ |
| **Scone**         | Immediate       | Imperative           | Low-level   | Low activity | [repo](https://github.com/Elronnd/scone)   |
| **Arsd terminal** | Hybrid          | Imperative + widgets | Mid-level   | Active       | [repo](https://github.com/adamdruppe/arsd) |
| **Nice**          | N/A (backend)   | Imperative           | Low-level   | Unmaintained | [repo](https://github.com/zhfkt/nice)      |

## Java / Kotlin

| Library                 | Rendering Model    | Architecture | Abstraction | Status     | Links                                         |
| ----------------------- | ------------------ | ------------ | ----------- | ---------- | --------------------------------------------- |
| **Lanterna**            | Retained           | Widget tree  | High-level  | Maintained | [repo](https://github.com/mabe02/lanterna)    |
| **JLine**               | N/A (line editing) | Imperative   | Low-level   | Active     | [repo](https://github.com/jline/jline3)       |
| **[Mosaic](mosaic.md)** | Retained           | Compose-like | High-level  | Active     | [repo](https://github.com/JakeWharton/mosaic) |

## Ruby

| Library          | Rendering Model | Architecture      | Abstraction | Status     | Links                                      |
| ---------------- | --------------- | ----------------- | ----------- | ---------- | ------------------------------------------ |
| **TTY**          | Hybrid          | Component toolkit | Mid-level   | Maintained | [repo](https://github.com/piotrmurach/tty) |
| **Curses** (gem) | Immediate       | Imperative        | Low-level   | Maintained | [repo](https://github.com/ruby/curses)     |

## Zig

| Library                     | Rendering Model | Architecture     | Abstraction | Status | Links                                          |
| --------------------------- | --------------- | ---------------- | ----------- | ------ | ---------------------------------------------- |
| **Tuile**                   | Immediate       | Functional       | Mid-level   | Early  | [repo](https://github.com/unvariant/tuile)     |
| **zbox**                    | Immediate       | Ratatui-inspired | Mid-level   | Active | [repo](https://github.com/sackosoft/zbox)      |
| **[libvaxis](libvaxis.md)** | Immediate       | Imperative       | Low-level   | Active | [repo](https://github.com/rockorager/libvaxis) |

## Nim

| Library     | Rendering Model | Architecture    | Abstraction | Status       | Links                                        |
| ----------- | --------------- | --------------- | ----------- | ------------ | -------------------------------------------- |
| **Illwill** | Immediate       | Imperative      | Low-level   | Maintained   | [repo](https://github.com/johnnovak/illwill) |
| **nimbox**  | Immediate       | Termbox binding | Low-level   | Unmaintained | [repo](https://github.com/dom96/nimbox)      |

## OCaml

| Library                 | Rendering Model | Architecture        | Abstraction | Status     | Links                                                  |
| ----------------------- | --------------- | ------------------- | ----------- | ---------- | ------------------------------------------------------ |
| **[Nottui](nottui.md)** | Retained        | Functional reactive | Mid-level   | Maintained | [repo](https://github.com/let-def/lwd)                 |
| **Lambda-term**         | Retained        | Widget tree         | Mid-level   | Maintained | [repo](https://github.com/ocaml-community/lambda-term) |

## Clojure

| Library              | Rendering Model | Architecture | Abstraction | Status       | Links                                                |
| -------------------- | --------------- | ------------ | ----------- | ------------ | ---------------------------------------------------- |
| **Clansi**           | N/A (styling)   | Functional   | Low-level   | Maintained   | [repo](https://github.com/ams-clj/clansi)            |
| **clojure-lanterna** | Retained        | Wrapper      | Mid-level   | Unmaintained | [repo](https://github.com/MultiMUD/clojure-lanterna) |

## Scala

| Library   | Rendering Model | Architecture | Abstraction | Status     | Links                                        |
| --------- | --------------- | ------------ | ----------- | ---------- | -------------------------------------------- |
| **Fansi** | N/A (styling)   | Functional   | Low-level   | Maintained | [repo](https://github.com/com-lihaoyi/fansi) |

---

## Architectural Taxonomy

### By Rendering Model

| Model         | Description                                                          | Libraries                                                                  |
| ------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **Immediate** | Application redraws entire UI each frame; framework diffs or flushes | Ratatui, FTXUI, ImTui, Bubble Tea, ncurses                                 |
| **Retained**  | Framework maintains widget tree; updates propagate automatically     | Textual, Brick, Blessed, Ink, Cursive, tview, Lanterna, Notcurses (planes) |
| **Hybrid**    | Mix of retained state with explicit render calls                     | Terminal Kit, arsd terminal, TTY                                           |

### By Architecture Pattern

| Pattern                   | Description                                       | Libraries                                         |
| ------------------------- | ------------------------------------------------- | ------------------------------------------------- |
| **Elm / MVU**             | Model-View-Update loop with messages              | Bubble Tea, Brick (partially)                     |
| **React / Component**     | Declarative components with props, reconciliation | Ink, Dioxus TUI, Mosaic                           |
| **Pure Functional**       | Immutable state, declarative combinators          | Brick, Nottui                                     |
| **Widget Tree**           | Mutable tree of widget objects                    | Textual, Cursive, tview, Urwid, Lanterna, Blessed |
| **Imperative**            | Direct terminal manipulation                      | ncurses, Crossterm, tcell, Termbox                |
| **Functional Components** | Stateless functions returning UI trees            | FTXUI                                             |

### By Layout Approach

| Approach               | Description                                     | Libraries                                        |
| ---------------------- | ----------------------------------------------- | ------------------------------------------------ |
| **CSS / Flexbox**      | Web-inspired box model and flex layout          | Textual (CSS subset), Ink (Yoga/flexbox)         |
| **Constraint-based**   | Size constraints flow through widget tree       | Ratatui, Brick, tview                            |
| **Combinators**        | Compositional layout via functional combinators | Brick (`hBox`, `vBox`, `padded`)                 |
| **Manual / Absolute**  | Explicit coordinates and sizes                  | ncurses, Notcurses (planes), Termbox             |
| **Declarative Splits** | Layout DSL with percentage/fixed splits         | Ratatui (`Layout::default().constraints([...])`) |

---

## Detailed Studies

The following libraries are analyzed in depth:

- **[Ratatui](ratatui.md)** — Rust immediate-mode TUI with constraint-based layout
- **[Ink](ink.md)** — React for the terminal (JavaScript)
- **[Textual](textual.md)** — CSS-styled retained-mode framework (Python)
- **[Bubble Tea](bubbletea.md)** — Elm Architecture for terminals (Go)
- **[Brick](brick.md)** — Pure functional declarative TUI (Haskell)
- **[Notcurses](notcurses.md)** — Modern ncurses successor (C)
- **[FTXUI](ftxui.md)** — Functional DOM-like components with flexbox layout (C++)
- **[Cursive](cursive.md)** — Retained-mode callback-based view hierarchy (Rust)
- **[Mosaic](mosaic.md)** — Jetpack Compose runtime for terminals (Kotlin)
- **[Nottui](nottui.md)** — Incremental computation / functional reactive TUI (OCaml)
- **[libvaxis](libvaxis.md)** — comptime-powered, allocator-aware terminal library (Zig)
- **[tview](tview.md)** — Retained widget tree with flex layout (Go)
- **[ImTui](imtui.md)** — Dear ImGui paradigm adapted for terminals (C++)
- **[Snacks.nvim](snacks-nvim.md)** — Neovim UI toolkit built on floating windows and layouts

See the **[Comparison](comparison.md)** for cross-library synthesis and design recommendations for Sparkles.

See the **[Tree-View Case Study](tree-view-case-study.md)** for a focused analysis of tree-view implementations across libraries.
