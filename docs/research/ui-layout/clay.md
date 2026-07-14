# Clay (C)

A high-performance, single-header C UI layout library that resolves a nested,
Flexbox-flavored element tree into a flat, renderer-agnostic list of drawing
primitives. Clay is designed for real-time graphical UIs (games, editors, video
demos) and prides itself on microsecond-scale layout passes, an arena-only
allocation model, and zero dependencies -- including no standard-library
linkage.

| Field            | Value                                                                                                                  |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Language         | C99 (also compiles cleanly as C++20)                                                                                   |
| License          | Zlib                                                                                                                   |
| Repository       | <https://github.com/nicbarker/clay>                                                                                    |
| Documentation    | <https://github.com/nicbarker/clay#readme>                                                                             |
| Version snapshot | `clay.h` reports 0.14 in the local `main` snapshot; the project primarily tracks `main`                                |
| Notable adoption | Clay's own website (Wasm), termbox2 demos, raylib/SDL2/SDL3/sokol/Cairo examples, multiple community games and tooling |

---

## Overview

### What It Solves

Hand-rolling a UI layout engine in C is a wide rabbit hole: you need a tree
structure, two-pass sizing (intrinsic + final), a Flexbox-like distribution
algorithm, text measurement, scroll containers, floating overlays, and some
form of hit-testing -- all without a garbage collector, all with stable
addresses, and all fast enough that you can do it sixty times a second on
a constrained device. Clay packages that engine into a single 4.8k-line
header file and gives you a declarative DSL on top.

The headline pitch in Clay's README is direct: a Flexbox-like layout model
for "complex, responsive layouts including text wrapping, scrolling
containers and aspect ratio scaling," with "microsecond layout
performance" backed by a static-arena allocator (no `malloc`/`free` in the
hot path) and an output model that is independent of any specific renderer.
Clay does not draw anything -- it produces a sorted `Clay_RenderCommandArray`
of rectangles, borders, text spans, images, scissor regions, and custom
commands, and hands that array off to whatever backend you are writing
against. Renderer reference implementations exist for raylib, SDL2, SDL3,
sokol, Cairo, GLES3, the Win32 GDI, Playdate, termbox2, and a raw ANSI
terminal renderer, all in-tree under `renderers/` in the repo.

### Design Philosophy

Clay leans hard into a few opinions:

- **Arena allocation, no runtime allocation.** You ask Clay how much memory
  it needs (`Clay_MinMemorySize()`), give it a single chunk, and from then
  on Clay never touches the system allocator. Element capacity, text cache
  capacity, and scroll-container counts are all compile-time knobs.
- **Immediate-mode authoring, retained-mode friendly output.** You re-declare
  the entire UI every frame, using a nested macro DSL that reads like JSX.
  But each emitted render command carries a stable `id`, so retained-mode
  renderers (e.g., the in-tree HTML renderer) can diff frames and reuse
  GPU resources.
- **Layout is decoupled from rendering.** Clay's output is a flat list of
  axis-aligned commands. The library is silent about how text actually
  rasterises, how images decode, or how borders are anti-aliased. Those are
  the renderer's problems.
- **A C-only macro DSL.** The `CLAY(id, { ... })` macro lets you nest
  blocks of C inside the layout description. Loops, conditionals, function
  calls, and ordinary C variables are all in scope inside a layout block --
  there is no template language to learn.
- **Single header, zero dependencies.** Drop `clay.h` into your project,
  `#define CLAY_IMPLEMENTATION` in exactly one translation unit, and you
  are done. No CMake required, no `libc` required, no `malloc` required.

### History

Clay was created by Nic Barker and went public alongside a [YouTube
introduction video](https://youtu.be/DYWTw19_8r4) in 2024 that quickly drew
attention for the macro-DSL trick (see below) and for the live-demo of the
official Clay website rendered via Wasm. The project has grown steadily on
GitHub, accumulating renderer backends, language
bindings, and a transition/animation API. Notable milestones include the
introduction of the transition API (per-property tweens on stable IDs),
the addition of clip/scroll containers driven by `Clay_GetScrollOffset()`,
and the `Clay_ElementDeclaration` style refactor that unified all per-element
configuration into a single struct passed to the `CLAY()` macro.

---

## Architecture / Layout Model

Clay's mental model is similar to a Flexbox engine:

- The UI is a tree of rectangular **elements**.
- Each element has a **layout direction** -- `CLAY_LEFT_TO_RIGHT` (default)
  or `CLAY_TOP_TO_BOTTOM` -- that determines which axis is the "main axis"
  for child distribution.
- Each element has a **sizing policy** on each axis (fit/grow/fixed/percent)
  with optional min/max clamps.
- Each element has **padding** (four sides, asymmetric), a **child gap**
  (uniform spacing between siblings on the main axis), and a **child
  alignment** policy on each axis.
- The layout pass produces a flat `Clay_RenderCommandArray` of axis-aligned
  rectangles, text spans, borders, images, scissor (clip) regions, and
  user-defined custom commands -- in render order, with each command
  carrying a `boundingBox`, a stable `id`, a `zIndex`, and a
  command-type-specific payload.

There is no notion of a CSS box model with `box-sizing`; padding is always
"inside" the element's box and reduces the area available to children.
There is also no `display: grid`, no `position: absolute` (floating
elements approximate this), no `flex-wrap`, no `display: contents`, and no
`align-content`/`justify-content` distinction -- alignment is single-axis,
single-value on each axis.

### Sizing Primitives

Sizing is the heart of Clay's layout algorithm. Each axis (width, height)
takes a `Clay_SizingAxis` value built by one of four macros:

| Macro                           | Meaning                                                                                                                                                                                            |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLAY_SIZING_FIT(min, max)`     | Size to the intrinsic size of children (plus padding/gap), clamped to `[min, max]`. This is the default. Omit `max` to let it default to `FLOAT_MAX`. Omit both for unbounded.                     |
| `CLAY_SIZING_GROW(min, max)`    | Grow to fill the parent's available space along this axis, clamped to `[min, max]`. Multiple grow-siblings share available space, with min/max clamps deciding when a sibling stops participating. |
| `CLAY_SIZING_FIXED(n)`          | Exactly `n` pixels (or whatever unit your renderer uses). Equivalent to `CLAY_SIZING_FIT(n, n)`.                                                                                                   |
| `CLAY_SIZING_PERCENT(fraction)` | A fraction of the parent's content size (parent size minus its padding and gaps). `fraction` is in `[0, 1]`.                                                                                       |

Note that Clay's "pixels" are really just `float` units -- the library
makes no assumptions about what one unit means at the renderer level. The
official terminal renderer treats one Clay unit as one character cell (see
the terminal-backend discussion below); the raylib/SDL renderers treat it
as one screen pixel.

The min/max clamps are first-class: a `CLAY_SIZING_GROW(120, 480)` element
will never shrink below 120 (even if siblings want more room) and never
grow past 480 (even if extra space is available). This is the same pattern
as Flexbox's `flex-basis` + `min-width` + `max-width`, but folded into a
single constructor.

The layout pass runs in two phases per axis:

1. **Fit pass.** Walk the tree bottom-up, computing the intrinsic
   "fit" size of each element from its children, padding, and gaps. Text
   elements call out to the user-provided `MeasureText` callback to
   determine their natural width.
2. **Grow/shrink pass.** Walk top-down, distributing each parent's
   available space among its children. Grow siblings get the leftover
   space (subject to their min/max clamps); fit/fixed/percent siblings
   keep their natural sizes; if the children's total exceeds available
   space, Clay shrinks elements down to their `min`.

This two-pass structure is what makes the entire layout O(n) in element
count, which is how Clay hits its microsecond-scale targets.

### Padding, Child Gap, and Child Alignment

```c
typedef struct {
    uint16_t left;
    uint16_t right;
    uint16_t top;
    uint16_t bottom;
} Clay_Padding;
```

Padding is per-side and unsigned 16-bit. The convenience macro
`CLAY_PADDING_ALL(n)` expands to `{ n, n, n, n }`. Padding is _inside_
the element's box and reduces the area available to children. There is
no shorthand for "vertical" or "horizontal" padding pairs analogous to
Ink's `paddingX`/`paddingY` -- you write them out, or compose with a
small helper struct.

`childGap` is a single `uint16_t` that controls the spacing between
adjacent siblings on the main axis. When `layoutDirection ==
`CLAY_LEFT_TO_RIGHT``, `childGap`is horizontal whitespace between children;
when`layoutDirection == CLAY_TOP_TO_BOTTOM`, it is vertical whitespace.
There is no separate row-gap/column-gap concept because Clay does not wrap.

`childAlignment` is a `Clay_ChildAlignment` with two axis values:

```c
typedef struct {
    Clay_LayoutAlignmentX x;   // CLAY_ALIGN_X_LEFT (default) | CLAY_ALIGN_X_CENTER | CLAY_ALIGN_X_RIGHT
    Clay_LayoutAlignmentY y;   // CLAY_ALIGN_Y_TOP  (default) | CLAY_ALIGN_Y_CENTER | CLAY_ALIGN_Y_BOTTOM
} Clay_ChildAlignment;
```

The crucial nuance: alignment in Clay is _not_ the Flexbox
`justify-content` / `align-items` split. There is one `childAlignment.x`
and one `childAlignment.y` per element, applied uniformly. If the layout
direction is `CLAY_LEFT_TO_RIGHT`, then `childAlignment.x` controls the
cross-axis packing of the children as a group along the main axis (left,
center, or right) and `childAlignment.y` controls the per-child cross-axis
alignment within the row. The roles flip when the direction is
`CLAY_TOP_TO_BOTTOM`. There is no `space-between` / `space-around` /
`space-evenly` -- you produce those effects by inserting `flexGrow`-like
spacer elements (a `CLAY_SIZING_GROW`-on-an-empty-element trick).

### Layout Direction

```c
typedef enum {
    CLAY_LEFT_TO_RIGHT = 0,   // default
    CLAY_TOP_TO_BOTTOM,
} Clay_LayoutDirection;
```

Only two directions. There is no right-to-left, no bottom-to-top, and
no axis-reversal variant analogous to Flexbox's `row-reverse` or
`column-reverse`. This is a deliberate simplification: the rendering
primitives Clay emits are also unidirectional, and reversal can be
expressed by re-ordering child declarations.

### The C-Macro DSL Trick

Clay's nested `CLAY(id, { ... }) { children }` DSL is what makes the
library feel like JSX in plain C. The trick lives in `clay.h` around line
146:

```c
#define CLAY(id, ...)                                                                                  \
    for (                                                                                              \
        CLAY__ELEMENT_DEFINITION_LATCH = (                                                             \
            Clay__OpenElementWithId(id),                                                               \
            Clay__ConfigureOpenElement(                                                                \
                CLAY__CONFIG_WRAPPER(Clay_ElementDeclaration, __VA_ARGS__)                             \
            ),                                                                                         \
            0                                                                                          \
        );                                                                                             \
        CLAY__ELEMENT_DEFINITION_LATCH < 1;                                                            \
        CLAY__ELEMENT_DEFINITION_LATCH = 1, Clay__CloseElement()                                       \
    )
```

The expansion is a single-iteration `for`-loop with three slots:

1. **Initializer**: opens the element (pushes it onto Clay's internal
   stack), configures it with the variadic-struct designated-initializer,
   and sets the latch to 0.
2. **Condition**: checks the latch.
3. **Post-iteration**: sets the latch to 1 (so the loop exits next
   check) _and_ calls `Clay__CloseElement()` (pops the stack).

The body of the `for` loop is the block of code that follows the macro
call -- which is where you write your children. Because it is a real C
block, you can use `for`, `if`, function calls, local variables, and
anything else that compiles. `break` and `continue` work too (with the
expected caveat that `break` will skip the close-element call -- Clay's
documentation warns against this).

This trick predates Clay (it's a known idiom for "scoped" macros in C),
but Clay's use of it is one of the most polished examples around: it
gives the user a JSX-style block-nesting DSL while staying purely in
the C preprocessor and producing a flat, predictable expansion.

The Odin bindings achieve the same nesting using Odin's
[`@(deferred_none)`](https://odin-lang.org/docs/overview/) attribute,
which schedules a cleanup proc to run when the surrounding scope exits.
That maps the C-macro pattern almost exactly: open on entry, configure
inline, close on scope exit.

### Measure-Arrange Protocol

Clay does not measure text itself. The user provides a callback:

```c
typedef Clay_Dimensions (*Clay_MeasureTextFn)(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *userData
);

void Clay_SetMeasureTextFunction(Clay_MeasureTextFn fn, void *userData);
```

This callback is invoked during the fit pass for every text element whose
natural size has not already been cached. Two important contracts:

- **The string slice is not null-terminated.** Clay slices the original
  string into segments (e.g., for wrap candidates) and passes pointer +
  length, not a C-string. Renderers that need a null-terminated string
  (Raylib's font API, for example) must copy into a scratch buffer.
- **The callback is on the hot path.** Clay caches measurements per word,
  but for text-heavy UIs this function still gets called many times per
  frame. The README warns that a slow `MeasureText` callback can easily
  dominate frame time even with the cache.

`Clay_ResetMeasureTextCache()` invalidates the cache (call it when DPI or
font changes), and `Clay_SetMaxMeasureTextCacheWordCount()` adjusts the
internal cache size before initialization.

The measure-arrange protocol is therefore a hybrid: Clay arranges, the
host measures text, and Clay caches the measurements. There is no
separate "arrange" callback -- Clay handles arrangement entirely
internally using its sizing primitives.

### Render-Command Output Model

`Clay_EndLayout()` returns a `Clay_RenderCommandArray`:

```c
typedef enum {
    CLAY_RENDER_COMMAND_TYPE_NONE,
    CLAY_RENDER_COMMAND_TYPE_RECTANGLE,
    CLAY_RENDER_COMMAND_TYPE_BORDER,
    CLAY_RENDER_COMMAND_TYPE_TEXT,
    CLAY_RENDER_COMMAND_TYPE_IMAGE,
    CLAY_RENDER_COMMAND_TYPE_SCISSOR_START,
    CLAY_RENDER_COMMAND_TYPE_SCISSOR_END,
    CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_START,
    CLAY_RENDER_COMMAND_TYPE_OVERLAY_COLOR_END,
    CLAY_RENDER_COMMAND_TYPE_CUSTOM,
} Clay_RenderCommandType;

typedef struct {
    Clay_BoundingBox boundingBox;
    Clay_RenderData renderData;          // union over command-type payloads
    void *userData;
    uint32_t id;
    int16_t zIndex;
    Clay_RenderCommandType commandType;
} Clay_RenderCommand;
```

Every command has an axis-aligned bounding box, a stable id, a z-index,
and a discriminated union of per-type data. The renderer iterates the
array once, switching on `commandType`, and dispatches to the
appropriate drawing primitive.

The `SCISSOR_START`/`SCISSOR_END` pair brackets a region inside which
all draw commands should be clipped to the start command's bounding
box -- this is how scroll containers and clip regions are expressed.
`OVERLAY_COLOR_START`/`OVERLAY_COLOR_END` brackets a region that should
have a tint applied (used for "fade out" effects).
`CLAY_RENDER_COMMAND_TYPE_CUSTOM` carries an opaque `void *` payload
that you populate yourself (typically out of a frame arena), letting you
inject custom primitives (3D models, video frames, native widgets) into
the otherwise opaque draw stream.

**What this means for terminal backends.** Clay's render commands are
in float-pixel space, and rectangles carry RGBA colors plus corner radii.
A terminal backend has to project all of that onto an integer character
grid. The in-tree `renderers/terminal/clay_renderer_terminal_ansi.c`
takes the simplest approach: every rectangle is drawn as a block of
shaded box-drawing characters (`█`, `▓`, `▒`, `░`) chosen by the
average channel intensity, every text command is positioned by
ANSI cursor-move escapes, and there is no color support at all (RGB is
collapsed to brightness). The termbox2-based renderer is more elaborate,
mapping Clay colors to xterm-256 cells and using termbox's cell buffer
to handle diffing. Either way: the renderer is responsible for the
projection from `float` to cells, for color quantisation, for character
selection, and for any double-buffer diffing -- Clay itself has no
opinion. See [Strengths and Weaknesses](#strengths-and-weaknesses) below
for what this means in practice.

### Code Example 1: A Sidebar-and-Content Layout

A minimal example from the README, lightly trimmed:

```c
#define CLAY_IMPLEMENTATION
#include <stdio.h>
#include <stdlib.h>
#include "clay.h"

const Clay_Color COLOR_LIGHT = (Clay_Color){ 224, 215, 210, 255 };
const Clay_Color COLOR_RED   = (Clay_Color){ 168,  66,  28, 255 };

static Clay_Dimensions MeasureText(
    Clay_StringSlice text,
    Clay_TextElementConfig *config,
    void *userData
) {
    // Monospace approximation -- a real renderer would consult a font.
    return (Clay_Dimensions){
        .width  = text.length * config->fontSize,
        .height = config->fontSize,
    };
}

static void HandleClayErrors(Clay_ErrorData data) {
    fprintf(stderr, "clay: %.*s\n", data.errorText.length, data.errorText.chars);
}

int main(void) {
    uint64_t   sz    = Clay_MinMemorySize();
    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(sz, malloc(sz));
    Clay_Initialize(arena, (Clay_Dimensions){ 1920, 1080 },
                    (Clay_ErrorHandler){ HandleClayErrors });
    Clay_SetMeasureTextFunction(MeasureText, NULL);

    Clay_BeginLayout();

    CLAY(CLAY_ID("Outer"), {
        .layout = {
            .sizing          = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
            .padding         = CLAY_PADDING_ALL(16),
            .childGap        = 16,
            .layoutDirection = CLAY_LEFT_TO_RIGHT,
        },
        .backgroundColor = { 250, 250, 255, 255 },
    }) {
        CLAY(CLAY_ID("Sidebar"), {
            .layout = {
                .sizing          = { CLAY_SIZING_FIXED(300), CLAY_SIZING_GROW(0) },
                .padding         = CLAY_PADDING_ALL(16),
                .childGap        = 16,
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
            },
            .backgroundColor = COLOR_LIGHT,
        }) {
            CLAY_TEXT(CLAY_STRING("Clay - UI Library"),
                CLAY_TEXT_CONFIG({ .fontSize = 24, .textColor = { 255, 255, 255, 255 } }));

            for (int i = 0; i < 5; i++) {
                CLAY(CLAY_IDI("Item", i), {
                    .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(50) } },
                    .backgroundColor = COLOR_RED,
                }) {}
            }
        }

        CLAY(CLAY_ID("Content"), {
            .layout = {
                .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
            },
            .backgroundColor = COLOR_LIGHT,
        }) {}
    }

    Clay_RenderCommandArray cmds = Clay_EndLayout();
    for (int i = 0; i < cmds.length; i++) {
        Clay_RenderCommand *c = &cmds.internalArray[i];
        // dispatch on c->commandType ...
    }
}
```

Things to notice:

- The whole UI is declared inside a single arena. `malloc` is only used
  to _acquire_ the arena -- after that, Clay never allocates.
- `CLAY_IDI("Item", i)` is the loop-friendly id macro: it produces a
  unique element id from a string + integer pair without any runtime
  string formatting.
- The `Sidebar` is sized as `CLAY_SIZING_FIXED(300)` on the main axis and
  `CLAY_SIZING_GROW(0)` on the cross axis -- a fixed-width column that
  fills the parent's height.
- `Content` is `GROW(0)` on both axes, so it takes whatever the sidebar
  leaves.

### Code Example 2: Centered Card with Padding and Gap

```c
CLAY(CLAY_ID("PageRoot"), {
    .layout = {
        .sizing          = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
        .childAlignment  = { .x = CLAY_ALIGN_X_CENTER, .y = CLAY_ALIGN_Y_CENTER },
    },
}) {
    CLAY(CLAY_ID("Card"), {
        .layout = {
            .sizing          = {
                CLAY_SIZING_FIT(240, 480),  // grow with content, clamped
                CLAY_SIZING_FIT(0, 0),      // hug children vertically
            },
            .padding         = { 24, 24, 16, 16 },
            .childGap        = 12,
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .childAlignment  = { .x = CLAY_ALIGN_X_CENTER, .y = CLAY_ALIGN_Y_TOP },
        },
        .backgroundColor = { 30, 30, 36, 255 },
        .cornerRadius    = CLAY_CORNER_RADIUS(8),
        .border          = {
            .color = { 70, 70, 90, 255 },
            .width = { .left = 1, .right = 1, .top = 1, .bottom = 1, .betweenChildren = 0 },
        },
    }) {
        CLAY_TEXT(CLAY_STRING("Confirm action"),
            CLAY_TEXT_CONFIG({ .fontSize = 18, .textColor = { 240, 240, 245, 255 } }));
        CLAY_TEXT(CLAY_STRING("Are you sure you want to proceed?"),
            CLAY_TEXT_CONFIG({ .fontSize = 14, .textColor = { 200, 200, 210, 255 } }));
    }
}
```

`CLAY_SIZING_FIT(240, 480)` is the clamp idiom: the card wants to hug
its children's intrinsic width, but never narrower than 240 units and
never wider than 480. Combined with `childAlignment` on the root, the
card naturally centers itself in the viewport.

### Code Example 3: Scroll Container

```c
CLAY(CLAY_ID("Scroll"), {
    .layout = {
        .sizing          = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(300) },
        .layoutDirection = CLAY_TOP_TO_BOTTOM,
        .childGap        = 4,
    },
    .clip = {
        .vertical    = true,
        .childOffset = Clay_GetScrollOffset(),
    },
    .backgroundColor = { 20, 20, 24, 255 },
}) {
    for (int i = 0; i < 1000; i++) {
        CLAY(CLAY_IDI("Row", i), {
            .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(24) } },
            .backgroundColor = (i & 1) ? (Clay_Color){ 28, 28, 32, 255 }
                                       : (Clay_Color){ 22, 22, 26, 255 },
        }) {
            CLAY_TEXT(rowLabel(i), CLAY_TEXT_CONFIG({ .fontSize = 14, .textColor = { 220, 220, 220, 255 } }));
        }
    }
}
```

The `.clip = { .vertical = true, .childOffset = Clay_GetScrollOffset() }`
field is the key. It tells Clay to emit a `SCISSOR_START` at the start
of this element and a `SCISSOR_END` at the end, _and_ to offset the
child content vertically by Clay's internally tracked scroll offset.
`Clay_UpdateScrollContainers()` (called once per frame before
`BeginLayout`) updates that offset from mouse-wheel / touch-drag deltas.
A scroll bar is just another element you can position alongside.

### Code Example 4: Odin Bindings

The Odin port mirrors the C API closely. The key trick is that Odin's
`@(deferred_none = ...)` attribute lets a procedure schedule a cleanup
proc to run on scope exit, which gives you the same "open-close" pairing
the C macro provides:

```odin
import clay "clay-odin"

LandingPageBlob :: proc(
    index: u32,
    fontSize: u16,
    fontId: u16,
    color: clay.Color,
    $text: string,
    image: ^raylib.Texture2D,
) {
    if clay.UI(clay.ID("HeroBlob", index))(
        {
            layout = {
                sizing         = { width = clay.SizingGrow({ max = 480 }) },
                padding        = clay.PaddingAll(16),
                childGap       = 16,
                childAlignment = clay.ChildAlignment{ y = .Center },
            },
            border       = border2pxRed,
            cornerRadius = clay.CornerRadiusAll(10),
        },
    ) {
        if clay.UI(clay.ID("CheckImage", index))(
            {
                layout      = { sizing = { width = clay.SizingFixed(32) } },
                aspectRatio = { 1.0 },
                image       = { imageData = image },
            },
        ) {}
        clay.Text(text, { fontSize = fontSize, fontId = fontId, textColor = color })
    }
}
```

The double-paren syntax (`clay.UI(id)(config)`) reflects that `UI` is a
curried procedure: the outer call opens the element, and the returned
procedure receives the element configuration. The `@(deferred_none)`
attribute on `UI_WithId`/`UI_AutoId` arranges for `_CloseElement` to run
at the end of the `if` block. Apart from that, every Odin call line-for-line
matches the equivalent C macro.

---

## Bindings and Language Support

Clay is, by design, a C library. The public API is plain C with no
templates or generics, so binding it from other languages is a matter of
exposing the same functions and replicating the macro DSL using the host
language's idioms.

### Official / In-tree

| Language | Status        | Location                             |
| -------- | ------------- | ------------------------------------ |
| C        | Reference     | `clay.h`                             |
| C++      | Reference     | `clay.h` (compiles cleanly as C++20) |
| Odin     | Official      | `bindings/odin/clay-odin/`           |
| Rust     | Official      | <https://github.com/clay-ui-rs/clay> |
| Zig      | Bindings dir  | `bindings/zig/`                      |
| C#       | Bindings dir  | `bindings/csharp/`                   |
| C++      | Idiomatic dir | `bindings/cpp/`                      |

The Odin bindings are particularly polished -- they ship with prebuilt
static libraries for Linux, macOS (`x86_64` and arm64), Windows, and
WebAssembly, and they include a full port of the Clay-website example.
The Rust bindings (in a separate repo, `clay-ui-rs/clay`) wrap the C
header via `bindgen` and expose an ergonomic builder API.

### External / Community

| Language | Project                                                                            |
| -------- | ---------------------------------------------------------------------------------- |
| D        | [`clayd`](https://github.com/zkxjzmswkwl/clayd)                                    |
| D        | [`clayui`](https://github.com/zkxjzmswkwl/clayui)                                  |
| Go       | [`glay`](https://github.com/soypat/glay)                                           |
| Go       | [`totallygamerjet/clay`](https://github.com/totallygamerjet/clay) (cxgo transpile) |
| Go       | [`goclay`](https://github.com/igadmg/goclay)                                       |

The `bindings/d/README` file in the Clay repo is literally just two URLs:
the `clayd` and `clayui` repositories, both maintained by the same
external author. There is no in-tree D binding -- if you want to use
Clay from D today, you either consume one of those external wrappers or
you generate your own bindings from `clay.h` using `dpp` /
`dstep` / `htod`. The Sparkles project's preference for `@nogc`,
templated, statically-known APIs would make a fresh, lean D wrapper an
attractive option -- Clay's arena-based, allocation-free runtime maps
unusually well to D's `@nogc` subset.

### What a Binding Has to Provide

The non-obvious part of binding Clay is replicating the nested DSL. The
binding author has three options:

1. **A scope-guard pattern.** Odin uses `@(deferred_none)`; Zig uses
   `defer`; Rust uses RAII through `Drop`; D can use `scope(exit)`. The
   binding exposes a function that opens an element and another that
   closes it, and the host language's scope-exit hook calls the closer.
2. **A higher-order function.** Pass a closure that receives a builder.
   The wrapper opens the element, runs the closure, then closes the
   element. This is what `clay-ui-rs` does for one of its APIs.
3. **A literal port of the `for`-loop trick.** Only practical in
   languages with C-style preprocessors (so basically just C/C++).

All three end up producing the same `Clay_RenderCommandArray`; the
choice is purely about ergonomics in the host language.

---

## Strengths and Weaknesses

### For Real-Time Graphical UIs (its target)

Clay is excellent at what it was designed for:

- **Microsecond layout passes**. With 8000+ elements the layout pass
  finishes in single-digit milliseconds on a desktop CPU, which is well
  inside a 60 Hz frame budget with room to spare.
- **Zero runtime allocation**. The arena is sized once, never grows.
  This is enormously valuable in soft-real-time contexts (games,
  audio software, embedded UIs) where any heap interaction is a tail
  latency risk.
- **Single-header, zero-dependency distribution**. Drop `clay.h` into
  your project, define `CLAY_IMPLEMENTATION` in one file, and you have a
  layout engine. No CMake, no `libc` required, no build orchestration.
- **Renderer agnosticism is real**. The in-tree backends -- raylib,
  SDL2/3, sokol, Cairo, GLES3, Win32 GDI, Playdate, termbox2 -- share
  no Clay-specific glue beyond consuming the render-command array.
- **The macro DSL is genuinely pleasant** for C/C++ developers. Nested
  layout reads like JSX with `for` loops, `if` statements, and ordinary
  C variables inline -- there is no template language to learn.
- **Strong debug tooling**. `Clay_SetDebugModeEnabled(true)` injects an
  inspector panel into the render-command stream, with element
  bounding-box visualisation and hierarchy navigation, so you do not
  need to write your own debug overlay.

### For Static One-Shot Rendering (e.g. a Terminal Table)

Clay is a **poor fit** for static one-shot rendering, and it is worth
unpacking why.

The first mismatch is **abstraction level**. Clay's output is a
`Clay_RenderCommandArray` of float-coordinate axis-aligned rectangles,
borders, and text spans. If you want to emit a final ANSI string for a
terminal table -- the kind of thing the Sparkles `core-cli` `prettyPrint`
or table-formatter modules produce -- you would have to:

1. Build the element tree (allocate arena, configure padding/sizing).
2. Provide a `MeasureText` callback that returns column widths.
3. Run `Clay_EndLayout()` to get the render-command array.
4. Iterate the array and project each command onto an integer character
   grid -- choosing block characters for filled rectangles, using cursor
   moves for text placement, quantising RGB colours to xterm-256 or
   true-colour SGR escapes, and tracking the
   `SCISSOR_START`/`SCISSOR_END` pairs to clip text inside scroll
   regions.

The in-tree `renderers/terminal/clay_renderer_terminal_ansi.c` is 194
lines, and _most_ of it is the shading lookup that maps RGBA to
`█`/`▓`/`▒`/`░`. It has no styled-text support, no border-character
selection, and treats every rectangle as a heat-map cell. The
termbox2-based renderer is much more sophisticated -- it uses cell
buffers, mosaic image rendering, and quantises colours into the
xterm-256 palette -- but it is also nearly 1800 lines, and a non-trivial
fraction of that is image-rendering scaffolding rather than the layout
glue.

For Sparkles' use cases -- printing a one-shot table, a help screen, or
a colorised log line -- this is the **wrong abstraction stack**. You
do not want to:

- pull in arena allocation, scroll containers, transitions, hit-testing,
  and a render-command array, just to align two columns;
- build, then re-interpret, then re-rasterise an intermediate output
  format whose primitives (RGBA rectangles, float bounding boxes,
  scissor regions) are themselves a mismatch for the target medium
  (a 2D grid of styled cells with bounded color depth);
- maintain a `MeasureText` callback whose contract is "give me a
  fractional width in float pixels" when you actually know the width
  in character cells without ambiguity.

Put differently: Clay solves a _layout calculation_ problem that
terminal CLIs do not have, and then leaves you to solve a _rendering
projection_ problem (float-pixel commands → integer-cell ANSI) that
turns out to be most of the work. For a one-shot terminal rendering
pipeline, a constraint solver that produces (col, row, width, height,
style) tuples directly -- like Ratatui's `Layout::split` -- is a
better fit. See [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md)
for the constraint-and-Rect model Ratatui uses, and
[../tui-libraries/ink.md](../tui-libraries/ink.md) for the Yoga-based
approach Ink takes, which is closer to Clay's model but with the
"float pixels → cells" projection abstracted away by yoga-layout's
configuration knobs.

The other practical wrinkle for terminal output is the **box model**.
Clay uses rectangles with optional corner radii, RGBA colours, and
borders specified as `Clay_BorderElementConfig` with per-side widths
in floats. A terminal renderer has to choose box-drawing characters
(`┌`, `─`, `│`, `┐`, ...) for borders, and Clay's renderer-agnostic
output gives no hint about which character to pick -- you have to
look at the four neighbours of every cell to decide whether to emit
a corner or an edge piece. The termbox2 renderer does this; the
plain ANSI renderer does not, which is why its output looks like
heatmap blocks instead of crisp boxes.

### Embedding Across Renderers

Where Clay genuinely shines, and where no other library in this
catalog matches it, is **the same layout tree producing pixel-perfect
output across radically different backends**. The same C code that
runs on a Playdate (1-bit framebuffer, 84 MHz Cortex-M7) renders on
WebAssembly in the browser, on Win32 GDI, on raylib, on SDL2/3, on
sokol, on Cairo for PDF generation, and on terminal cells. The
official Clay website is itself a Clay layout running in Wasm, with
an HTML renderer that converts each render command into a persistent
DOM element. This is impossible in retained-mode toolkits because
their primitives are bound to a specific render target.

For Sparkles, this "single tree, many renderers" property is mostly
moot: the project's renderer is always a terminal, and the
projection from Clay's command stream to ANSI cells is exactly the
work being avoided.

### Compared to Alternatives

- **[Yoga](./yoga.md)**. Yoga is the other Flexbox-style layout engine
  in this catalog. Yoga implements a faithful subset of the CSS
  Flexbox specification (with proper `justify-content`, `align-items`,
  `align-content`, `flex-wrap`, RTL support, percentages, gaps); Clay
  implements a simplified, Clay-shaped flex model with single-value
  `childAlignment` and no wrapping. Yoga is much larger (hundreds of
  kilobytes of C++ in the WASM build) and slower per node, but it
  produces output that web developers immediately recognise. Clay is
  smaller, faster, and more opinionated. Crucially, Yoga produces
  `(left, top, width, height)` tuples per node (a "computed style"
  tree), not a render-command array -- the caller is expected to
  re-traverse the tree itself to render, which makes Yoga a better
  fit if you already have a retained-mode renderer (this is exactly
  what [../tui-libraries/ink.md](../tui-libraries/ink.md) does).
- **Ratatui's constraint solver**. Ratatui ([../tui-libraries/ratatui.md](../tui-libraries/ratatui.md))
  uses a Cassowary-style constraint system to subdivide a `Rect`
  into sub-rects, one constraint per child. It is _not_ a layout
  engine in the Flexbox sense -- there is no tree, no measurement
  pass, no intrinsic sizing. It is a one-shot box-splitter. For
  the terminal-output use case, this is exactly the right shape and
  one or two orders of magnitude smaller and simpler than Clay.
- **Dear ImGui's auto-layout**. Dear ImGui has a much weaker layout
  story -- elements are positioned by cursor movement, with `SameLine`,
  groups, and tables as escape hatches. Clay's layout model is
  considerably more expressive and more declarative.
- **Native toolkits (Qt, GTK, AppKit)**. These ship layout engines too,
  but bound to a specific widget set and platform. Clay is portable to
  anywhere C compiles, and the layout output is decoupled from
  rendering.

---

## References

### Primary

- **Repository**: <https://github.com/nicbarker/clay>
- **README / API reference**: <https://github.com/nicbarker/clay#readme>
- **Live demo (Wasm)**: <https://nicbarker.com/clay>
- **Introduction video**: <https://youtu.be/DYWTw19_8r4>
- **Discord**: <https://discord.gg/b4FTWkxdvT>

### Source

- **`clay.h`** (single header, 4.8k LOC): <https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h>
- **The `CLAY()` macro** (lines 146-151 of `clay.h`): the for-loop DSL trick.
- **Render-command type enum**: `Clay_RenderCommandType` around line 765 of `clay.h`.

### Renderer Backends (in-tree)

- **raylib**: `renderers/raylib/`
- **SDL2 / SDL3**: `renderers/SDL2/`, `renderers/SDL3/`
- **sokol**: `renderers/sokol/`
- **Cairo** (PDF output): `renderers/cairo/`
- **GLES3**: `renderers/GLES3/`
- **Win32 GDI**: `renderers/win32_gdi/`
- **Playdate**: `renderers/playdate/`
- **Terminal (raw ANSI)**: `renderers/terminal/clay_renderer_terminal_ansi.c`
- **termbox2**: `renderers/termbox2/clay_renderer_termbox2.c`
- **Web (HTML)**: `renderers/web/`

### Bindings

- **Odin** (in-tree, official): <https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b/bindings/odin>
- **Rust** (separate repo, official): <https://github.com/clay-ui-rs/clay>
- **Zig** (in-tree): <https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b/bindings/zig>
- **C#** (in-tree): <https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b/bindings/csharp>
- **C++** (in-tree, idiomatic): <https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b/bindings/cpp>
- **D** (external, community): <https://github.com/zkxjzmswkwl/clayd>, <https://github.com/zkxjzmswkwl/clayui>
- **Go (line-by-line port)**: <https://github.com/soypat/glay>
- **Go (cxgo transpile)**: <https://github.com/totallygamerjet/clay>
- **Go (alternative port)**: <https://github.com/igadmg/goclay>

### Cross-References

- [yoga.md](./yoga.md) -- the other Flexbox-style layout engine in this
  catalog. Faithful CSS-Flexbox subset, used by Ink for terminal layout.
- [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md) --
  constraint-based one-shot rectangle splitter; the closest "shape" of
  layout primitive to what a static terminal renderer wants.
- [../tui-libraries/ink.md](../tui-libraries/ink.md) -- the
  Yoga-via-WASM-in-Node story for terminal Flexbox, useful as a
  contrast to Clay's "emit a command array, you project it onto cells"
  philosophy.
- [../tui-libraries/notcurses.md](../tui-libraries/notcurses.md) --
  another C terminal library that handles cell-level rendering, useful
  for thinking about what a Clay terminal renderer ultimately has to
  do at the byte level.
- [../tui-libraries/ftxui.md](../tui-libraries/ftxui.md) -- a C++
  layout-and-render system whose `hbox`/`vbox`/`flex` primitives sit
  closer to Clay's model than to Ratatui's.
