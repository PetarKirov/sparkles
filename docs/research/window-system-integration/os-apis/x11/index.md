# X11 (Xlib)

The original network-transparent windowing system of Unix: a **request/event protocol** spoken over a byte stream (a Unix-domain or TCP socket), with [Xlib][xlib] as the canonical C client library that marshals protocol requests into an output buffer and demarshals events out of an input queue. A client opens a [`Display`][xopendisplay] connection, creates [`Window`][xcreatewindow] resources living on the server, and pumps the big [`XEvent`][xnextevent] union. This is the layer the X11 backends of [winit][winit], [SDL3][sdl3], [GTK 4][gtk4] (GDK X11), and [Chromium Ozone][ozone] all reduce to on Linux.

**Last reviewed:** June 9, 2026

| Field                    | Value                                                                                                                                  |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Native API               | **X11 protocol** via **Xlib** (`Display` / `Window` / `XEvent` / `Atom` / `GC`)                                                        |
| Library / framework      | `libX11` (`-lX11`); the lower-level [XCB][xcb] (`libxcb`) is the modern alternative most toolkits actually link                        |
| Header / protocol source | [`<X11/Xlib.h>`][xlib] (C declarations) over the [X protocol][xproto] wire format; conventions in [ICCCM][icccm] and [EWMH][ewmh]      |
| Window handle type       | `Window` — a 32-bit `XID` (a server-side resource id), **not** a pointer; valid across the connection, not just in-process             |
| Event-loop primitive     | The X **connection file descriptor** (`ConnectionNumber(dpy)`) drained by [`XNextEvent`][xnextevent] — a readiness loop over a socket  |
| Coordinate unit          | **Physical pixels** (the server knows nothing of logical/DPI scaling)                                                                  |
| Decoration owner         | **Server-side** — but it is the **window manager**, a separate client, that reparents and draws the frame; Xlib itself draws no chrome |
| Example                  | [`./example/app.d`](./example/app.d)                                                                                                   |

> [!NOTE]
> **The window manager is a client, not the server.** Unlike Win32 (`DefWindowProc` draws the frame) or macOS (AppKit draws it), the X server draws **no** decorations. A separate process — the window manager — reparents top-level windows into a frame it draws, and decides placement, focus, and stacking by intercepting map/configure requests. So "server-side decorations" on X11 really means "another-client-side": the protocol is the medium, [ICCCM][icccm]/[EWMH][ewmh] are the contract, and the WM is the counterparty. A WM-less `Xvfb`/`Xephyr` session shows windows with no frame at all.

---

## What it is

X11 is a **protocol**, and Xlib is one library that speaks it. A client establishes a connection — a socket to the X server — and from then on does two things: it **sends requests** (create a window, map it, draw a rectangle, intern an atom) and it **receives events, replies, and errors** back. There is no shared memory and no function-call semantics across the wire; everything is asynchronous messages over a byte stream. The Xlib manual states the model verbatim:

> Most of the functions in Xlib just add requests to an output buffer. These requests later execute asynchronously on the X server.
>
> — [_Xlib — C Language X Interface_, "Handling the Output Buffer"][xlib]

This one sentence governs the whole survey. A call like `XCreateSimpleWindow` or `XMapWindow` does **not** round-trip; it appends a request to Xlib's output buffer and returns immediately, and the `Window` `XID` it hands back is allocated client-side without waiting for the server. The buffer is flushed lazily — when it fills, when a function that needs a reply blocks, or when the program explicitly calls [`XFlush`][xflush]/`XSync`. The corollary, also from the manual, is that a "create then immediately use" sequence may not have reached the server yet, and that the output buffer "is always flushed by a call to any function that returns a value from the server or waits for input" — which is why the event-pump functions (`XNextEvent`, `XPending`) flush as a side effect.

The handle type follows from the protocol being network-transparent. A `Window` is an `XID` — a 32-bit integer resource id minted by the client from a server-allocated range — not a pointer into client memory. The same is true of `Pixmap`, `Font`, `Colormap`, `Cursor`, and `GC` (graphics context). Resources live on the server; the client refers to them by id. This is the deep difference from `NSWindow*`/`HWND`: a `Window` is meaningful to **any** client on the same connection (which is exactly how a window manager manipulates _your_ windows), and it survives being passed around as a plain integer.

The example reaches Xlib through D's **ImportC**: a one-line C shim, [`./example/c.c`](./example/c.c), `#include`s the real `<X11/Xlib.h>`, so every type — including the exact memory layout of the `XEvent` union — and every function signature comes verbatim from the system header, with nothing hand-declared to drift.

> [!NOTE]
> **Xlib vs XCB.** Most modern toolkits do not use raw Xlib for I/O. [XCB][xcb] (`libxcb`) exposes the protocol directly with explicit request/reply cookies (so the asynchrony above is in the type system), and `Xlib/XCB` lets the two share one connection. The survey's example uses Xlib because its `XOpenDisplay`→`XCreateSimpleWindow`→`XNextEvent` path is the irreducible, readable form; the concepts (resources-by-id, request/event, the WM as a client) are identical on XCB.

---

## The minimal program

The example, [`./example/app.d`](./example/app.d), is the irreducible Xlib window-open sequence that [winit][winit], [SDL3][sdl3], and [GLFW][glfw] each wrap on X11. Because Xlib exposes some constants as object-like macros (`ExposureMask` is `(1L<<15)`) that ImportC does not reliably import, the example re-declares the handful of event-mask and event-type constants it uses and prefers the real function forms (`XDefaultScreen`, `XRootWindow`, `XBlackPixel`) over their function-macro aliases. The sequence:

1. **Connect.** `XOpenDisplay(null)` opens the connection named by `$DISPLAY` (`null` = the default). It returns a `Display*` — an opaque per-connection client-side struct holding the socket, the output buffer, and the event queue — or `null` if no server is reachable. The example treats `null` as the **headless guard**: it prints `SKIP:` and exits `0`, the research-doc discipline for host-capability gating (an SSH session or CI runner with no `$DISPLAY`). `scope (exit) XCloseDisplay(dpy)` tears the connection down.

2. **Create the window.** `XCreateSimpleWindow(dpy, root, 0, 0, 480, 320, 1, black, white)` creates a top-level window as a child of the screen's `root` window (from `XRootWindow`), with a 480×320 content size **in physical pixels**, a 1-pixel border, and black-on-white pixels (`XBlackPixel`/`XWhitePixel`). It returns the `Window` `XID` immediately — no round-trip. `XStoreName` sets the `WM_NAME` property (the title the WM will draw).

3. **Opt into the close button.** `XInternAtom(dpy, "WM_DELETE_WINDOW", False)` interns an [atom][xinternatom] — a server-side interned-string id — and `XSetWMProtocols` registers it so that, per [ICCCM][icccm], clicking the WM's close button delivers a `ClientMessage` event to the program instead of the server killing the connection. This is the canonical graceful-close handshake.

4. **Subscribe, then map.** `XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask)` tells the server which event categories this window wants (you receive **only** what you select — there is no firehose). `XMapWindow(dpy, win)` requests that the window be shown; the WM may reparent and frame it, then map it. Unlike Wayland's [no-buffer-no-window][nbnw] handshake, mapping is conceptually synchronous, like Win32 `ShowWindow`.

5. **Event loop.** `XNextEvent(dpy, &ev)` flushes the output buffer and blocks until the next `XEvent` is dequeued. On the first `Expose` (the server telling the client a region needs (re)painting) the example draws a filled rectangle with `XFillRectangle` through the default graphics context (`XDefaultGC`), calls [`XFlush`][xflush] to push the drawing requests to the server, prints `ok:`, and exits so CI never blocks. A real app would loop until the `WM_DELETE_WINDOW` `ClientMessage` (or a chosen key); the example also returns on `KeyPress`/`ClientMessage`.

> [!IMPORTANT]
> **Drawing only happens on `Expose`.** X does not retain window contents by default (the server may discard them when the window is occluded), so a client must redraw whatever was lost whenever it receives an `Expose` event. Issuing draw calls before the first `Expose` — or expecting them to persist across occlusion — is the classic "my window is blank" bug. (The `XComposite`/backing-store extensions can retain contents, but the portable contract is redraw-on-`Expose`.)

---

## Window creation & lifecycle

Top-level windows are created with [`XCreateWindow`][xcreatewindow] (full control over visual, depth, and an `XSetWindowAttributes`) or its convenience wrapper `XCreateSimpleWindow` (the example's choice). Creation is purely client-driven request marshalling: the `XID` is allocated locally and the request is buffered, so a window "exists" as a resource id before the server has processed it. Geometry is always in **physical pixels**, relative to the parent (`x`, `y` are offsets within the parent window).

Showing a window is `XMapWindow` (and `XMapRaised` to also raise it); hiding is `XUnmapWindow`; destroying is `XDestroyWindow`, which frees the server resource. The reason mapping is not the whole story is the window manager. Per [ICCCM][icccm], a top-level window's relationship to the WM is mediated by **properties** the client sets before mapping:

- `WM_NAME` / `_NET_WM_NAME` — the title (`XStoreName` sets the former; EWMH prefers a UTF-8 `_NET_WM_NAME`).
- `WM_PROTOCOLS` (with the `WM_DELETE_WINDOW` atom) — opt into graceful close, as the example does.
- `WM_NORMAL_HINTS` (an `XSizeHints`) — min/max/increment sizes and the initial geometry.
- `WM_HINTS` — input focus model, initial state (normal/iconic).
- `_NET_WM_WINDOW_TYPE` ([EWMH][ewmh]) — `_NET_WM_WINDOW_TYPE_NORMAL`, `…_DIALOG`, `…_TOOLTIP`, `…_MENU`, etc., which tell the WM how to treat the window.

Lifecycle changes arrive **as events**, because the WM (not the client) controls placement and framing. After mapping, a client learns its real on-screen size and position from `ConfigureNotify` events (delivered because the example selected `StructureNotifyMask`) — the WM may have resized or repositioned the window inside its frame. There is no synchronous "what is my size" truth at creation time; the authoritative size is whatever the latest `ConfigureNotify` reports.

> [!WARNING]
> **Placement and geometry are advisory.** A client can _request_ a position and size, but the window manager is free to override both (tiling WMs ignore size entirely; most WMs reposition to avoid panels). Treat the geometry you asked for as a hint and the `ConfigureNotify` you receive as the truth — the same "request, then react to the configure" discipline Wayland forces via [the decoration handshake][csd-handshake], arrived at from the opposite direction.

---

## Event loop & frame pacing

The loop is a **readiness loop over a socket**. The connection is a file descriptor (`ConnectionNumber(dpy)`), and the canonical pump is [`XNextEvent`][xnextevent], which flushes the output buffer and blocks until an event is available, copying it into a caller-provided `XEvent`. This is the [readiness][rvc] end of the readiness-vs-completion fork: the app owns the loop, polls the fd, and drains the queue — exactly the reactor model the Linux backends standardize on. Because it is just an fd, an app can `poll(2)`/`select(2)` it alongside its own sources: select on `ConnectionNumber(dpy)`, and when readable, drain with `XPending` + `XNextEvent`. This is how [winit][winit] folds the X connection into its `calloop` reactor.

The pivotal data structure is the **`XEvent` union**. Every event is the same fixed-size union whose first member (`ev.type`) discriminates which struct is active — `XExposeEvent` (`Expose`), `XKeyEvent` (`KeyPress`/`KeyRelease`), `XButtonEvent`, `XMotionEvent`, `XConfigureEvent` (`ConfigureNotify`), `XClientMessageEvent` (`ClientMessage`), and dozens more. The client `switch`es on `ev.type` and reads the matching member. Selecting events is opt-in via the `XSelectInput` event mask; you receive only the categories you asked for.

The asynchrony from [What it is](#what-it-is) shows up here as two flushing functions:

- [`XFlush`][xflush] pushes the buffered requests to the server **without waiting** for a reply. The example calls it after drawing so the rectangle actually reaches the server before the program exits.
- `XSync` flushes **and blocks** until the server has processed every request, then drains (or discards) the queued events — used when a client must observe protocol errors at a known point, at the cost of a full round-trip.

**Frame pacing.** Core X11 has **no vsync event** — there is no `wl_surface.frame` analogue ([frame-callback / vsync][fcv]); a client's redraw cadence is its own (a timer, the GL/EGL swap interval, or busy redraw). The modern fix is the [Present extension][present] (`presentproto`): a client uses `PresentPixmap` to present a buffer at a target MSC (media stream counter) and receives `PresentCompleteNotify`/`PresentIdleNotify` events tied to the vertical retrace, giving real vsync timing. Without it (or without a compositing manager that throttles via the Composite extension), X11 paths in the survey have no frame-pacing telemetry and tear on high-refresh displays — the recurring weakness recorded under [frame-callback / vsync][fcv].

---

## Input

**Keyboard.** Key events (`XKeyEvent`, type `KeyPress`/`KeyRelease`) carry a hardware **keycode** — a small layout-independent integer naming the physical key, the X analogue of a [scancode][skv]. The keycode is _not_ the symbol; to get the layout-dependent **keysym** (`XK_a`, `XK_Escape`, `XK_F1`) the client translates with `XLookupKeysym`/`XLookupString` against the active keyboard mapping. Modern clients drive that translation with the **[XKB][xkb] extension** (`xkbproto`/`libX11`'s XKB API), the same state machine `xkbcommon` mirrors on Wayland — see the [scancode / keysym / virtual-key][skv] split. The recurring gotcha the concept page records: X11 keycodes are offset by `+8` from raw evdev codes, which is why Wayland backends add `+8` before every xkbcommon call to match the X keycode base.

**IME / text input.** Composition (CJK, dead keys, emoji) goes through **XIM** — the X Input Method framework. The libX11 manual documents the model under its [Input Method Overview][xim]; a client opens an input method with `XOpenIM`, creates an input context (`XIC`) per text field, routes raw key events through `XFilterEvent` (which lets the IM swallow composition keystrokes), and receives provisional **pre-edit** text and the final **commit** string via the input-context callbacks ([pre-edit / composition][pec]). The survey-wide finding: [winit][winit]/[SDL3][sdl3] implement XIM, while [GLFW][glfw] and [JUCE][juce] omit pre-edit entirely on X11.

**Pointer.** Mouse motion and buttons are `XMotionEvent`/`XButtonEvent`, carrying window-relative coordinates in physical pixels; scroll-wheel notches arrive historically as button presses (buttons 4/5/6/7). Core X has no un-accelerated relative-motion stream — the [raw vs accelerated pointer][rap] split is served by the **XInput2** extension (`XI_RawMotion`) plus a pointer grab (`XGrabPointer`)/`XWarpPointer` for cursor confinement, used by FPS-style apps; core `MotionNotify` only ever reports accelerated, absolute window-local positions.

---

## Coordinates & scaling

X11's coordinate unit is the **physical pixel**, full stop. The server has **no concept of a logical/DPI-scaled coordinate space** ([logical vs physical coords][lpc]): a window is N pixels wide, events report pixel coordinates, and there is no per-surface scale factor in the protocol the way Wayland exposes `wp_fractional_scale_v1` or macOS exposes `backingScaleFactor`. This makes HiDPI on X11 the universal weak spot of the survey.

There is no standard, per-monitor scale event. Clients reconstruct a scale from one of two scrapes, neither per-window:

- **`Xft.dpi`** — a single global DPI value published in the `RESOURCE_MANAGER` property (the X resource database, read with `XrmGetResource`). It is one number for the whole display; [GLFW][glfw] and [JUCE][juce] read it (JUCE will even shell out to `dconf` for Ubuntu's per-display scale), and there is no notification when it changes.
- **[RANDR][randr]** (`randrproto`) — the Resize and Rotate extension reports each monitor's pixel resolution **and physical millimetre size**, from which a true DPI can be computed per output. But because window coordinates are global physical pixels, RANDR gives the geometry, not a per-window scale the toolkit can react to.

The consequence, recorded under [the scale factor][scale-factor]: a window dragged from a 1× monitor to a 2× monitor **does not re-scale** — there is no `WM_DPICHANGED` and no fresh `preferred_scale`, only the global `Xft.dpi` that did not change. Mixed-DPI multi-monitor is therefore the canonical X11 failure mode, and toolkits either pick one global scale and live with blur on the other monitor or guess.

---

## Decorations & multi-window/popups

**Decorations are server-side — but drawn by the window manager, not the X server** ([CSD vs SSD][csd]). The WM is a separate client that, on seeing a top-level window mapped, **reparents** it into a frame window it owns and draws the titlebar, borders, and buttons there. The client states preferences through properties (`WM_NORMAL_HINTS`, the `_MOTIF_WM_HINTS` "no border" hint, `_NET_WM_WINDOW_TYPE`) and the WM honours them as it sees fit; there is no Wayland-style per-configure [decoration negotiation handshake][csd-handshake], and no reliable way to _force_ a frame on or off — the same "SSD is only a hint" lesson, expressed through ICCCM/EWMH conventions instead of a protocol object.

**Multi-window** is trivial and first-class: any number of top-level windows are just more `XID`s on the one `Display` connection, all draining the same event queue. Stacking is controlled with `XRaiseWindow`/`XLowerWindow`/`XConfigureWindow` (subject to WM override), and parent/child relationships with `XReparentWindow`. There is one application loop for all of them.

**Popups / menus** are the [override-redirect vs xdg_popup grab][orx] fork's X11 side. A client marks a transient surface (menu, tooltip, dropdown) with the **`override_redirect`** window attribute, which tells the WM to leave it alone — no frame, no reparenting, the client positions and stacks it at absolute screen coordinates. The Xlib manual is explicit:

> The override-redirect flag specifies whether map and configure requests on this window should override a `SubstructureRedirectMask` on the parent. … Window managers use this information to avoid tampering with pop-up windows.
>
> — [_Xlib_, §3.2.8 "Override Redirect Flag"][override]

The client then owns everything the WM normally would: it must `XGrabPointer`/`XGrabKeyboard` to capture input and **dismiss the popup itself** on click-outside (there is no compositor-enforced grab as in Wayland's `xdg_popup`). [SDL3][sdl3] sets `override_redirect` for tooltip/popup-menu windows; [Qt 6][qt6] creates `BypassWindowManagerHint` windows the same way; [Avalonia][avalonia] runs its own flip/slide positioner because absolute placement is the client's job.

---

## Clipboard & drag-and-drop

**Clipboard** on X11 is the **selection** mechanism defined by [ICCCM][icccm], and it is unusual: the clipboard holds **no data at rest**. Three selections exist — `PRIMARY` (middle-click paste), `SECONDARY`, and `CLIPBOARD` (the Ctrl+C/Ctrl+V clipboard). An owner claims a selection with `XSetSelectionOwner`; a paster requests a conversion to a target type with `XConvertSelection`, the owner answers by writing the data into a property and sending a `SelectionNotify`, and the requestor reads it. The data lives only in the owner client — close the owner and the clipboard is empty (the reason a clipboard manager daemon exists).

Large transfers use the **`INCR` protocol** ([ICCCM §2.7.2][incr]): when the data is too big for a single property, the owner replies with the `INCR` target and a size estimate, then streams the value in chunks, each delivered as a `PropertyNotify` on a property the requestor deletes to acknowledge, until a zero-length chunk ends it. Every X11 clipboard implementation in the survey must implement this chunking to paste large images or text — it is the X-specific complication [SDL3][sdl3]/[GTK 4][gtk4] handle and that the [concepts page notes][icccm] is "the same shape of ICCCM negotiation" as the decoration dance.

**Drag-and-drop** is **XDND** — a freedesktop convention layered entirely on `ClientMessage` events and selections (the `XdndSelection`), not part of core Xlib or ICCCM. Source and target windows exchange `XdndEnter`/`XdndPosition`/`XdndStatus`/`XdndDrop` `ClientMessage`s to negotiate types and the drop, then transfer the payload through the `XdndSelection` (with `INCR` chunking for large data). It is a full bidirectional protocol, but each toolkit implements the message choreography by hand.

---

## What toolkits build on this

Every X11-capable toolkit in the survey bottoms out in this same Display/Window/XEvent layer (most via [XCB][xcb] rather than raw Xlib, but the model is identical):

- **[winit][winit]** — its X11 backend talks XCB, wraps the connection fd as a `calloop` `Generic` source (the [readiness][rvc] reactor), drives keysym translation through `xkbcommon`, sets `_NET_WM_WINDOW_TYPE` hints for popups (it exposes no cross-platform grab API), and reports `PhysicalSize` since X is pixel-native.
- **[SDL3][sdl3]** — `SDL_x11window.c`/`SDL_x11events.c` build the `Window` and run the pump; it sets `override_redirect` for tooltip/popup windows, implements XIM for text input, and reports the X surface in **physical pixels** (its X11 platform is one of the physical-unit backends).
- **[GTK 4][gtk4]** — GDK's X11 backend (`gdk/x11/`) wraps the connection, properties, and selections; GTK draws its own client-side decorations and treats `Xft.dpi` as the scale source. (On X11 GTK's CSD is purely cosmetic since the WM still frames the window unless the `_MOTIF_WM_HINTS` borderless hint is set.)
- **[Chromium Ozone][ozone]** — its X11 platform plugs the connection fd into Chromium's `base::MessagePump`, does SSD-first via the WM with a Views-drawn CSD fallback, and shares the high-resolution-scroll/clipboard machinery with its Wayland backend.

---

## Sources

- **Xlib — C Language X Interface** ([X.Org current][xlib]) — the asynchronous output-buffer model, [`XFlush`][xflush]/`XSync`, the event queue, [Input Method Overview (XIM)][xim].
- **Xlib reference (Tronche mirror)** — [`XOpenDisplay`][xopendisplay], [`XCreateWindow`][xcreatewindow], [`XMapWindow`][xmapwindow], [`XSelectInput`][xselectinput], [`XNextEvent`][xnextevent], [`XInternAtom`][xinternatom], [keyboard encoding / keycodes & keysyms][keyenc], [`Expose` event][expose], [the override-redirect flag][override].
- **[ICCCM][icccm]** — selections, the [`INCR` protocol §2.7.2][incr], and client↔window-manager conventions (`WM_PROTOCOLS`/`WM_DELETE_WINDOW`, size/state hints).
- **[EWMH / `_NET_WM_*`][ewmh]** — `_NET_WM_NAME`, `_NET_WM_WINDOW_TYPE`, and the modern WM hint set.
- **Extensions** — [XKB protocol][xkb] (keyboard state), [RANDR protocol][randr] (per-output geometry/DPI), [Present protocol][present] (vsync-timed presentation), and [XCB][xcb] (the modern protocol binding).
- **This survey's example** — [`./example/app.d`](./example/app.d) (+ ImportC shim [`./example/c.c`](./example/c.c), [`./example/dub.sdl`](./example/dub.sdl)).
- **Cross-references** — the [window-system index][index] and shared [concepts][concepts]; the X11 rows of [platform-gotchas][gotchas]; the per-toolkit X11 findings in [winit][winit], [SDL3][sdl3], [GLFW][glfw], [GTK 4][gtk4], [Qt 6][qt6], [JUCE][juce], [Avalonia][avalonia], [Chromium Ozone][ozone].

<!-- References -->

<!-- Survey siblings (deep-dives one level up) -->

[index]: ../../index.md
[concepts]: ../../concepts.md
[gotchas]: ../../platform-gotchas.md
[winit]: ../../winit.md
[sdl3]: ../../sdl3.md
[glfw]: ../../glfw.md
[gtk4]: ../../gtk4.md
[qt6]: ../../qt6.md
[juce]: ../../juce.md
[avalonia]: ../../avalonia.md
[ozone]: ../../chromium-ozone.md

<!-- Concept anchors -->

[csd]: ../../concepts.md#csd-vs-ssd
[csd-handshake]: ../../concepts.md#client-vs-server-decoration
[skv]: ../../concepts.md#scancode-keysym-virtualkey
[lpc]: ../../concepts.md#logical-vs-physical-coords
[scale-factor]: ../../concepts.md#scale-factor
[pec]: ../../concepts.md#pre-edit-composition
[orx]: ../../concepts.md#override-redirect-vs-xdg-popup-grab
[rap]: ../../concepts.md#raw-vs-accelerated-pointer
[nbnw]: ../../concepts.md#no-buffer-no-window
[fcv]: ../../concepts.md#frame-callback-vsync
[rvc]: ../../concepts.md#readiness-vs-completion-windowing

<!-- Cross-tree -->

[async-io]: ../../../async-io/index.md

<!-- X11 primary sources -->

[xlib]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
[xim]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html#Input_Method_Overview
[xproto]: https://www.x.org/releases/current/doc/xproto/x11protocol.html
[xcb]: https://xcb.freedesktop.org/
[icccm]: https://tronche.com/gui/x/icccm/sec-2.html
[incr]: https://tronche.com/gui/x/icccm/sec-2.html#s-2.7.2
[ewmh]: https://specifications.freedesktop.org/wm-spec/latest/
[xkb]: https://www.x.org/releases/current/doc/kbproto/xkbproto.html
[randr]: https://www.x.org/releases/X11R7.7/doc/randrproto/randrproto.txt
[present]: https://gitlab.freedesktop.org/xorg/proto/presentproto/-/blob/master/presentproto.txt

<!-- Xlib reference (Tronche mirror) -->

[xopendisplay]: https://tronche.com/gui/x/xlib/display/opening.html
[xcreatewindow]: https://tronche.com/gui/x/xlib/window/XCreateWindow.html
[xmapwindow]: https://tronche.com/gui/x/xlib/window/XMapWindow.html
[xselectinput]: https://tronche.com/gui/x/xlib/event-handling/XSelectInput.html
[xnextevent]: https://tronche.com/gui/x/xlib/event-handling/manipulating-event-queue/XNextEvent.html
[xflush]: https://tronche.com/gui/x/xlib/event-handling/XFlush.html
[xinternatom]: https://tronche.com/gui/x/xlib/window-information/XInternAtom.html
[keyenc]: https://tronche.com/gui/x/xlib/input/keyboard-encoding.html
[expose]: https://tronche.com/gui/x/xlib/events/exposure/expose.html
[override]: https://tronche.com/gui/x/xlib/window/attributes/override-redirect.html
