# Notcurses (C)

A modern, high-performance terminal UI library that reimagines TUI programming from scratch, exploiting the full capabilities of contemporary terminal emulators rather than constraining itself to the lowest common denominator.

| Field              | Value                                                                                                                                     |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**       | C (C17), with C++17 optional components                                                                                                   |
| **License**        | Apache 2.0                                                                                                                                |
| **Repository**     | [github.com/dankamongmen/notcurses](https://github.com/dankamongmen/notcurses)                                                            |
| **Documentation**  | [notcurses.com](https://notcurses.com) (man pages), [nick-black.com/dankwiki](https://nick-black.com/dankwiki/index.php/Notcurses) (wiki) |
| **Latest Version** | ~3.0.17 (October 2024)                                                                                                                    |
| **GitHub Stars**   | ~4.3k                                                                                                                                     |

---

## Overview

### What It Solves

Notcurses provides a modern foundation for building complex terminal user interfaces that go far beyond what ncurses (or any X/Open Curses implementation) can offer. Where ncurses assumes the terminal is a VT100-era device and requires developers to opt into each advanced feature individually, Notcurses assumes the terminal is a modern emulator capable of 24-bit color, Unicode, bitmap graphics, and advanced keyboard protocols -- then gracefully degrades when it encounters limitations.

The library addresses several long-standing deficiencies in the terminal UI ecosystem:

- **True color**: 24-bit RGB as the default, with automatic quantization for limited terminals.
- **Bitmap graphics**: Sixel, Kitty graphics protocol, and Linux framebuffer for actual pixel-level rendering within the terminal.
- **Unicode completeness**: Full Extended Grapheme Cluster (EGC) support, wide characters, and emoji.
- **Thread safety**: Designed from inception for concurrent access, unlike ncurses which requires external synchronization.
- **Multimedia**: Video playback and image rendering directly in the terminal via FFmpeg integration.

### Design Philosophy

Notcurses deliberately abandons the X/Open Curses API. It is **not** an ncurses wrapper, not a source-compatible replacement, and not constrained by decades of backward-compatibility baggage. The core philosophy is stated directly in the project documentation:

> Notcurses assumes the maximum and steps down (by itself) when necessary.

This is the inverse of ncurses, which assumes the minimum and steps up only when explicitly asked. The result is a library that can exploit every capability a modern terminal offers while still functioning (with reduced fidelity) on older terminals.

### History

Notcurses was created by **Nick Black**, a systems programmer, author, and former Googler. Development began around 2019 as a clean-room reimagining of what a terminal UI library should look like in the era of GPU-accelerated terminal emulators like Kitty, Alacritty, and WezTerm. The library reached its 1.0 release and has since evolved through major versions, with the 3.x series representing the current stable API. Nick Black also authored _Hacking the Planet with Notcurses_, a comprehensive guidebook available as both a free PDF and paperback.

---

## Architecture

### Rendering Model

Notcurses uses a **retained-mode rendering model** built around the concept of **planes** (`ncplane`). The architecture is a compositor: the library maintains a stack of overlapping rectangular drawing surfaces, and on each render call, composites them together (including alpha blending) to produce the final frame. It then diffs against the previous frame and emits only the minimal set of terminal escape sequences needed to update the display.

### Core Structures

- **`struct notcurses`** -- The top-level context. Represents the connection to a terminal and owns all associated state. Created with `notcurses_init()`, destroyed with `notcurses_stop()`. A program typically has exactly one.

- **`struct ncplane`** -- The fundamental drawing surface. A rectangular region of cells that can be positioned, resized, and layered. Planes are organized into **piles** (independent z-ordered stacks). Each pile has its own render/rasterize cycle.

- **`struct nccell`** -- A single cell on a plane. Contains a grapheme cluster (UTF-8 encoded, 32-bit packed or spilled to storage), a 16-bit style mask, and 64-bit channels (32-bit foreground + 32-bit background, each with RGB + alpha).

- **`struct ncinput`** -- An input event. Carries a Unicode codepoint (or synthesized key constant), mouse coordinates, modifier flags, and event type (press/repeat/release).

### The Standard Plane

When a `notcurses` context is created, a **standard plane** is automatically allocated. It spans the entire terminal and sits at the bottom of the default pile. It cannot be destroyed and is always available via `notcurses_stdplane()`.

### Render Pipeline

```
Application draws to planes
        |
        v
ncpile_render()  -- composites all planes in the pile,
                    producing a flattened cell grid
        |
        v
ncpile_rasterize() -- diffs against previous frame,
                      emits escape sequences to terminal
```

The convenience function `notcurses_render()` performs both steps for the standard pile. Separating render from rasterize allows the application to inspect the composed frame before committing it to the terminal.

```c
#include <notcurses/notcurses.h>

int main(void) {
    // Initialize with default options
    struct notcurses* nc = notcurses_init(NULL, stdout);
    if (nc == NULL) return 1;

    // Get the standard plane
    struct ncplane* std = notcurses_stdplane(nc);

    // Draw on the standard plane
    ncplane_set_fg_rgb8(std, 0x00, 0xff, 0x00);  // green foreground
    ncplane_putstr_yx(std, 0, 0, "Hello, Notcurses!");

    // Render to terminal
    notcurses_render(nc);

    // Wait for input
    notcurses_get_blocking(nc, NULL);

    // Cleanup
    notcurses_stop(nc);
    return 0;
}
```

---

## Terminal Backend

### Direct Terminal Manipulation

Notcurses communicates directly with the terminal via escape sequences. It does not use ncurses for rendering; however, it does leverage ncurses' **terminfo** database (6.1+) for baseline capability detection. On top of terminfo, Notcurses performs **runtime terminal interrogation**: it sends query sequences to the terminal and parses responses to discover capabilities dynamically.

### Capability Detection

The library combines multiple strategies:

1. **Terminfo database** -- baseline capabilities (colors, cursor movement, etc.)
2. **`COLORTERM` environment variable** -- `truecolor` or `24bit` signals 24-bit color support
3. **Terminal query responses** -- DA1/DA2/DA3 device attribute queries, XTVERSION, Kitty keyboard protocol probes
4. **`TERM` and `TERM_PROGRAM`** -- terminal identification for known-good feature sets

The included `notcurses-info` tool reports detected capabilities for any terminal.

### Supported Capabilities

| Capability                  | Details                                                                                                                                                                  |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **True color**              | 24-bit RGB (16.7M colors), auto-quantized to 256 or 8 when needed                                                                                                        |
| **Sixel graphics**          | Pixel-level bitmap rendering on Sixel-capable terminals                                                                                                                  |
| **Kitty graphics protocol** | High-performance pixel graphics with animation support                                                                                                                   |
| **Unicode**                 | Full EGC support, wide characters, combining characters, emoji                                                                                                           |
| **Video/multimedia**        | MPEG4 and other video codecs via FFmpeg, rendered as frames in the terminal                                                                                              |
| **Mouse**                   | Button press/release, motion tracking, scroll events                                                                                                                     |
| **Kitty keyboard protocol** | Disambiguated key events with press/repeat/release distinction                                                                                                           |
| **Blitting modes**          | Multiple character-based bitmap approximations: half-blocks (`2x1`), quadrants (`2x2`), sextants (`3x2`), octants (`4x2`), Braille (`BRAILLE`), and true pixel (`PIXEL`) |
| **Alpha blending**          | Per-cell alpha: opaque, transparent, blend, high-contrast                                                                                                                |

### Performance

Notcurses is designed for high throughput. The frame-diffing approach means only changed cells produce escape sequences. Header-only static inline functions minimize call overhead. The library is thread-safe, allowing concurrent plane manipulation with rendering on a dedicated thread. Benchmark-oriented design choices pervade the codebase -- for example, glyph clusters are packed inline in the 32-bit `gcluster` field of `nccell` when they fit, avoiding heap allocation for the common case of ASCII and BMP characters.

---

## Layout System

### Manual / Absolute Positioning

Notcurses does **not** provide an automatic layout engine. All positioning is explicit. Planes have:

- **y/x position** -- relative to parent plane (for child planes) or absolute within the pile (for root planes)
- **rows/columns dimensions** -- the size of the plane's cell grid

This is fundamentally different from CSS-based or constraint-based layout systems. The application is responsible for computing positions and sizes, typically in response to terminal resize events.

### Key Layout Functions

```c
// Query plane dimensions
unsigned rows, cols;
ncplane_dim_yx(plane, &rows, &cols);

// Move plane to new position (relative to parent)
ncplane_move_yx(plane, new_y, new_x);

// Resize a plane, preserving a region of existing content
// Parameters: keep_y, keep_x, keep_len_y, keep_len_x,
//             y_off, x_off, new_rows, new_cols
ncplane_resize(plane, 0, 0, 0, 0, 0, 0, new_rows, new_cols);

// Get absolute position on screen
int abs_y, abs_x;
ncplane_abs_yx(plane, &abs_y, &abs_x);
```

### Plane Hierarchy

Child planes are positioned relative to their parent. When a parent moves, all children move with it. This provides a basic form of relative layout:

```c
#include <notcurses/notcurses.h>

int main(void) {
    struct notcurses* nc = notcurses_init(NULL, stdout);
    struct ncplane* std = notcurses_stdplane(nc);

    unsigned term_rows, term_cols;
    ncplane_dim_yx(std, &term_rows, &term_cols);

    // Create a "panel" plane centered on screen
    struct ncplane_options panel_opts = {
        .y = (int)(term_rows / 4),
        .x = (int)(term_cols / 4),
        .rows = term_rows / 2,
        .cols = term_cols / 2,
        .name = "panel",
    };
    struct ncplane* panel = ncplane_create(std, &panel_opts);
    ncplane_set_bg_rgb8(panel, 0x20, 0x20, 0x40);

    // Fill panel background
    for (unsigned y = 0; y < panel_opts.rows; y++) {
        for (unsigned x = 0; x < panel_opts.cols; x++) {
            ncplane_putchar_yx(panel, y, x, ' ');
        }
    }

    // Create a title bar as a child plane (position relative to panel)
    struct ncplane_options title_opts = {
        .y = 0,
        .x = 0,
        .rows = 1,
        .cols = panel_opts.cols,
        .name = "title",
    };
    struct ncplane* title = ncplane_create(panel, &title_opts);
    ncplane_set_fg_rgb8(title, 0xff, 0xff, 0xff);
    ncplane_set_bg_rgb8(title, 0x40, 0x40, 0x80);
    ncplane_putstr_aligned(title, 0, NCALIGN_CENTER, " My Panel ");

    // Create a status bar at the bottom of the panel
    struct ncplane_options status_opts = {
        .y = (int)(panel_opts.rows - 1),
        .x = 0,
        .rows = 1,
        .cols = panel_opts.cols,
        .name = "status",
    };
    struct ncplane* status = ncplane_create(panel, &status_opts);
    ncplane_set_fg_rgb8(status, 0xaa, 0xaa, 0xaa);
    ncplane_set_bg_rgb8(status, 0x30, 0x30, 0x50);
    ncplane_putstr_yx(status, 0, 1, "Press 'q' to quit");

    notcurses_render(nc);

    // Event loop
    struct ncinput ni;
    while (notcurses_get_blocking(nc, &ni) != (uint32_t)-1) {
        if (ni.id == 'q') break;
    }

    notcurses_stop(nc);
    return 0;
}
```

### Resize Callbacks

Planes can have resize callbacks that fire when the terminal is resized. This is the primary mechanism for responsive layout:

```c
// Callback signature
int resize_cb(struct ncplane* plane);

// Common built-in callbacks:
// ncplane_resize_maximize   -- resize to fill parent
// ncplane_resize_marginalized -- resize with fixed margins
```

---

## Widget / Component System

Notcurses provides a set of high-level **widget** types, each backed by one or more planes. Widgets are opaque structs created via `*_create()` functions and destroyed with `*_destroy()`. They receive input via `*_offer_input()` functions.

### Built-in Widgets

| Widget                               | Description                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| **`ncselector`**                     | Single-selection scrollable menu with title, footer, and descriptions          |
| **`ncmultiselector`**                | Multi-selection variant of `ncselector` with checkbox-style toggling           |
| **`ncmenu`**                         | Top-of-screen menu bar with dropdown sub-menus and keyboard shortcuts          |
| **`nctree`**                         | Hierarchical tree view with expandable/collapsible nodes                       |
| **`ncplot` / `ncuplot` / `ncdplot`** | Line/scatter plots for `uint64_t` or `double` data streams                     |
| **`ncprogbar`**                      | Progress bar with configurable direction and EGC fill characters               |
| **`nctabbed`**                       | Tabbed interface with a tab bar and per-tab content planes                     |
| **`ncreader`**                       | Text input widget with cursor movement and editing                             |
| **`ncreel`**                         | Scrollable "card stack" (reel of tablets) for browsing variable-height content |

### Widget Example: Selector

```c
#include <notcurses/notcurses.h>

int main(void) {
    struct notcurses* nc = notcurses_init(NULL, stdout);
    struct ncplane* std = notcurses_stdplane(nc);

    // Define selector items
    struct ncselector_item items[] = {
        { .option = "Option A", .desc = "First option" },
        { .option = "Option B", .desc = "Second option" },
        { .option = "Option C", .desc = "Third option" },
    };

    // Configure the selector
    struct ncselector_options sopts = {
        .title = "Select an item",
        .items = items,
        .itemcount = 3,
        .maxdisplay = 5,
        .opchannels = NCCHANNELS_INITIALIZER(0xff, 0xff, 0xff,
                                              0x20, 0x20, 0x20),
        .descchannels = NCCHANNELS_INITIALIZER(0xaa, 0xaa, 0xaa,
                                                0x20, 0x20, 0x20),
        .titlechannels = NCCHANNELS_INITIALIZER(0x00, 0xff, 0x00,
                                                 0x20, 0x20, 0x20),
        .boxchannels = NCCHANNELS_INITIALIZER(0x80, 0x80, 0x80,
                                               0x20, 0x20, 0x20),
    };

    struct ncselector* sel = ncselector_create(std, &sopts);
    notcurses_render(nc);

    // Feed input to the selector
    struct ncinput ni;
    while (notcurses_get_blocking(nc, &ni) != (uint32_t)-1) {
        if (ni.id == 'q') break;
        if (ni.id == NCKEY_ENTER) {
            const char* selected = ncselector_selected(sel);
            // Use selected item...
            break;
        }
        ncselector_offer_input(sel, &ni);
        notcurses_render(nc);
    }

    ncselector_destroy(sel, NULL);
    notcurses_stop(nc);
    return 0;
}
```

### Custom Widgets

There is no formal widget protocol or base class. Custom widgets are built by drawing directly on `ncplane` surfaces. The pattern is:

1. Create one or more planes for the widget.
2. Draw the widget's visual representation on those planes.
3. Accept input and update the planes accordingly.
4. Attach user data via `ncplane_set_userptr()` for associating application state with planes.

---

## Styling

### Cell-Based Model

Every cell on a plane has three styling components:

1. **Foreground channel** (32 bits) -- 8-bit R, G, B + 2-bit alpha + flags
2. **Background channel** (32 bits) -- 8-bit R, G, B + 2-bit alpha + flags
3. **Style mask** (16 bits) -- bold, italic, underline, undercurl, struck, blink

Together, the two channels form a 64-bit `channels` value. The `nccell` struct packs all of this alongside the glyph:

```c
typedef struct nccell {
    uint32_t gcluster;     // EGC, packed or spilled
    uint8_t  width;        // occupied columns (0 for continuation)
    uint16_t stylemask;    // style attributes
    uint64_t channels;     // fg (high 32) + bg (low 32)
} nccell;
```

### Color and Alpha

```c
// Set plane-level default colors (affect subsequent output)
ncplane_set_fg_rgb8(plane, 0xff, 0x80, 0x00);  // orange foreground
ncplane_set_bg_rgb8(plane, 0x00, 0x00, 0x00);  // black background

// Set colors on a channel pair directly
uint64_t channels = 0;
ncchannels_set_fg_rgb8(&channels, 0xff, 0x80, 0x00);
ncchannels_set_bg_rgb8(&channels, 0x00, 0x00, 0x00);

// Alpha modes per channel
ncchannels_set_fg_alpha(&channels, NCALPHA_OPAQUE);       // fully opaque
ncchannels_set_bg_alpha(&channels, NCALPHA_TRANSPARENT);   // see-through
ncchannels_set_fg_alpha(&channels, NCALPHA_BLEND);         // alpha blend
ncchannels_set_fg_alpha(&channels, NCALPHA_HIGHCONTRAST);  // auto fg color
```

### Alpha Blending Between Planes

When planes overlap, Notcurses composites them using per-cell alpha values:

- **`NCALPHA_OPAQUE`** -- cell fully covers planes below
- **`NCALPHA_TRANSPARENT`** -- cell is invisible, plane below shows through
- **`NCALPHA_BLEND`** -- cell blends with plane below using alpha channel
- **`NCALPHA_HIGHCONTRAST`** -- foreground automatically chosen for maximum contrast against the composited background

### Style Attributes

```c
// Set styles on a plane (affect subsequent output)
ncplane_set_styles(plane, NCSTYLE_BOLD | NCSTYLE_ITALIC);

// Turn on additional styles
ncplane_on_styles(plane, NCSTYLE_UNDERLINE);

// Turn off specific styles
ncplane_off_styles(plane, NCSTYLE_BOLD);

// Available style flags:
// NCSTYLE_BOLD       NCSTYLE_ITALIC      NCSTYLE_UNDERLINE
// NCSTYLE_UNDERCURL  NCSTYLE_STRUCK      NCSTYLE_BLINK
```

### Palette Mode

For terminals limited to 256 colors, palette-indexed colors are supported:

```c
ncplane_set_fg_palindex(plane, 196);  // palette index 196 (red)
ncplane_set_bg_palindex(plane, 17);   // palette index 17 (dark blue)
```

---

## Event Handling

### Input API

Notcurses provides three input functions, all returning a 32-bit value (Unicode codepoint or synthesized key):

```c
// Blocking: waits up to ts nanoseconds (NULL = wait forever)
uint32_t notcurses_get(struct notcurses* nc, const struct timespec* ts,
                       struct ncinput* ni);

// Non-blocking: returns immediately
uint32_t notcurses_get_nblock(struct notcurses* nc, struct ncinput* ni);

// Blocking: waits indefinitely
uint32_t notcurses_get_blocking(struct notcurses* nc, struct ncinput* ni);
```

### The `ncinput` Structure

```c
typedef struct ncinput {
    uint32_t id;        // Unicode codepoint or NCKEY_* constant
    int y, x;           // cell coordinates for mouse events (-1 if N/A)
    unsigned modifiers;  // bitmask: NCKEY_MOD_SHIFT, NCKEY_MOD_ALT,
                        //          NCKEY_MOD_CTRL, NCKEY_MOD_SUPER,
                        //          NCKEY_MOD_HYPER, NCKEY_MOD_META,
                        //          NCKEY_MOD_CAPSLOCK, NCKEY_MOD_NUMLOCK
    ncintype_e evtype;  // NCTYPE_PRESS, NCTYPE_REPEAT, NCTYPE_RELEASE
    uint32_t eff_text[4]; // effective UTF-32 text accounting for modifiers
} ncinput;
```

### Kitty Keyboard Protocol

When the terminal supports the Kitty keyboard protocol, Notcurses can distinguish between key press, repeat, and release events. This enables:

- Detecting modifier-only key presses (e.g., pressing Shift alone)
- Distinguishing `Enter` from `Ctrl+M`
- Reporting key release events for game-style input

### Mouse Events

```c
// Enable mouse tracking
notcurses_mice_enable(nc, NCMICE_ALL_EVENTS);

// In event loop, check for mouse events
struct ncinput ni;
notcurses_get_blocking(nc, &ni);
if (ni.id == NCKEY_BUTTON1) {
    // Left mouse button at (ni.y, ni.x)
    if (ni.evtype == NCTYPE_PRESS) {
        // button pressed
    } else if (ni.evtype == NCTYPE_RELEASE) {
        // button released
    }
} else if (ni.id == NCKEY_SCROLL_UP) {
    // scroll wheel up
}

// Disable mouse tracking
notcurses_mice_disable(nc);
```

### Signal Handling

Notcurses installs signal handlers for `SIGWINCH` (terminal resize), `SIGCONT` (resume from suspend), and optionally for `SIGINT`/`SIGQUIT`/`SIGTERM` (to restore the terminal before exit). The `NCOPTION_NO_QUIT_SIGHANDLERS` flag disables the quit signal handlers if the application wants to manage them itself.

### Event Loop Example

```c
struct ncinput ni;
uint32_t id;
while ((id = notcurses_get_blocking(nc, &ni)) != (uint32_t)-1) {
    if (id == 'q' || id == 'Q') {
        break;  // quit on 'q'
    }

    if (id == NCKEY_RESIZE) {
        // Terminal was resized -- re-layout
        unsigned new_rows, new_cols;
        notcurses_stddim_yx(nc, &new_rows, &new_cols);
        // Recompute layout for new dimensions...
    }

    if (ni.modifiers & NCKEY_MOD_CTRL) {
        // Ctrl was held
    }

    // Offer input to widgets
    ncselector_offer_input(my_selector, &ni);

    // Re-render
    notcurses_render(nc);
}
```

---

## State Management

### Imperative Model

Notcurses is fundamentally imperative. There is no framework-imposed state management pattern -- no model-view-update loop, no reactive data binding, no virtual DOM. The application is fully responsible for:

1. Maintaining its own data model.
2. Drawing the appropriate visual representation onto planes.
3. Handling input and updating both the model and the planes.

### Plane as Visual State

Each `ncplane` holds its own visual state: a grid of `nccell` values representing the current appearance. The application mutates this state directly via `ncplane_putstr()`, `ncplane_putchar()`, `ncplane_set_fg_rgb8()`, etc. The plane retains its contents until explicitly overwritten or erased.

```c
// Erase a plane (reset all cells to defaults)
ncplane_erase(plane);

// Erase a specific region
ncplane_erase_region(plane, y, x, rows, cols);
```

### User Data Pointers

Every plane can carry an opaque user pointer, providing a way to associate application-level state with a drawing surface:

```c
struct my_widget_state {
    int counter;
    char label[64];
};

struct my_widget_state* state = malloc(sizeof(*state));
state->counter = 0;
snprintf(state->label, sizeof(state->label), "Widget A");

ncplane_set_userptr(plane, state);

// Later, retrieve it:
struct my_widget_state* s = ncplane_userptr(plane);
s->counter++;
```

### No Automatic Dirty Tracking

Notcurses does not track which cells have been modified since the last render. Instead, `notcurses_render()` composites all visible planes and diffs the result against the previously rendered frame. This means modifying a plane's contents is cheap (just memory writes), and the cost of rendering depends on the number of cells that actually changed on screen, not the number of API calls made.

---

## Extensibility & Ecosystem

### Language Bindings

| Language   | Binding                                                         | Maintainer                    |
| ---------- | --------------------------------------------------------------- | ----------------------------- |
| **C++**    | Built-in (`notcurses/ncpp.hh`)                                  | Official                      |
| **Python** | Built-in (`cffi` based)                                         | Official                      |
| **Rust**   | [`libnotcurses-sys`](https://crates.io/crates/libnotcurses-sys) | Community (official-adjacent) |
| **Ada**    | Community                                                       | Community                     |
| **Dart**   | Community                                                       | Community                     |
| **Julia**  | Community                                                       | Community                     |
| **Nim**    | Community                                                       | Community                     |
| **Zig**    | Community                                                       | Community                     |

### Multimedia Integration

With FFmpeg linked, Notcurses can decode and render images and video directly in the terminal. The `ncvisual` API handles:

- Loading images from files or memory
- Decoding video frame-by-frame
- Blitting frames to planes using the best available pixel protocol (Kitty > Sixel > character-based)
- Scaling and interpolation

The included `ncplayer` tool demonstrates video playback, and `ncls` renders file thumbnails in directory listings.

### Direct Pixel Rendering

Via `NCBLIT_PIXEL`, Notcurses can render true pixel graphics using whichever protocol the terminal supports:

```c
struct ncvisual* ncv = ncvisual_from_file("image.png");
struct ncvisual_options vopts = {
    .blitter = NCBLIT_PIXEL,
    .n = target_plane,
    .scaling = NCSCALE_STRETCH,
};
ncvisual_blit(nc, ncv, &vopts);
notcurses_render(nc);
ncvisual_destroy(ncv);
```

### Demo Suite

The `notcurses-demo` binary showcases the library's full capabilities across multiple demonstrations: scrolling, transparency, video, Unicode, Braille plots, fading, and more. It serves as both a feature showcase and a stress test.

---

## Strengths

- **Unmatched performance** -- Frame-diffing, minimal escape sequence output, header-inline functions, and packed cell representation minimize overhead.
- **Richest terminal capability support** -- No other TUI library matches its breadth: true color, Sixel, Kitty graphics, Kitty keyboard protocol, Unicode EGC, video playback, octant/sextant/Braille blitting.
- **True alpha compositing between planes** -- Four alpha modes (opaque, transparent, blend, high-contrast) enable sophisticated layered UIs without manual z-order management.
- **Multimedia support** -- Built-in FFmpeg integration for image and video rendering directly in the terminal.
- **Modern terminal features as defaults** -- 24-bit color and Unicode are assumed, not opted into. Graceful degradation handles older terminals automatically.
- **Zero-dependency core** -- `libnotcurses-core` can be built without the multimedia stack, C++ compiler, or any optional dependencies.
- **Thorough documentation** -- Comprehensive man pages, a published book, wiki, and an extensive demo suite.
- **Thread-safe design** -- Concurrent plane manipulation with rendering on a dedicated thread is supported out of the box.

---

## Weaknesses & Limitations

- **C API complexity** -- The API surface is very large (hundreds of functions) with C-style naming conventions. Managing `nccell` channels, style masks, and plane lifecycles requires careful attention.
- **Manual memory management** -- Planes, widgets, visuals, and cells with spilled glyph clusters all require explicit destruction. Missing a `*_destroy()` call leaks resources.
- **No automatic layout** -- All positioning is manual. Building responsive layouts requires implementing your own layout engine on top of planes and resize callbacks. This is a significant burden for complex UIs.
- **Steep learning curve** -- The combination of a large API, manual layout, manual memory management, and the compositor mental model makes Notcurses harder to learn than higher-level alternatives like Textual, Ink, or Bubble Tea.
- **Platform limitations** -- Primary development targets Linux and macOS. Windows support exists (10 v1093+) but is less mature. FreeBSD and DragonFly BSD are supported but less tested.
- **Complex build requirements** -- Full builds need CMake, a C17 compiler, terminfo, libunistring, and optionally FFmpeg, OpenImageIO, and a C++17 compiler. The dependency chain is non-trivial compared to single-file or header-only alternatives.
- **Lower-level than most alternatives** -- Notcurses sits closer to a "terminal compositor" than to an application framework. Features like routing, state management, and layout that higher-level frameworks provide must be built by the application.

---

## Lessons for D / Sparkles

Notcurses offers several architectural patterns that translate well to D's strengths:

### Plane Abstraction with RAII

Notcurses planes require manual `ncplane_destroy()` calls. In D, planes could be wrapped in `@nogc`-compatible structs with deterministic cleanup via `~this()` (the destructor). D's `scope` and DIP1000 lifetime tracking would prevent dangling plane references at compile time:

```d
struct Plane {
    private ncplane* handle;

    @disable this(this);  // no copy

    ~this() @nogc nothrow {
        if (handle) ncplane_destroy(handle);
    }
}
```

### Channel-Based Coloring

Notcurses packs RGBA into 32-bit channels and pairs them into 64-bit values. D's bitwise operations on `uint` and `ulong` are natural for this, and `@nogc` helper functions could provide a type-safe API:

```d
struct Channel {
    uint raw;

    @nogc nothrow pure @safe:
    void setRgb8(ubyte r, ubyte g, ubyte b) { /* bit manipulation */ }
    ubyte r() const { return cast(ubyte)(raw >> 16 & 0xff); }
}
```

### Compositor Model with Output Ranges

Notcurses' plane compositing (iterate planes in z-order, blend cells) maps naturally to D output ranges. A `composit()` function could accept any output range of cells, enabling both direct terminal writing and testing with in-memory buffers.

### Capability Detection via Design by Introspection

Notcurses detects terminal capabilities at runtime (Sixel, Kitty, true color). D's compile-time introspection (Design by Introspection / DbI) could complement this with static feature detection, building different code paths based on backend capabilities -- e.g., a `SixelBlitter` that only compiles when the Sixel trait is satisfied.

### Cell Struct with SmallBuffer

The `nccell` approach of packing short glyph clusters inline (32-bit `gcluster`) and spilling to heap for longer EGCs maps directly to `SmallBuffer`. A D cell could use `SmallBuffer!(char, 4)` for the glyph cluster, keeping the common case allocation-free while supporting arbitrary Unicode:

```d
struct Cell {
    SmallBuffer!(char, 4) gcluster;  // inline for ASCII/BMP, spills for long EGCs
    ushort stylemask;
    ulong channels;
}
```

### Direct C Interop

D has excellent C interop via `extern(C)` and `importC`. A D binding to Notcurses could be nearly zero-cost, directly calling into `libnotcurses-core` without a wrapper layer. This would give Sparkles access to Notcurses' full capability set (including multimedia) while providing a D-idiomatic API on top.

### Performance Patterns

Notcurses' zero-allocation rendering philosophy (packed cells, frame diffing, minimal escape output) aligns with D's `@nogc` + output range patterns. A D TUI renderer could write escape sequences to a `SmallBuffer` or directly to an output range, avoiding GC allocation entirely in the render path.

---

## References

- **Repository**: [github.com/dankamongmen/notcurses](https://github.com/dankamongmen/notcurses)
- **Man pages**: [notcurses.com](https://notcurses.com)
- **Wiki**: [nick-black.com/dankwiki/Notcurses](https://nick-black.com/dankwiki/index.php/Notcurses)
- **Book**: _Hacking the Planet with Notcurses: A Guide to TUIs and Character Graphics_ by Nick Black ([free PDF](https://nick-black.com/htp-notcurses.pdf))
- **Nick Black's blog**: [nick-black.com](https://nick-black.com)
- **API header**: [`include/notcurses/notcurses.h`](https://github.com/dankamongmen/notcurses/blob/master/include/notcurses/notcurses.h)
- **Rust binding**: [libnotcurses-sys on crates.io](https://crates.io/crates/libnotcurses-sys)
- **Demo video / showcase**: Run `notcurses-demo` after installation
- **NEWS / changelog**: [NEWS.md](https://github.com/dankamongmen/notcurses/blob/master/NEWS.md)
- **FOSDEM 2021 talk**: Nick Black on Notcurses and modern terminal capabilities
