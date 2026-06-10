# Window-System Concepts: Shared Vocabulary

The shared-vocabulary page for the [window-system-integration][index] survey. Every
per-subject deep-dive ([Winit][winit], [SDL3][sdl3], [GLFW][glfw], [Qt 6][qt6],
[GTK 4][gtk4], [Smithay/libdecor][smithay], …) links back here for the concepts it
exhibits, so each idea is defined **once**, grounded in a concrete real example, and
cross-linked to the implementations that show it off. This page is the windowing
counterpart of the async-I/O survey's [primitives][primitives] vocabulary; where a
concept is really an event-loop concept wearing a windowing hat, it cross-links there.

> [!NOTE]
> **Scope.** These are the cross-cutting concepts the deep-dives share — the recurring
> hazards and design forks of the windowing layer (decorations, coordinates, input
> translation, the loop). Library-specific mechanics stay in each deep-dive; this page
> only fixes the shared terms and shows the smallest faithful illustration of each.
> Several concepts are demonstrated by a CI-verified runnable D snippet (pure `std`, no
> display, byte-deterministic output) placed in the most relevant section.

**Last reviewed:** June 8, 2026

---

## Client-side vs server-side decorations {#csd-vs-ssd}

A window's **decorations** are its titlebar, borders, drop shadow, and the
minimize/maximize/close buttons. The fork is **who draws them**:

- **Server-side decorations (SSD)** — the display server / compositor / window manager
  draws the frame around the client's content. This is the historical X11 model (the WM
  reparents the client and draws a frame) and the Wayland model when the compositor
  honours `zxdg_decoration_manager_v1` with `mode_server_side` (KDE/KWin, wlroots).
- **Client-side decorations (CSD)** — the application draws its own titlebar and borders
  into its own surface. This is mandatory on Wayland compositors that refuse SSD
  (GNOME/Mutter advertises **no** `zxdg_decoration_manager_v1` at all), and on Win32 for
  custom-chrome apps.

On Wayland the choice is **negotiated**, not assumed — see
[the negotiation handshake](#client-vs-server-decoration) below. The recurring lesson
across the survey is that **SSD is only a hint**: per the [`xdg-decoration`][p-xdgdeco]
protocol there is no reliable way to force or forbid it, so every serious toolkit must
carry a CSD path. Who draws CSD differs sharply:

| Implementation          | CSD strategy                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------ |
| [Winit][winit]          | own-drawn Adwaita frame via `sctk-adwaita` (no [libdecor][libdecor])                 |
| [SDL3][sdl3]            | delegates to [libdecor][libdecor]; draws no titlebar of its own                      |
| [GLFW][glfw]            | [libdecor][libdecor] → SSD → own-drawn subsurface-edge fallback                      |
| [Qt 6][qt6]             | own-drawn CSD via decoration plugins (`adwaita`/`bradient`), predating libdecor      |
| [GTK 4][gtk4]           | own-drawn CSD in `gtk/`; binds **only** KDE `org_kde_kwin_server_decoration` for SSD |
| [Chromium Ozone][ozone] | SSD-first via `zxdg_toplevel_decoration_v1`, own Views-drawn CSD fallback            |
| [Smithay SCTK][smithay] | three-tier: compositor SSD → spartan `FallbackFrame` → [libdecor][libdecor]          |

[GTK 4][gtk4] is the outlier worth remembering: GDK binds neither libdecor **nor**
`zxdg-decoration-v1`, so on wlroots compositors it always falls back to its own CSD.

### The Wayland decoration handshake {#client-vs-server-decoration}

On Wayland the SSD/CSD decision is a **double-buffered, asynchronous negotiation**, not a
boolean the client sets. The canonical sequence (as wrapped by [Smithay SCTK][smithay] and
spoken raw by every other Wayland client):

1. The client binds `zxdg_decoration_manager_v1` **if the compositor advertises it**. If
   it does not (GNOME), the client is on its own — CSD is the only option.
2. The client creates a `zxdg_toplevel_decoration_v1` for its toplevel and **requests** a
   mode with `set_mode(server_side)` / `set_mode(client_side)` (or `unset_mode` to defer
   to the compositor).
3. The compositor replies with a `zxdg_toplevel_decoration_v1.configure(mode)` event
   carrying the **actual** mode. The client must obey it: if it comes back `client_side`,
   the client draws the frame; if `server_side`, the client draws nothing.

SCTK exposes this verbatim — its `WindowConfigure.decoration_mode` "will always be
`DecorationMode::Client` if server side decorations are not enabled or supported", and
[libdecor][libdecor]'s own source admits that, per `xdg-decoration` v1, the toggle "is
just a hint and there is no reliable way of disabling all decorations." Because the
handshake is per-configure and may flip, a robust client treats decoration mode like
any other negotiated window state ([no-buffer-no-window](#no-buffer-no-window),
[scale](#scale-factor)): request, then react to the configure.

[X11 selections / `INCR`][x11-icccm] are not a decoration concept, but they are the same
shape of ICCCM negotiation; deep-dives that mention X11 clipboard chunking point at the
[ICCCM spec][x11-icccm].

---

## Scancode vs keysym vs virtual-key {#scancode-keysym-virtualkey}

A keypress carries (at least) two independent identities, and conflating them is the
classic input bug:

- **Scancode** (a.k.a. **physical key**, **`PhysicalKey`/`KeyCode`**, evdev code, USB-HID
  usage) — the layout-**independent** physical location of the key. The key labelled `Q`
  on a US keyboard and `A` on an AZERTY keyboard report the **same** scancode. This is
  what you want for `WASD` movement or "the key in the top-left", and it is stable across
  layouts.
- **Keysym** (a.k.a. **logical key**, **`Keycode`**, **virtual-key**/`VK_*` on Win32) —
  the layout-**dependent** symbol the key produces: `q`, `a`, `Escape`, `F1`. This is what
  you want for "is this the `Z` of Ctrl+Z" or for displaying a shortcut.
- **Text / commit string** — the actual characters produced, including
  [composition](#pre-edit-composition). A dead-key sequence (`´` then `e` → `é`) produces
  no text on the first press and the composed text on the second.

Where the scancode→keysym translation happens is the platform fork. On Linux, the
state machine is **[xkbcommon][xkbcommon]**: [Winit][winit] owns its own xkb state in
`winit-common`, [SDL3][sdl3] feeds the compositor's keymap fd to xkbcommon, and
[Smithay SCTK][smithay] holds `xkb::Context`/`State`/`compose::State` behind mutexes.
Two recurring gotchas: Wayland's `wl_keyboard` delivers **raw evdev** codes that need a
**`+8` offset** before every xkb call (the X11 keycode base), and toolkits that ship their
own table instead of xkbcommon ([Avalonia][avalonia]'s `X11KeyTransform`, [JUCE][juce]'s
`XLookupString`-only path) inherit layout bugs. On Win32 the symbol is a `VK_*`
virtual-key; on macOS there is "no direct analogue to either keysyms or virtual-key
codes", so [Winit][winit] reports the raw scancode there.

The runnable snippet below shows the **direction** of the lookup — a fixed evdev-code
table standing in for what xkbcommon resolves against the active layout. Real toolkits
delegate to [xkbcommon][xkbcommon]; this is the shape of what it returns.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "scancode_keysym"
+/
import std.stdio : writefln;

// A physical (evdev) scancode is layout-independent; a keysym is the
// layout-dependent symbol xkbcommon resolves it to. This is a tiny fixed
// US-layout slice of that mapping (real toolkits delegate to libxkbcommon).
struct Entry { int scancode; string keysym; }

immutable Entry[] table = [
    Entry(1,  "Escape"),
    Entry(30, "a"),
    Entry(57, "space"),
];

string lookup(int scancode) pure @safe nothrow
{
    foreach (e; table)
        if (e.scancode == scancode)
            return e.keysym;
    return "(unmapped)";
}

void main()
{
    foreach (sc; [1, 30, 57, 99])
        writefln("scancode %2d -> keysym %s", sc, lookup(sc));
}
```

```[Output]
scancode  1 -> keysym Escape
scancode 30 -> keysym a
scancode 57 -> keysym space
scancode 99 -> keysym (unmapped)
```

---

## Logical vs physical coordinates {#logical-vs-physical-coords}

Two coordinate systems coexist in every windowing API:

- **Physical (device) pixels** — the actual pixels the GPU rasterizes into. A 4K monitor
  is 3840×2160 physical pixels.
- **Logical (device-independent) pixels / points / DIPs** — a resolution-independent unit
  the app lays out in. At 200% scale, one logical pixel covers a 2×2 block of physical
  pixels, so a "1920×1080 logical" window fills a 3840×2160 physical surface.

The two are bridged by the [scale factor](#scale-factor). The deep design choice is
**which one the API speaks natively**:

| Native unit                                  | Toolkits                                                                                     |
| -------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Physical** (app converts via scale factor) | [Winit][winit] (`PhysicalSize`/`PhysicalPosition` are the default)                           |
| **Logical** (physical only at the OS seam)   | [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [JUCE][juce], [Slint][slint], [MAUI][maui] |
| **Mixed / per-platform native unit**         | [SDL3][sdl3], [GLFW][glfw] (separate window-size vs framebuffer-size), [Flutter][flutter]    |

[SDL3][sdl3] is the instructive case: it deliberately uses each platform's own native
unit — physical on Win32/X11/Android, logical on macOS/iOS/Wayland — so the **same**
default window reports `1920×1080` from `SDL_GetWindowSize` on macOS but `3840×2160` on
Windows for one physical 4K/200% display. [GLFW][glfw] formalizes the split into two
distinct queries: **window size** (in screen coordinates) versus **framebuffer size**
(in pixels), with a content-scale ratio between them. The practical rule the survey keeps
re-learning: never size your render target off the logical window size — size it off the
physical/framebuffer size (or the pixel-size-changed event), or you render blurry.

---

## The scale factor & fractional scaling {#scale-factor}

The **scale factor** is the multiplier from [logical to physical pixels](#logical-vs-physical-coords):
`physical = logical × scale`. Integer scales (1×, 2×, 3×) are easy; **fractional** scales
(1.25×, 1.5×, 1.75×) are where the platforms diverge, and where two distinct hazards live.

**Where the scale comes from, per platform:**

- **Wayland** — `wp_fractional_scale_v1` (paired with `wp_viewporter`). The compositor
  sends a **preferred scale as an integer in 1/120ths**: `180` means 1.5×, `90` means
  0.75×, `120` means 1.0×. The client renders at that fractional scale and uses a
  `wp_viewport` to size the buffer exactly. [GTK 4][gtk4]'s `GdkFractionalScale` stores the
  raw 120ths value and offers `to_double`; [GLFW][glfw] reports `numerator / 120.f` as the
  content scale; [Qt 6][qt6] creates a `QWaylandFractionalScale` only when the rounding
  policy is `PassThrough`. Without the protocol, clients fall back to the **integer**
  `wl_surface.set_buffer_scale`. ([Smithay SCTK][smithay] never implements fractional
  scale at all — integer only — and is the cautionary tale here.)
- **Win32** — per-monitor DPI. The process opts into **Per-Monitor-V2** awareness
  (`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`, falling back to V1 then
  system-DPI), and the OS delivers [`WM_DPICHANGED`][wm-dpichanged] when a window crosses a
  DPI boundary. The message packs the new X DPI in the **low word** of `wParam` and the new
  Y DPI in the **high word**; `scale = dpi / 96`. The handler must reposition the window to
  the OS-suggested rect from `lParam`. [Qt 6][qt6] additionally handles the prefatory
  [`WM_GETDPISCALEDSIZE`][wm-dpichanged] and carefully separates the spontaneous-drag case
  from the `setGeometry`-induced case to avoid double-scaling.
- **macOS** — `NSWindow.backingScaleFactor`, which is integer-only (1× or 2×); the OS
  composites everything else.
- **X11** — there is no per-surface scale protocol, so toolkits scrape a single global
  `Xft.dpi` ([GLFW][glfw], [JUCE][juce] — which will literally shell out to `dconf` for
  Ubuntu's per-display scale) or guess ([Avalonia][avalonia]). Mixed-DPI multi-monitor on
  X11 is therefore the universal weak spot: a window dragged to a differently-scaled
  monitor does **not** re-scale.

**Hazard 1 — created-at-wrong-scale.** On Wayland a surface has no scale until it
`enter`s an output (pre-v6) or receives its first `preferred_scale`, so it is created at
1× and **rescaled** on the first event. Toolkits handle this by treating the first scale
as a configure-driven event and re-laying-out; [Winit][winit]'s `ScaleFactorChanged` even
ships a `surface_size_writer` so the callback can rewrite the post-rescale physical size,
and [Slint][slint] dispatches `ScaleFactorChanged` on window creation _before_ first paint
to dodge the transient. **Hazard 2 — mixed-DPI migration.** Dragging a window between
monitors of different scale must re-fire the scale event (`WM_DPICHANGED` on Win32, a
fresh `preferred_scale` on Wayland) — the X11 single-global-DPI model cannot.

The two snippets below show the arithmetic of each side: the Wayland 120ths conversion and
the Win32 `WM_DPICHANGED` word extraction.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "fracscale_v120"
+/
import std.stdio : writefln;

// Wayland wp_fractional_scale_v1 sends the preferred scale as an integer in 1/120ths.
// to_double = numerator / 120.0  (e.g. 180 -> 1.5, 90 -> 0.75, 120 -> 1.0).
double scaleFrom120(int numerator) pure @safe nothrow @nogc
{
    return numerator / 120.0;
}

void main()
{
    foreach (n; [120, 180, 90, 144, 240])
        writefln("preferred_scale=%3d -> scale=%.4f", n, scaleFrom120(n));
}
```

```[Output]
preferred_scale=120 -> scale=1.0000
preferred_scale=180 -> scale=1.5000
preferred_scale= 90 -> scale=0.7500
preferred_scale=144 -> scale=1.2000
preferred_scale=240 -> scale=2.0000
```

The Win32 side decodes the DPI from a [`WM_DPICHANGED`][wm-dpichanged] `wParam`. `0x00C000C0`
is `192` DPI in both words → 2.0× scale.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wm_dpichanged"
+/
import std.stdio : writefln;

// On Win32, WM_DPICHANGED packs the new X DPI in the low word of wParam and the
// new Y DPI in the high word; both are normally equal. scale = dpi / 96.
enum uint USER_DEFAULT_SCREEN_DPI = 96;

uint loword(uint v) pure @safe nothrow @nogc { return v & 0xFFFF; }
uint hiword(uint v) pure @safe nothrow @nogc { return (v >> 16) & 0xFFFF; }

void main()
{
    foreach (wparam; [0x0060_0060u, 0x0078_0078u, 0x00C0_00C0u, 0x0090_0090u])
    {
        const dpiX = loword(wparam);
        const dpiY = hiword(wparam);
        const scale = cast(double) dpiX / USER_DEFAULT_SCREEN_DPI;
        writefln("wParam=0x%08X -> dpiX=%d dpiY=%d scale=%.3f", wparam, dpiX, dpiY, scale);
    }
}
```

```[Output]
wParam=0x00600060 -> dpiX=96 dpiY=96 scale=1.000
wParam=0x00780078 -> dpiX=120 dpiY=120 scale=1.250
wParam=0x00C000C0 -> dpiX=192 dpiY=192 scale=2.000
wParam=0x00900090 -> dpiX=144 dpiY=144 scale=1.500
```

---

## IME pre-edit / composition {#pre-edit-composition}

An **input method editor (IME)** turns a sequence of keystrokes into text that has no
1:1 key mapping — CJK characters, accented Latin via dead keys, emoji pickers. The key
concept is the **pre-edit (composition) string**: the _provisional, not-yet-committed_
text shown (usually underlined) while the user is still composing, distinct from the
**commit string** that is finally inserted. A robust app must (a) render the pre-edit
inline, (b) position the candidate window near the text caret, and (c) keep raw key
events separate from composed text.

Every toolkit models this as a **separate event stream** from key events. [Winit][winit]
emits `Ime::{Enabled, Preedit, Commit, Disabled}`; [SDL3][sdl3] separates
`SDL_EVENT_TEXT_EDITING` (pre-edit) from `SDL_EVENT_TEXT_INPUT` (commit); [Slint][slint]
and [Flutter][flutter] route through the platform stack. The per-platform protocol is the
fragmentation point:

| Platform | Modern protocol                      | What the survey actually found                                                                                                              |
| -------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Wayland  | `zwp_text_input_v3`                  | Used by [SDL3][sdl3], [Winit][winit], [Qt 6][qt6]; **not** bound by GDK ([GTK 4][gtk4] does IME above GDK)                                  |
| Win32    | [Text Services Framework (TSF)][tsf] | **Nobody** uses TSF — [SDL3][sdl3], [Winit][winit], [Qt 6][qt6], [GTK 4][gtk4], [JUCE][juce], [Avalonia][avalonia] all use **legacy IMM32** |
| macOS    | [`NSTextInputClient`][nstextinput]   | Implemented by [SDL3][sdl3], [Winit][winit], [JUCE][juce]; [GLFW][glfw] mispositions the candidate window                                   |
| X11      | XIM                                  | [Winit][winit]/[SDL3][sdl3] use XIM; [GLFW][glfw], [JUCE][juce] omit pre-edit entirely                                                      |

Two findings dominate. First, **the universal IMM32-over-TSF choice on Windows**: not one
surveyed toolkit uses the modern [TSF][tsf], every one falls back to legacy IMM32
(`WM_IME_COMPOSITION` with `GCS_COMPSTR`/`GCS_RESULTSTR`). Second, **IME is frequently
absent**: [GLFW][glfw] omits pre-edit by design (issue #41 open since 2013),
[JUCE][juce]'s X11 path has no IME at all, [Smithay SCTK][smithay] ships no client-side
`text_input_v3` consumer, and [MAUI][maui] delegates the whole concern to native controls.
The deep design lesson recorded across the tree: IME is table-stakes but uneven, and a
windowing layer that wants to be reusable standalone should own the pre-edit consumer
rather than punt it upward (as [GTK 4][gtk4] does, leaving GDK alone without text input).

---

## X11 override-redirect vs Wayland xdg_popup grab {#override-redirect-vs-xdg-popup-grab}

Menus, tooltips, dropdowns, and combo-box popups are **transient surfaces** that the
window manager should not decorate, tile, or focus normally, and that must **dismiss on
click-outside**. The two display servers solve this with fundamentally different
mechanisms:

- **X11 override-redirect.** The client sets the `override_redirect` attribute on the
  window, which tells the WM "do not manage this window" — no frame, no reparenting, the
  client positions and stacks it absolutely. The client is then responsible for the
  pointer/keyboard **grab** and for dismissing on click-outside. [SDL3][sdl3] sets
  `xattr.override_redirect` for `TOOLTIP`/`POPUP_MENU` windows; [Avalonia][avalonia]
  positions override-redirect popups with its own `ManagedPopupPositioner` flip/slide math;
  [Qt 6][qt6] creates `BypassWindowManagerHint` windows override-redirect.
- **Wayland xdg_popup grab.** There is no absolute positioning. A popup is an `xdg_popup`
  **parented** to another surface, placed via an `xdg_positioner` (anchor + gravity +
  constraint-adjustment/slide), and given an explicit `grab(seat, serial)`. The
  **compositor** owns the grab and dismisses the popup on click-outside. The client cannot
  place a popup at an absolute screen coordinate; it can only describe it relative to its
  parent. [SDL3][sdl3] maps popups to `xdg_popup` + `xdg_positioner`; [Smithay SCTK][smithay]
  wraps it as `Popup`/`XdgPositioner`; [libdecor][libdecor] forwards window-menu grabs via
  `libdecor_frame_popup_grab(frame, seat_name)`.

The cross-platform consequence the survey keeps hitting: a toolkit's popup abstraction
**cannot** be a simple "place this window at (x, y)" call, because that maps onto neither
model cleanly. [Winit][winit] punts entirely — it has _no_ cross-platform popup/grab API,
only X11 `_NET_WM_WINDOW_TYPE` hints — and apps draw menus inside the parent surface
instead. Framework toolkits that render popups **in-canvas** ([Uno][uno], [Slint][slint]'s
winit backend) sidestep the whole fork by never creating a real OS sub-surface, at the cost
of not getting compositor-enforced dismiss.

---

## The Win32 modal resize/move loop {#win32-modal-resize-loop}

When the user grabs a Win32 window's titlebar or a resize edge, Windows enters its **own
nested modal message loop** inside `DefWindowProc` and stops returning to the
application's pump until the drag ends. The symptoms: timers stop firing, `GetMessage`
never returns, and **redraws freeze** for the entire drag — a live-resize that shows a
frozen window. The loop is bracketed by [`WM_ENTERSIZEMOVE`][wm-entersizemove] and
`WM_EXITSIZEMOVE`.

The survey-wide workaround is identical in spirit everywhere: on `WM_ENTERSIZEMOVE`,
install a `SetTimer`, and drive a frame from each `WM_TIMER` so the app keeps drawing
while `DefWindowProc` blocks. [SDL3][sdl3] arms `SetTimer(SDL_IterateMainCallbacks, ...)`
and runs live-resize iterations from `WM_TIMER`; [GTK 4][gtk4] pumps
`g_main_context_iteration` from the timer; [sokol][sokol] arms `SetTimer(USER_TIMER_MINIMUM)`.
A second, finer trick appears in [Winit][winit] and [sokol][sokol]: a ~500 ms pause on the
_first_ titlebar click is cancelled by posting a dummy `WM_MOUSEMOVE` (with `lParam = 0`)
on `WM_NCLBUTTONDOWN`. [Qt 6][qt6], [JUCE][juce], and [wxWidgets][wxwidgets] track an "in size-move" flag and
accept that the loop is mitigated, not eliminated.

This is a **Win32-only** concept. Wayland resize is cooperative and non-blocking (a CSD
border click calls `xdg_toplevel.resize` and the compositor streams `configure` events —
[Smithay SCTK][smithay] notes the client "never enters a blocking modal loop"); X11 resize
is likewise driven by ordinary `ConfigureNotify` events. Toolkits with no Win32 backend
([Smithay/libdecor][smithay]) mark this dimension N/A.

---

## Raw/relative vs accelerated/absolute pointer motion {#raw-vs-accelerated-pointer}

Two kinds of pointer motion serve two kinds of application:

- **Absolute / accelerated motion** — the cursor position in window-local coordinates,
  after the OS applies pointer acceleration. This is what GUIs want: "the click was at
  (412, 88)". It is the default everywhere (`WindowEvent::PointerMoved`,
  `wl_pointer.motion`, `WM_MOUSEMOVE`).
- **Raw / relative motion** — un-accelerated deltas (`dx`, `dy`) with no absolute
  position, used by first-person cameras and 3D viewports that lock and hide the cursor.
  This is a **separate event source** everywhere: a `DeviceEvent::MouseMotion`
  ([Winit][winit]) backed by `zwp_relative_pointer_v1` on Wayland and `WM_INPUT` on Win32,
  paired with pointer **locking/confinement** (`zwp_pointer_constraints_v1`, or
  `SDL_WINDOW_MOUSE_RELATIVE_MODE`). Notably [GTK 4][gtk4] binds **none** of the
  pointer-constraints/relative-pointer protocols — a deliberate gap, since GTK is not a
  game toolkit, so it cannot do FPS-style raw input at all.

A closely-related sub-concept is **high-resolution scroll**. Both Wayland's
`wl_pointer.axis_value120` and Win32's `WM_MOUSEWHEEL` report wheel motion in **1/120 of a
logical detent** (Win32's `WHEEL_DELTA` is `120`) — a convention shared across the two
platforms ([Chromium Ozone][ozone] notes the "120-per-detent convention shared with
Windows"). A high-resolution mouse or trackpad sends sub-120 deltas; the client
**accumulates** them and emits one wheel "notch" per 120 units, carrying the remainder for
sub-notch precision. [SDL3][sdl3] accumulates `axis_value120` per `wl_pointer.frame`,
[Smithay SCTK][smithay] merges `value120` across frames, [GLFW][glfw]/[Qt 6][qt6]/[GTK 4][gtk4]
all read `axis_value120` when the seat is new enough.

The snippet below is that accumulator. Feeding `[40, 40, 40, 30]` (sub-notch deltas)
emits exactly one notch and carries a remainder of `30/120`.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "axis_v120"
+/
import std.stdio : writefln;

// wl_pointer.axis_value120 (and Win32 WM_MOUSEWHEEL) report wheel motion in
// 1/120 of a logical "detent". Accumulate deltas; emit one wheel notch per 120
// units accumulated, carrying the remainder for sub-notch precision.
void main()
{
    int acc;
    int notches;
    foreach (delta; [40, 40, 40, 30])
    {
        acc += delta;
        while (acc >= 120)
        {
            acc -= 120;
            ++notches;
            writefln("wheel notch #%d", notches);
        }
    }
    writefln("emitted %d notch(es), remainder %d/120", notches, acc);
}
```

```[Output]
wheel notch #1
emitted 1 notch(es), remainder 30/120
```

---

## The Wayland no-buffer-no-window rule {#no-buffer-no-window}

On X11 and Win32, creating a window **maps it immediately**: `CreateWindowEx` + `ShowWindow`,
or `XMapWindow`, and the window is on screen. Wayland is the opposite: a `wl_surface` is
**invisible until a buffer is committed**, _and_ a toplevel surface cannot use its role
until the compositor has sent the initial `xdg_surface.configure`. The startup dance is
mandatory and ordered:

1. Create `wl_surface` → give it the `xdg_toplevel` role via `xdg_surface`.
2. **Commit** the surface with **no buffer** and round-trip.
3. Wait for the compositor's `xdg_surface.configure`, **ack** it.
4. Only _now_ attach the first buffer and commit — the window appears.

The consequence is that "create window" is **not synchronous** on Wayland. [Winit][winit]'s
constructor blocks in `roundtrip` + `blocking_dispatch` until `is_configured()` before
returning; [SDL3][sdl3]'s `Wayland_ShowWindow` spins on `libdecor_dispatch`/`dispatch_pending`
"until the surface gets a configure event"; [Smithay SCTK][smithay] draws the first frame
_inside_ `WindowHandler::configure`, never on creation; [Chromium Ozone][ozone] notes some
state (`set_window_geometry`) is "silently dropped if committed without a buffer";
[Slint][slint] goes so far as to **destroy** the window on hide because winit "won't create
an invisible Wayland window". A second consequence, recorded in [SDL3][sdl3]'s long bug tail
(referencing KDE bug 448856), is that retrofitting a synchronous "create then show" API onto
this asynchronous handshake is fragile — model the lifecycle as explicit state from the
start.

This rule is also why **clients cannot set their own toplevel position** on Wayland (the
compositor owns placement, so `SetWindowPosition` is a silent no-op — see
[SDL3][sdl3]/[GLFW][glfw]/[Chromium Ozone][ozone]) and why window size/state are
**negotiated** via configure rather than set.

---

## Frame callbacks & per-platform vsync sources {#frame-callback-vsync}

Smooth animation needs the application to draw **once per display refresh**, synchronized
to vsync, and ideally to _stop_ drawing when the window is hidden so it does not burn the
CPU/GPU. There is no single cross-platform vsync primitive; each platform has its own
source, and a toolkit must funnel them into one redraw scheduler:

| Platform | Vsync source                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------- |
| Wayland  | **`wl_surface.frame`** callbacks — the compositor tells you when to draw next                   |
| macOS    | [`CVDisplayLink`][cvdisplaylink] (deprecated since macOS 15) / [`CADisplayLink`][cadisplaylink] |
| Win32    | DXGI `WaitForVBlank` / DWM composition timing                                                   |
| X11      | the app's own redraw cadence (no standard vsync event)                                          |

The **Wayland frame callback** is the model worth internalizing: before committing a
frame, the client requests `wl_surface.frame`; the compositor fires the callback when the
surface will next be visible; the client draws only then. This both paces to vsync **and**
naturally throttles to zero when occluded. [GTK 4][gtk4] _freezes_ its per-surface
`GdkFrameClock` while a frame callback is outstanding so the client "never out-runs the
compositor"; [Qt 6][qt6] runs a **dedicated second event thread** for frame callbacks so
they are not starved by the main queue; [GLFW][glfw] gates its EGL swap on a frame callback
specifically so a swap on a hidden surface does not block forever; [Winit][winit] exposes
`pre_present_notify` solely to schedule one.

The other platforms decouple pacing from the message loop onto a **separate high-priority
source**: [JUCE][juce] runs a per-screen `CVDisplayLink` on macOS and a dedicated
`WaitForVBlank` thread at highest priority on Windows; [GTK 4][gtk4] and [Qt 6][qt6] use
`CVDisplayLink` on macOS (both noting its macOS-15 deprecation). The recurring weakness:
toolkits with no dedicated pacing source ([GLFW][glfw], which relies purely on the GL/EGL
swap interval; X11 paths generally) offer **no frame-pacing telemetry** and tear on
high-refresh displays. A new framework should pick the per-platform source explicitly and
fold all of them into one frame-clock abstraction, and should have a `CADisplayLink`
migration plan for the deprecated `CVDisplayLink`.

---

## Readiness vs completion in the windowing loop {#readiness-vs-completion-windowing}

The windowing event loop is, underneath, an I/O event loop, and it inherits the same
**readiness vs completion** distinction analyzed for async I/O in the
[primitives][primitives] vocabulary — here it governs **who owns the loop** and **how the
display connection is multiplexed**.

On Linux, the display connection is a **socket fd** (the Wayland display socket, or the
X11/XCB connection), and a windowing loop is a **readiness** loop over that fd: poll the
fd, and when it is readable, drain and dispatch the queued events. This is exactly the
reactor model. [Winit][winit] wraps the Wayland socket as a `calloop` `WaylandSource` and
the XCB fd as a `calloop` `Generic` source — "the windowing analogue of the readiness-driven
reactors"; [Smithay SCTK][smithay] integrates the Wayland fd into `calloop` via
`calloop-wayland-source`; [SDL3][sdl3]'s Wayland pump hand-rolls the
`prepare_read`/`flush`/`SDL_IOReady`/`read_events`/`dispatch_pending` readiness dance;
[Chromium Ozone][ozone] plugs each backend's display fd into Chromium's `base::MessagePump`
(and runs a _dedicated_ fd-watch thread to dodge the libwayland `prepare_read` single-reader
deadlock).

The deeper point is the **loop-ownership fork**, which mirrors readiness-vs-completion's
"who calls whom":

- **App owns the loop (poll model)** — the app calls `glfwPollEvents` / `SDL_PollEvent` /
  dispatches calloop. [GLFW][glfw] and default [SDL3][sdl3] are here. Like a readiness
  reactor, the app is in control and can add its own fd sources (on Linux; [Winit][winit]'s
  `EventLoop` even implements `AsFd` so it can be polled inside a larger reactor).
- **Library/OS owns the loop (callback model)** — control is inverted: the OS drives, and
  the app is called back. This is mandatory where the OS owns the loop — Web's
  animation-frame, iOS `UIApplicationMain`, macOS `CFRunLoop` — which is precisely why
  [Winit][winit] abandoned its old `poll_events()` iterator for `ApplicationHandler`
  callbacks, and why [SDL3][sdl3] added the opt-in `SDL_MAIN_USE_CALLBACKS` model. On macOS,
  every toolkit cedes the loop to AppKit (`[NSApp run]` + `CFRunLoop` observers).

The cross-cutting lesson: an external async runtime ([async-io][async-io]) and a windowing
loop both want to own the process's blocking wait, and reconciling them means either making
the windowing loop a pollable fd source (the [Winit][winit]/`calloop` story) or running the
windowing loop on its own thread — there is **no portable external-fd injection** in
[GLFW][glfw] or [SDL3][sdl3].

---

## Sources

The concepts above are abstractions over behaviours documented and quoted in the
per-subject deep-dives; each deep-dive's own `Sources` block carries its primary-source
citations. The cross-cutting external references behind the definitions here:

- **Wayland protocols** (wayland.app): [`xdg-shell`][p-xdgshell],
  [`xdg-decoration`][p-xdgdeco], [`fractional-scale-v1`][p-fracscale],
  [`viewporter`][p-viewporter], [`text-input-v3`][p-ti3],
  [`pointer-constraints`][p-pointerconstraints], [`relative-pointer`][p-relpointer],
  [`cursor-shape-v1`][p-cursorshape], [`wlr-layer-shell`][p-layershell],
  [`wl_pointer.axis_value120`][p-axis120].
- **X11 / ICCCM** — the [ICCCM specification][x11-icccm] (selections, `INCR`, window
  management semantics).
- **Win32** — [`WM_DPICHANGED`][wm-dpichanged], [`WM_ENTERSIZEMOVE`][wm-entersizemove],
  the [Text Services Framework][tsf] (pinned to verified Wayback snapshots).
- **macOS / AppKit** — [`NSTextInputClient`][nstextinput], [`CVDisplayLink`][cvdisplaylink],
  [`CADisplayLink`][cadisplaylink] (pinned to verified Wayback snapshots).
- **[xkbcommon][xkbcommon]** — the keymap/keysym state machine the Linux backends share.
- **[libdecor][libdecor]** — the de-facto CSD library; see the [Smithay/libdecor][smithay]
  deep-dive for its plugin model.
- Sibling concept docs: async-io [primitives][primitives]; the [window-system index][index];
  the [ui-layout catalog][ui-layout].

<!-- References -->

<!-- Deep-dives (siblings) -->

[index]: ./index.md
[winit]: ./winit.md
[sdl3]: ./sdl3.md
[glfw]: ./glfw.md
[sokol]: ./sokol.md
[qt6]: ./qt6.md
[gtk4]: ./gtk4.md
[flutter]: ./flutter-engine.md
[ozone]: ./chromium-ozone.md
[avalonia]: ./avalonia.md
[maui]: ./dotnet-maui.md
[uno]: ./uno-platform.md
[slint]: ./slint.md
[wxwidgets]: ./wxwidgets.md
[juce]: ./juce.md
[smithay]: ./smithay-libdecor.md

<!-- Cross-tree siblings -->

[primitives]: ../async-io/primitives.md
[async-io]: ../async-io/index.md
[ui-layout]: ../ui-layout/index.md

<!-- Wayland protocols -->

[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[p-xdgdeco]: https://wayland.app/protocols/xdg-decoration-unstable-v1
[p-fracscale]: https://wayland.app/protocols/fractional-scale-v1
[p-viewporter]: https://wayland.app/protocols/viewporter
[p-ti3]: https://wayland.app/protocols/text-input-unstable-v3
[p-pointerconstraints]: https://wayland.app/protocols/pointer-constraints-unstable-v1
[p-relpointer]: https://wayland.app/protocols/relative-pointer-unstable-v1
[p-cursorshape]: https://wayland.app/protocols/cursor-shape-v1
[p-layershell]: https://wayland.app/protocols/wlr-layer-shell-unstable-v1
[p-axis120]: https://wayland.app/protocols/wayland#wl_pointer:event:axis_value120

<!-- X11 / cross-platform specs -->

[x11-icccm]: https://tronche.com/gui/x/icccm/sec-2.html
[xkbcommon]: https://xkbcommon.org/
[libdecor]: https://gitlab.freedesktop.org/libdecor/libdecor

<!-- Win32 (Wayback-pinned, bot-hostile host) -->

[wm-dpichanged]: https://web.archive.org/web/20260428034332/https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[wm-entersizemove]: https://web.archive.org/web/20250611230612/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove
[tsf]: https://web.archive.org/web/20221114201716/https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework

<!-- macOS / AppKit (Wayback-pinned, bot-hostile host) -->

[nstextinput]: https://web.archive.org/web/20260115025403/https://developer.apple.com/documentation/appkit/nstextinputclient
[cvdisplaylink]: https://web.archive.org/web/20250609094433/https://developer.apple.com/documentation/corevideo/cvdisplaylink
[cadisplaylink]: https://web.archive.org/web/20190614134451/https://developer.apple.com/documentation/quartzcore/cadisplaylink
