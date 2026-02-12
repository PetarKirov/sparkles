# TUI Library Comparison & Design Recommendations

A cross-library synthesis of thirteen TUI frameworks -- Ratatui (Rust), Ink (JavaScript), Textual (Python), Bubble Tea (Go), Brick (Haskell), Notcurses (C), FTXUI (C++), Cursive (Rust), Mosaic (Kotlin), Nottui (OCaml), libvaxis (Zig), tview (Go), and ImTui (C++) -- with concrete design recommendations for Sparkles.

---

## 1. Rendering Models Compared

The thirteen libraries span five rendering paradigms: immediate mode, retained mode, functional DOM composition, incremental/reactive computation, and pure immediate-mode (ImGui). Each makes fundamentally different tradeoffs around state ownership, allocation patterns, and update granularity.

### Immediate Mode

**Ratatui**, **Bubble Tea**, and **libvaxis** use immediate-mode rendering. Every frame, the application rebuilds the entire UI description from scratch. There is no persistent widget tree or scene graph.

**How the render cycle works:**

- **Ratatui**: The application calls `terminal.draw(|frame| { ... })`. Inside the closure, widgets are constructed inline from application state and rendered into a `Buffer` (a flat `Vec<Cell>` grid). After the closure returns, the `Terminal` diffs the current buffer against the previous one and emits only changed cells to the backend. Widgets are consumed by value on render -- they do not persist between frames.

- **Bubble Tea**: The `View()` method returns a plain `string` representing the entire UI. The framework diffs the new string against the previous one at the line level and overwrites only changed lines. There is no structured buffer -- just string comparison.

- **libvaxis**: The application gets a `Window` (a view into the `Screen` back buffer), clears it, draws widgets into it via `writeCell()` and `print()`, then calls `render()`. Vaxis diffs the current `Screen` against `screen_last` (the front buffer) and emits only changed cells. The immediate-mode pattern is the same as Ratatui, but with Zig's explicit allocator passing at every allocation site.

**Pros:**

- Simple mental model: UI is always a function of current state
- No stale widget state to manage
- Zero persistent allocations for the widget tree
- Naturally compatible with `pure` functions and `@nogc` rendering

**Cons:**

- Rebuilds the full UI every frame, even unchanged regions
- No mechanism to skip unchanged subtrees without manual optimization
- Bubble Tea's string-based approach loses spatial structure, making hit-testing and partial updates expensive

**D suitability:** Excellent. Widgets as stack-allocated `struct` values, consumed within a single `draw` call, align perfectly with `@nogc` and output range patterns. Ratatui's `Buffer`-based approach maps directly to `SmallBuffer!(Cell, N)`. libvaxis's explicit allocator passing maps to D's `@nogc` attribute, which provides the same guarantee (no hidden allocation) enforced at compile time rather than by convention.

### Retained Mode

**Textual**, **Ink**, **Cursive**, and **tview** maintain persistent widget trees that survive across frames.

**How the render cycle works:**

- **Textual**: Maintains a DOM-like tree of `Widget` objects. When a `reactive` attribute changes, the widget is marked dirty. On the next frame, only dirty widgets are re-rendered. The compositor assembles output from Rich `Segment` objects, performing cuts, chops, occlusion, and composition to produce minimal terminal writes.

- **Ink**: Uses React's `react-reconciler` to manage a virtual component tree. State changes trigger reconciliation (virtual tree diffing), then Yoga computes Flexbox layout, and the result is rendered to an ANSI string buffer. The framework patches the terminal by overwriting its output region.

- **Cursive**: Maintains a persistent tree of `View` trait objects (`Box<dyn View>`). The framework owns the event loop, calls `required_size` / `layout` / `draw` on the tree, and routes events through the focused path. Views hold their own mutable state (scroll position, text content, selection index) and persist between frames. Named views can be accessed from callbacks via `call_on_name`.

- **tview**: Maintains a tree of `Primitive` interface objects. `Application.Run()` owns the event loop, dispatching terminal events to the focused widget. On each event, the framework calls `Draw` on the entire tree -- tcell's internal diff layer optimizes actual terminal writes. Widgets own their state via getters/setters.

**Pros:**

- Partial updates: only dirty widgets are re-rendered (Textual, Ink)
- Rich lifecycle hooks (mount, unmount, focus, effects)
- CSS selectors and DOM queries for widget management (Textual)
- Event bubbling through the tree
- Built-in focus management (Cursive, tview) -- the framework tracks focus, routes input, and supports Tab/Shift-Tab navigation

**Cons:**

- Persistent heap allocations for the widget tree
- Complex invalidation and dirty-tracking logic
- GC pressure from retained objects (Python, JavaScript)
- Virtual dispatch overhead for trait objects / interfaces (Cursive's `Box<dyn View>`, tview's `Primitive` interface)
- Callback spaghetti in complex apps (Cursive, tview)
- More complex state synchronization between app state and widget state

**D suitability:** Mixed. A full retained DOM with GC-managed objects would fight D's `@nogc` philosophy. However, Textual's dirty-tracking compositor pattern is valuable -- it could be implemented with a flat cell-buffer approach rather than a GC object tree. Cursive's `View` trait maps to D interfaces (for heterogeneous trees) or template constraints (for static trees). tview's `Primitive` interface maps directly to D's Design by Introspection, with the advantage that D can check the contract at compile time rather than via Go's runtime duck typing.

### Functional DOM Composition (FTXUI)

**FTXUI** occupies a distinctive position: a two-tier architecture where the rendering layer is pure functional (immediate-mode elements) and the interaction layer is retained-mode (stateful components).

**How the render cycle works:**

The dom layer constructs an `Element` tree from functions (`text`, `hbox`, `vbox`, `border`, `gauge`). Elements are `shared_ptr<Node>` values -- new every frame, no mutation. The tree goes through a two-pass layout (bottom-up `ComputeRequirement`, top-down `SetBox`), then renders to a `Screen` pixel grid. The component layer wraps this: a `Component` produces an `Element` tree via `Render()`, handles events via `OnEvent()`, and participates in a focus tree. `ScreenInteractive` drives the loop, calling `Render()` each frame, diffing, and flushing.

The pipe operator (`|`) enables decorator chaining: `text("hello") | bold | color(Color::Red) | border`. This is syntactic sugar for nested function application.

**Pros:**

- Clean separation: dom layer is pure functional, component layer adds only necessary statefulness
- Pipe operator for left-to-right readability
- Flexbox-inspired layout with full CSS flexbox semantics
- Zero external dependencies

**Cons:**

- `shared_ptr` per node means heap allocation for every element every frame
- No built-in async/concurrency model
- No theming system

**D suitability:** Excellent conceptual fit. FTXUI's pipe operator maps directly to D's UFCS -- `text("hello").bold.color(Color.red).border` -- as a built-in language feature with zero operator overloading. Elements can be `@nogc` struct values in `SmallBuffer`-backed trees instead of `shared_ptr` nodes. The dual dom/component architecture maps to `@nogc` pure element types + DbI-detected component capabilities.

### Compose / Reactive Recomposition (Mosaic)

**Mosaic** uses the Jetpack Compose compiler plugin and runtime, retargeted from Android views to terminal ANSI output.

**How the render cycle works:**

The Compose compiler plugin transforms `@Composable` functions at compile time, inserting change-detection guards and slot-table management code. During composition, the runtime records which `@Composable` functions read which snapshot state objects. When a `mutableStateOf` value changes, only the functions that read it are re-executed -- no virtual DOM diff, no full tree rebuild. A `MosaicNodeApplier` maps the abstract composition to a terminal node tree, which is measured, placed, and drawn to a `TextSurface` grid of styled pixels, then serialized as ANSI.

**Pros:**

- Compiler-powered recomposition: change detection inserted at compile time, not diffed at runtime
- Automatic fine-grained dependency tracking via snapshot system
- Familiar Compose/React mental model
- Deep coroutine integration (`LaunchedEffect`, `snapshotFlow`)

**Cons:**

- Requires Kotlin and the Compose compiler plugin -- not portable to other languages
- JVM startup overhead on JVM target
- Limited built-in widgets (Text, Row, Column, Box, Spacer, Filler)
- No focus management, no mouse support, no input field abstraction

**D suitability:** The compiler-plugin mechanism is not replicable in D, but the _patterns_ are highly relevant. D's CTFE + mixin templates can generate change-detection boilerplate for struct fields. D's `Reactive!T` wrapper structs with `opDispatch` can approximate snapshot state. Modifier chains (`Modifier.width(10).padding(2).background(Color.Red)`) map directly to UFCS. The key lesson is that compile-time code generation for reactive state tracking is a powerful pattern that D can approximate through its own metaprogramming.

### Incremental Computation / FRP (Nottui)

**Nottui** uses incremental computation primitives where the UI is a reactive document with automatic dependency tracking.

**How the render cycle works:**

The core type is `'a Lwd.t` -- a reactive value that tracks dependencies in a DAG. Source nodes are `Lwd.var` (mutable reactive cells). Computed values use `Lwd.map`, `Lwd.map2`, `Lwd.bind` to compose reactive computations. The UI is a `Ui.t Lwd.t` -- a reactive value producing UI trees. On each frame, `Lwd.sample root` evaluates only damaged nodes (those whose transitive inputs changed). If nothing changed, sampling returns cached values at zero cost. There is no virtual DOM diff and no full redraw.

**Pros:**

- Automatic fine-grained reactivity -- dependencies tracked by the runtime, not declared by the programmer
- Efficient sparse updates: O(k) where k = changed dependencies, not O(n) for the full tree
- No virtual DOM overhead -- the dependency graph directly encodes what needs to update
- Mathematically principled (Functor/Applicative/Monad)
- Backend-agnostic core (Lwd works for terminal, web, and any other output)

**Cons:**

- Steep learning curve (monadic composition, OCaml type system)
- Small ecosystem and community
- `Lwd.bind` (dynamic graph rewiring) is more expensive than static edges
- `Lwd.root` values must be explicitly released to avoid memory leaks

**D suitability:** The incremental computation model is the most sophisticated update strategy among the thirteen libraries. For D, the key insight is that dependency-tracked incremental computation avoids both the O(n) full-redraw cost and the O(n) virtual-DOM-diff cost. A `Reactive!T` struct with automatic dependency registration during render passes can be implemented `@nogc` with a pre-allocated DAG -- no allocation, no diffing. This is the most promising path for high-performance partial updates in a `@nogc` context.

### Pure Immediate-Mode / ImGui (ImTui)

**ImTui** brings Dear ImGui's pure immediate-mode paradigm to the terminal. There are no widget objects, no retained tree, no callbacks. The UI is a sequence of function calls each frame.

**How the render cycle works:**

Each frame, the application calls ImGui functions (`Button`, `Text`, `SliderFloat`). ImGui accumulates draw geometry into draw lists. ImTui's text backend rasterizes triangles into a `TScreen` of packed 32-bit `TCell` values (character + foreground + background). The ncurses backend diffs current vs previous frame and writes only changed cells.

Widget identity uses an ID stack (hashed string labels + window ID). The hot/active model tracks mouse hover and interaction state with zero widget objects -- just two IDs per frame.

**Pros:**

- Zero widget boilerplate -- a widget is a function call
- UI code is maximally concise
- Full Dear ImGui ecosystem (1000+ extensions)
- No callback hell -- event handling is inline with rendering
- State management is trivial -- application owns all state as plain variables
- Entire render path can be `@nogc`

**Cons:**

- Pixel-to-character mapping loses precision
- Limited to 256 ANSI colors
- Cursor-based layout has no constraint solver or flexbox
- No styled text (inline bold/color within a string)
- No proper Unicode box-drawing characters

**D suitability:** The widget-as-function pattern is maximally `@nogc`-friendly. D could offer an ImGui-like API layer for rapid prototyping with compile-time widget IDs via `__FILE__` and `__LINE__` template parameters (zero-cost, unlike ImGui's runtime string hashing). Push/pop style stacks map to D's `scope(exit)` guards, preventing the "forgot to pop" bugs common in C++ ImGui code. This would complement a more structured widget system as a rapid-development fast path.

### Hybrid: Compositor with Planes (Notcurses)

**Notcurses** uses a retained compositor model with manually managed planes.

**How the render cycle works:**

The application draws to `ncplane` surfaces (retained cell grids). On render, `ncpile_render()` composites all planes in z-order with alpha blending, producing a flattened cell grid. `ncpile_rasterize()` diffs against the previous frame and emits minimal escape sequences. The plane contents are retained and only need updating when they actually change, but the composition step runs across all visible planes every frame.

**Pros:**

- True alpha compositing between overlapping layers
- Retained plane contents avoid unnecessary redraws of static elements
- Cell-packed representation with inline glyph clusters avoids heap allocation
- Thread-safe concurrent plane manipulation

**Cons:**

- Manual positioning and sizing of all planes
- No automatic layout engine
- Manual memory management for planes and cells

**D suitability:** The plane compositor model maps well to D. Planes as `@nogc` structs with RAII cleanup via `~this()`, channel-based coloring via bitwise operations, and compositor output to `SmallBuffer` -- all align naturally.

### Declarative Rebuild (Brick)

**Brick** is a pure functional approach: `appDraw` is a pure function producing `[Widget n]` layers. The rendering engine evaluates each widget's rendering function, threading layout constraints through the tree. Widgets produce Vty `Image` values that are composited into the final frame. Unlike Textual and Ink, Brick re-evaluates the entire `appDraw` function on each event, making it a "declarative rebuild" rather than a persistent retained tree.

**D suitability:** Strong. D's UFCS chains provide the same compositional expressiveness as Haskell's combinators, with left-to-right readability. D's `pure` attribute enforces the same side-effect-free guarantee.

### Comparison Table

| Aspect                | Ratatui                  | Bubble Tea           | Textual             | Ink                  | Brick                 | Notcurses             | FTXUI                                                | Cursive                                 | Mosaic                                   | Nottui                              | libvaxis                    | tview                    | ImTui                      |
| --------------------- | ------------------------ | -------------------- | ------------------- | -------------------- | --------------------- | --------------------- | ---------------------------------------------------- | --------------------------------------- | ---------------------------------------- | ----------------------------------- | --------------------------- | ------------------------ | -------------------------- |
| **Model**             | Immediate                | Immediate            | Retained (DOM)      | Retained (React)     | Declarative rebuild   | Retained (planes)     | Hybrid (functional DOM + retained components)        | Retained (view tree + callbacks)        | Reactive recomposition (compiler plugin) | Incremental computation (FRP/DAG)   | Immediate (double-buffered) | Retained (widget tree)   | Pure immediate (ImGui)     |
| **Render target**     | Cell buffer              | String               | Rich Segments       | ANSI string          | Vty Image             | Cell grid             | Screen pixel grid                                    | Printer abstraction                     | TextSurface (TextPixel grid)             | Notty Image                         | Screen cell buffer          | tcell Screen             | TScreen (packed TCell)     |
| **Diffing**           | Cell-level               | Line-level           | Region-level        | String patch         | Full recomposite      | Cell-level            | Cell-level (ScreenInteractive)                       | Full redraw                             | Differential ANSI encoding               | Incremental (only damaged nodes)    | Cell-level                  | Cell-level (via tcell)   | Cell-level                 |
| **Partial update**    | No (full rebuild)        | No (full rebuild)    | Yes (dirty widgets) | Yes (reconciler)     | No (full rebuild)     | Yes (retained planes) | No (full element tree rebuild)                       | No (full redraw, `needs_relayout` hint) | Yes (snapshot-tracked recomposition)     | Yes (dependency-graph invalidation) | No (full rebuild)           | No (full tree Draw)      | No (full rebuild)          |
| **Persistent state**  | None (widgets ephemeral) | None (string output) | Widget tree + CSS   | React component tree | None (pure rebuild)   | Plane cell grids      | Component tree (retained) + Element tree (ephemeral) | View tree (persistent)                  | Slot table (composition state)           | Lwd DAG (reactive variables)        | None (app-owned)            | Widget tree (persistent) | None (app-owned variables) |
| **GC pressure**       | Zero                     | String alloc/frame   | High (Python)       | High (JS)            | Moderate (Haskell GC) | Zero (manual)         | Moderate (shared_ptr/frame)                          | Low (Rust ownership)                    | Moderate (JVM/native)                    | Low (OCaml GC, incremental)         | Zero (explicit allocator)   | Moderate (Go GC)         | Zero (C++ manual)          |
| **@nogc feasibility** | High                     | Moderate             | Low                 | Low                  | N/A                   | High                  | Moderate (shared_ptr)                                | N/A (Rust)                              | Low (Kotlin/JVM)                         | Moderate (OCaml)                    | High                        | Moderate (Go GC)         | High                       |

---

## 2. Architecture Patterns Compared

### Elm / MVU (Bubble Tea, partially Brick)

Both Bubble Tea and Brick structure applications around a variant of The Elm Architecture:

- **Bubble Tea**: Strict MVU via the `Model` interface with `Init() Cmd`, `Update(Msg) (Model, Cmd)`, and `View() string`. Side effects are modeled as `Cmd` values. The framework owns the event loop.
- **Brick**: The `App s e n` record with `appDraw`, `appHandleEvent`, `appChooseCursor`, `appStartEvent`, and `appAttrMap`. While `appDraw` is pure, `appHandleEvent` uses the `EventM` monad for stateful updates with lens operations, making it less purely functional than Bubble Tea.

**D alignment:** Strong. D's `pure` attribute enforces the no-side-effects contract at compile time. A `pure` `view` function taking `in Model` (which is `scope const` under `-preview=in`) provides a stronger guarantee than Go's convention-based immutability. D's `SumType` enables exhaustive, compiler-checked message dispatch -- a significant improvement over Go's `interface{}` type switches.

### React / Component (Ink)

Ink uses React's component model: function components with hooks (`useState`, `useEffect`, `useInput`), a virtual tree managed by `react-reconciler`, and Yoga for Flexbox layout.

**D alignment:** Weak. React's component model is deeply tied to runtime reconciliation, closure-based hooks, and garbage collection. Translating hooks to D would lose the core benefits. However, the _concept_ of composable components with local state can be expressed through struct-based widgets with template parameters.

### Pure Functional (Brick)

Brick's pure functional core -- `appDraw :: s -> [Widget n]` -- is the cleanest expression of "UI as a function of state" in any of the thirteen libraries. Layout is entirely combinator-based (`hBox`, `vBox`, `padLeft`, `hLimit`), with no mutation.

**D alignment:** Strong. D's UFCS chains provide the same compositional expressiveness as Haskell's combinators, with left-to-right readability. D's `pure` attribute enforces the same side-effect-free guarantee. The combinator approach maps directly to template functions returning widget structs by value.

### CSS + Widget Tree (Textual)

Textual mirrors web development: a DOM-like widget tree, TCSS stylesheets with selectors and pseudo-classes, message bubbling, reactive data binding, and async event handling.

**D alignment:** Mixed. The CSS-like styling and selector system are powerful but deeply tied to runtime parsing and dynamic dispatch. D could implement a compile-time CSS DSL via CTFE, validating styles at compile time and producing zero-allocation style lookups. However, the full DOM + message-bubbling architecture adds complexity that may not be justified for a systems-oriented D library.

### Functional DOM Composition (FTXUI)

FTXUI's two-tier architecture separates pure functional rendering from stateful interaction. The dom layer builds Element trees from function calls. The component layer wraps Elements with event handling and mutable state. The pipe operator (`|`) enables decorator chaining.

**D alignment:** Excellent. FTXUI's architecture maps remarkably well to D. The pipe operator IS D's UFCS -- `text("hello").bold.color(Color.blue).border` -- with zero operator overloading needed. The dual dom/component layers map to `@nogc` pure element types + DbI-detected component capabilities. FTXUI's `FlexboxConfig` struct maps to named-argument D structs with CTFE validation. The key improvement D offers: elements as `@nogc` value-type structs in `SmallBuffer` instead of `shared_ptr` heap nodes.

### Callback-Based Retained Mode (Cursive, tview)

Cursive and tview represent traditional desktop GUI toolkit architecture translated to the terminal: a retained widget tree with callback-driven event handling.

- **Cursive**: Views form a persistent tree. The `View` trait provides `draw`, `required_size`, `layout`, and `on_event`. Named views are accessed by string via `call_on_name`. Callbacks receive `&mut Cursive` for tree manipulation. User data (`Box<dyn Any>`) stores application state.
- **tview**: Primitives form a persistent tree. `Application.Run()` owns the event loop. `Flex` and `Grid` containers handle layout. Widgets own their state via getters/setters. `QueueUpdateDraw` serializes goroutine-to-UI communication.

**D alignment:** The callback pattern maps to D delegates. However, callback spaghetti is a known weakness of both libraries. D could improve on this by offering an MVU alternative alongside callbacks. Cursive's named view access could be enhanced with compile-time indexed view trees using string template parameters. tview's `Primitive` interface maps to D's `isWidget` template constraint with static dispatch.

### Compose / Reactive Recomposition (Mosaic)

Mosaic uses Kotlin's Compose compiler plugin to transform `@Composable` functions into incremental tree-building code. The runtime's snapshot system tracks state reads and triggers minimal recomposition.

**D alignment:** The compiler-plugin mechanism is language-specific, but the patterns translate. D's CTFE + mixin templates can generate change-detection logic for struct fields. A `mixin Reactive!(MyState)` could introspect fields and generate dirty-tracking code. Modifier chains map to UFCS. The constraint-based layout (`Row`, `Column`, `Box` with `MeasurePolicy`) maps to D template constraints and DbI.

### Incremental Computation / FRP (Nottui/Lwd)

Nottui's Lwd layer provides a general-purpose incremental computation engine. `Lwd.var` (mutable reactive cells) are source nodes. `Lwd.map`/`Lwd.map2`/`Lwd.bind` compose reactive computations into a DAG. Dependencies are tracked automatically -- no manual subscriptions, no observer pattern, no dirty flags.

**D alignment:** Strong conceptual fit. D's template metaprogramming could create compile-time dependency graphs for static reactive relationships, with runtime `Reactive!T`-style tracking for dynamic state. The `get`/`peek` distinction (tracked read vs untracked read) is directly implementable. `Lwd_table` (reactive collections with incremental reduction) maps to a `ReactiveList!T` with incremental `reduce` operations -- valuable for log views and list widgets.

### Pure Immediate-Mode / ImGui (ImTui)

ImTui inherits Dear ImGui's paradigm: no widget objects, no retained tree, no callbacks. A widget is a function call that lays out, renders, and checks interaction in a single expression. The hot/active model tracks exactly two IDs for mouse interaction.

**D alignment:** Excellent for `@nogc`. The entire pattern -- widget functions writing to a buffer, returning interaction state, with compile-time IDs via `__FILE__`/`__LINE__` -- is directly implementable in D with zero allocation. This makes an ideal rapid-prototyping layer.

### comptime-Powered (libvaxis)

libvaxis uses Zig's `comptime` pervasively: generic event types where `@hasField` determines at compile time which event categories to generate; duck-typed widgets where any type with the right methods works; compile-time table column generation via `@typeInfo` and `inline for`.

**D alignment:** Direct. Zig's `comptime` and D's CTFE serve the same purpose. `@hasField` maps to `__traits(hasMember, ...)`. Zig's manual vtable construction (`*anyopaque` + function pointers) is what D's template constraints eliminate -- D achieves the same type erasure more ergonomically. libvaxis's explicit allocator passing maps to D's `@nogc` attribute enforcement. D can go further with string mixins and CTFE evaluation of arbitrary expressions.

### App-Loop + Widgets (Ratatui)

Ratatui is deliberately minimal: it provides widgets, layout, and buffered rendering but does not own the event loop or impose a state pattern.

**D alignment:** Excellent. This "library, not framework" philosophy matches D's systems-programming ethos. The application controls the loop, widgets are value types rendered into a buffer, and the library handles only rendering concerns.

### Imperative (Notcurses)

Notcurses has no imposed architecture. The application creates planes, draws on them, handles input, and calls render. All state management is manual.

**D alignment:** Natural. This is how most D terminal code would work without a framework. However, it provides no abstractions -- the burden is entirely on the application.

### Recommendation for Sparkles

**Primary: Ratatui's library-centric model with Brick-inspired pure combinators, FTXUI-inspired functional DOM composition via UFCS, Bubble Tea's MVU as an optional overlay, and Nottui-inspired incremental reactivity as a future optimization.**

The core should be a rendering library (like Ratatui): `Buffer` + `Cell` + `Backend` + `Layout` + `Widget` trait. Applications control their own event loop. FTXUI's element-as-value pattern translates directly via UFCS decorator chains. For applications wanting more structure, an optional MVU module provides Bubble Tea-style `Model`/`update`/`view` scaffolding built on top of the core primitives.

The combinator-based layout from Brick (via UFCS) should be the primary layout mechanism, with constraint-based layout available for advanced use cases. ImTui-style immediate-mode widget functions should be available as a rapid-prototyping fast path.

For the future, Nottui's incremental computation model offers the most principled path to partial updates without virtual DOM diffing -- a `Reactive!T` system with dependency-tracked DAG propagation, implementable `@nogc` with pre-allocated graph nodes.

---

## 3. Layout Systems Compared

| Aspect                 | Ratatui                          | Ink                      | Textual                       | Bubble Tea                     | Brick                  | Notcurses          | FTXUI                                                      | Cursive                                   | Mosaic                                          | Nottui                              | libvaxis                                 | tview                                       | ImTui                           |
| ---------------------- | -------------------------------- | ------------------------ | ----------------------------- | ------------------------------ | ---------------------- | ------------------ | ---------------------------------------------------------- | ----------------------------------------- | ----------------------------------------------- | ----------------------------------- | ---------------------------------------- | ------------------------------------------- | ------------------------------- |
| **Approach**           | Constraint solver (Cassowary)    | Flexbox (Yoga)           | CSS subset                    | String composition (Lip Gloss) | Combinators            | Manual positioning | Flexbox-inspired                                           | Constraint-based (required_size / layout) | Compose layout (Row/Column/Box + Constraints)   | Combinator-based reactive           | Manual windows + vxfw FlexRow/FlexColumn | Flex + Grid containers                      | Cursor-based procedural (ImGui) |
| **Direction**          | Vertical/Horizontal              | Row/Column + nested flex | Horizontal/Vertical/Grid/Dock | Manual join                    | Horizontal/Vertical    | Absolute (y, x)    | hbox/vbox/flexbox                                          | LinearLayout (H/V)                        | Row/Column/Box                                  | join_x/join_y/join_z                | Manual child windows                     | FlexRow/FlexColumn                          | SameLine / default vertical     |
| **Sizing**             | Length, %, Ratio, Min, Max, Fill | flexGrow/Shrink/Basis    | auto, fixed, %, fr            | Explicit Width/Height          | Fixed/Greedy two-pass  | Explicit rows/cols | flex/flex_grow/flex_shrink, size constraints               | required_size + weight                    | fillMaxWidth, width, requiredWidth, Constraints | layout_spec (w/h + stretch factors) | limit/unbounded                          | fixedSize + proportion                      | SetNextItemWidth, child regions |
| **Flexbox**            | No                               | Full (Yoga)              | No                            | No                             | No                     | No                 | Full (FlexboxConfig: direction, wrap, justify, align, gap) | No                                        | Row/Column with Arrangement                     | No                                  | Basic (FlexRow/FlexColumn)               | Flex (proportion-based)                     | No                              |
| **Grid**               | No                               | No                       | Yes (CSS Grid subset)         | No                             | No                     | No                 | gridbox (2D)                                               | No                                        | No                                              | No                                  | No                                       | Grid (responsive breakpoints)               | BeginTable (columnar)           |
| **Nesting**            | Layout::split -> sub-layouts     | Arbitrary JSX nesting    | Widget tree with CSS          | Manual string joins            | Combinator composition | Plane hierarchy    | Arbitrary function nesting                                 | View tree nesting                         | Arbitrary @Composable nesting                   | Combinator composition              | Window.child() nesting                   | Flex/Grid nesting                           | BeginChild/EndChild nesting     |
| **Constraint solving** | Yes (Cassowary)                  | Yes (Yoga)               | Yes (CSS-like)                | No                             | No (greedy/fixed)      | No                 | Yes (two-pass: ComputeRequirement + SetBox)                | Yes (required_size + layout two-pass)     | Yes (Compose Constraints + MeasurePolicy)       | No (stretch factors)                | No (manual)                              | No (proportional division)                  | No                              |
| **Responsive**         | Re-split on resize               | Flexbox adapts           | CSS adapts                    | Manual                         | Greedy adapts          | Resize callbacks   | Flexbox adapts                                             | needs_relayout                            | Compose Constraints adapt                       | Stretch factors adapt               | Manual resize handling                   | Grid minGridWidth/minGridHeight breakpoints | Manual size calculation         |

### Newly Notable Layout Patterns

**FTXUI's Flexbox** is the most complete flexbox implementation among the thirteen libraries. Its `FlexboxConfig` brings CSS Flexbox semantics (direction, wrap, justify-content, align-items, align-content, gap) directly to the terminal. This is rare -- most TUI libraries offer only linear (hbox/vbox) layout. For D, `FlexboxConfig` maps to a named-argument struct with CTFE validation, and the layout solver operates as `@nogc pure nothrow` functions on stack-allocated node arrays.

**tview's Grid with Responsive Breakpoints** provides CSS media query-like behavior via `minGridWidth` / `minGridHeight` parameters on grid items. Items are only shown when the terminal meets minimum size thresholds. This enables different layouts at different terminal sizes without imperative resize handling -- the declarative specification handles everything. D's CTFE could validate grid definitions at compile time while breakpoint evaluation happens at runtime.

**Mosaic's Compose Layout** brings Android's constraint-based layout model to terminals. `Row`, `Column`, and `Box` composables with `Arrangement` (Start, End, Center, SpaceBetween, SpaceEvenly, SpaceAround, spacedBy) and `Alignment` provide sophisticated distribution. Custom layout via `MeasurePolicy` enables arbitrary measurement and placement. For D, the `MeasurePolicy` interface maps to template constraints and DbI.

**Cursive's Two-Pass Protocol** (`required_size` + `layout`) is the classic desktop GUI approach. Each view reports its ideal size given constraints, then the framework assigns final sizes top-down. Weight-based flex distribution allows proportional sizing. This is simpler than flexbox but sufficient for dialog-heavy applications.

**Nottui's Combinator-Based Reactive Layout** integrates layout with reactivity. Each `Ui.t` carries a `layout_spec` with stretch factors (`sw`, `sh`) controlling how extra space is distributed. The same combinators work with both plain `Ui.t` values and reactive `Ui.t Lwd.t` values. When a reactive variable changes, only the affected subtree's layout is recomputed.

**libvaxis's Manual Layout** is the simplest: create child windows with explicit offsets and dimensions. The vxfw framework adds basic flex via `FlexRow`/`FlexColumn` with a two-pass algorithm (measure fixed children, distribute remainder proportionally). For D, this level of manual layout is the baseline -- always available, with higher-level abstractions layered on top.

**ImTui's Cursor-Based Layout** is the most limited. ImGui's procedural cursor model (`Text` advances cursor down, `SameLine()` moves it right) has no constraint solver. Complex layouts require manual size calculations. However, `BeginChild`/`EndChild` provides scrollable sub-regions, and `BeginTable` provides columnar layout.

### D Opportunities

**Compile-time layout validation:** D's CTFE can validate layout constraints at compile time. Ratatui's `areas::<N>()` pattern catches count mismatches; D can go further by statically verifying that percentages sum to at most 100%, that exactly one Fill exists where required, and that min/max constraints are consistent:

```d
// Compile-time validated layout
enum layout = Layout.vertical([
    Constraint.length(3),      // header
    Constraint.fill(1),        // body
    Constraint.length(1),      // footer
]);
static assert(layout.constraints.length == 3);

// Split returns fixed-size array -- count mismatch is a compile error
auto areas = layout.split(frame.area);  // typeof(areas) == Rect[3]
```

**@nogc constraint solving:** A Cassowary solver operating on `SmallBuffer`-backed vectors could solve layout constraints without GC allocation, making the entire render path `@nogc`.

**UFCS combinator chains:** Brick's combinator style maps directly to D UFCS, providing a fluent layout API with zero runtime overhead:

```d
auto sidebar = fileList
    .vBox
    .padAll(1)
    .borderWithLabel(" Files ")
    .hLimit(25);

auto mainArea = hBox(sidebar, vBorder(), editor);
```

**FTXUI-style flexbox via UFCS:** FTXUI's flexbox layout maps to D named-argument structs:

```d
auto config = FlexboxConfig(
    direction: Direction.row,
    wrap: Wrap.wrap,
    justifyContent: JustifyContent.spaceBetween,
    alignItems: AlignItems.center,
    gap: Gap(x: 1, y: 0),
);

auto layout = flexbox(children, config);
```

**Hybrid approach:** Use combinators (Brick-style) for most layouts, with an optional constraint solver (Ratatui-style) for complex responsive layouts, and FTXUI-style flexbox for CSS-familiar developers.

---

## 4. Widget Extensibility Compared

### Widget Contracts

| Library        | Contract                                                                                                              | Mechanism                                                           | Statefulness                                                             |
| -------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **Ratatui**    | `Widget` trait: `fn render(self, area: Rect, buf: &mut Buffer)`                                                       | Rust trait (static dispatch)                                        | `StatefulWidget` trait with associated `State` type                      |
| **Ink**        | React function component returning JSX                                                                                | Runtime reconciler                                                  | `useState`/`useReducer` hooks                                            |
| **Textual**    | `Widget` class with `compose()` and/or `render()`                                                                     | Python class inheritance                                            | `reactive` descriptor attributes                                         |
| **Bubble Tea** | `Model` interface: `Init() Cmd`, `Update(Msg) (Model, Cmd)`, `View() string`                                          | Go interface (dynamic dispatch)                                     | State embedded in Model struct                                           |
| **Brick**      | `Widget n` type: `hSize`, `vSize`, `render :: RenderM n (Result n)`                                                   | Haskell data type + monadic render                                  | Via `EventM n s` monad and lenses                                        |
| **Notcurses**  | No formal contract; draw on `ncplane`                                                                                 | C function calls on plane handles                                   | Plane retains cell state; `userptr` for app state                        |
| **FTXUI**      | `Element` (shared_ptr\<Node\>) for dom; `ComponentBase` subclass for interaction                                      | Dual: pure function calls (dom) + virtual methods (components)      | Dom layer: stateless. Component layer: member variables + lambda capture |
| **Cursive**    | `View` trait: `draw`, `required_size`, `layout`, `on_event`, `take_focus`                                             | Rust trait object (`Box<dyn View>`)                                 | View-internal state (each view owns its data)                            |
| **Mosaic**     | `@Composable` function                                                                                                | Compiler plugin transforms functions into incremental tree-builders | `remember { mutableStateOf(...) }` snapshot state                        |
| **Nottui**     | `Ui.t` value (atom, composition, event handler) wrapped in `Lwd.t` for reactivity                                     | Combinator composition of values                                    | `Lwd.var` reactive cells                                                 |
| **libvaxis**   | Low-level: duck-typed `draw(Window)` convention. vxfw: `Widget` struct with `drawFn`/`eventHandler` function pointers | comptime duck typing (low-level) / manual vtable (vxfw)             | Application-owned structs                                                |
| **tview**      | `Primitive` interface: `Draw`, `SetRect`, `GetRect`, `InputHandler`, `Focus`, `HasFocus`, `Blur`, `MouseHandler`      | Go interface (dynamic dispatch)                                     | Widgets own state via getters/setters                                    |
| **ImTui**      | No widget contract. Widget = function call that writes to draw list and returns interaction state.                    | Immediate-mode function calls                                       | Application owns all state as plain variables                            |

### Key Extensibility Patterns

**FTXUI's Element/Component Duality** is particularly instructive. Elements (dom layer) are created by composing pure functions -- `text`, `hbox`, `vbox`, `border`. Components (interaction layer) produce Elements via `Render()` and handle events via `OnEvent()`. Custom components can subclass `ComponentBase` for complex interaction, or use `Renderer` lambdas for simple cases. The pipe operator composes decorators. For D, this duality maps to `@nogc` element structs (pure value types) + DbI-detected component capabilities.

**Cursive's View Trait + ViewWrapper** provides two paths: implement `View` for full control, or use `ViewWrapper` (which delegates most methods to an inner view) for decorators. The `Canvas` closure-based view enables rapid prototyping without trait implementation. For D, `ViewWrapper` maps to `alias this` or mixin templates.

**Mosaic's @Composable Functions** eliminate the widget class hierarchy entirely. Any `@Composable` function is a reusable component. State is held via `remember { mutableStateOf(...) }`. For D, composable functions returning element trees with UFCS modifiers achieve the same composition without a compiler plugin:

```d
auto statusBadge(string label, bool active) {
    return row(
        text(active ? "ON " : "OFF")
            .bg(active ? Color.green : Color.red)
            .pad(0, 1),
        text(" " ~ label),
    );
}
```

**Nottui's Widget-as-Value** approach has no widget classes, no inheritance, no widget IDs. A `Ui.t` is constructed from primitives and composed with combinators. Reactivity comes from wrapping in `Lwd.t`. For D, this maps to struct values composed via UFCS, with optional `Reactive!T` wrapping for incremental updates.

**libvaxis's comptime Duck Typing** is structurally identical to D's Design by Introspection. Any type with the right method signatures is a widget. The vxfw framework's manual vtable (`*anyopaque` + function pointers) is exactly what D's template constraints eliminate. D achieves the same polymorphism with `isWidget!T` and monomorphized code generation -- no manual vtable construction needed.

**tview's Primitive Interface + Box Embedding** provides a rich base: every widget embeds `Box` for free border, title, padding, background, and focus highlight. For D, this maps to `mixin BoxBehavior` injecting border drawing, padding calculation, and focus tracking into any widget struct, or `alias this` for transparent delegation.

**ImTui's No-Widget-Concept** is the radical alternative. A "custom widget" is just a function. For D, this means simple `@nogc` functions that write to a buffer and return interaction state -- the minimum possible widget API.

### Mapping to D

**Ratatui -> D template constraints (recommended for the core)**

```d
/// Any type with a `render(Rect, ref Buffer)` method is a widget.
enum isWidget(T) = is(typeof((T w, Rect area, ref Buffer buf) {
    w.render(area, buf);
}));

/// Stateful widgets also have an associated State type.
enum isStatefulWidget(T) = isWidget!T
    && is(T.State)
    && is(typeof((T w, Rect area, ref Buffer buf, ref T.State s) {
        w.render(area, buf, s);
    }));
```

**FTXUI -> D UFCS element composition (recommended for ergonomics)**

```d
/// Elements as value types composed via UFCS.
auto ui = vbox(
    text("Dashboard").bold.cyan.hCenter,
    separator(),
    hbox(
        gauge(0.73).color(Color.green).flex,
        gauge(0.58).color(Color.yellow).flex,
    ),
).border;
```

**Brick -> D Design by Introspection for size policies**

```d
/// Widget optionally declares size policy via enum members.
enum hasHPolicy(W) = is(typeof(W.hPolicy) == SizePolicy);
SizePolicy getHPolicy(W)() {
    static if (hasHPolicy!W) return W.hPolicy;
    else return SizePolicy.greedy;
}
```

**libvaxis -> D compile-time widget protocol (for zero-overhead generics)**

```d
/// Compile-time widget concept -- no interface, no vtable.
enum isWidget(T) = __traits(hasMember, T, "draw")
    && is(typeof((T w, Window win) { w.draw(win); }));

/// Optional capabilities detected at compile time.
enum isInteractiveWidget(T) = isWidget!T
    && __traits(hasMember, T, "handleEvent");

/// Dispatch events with optional handler.
void dispatchEvent(W)(ref W widget, Event event) if (isWidget!W) {
    static if (isInteractiveWidget!W)
        widget.handleEvent(event);
}
```

### Recommended Approach for D

Use **template-based duck-typing** (like Ratatui's trait, but resolved at compile time via `isWidget`) as the core contract. Extend with **Design by Introspection** for optional capabilities:

- `isWidget!T` -- core: has `render(Rect, ref Buffer)`
- `isStatefulWidget!T` -- has associated `State` type
- `hasHPolicy!T`, `hasVPolicy!T` -- declares size policy
- `hasFocusable!T` -- can receive focus
- `hasScrollable!T` -- supports scroll state

This avoids virtual dispatch entirely. All widget calls are monomorphized at compile time. The `ref Buffer` parameter follows Sparkles' established output-range pattern.

---

## 5. Styling Approaches Compared

| Library        | Mechanism                                                | Builder Pattern                                          | Color Support                   | Theme System                                   | Separation                           |
| -------------- | -------------------------------------------------------- | -------------------------------------------------------- | ------------------------------- | ---------------------------------------------- | ------------------------------------ |
| **Ratatui**    | `Style` struct + `Stylize` trait                         | `"hello".green().bold()`                                 | 16, 256, RGB                    | No built-in                                    | Style per Span/Line/Widget           |
| **Ink**        | JSX props: `color`, `bold`                               | Component props                                          | Named, hex, RGB (chalk)         | No built-in                                    | Props on components                  |
| **Textual**    | TCSS stylesheets + inline styles                         | CSS rule syntax                                          | Named, hex, RGB, HSL            | CSS variables (`$primary`)                     | External `.tcss` files               |
| **Bubble Tea** | Lip Gloss `NewStyle()` builder                           | `NewStyle().Bold(true).Foreground(...)`                  | 16, 256, RGB + Adaptive         | No built-in                                    | Style objects at Render              |
| **Brick**      | `AttrMap` with hierarchical `AttrName` keys              | `fg cyan \`withStyle\` bold`                             | 16, 256, RGB (Vty)              | `Brick.Themes` with INI serialization          | AttrMap separate, `withAttr` applies |
| **Notcurses**  | Cell-level 64-bit channels + 16-bit style mask           | Imperative set functions                                 | 16, 256, RGB + alpha            | No built-in                                    | Per-cell on plane                    |
| **FTXUI**      | Decorator functions + pipe operator                      | `text("hi") \| bold \| color(Color::Red) \| border`      | 16, 256, RGB, HSV, gradients    | No built-in                                    | Decorators wrap elements             |
| **Cursive**    | Theme-based `Palette` with semantic color roles          | `update_theme(\|t\| { ... })`                            | 8, 256, RGB (auto-downgrade)    | Built-in (Palette + TOML loading + ThemedView) | Global theme + per-view overrides    |
| **Mosaic**     | TextStyle bitmask + Color value class on Text params     | `TextStyle.Bold + TextStyle.Italic`                      | 16, 256, RGB (auto-downconvert) | No built-in                                    | Per-Text parameters                  |
| **Nottui**     | Notty attributes (`A.fg red ++ A.st bold`)               | OCaml operator composition (`++`)                        | 8, 16, 256, 24-bit              | No built-in                                    | Per-cell in Notty images             |
| **libvaxis**   | `Style` struct on `Cell`                                 | Struct literal: `.{ .fg = .{.rgb = ...}, .bold = true }` | 256, RGB                        | No built-in                                    | Per-cell Style struct                |
| **tview**      | Tag-based inline text styling + programmatic tcell.Style | `"[red::b]text[-]"`                                      | 16, 256, RGB (via tcell)        | Global `tview.Styles` theme variable           | Tags in text + setter methods        |
| **ImTui**      | ImGuiStyle struct (55 colors, 25 sizes) + Push/Pop stack | `PushStyleColor(idx, color)` / `PopStyleColor()`         | RGBA mapped to 256 ANSI         | Built-in (Dark/Light/Classic)                  | Global style + scoped overrides      |

### Key Styling Patterns

**FTXUI's Decorator Pipe** is the most compositional approach. Decorators are functions that wrap elements: `text("hi") | bold | color(Color::Red)`. The pipe operator is just `decorator(element)`. In D, this is UFCS: `text("hi").bold.color(Color.red)` -- identical semantics with no operator overloading.

**Cursive's Theme System** is the most complete theming approach. A `Palette` maps 11 semantic roles (Background, Primary, Highlight, etc.) to concrete colors. Views reference roles via `ColorType::Palette(role)`, enabling runtime theme switching. TOML files define themes externally. `ThemedView` applies local theme overrides to subtrees. For D, the palette enum maps directly, and CTFE can parse TOML themes at compile time -- impossible in Rust.

**tview's Tag-Based Styling** (`[red::b]Warning[-::-]`) embeds style information in text strings. While convenient for quick formatting, it requires runtime parsing and is limited to text content. For D, CTFE could parse these tags at compile time, producing pre-resolved style spans with zero runtime overhead.

**ImTui's Push/Pop Style Stack** uses scoped overrides: `PushStyleColor(idx, color)` ... `PopStyleColor()`. The "forgot to pop" bug is common in C++ ImGui code. For D, `scope(exit)` guards or RAII structs prevent this class of bug entirely.

**libvaxis's Style Struct** is the most minimal: a plain struct with boolean fields for attributes and union-tagged colors. No builder, no chain, no theme. For D, this direct struct approach is the natural `@nogc` representation for cell-level style storage.

### Relation to Sparkles' Existing `term_style`

Sparkles already has a `Style` enum with ANSI codes and a `stylizedTextBuilder` that supports UFCS-chain and CTFE styling:

```d
// Existing Sparkles pattern -- compile-time evaluated
enum greeting = "Hello"
    .stylizedTextBuilder(true)
    .bold
    .green;
```

This is closest to Ratatui's `Stylize` trait and FTXUI's pipe operator, but with the advantage of compile-time evaluation via `enum`.

### Extension Path

To support TUI widgets, the style system needs:

1. **Structured `CellStyle` struct** (like Ratatui/libvaxis): Hold optional fg/bg colors and modifier flags, separate from ANSI string rendering.

2. **RGB color support**: `Color.rgb(r, g, b)` and `Color.indexed(n)`, matching Ratatui's `Color` enum.

3. **Incremental style application**: Applying a style patches only the fields it sets, enabling layered composition.

4. **Attribute maps** (Brick/Cursive-inspired): Compile-time or runtime maps from semantic names to styles for themeable widgets. D's CTFE can parse theme TOML at compile time.

5. **UFCS builder preserved**: `auto style = CellStyle.init.fg(Color.green).bold.bg(Color.black);`

---

## 6. Event Handling Compared

### Architecture Summary

| Library        | Model                                                        | Centralized?                                      | Keyboard                     | Mouse                              | Focus                                           | Async                             |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------- | ---------------------------- | ---------------------------------- | ----------------------------------------------- | --------------------------------- |
| **Ratatui**    | Not provided (app's responsibility)                          | N/A                                               | Via backend                  | Via backend                        | Manual                                          | Via async runtime                 |
| **Ink**        | Hooks (`useInput`, `useFocus`)                               | Distributed (per-component)                       | `useInput` hook              | Not supported                      | Built-in (`useFocus`)                           | React concurrent mode             |
| **Textual**    | Message bubbling through DOM                                 | Centralized tree                                  | `on_key`, `BINDINGS`         | Full                               | CSS `:focus`                                    | asyncio-first                     |
| **Bubble Tea** | All events as `Msg` to `Update`                              | Fully centralized                                 | `KeyMsg`                     | `MouseMsg`                         | Manual                                          | `Cmd` as async values             |
| **Brick**      | `BrickEvent` to `appHandleEvent`                             | Fully centralized                                 | `VtyEvent`                   | Per-widget                         | `appChooseCursor`                               | `liftIO` in `EventM`              |
| **Notcurses**  | Raw input API (`notcurses_get`)                              | App-controlled                                    | `ncinput` struct             | Full                               | Manual                                          | Thread-safe, app manages          |
| **FTXUI**      | `OnEvent(Event) -> bool` on ComponentBase                    | Tree-based (focus path + bubbling)                | Event struct matching        | Full (click, scroll, motion, drag) | Built-in focus tree (ActiveChild)               | `Post()` for thread marshaling    |
| **Cursive**    | Callbacks via `EventResult`                                  | Tree-based (focused path + bubbling + global)     | `Event` enum matching        | Via backends                       | Built-in (Tab/Shift-Tab, `take_focus`)          | `cb_sink()` channel injection     |
| **Mosaic**     | `onKeyEvent` / `onPreviewKeyEvent` modifiers                 | Two-phase (preview down, bubble up)               | `KeyEvent` data class        | Not supported                      | Not built-in                                    | Coroutines (`LaunchedEffect`)     |
| **Nottui**     | `keyboard_area` / `mouse_area` / `event_filter` wrappers     | Tree-based (propagation with Handled/Unhandled)   | Polymorphic variant matching | Full (click, drag, release, grab)  | Built-in                                        | Lwt for async                     |
| **libvaxis**   | Tagged union event loop (`switch` on Event)                  | App-controlled                                    | `Key` struct                 | Full (SGR pixel precision)         | Manual (vxfw App provides basic tracking)       | Background thread + event queue   |
| **tview**      | Callbacks (`SetInputCapture`, `SetChangedFunc`, etc.)        | Framework-managed (capture chain + focus routing) | `*tcell.EventKey`            | Full (click, drag, scroll)         | Built-in (framework tracks, Tab navigation)     | `QueueUpdateDraw` from goroutines |
| **ImTui**      | Widget return values (`if (Button("OK"))`) + global IO state | None -- inline with rendering                     | `IsKeyPressed(key)`          | `io.MousePos`, `IsMouseClicked()`  | Hot/Active model (automatic, no explicit focus) | N/A (single-threaded frame loop)  |

### Key Event Handling Patterns

**Cursive's Callback-Based Events** use `EventResult` (Ignored or Consumed with optional callback). Events flow top-down through the focused path, then bubble up if ignored. Global callbacks catch unhandled events. The `OnEventView` wrapper adds per-view interception. The `cb_sink()` channel enables async injection from background threads. The pattern is familiar from desktop GUI toolkits but prone to callback spaghetti in complex applications.

**tview's Framework-Managed Events** provide a capture chain: Application capture -> ancestor captures (top-down) -> focused widget's InputHandler. Widget-specific callbacks (`SetChangedFunc`, `SetSelectedFunc`, `SetDoneFunc`) provide semantic event handling. `QueueUpdateDraw` serializes goroutine-to-UI communication.

**FTXUI's Component Event Handlers** use the `OnEvent(Event) -> bool` pattern on `ComponentBase`. Events propagate through the component tree: the deepest focused component handles first, bubbling up on `false`. The `CatchEvent` decorator intercepts events before they reach a component.

**Mosaic's Two-Phase Propagation** mirrors Android: `onPreviewKeyEvent` fires top-down (preview/capture phase), `onKeyEvent` fires bottom-up (bubble phase). Returning `true` stops propagation. This is integrated with Kotlin coroutines for async side effects.

**Nottui's Reactive Event Handlers** wrap widgets with `keyboard_area`, `mouse_area`, or `event_filter`. Handlers return `` `Handled `` or `` `Unhandled `` variants. Mouse areas support `` `Grab `` for drag capture. Events flow through the widget tree from root toward leaves.

**libvaxis's Tagged Union Events** use Zig's exhaustive `switch` on a `union(enum)`. The `Loop` type is parameterized on the application's `Event` type -- `@hasField` at comptime determines which event categories to dispatch, generating zero code for undeclared variants. This is zero-cost event filtering.

**ImTui's Inline Event Handling** is the simplest: `if (Button("Submit")) submitForm();`. No event propagation, no callbacks, no registration. The widget function checks interaction state at the call site. Item query functions (`IsItemHovered()`, `IsItemActive()`) provide additional state after any widget call.

### Recommendation for Sparkles

Follow Ratatui's approach: **do not own the event loop**. Provide event-related utilities (input parsing, key mapping, mouse event structures) but let the application control the loop. Use D's `SumType` for structured events with exhaustive matching:

```d
alias Event = SumType!(KeyEvent, MouseEvent, ResizeEvent, TickEvent);

// Pure update function -- compiler-enforced
@safe pure nothrow
Model update(in Model model, in Event event) {
    return event.match!(
        (KeyEvent k)    => handleKey(model, k),
        (MouseEvent m)  => handleMouse(model, m),
        (ResizeEvent r) => handleResize(model, r),
        (TickEvent t)   => handleTick(model, t),
    );
}
```

For libvaxis-inspired comptime event filtering, D can use `static if` on event type members:

```d
Event handleEvent(Event)(RawEvent raw) {
    static if (__traits(hasMember, Event, "keyPress")) {
        if (raw.isKeyPress)
            return Event(Event.Kind.keyPress, raw.toKey);
    }
}
```

---

## 7. Performance Characteristics

### Allocation Patterns

| Library        | Language GC     | Render-path allocations                          | Buffer type               | Widget lifetime                           |
| -------------- | --------------- | ------------------------------------------------ | ------------------------- | ----------------------------------------- |
| **Ratatui**    | None (Rust)     | `Vec<Cell>` reused across frames                 | Flat cell grid            | Ephemeral                                 |
| **Bubble Tea** | Go GC           | String alloc per frame                           | String                    | Ephemeral                                 |
| **Textual**    | Python GC       | Rich Segment objects per dirty widget            | Segment lists             | Persistent                                |
| **Ink**        | JS GC           | React fiber tree + ANSI string                   | String buffer             | Persistent                                |
| **Brick**      | Haskell GC      | Vty Image alloc per frame                        | Image (lazy)              | Ephemeral                                 |
| **Notcurses**  | None (manual C) | Zero in common path (cells inline)               | Packed cell grid          | Persistent (planes)                       |
| **FTXUI**      | None (C++)      | `shared_ptr<Node>` per element per frame         | Screen pixel grid         | Element: ephemeral. Component: persistent |
| **Cursive**    | None (Rust)     | `Box<dyn View>` for view tree (persistent)       | Printer writes to backend | Persistent                                |
| **Mosaic**     | JVM/Native GC   | Slot table + TextSurface per frame               | TextPixel grid            | Persistent (slot table)                   |
| **Nottui**     | OCaml GC        | Incremental -- only damaged nodes recomputed     | Notty Image               | Persistent (DAG)                          |
| **libvaxis**   | None (Zig)      | Explicit allocator; arena per frame in vxfw      | Screen cell buffer        | Ephemeral                                 |
| **tview**      | Go GC           | Widget tree persistent; tcell cell buffer reused | tcell Screen              | Persistent                                |
| **ImTui**      | None (C++)      | Zero (TScreen is flat array, reused)             | Packed TCell grid         | None (no widgets)                         |

### Key Allocation Insights

**libvaxis's allocator-aware pattern** is the most relevant for D. Every allocation site accepts a `std.mem.Allocator` parameter. The vxfw framework uses per-frame arena allocation for temporaries (formatted text, layout scratch), freed automatically at frame end. D's `@nogc` attribute provides the same guarantee at the type level -- the compiler ensures no hidden GC allocation rather than relying on the programmer to thread allocators correctly.

**FTXUI's value-based elements** create `shared_ptr<Node>` for every element every frame. In D, elements as `@nogc` struct values stored in `SmallBuffer` eliminate this heap allocation entirely. For small-to-medium UIs (the common case in CLI tools), the entire Element tree fits in a `SmallBuffer` with no heap allocation at all.

**ImTui's zero-widget-state** approach is the most allocation-friendly. The `TScreen` is a flat array of packed 32-bit `TCell` values (character + colors), reused across frames. There are no widget objects to allocate. The entire render path is just function calls writing to a fixed-size buffer. This is the theoretical minimum for allocation in a TUI framework.

**Nottui's incremental computation** avoids the allocation problem differently: the reactive DAG is allocated once and reused. Updates touch only damaged nodes, so neither allocation nor computation scales with total UI size. The `Lwd_table` reactive collection tracks insertions/deletions incrementally. For D, a pre-allocated `DependencyGraph` with `SmallBuffer`-backed node arrays achieves the same pattern `@nogc`.

**Mosaic's slot table** is a flat, gap-buffer-style array that stores composition state. While not zero-allocation (JVM/native GC manages the slot table), the design minimizes allocation by reusing slots across recompositions. For D, the lesson is that a flat, reusable buffer for composition state is more efficient than per-frame tree construction.

### @nogc Feasibility

| Approach                              | @nogc feasibility | Notes                                                                 |
| ------------------------------------- | ----------------- | --------------------------------------------------------------------- |
| **ImTui-style pure immediate**        | **Highest**       | Zero widget objects, flat buffer, function calls only                 |
| **libvaxis-style explicit allocator** | **High**          | Arena per frame, explicit control at every site                       |
| **Ratatui-style cell buffer**         | **High**          | `SmallBuffer!(Cell, N)` for typical screens                           |
| **Notcurses-style planes**            | **High**          | Manual alloc with RAII; cell packing is naturally @nogc               |
| **FTXUI-style functional DOM**        | **High in D**     | shared_ptr in C++, but elements as @nogc structs in D                 |
| **Nottui-style incremental DAG**      | **High**          | Pre-allocated graph, no per-frame allocation                          |
| **Brick-style pure rebuild**          | **Moderate**      | Compatible if output goes to cell buffer                              |
| **Bubble Tea-style string render**    | **Moderate**      | `SmallBuffer!(char, N)` instead of heap string                        |
| **Cursive-style retained view tree**  | **Low-Moderate**  | View tree requires allocation; `pureMalloc`-based allocators possible |
| **tview-style retained widget tree**  | **Low-Moderate**  | Go GC manages widgets; D would need manual allocation                 |
| **Textual-style retained DOM**        | **Low**           | Persistent object tree with dynamic dispatch                          |
| **Mosaic-style Compose**              | **Low**           | Depends on compiler plugin + JVM/native runtime                       |
| **Ink-style React reconciler**        | **Very low**      | Fundamentally depends on GC                                           |

### Frame Diffing Strategies

| Library        | Diffing unit      | Strategy                                                          |
| -------------- | ----------------- | ----------------------------------------------------------------- |
| **Ratatui**    | Cell              | Current vs previous buffer, cell-by-cell                          |
| **Bubble Tea** | Line              | String output, line-by-line                                       |
| **Textual**    | Region            | Compositor identifies dirty widget regions                        |
| **Ink**        | Full output       | Overwrite entire output region                                    |
| **Brick**      | Full image        | Vty diffs entire composed Image                                   |
| **Notcurses**  | Cell              | Full compositor pass, then cell-by-cell diff                      |
| **FTXUI**      | Cell              | ScreenInteractive diffs current vs previous                       |
| **Cursive**    | Full              | Entire view tree re-laid-out and re-drawn per event               |
| **Mosaic**     | Differential ANSI | Emit style codes only when pixel attributes change cell-to-cell   |
| **Nottui**     | Incremental       | Only damaged nodes recomputed; Notty handles rendering            |
| **libvaxis**   | Cell              | Screen vs screen_last, cell equality check with fast default path |
| **tview**      | Cell              | tcell diffs new cell buffer vs previous                           |
| **ImTui**      | Cell              | TScreen current vs screenPrev, row-by-row character comparison    |

### Performance Ranking for D Implementation

1. **ImTui-style flat buffer** -- Zero allocation, function calls to fixed buffer, cell-level diff. Theoretical minimum overhead.
2. **Notcurses/libvaxis-style packed cells** -- Zero allocation in common path, cell-level diff, explicit memory control. Highest raw performance with retained planes.
3. **Ratatui-style cell buffer** -- Near-zero allocation with `SmallBuffer`, cell-level diff, immediate-mode simplicity. Best balance of performance and ergonomics.
4. **FTXUI-style functional DOM (in D)** -- Elements as `@nogc` structs in `SmallBuffer` instead of `shared_ptr`. Combines compositional elegance with zero allocation.
5. **Nottui-style incremental DAG** -- Pre-allocated graph, O(k) updates for sparse changes. Best asymptotic performance for large, mostly-static UIs.
6. **Brick-style pure rebuild** -- Compatible with `@nogc` if output goes to cell buffer.
7. **Retained-mode (Cursive/tview adapted)** -- Requires allocation management but provides framework-level focus/layout.

---

## 8. Synthesis: Design Recommendations for Sparkles

### Recommended Architecture

**Adopt Ratatui's library-centric model as the core, enhanced with FTXUI-inspired functional DOM composition via UFCS, Brick's combinator API, Bubble Tea's MVU as an optional layer, Nottui-inspired incremental reactivity as an optimization path, and ImTui-style immediate-mode widget functions as a rapid-prototyping fast path.**

The rationale:

1. **Ratatui's approach is the most natural fit for D.** Widgets as value-type structs, rendered into a cell buffer via template-constrained `render` methods, consumed by value -- this maps directly to `@nogc` D idioms with zero virtual dispatch overhead. The library does not own the event loop, respecting the application's control.

2. **FTXUI's functional DOM composition translates beautifully to D UFCS.** Where FTXUI writes `text("hello") | bold | color(Color::Red) | border`, D writes `text("hello").bold.color(Color.red).border`. No special pipe operator needed -- UFCS is built-in, works at compile time, and composes with any free function. Elements as `@nogc` struct values in `SmallBuffer` instead of `shared_ptr` nodes eliminate FTXUI's per-node heap allocation. This is arguably the single most important lesson: FTXUI proved the functional DOM pattern works for terminals; D's UFCS makes it even more natural.

3. **Brick's combinators provide the layout vocabulary.** `items.vBox.hLimit(25).padAll(1).borderWithLabel("Files")` -- same composability as Haskell, better readability, zero runtime overhead.

4. **Bubble Tea's MVU pattern maps to D's `pure` + `SumType`.** For applications wanting structured state management, an optional module provides `Model`/`update`/`view` scaffolding where `update` is `pure` (compiler-enforced) and messages are `SumType` (exhaustive matching).

5. **Mosaic's Compose model inspires D CTFE-driven reactive patterns.** While D cannot replicate Kotlin's compiler plugin, it can approximate snapshot state with `Reactive!T` wrapper structs, generate change-detection logic via `mixin Reactive!(MyState)`, and use CTFE to validate composable function signatures. The key insight from Compose: compile-time code generation for reactive state tracking is more efficient than runtime virtual DOM diffing.

6. **Nottui's incremental computation is the most principled update strategy.** For large UIs where full rebuilds are expensive, a `Reactive!T` system with dependency-tracked DAG propagation avoids both O(n) full redraws and O(n) virtual DOM diffs. The DAG can be pre-allocated and reused `@nogc`. This is the most promising path for high-performance partial updates.

7. **libvaxis's comptime patterns are DIRECTLY applicable to D.** Zig's `comptime` and D's CTFE serve the same purpose. `@hasField` -> `__traits(hasMember, ...)`. comptime event filtering -> `static if` on event union members. Manual vtable construction -> D template constraints (more ergonomic). Explicit allocator passing -> `@nogc` attribute (compiler-enforced). libvaxis validates that D's language features are sufficient for a modern, zero-overhead TUI library.

8. **ImTui proves pure immediate-mode works for complex UIs.** The hnterm Hacker News client is a production-quality terminal application built entirely with immediate-mode function calls. D can offer this as a rapid-prototyping layer with compile-time widget IDs (via `__FILE__`/`__LINE__` template parameters) and `scope(exit)` style guards.

9. **Cursive and tview show retained-mode variants' strengths.** Built-in focus management, dialog stacking, and form handling reduce boilerplate for form-heavy applications. D could offer these as optional framework modules on top of the core rendering library, using D interfaces for runtime polymorphism where heterogeneous view trees are needed, alongside template-based static dispatch for known-at-compile-time trees.

10. **Textual's dirty-tracking compositor is a valuable optimization.** A dirty-tracking layer on top of the cell buffer can skip re-rendering unchanged regions. This is an optimization, not a core architectural requirement.

### Core Abstractions

#### Widget Concept (Template-Based, DbI)

```d
/// Core widget concept: any type that can render to a Buffer.
enum isWidget(T) = is(typeof((T w, Rect area, ref Buffer buf) {
    w.render(area, buf);
}));

/// Extended: stateful widget with associated State type.
enum isStatefulWidget(T) = isWidget!T
    && is(T.State)
    && is(typeof((T w, Rect area, ref Buffer buf, ref T.State s) {
        w.render(area, buf, s);
    }));

/// DbI: optional size policy declaration.
SizePolicy hPolicyOf(W)() {
    static if (__traits(hasMember, W, "hPolicy"))
        return W.hPolicy;
    else
        return SizePolicy.greedy;  // default: fill available space
}
```

#### Layout System Approach

Hybrid: Brick-style combinators as the primary API, FTXUI-style flexbox for CSS-familiar developers, optional Ratatui-style constraint solver for advanced responsive layouts.

```d
/// Combinator-based layout (primary, UFCS)
auto ui = vBox(
    "Dashboard".text.bold.cyan.hCenter,
    hBorder(),
    hBox(
        sidebarWidget.hLimit(25),
        vBorder(),
        contentWidget,  // greedy: fills remaining space
    ),
    hBorder(),
    statusLine.text,
);

/// FTXUI-style flexbox (CSS-familiar)
auto config = FlexboxConfig(
    direction: Direction.row,
    justifyContent: JustifyContent.spaceBetween,
    gap: Gap(x: 1, y: 0),
);
auto layout = flexbox(children, config);

/// Constraint-based layout (advanced)
auto [header, body, footer] = Layout.vertical([
    Constraint.length(3),
    Constraint.fill(1),
    Constraint.length(1),
]).split(frame.area);
```

#### Buffer / Rendering Pipeline

```d
@safe pure nothrow @nogc:

/// A single terminal cell.
struct Cell {
    SmallBuffer!(char, 8) grapheme;  // inline for ASCII/BMP, spills for long EGCs
    StyleFlags style;                // bold, italic, underline, etc.
    Color fg = Color.default_;
    Color bg = Color.default_;
}

/// A rectangular grid of cells.
struct Buffer {
    Rect area;
    Cell[] cells;  // or SmallBuffer!(Cell, 80 * 24) for typical terminals

    /// Write a styled string at position.
    void setString(ushort x, ushort y, scope const(char)[] text, Style style) { ... }

    /// Diff against previous frame, writing only changed cells to output.
    void diff(scope const Buffer prev, Writer)(ref Writer output) { ... }
}

/// Terminal wraps double-buffering and backend communication.
struct Terminal(B) if (isBackend!B) {
    B backend;
    Buffer current;
    Buffer previous;

    /// Render a frame: call the draw function, diff, flush.
    void draw(scope void delegate(ref Frame) @nogc nothrow drawFn) {
        auto frame = Frame(&this.current);
        drawFn(frame);
        current.diff(previous, backend);
        backend.flush();
        swap(current, previous);
    }
}
```

#### Style System (Extending Existing term_style)

```d
/// Structured style for cell-level storage (not ANSI strings).
struct CellStyle {
    Nullable!Color fg;
    Nullable!Color bg;
    Modifiers modifiers;  // bitflag: bold, italic, underline, etc.

    /// Incremental patch: only overwrite fields that are set.
    CellStyle patch(CellStyle other) const { ... }
}

/// Color with full range support.
struct Color {
    enum Type : ubyte { default_, ansi16, ansi256, rgb }
    Type type;
    ubyte r, g, b;

    static Color rgb(ubyte r, ubyte g, ubyte b) { ... }
    static Color indexed(ubyte n) { ... }
}

/// UFCS style builder (preserves existing Sparkles pattern).
auto bold(CellStyle s) { return CellStyle(s.fg, s.bg, s.modifiers | Modifiers.bold); }
auto fg(CellStyle s, Color c) { return CellStyle(Nullable!Color(c), s.bg, s.modifiers); }
```

#### Event System

```d
/// Structured event types with D SumType.
struct KeyEvent {
    dchar codepoint;
    Modifiers modifiers;
    KeyAction action;
}

struct MouseEvent {
    ushort x, y;
    MouseButton button;
    MouseAction action;
    Modifiers modifiers;
}

struct ResizeEvent {
    ushort width, height;
}

alias Event = SumType!(KeyEvent, MouseEvent, ResizeEvent);

/// Optional MVU layer built on core event types.
@safe pure nothrow
Model update(in Model model, in Event event) {
    return event.match!(
        (in KeyEvent k)    => handleKey(model, k),
        (in MouseEvent m)  => handleMouse(model, m),
        (in ResizeEvent r) => handleResize(model, r),
    );
}
```

#### Optional: Incremental Reactivity Layer (Nottui-inspired)

```d
/// A reactive value that tracks dependencies automatically.
struct Reactive(T) {
    private T _value;
    private DependencyNode _node;

    /// Read the value, registering a dependency on the current computation.
    T get() @safe {
        if (auto ctx = RenderContext.current)
            ctx.registerDependency(&_node);
        return _value;
    }

    /// Read without dependency tracking (for event handlers).
    T peek() @safe pure nothrow @nogc { return _value; }

    /// Set the value, invalidating all dependents.
    void set(T newVal) @safe {
        _value = newVal;
        _node.invalidateDependents();
    }
}

/// Incremental propagation -- only recompute damaged nodes.
@safe @nogc nothrow
void propagateChanges(DependencyGraph* graph) {
    foreach (node; graph.damagedNodes) {
        node.recompute();
        node.markClean();
    }
}
```

### Incremental Path from Current Sparkles

#### Phase 1: Buffer + Cell + Backend Abstraction

**Goal:** Establish the foundational rendering primitives.

- `Cell` struct: grapheme (SmallBuffer-based) + style + fg/bg color
- `Buffer` struct: `Rect` + flat cell array with `setString`, `setCell`, `diff`
- `Color` type: ANSI 16, 256, and RGB support
- `CellStyle` struct: fg, bg, modifiers with incremental patching
- `Backend` template constraint: `draw`, `flush`, `clear`, `size`
- POSIX backend: alternate screen, raw mode, ANSI output
- `TestBackend`: in-memory backend for deterministic testing
- `Terminal(B)` struct: double-buffering, diffing, draw function

This phase builds on the existing `term_style` module (extending it) and `SmallBuffer` (for cell graphemes and buffer storage).

#### Phase 2: Layout Engine

**Goal:** Provide composable layout primitives.

- `Rect` struct: position + size, with arithmetic helpers
- Brick-style combinators as UFCS functions: `hBox`, `vBox`, `hLimit`, `vLimit`, `padLeft`, `padAll`, `hCenter`, `vCenter`, `fill`
- FTXUI-style flexbox: `FlexboxConfig` struct with direction, wrap, justify, align, gap
- `SizePolicy` enum (Fixed/Greedy) with DbI detection
- Two-pass layout algorithm: allocate Fixed children first, divide remainder among Greedy
- Optional: Cassowary constraint solver for `Constraint.length`, `Constraint.fill`, `Constraint.percentage`
- Layout result caching (thread-local, keyed on constraints + input area)

#### Phase 3: Widget System

**Goal:** Define the widget contract and provide built-in widgets.

- `isWidget` template constraint
- `isStatefulWidget` with associated `State` type
- Built-in widgets: `Text`, `Paragraph` (with wrapping), `Block` (borders + title), `List`/`ListState`, `Table`/`TableState`, `Gauge`, `Separator`
- FTXUI-style element composition: `text("hello").bold.border` via UFCS
- Optional ImTui-style immediate-mode functions: `button(buf, "Submit")`, `sliderInt(buf, "Volume", &state.volume, 0, 100)`
- `AttrMap` for semantic styling (Brick/Cursive-inspired): compile-time `enum` maps for themes
- `Viewport` with named scrollable regions

#### Phase 4: Event Loop + State Management

**Goal:** Provide optional structured event handling and reactivity.

- `Event` SumType: `KeyEvent`, `MouseEvent`, `ResizeEvent`, custom events
- Input parsing module: raw terminal bytes to structured `Event` values (libvaxis-inspired direct query, no terminfo dependency)
- Optional MVU module: `Model`/`update`/`view` scaffolding with `pure` enforcement
- `Cmd` type for side effects (Bubble Tea-inspired)
- Focus management utilities (Cursive/tview-inspired)
- Optional `Reactive!T` layer with incremental dependency tracking (Nottui-inspired)

### Open Questions

#### Retained vs Immediate for D?

**Recommendation: Immediate-mode as the default, with optional retained-mode and incremental-mode optimization paths.**

Immediate mode is the natural fit for `@nogc` D: widgets are stack-allocated, consumed on render, with no persistent allocations. For large UIs where rebuilding everything is expensive, two optimization paths are available:

1. **Dirty-tracking** (Textual-inspired): mark regions as clean and skip re-rendering.
2. **Incremental computation** (Nottui-inspired): pre-allocated dependency DAG with O(k) updates for sparse changes.

The core API should be immediate-mode -- it is simpler, easier to reason about, and aligns with D's zero-overhead philosophy.

#### CSS-like DSL vs Pure D Combinators?

**Recommendation: Pure D combinators as the primary API, with optional compile-time CSS parsing.**

Combinators (Brick/FTXUI-style via UFCS) provide type safety, `@nogc` compatibility, and zero runtime parsing cost. A compile-time CSS parser (via CTFE `import(...)` + string processing) could be provided for developers who prefer external stylesheets, but it should not be the primary interface.

#### Compile-time vs Runtime Layout?

**Recommendation: Both, with compile-time as the fast path.**

For layouts known at compile time (static dashboards, fixed-structure UIs), CTFE can pre-compute the entire layout into a `static immutable Rect[]`. For dynamic layouts (user-resizable panes, responsive designs), runtime constraint solving is necessary. The API should be the same in both cases.

#### Should Sparkles Bind to Notcurses or Build from Scratch?

**Recommendation: Build from scratch, informed by Notcurses' and libvaxis's design decisions.**

Rationale:

- **D's strengths are underutilized by a C binding.** A binding gives access to Notcurses' features but none of D's advantages: no `@nogc` enforcement, no UFCS, no CTFE validation, no template-based widgets.

- **The core patterns are straightforward to implement.** Packed cell representation, double-buffered diffing, escape sequence generation -- libvaxis demonstrates these in ~5k lines of Zig, and the patterns translate directly to D.

- **libvaxis validates the no-terminfo approach.** Direct escape sequence generation with runtime capability queries (as libvaxis does) is more reliable and simpler than depending on terminfo databases. D's seamless C interop enables fallback to terminfo for legacy terminals.

- **Dependency cost.** Notcurses has a non-trivial build chain. Building from scratch in D keeps the dependency graph minimal.

- **Selective borrowing.** Specific innovations should be adopted: inline glyph cluster packing (via `SmallBuffer!(char, 8)`), packed cell representation, Kitty keyboard protocol support, and synchronized output. These can be implemented natively in D.
