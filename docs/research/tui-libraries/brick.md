# Brick (Haskell)

A declarative terminal user interface library for Haskell that lets developers build TUIs by writing pure functions to describe how the UI should look based on application state.

| Field          | Value                                                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Language       | Haskell                                                                                                                              |
| License        | BSD-3-Clause                                                                                                                         |
| Repository     | [github.com/jtdaugherty/brick](https://github.com/jtdaugherty/brick)                                                                 |
| Documentation  | [Hackage](https://hackage.haskell.org/package/brick) / [User Guide](https://github.com/jtdaugherty/brick/blob/master/docs/guide.rst) |
| Latest Version | ~2.10                                                                                                                                |
| GitHub Stars   | ~1.7k                                                                                                                                |

---

## Overview

### What It Solves

Brick provides a high-level, declarative abstraction for building terminal user interfaces in Haskell. Rather than imperatively manipulating terminal cells, developers describe the UI as a pure function from application state to a list of widget layers. Brick handles rendering, diffing, layout computation, and the event loop internally.

### Design Philosophy

Brick is built on three core principles:

1. **Pure functional rendering** -- the drawing function `appDraw` is a pure function from state `s` to `[Widget n]`. No IO is involved in describing what the UI looks like.
2. **Declarative widget combinators** -- layouts are composed using combinators like `hBox`, `vBox`, `padLeft`, `hLimit`, `center`, and `viewport`. These compose cleanly, producing complex layouts from simple building blocks.
3. **Typed application structure** -- the `App s e n` record type parameterizes the entire application over its state type, custom event type, and resource name type, giving the compiler full visibility into the application's structure.

### History

Brick was created by **Jonathan Daugherty** and is built on top of the **Vty** library (also by Daugherty). Vty handles the low-level terminal abstraction -- input parsing, output rendering, color support -- while Brick provides the higher-level widget, layout, and application architecture layers.

The library has been under active development since around 2015 and is one of the most mature and well-documented TUI libraries in any language. It has comprehensive Haddock API documentation, a detailed user guide (`docs/guide.rst`), over 30 demo programs, and an FAQ. Over 50 known projects have been built with Brick, including terminal games, mail clients, file managers, and developer tools.

---

## Architecture

### Application Type

The central type in Brick is `App s e n`, a record parameterized over three type variables:

- **`s`** -- the application state type
- **`e`** -- the custom event type (for application-specific asynchronous events)
- **`n`** -- the resource name type (used to identify viewports, extents, cursors, and mouse event targets)

```haskell
data App s e n =
    App { appDraw         :: s -> [Widget n]
        , appChooseCursor :: s -> [CursorLocation n] -> Maybe (CursorLocation n)
        , appHandleEvent  :: BrickEvent n e -> EventM n s ()
        , appStartEvent   :: EventM n s ()
        , appAttrMap      :: s -> AttrMap
        }
```

### Core Functions

| Function          | Signature                                             | Purpose                                                         |
| ----------------- | ----------------------------------------------------- | --------------------------------------------------------------- |
| `appDraw`         | `s -> [Widget n]`                                     | Pure function producing a list of widget layers (topmost first) |
| `appHandleEvent`  | `BrickEvent n e -> EventM n s ()`                     | Monadic handler that modifies state in response to events       |
| `appStartEvent`   | `EventM n s ()`                                       | One-time initialization at application startup                  |
| `appChooseCursor` | `s -> [CursorLocation n] -> Maybe (CursorLocation n)` | Selects which cursor location to display                        |
| `appAttrMap`      | `s -> AttrMap`                                        | Maps attribute names to visual attributes                       |

### Rendering Model: Retained / Declarative

Brick uses a **declarative, retained-style** rendering model. The application never directly manipulates terminal cells. Instead:

1. `appDraw` produces a list of `Widget n` layers from the current state.
2. Brick's rendering engine evaluates each widget's rendering function, threading layout constraints (available width, height) through the widget tree.
3. Widgets produce `Result n` values containing Vty `Image`s, cursor positions, visibility requests, and border information.
4. Brick composites the layers and hands the final `Image` to Vty for efficient terminal output with minimal repainting.

### Event Loop

Brick owns the event loop. The developer does not write a loop. The flow is:

```
startup -> appStartEvent -> render (appDraw) -> wait for event
  -> appHandleEvent -> render -> wait for event -> ...
  -> halt (terminates the loop)
```

After each event handler completes, three outcomes are possible:

- **Default**: re-render the screen by calling `appDraw` again.
- **`halt`**: stop the event loop and return the final state.
- **`continueWithoutRedraw`**: skip re-rendering (optimization for events that do not change visible state).

### EventM Monad

In the current API (Brick 2.x), `appHandleEvent` operates in the `EventM n s ()` monad rather than returning a pure state transformation. `EventM` provides:

- **`MonadState s`** -- full `mtl`-style state access (`get`, `put`, `modify`)
- **Lens operations** -- via `microlens-mtl`, enabling `zoom`, `.=`, `%=` for focused state updates
- **`liftIO`** -- for performing IO when needed (e.g., reading files)
- **Scrolling requests** -- `hScrollBy`, `vScrollBy`, `vScrollPage`, `vScrollToBeginning`, etc.
- **Extent lookups** -- querying rendered widget positions and sizes
- **Vty handle access** -- for low-level terminal operations when necessary

---

## Terminal Backend

### Vty (Virtual Terminal)

Brick is built on top of **Vty**, a Haskell library described as "a high-level ncurses alternative." Vty handles all direct terminal interaction:

| Capability       | Details                                                             |
| ---------------- | ------------------------------------------------------------------- |
| Color support    | True color (24-bit), 256 color, 16 color                            |
| Input parsing    | Keyboard events, mouse events (normal and SGR extended mode)        |
| Output rendering | Efficient buffered output, minimal terminal state changes           |
| Unicode          | Full multi-column Unicode support (CJK, emoji), custom width tables |
| Resize handling  | Automatic window resize detection and notification                  |
| Paste mode       | Bracketed paste support                                             |
| Refresh          | Automatic Ctrl-L screen refresh                                     |

### Image Model

Vty renders **Images** -- layers of characters with attributes (colors, styles). The rendering model minimizes the repaint area on each frame, "which virtually eliminates the flicker problems that plague ncurses programs." Images are composed using pure, compositional combinators before being flushed to the terminal.

### Platform Support

- **vty-unix** -- Unix/Linux backend using terminfo
- **vty-windows** -- Windows backend
- **vty-crossplatform** -- Selects the appropriate backend automatically

Brick 2.0+ depends on `vty-crossplatform`, enabling support beyond Unix-like systems. Prior versions (1.x) were Unix-only.

---

## Layout System

### Combinator-Based Layout

Brick's layout system is entirely combinator-based. Widgets are composed using functions that express spatial relationships and constraints. There are no coordinates, no absolute positioning -- only relative, declarative composition.

### Key Combinators

| Combinator                    | Purpose                                 |
| ----------------------------- | --------------------------------------- |
| `hBox [w1, w2, ...]`          | Horizontal composition (left to right)  |
| `vBox [w1, w2, ...]`          | Vertical composition (top to bottom)    |
| `w1 <+> w2`                   | Infix horizontal composition            |
| `w1 <=> w2`                   | Infix vertical composition              |
| `padLeft n w`, `padRight n w` | Horizontal padding                      |
| `padTop n w`, `padBottom n w` | Vertical padding                        |
| `padAll n w`                  | Uniform padding on all sides            |
| `padLeftRight n w`            | Horizontal padding on both sides        |
| `padTopBottom n w`            | Vertical padding on both sides          |
| `hLimit n w`                  | Constrain widget to at most `n` columns |
| `vLimit n w`                  | Constrain widget to at most `n` rows    |
| `hCenter w`, `vCenter w`      | Center horizontally / vertically        |
| `center w`                    | Center in both dimensions               |
| `fill c`                      | Fill available space with character `c` |
| `viewport name type w`        | Create a named scrollable region        |

### Widget Sizing: Greedy vs Fixed

Every widget carries two `Size` values (horizontal and vertical), each being either `Fixed` or `Greedy`:

```haskell
data Size = Fixed | Greedy
```

- **`Fixed`** -- the widget uses the same amount of space regardless of how much is available. Examples: `str "hello"`, `hLimit 20 w`.
- **`Greedy`** -- the widget expands to fill all available space. Examples: `fill ' '`, `vBox [...]`.

The box layout algorithm uses these hints to allocate space:

1. First, render all `Fixed` children and deduct their sizes from the available space.
2. Then, divide the remaining space equally among `Greedy` children.

This two-pass approach ensures fixed-size widgets always get their required space while greedy widgets share the remainder.

### Multi-Panel Layout Example

```haskell
import Brick
import Brick.Widgets.Border (border, borderWithLabel, hBorder, vBorder)
import Brick.Widgets.Border.Style (unicode)
import Brick.Widgets.Center (center, hCenter)

-- | A three-panel layout: sidebar, main content, and a status bar.
drawUI :: AppState -> [Widget Name]
drawUI st = [ui]
  where
    ui = vBox
        [ topPanel
        , hBorder
        , statusBar st
        ]

    topPanel = hBox
        [ hLimit 25 (sidebar st)
        , vBorder
        , mainContent st
        ]

    sidebar st = borderWithLabel (str " Files ") $
        padAll 1 $
        vBox $ map (str . fileName) (st ^. fileList)

    mainContent st = borderWithLabel (str " Editor ") $
        padAll 1 $
        viewport EditorViewport Vertical $
        vBox $ map str (st ^. editorLines)

    statusBar st = hBox
        [ padLeftRight 1 $ str ("Line: " ++ show (st ^. cursorLine))
        , fill ' '
        , padLeftRight 1 $ str (st ^. statusMessage)
        ]
```

This produces a layout like:

```
+--- Files ---+|+--------- Editor ----------+
|              ||                            |
| main.hs     ||  module Main where         |
| lib.hs      ||                            |
| test.hs     ||  import Brick              |
|              ||  import qualified ...      |
+--------------||                            |
               |+----------------------------+
─────────────────────────────────────────────
 Line: 3                        Ready
```

The sidebar has a fixed width of 25 columns (`hLimit 25`). The main content area is greedy and takes the remaining space. The status bar uses `fill ' '` as a flexible spacer between the left and right items.

---

## Widget / Component System

### The Widget Type

```haskell
data Widget n = Widget
    { hSize  :: Size
    , vSize  :: Size
    , render :: RenderM n (Result n)
    }
```

A `Widget n` is a rendering instruction carrying its size policies and a monadic rendering function. The `n` parameter is the resource name type used to identify viewports, extents, and mouse targets.

### Result Type

Rendering a widget produces a `Result`:

```haskell
data Result n = Result
    { image              :: Graphics.Vty.Image
    , cursors            :: [CursorLocation n]
    , visibilityRequests :: [VisibilityRequest]
    , extents            :: [Extent n]
    , borders            :: BorderMap DynBorder
    }
```

The `image` field contains the Vty `Image` (character grid with attributes). The other fields carry metadata about cursor positions, scrolling hints, clickable regions, and border connection information.

### Built-In Widgets

| Widget / Module         | Description                                          |
| ----------------------- | ---------------------------------------------------- |
| `str s`                 | Render a `String` (single line)                      |
| `txt t`                 | Render `Text` (single line)                          |
| `strWrap s`             | Render a `String` with word wrapping                 |
| `txtWrap t`             | Render `Text` with word wrapping                     |
| `withAttr an w`         | Apply attribute name `an` to widget `w`              |
| `border w`              | Surround with a border                               |
| `borderWithLabel lbl w` | Border with a label widget in the top edge           |
| `hBorder`               | Horizontal line border                               |
| `vBorder`               | Vertical line border                                 |
| `table`                 | Table layout (`Brick.Widgets.Table`)                 |
| `list`                  | Scrollable, selectable list (`Brick.Widgets.List`)   |
| `dialog`                | Modal dialog with buttons (`Brick.Widgets.Dialog`)   |
| `progressBar`           | Progress bar (`Brick.Widgets.ProgressBar`)           |
| `edit` / `editor`       | Single/multi-line text editor (`Brick.Widgets.Edit`) |
| `fileBrowser`           | File/directory browser (`Brick.Widgets.FileBrowser`) |

### Custom Widgets

Custom widgets are created using the `Widget` constructor, providing size policies and a rendering function:

```haskell
-- | A widget that draws a horizontal rule of a given character.
horizontalRule :: Char -> Widget n
horizontalRule ch = Widget Greedy Fixed $ do
    ctx <- getContext
    let w = ctx ^. availWidthL
    render $ str (replicate w ch)

-- | A widget that shows text with a colored bullet point.
bulletItem :: AttrName -> String -> Widget n
bulletItem bulletAttr text =
    (withAttr bulletAttr (str "* ")) <+> strWrap text
```

The `getContext` function in `RenderM` provides the available width and height, the current attribute map, and the border style, enabling widgets to adapt to their layout context.

### Forms Library (Brick.Forms)

`Brick.Forms` provides a type-safe, validated form abstraction for structured input:

```haskell
data Form s e n

-- Constructing a form from field descriptors
mkForm :: UserInfo -> Form UserInfo e Name
mkForm =
    newForm [ editTextField (nameL) NameField (Just 1)
            , editShowableField (ageL) AgeField
            , editPasswordField (passwordL) PasswordField
            , radioField (handednessL)
                [ (LeftHanded,  LHField, "Left")
                , (RightHanded, RHField, "Right")
                , (Ambidextrous, AField,  "Ambidextrous")
                ]
            , checkboxField (ridesBikeL) BikeField "Do you ride a bike?"
            ]

-- In the event handler
appHandleEvent (VtyEvent e) = zoom formL $ handleFormEvent (VtyEvent e)

-- Accessing validated state
let info = formState (st ^. form)
```

Forms handle focus management, tab ordering, validation, and rendering automatically. The `formState` accessor returns the current validated state of the form at any time.

---

## Styling

### Attribute System

Brick's styling system is based on **attribute maps** (`AttrMap`) that associate semantic **attribute names** (`AttrName`) with visual **attributes** (`Attr`).

```haskell
-- Attr contains: foreground color, background color, style modifiers
data Attr = Attr
    { attrStyle   :: MaybeDefault Style
    , attrForeColor :: MaybeDefault Color
    , attrBackColor :: MaybeDefault Color
    , attrURL     :: Maybe String
    }
```

### Defining Attributes

```haskell
-- Attribute names use <> (Monoid) for hierarchy
baseAttr, headerAttr, selectedAttr, errorAttr :: AttrName
baseAttr     = attrName "base"
headerAttr   = attrName "header"
selectedAttr = attrName "list" <> attrName "selected"
errorAttr    = attrName "error"

-- Build the attribute map with a global default and named overrides
theAttrMap :: AttrMap
theAttrMap = attrMap
    (white `on` black)                -- global default: white on black
    [ (headerAttr,   fg cyan `withStyle` bold)
    , (selectedAttr, black `on` yellow)
    , (errorAttr,    fg red `withStyle` bold)
    , (listAttr,     fg white)
    ]
```

### Attribute Inheritance

Attribute names form a hierarchy via `<>`. When Brick looks up an attribute, it walks from the most specific name up to the global default, inheriting any properties (foreground, background, style) not explicitly set at the more specific level.

For example, if `listAttr` sets only the foreground color, then `selectedAttr` (which is `listAttr <> attrName "selected"`) inherits the background from `listAttr`'s resolution, which in turn inherits from the global default.

### Applying Attributes to Widgets

```haskell
drawUI :: AppState -> [Widget Name]
drawUI st =
    [ vBox
        [ withAttr headerAttr $ str "=== My Application ==="
        , str " "
        , renderItems (st ^. items)
        , str " "
        , withAttr errorAttr $ str (st ^. errorMessage)
        ]
    ]

renderItems :: [Item] -> Widget Name
renderItems items = vBox
    [ let attr = if selected then selectedAttr else listAttr
      in withAttr attr $ str (itemLabel item)
    | (i, item) <- zip [0..] items
    , let selected = i == selectedIndex
    ]
```

### Theme Support

Brick includes a theming system (`Brick.Themes`) that enables user-customizable attribute maps. Themes can be serialized to INI-format configuration files, allowing end users to restyle an application without recompilation.

---

## Event Handling

### BrickEvent Type

```haskell
data BrickEvent n e
    = VtyEvent Event          -- Keyboard, mouse, resize from Vty
    | AppEvent e              -- Custom application events
    | MouseDown n Button [Modifier] Location  -- Widget-level mouse press
    | MouseUp   n (Maybe Button) Location     -- Widget-level mouse release
```

- **`VtyEvent`** wraps the raw Vty `Event` type for keyboard input, terminal-level mouse events, and resize notifications.
- **`AppEvent e`** carries custom events of the application's chosen type `e`, delivered via a `BChan` (bounded channel).
- **`MouseDown`** / **`MouseUp`** are widget-level mouse events tagged with the resource name `n` of the widget that was clicked, enabling per-widget mouse handling.

### Event Handler Pattern

```haskell
appHandleEvent :: BrickEvent Name CustomEvent -> EventM Name AppState ()
appHandleEvent ev = case ev of
    -- Keyboard events
    VtyEvent (V.EvKey V.KEsc [])        -> halt
    VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
    VtyEvent (V.EvKey V.KUp [])         -> modify $ \s -> s & selectedIndex %~ max 0 . subtract 1
    VtyEvent (V.EvKey V.KDown [])       -> modify $ \s -> s & selectedIndex %~ min (length items - 1) . (+ 1)
    VtyEvent (V.EvKey V.KEnter [])      -> do
        st <- get
        liftIO $ performAction (st ^. selectedItem)

    -- Custom events from background threads
    AppEvent (DataLoaded newData)        -> modify $ \s -> s & dataField .~ newData
    AppEvent Tick                        -> modify $ \s -> s & counter %~ (+ 1)

    -- Widget-level mouse click
    MouseDown ListItem _ _ _            -> modify $ \s -> s & mouseClicked .~ True

    -- Delegate to sub-widget handlers
    VtyEvent e                          -> zoom editorL $ handleEditorEvent (VtyEvent e)

    _                                   -> return ()
```

### Key Patterns

- **`halt`** terminates the event loop and returns the final state to the caller.
- **`modify`** / **`put`** update the application state within `EventM`.
- **`zoom`** with a lens focuses the handler on a sub-component of the state, enabling delegation to widget-specific handlers like `handleEditorEvent` or `handleListEvent`.
- Pattern matching on `VtyEvent (V.EvKey ...)` is the standard way to handle keyboard input.

### Custom Events via BChan

```haskell
main :: IO ()
main = do
    chan <- newBChan 10  -- bounded channel, capacity 10

    -- Background thread producing custom events
    forkIO $ forever $ do
        writeBChan chan Tick
        threadDelay 1000000  -- 1 second

    let app = App { ... }
    initialState <- mkInitialState
    finalState <- customMainWithDefaultVty (Just chan) app initialState
    print finalState
```

The `BChan` (bounded channel) bridges background threads and the Brick event loop. Events written to the channel are delivered to `appHandleEvent` as `AppEvent` values, fully integrated with keyboard and mouse events.

---

## State Management

### Single State Value

Brick threads a single state value of type `s` through the entire application. This is the sole source of truth -- `appDraw` renders from it, `appHandleEvent` modifies it, and the final state is returned when the event loop terminates.

```haskell
data AppState = AppState
    { _items         :: [Item]
    , _selectedIndex :: Int
    , _editor        :: Editor Text Name
    , _statusMsg     :: String
    , _counter       :: Int
    }

makeLenses ''AppState
```

### EventM and State Updates

The `EventM n s` monad provides `MonadState s`, so state updates use standard `mtl` patterns:

```haskell
-- Direct update
modify $ \s -> s { _counter = _counter s + 1 }

-- Lens-based (recommended for complex state)
counter %= (+ 1)
selectedIndex .= 0
editor %= applyEdit clearContents

-- Zoom into sub-state for delegated handling
zoom editor $ handleEditorEvent e
```

### Immutability by Default

All state updates produce new values. Haskell's immutability guarantees that the rendering function always sees a consistent snapshot of the state. There is no possibility of partial updates or race conditions between rendering and event handling.

### No Reactive System

Brick does not have a reactive or observable system. There are no signals, subscriptions, or automatic propagation of changes. State changes are explicit: the event handler modifies the state, and the next render cycle uses the updated value. This simplicity is a deliberate design choice -- the entire state flow is visible in the event handler.

### External Events via BChan

For integrating with the outside world (network, timers, file watchers), the `BChan` (bounded channel) pattern is used. Background threads write events to the channel, and Brick delivers them as `AppEvent` values in the event handler, maintaining the single-threaded state update model.

---

## Extensibility & Ecosystem

### Extension Libraries

| Package               | Description                                     |
| --------------------- | ----------------------------------------------- |
| **brick-skylighting** | Syntax highlighting via the Skylighting library |
| **brick-tabular**     | Enhanced table widgets                          |
| **brick-filetree**    | Directory tree browser widget                   |
| **brick-panes**       | Overlay/pane management library                 |
| **brick-calendar**    | Calendar widget                                 |

### Built-In Extension Points

- **Custom widgets** -- the `Widget` constructor is public; any function producing `Widget n` is a first-class citizen in layouts.
- **Forms library** -- `Brick.Forms` provides high-level form construction with validation, built into the core package.
- **Themes** -- `Brick.Themes` enables user-customizable styling via INI configuration files.
- **File browser** -- `Brick.Widgets.FileBrowser` provides a ready-made file selection widget.

### Community

Brick has an active Haskell community with:

- GitHub Discussions for Q&A
- A `brick-users` Google Group / mailing list
- Over 50 known projects built with Brick (games, mail clients, accounting tools, developer utilities)
- 88+ contributors on GitHub
- 30+ demo programs in the repository

---

## Strengths

- **Pure functional elegance** -- rendering is a pure function from state to widgets, with no side effects. This makes the UI trivially testable and easy to reason about.
- **Excellent combinator-based API** -- the layout combinators (`hBox`, `vBox`, `padLeft`, `hLimit`, `center`, `viewport`) compose cleanly and are highly expressive for a small API surface.
- **Strong type safety** -- the `App s e n` type parameterization catches many errors at compile time. Resource names, custom events, and state are all statically typed.
- **Comprehensive documentation** -- the user guide (`docs/guide.rst`) is one of the best pieces of library documentation in the Haskell ecosystem. The 30+ demo programs serve as a living reference.
- **Good default layouts** -- the `Greedy` / `Fixed` sizing model produces sensible layouts without manual calculation. The box layout algorithm automatically distributes space.
- **Forms library is excellent** -- `Brick.Forms` provides type-safe, validated forms with automatic focus management, a rare feature in TUI libraries at any level.
- **Very composable** -- widgets, attributes, event handlers, and layout combinators all compose orthogonally. Complex UIs are built by snapping together small, well-understood pieces.
- **Mature and stable** -- active development since ~2015, with a clean versioning history and thoughtful API evolution (e.g., the migration from pure update functions to `EventM`).
- **Automatic border joining** -- adjacent border widgets automatically connect using appropriate intersection characters, a surprisingly difficult detail that Brick handles transparently.

---

## Weaknesses & Limitations

- **Haskell learning curve** -- Brick requires familiarity with Haskell, lenses, monad transformers, and type-level programming. The barrier to entry is high for developers outside the Haskell ecosystem.
- **Limited to Unix-like platforms historically** -- while Brick 2.0+ supports Windows via `vty-crossplatform`, the Unix backend (using terminfo) remains the primary and most battle-tested path.
- **Performance overhead of immutable data structures** -- every state update allocates a new state value. For applications with very large state (e.g., large text buffers), this can introduce GC pressure.
- **Debugging difficulty in pure functional style** -- tracing rendering issues through combinator composition and lazy evaluation can be challenging. There is no "inspect element" equivalent.
- **Smaller widget ecosystem than some alternatives** -- compared to web-based TUI frameworks (Textual, Ink) or the Charm ecosystem (Bubble Tea + Bubbles + Lip Gloss), the number of pre-built widgets and community components is more limited.
- **Less suitable for high-frequency updates** -- applications requiring very frequent re-renders (>30fps animations, real-time data visualization) may find the full re-render model and Haskell runtime overhead limiting.
- **No built-in async/reactive primitives** -- unlike frameworks with reactive state management, all async integration requires manual `BChan` plumbing and explicit event handling.
- **Lens dependency** -- effective use of Brick's state management strongly encourages (practically requires) the lens pattern, adding another conceptual layer.

---

## Lessons for D / Sparkles

### Widget Combinators to UFCS Chains

Brick's combinator composition:

```haskell
borderWithLabel (str " Files ") $ padAll 1 $ hLimit 25 $ vBox items
```

Maps naturally to D's UFCS chains:

```d
items
    .vBox
    .hLimit(25)
    .padAll(1)
    .borderWithLabel(" Files ")
```

D's UFCS provides the same left-to-right readability without Haskell's right-to-left `$` application, and with zero runtime overhead when the combinators are `@nogc` template functions returning widget structs by value.

### AttrMap to Compile-Time D Map

Brick's `AttrMap` with hierarchical attribute resolution could be implemented as a compile-time associative array in D using CTFE:

```d
enum Attr baseTheme = [
    "header":   Attr(fg: Color.cyan, style: Style.bold),
    "selected": Attr(fg: Color.black, bg: Color.yellow),
    "error":    Attr(fg: Color.red, style: Style.bold),
];
```

D's `enum` AA evaluated at compile time gives zero-runtime-cost theme definitions. Runtime theme loading could use the same `Attr[string]` type with runtime initialization.

### Size Type (Greedy / Fixed) to D Enum or DbI Trait

Brick's `Size` type:

```haskell
data Size = Fixed | Greedy
```

In D, this could be either a simple enum:

```d
enum SizePolicy { fixed, greedy }
```

Or a Design by Introspection capability trait, where widgets that expose `enum hPolicy = SizePolicy.greedy` are detected at compile time and handled differently by the layout algorithm:

```d
template isGreedyH(W) {
    enum isGreedyH = __traits(hasMember, W, "hPolicy")
        && W.hPolicy == SizePolicy.greedy;
}
```

### Named Viewports

Brick's viewport pattern -- named scrollable regions that persist scroll state across renders -- is directly useful for D. A D implementation could use string-based or enum-based names with a global viewport state registry:

```d
content
    .vBox
    .viewport("editor", ViewportType.vertical)
    .vLimit(20)
```

### Forms from Struct Introspection

Brick's `Form s e n` requires manual field-by-field form construction. D's compile-time introspection could auto-generate forms from struct definitions:

```d
struct UserInfo {
    @Label("Name") string name;
    @Label("Age") @Min(18) int age;
    @Label("Password") @Password string password;
    @Label("Handedness") Handedness handedness;
    @Label("Rides bike") bool ridesBike;
}

// Auto-generated form with validation, focus, and rendering
auto form = autoForm!UserInfo(initialValue);
```

D's `__traits(allMembers, ...)` and UDAs enable generating form fields, validation, and rendering at compile time with zero runtime reflection cost -- something Haskell achieves only through Template Haskell or GHC Generics.

### Pure State Transitions

Brick's `EventM` monad enforces structured state updates. D's `pure` attribute provides a similar guarantee:

```d
@safe pure nothrow
AppState handleEvent(in AppState state, in Event event) {
    // Guaranteed no global state mutation, no IO
    return state.with!"selectedIndex"(state.selectedIndex + 1);
}
```

D's `pure` functions cannot access mutable global state, providing a compile-time guarantee analogous to Haskell's separation of pure rendering from IO.

### Template-Based Widget Composition

Brick's type-safe widget composition translates to D's template system for zero-cost abstraction:

```d
auto ui = hBox(
    sidebar.hLimit(25),
    vBorder(),
    mainContent,
).border;
```

With D templates, the layout tree can be resolved at compile time. Widget types carry their size policies as template parameters, enabling the layout algorithm to specialize at compile time:

```d
struct HBox(Widgets...) {
    enum hPolicy = allSatisfy!(isGreedyH, Widgets) ? SizePolicy.greedy : SizePolicy.fixed;
    // ...
}
```

---

## References

- **Repository**: <https://github.com/jtdaugherty/brick>
- **User Guide**: <https://github.com/jtdaugherty/brick/blob/master/docs/guide.rst>
- **Hackage (API docs)**: <https://hackage.haskell.org/package/brick>
- **FAQ**: <https://github.com/jtdaugherty/brick/blob/master/docs/FAQ.md>
- **Demo Programs**: <https://github.com/jtdaugherty/brick/tree/master/programs>
- **Vty (terminal backend)**: <https://github.com/jtdaugherty/vty>
- **Vty on Hackage**: <https://hackage.haskell.org/package/vty>
- **brick-users mailing list**: <https://groups.google.com/group/brick-users>
- **GitHub Discussions**: <https://github.com/jtdaugherty/brick/discussions>
- **Changelog**: <https://github.com/jtdaugherty/brick/blob/master/CHANGELOG.md>
- **Jonathan Daugherty's talk -- "Building Terminal User Interfaces in Haskell"**: Presented at various Haskell meetups; search for conference recordings.
- **Samuel Tay -- "Brick Tutorial"**: <https://samtay.github.io/posts/introduction-to-brick>
