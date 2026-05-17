# xmonad (Haskell)

A dynamically tiling X11 window manager written and configured in Haskell. Although
xmonad targets full desktop windows rather than terminal cells, its **layout
architecture** is one of the cleanest published examples of a typeclass-as-strategy
pattern for arranging rectangles. The same ideas -- layouts as first-class values,
combinators that compose them, messages that mutate them -- transfer naturally to any
extensible UI-layout system, including a terminal renderer like Sparkles.

| Field            | Value                                                              |
| ---------------- | ------------------------------------------------------------------ |
| Language         | Haskell (GHC)                                                      |
| License          | BSD-3-Clause                                                       |
| Repository       | <https://github.com/xmonad/xmonad>                                 |
| Contrib          | <https://github.com/xmonad/xmonad-contrib>                         |
| Documentation    | <https://xmonad.org/>                                              |
| Version snapshot | xmonad 0.18.1; xmonad-contrib 0.18.2 (March 2026)                  |
| First Release    | March 2007                                                         |
| Core size        | ~2,000 lines of Haskell (StackSet + Layout + main loop)            |
| Authors          | Don Stewart, Spencer Janssen, Jason Creighton (original 2007 team) |

---

## Overview

### What It Is

xmonad is a [dynamically tiling][xmonad-home] X11 window manager. "Dynamically tiling"
means it does not require the user to pre-specify a layout; instead it automatically
arranges windows in a workspace according to a _layout algorithm_ (typically a master
pane plus a column of stack windows), and the user reshapes the layout by spawning
new windows, resizing the master area, or switching to an entirely different layout
with a keystroke. Floating windows are supported as an opt-in, second-class citizen.

What makes xmonad interesting outside its application domain is that **every layout
algorithm is a Haskell value of a known typeclass**, and combinators (`Mirror`,
`|||`, `Choose`, layout modifiers like gaps and smart borders) compose those values
into more elaborate layouts the way `std.algorithm` composes ranges. The set of
available layouts is open and extensible by third parties without forking the core,
and the open-set is enforced by the typeclass system rather than by a configuration
language.

### Design Philosophy

The xmonad README and home page emphasise four properties:

1. **Minimalism.** No titlebars, no taskbar, no icon dock. The window manager's job
   is to arrange windows; everything else is delegated to dedicated programs
   (xmobar, dzen2, trayer, ...).
2. **Stability.** The core uses Haskell's type system aggressively. The central
   data structure, `StackSet`, is a purely functional zipper over workspaces and
   windows; its invariants are tested with QuickCheck. Crash-resistance was a major
   marketing point in xmonad's early years.
3. **Efficiency.** The tiling core is around 500 lines of Haskell. The full
   distribution (StackSet + Layout + main loop + X11 plumbing) is around 2,000.
4. **Keyboard-driven extensibility.** All user configuration is a Haskell program
   (`xmonad.hs`) that imports the library and overrides defaults. Reconfiguration
   compiles a new binary and execs it.

The phrase often associated with xmonad is "exemplary Haskell" -- the project was
publicly held up by the Haskell community as proof that real systems software could
be built in a pure functional language with negligible overhead.

### History

- **2007.** Don Stewart, Spencer Janssen, and Jason Creighton announce xmonad as a
  reimplementation, in Haskell, of the ideas behind `dwm` (Anselm R. Garbe's
  C-based suckless tiling window manager). Initial release 0.1 lands in March.
- **2007--2008.** QuickCheck properties for `StackSet`. The published paper
  "xmonad in Coq" by Spencer Janssen, Andy Gill, and others demonstrates a
  mechanically verified port of the core data structure.
- **2009 onwards.** The `xmonad-contrib` package becomes the home for dozens of
  third-party layouts, layout modifiers, key bindings, and prompts. Today
  `xmonad-contrib` is roughly an order of magnitude larger than `xmonad` proper.
- **2017--2024.** Long maintenance era under new maintainers (Brent Yorgey, Tony
  Zorman, slotThe). Core API is mostly frozen; most innovation happens in contrib.
- **0.18.x (2024--2026).** GHC 9.x compatibility, Wayland-adjacent discussions,
  small contrib additions.

---

## Layout Model

### The `LayoutClass` Typeclass

At the centre of xmonad's layout architecture is the [`LayoutClass`][xmonad-layout]
typeclass, defined (slightly abridged) in `XMonad.Core`:

```haskell
class (Show (layout a), Typeable layout) => LayoutClass layout a where

    -- | Compute the actual layout: given the screen rectangle and the
    --   non-empty 'Stack' of visible windows, return the per-window
    --   rectangles plus optionally a new layout state.
    runLayout :: Workspace WorkspaceId (layout a) a
              -> Rectangle
              -> X ([(a, Rectangle)], Maybe (layout a))
    runLayout (Workspace _ l ms) r = maybe (emptyLayout l r)
                                           (doLayout l r) ms

    -- | A simpler variant of runLayout for the common case of a
    --   non-empty stack. Default implementation defers to pureLayout.
    doLayout :: layout a
             -> Rectangle
             -> Stack a
             -> X ([(a, Rectangle)], Maybe (layout a))
    doLayout l r s = return (pureLayout l r s, Nothing)

    -- | Pure layout function for layouts that have no state and need
    --   no access to the X monad.
    pureLayout :: layout a -> Rectangle -> Stack a -> [(a, Rectangle)]
    pureLayout _ r s = [(focus s, r)]

    -- | What to do when the stack is empty (default: nothing).
    emptyLayout :: layout a -> Rectangle
                -> X ([(a, Rectangle)], Maybe (layout a))
    emptyLayout _ _ = return ([], Nothing)

    -- | React to a 'Message' (resize, layout change, ...). Returning
    --   Nothing means "no change"; Just l' replaces the layout state.
    handleMessage :: layout a -> SomeMessage -> X (Maybe (layout a))
    handleMessage l = return . pureMessage l

    -- | Pure version of handleMessage for stateless reactions.
    pureMessage :: layout a -> SomeMessage -> Maybe (layout a)
    pureMessage _ _ = Nothing

    -- | A human-readable description shown in status bars.
    description :: layout a -> String
    description = show
```

The signature `doLayout :: l a -> Rectangle -> Stack a -> X ([(a, Rectangle)], Maybe (l a))`
captures the entire problem statement in one type:

- **Input**: the layout's own state `l a`, the screen rectangle `Rectangle`, and
  a non-empty zipper `Stack a` of windows with a distinguished focus.
- **Output**: a list of `(window, rectangle)` pairs (the assignment) and
  optionally a new layout state (e.g. an updated master/slave ratio).
- **Effects**: the `X` monad (a reader/state monad over `XConf`/`XState`)
  allows IO when needed; most layouts never use it and default to `pureLayout`.

This is precisely a strategy interface. Each layout chooses how clever it wants to
be: stateless tilings (`Full`, `Tall`) define `pureLayout`; stateful ones
(`ResizableTall`, `MosaicAlt`) override `doLayout` and emit a `Just l'` when their
internal state changes; layouts that need to query X (e.g. fetch a window title for
a tab bar) reach for `X` directly.

### The `Message` System

Layouts react to user input via the [`Message`][xmonad-core] system, an open-set
extension mechanism built on `Data.Typeable`:

```haskell
class Typeable a => Message a

data SomeMessage = forall a. Message a => SomeMessage a

fromMessage :: Message m => SomeMessage -> Maybe m
fromMessage (SomeMessage m) = cast m

-- Built-in messages
data ChangeLayout = NextLayout | FirstLayout deriving (Eq, Show, Typeable)
data Resize       = Shrink | Expand          deriving (Eq, Show, Typeable)
data IncMasterN   = IncMasterN !Int          deriving (Eq, Show, Typeable)
instance Message ChangeLayout
instance Message Resize
instance Message IncMasterN
```

A key binding like `mod-h` sends `SomeMessage Shrink` to the current layout via
`sendMessage`. The layout's `handleMessage` implementation pattern-matches on
`fromMessage msg :: Maybe Resize` and decides what to do; if the message is not
relevant it returns `Nothing` and the framework leaves the layout untouched. This
is essentially Smalltalk's `doesNotUnderstand:` but type-safe: any value of any
type can be a message as long as it implements `Message`, and the layout only
catches the messages whose types it cares about.

### Core Layouts

`XMonad.Layout` defines the small set of layouts shipped with the core:

```haskell
-- | Master area on the left, stack of remaining windows on the right.
data Tall a = Tall { tallNMaster      :: !Int       -- windows in master pane
                   , tallRatioIncrement :: !Rational -- resize step
                   , tallRatio        :: !Rational  -- master area fraction
                   } deriving (Show, Read)

instance LayoutClass Tall a where
    pureLayout (Tall nmaster _ frac) r s = zip ws rs
        where ws = W.integrate s
              rs = tile frac r nmaster (length ws)

    pureMessage (Tall nmaster delta frac) m =
        msum [fmap resize     (fromMessage m)
             ,fmap incmastern (fromMessage m)]
        where resize Shrink             = Tall nmaster delta (max 0 $ frac-delta)
              resize Expand             = Tall nmaster delta (min 1 $ frac+delta)
              incmastern (IncMasterN d) = Tall (max 0 (nmaster+d)) delta frac

    description _ = "Tall"

-- | Render a single window fullscreen.
data Full a = Full deriving (Show, Read)
instance LayoutClass Full a

-- | Rotate any layout 90 degrees.
data Mirror l a = Mirror (l a) deriving (Show, Read)

instance LayoutClass l a => LayoutClass (Mirror l) a where
    runLayout (W.Workspace i (Mirror l) ms) r =
        (fmap (map $ second mirrorRect) *** fmap Mirror)
        <$> runLayout (W.Workspace i l ms) (mirrorRect r)
    handleMessage (Mirror l) = fmap (fmap Mirror) . handleMessage l
    description (Mirror l) = "Mirror " ++ description l
  where
    mirrorRect (Rectangle rx ry rw rh) = Rectangle ry rx rh rw
```

Note how `Mirror` is a true _combinator_: it takes any `LayoutClass l a` and produces
another `LayoutClass (Mirror l) a`. It does not need to know what `l` does -- it
swaps the input rectangle into "mirrored" coordinates, defers to `l`, and swaps the
output back. This pattern -- "transform the input, delegate, transform the output" --
is repeated dozens of times across xmonad-contrib's layout modifiers (`Gaps`,
`Spacing`, `SmartBorder`, `Reflect`, `NoBorders`, `Magnifier`, ...).

### The `|||` Combinator

The most commonly used layout combinator is [`Choose`][xmonad-layout], pronounced
"or" and written `|||`:

```haskell
data Choose l r a = Choose CLR (l a) (r a) deriving (Show, Read)
data CLR = CL | CR  -- which side is currently active

(|||) :: l a -> r a -> Choose l r a
(|||) = Choose CL
infixr 5 |||

instance (LayoutClass l a, LayoutClass r a) => LayoutClass (Choose l r) a where
    runLayout (W.Workspace i (Choose CL l r) ms) rect =
        fmap (fmap (flip (Choose CL) r)) <$> runLayout (W.Workspace i l ms) rect
    runLayout (W.Workspace i (Choose CR l r) ms) rect =
        fmap (fmap (Choose CR l)) <$> runLayout (W.Workspace i r ms) rect

    handleMessage c m | Just NextLayout <- fromMessage m = ...
                     | otherwise                         = ...
    description (Choose CL l _) = description l
    description (Choose CR _ r) = description r
```

Because `|||` is right-associative with low precedence, this just works:

```haskell
myLayout = Tall 1 (3/100) (1/2)
       ||| Mirror (Tall 1 (3/100) (1/2))
       ||| Full
       ||| ThreeColMid 1 (3/100) (1/2)
```

Each `|||` builds a `Choose`-tree; sending `NextLayout` walks the tree, flipping
the `CLR` tag from `CL` to `CR` at the appropriate level. The result is that
`myLayout` is, statically, a single Haskell value of some concrete type
`Choose Tall (Choose (Mirror Tall) (Choose Full ThreeColMid))`, with the union of
all message-handling behaviour of its constituents.

`XMonad.Layout.LayoutCombinators` extends this with more specialised
combinators ([`xmonad-layout-combinators`][xmonad-layout-combinators]):

- `|||` itself (re-exported, with a non-deprecated implementation that supports
  `JumpToLayout`).
- `JumpToLayout name` -- a `Message` that jumps to the _named_ layout (matched
  against `description`), without cycling through intermediates.
- A family of geometric splitters: `*||*` (one-half left), `**||*` (two-thirds
  left), `*//*` (one-half top), `**//*` (two-thirds top), etc. -- these split
  the screen at a fixed ratio and run a different sub-layout in each half.

### `xmonad-contrib` Layout Catalogue

The contrib package ships dozens of additional layouts. A representative sample:

| Module                               | Layout          | Sketch                                       |
| ------------------------------------ | --------------- | -------------------------------------------- |
| `XMonad.Layout.ThreeColumns`         | `ThreeColMid`   | Master in centre, stack columns left + right |
| `XMonad.Layout.Grid`                 | `Grid`          | Regular `sqrt n` grid                        |
| `XMonad.Layout.Spiral`               | `spiral`        | Fibonacci spiral subdivision                 |
| `XMonad.Layout.Circle`               | `Circle`        | Master in centre, others on a circle         |
| `XMonad.Layout.Roledex`              | `Roledex`       | Stack of cascading windows                   |
| `XMonad.Layout.Accordion`            | `Accordion`     | Focused window expanded, others collapsed    |
| `XMonad.Layout.Tabbed`               | `tabbed`        | One window visible, tab bar at top           |
| `XMonad.Layout.MosaicAlt`            | `MosaicAlt`     | User-adjustable mosaic of sizes              |
| `XMonad.Layout.ResizableTile`        | `ResizableTall` | Tall with per-stack-row resize               |
| `XMonad.Layout.BinarySpacePartition` | `emptyBSP`      | Tree of recursive vertical/horizontal splits |
| `XMonad.Layout.IM`                   | `withIM`        | Reserve a strip for an IM roster             |

Each of them is a `LayoutClass` instance. Each one composes with `Mirror`, `|||`,
and the layout modifiers without modification.

### Layout Modifiers (`LayoutModifier`)

A second layer of extensibility comes from `XMonad.Layout.LayoutModifier`:

```haskell
class (Show (m a), Read (m a)) => LayoutModifier m a where
    modifyLayout    :: m a -> Workspace WorkspaceId (l a) a -> Rectangle
                    -> X ([(a, Rectangle)], Maybe (l a))
    handleMess      :: m a -> SomeMessage -> X (Maybe (m a))
    pureMess        :: m a -> SomeMessage -> Maybe (m a)
    redoLayout      :: m a -> Rectangle -> Maybe (Stack a)
                    -> [(a, Rectangle)]
                    -> X ([(a, Rectangle)], Maybe (m a))
    pureModifier    :: m a -> Rectangle -> Maybe (Stack a)
                    -> [(a, Rectangle)]
                    -> ([(a, Rectangle)], Maybe (m a))
    modifierDescription :: m a -> String

data ModifiedLayout m l a = ModifiedLayout (m a) (l a) deriving (Show, Read)

instance (LayoutModifier m a, LayoutClass l a) =>
         LayoutClass (ModifiedLayout m l) a where ...
```

A `LayoutModifier` is a "small" version of a layout that only adjusts the output of
some inner layout. `Spacing` (per-window gaps), `Gaps` (screen-edge gaps),
`SmartBorders` (suppress borders when only one window), `NoBorders`,
`WindowNavigation` (record adjacency for directional focus), `Renamed` (rename for
the status bar), and many others are implemented this way. The same modifier wraps
arbitrarily many layouts:

```haskell
import XMonad.Layout.Spacing  (spacingRaw, Border(..))
import XMonad.Layout.NoBorders (smartBorders)

myLayout = smartBorders
         $ spacingRaw False (Border 4 4 4 4) True (Border 4 4 4 4) True
         $ Tall 1 (3/100) (1/2) ||| Full ||| ThreeColMid 1 (3/100) (1/2)
```

The Haskell type checker statically _proves_ that the composed layout still
implements `LayoutClass`. There is no possibility of dispatching a message that
some part of the stack cannot handle: the typeclass instances for `ModifiedLayout`,
`Mirror`, and `Choose` collectively delegate message handling along the same
structure as `runLayout`.

### `StackSet`: The Pure Workspace State

xmonad's other contribution to the design space is `Data.StackSet`, the pure data
structure that holds the workspaces, screens, and focus state:

```haskell
data StackSet i l a sid sd = StackSet
    { current  :: !(Screen i l a sid sd)   -- focused screen
    , visible  :: [Screen i l a sid sd]    -- non-focused but mapped
    , hidden   :: [Workspace i l a]        -- non-mapped workspaces
    , floating :: Map a RationalRect       -- floating window positions
    }

data Screen    i l a sid sd = Screen { workspace :: !(Workspace i l a), ... }
data Workspace i l a        = Workspace { tag :: !i, layout :: l, stack :: Maybe (Stack a) }
data Stack a                = Stack { focus :: !a, up :: [a], down :: [a] }
```

A `Stack a` is a _zipper_: the focused element plus the lists of elements above
and below it. All workspace operations (`focusUp`, `focusDown`, `swapMaster`,
`shiftWin`, ...) are pure functions on `StackSet`, exhaustively tested with
QuickCheck properties (e.g. "after focus up then focus down, the set is
unchanged"). Layouts live _inside_ a `Workspace`, parameterised on the type `l`,
so each workspace can have its own layout state independently.

### Putting It Together: An Example Configuration

A representative `xmonad.hs` showing layouts, combinators, and modifiers:

```haskell
import XMonad
import XMonad.Layout.NoBorders          (smartBorders)
import XMonad.Layout.Spacing            (spacingRaw, Border(..))
import XMonad.Layout.ThreeColumns       (ThreeCol(..))
import XMonad.Layout.Tabbed             (tabbed, shrinkText, def)
import XMonad.Layout.LayoutCombinators  ((|||), JumpToLayout(..))
import XMonad.Layout.Renamed            (renamed, Rename(..))
import XMonad.Util.EZConfig             (additionalKeysP)

myLayout = smartBorders
         . spacingRaw True (Border 0 8 8 8) True (Border 8 8 8 8) True
         $ renamed [Replace "tall"]  (Tall 1 (3/100) (1/2))
       ||| renamed [Replace "wide"]  (Mirror (Tall 1 (3/100) (1/2)))
       ||| renamed [Replace "3col"]  (ThreeColMid 1 (3/100) (1/2))
       ||| renamed [Replace "full"]  Full
       ||| renamed [Replace "tabs"]  (tabbed shrinkText def)

main = xmonad $ def
    { layoutHook = myLayout
    , terminal   = "alacritty"
    } `additionalKeysP`
    [ ("M-S-f", sendMessage $ JumpToLayout "full")
    , ("M-S-t", sendMessage $ JumpToLayout "tall")
    , ("M-S-w", sendMessage $ JumpToLayout "wide")
    ]
```

The `myLayout` value is, statically, a single layout of some elaborate Haskell
type. Adding a new layout means importing a module and inserting another `|||`.
Adding a new _kind_ of modifier (e.g. one that paints debug rectangles) means
writing a `LayoutModifier` instance -- no patches to `xmonad-core`, no
plugin-loader, no configuration DSL.

---

## Strengths and Weaknesses

### Strengths

- **Layouts are first-class values.** A layout is a Haskell expression that can
  be named, passed around, and combined like any other value. There is no second
  language (configuration, DSL, JSON schema) interposed between the user and
  the layout algorithm.
- **Combinators compose cleanly.** `Mirror`, `|||`, and the `LayoutModifier`
  framework allow non-trivial compositions (`smartBorders $ spacing 4 $
Tall ||| Full`) without any layout knowing about the others. The typeclass
  obligation is the only contract.
- **Type-safe open extensibility.** The `Message`/`SomeMessage` system lets
  layouts declare arbitrary new commands without coordinating with the core. A
  layout that does not understand a message returns `Nothing`; one that does
  pattern-matches via `fromMessage`. This is open in the
  ["expression problem"][expr-problem] sense: both new layouts and new messages
  can be added without modifying existing code.
- **Pure functional core.** `StackSet` and `pureLayout`/`pureMessage` are total
  functions over immutable data. QuickCheck-tested invariants give the project a
  reputation for stability that few window managers can match.
- **Tiny core.** ~500 lines for the tiling logic and ~2,000 lines for the whole
  WM. A reader can grasp the entire data model in an afternoon.
- **Configuration is a real program.** A user's `xmonad.hs` is recompiled and
  re-exec'd on change. The configuration has access to the full Haskell language
  and the full xmonad library; there is no expressivity ceiling.

### Weaknesses

- **Configuration learning curve is steep for non-Haskell users.** Editing
  `xmonad.hs` requires reading Haskell type errors. Newcomers routinely report
  that the type signatures in `XMonad.Layout.*` modules are intimidating, even
  though the _usage_ is usually one line. The community has partly mitigated
  this with `XMonad.Util.EZConfig` (string-based key specs) and quickstart
  templates, but the bar remains higher than i3's INI-like config.
- **GHC dependency.** Reconfiguring xmonad recompiles a fresh binary. On systems
  without GHC pre-installed, this is a non-trivial setup cost; on slow hardware
  the rebuild takes seconds.
- **X11-only.** xmonad targets the X protocol. There is no native Wayland
  port; users who want a Wayland tiling compositor look at `sway`, `river`,
  `niri`, or `Hyprland`. The xmonad-on-Wayland question has been periodically
  discussed but no production implementation exists.
- **The type system can rebel.** Composing many `LayoutModifier`s yields
  exotic types like `ModifiedLayout SmartBorder (ModifiedLayout Spacing
(Choose (Mirror Tall) (Choose Full (ModifiedLayout WindowNavigation
ThreeCol))))`. Most users never look at these types, but the moment a
  `JumpToLayout` message or a function signature needs to mention the layout
  type, GHC's error messages become a learning opportunity.
- **No mouse-first workflow.** xmonad expects keyboard-driven navigation.
  Floating windows can be dragged, but the tiling story is keyboard-only.
- **Layout state is opaque to the rest of the system.** Because layout state is
  hidden inside `l a`, status bars that want to display "current master ratio"
  or "BSP tree shape" have to define a custom `Message` and have the layout
  publish state through it.

### Lessons for Sparkles

xmonad is _not_ a TUI library, but for a layout subsystem in a CLI/TUI toolkit a
few patterns are directly applicable:

- **Layout-as-type / strategy-as-value.** A D `interface Layout` or
  Design-by-Introspection trait `isLayout!T` enforcing
  `Rect[] doLayout(Rect screen, Window[] windows)` maps onto `LayoutClass`
  almost mechanically. Combinators like a `Mirror!Layout` wrapping any inner
  layout, or a `Choose!(L, R)` selecting between two, can be implemented as
  templated structs that delegate at compile time without virtual dispatch.
- **Open-set messages.** The `SomeMessage`/`fromMessage` pattern can be realised
  in D with `std.variant.Variant`, with a typeclass-style introspection check
  ("does this layout's `handleMessage` accept a `Resize`?"). For a
  more zero-cost variant, a CTFE-built dispatch table keyed on `TypeInfo`
  achieves the same flexibility without `Variant`'s allocations.
- **Pure layout functions.** xmonad's `pureLayout :: l a -> Rect -> Stack a ->
[(a, Rect)]` is a `@safe pure nothrow @nogc` function in D terms: takes
  layout state and screen, returns a finite list of placed rectangles. Sparkles
  could declare a `pureLayout` primitive of this exact shape and require
  layouts that opt into it.
- **Composable wrappers (`LayoutModifier`).** A "modifier" pattern -- a struct
  that wraps another layout and post-processes its output -- maps onto D
  template wrappers very directly:

  ```d
  struct Spacing(Inner)
  if (isLayout!Inner)
  {
      Inner inner;
      int padding;

      Rect[] doLayout(in Rect screen, in Window[] ws) {
          auto inset = screen.inset(padding);
          auto rs = inner.doLayout(inset, ws);
          foreach (ref r; rs) r = r.inset(padding);
          return rs;
      }
  }
  ```

  The compile-time wiring is identical to xmonad's `ModifiedLayout`.

For comparison with a _configuration-language_ approach to the same problem,
see [i3-sway.md](./i3-sway.md): i3/Sway expresses layout choices through a
small INI-flavoured DSL, but the set of available layouts is closed and the
extension story is "fork i3 or write an IPC client". xmonad's layouts are open
because they are values of an open typeclass; i3's are closed because they are
keywords in a parser.

### Concrete D Sketch

A first-cut translation of `LayoutClass` into idiomatic D, suitable for a
hypothetical `sparkles.core_cli.layout` module:

```d
module sparkles.core_cli.layout;

@safe pure nothrow:

/// Capability trait: any T is a Layout if it supplies the three primitives.
enum isLayout(T) = is(typeof((T t, Rect r, Pane[] ps) {
    Pane[] placed = t.doLayout(r, ps);
    static assert(is(typeof(placed) == Pane[]));
}));

/// Optional capability: a layout that reacts to messages.
enum handlesMessage(T, M) = is(typeof((T t, M m) {
    auto next = t.handleMessage(m); // returns T (new state) or void
}));

struct Rect { int x, y, w, h; }
struct Pane { uint id; Rect rect; }

/// The canonical xmonad-Tall analogue.
struct Tall {
    int nMaster   = 1;
    float ratio   = 0.5f;
    float delta   = 0.03f;

    Pane[] doLayout(in Rect r, Pane[] ps) const {
        if (ps.length == 0) return ps;
        // master pane fills `ratio * r.w`; remaining stack split vertically.
        // (Body elided.)
        return ps;
    }

    Tall handleMessage(Resize m) const {
        final switch (m) with (Resize) {
            case shrink: return Tall(nMaster, ratio - delta, delta);
            case expand: return Tall(nMaster, ratio + delta, delta);
        }
    }
}

enum Resize { shrink, expand }

/// `Mirror` works for any Layout. Compile-time delegation: zero virtual cost.
struct Mirror(Inner) if (isLayout!Inner)
{
    Inner inner;
    Pane[] doLayout(in Rect r, Pane[] ps) {
        auto mirrored = Rect(r.y, r.x, r.h, r.w);
        auto out_ = inner.doLayout(mirrored, ps);
        foreach (ref p; out_)
            p.rect = Rect(p.rect.y, p.rect.x, p.rect.h, p.rect.w);
        return out_;
    }
}

/// `Choose!(L, R)` is `|||`: cycle between two layouts at compile time.
struct Choose(L, R) if (isLayout!L && isLayout!R)
{
    L left;
    R right;
    bool useLeft = true;

    Pane[] doLayout(in Rect r, Pane[] ps) {
        return useLeft ? left.doLayout(r, ps)
                       : right.doLayout(r, ps);
    }
}
```

Note how `Mirror` and `Choose` are generic over their inner layouts: D's
template system gives the same compile-time guarantee as Haskell's type-class
constraint that the inner type is a layout. Sending a message to a
`Choose!(Mirror!Tall, Full)` works without virtual dispatch -- the compiler
generates direct calls to each delegated `handleMessage`. The resulting binary
shape mirrors xmonad's Haskell types exactly.

### Notes on Wayland Compositors

While xmonad itself is X11-only, the _layout-as-strategy_ pattern has been
re-implemented in several Wayland compositors:

- **`river`** (Zig) -- separates "layout" into an external process spoken to
  over a custom Wayland protocol. Any executable that speaks the protocol
  becomes a layout. Layouts are open in the same sense as xmonad's typeclass,
  but the boundary is a UNIX socket rather than a Haskell module.
- **`niri`** (Rust) -- ships a small enumerated set of layouts; closer to the
  i3 model.
- **`Hyprland`** (C++) -- plugin-loadable layouts; closer to xmonad's
  contrib model but via shared libraries rather than recompilation.

For a TUI library, "process boundary" is overkill; the in-process,
typeclass/template approach used by xmonad is the right comparable.

---

## References

- **Home page**: <https://xmonad.org/>
- **Source (core)**: <https://github.com/xmonad/xmonad>
- **Source (contrib)**: <https://github.com/xmonad/xmonad-contrib>
- **Hackage (core)**: <https://hackage.haskell.org/package/xmonad>
- **Hackage (contrib)**: <https://hackage.haskell.org/package/xmonad-contrib>
- **`XMonad.Layout`**: <https://hackage.haskell.org/package/xmonad/docs/XMonad-Layout.html>
- **`XMonad.Layout.LayoutCombinators`**: <https://hackage.haskell.org/package/xmonad-contrib/docs/XMonad-Layout-LayoutCombinators.html>
- **`XMonad.Layout.LayoutModifier`**: <https://hackage.haskell.org/package/xmonad-contrib/docs/XMonad-Layout-LayoutModifier.html>
- **Original announcement (haskell-cafe, 2007)**: <https://mail.haskell.org/pipermail/haskell-cafe/2007-March/023253.html>
- **"xmonad in Coq"** (Janssen, Gill, et al., 2008): a Coq port of the
  `StackSet` data structure, illustrating the small-pure-core philosophy.
- **`dwm` (the C precursor)**: <https://dwm.suckless.org/>
- **Comparison docs**: [i3-sway.md](./i3-sway.md) (config-DSL approach),
  [css-flexbox.md](./css-flexbox.md) (declarative grow/shrink),
  [taffy.md](./taffy.md) (Rust layout engine),
  [../tui-libraries/brick.md](../tui-libraries/brick.md) (Haskell TUI
  combinators in the same ecosystem).

[xmonad-home]: https://xmonad.org/
[xmonad-layout]: https://hackage.haskell.org/package/xmonad/docs/XMonad-Layout.html
[xmonad-core]: https://hackage.haskell.org/package/xmonad/docs/XMonad-Core.html
[xmonad-layout-combinators]: https://hackage.haskell.org/package/xmonad-contrib/docs/XMonad-Layout-LayoutCombinators.html
[expr-problem]: https://en.wikipedia.org/wiki/Expression_problem
