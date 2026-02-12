# libvaxis (Zig)

A modern terminal UI library for Zig that eschews terminfo in favor of runtime capability detection, providing both a low-level cell-based API and a Flutter-inspired widget framework with explicit allocator passing and comptime-powered generics.

| Field          | Value                                    |
| -------------- | ---------------------------------------- |
| Language       | Zig                                      |
| License        | MIT                                      |
| Repository     | <https://github.com/rockorager/libvaxis> |
| Documentation  | <https://rockorager.github.io/libvaxis/> |
| Latest Version | 0.5.1 (targeting Zig 0.15.1)             |
| GitHub Stars   | ~1.4k                                    |

---

## Overview

**What it solves.** libvaxis provides a complete terminal UI toolkit for Zig that handles
screen rendering, keyboard/mouse input, color management, image display, and Unicode
grapheme clustering. It eliminates the need for terminfo databases by detecting terminal
capabilities at runtime through escape-sequence queries, enabling direct use of modern
terminal features without static capability files.

**Design philosophy.** libvaxis is built on four core principles:

1. **Modern terminals first.** Rather than targeting the lowest common denominator of VT100
   compatibility, libvaxis is designed around the Kitty keyboard protocol, Kitty graphics
   protocol, SGR pixel mouse mode, and other features available in modern terminals (Kitty,
   WezTerm, Ghostty, foot, Alacritty). Legacy terminals are supported through fallback
   paths, but the API is designed around the capabilities of modern emulators.

2. **Explicit allocator passing.** Every allocation site accepts a `std.mem.Allocator`
   parameter. There are no global allocators, no hidden heap usage. The caller controls
   exactly where memory comes from -- general-purpose, arena, fixed-buffer, or a custom
   allocator.

3. **comptime-powered generics.** Zig's `comptime` is used pervasively: generic event types,
   duck-typed widget interfaces, compile-time field iteration for table rendering, and
   compile-time format string evaluation. No runtime reflection, no vtable overhead for
   generic code paths.

4. **Minimal dependencies.** The library depends only on `zigimg` (for image decoding) and
   `uucode` (for Unicode tables). There is no libc dependency, no terminfo, no curses.

**History and motivation.** libvaxis was created by rockorager as a ground-up Zig
implementation that rejects the terminfo model used by ncurses, notcurses, and most existing
TUI libraries. The author observed that modern terminal emulators have converged on a set of
de facto standard protocols (Kitty keyboard, synchronized output, true color) and that
querying the terminal directly is more reliable than relying on potentially outdated terminfo
entries. The library has gained significant traction in the Zig ecosystem: it is used by
Ghostty (the terminal emulator by Mitchell Hashimoto) and Superhtml, among other projects.

---

## Architecture

### Three Primitives

libvaxis is structured around three fundamental objects:

1. **`Tty`** -- A platform-specific TTY handle (POSIX or Windows) that manages raw mode,
   signal handling, and byte-level I/O with the terminal.
2. **`Vaxis`** -- The core library context. Holds screen buffers, capability state, image
   IDs, and rendering logic. Initialized with an allocator.
3. **`Loop`** -- A multi-threaded event loop that reads from the TTY on a background thread,
   parses escape sequences, and enqueues typed events into a thread-safe queue.

```zig
var tty = try vaxis.Tty.init();
defer tty.deinit();

var vx = try vaxis.init(alloc, .{});
defer vx.deinit(alloc, &tty);

var loop = try vaxis.Loop(Event).init(&vx, &tty);
defer loop.deinit();
loop.start();
```

### Double-Buffered Rendering

Vaxis maintains two screen representations:

- **`screen: Screen`** -- The current (back) buffer. Widgets write into this buffer during
  the draw phase.
- **`screen_last: InternalScreen`** -- The previous (front) buffer, representing what is
  currently displayed on the terminal.

On each `render()` call, Vaxis diffs the current screen against `screen_last`, emitting only
the escape sequences needed to update changed cells. Unchanged cells are skipped via a fast
equality check (`InternalCell.eql()`), with a fast path when both cells are in their default
state.

### Render Loop

The render loop follows an immediate-mode pattern:

```
App State
   |
   v
win = vx.window()      // get the full-screen Window
win.clear()             // clear the back buffer
   |
   v
Draw widgets into win   // write cells via win.writeCell(), win.print(), widget.draw()
   |
   v
vx.render(&tty)         // diff back buffer vs front buffer, flush escape sequences
   |
   v
Terminal emulator        // only changed cells are updated
```

Each frame, the application clears the back buffer, draws the entire UI from scratch, and
calls `render()`. Despite rebuilding every frame, performance is bounded by the number of
_changed_ cells, not the total cell count.

### Event Loop

The `Loop` is parameterized on a user-defined `Event` type. The library uses Zig's
`@hasField` comptime introspection to determine which event categories the application
cares about:

```zig
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    // Only declare the events you handle.
    // The loop uses @hasField to check at comptime.
};

// Blocking wait for next event
const event = loop.nextEvent();

// Non-blocking poll
if (loop.tryEvent()) |event| { ... }
```

This is a powerful pattern: the event loop adapter inspects the application's `Event` union
at compile time and only generates dispatch code for the variants the application declares.
If the application does not declare `mouse`, mouse events are never enqueued. This is
zero-cost event filtering via comptime.

---

## Terminal Backend

### No Terminfo

libvaxis generates escape sequences directly from hardcoded control strings defined in
`ctlseqs.zig`. Instead of querying a terminfo database for "does this terminal support bold",
it sends a query escape sequence to the terminal and reads the response. This approach has
several advantages:

- No dependency on system-installed terminfo files (which may be incomplete or outdated).
- Correct capability detection for terminals running over SSH or in containers.
- Support for features that terminfo does not describe (Kitty keyboard protocol, graphics
  protocol, synchronized output).

### Feature Detection

During initialization, `vx.queryTerminal(&tty, timeout)` sends a batch of capability
queries and waits for responses. The detected capabilities are stored in `vx.caps`:

```zig
pub const Capabilities = struct {
    kitty_keyboard: bool,
    kitty_graphics: bool,
    rgb: bool,
    sgr_pixels: bool,
    unicode: bool,
    color_scheme_updates: bool,
    // ...
};
```

### Supported Capabilities

| Feature                 | Protocol / Mode  | Notes                                        |
| ----------------------- | ---------------- | -------------------------------------------- |
| Kitty keyboard protocol | CSI >1u          | Press/release/repeat, full modifier tracking |
| Kitty graphics protocol | APC Gq           | Inline images, image placement and lifecycle |
| True color (24-bit RGB) | SGR 38;2 / 48;2  | Detected via DA1 response                    |
| Mouse (SGR pixel mode)  | Mode 1003 + 1016 | Sub-cell precision via pixel coordinates     |
| Synchronized output     | Mode 2026        | Prevents tearing on fast updates             |
| Unicode core            | Mode 2027        | Proper grapheme clustering in terminal       |
| Styled underlines       | SGR 4:x          | Curly, dotted, dashed, double                |
| Hyperlinks              | OSC 8            | Clickable URIs in terminal text              |
| System clipboard        | OSC 52           | Read/write system clipboard                  |
| Bracketed paste         | Mode 2004        | Distinguishes typed input from paste         |
| In-band resize reports  | Mode 2048        | Resize events via escape sequences           |
| Color scheme updates    | Mode 2031        | Dark/light mode change notifications         |
| Desktop notifications   | OSC 9 / OSC 777  | Toast notifications from TUI apps            |
| Mouse cursor shape      | OSC 22           | Change cursor appearance on hover            |
| Alt screen              | Mode 1049        | Separate buffer for full-screen UI           |

### Fallback Path

For legacy terminals that do not respond to capability queries, libvaxis falls back to
standard SGR rendering mode (256-color palette, basic modifiers, no Kitty keyboard). The
`sgr` field on `Vaxis` tracks whether to use standard or legacy escape sequence formatting.

---

## Layout System

### Manual Window-Based Layout

libvaxis does not include a constraint solver. Layout is performed manually by creating
**child windows** from a parent window, specifying offsets and dimensions:

```zig
const win = vx.window();
win.clear();

// Create a child window: left panel, 30 columns wide, full height
const left_panel = win.child(.{
    .x_off = 0,
    .y_off = 0,
    .width = .{ .limit = 30 },
    .height = .{ .limit = win.height },
});

// Right panel fills remaining space
const right_panel = win.child(.{
    .x_off = 30,
    .y_off = 0,
    .width = .{ .limit = win.width -| 30 },
    .height = .{ .limit = win.height },
});
```

A `Window` is a view into the underlying `Screen` buffer with an offset and dimensions. It
provides bounds-checked `writeCell()` and `readCell()` methods -- writes outside the window
bounds are silently discarded. This is memory-safe without any runtime overhead beyond a
bounds check.

### Window.child()

The `child()` method creates a sub-window with relative positioning. Key properties:

- **`x_off`, `y_off`** -- Offset relative to the parent.
- **`width`, `height`** -- Size specification (limit or unbounded, clamped to parent).
- **`border`** -- Optional border using customizable Unicode glyphs.

Child windows accumulate offsets. A child of a child has its absolute position computed from
the chain of offsets, enabling nested composition.

### Alignment Helpers

The `widgets/alignment.zig` module provides positioning helpers:

```zig
// Center a 20x5 region within the parent window
const centered = vaxis.widgets.alignment.center(win, 20, 5);

// Other alignment options
const top_right = vaxis.widgets.alignment.topRight(win, 20, 5);
const bottom_left = vaxis.widgets.alignment.bottomLeft(win, 20, 5);
```

Each helper returns a `Window` (child) positioned at the appropriate offset within the
parent.

### vxfw FlexBox Layout

The higher-level `vxfw` framework adds flex-based layout through `FlexRow` and `FlexColumn`
widgets. These implement a two-pass algorithm:

1. **Measure pass:** Children with `flex = 0` are drawn with unconstrained size to determine
   their inherent dimensions.
2. **Distribute pass:** Remaining space is allocated proportionally among flex children. The
   last child receives any remainder to prevent rounding gaps.

```zig
// Three columns: fixed 10 + flex 1 + flex 2
const row = FlexRow{
    .children = &.{
        .{ .widget = sidebar.widget(), .flex = 0 },  // inherent width
        .{ .widget = content.widget(), .flex = 1 },   // 1/3 remaining
        .{ .widget = preview.widget(), .flex = 2 },   // 2/3 remaining
    },
};
```

---

## Widget / Component System

### Low-Level API: Duck-Typed via Convention

In the low-level API, a "widget" is any type that knows how to draw itself into a `Window`.
There is no formal interface or trait. By convention, widgets implement:

- `draw(win: Window) void` -- Render into the given window.
- `update(event: Event) void` -- Process an input event (optional).

The `TextInput` widget exemplifies this pattern:

```zig
const TextInput = @import("vaxis").widgets.TextInput;

var text_input = TextInput.init(alloc);
defer text_input.deinit();

// In event handling:
try text_input.update(.{ .key_press = key });

// In rendering:
const child = win.child(.{ .x_off = 1, .y_off = 1, .width = .{ .limit = 40 }, .height = .{ .limit = 1 } });
text_input.draw(child);
```

The `Table` widget goes further, using comptime field iteration to render arbitrary struct
types:

```zig
// Table renders any Slice, ArrayList, or MultiArrayList
// using inline for over struct fields at comptime
const table = Table(MyData){
    .ctx = &table_ctx,
};
table.drawTable(win, data_slice);
```

This uses `@typeInfo`, `std.meta.fields()`, and `inline for` to iterate struct fields at
compile time, generating specialized rendering code for each column with zero runtime
overhead.

### vxfw Framework: Type-Erased Widget Protocol

The `vxfw` (Vaxis Framework) provides a more structured widget system with type erasure.
Widgets implement their behavior through a standardized protocol:

```zig
pub const Widget = struct {
    userdata: *anyopaque,
    eventHandler: ?*const fn (*anyopaque, *EventContext) anyerror!void = null,
    drawFn: *const fn (*anyopaque, DrawContext) Allocator.Error!Surface,

    /// Draw the widget, returning a Surface
    pub fn draw(self: Widget, ctx: DrawContext) Allocator.Error!Surface {
        return self.drawFn(self.userdata, ctx);
    }
};
```

Any concrete widget provides a `widget()` method that returns a type-erased `Widget`:

```zig
const Center = struct {
    child: vxfw.Widget,

    pub fn widget(self: *const Center) vxfw.Widget {
        return .{
            .userdata = @ptrCast(@constCast(self)),
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedDrawFn(userdata: *anyopaque, ctx: DrawContext) !Surface {
        const self: *const Center = @ptrCast(@alignCast(userdata));
        return self.draw(ctx);
    }

    fn draw(self: *const Center, ctx: DrawContext) !Surface {
        const child_surface = try self.child.draw(ctx.withConstraints(.{}, ctx.max));
        // Center the child within available space
        const x = (ctx.max.width -| child_surface.size.width) / 2;
        const y = (ctx.max.height -| child_surface.size.height) / 2;
        return Surface{
            .size = ctx.max,
            .children = &.{.{ .origin = .{ .x = x, .y = y }, .surface = child_surface }},
        };
    }
};
```

**Key point:** Zig's comptime duck typing here (any type with the right method signatures
becomes a widget) is structurally identical to D's Design by Introspection. The `Widget`
struct is a manually constructed vtable -- Zig does not have interfaces, so type erasure is
built by hand using `*anyopaque` and function pointers. D can achieve the same pattern more
ergonomically with template constraints.

### Built-In Widgets

**Low-level API widgets** (`src/widgets/`):

| Widget        | Purpose                                        |
| ------------- | ---------------------------------------------- |
| `TextInput`   | Single-line text input with cursor and editing |
| `Table`       | Generic table rendering from struct data       |
| `ScrollView`  | Scrollable content container                   |
| `Scrollbar`   | Visual scroll position indicator               |
| `TextView`    | Multi-line text display                        |
| `CodeView`    | Syntax-aware code display with line numbers    |
| `LineNumbers` | Line number column                             |
| `View`        | Base container widget                          |
| `alignment`   | Positioning helpers (center, topLeft, etc.)    |
| `Terminal`    | Embedded terminal emulator widget              |

**vxfw framework widgets** (`src/vxfw/`):

| Widget       | Purpose                                      |
| ------------ | -------------------------------------------- |
| `FlexRow`    | Horizontal flex layout (proportional widths) |
| `FlexColumn` | Vertical flex layout (proportional heights)  |
| `Border`     | Decorative border wrapper                    |
| `Center`     | Center a child within available space        |
| `Padding`    | Add spacing around a child                   |
| `SizedBox`   | Fix a child to specific dimensions           |
| `SplitView`  | Two-pane split with adjustable divider       |
| `ScrollView` | Scrollable container with scroll bars        |
| `ListView`   | Virtualized list for large datasets          |
| `Text`       | Basic text rendering                         |
| `RichText`   | Styled text with inline formatting           |
| `TextField`  | Text input field                             |
| `Button`     | Clickable button with event handler          |
| `Spinner`    | Animated loading indicator                   |

---

## Styling

### Cell Struct

Each terminal cell is represented by a `Cell` struct:

```zig
pub const Cell = struct {
    char: Character = .{},
    style: Style = .{},
    link: Hyperlink = .{},
    image: ?Image.Placement = null,
    default: bool = false,
    wrapped: bool = false,
};

pub const Character = struct {
    grapheme: []const u8 = " ",  // UTF-8 bytes, may be multi-codepoint
    width: u8 = 1,               // display width in columns
};
```

The `grapheme` field stores a byte slice, not a single codepoint. This correctly handles
multi-codepoint grapheme clusters (emoji with ZWJ sequences, combining characters, etc.).
The `width` field stores the pre-computed East Asian width for the grapheme.

### Style

```zig
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,          // underline color (separate from text color)
    ul_style: Underline = .off,    // off, single, double, curly, dotted, dashed
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};
```

### Color

```zig
pub const Color = union(enum) {
    default,             // terminal default foreground/background
    index: u8,           // 256-color palette index
    rgb: [3]u8,          // 24-bit true color [r, g, b]
};
```

No palette abstraction or named colors. Direct values. This avoids the overhead of color
resolution at render time.

### Hyperlink

```zig
pub const Hyperlink = struct {
    uri: []const u8 = "",
    params: []const u8 = "",  // OSC 8 parameters (e.g., id=...)
};
```

### Usage Example

```zig
const style: vaxis.Style = .{
    .fg = .{ .rgb = .{ 0, 255, 128 } },
    .bg = .{ .index = 236 },
    .bold = true,
    .ul = .{ .rgb = .{ 255, 0, 0 } },
    .ul_style = .curly,
};

win.writeCell(.{
    .char = .{ .grapheme = "A", .width = 1 },
    .style = style,
    .link = .{ .uri = "https://example.com" },
});
```

---

## Event Handling

### Tagged Union Events

libvaxis represents events as a Zig tagged union. The internal `Event` type covers all
possible terminal events:

```zig
pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    mouse_leave,
    focus_in,
    focus_out,
    paste_start,
    paste_end,
    paste: []const u8,
    color_report: Color.Report,
    color_scheme: Color.Scheme,
    winsize: Winsize,
    // Capability detection results
    cap_kitty_keyboard,
    cap_kitty_graphics,
    cap_rgb,
    cap_sgr_pixels,
    cap_unicode,
    cap_da1,
    cap_color_scheme_updates,
};
```

### Key Events

```zig
pub const Key = struct {
    codepoint: u21,                    // Unicode codepoint
    shifted_codepoint: ?u21 = null,    // codepoint with shift applied
    base_layout_codepoint: ?u21 = null, // layout-independent codepoint
    mods: Modifiers = .{},
    text: ?[]const u8 = null,          // generated text (if any)
};

pub const Modifiers = packed struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};
```

The Kitty keyboard protocol provides press, release, and repeat events as separate union
variants (`key_press` vs `key_release`), full modifier tracking including Super/Hyper/Meta,
and the `shifted_codepoint` field for disambiguating shifted keys. The `text` field contains
the actual text generated by the key event, which may differ from the codepoint (e.g., for
dead keys or input methods).

### Mouse Events

```zig
pub const Mouse = struct {
    col: i16,
    row: i16,
    xoffset: u16 = 0,  // sub-cell pixel offset (SGR pixel mode)
    yoffset: u16 = 0,
    button: Button,
    mods: Modifiers,
    type: Type,

    pub const Button = enum { left, middle, right, wheel_up, wheel_down, ... };
    pub const Type = enum { press, release, motion, drag };
    pub const Modifiers = packed struct { shift: bool, alt: bool, ctrl: bool };
};
```

When SGR pixel mode is available, `xoffset` and `yoffset` provide sub-cell precision for
mouse events, enabling precise hit testing within grapheme clusters or images.

### Event Loop Example

```zig
while (true) {
    const event = loop.nextEvent();  // blocking wait

    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                break;  // Ctrl+C to exit
            }
            if (key.matches('l', .{ .ctrl = true })) {
                vx.queueRefresh();  // Ctrl+L to refresh
            }
            try text_input.update(.{ .key_press = key });
        },
        .winsize => |ws| {
            try vx.resize(alloc, &tty, ws);
        },
        .mouse => |mouse| {
            if (win.hasMouse(mouse)) {
                // Mouse is within this window's bounds
            }
        },
        else => {},
    }

    // Render after handling all available events
    const win = vx.window();
    win.clear();
    text_input.draw(win);
    try vx.render(&tty);
}
```

Zig's `switch` on tagged unions is exhaustive: if you do not handle a variant and do not
include an `else` branch, the code will not compile. This is a compile-time guarantee that
all event types are considered.

---

## State Management

libvaxis is purely imperative. The application owns all state. There is no framework-imposed
architecture, no model-view separation, no signals, no reactive bindings.

### Low-Level API

State management is entirely ad-hoc. The application struct holds whatever fields it needs,
mutates them in response to events, and renders from them:

```zig
const App = struct {
    counter: u32 = 0,
    text_input: TextInput,
    running: bool = true,

    fn handleEvent(self: *App, event: Event) void {
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{})) self.running = false;
                if (key.matches(vaxis.Key.up, .{})) self.counter += 1;
            },
            else => {},
        }
    }

    fn render(self: *App, win: Window) void {
        win.clear();
        // Draw UI based on current state
    }
};
```

### vxfw Framework

The `vxfw` framework provides an `App` runtime that manages the event loop, focus tracking,
and frame timing (default 60 FPS). State is still application-managed, but the framework
provides structure:

- **`eventHandler`**: Called for each event, receives an `EventContext` for issuing commands
  (redraw, focus change, set cursor, etc.).
- **`drawFn`**: Called to produce a `Surface` with layout constraints.
- **Arena allocation**: Per-frame arena for temporary allocations (formatted text, layout
  scratch space). Freed automatically at frame end.

```zig
const Model = struct {
    counter: u32 = 0,
    button: vxfw.Button,

    fn eventHandler(self: *Model, ctx: *EventContext) !void {
        switch (ctx.event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
            },
            else => {},
        }
    }

    fn drawFn(self: *Model, ctx: DrawContext) !Surface {
        const label = try std.fmt.allocPrint(ctx.arena, "Count: {}", .{self.counter});
        // Return Surface with children
    }
};
```

Zig's explicit memory management means every allocation is visible. There are no hidden
heap allocations, no GC pauses, no reference counting. The developer sees exactly where
memory is allocated and when it is freed.

---

## Extensibility and Ecosystem

### Ecosystem

libvaxis's ecosystem is small but growing, anchored by high-profile users:

- **Ghostty** -- Mitchell Hashimoto's GPU-accelerated terminal emulator uses libvaxis as a
  dependency for its TUI rendering layer.
- **Superhtml** -- An HTML tool built with libvaxis.
- The Zig community is active on **#vaxis on libera.chat IRC** and GitHub Discussions.

### Package Integration

libvaxis is distributed via the Zig package manager:

```bash
zig fetch --save git+https://github.com/rockorager/libvaxis.git
```

Then in `build.zig`:

```zig
const vaxis_dep = b.dependency("vaxis", .{});
exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
```

### C API

A C API wrapper is available for non-Zig consumers, enabling use from C, C++, or any
language with C FFI. This broadens the library's reach beyond the Zig ecosystem.

### Unicode Tables

libvaxis bundles its own Unicode data tables (via the `uucode` dependency) for grapheme
cluster breaking, East Asian width calculation, and emoji detection. This avoids depending
on the system's ICU or locale configuration.

---

## Strengths

- **comptime type safety without runtime overhead.** Generic event types, duck-typed widgets,
  compile-time table column generation, and `@hasField`-based event filtering all resolve at
  compile time. The emitted machine code is fully monomorphized.

- **Explicit allocator control.** Every allocation site accepts an `Allocator` parameter.
  Applications can use arena allocators for per-frame temporaries, fixed-buffer allocators
  for `@nogc`-style operation, or custom allocators for profiling and debugging.

- **Modern terminal features are first-class.** Kitty keyboard protocol, Kitty graphics,
  SGR pixel mouse, styled underlines, hyperlinks, and synchronized output are not
  afterthoughts bolted onto a legacy abstraction -- they are the primary API surface.

- **Small and focused.** The library has a clear scope (terminal UI) and does not attempt to
  be a framework, an async runtime, or a widget toolkit. The low-level API gives full
  control; the vxfw framework is opt-in.

- **No terminfo dependency.** Runtime capability detection means correct behavior on any
  terminal, including over SSH, in containers, and on systems without terminfo databases.

- **Fast compilation.** Zig compiles quickly, and libvaxis has minimal dependencies. Build
  times are measured in seconds, not minutes.

- **Cross-platform.** macOS, Linux, BSD, and Windows are supported from a single codebase.

- **Panic-safe terminal restoration.** A custom panic handler resets the terminal (exits alt
  screen, restores cursor, disables raw mode) before crashing, preventing corrupted terminal
  state.

- **Double-buffered differential rendering.** Only changed cells are written to the terminal,
  minimizing I/O and preventing flicker (especially with synchronized output mode).

---

## Weaknesses and Limitations

- **Manual layout.** The low-level API has no layout engine at all. Even the vxfw flex
  widgets are basic compared to CSS flexbox or Ratatui's constraint solver. Complex layouts
  require manual coordinate arithmetic.

- **Zig language instability.** Zig has not reached 1.0. The language and standard library
  change between versions. libvaxis targets Zig 0.15.1 specifically and may require updates
  for future Zig releases. This is a risk for long-lived projects.

- **Small ecosystem.** Compared to Ratatui (12,700+ dependents) or ncurses, the libvaxis
  ecosystem is tiny. There are few third-party widgets, no template generators, and limited
  learning resources beyond the source code and examples.

- **Targets modern terminals.** Terminals that do not support the Kitty keyboard protocol or
  SGR mouse fall back to degraded functionality. This is a deliberate design choice but
  limits compatibility with older or minimal terminals (e.g., the Linux console, very old
  xterm builds).

- **Limited built-in widgets.** The low-level widget set covers basics (text input, table,
  scroll view) but lacks a tree view, tabs, progress bar, chart, or other common components.
  The vxfw set is more complete but still growing.

- **Documentation is code-focused.** There is no prose tutorial or conceptual guide. The
  documentation is auto-generated API docs plus example programs. Learning the library
  requires reading source code.

- **Type erasure is manual.** Zig lacks interfaces and traits, so the vxfw widget protocol
  requires manual vtable construction with `*anyopaque` and function pointers. This is
  verbose and error-prone compared to Rust traits or D template constraints.

- **No retained mode option.** Every frame redraws from scratch. For UIs with expensive
  widget construction, there is no built-in mechanism to cache subtrees.

---

## Lessons for D / Sparkles

Zig and D share fundamental design goals: compile-time execution of arbitrary code, explicit
control over memory allocation, zero-cost generic programming, and systems-level performance.
libvaxis is the most directly relevant TUI library for Sparkles' design because the patterns
translate almost one-to-one.

### comptime -> CTFE

Zig's `comptime` and D's CTFE (Compile-Time Function Evaluation) serve the same purpose:
execute arbitrary code at compile time to generate specialized runtime code.

**Zig pattern -- comptime event filtering:**

```zig
fn handleEventGeneric(comptime Event: type, raw: RawEvent) ?Event {
    if (@hasField(Event, "key_press")) {
        if (raw.isKeyPress()) return Event{ .key_press = raw.toKey() };
    }
    // Only generates code for declared event variants
}
```

**D equivalent -- CTFE + `static if`:**

```d
Event handleEvent(Event)(RawEvent raw)
{
    static if (__traits(hasMember, Event, "keyPress"))
    {
        if (raw.isKeyPress)
            return Event(Event.Kind.keyPress, raw.toKey);
    }
    // Only generates code for declared event variants
}
```

D can go further than Zig's comptime with **string mixins** and **CTFE evaluation of
arbitrary expressions**. For example, D can generate an entire event dispatch table at
compile time from a list of handler function names:

```d
/// Generate a dispatch switch at compile time from handler method names.
enum generateDispatch(Handlers...) = {
    string code = "switch (event.kind) {\n";
    static foreach (H; Handlers)
        code ~= "    case Event.Kind." ~ H.name ~ ": "
              ~ H.name ~ "Handler(event); break;\n";
    code ~= "    default: break;\n}\n";
    return code;
}();

// Usage:
mixin(generateDispatch!(onKeyPress, onMouse, onResize));
```

### Explicit Allocators -> D's @nogc + SmallBuffer

Zig passes allocators explicitly to every function that allocates:

```zig
var vx = try vaxis.init(alloc, .{});
var text_input = TextInput.init(alloc);
const label = try std.fmt.allocPrint(ctx.arena, "Count: {}", .{count});
```

D achieves similar control through a combination of mechanisms:

1. **`@nogc` attribute** -- Enforces at the type level that a function cannot use the GC.
   This is arguably more ergonomic than explicit allocator passing because it is checked by
   the compiler rather than by convention.

2. **`SmallBuffer`** -- Sparkles' existing `SmallBuffer` provides inline allocation with
   heap fallback, similar to Zig's `std.ArrayList` but with a small-buffer optimization
   that avoids allocation entirely for typical sizes.

3. **Scoped allocators via D's `scope`** -- D's `scope` and `-preview=dip1000` enable
   stack-like allocation disciplines similar to Zig's arena pattern.

```d
@safe pure nothrow @nogc:

/// Arena-style per-frame allocation using SmallBuffer.
struct FrameArena
{
    SmallBuffer!(ubyte, 4096) storage;

    T[] alloc(T)(size_t count) return
    {
        auto bytes = storage.extendUnsafe(count * T.sizeof);
        return (cast(T*) bytes.ptr)[0 .. count];
    }

    void reset() { storage.clear(); }
}

void renderFrame(ref FrameArena arena, ref Screen screen)
{
    // All allocations come from the arena, freed at frame end
    auto cells = arena.alloc!Cell(screen.width * screen.height);
    // ...
    arena.reset();  // zero-cost "free all"
}
```

The key difference: D's approach is **attribute-based** (`@nogc` is enforced by the compiler
globally) while Zig's is **parameter-based** (allocator must be threaded through every call
site). D's approach catches violations at compile time even in code you did not write;
Zig's approach gives more flexibility in choosing different allocators per call site.

### Duck-Typed Widgets -> Design by Introspection (DbI)

Zig's widget pattern relies on "any type with the right methods":

```zig
// Any type with a draw method can be used as a widget
text_input.draw(window);
table.drawTable(window, data);
```

In the vxfw framework, type erasure is manual:

```zig
pub fn widget(self: *const Center) vxfw.Widget {
    return .{
        .userdata = @ptrCast(@constCast(self)),
        .drawFn = typeErasedDrawFn,
    };
}
```

D's Design by Introspection achieves this more directly:

```d
/// Compile-time widget concept -- no interface, no vtable.
enum isWidget(T) = __traits(hasMember, T, "draw")
    && is(typeof((T w, Window win) { w.draw(win); }));

/// Optional capabilities detected at compile time.
enum isInteractiveWidget(T) = isWidget!T
    && __traits(hasMember, T, "handleEvent");

/// Render any widget -- monomorphized, zero overhead.
void renderWidget(W)(ref W widget, Window win)
if (isWidget!W)
{
    widget.draw(win);
}

/// Dispatch events with optional handler.
void dispatchEvent(W)(ref W widget, Event event)
if (isWidget!W)
{
    static if (isInteractiveWidget!W)
        widget.handleEvent(event);
    // else: silently skip -- widget does not handle events
}
```

This is structurally identical to Zig's pattern but with two advantages:

1. **No manual vtable construction.** D's templates monomorphize automatically; there is no
   need to cast through `*anyopaque` and build function pointer tables by hand.
2. **`static if` for optional capabilities.** D can check for optional methods at compile
   time and generate different code paths, exactly like Zig's `@hasField` but integrated
   into the template system.

### Tagged Union Events -> D's SumType

Zig's tagged unions:

```zig
const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    focus_in,
    focus_out,
    winsize: Winsize,
};

switch (event) {
    .key_press => |key| { ... },
    .winsize => |ws| { ... },
    else => {},
}
```

D equivalent with `std.sumtype.SumType`:

```d
import std.sumtype : SumType;

alias Event = SumType!(
    KeyPress,
    KeyRelease,
    Mouse,
    FocusIn,
    FocusOut,
    Winsize,
);

event.match!(
    (KeyPress key)  => handleKeyPress(key),
    (Winsize ws)    => handleResize(ws),
    (_)             => {},  // default case
);
```

Both provide exhaustive matching (the compiler errors if a variant is unhandled without a
default branch). D's `match!` uses lambdas, which is slightly more verbose but composes
well with UFCS chains. D also allows pattern matching with `static if` and `is()` checks
for more complex dispatch logic.

### Cell Struct -> D Struct with SmallBuffer

Zig's `Cell` with its `Character` containing a `[]const u8` grapheme maps directly to D:

```d
@safe pure nothrow @nogc:

struct Character
{
    SmallBuffer!(char, 16) grapheme;  // inline storage for typical graphemes
    ubyte width = 1;                  // East Asian display width

    this(string s, ubyte w = 1)
    {
        grapheme ~= s;
        width = w;
    }
}

struct Style
{
    Color fg = Color.init;
    Color bg = Color.init;
    Color ul = Color.init;
    UnderlineStyle ulStyle = UnderlineStyle.off;
    bool bold, dim, italic, blink, reverse, invisible, strikethrough;
}

struct Cell
{
    Character ch;
    Style style;
    string hyperlink;     // OSC 8 URI
}
```

The `SmallBuffer!(char, 16)` stores most grapheme clusters (even complex emoji sequences
like family emoji are under 16 bytes of UTF-8) inline without heap allocation. This mirrors
Zig's approach where the grapheme is a byte slice, but with D's small-buffer optimization
to avoid the need for an external allocator for typical cases.

### Window as Buffer Slice -> Typed Slice with Bounds Checking

Zig's `Window` is a view into a `Screen`'s cell buffer with offset and dimensions:

```zig
const Window = struct {
    x_off: u16,
    y_off: u16,
    width: u16,
    height: u16,
    screen: *Screen,
};
```

D equivalent with `@safe` bounds checking:

```d
@safe pure nothrow @nogc:

struct Window
{
    ushort xOff, yOff;
    ushort width, height;
    Screen* screen;

    /// Write a cell with automatic bounds checking.
    void writeCell(ushort x, ushort y, Cell cell)
    in (x < width, "x out of bounds")
    in (y < height, "y out of bounds")
    {
        screen.buf[(yOff + y) * screen.width + (xOff + x)] = cell;
    }

    /// Create a child window with relative positioning.
    Window child(ChildOpts opts) const
    {
        import std.algorithm : min;
        return Window(
            xOff: cast(ushort)(xOff + opts.xOff),
            yOff: cast(ushort)(yOff + opts.yOff),
            width: cast(ushort) min(opts.width, width - opts.xOff),
            height: cast(ushort) min(opts.height, height - opts.yOff),
            screen: screen,
        );
    }
}
```

D's expression-based contracts (`in (x < width, "x out of bounds")`) provide the same
bounds safety as Zig's runtime checks but with more descriptive error messages and the
ability to be disabled in release builds.

### No Terminfo -> Direct Escape Sequences with C Interop Fallback

libvaxis generates escape sequences directly and queries the terminal for capabilities.
D could follow the same approach:

```d
/// Direct escape sequence generation -- no terminfo dependency.
@safe pure nothrow @nogc:

enum CtlSeqs : string
{
    enterAltScreen = "\x1b[?1049h",
    exitAltScreen  = "\x1b[?1049l",
    syncStart      = "\x1b[?2026h",
    syncEnd        = "\x1b[?2026l",
    curlyUnderline = "\x1b[4:3m",
}

/// Query terminal capabilities via escape sequence round-trip.
Capabilities queryTerminal(ref Tty tty, Duration timeout)
{
    tty.write("\x1b[?u");  // Query Kitty keyboard support
    tty.write("\x1b[c");   // DA1 query
    // Parse responses within timeout...
}
```

For legacy terminals, D's seamless C interop enables fallback to terminfo without a
separate binding layer:

```d
/// Fallback to terminfo via D's C interop.
extern(C) int setupterm(const(char)* term, int fildes, int* errret);
extern(C) const(char)* tigetstr(const(char)* capname);

string getTerminfoCapability(string cap)
{
    auto result = tigetstr(cap.toStringz);
    if (result is null || result == cast(const(char)*) -1)
        return null;
    return result.fromStringz.idup;
}
```

This hybrid approach gives the best of both worlds: modern terminals get direct protocol
support (fast, no dependency), while legacy terminals fall back to terminfo through D's
zero-cost C FFI.

---

## References

- **GitHub Repository:** <https://github.com/rockorager/libvaxis>
- **API Documentation:** <https://rockorager.github.io/libvaxis/>
- **Zig Package Registry (Zigistry):** <https://zigistry.dev/programs/github/rockorager/libvaxis/>
- **Ziggit Community Discussion:** <https://ziggit.dev/t/libvaxis-a-modern-tui-library/4380>
- **IRC Channel:** `#vaxis` on libera.chat
- **Key Source Files:**
  - Vaxis core: `src/Vaxis.zig`
  - Cell/Style: `src/Cell.zig`
  - Window: `src/Window.zig`
  - Event types: `src/event.zig`
  - Key input: `src/Key.zig`
  - Mouse input: `src/Mouse.zig`
  - Control sequences: `src/ctlseqs.zig`
  - Event loop: `src/Loop.zig`
  - Screen buffer: `src/Screen.zig`, `src/InternalScreen.zig`
  - vxfw framework: `src/vxfw/vxfw.zig`, `src/vxfw/App.zig`
- **Notable Users:**
  - Ghostty terminal emulator: <https://github.com/ghostty-org/ghostty>
- **Related Protocols:**
  - Kitty keyboard protocol: <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>
  - Kitty graphics protocol: <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
  - OSC 8 hyperlinks: <https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda>
