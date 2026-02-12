# Nottui (OCaml)

A reactive terminal UI library built on incremental computation primitives, where the UI is defined as a dependency-tracked reactive document that automatically recomputes only the affected subtrees when state changes.

| Field         | Value                                                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language      | OCaml                                                                                                                       |
| License       | MIT                                                                                                                         |
| Repository    | [github.com/let-def/lwd](https://github.com/let-def/lwd) (monorepo: Lwd + Nottui)                                           |
| Documentation | [README](https://github.com/let-def/lwd/blob/master/lib/nottui/README.md) / [opam](https://opam.ocaml.org/packages/nottui/) |
| Install       | `opam install nottui`                                                                                                       |
| Author        | Frederic Bour (also known for Merlin, the OCaml IDE service)                                                                |

---

## Overview

### What It Solves

Nottui provides a fundamentally different approach to terminal UI: instead of immediate-mode full redraws or retained-mode virtual DOM diffing, it uses **incremental computation** to build UIs as reactive documents. When a piece of state changes, only the computations that depend on that state are re-evaluated -- not the entire UI tree. This is the same paradigm as a spreadsheet: change one cell, and only the formulas that reference it recalculate.

### Design Philosophy

The UI is a **value that changes over time**. Rather than imperatively mutating a DOM or redrawing every frame, the developer declares how UI fragments depend on reactive variables. The runtime maintains a dependency graph and propagates changes minimally. This is functional reactive programming applied to terminal interfaces, with automatic dependency tracking replacing manual subscriptions or dirty flags.

### Lineage

Nottui is not a standalone library. It is a composition of three layers:

1. **Lwd (Lightweight Documents)** -- the incremental computation engine. Provides the core `'a Lwd.t` type (a reactive value that tracks its dependencies), `Lwd.var` (mutable reactive cells), and combinators (`map`, `map2`, `bind`, `join`) for composing reactive computations into a DAG. This layer knows nothing about terminals -- it is a general-purpose incremental computation library.

2. **Nottui** -- the TUI widget layer built on Lwd. Defines `Ui.t` (a terminal UI element with layout, events, and rendering), composition combinators (`join_x`, `join_y`, `hcat`, `vcat`), event dispatch, and focus management. A Nottui UI is an `Ui.t Lwd.t` -- a reactive value producing UI trees.

3. **Notty** -- the terminal rendering backend. Provides the `Notty.image` type (a 2D grid of styled characters), styled text construction, image composition operators, and terminal I/O. Nottui renders its `Ui.t` trees into Notty images for display.

Frederic Bour created Lwd and Nottui. He is also the author of **Merlin**, the widely-used OCaml IDE service providing autocompletion, type information, and error reporting. This background in language tooling and incremental analysis directly informs Lwd's design -- Merlin itself must incrementally reprocess source code as the user edits, a problem structurally similar to incrementally updating a UI.

---

## Architecture

### Incremental Computation Model

The core insight of Lwd is that UI updates are typically **sparse** -- a single user action changes one or two state variables, affecting a small fraction of the UI tree. Lwd exploits this by maintaining a **directed acyclic graph (DAG)** of computations with automatic dependency tracking.

#### `'a Lwd.t` -- Reactive Values

The central type is `'a Lwd.t`, representing a value of type `'a` that may change over time. It is analogous to a spreadsheet cell: it may be a constant, or it may be computed from other reactive values. When any input changes, dependent outputs are automatically invalidated.

```ocaml
(* A reactive value is a node in the computation DAG *)
type +'a t

(* A constant reactive value -- never changes *)
val pure : 'a -> 'a t
val return : 'a -> 'a t
```

#### `Lwd.var` -- Mutable Reactive Variables

Source nodes in the DAG are created with `Lwd.var`. These are the only mutable entry points into the reactive graph:

```ocaml
(* Create a mutable reactive variable *)
val var : 'a -> 'a var

(* Read the variable's value within the reactive graph (creates a dependency) *)
val get : 'a var -> 'a t

(* Read the variable's value immediately (no dependency tracking) *)
val peek : 'a var -> 'a

(* Update the variable, invalidating all dependents *)
val set : 'a var -> 'a -> unit
```

The distinction between `get` and `peek` is critical. `get` returns an `'a Lwd.t`, registering the caller as a dependent. `peek` returns a plain `'a` with no dependency -- useful inside event handlers where you want the current value without creating a reactive dependency.

#### Combinators -- Building the DAG

Lwd implements the standard functional programming abstractions (Functor, Applicative, Monad) for composing reactive values:

```ocaml
(* Functor: transform a reactive value *)
val map : 'a t -> f:('a -> 'b) -> 'b t

(* Applicative: combine two independent reactive values *)
val map2 : 'a t -> 'b t -> f:('a -> 'b -> 'c) -> 'c t

(* Monad: nest reactive computations (use sparingly) *)
val bind : 'a t -> f:('a -> 'b t) -> 'b t
val join : 'a t t -> 'a t
```

`map` and `map2` create static edges in the DAG -- the dependency structure is fixed at construction time. `bind` and `join` create **dynamic** edges: the shape of the DAG itself depends on a reactive value. This is powerful but more expensive, as the runtime must rewire dependencies when the structure changes.

#### Observation and Sampling

To consume the reactive graph, you create a **root** -- an observation point:

```ocaml
type 'a root

(* Create a root observation point *)
val observe : ?on_invalidate:('a -> unit) -> 'a t -> 'a root

(* Compute the current value (triggers recomputation if damaged) *)
val sample : release_queue -> 'a root -> 'a

(* Check if any input has changed since last sample *)
val is_damaged : 'a root -> bool

(* Stop observing -- releases the graph for GC *)
val release : 'a root -> unit
```

A root has three states:

1. **Released** -- not observing, graph can be GC'd
2. **Sampled** -- graph is live, value is current
3. **Damaged** -- an input changed, value is stale, next `sample` will recompute

#### Reactive Collections with `Lwd_table`

For collections where items are inserted, removed, or reordered, `Lwd_table` provides a reactive doubly-linked list:

```ocaml
type 'a t    (* A reactive table *)
type 'a row  (* A handle to a row in the table *)

val make    : unit -> 'a t
val append  : ?set:'a -> 'a t -> 'a row
val prepend : ?set:'a -> 'a t -> 'a row
val before  : ?set:'a -> 'a row -> 'a row
val after   : ?set:'a -> 'a row -> 'a row
val remove  : 'a row -> unit
val set     : 'a row -> 'a -> unit
val get     : 'a row -> 'a option

(* Reactively reduce the table using a monoid *)
val reduce     : 'a Lwd_utils.monoid -> 'a t -> 'a Lwd.t
val map_reduce : ('a row -> 'a -> 'b) -> 'b Lwd_utils.monoid -> 'a t -> 'b Lwd.t
```

When a row is inserted, removed, or modified, only the affected portion of the reduction is recomputed. This makes `Lwd_table` efficient for dynamic lists, log views, or any collection that changes incrementally.

### How It Differs from Other Approaches

| Approach                             | Update Strategy                     | Cost of Sparse Update               | Example            |
| ------------------------------------ | ----------------------------------- | ----------------------------------- | ------------------ |
| **Immediate mode** (full redraw)     | Redraw entire UI every frame        | O(n) where n = total UI size        | Ratatui, Notcurses |
| **Retained mode** (virtual DOM diff) | Diff old tree vs new tree           | O(n) for the diff pass              | React/Ink, Textual |
| **Incremental computation** (Lwd)    | Recompute only invalidated subgraph | O(k) where k = changed dependencies | Nottui             |

The key advantage: when a single `Lwd.var` changes, only the `map`/`map2`/`bind` nodes that transitively depend on it are re-evaluated. In a large UI with hundreds of widgets, changing one counter value might recompute 3-4 nodes instead of the entire tree. There is no O(n) diff pass and no full redraw.

---

## Terminal Backend

### Notty

Nottui renders to the terminal via **Notty**, a declarative terminal graphics library for OCaml. Notty's philosophy is "describe what should be seen" rather than issuing terminal control sequences imperatively.

#### Image Model

Notty's central type is `Notty.image` -- a 2D grid of Unicode characters with per-cell styling. Images are immutable values that compose with pure functions:

```ocaml
(* Primitive image constructors *)
val I.string  : attr -> string -> image    (* styled text *)
val I.uchar   : attr -> Uchar.t -> int -> int -> image  (* repeated character *)
val I.char    : attr -> char -> int -> int -> image
val I.void    : int -> int -> image        (* empty space *)

(* Image composition *)
val I.(<|>) : image -> image -> image      (* horizontal composition *)
val I.(<->) : image -> image -> image      (* vertical composition *)
val I.(</>) : image -> image -> image      (* overlay/superposition *)
```

#### Capabilities

| Capability | Details                                       |
| ---------- | --------------------------------------------- |
| Unicode    | Full Unicode support, multi-column characters |
| Color      | 24-bit true color, 256-color, 16-color        |
| Styling    | Bold, underline, reverse, blink               |
| Input      | Keyboard events, mouse events                 |
| Platform   | Pure OCaml core; Unix module for terminal I/O |

Notty was inspired by Haskell's Vty library and shares its declarative, compositional approach to terminal rendering.

---

## Layout System

### Combinator-Based Reactive Layout

Nottui's layout system uses combinators for spatial composition, similar to Brick's approach but with reactivity built in at the foundation. Every layout combinator works with both plain `Ui.t` values and reactive `Ui.t Lwd.t` values.

### Layout Specification

Each UI element carries a `layout_spec` describing its space requirements:

```ocaml
type layout_spec = {
  w  : int;   (* minimum/fixed width *)
  h  : int;   (* minimum/fixed height *)
  sw : int;   (* stretch factor, horizontal (0 = fixed) *)
  sh : int;   (* stretch factor, vertical   (0 = fixed) *)
}
```

The stretch factors (`sw`, `sh`) control how extra space is distributed. A widget with `sw = 0` has a fixed width; one with `sw = 1` will expand to fill available horizontal space. When multiple stretchable widgets share a container, space is divided proportionally by their stretch factors.

### Core Layout Combinators

| Combinator      | Purpose                                                       |
| --------------- | ------------------------------------------------------------- |
| `Ui.atom img`   | Leaf widget from a Notty image                                |
| `Ui.space w h`  | Empty space with given dimensions                             |
| `Ui.empty`      | Zero-size empty widget                                        |
| `Ui.join_x a b` | Horizontal composition (a left of b)                          |
| `Ui.join_y a b` | Vertical composition (a above b)                              |
| `Ui.join_z a b` | Overlay/superposition (a on top of b)                         |
| `Ui.hcat list`  | Horizontal concatenation of a list                            |
| `Ui.vcat list`  | Vertical concatenation of a list                              |
| `Ui.zcat list`  | Overlay concatenation of a list                               |
| `Ui.resize`     | Override layout spec (set fixed dimensions, stretch, gravity) |
| `Ui.shift_area` | Scroll/pan the content (positive = crop, negative = pad)      |

### Gravity

The `Gravity` module controls alignment within allocated space:

```ocaml
type direction = [ `Negative | `Neutral | `Positive ]
type t  (* pairs horizontal and vertical gravity *)

val make : h:direction -> v:direction -> t

(* Examples:
   `Negative, `Negative  = top-left
   `Neutral,  `Neutral   = center
   `Positive, `Positive  = bottom-right *)
```

When a widget receives more space than its minimum, gravity determines where the widget sits within that space.

### Layout Example

```ocaml
open Nottui
open Notty

(* A simple two-panel layout with a status bar *)
let sidebar items =
  items
  |> List.map (fun name ->
    Ui.atom (I.string A.(fg green) name))
  |> Ui.vcat

let main_content text =
  Ui.atom (I.string A.empty text)
  |> Ui.resize ~w:0 ~sw:1  (* stretch horizontally *)

let status_bar msg =
  Ui.atom (I.string A.(fg white ++ bg blue) msg)
  |> Ui.resize ~w:0 ~sw:1 ~h:1 ~sh:0  (* full width, fixed height *)

let layout =
  Ui.join_y
    (Ui.join_x
      (sidebar ["main.ml"; "lib.ml"; "test.ml"])
      (main_content "Welcome to Nottui"))
    (status_bar " Ready")
```

### Reactive Layout with Lwd

The same combinators work with reactive values using `Lwd.map` and `Lwd.map2`:

```ocaml
let selected = Lwd.var 0

let reactive_sidebar items =
  Lwd.map (Lwd.get selected) ~f:(fun sel ->
    items
    |> List.mapi (fun i name ->
      let attr = if i = sel then A.(fg black ++ bg white) else A.(fg green) in
      Ui.atom (I.string attr name))
    |> Ui.vcat)
```

When `selected` changes, only the sidebar subtree is recomputed -- the main content and status bar are untouched.

---

## Widget / Component System

### Widgets Are Values

In Nottui, a widget is a value of type `Ui.t`. There are no widget classes, no inheritance hierarchies, and no widget IDs. Widgets are constructed from primitives and composed with combinators -- pure functional construction.

```ocaml
type Ui.t  (* a terminal UI element *)
```

A `Ui.t` carries:

- A `layout_spec` (size requirements and stretch factors)
- A description variant (atom, composition, event handler, sensor, etc.)
- Focus status
- Cached rendering state

### Leaf Widgets

Leaf widgets are created from Notty images:

```ocaml
(* A leaf widget displaying a Notty image *)
let label text =
  Ui.atom (I.string A.empty text)

(* A styled label *)
let bold_label text =
  Ui.atom (I.string A.(st bold) text)

(* A colored block *)
let colored_block w h color =
  Ui.atom (I.char A.(bg color) ' ' w h)
```

### Container Widgets

Containers compose child widgets spatially:

```ocaml
(* Vertical list *)
let menu items =
  List.map (fun (label, _action) ->
    Ui.atom (I.string A.empty label))
    items
  |> Ui.vcat

(* Horizontal bar *)
let toolbar buttons =
  buttons
  |> List.map (fun label ->
    Ui.atom (I.string A.(fg white ++ bg blue) (Printf.sprintf " %s " label)))
  |> Ui.hcat
```

### Interactive Widgets

Interactivity is added by wrapping widgets with event handlers:

```ocaml
(* A clickable button *)
let button label on_click =
  let ui = Ui.atom (I.string A.(fg white ++ bg blue) (Printf.sprintf " %s " label)) in
  Ui.mouse_area (fun ~x:_ ~y:_ _button ->
    on_click ();
    `Handled
  ) ui

(* A keyboard-interactive widget *)
let key_handler inner on_key =
  Ui.keyboard_area (fun key ->
    match key with
    | `ASCII 'q', [] -> on_key `Quit; `Handled
    | `Enter, []     -> on_key `Enter; `Handled
    | _              -> `Unhandled
  ) inner
```

### Custom Reactive Widgets

Custom widgets combine Lwd reactivity with Ui primitives:

```ocaml
(* A reactive counter widget *)
let counter () =
  let count = Lwd.var 0 in
  Lwd.map (Lwd.get count) ~f:(fun n ->
    let label = Printf.sprintf " Count: %d " n in
    let ui = Ui.atom (I.string A.(fg yellow) label) in
    Ui.mouse_area (fun ~x:_ ~y:_ _btn ->
      Lwd.set count (Lwd.peek count + 1);
      `Handled
    ) ui)

(* A reactive toggle *)
let toggle label =
  let state = Lwd.var false in
  Lwd.map (Lwd.get state) ~f:(fun on ->
    let indicator = if on then "[x]" else "[ ]" in
    let text = Printf.sprintf "%s %s" indicator label in
    let attr = if on then A.(fg green) else A.(fg white) in
    Ui.mouse_area (fun ~x:_ ~y:_ _btn ->
      Lwd.set state (not (Lwd.peek state));
      `Handled
    ) (Ui.atom (I.string attr text)))
```

### Built-In Widgets (Nottui_widgets)

The `Nottui_widgets` module provides higher-level widgets:

| Widget              | Signature (simplified)                                     | Purpose                        |
| ------------------- | ---------------------------------------------------------- | ------------------------------ |
| `string`            | `?attr -> string -> ui`                                    | Text display                   |
| `printf`            | `?attr -> format -> ui`                                    | Formatted text                 |
| `button`            | `?attr -> string -> (unit -> unit) -> ui`                  | Clickable button               |
| `toggle`            | `?init:bool -> string Lwd.t -> (bool -> unit) -> ui Lwd.t` | Checkbox toggle                |
| `edit_field`        | `(string * int) Lwd.t -> ... -> ui Lwd.t`                  | Text input with cursor         |
| `scrollbox`         | `ui Lwd.t -> ui Lwd.t`                                     | Scrollable container with bars |
| `vlist`             | `?bullet -> ui Lwd.t list -> ui Lwd.t`                     | Vertical bullet list           |
| `grid`              | `?headers -> ui Lwd.t list list -> ui Lwd.t`               | Table/grid layout              |
| `tabs`              | `(string * (unit -> ui Lwd.t)) list -> ui Lwd.t`           | Tabbed view                    |
| `unfoldable`        | `ui Lwd.t -> (unit -> ui Lwd.t) -> ui Lwd.t`               | Collapsible tree node          |
| `file_select`       | `?filter -> on_select -> unit -> ui Lwd.t`                 | File browser                   |
| `v_pane` / `h_pane` | `ui Lwd.t -> ui Lwd.t -> ui Lwd.t`                         | Resizable split panes          |

---

## Styling

### Notty Attributes

All styling in Nottui flows through Notty's `Notty.A` (attribute) module. Attributes are attached per-cell in Notty images -- there is no separate styling layer or CSS-like system.

```ocaml
(* Foreground and background colors *)
A.fg red
A.bg blue
A.(fg green ++ bg black)

(* Text styles *)
A.st bold
A.st underline
A.st reverse
A.st blink

(* Combining attributes with ++ *)
A.(fg cyan ++ st bold ++ st underline)

(* 24-bit color *)
A.fg (A.rgb_888 ~r:255 ~g:128 ~b:0)

(* Grayscale *)
A.fg (A.gray 12)  (* 0-23 grayscale levels *)

(* Apply attributes to text *)
I.string A.(fg red ++ st bold) "Error!"
I.string A.(fg white ++ bg blue) " Status Bar "
```

### Attribute Composition

Attributes compose with `++` (the `Notty.A.(++)` operator). Later attributes override earlier ones for conflicting properties:

```ocaml
let base_attr = A.(fg white ++ bg black)
let highlight  = A.(base_attr ++ fg yellow ++ st bold)
let error_attr = A.(base_attr ++ fg red ++ st bold ++ st underline)
```

### Color Support

| Color Type   | API                                | Range             |
| ------------ | ---------------------------------- | ----------------- |
| Named colors | `A.red`, `A.blue`, `A.green`, etc. | 8 standard colors |
| Light colors | `A.lightred`, `A.lightblue`, etc.  | 8 light variants  |
| 256-color    | `A.rgb ~r ~g ~b` (0-5 each)        | 216 colors        |
| Grayscale    | `A.gray level` (0-23)              | 24 gray levels    |
| 24-bit       | `A.rgb_888 ~r ~g ~b` (0-255 each)  | 16.7M colors      |

---

## Event Handling

### Event Flow

Events flow through the widget tree from the root toward leaves. Event handlers at each level can intercept events or let them propagate.

### Event Types

```ocaml
type event = [
  | `Key of key                          (* keyboard input *)
  | `Mouse of [ `Press of button         (* mouse press *)
              | `Release                  (* mouse release *)
              | `Drag ]                   (* mouse drag *)
              * (int * int)              (* coordinates *)
              * Unescape.mods            (* modifier keys *)
  | `Paste of string                     (* bracketed paste *)
]

type key = [
  | `ASCII of char                       (* printable ASCII *)
  | `Uchar of Uchar.t                   (* Unicode character *)
  | `Enter | `Escape | `Tab | `Backspace
  | `Arrow of [ `Up | `Down | `Left | `Right ]
  | `Page of [ `Up | `Down ]
  | `Home | `End | `Insert | `Delete
  | `Function of int                     (* F1-F12 *)
] * Unescape.mods                        (* modifier keys *)
```

### Attaching Event Handlers

```ocaml
(* Mouse events: handler receives coordinates and button *)
val Ui.mouse_area :
  (x:int -> y:int -> [ `Press of button | `Release | `Drag ] ->
   [ `Handled | `Unhandled | `Grab of ... ]) ->
  t -> t

(* Keyboard events *)
val Ui.keyboard_area :
  (key -> [ `Handled | `Unhandled ]) ->
  t -> t

(* General event filter: intercepts all events for a subtree *)
val Ui.event_filter :
  ([ `Key of key | `Mouse of ... ] -> [ `Handled | `Unhandled ]) ->
  t -> t
```

### Propagation Control

Handlers return a variant controlling propagation:

- **`` `Handled ``** -- the event is consumed; it does not propagate further up the tree
- **`` `Unhandled ``** -- the event is ignored by this handler and continues propagating
- **`` `Grab ``** (mouse only) -- captures subsequent mouse events (drag, release) regardless of cursor position

### Event Handler Example

```ocaml
(* A navigable list with keyboard and mouse support *)
let navigable_list items selected =
  let handle_key = function
    | `Arrow `Up, []   ->
      Lwd.set selected (max 0 (Lwd.peek selected - 1));
      `Handled
    | `Arrow `Down, [] ->
      Lwd.set selected (min (List.length items - 1) (Lwd.peek selected + 1));
      `Handled
    | `Enter, []       ->
      (* activate selected item *)
      `Handled
    | _ -> `Unhandled
  in
  Lwd.map (Lwd.get selected) ~f:(fun sel ->
    items
    |> List.mapi (fun i item ->
      let attr = if i = sel then A.(fg black ++ bg white) else A.empty in
      Ui.mouse_area (fun ~x:_ ~y:_ _ ->
        Lwd.set selected i;
        `Handled
      ) (Ui.atom (I.string attr item)))
    |> Ui.vcat
    |> Ui.keyboard_area handle_key)
```

### Renderer and Event Dispatch

The `Renderer` module bridges the reactive UI and the terminal:

```ocaml
module Renderer : sig
  type t
  val make : unit -> t
  val update : t -> size:(int * int) -> Ui.t -> unit
  val image : t -> Notty.image
  val dispatch_mouse : t -> int -> int -> ... -> [ `Handled | `Unhandled ]
  val dispatch_key : t -> key -> [ `Handled | `Unhandled ]
  val dispatch_event : t -> event -> [ `Handled | `Unhandled ]
end
```

The renderer maintains the current UI tree, produces Notty images for display, and routes input events to the appropriate handlers in the tree.

---

## State Management

### `Lwd.var` -- The Primary State Primitive

All mutable state in a Nottui application is held in `Lwd.var` values. A `Lwd.var` is a mutable cell that participates in the incremental computation graph:

```ocaml
(* Create a reactive variable with an initial value *)
let counter = Lwd.var 0

(* Read within the reactive graph -- creates a dependency *)
let counter_doc : int Lwd.t = Lwd.get counter

(* Read immediately -- no dependency, for use in event handlers *)
let current : int = Lwd.peek counter

(* Update the variable -- invalidates all dependents *)
let () = Lwd.set counter 42
```

### Automatic Dependency Tracking

When you build a computation with `Lwd.map`, `Lwd.map2`, or `Lwd.bind`, the runtime tracks which `Lwd.var` values are read (via `Lwd.get`). This builds the dependency graph **automatically** -- there is no need to:

- Manually subscribe to state changes
- Implement an observer pattern
- Mark widgets as dirty
- Declare dependencies explicitly

The graph is built by the act of computation. If a `map` function reads variable A, then the result depends on A. Period.

```ocaml
let name = Lwd.var "World"
let greeting = Lwd.map (Lwd.get name) ~f:(fun n ->
  Printf.sprintf "Hello, %s!" n)

(* greeting automatically depends on name.
   When name changes, greeting is invalidated. *)
let () = Lwd.set name "OCaml"
(* greeting is now "damaged" -- next sample will recompute it *)
```

### Invalidation and Recomputation

The lifecycle of a reactive value follows this pattern:

1. **Construction** -- `Lwd.map`/`Lwd.map2`/`Lwd.bind` builds the DAG
2. **Sampling** -- `Lwd.sample root` evaluates the graph, caching results
3. **Mutation** -- `Lwd.set var value` marks the variable and all transitive dependents as **damaged**
4. **Re-sampling** -- the next `Lwd.sample` recomputes only damaged nodes, caching new results
5. **Quiescence** -- if no variables change, sampling returns cached values at zero cost

The framework (specifically `Ui_loop` or `Nottui_lwt`) calls `sample` on each frame. If nothing changed, the frame is essentially free.

### State Patterns

```ocaml
(* Pattern: local state encapsulated in a widget *)
let expandable_section title content =
  let open_ = Lwd.var false in
  Lwd.map (Lwd.get open_) ~f:(fun is_open ->
    let header =
      let arrow = if is_open then "v " else "> " in
      Ui.mouse_area (fun ~x:_ ~y:_ _ ->
        Lwd.set open_ (not (Lwd.peek open_));
        `Handled
      ) (Ui.atom (I.string A.(st bold) (arrow ^ title)))
    in
    if is_open then
      Ui.join_y header content
    else
      header)

(* Pattern: shared state across widgets *)
let app () =
  let selected_tab = Lwd.var 0 in
  let tab_bar = Lwd.map (Lwd.get selected_tab) ~f:(fun sel ->
    (* renders tab headers, clicking sets selected_tab *) ...)
  in
  let tab_content = Lwd.map (Lwd.get selected_tab) ~f:(fun sel ->
    (* renders content for the selected tab *) ...)
  in
  Lwd.map2 tab_bar tab_content ~f:(fun bar content ->
    Ui.join_y bar content)
```

---

## Extensibility & Ecosystem

### Ecosystem

Nottui exists within the broader Lwd ecosystem:

| Package           | Purpose                                             |
| ----------------- | --------------------------------------------------- |
| **lwd**           | Core incremental computation library                |
| **nottui**        | Terminal UI widgets and layout on Lwd               |
| **nottui-lwt**    | Async/concurrent support via Lwt                    |
| **nottui-pretty** | Interactive pretty-printer based on Pprint          |
| **tyxml-lwd**     | Web DOM rendering via Js_of_ocaml (Lwd for the web) |
| **brr-lwd**       | Browser integration layer                           |

The Lwd core is backend-agnostic. The same incremental computation model that drives Nottui's terminal UI also drives `tyxml-lwd` for web UIs. This demonstrates the generality of the reactive document approach.

### Usage in Practice

Nottui is used in some OCaml developer tools and academic projects. The ecosystem is small but the library demonstrates ideas that are relevant far beyond its direct usage. The incremental computation approach has roots in academic work on self-adjusting computation (Acar et al.) and is related to Jane Street's `Incremental` library for OCaml.

### Extension Points

- **Custom widgets**: compose `Ui.atom`, `Ui.join_x/y/z`, `Ui.mouse_area`, `Ui.keyboard_area` with `Lwd.map` for reactivity
- **Custom backends**: Lwd itself is backend-agnostic; one could build a non-Notty renderer
- **Custom reactive primitives**: `Lwd.prim` allows defining lifecycle-managed reactive leaves with acquire/release semantics

---

## Strengths

- **Automatic fine-grained reactivity** -- dependencies are tracked by the runtime, not declared by the programmer. No manual subscriptions, no observer boilerplate, no forgotten unsubscribes.
- **Efficient sparse updates** -- changing one variable recomputes only its dependents. In a large UI, this can be O(1) instead of O(n) for a full redraw or O(n) for a virtual DOM diff.
- **No virtual DOM overhead** -- there is no diffing pass. The dependency graph directly encodes what needs to update, avoiding the O(n) tree comparison that retained-mode frameworks require.
- **Mathematically principled** -- the Functor/Applicative/Monad structure of `Lwd.t` provides well-understood composition laws. The incremental computation model has formal foundations in self-adjusting computation theory.
- **Elegant functional API** -- widgets are values, composition is function application, state is explicit `Lwd.var` cells. The entire API surface is small and orthogonal.
- **Compositional state management** -- each widget can own its local `Lwd.var` state. State is encapsulated naturally by lexical scope, not by framework-imposed patterns.
- **Backend-agnostic core** -- Lwd works for terminal UIs (Nottui), web UIs (tyxml-lwd), and any other output. The incremental computation layer is fully separated from rendering.
- **Lazy evaluation of collapsed subtrees** -- `Lwd.bind` enables conditional computation: collapsed sections do not evaluate their children until expanded.

---

## Weaknesses & Limitations

- **Small OCaml ecosystem** -- OCaml's community is much smaller than Rust, Python, Go, or JavaScript. Fewer users means fewer bug reports, fewer tutorials, and fewer ready-made components.
- **Limited documentation** -- the README covers basics but the Layout DSL section is literally marked "TODO". Understanding the full API requires reading `.mli` files and source code.
- **Few built-in widgets** -- `Nottui_widgets` provides essentials (buttons, text input, scroll, tabs, grid) but lacks the breadth of Brick's widget ecosystem or Textual's 30+ built-in widgets.
- **Steep learning curve** -- the incremental computation model, monadic composition, and OCaml's type system present a significant barrier for developers not already comfortable with functional programming.
- **Small community** -- finding help, examples, or third-party extensions is harder than with mainstream TUI libraries.
- **Less battle-tested** -- compared to ncurses-based systems with decades of deployment or Brick with hundreds of downstream projects, Nottui has seen limited production use.
- **Memory management discipline** -- `Lwd.root` values must be explicitly released to avoid memory leaks. Forgetting `release` keeps the entire dependency graph alive.
- **Dynamic dependency cost** -- `Lwd.bind` / `Lwd.join` (dynamic graph rewiring) is more expensive than `Lwd.map` / `Lwd.map2` (static edges). Overuse of `bind` can degrade the incremental performance advantage.

---

## Lessons for D / Sparkles

### `Lwd.t` Reactive Values --> D `Reactive!T` Struct

The core `'a Lwd.t` pattern could be implemented in D as a `Reactive!T` struct that tracks access during rendering. When a reactive value is read during a render pass, it registers itself as a dependency of the current computation context. On mutation, dependent subtrees are marked dirty.

```d
/// A reactive value that tracks dependencies automatically.
struct Reactive(T)
{
    private T _value;
    private DependencyNode _node;

    /// Read the value, registering a dependency on the current computation.
    T get() @safe
    {
        if (auto ctx = RenderContext.current)
            ctx.registerDependency(&_node);
        return _value;
    }

    /// Read without dependency tracking (for event handlers).
    T peek() @safe pure nothrow @nogc
    {
        return _value;
    }

    /// Set the value, invalidating all dependents.
    void set(T newVal) @safe
    {
        _value = newVal;
        _node.invalidateDependents();
    }
}
```

The render context could use thread-local storage or a scope parameter to track which reactive values are read during each computation, building the dependency graph implicitly -- just as Lwd does.

### Incremental Computation --> D Template Metaprogramming + Runtime Tracking

D's template metaprogramming could create a **compile-time dependency graph** for static reactive relationships (where the structure is known at compile time), with runtime `Lwd.var`-style tracking for dynamic state:

```d
/// A computed reactive value (like Lwd.map).
/// The dependency on `source` is known at compile time.
auto computed(alias fn, Sources...)(Sources sources)
{
    // The dependency edges are encoded in the type at compile time.
    // At runtime, only invalidation propagation occurs.
    return ComputedReactive!(fn, Sources)(sources);
}

// Usage:
auto name = reactive("World");
auto greeting = computed!(n => "Hello, " ~ n ~ "!")(name);
// greeting is invalidated when name changes -- zero-cost dependency tracking
```

For the dynamic case (where the dependency graph changes at runtime, analogous to `Lwd.bind`), a runtime dependency tracker with generation counters could be used, similar to Lwd's internal invalidation mechanism.

### `Lwd.map` / `Lwd.bind` --> D Range Composition or UFCS Monadic Style

Lwd's combinators map to D idioms:

```d
// Lwd-style: Lwd.map (Lwd.get counter) ~f:(fun n -> ...)
// D-style with UFCS:
auto counterView = counter
    .asReactive
    .map!(n => text(format!"Count: %d"(n)));

// Lwd-style: Lwd.map2 a b ~f:(fun x y -> ...)
// D-style:
auto combined = map2!(
    (header, body) => vBox(header, body)
)(headerWidget, bodyWidget);
```

D's `alias` parameters and template lambdas provide the same composition power as OCaml's first-class functions, with the added benefit of compile-time specialization.

### `Lwd_table` (Reactive Collections) --> D `ReactiveList!T`

A reactive list in D could track insertions and deletions, invalidating only affected reductions:

```d
/// A reactive ordered collection with incremental reduction.
struct ReactiveList(T)
{
    void append(T item) @safe;
    void remove(size_t index) @safe;
    void set(size_t index, T item) @safe;

    /// Incrementally reduce the collection.
    /// Only recomputes the portion affected by changes.
    auto reduce(alias monoidOp, B)(B identity)
    {
        return IncrementalReduction!(typeof(this), monoidOp, B)(this, identity);
    }
}
```

This is particularly valuable for log views, list widgets, and table displays where items change one at a time but the rendered list may contain thousands of entries.

### No Virtual DOM Diffing --> Incremental `@nogc` Reactivity

The key insight from Lwd is that **dependency-tracked incremental computation avoids the O(n) diff cost** entirely. For a D TUI library targeting `@nogc` operation, this is especially relevant:

- Virtual DOM diffing allocates a new tree each frame and walks both trees -- incompatible with `@nogc`
- Immediate-mode redraws the entire screen -- wastes work for sparse updates
- Incremental computation with `Reactive!T` values can propagate changes through a pre-allocated DAG with no allocation, making it naturally `@nogc`-compatible

```d
// The dependency graph is allocated once and reused.
// Updates only touch changed nodes -- no allocation, no diffing.
@safe @nogc nothrow
void propagateChanges(DependencyGraph* graph)
{
    foreach (node; graph.damagedNodes)
    {
        node.recompute();
        node.markClean();
    }
}
```

### Automatic Dependency Tracking --> D `opDispatch` or Scope Guards

D's metaprogramming facilities could intercept property reads to build dependency graphs automatically:

```d
/// A reactive wrapper that tracks reads via opDispatch.
struct Tracked(T)
{
    private T _inner;

    auto opDispatch(string member)()
    {
        // Register that `member` was read during this render pass
        RenderContext.current.trackRead(&this, member);
        return __traits(getMember, _inner, member);
    }
}

// Alternatively, scope-based tracking:
auto renderScope = RenderContext.beginScope();
scope(exit) renderScope.commit();
// Any Reactive!T.get() calls within this scope automatically
// register dependencies on renderScope.
```

This mirrors Lwd's approach where `Lwd.get` implicitly registers dependencies during evaluation, but uses D's compile-time introspection capabilities instead of OCaml's runtime tracking.

---

## References

- **Lwd repository (includes Nottui)**: <https://github.com/let-def/lwd>
- **Nottui source**: <https://github.com/let-def/lwd/tree/master/lib/nottui>
- **Nottui README with examples**: <https://github.com/let-def/lwd/blob/master/lib/nottui/README.md>
- **Lwd README (incremental computation model)**: <https://github.com/let-def/lwd/blob/master/README.md>
- **Lwd API (`.mli`)**: <https://github.com/let-def/lwd/blob/master/lib/lwd/lwd.mli>
- **Nottui API (`.mli`)**: <https://github.com/let-def/lwd/blob/master/lib/nottui/nottui.mli>
- **Nottui widgets API (`.mli`)**: <https://github.com/let-def/lwd/blob/master/lib/nottui/nottui_widgets.mli>
- **Lwd_table API (`.mli`)**: <https://github.com/let-def/lwd/blob/master/lib/lwd/lwd_table.mli>
- **Notty (terminal backend)**: <https://github.com/pqwy/notty>
- **opam package**: <https://opam.ocaml.org/packages/nottui/>
- **Frederic Bour (author)**: <https://github.com/let-def>
- **Merlin (OCaml IDE service, also by Bour)**: <https://github.com/ocaml/merlin>
