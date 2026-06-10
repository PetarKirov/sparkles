# GTK 4 / GDK (C / GObject)

GNOME's widget toolkit and the **de facto reference Wayland client**: GTK 4 builds on `GDK`, a thin windowing-abstraction layer whose backends (Wayland, X11, Win32, macOS, Android, Broadway) each wrap a native window system behind one `GdkSurface` / `GdkToplevel` / `GdkPopup` object model, integrated into GLib's `GMainLoop` and driven by a per-surface `GdkFrameClock`.

| Field             | Value                                                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Version / commit  | GTK `4.23.1` (development), commit [`817caae3`][gtk-commit] (`gdk/` + `gtk/` sparse checkout)                           |
| Language          | C (GObject / GLib); macOS backend is Objective-C compiled in `.c` files                                                 |
| License           | LGPL-2.1-or-later                                                                                                       |
| Repository        | [GNOME/gtk][gtk-repo]                                                                                                   |
| Documentation     | [GDK 4 API reference][gdk-docs] / [GTK 4 API reference][gtk-docs]                                                       |
| Category          | Full GUI framework (windowing layer = `GDK`)                                                                            |
| Platforms covered | Wayland, X11, Win32, macOS/AppKit, Android, Broadway (HTML/WebSocket); this doc focuses on the first four               |
| Loop ownership    | **Callback / hybrid** — GLib `GMainLoop` owns the loop; each backend installs a `GSource`; macOS inverts to `CFRunLoop` |
| Repo paths        | `gdk/gdksurface.c`, `gdk/gdktoplevel.c`, `gdk/gdkpopup.c`, `gdk/gdkframeclockidle.c`, `gdk/{wayland,x11,win32,macos}/`  |

---

## Overview

### What it solves

`GDK` ("GIMP Drawing Kit") is the windowing-system abstraction beneath the GTK widget toolkit. It does not draw widgets; it creates native windows, pumps native events into a uniform `GdkEvent` stream, and schedules frames. Its own header states the boundary plainly:

> Represents a rectangular region on the screen.
>
> It's a low-level object, used to implement high-level objects such as `GtkWindow`.
>
> The surfaces you see in practice are either `GdkToplevel` or `GdkPopup` [...].
>
> — `gdk/gdksurface.c` ([`GdkSurface` doc comment][gdksurface-c])

The split is the key to GTK's portability: widgets, layout, CSS and rendering all live above `GDK` in `gtk/` (see the [`ui-layout`][ui-layout] survey for the layout half), while `GDK`'s per-platform backends translate one abstract window model — [`logical`-coordinate][logical-vs-physical] `GdkSurface`s presented through `GdkToplevel`/`GdkPopup` — onto `wl_surface` + `xdg_toplevel`, `XCreateWindow` + EWMH, `CreateWindowEx`, or `NSWindow`.

### Design philosophy

- **One surface per toplevel, not per widget.** GTK 4 deleted `GdkWindow` (the GTK 3 type that gave nearly every widget its own native sub-window) in favour of a single `GdkSurface` per toplevel/popup; widgets became pure drawing within one surface. `gdk/gdkwindow.c` no longer exists — the file present in GTK 3 is gone. See [§10](#10-history-redesigns-known-regrets).
- **Wayland-first.** `GDK`'s Wayland backend is the most complete and is treated as the reference client; the protocol set it binds (below) is broader than most toolkits. GTK draws its **own** [client-side decorations][csd-vs-ssd] in `gtk/` and uses neither `libdecor` nor `zxdg-decoration-v1` (see [§4](#4-wayland-specifics)).
- **Integrate, don't own, the loop.** Rather than running its own event loop, `GDK` installs a `GSource` into GLib's `GMainLoop`, so windowing, D-Bus, timers and application code share one loop. macOS is the exception: there `CFRunLoop` must be in control, so GDK inverts and drives GLib _from_ `CFRunLoop` (see [§2](#2-event-loop)).
- **Frame-clock-driven painting.** A per-surface `GdkFrameClock` is the single scheduler for the update→layout→paint cycle, synchronised to the compositor's vsync signal (Wayland frame callbacks, `CVDisplayLink` on macOS). Animations read one consistent frame time.

---

## How it works

### Core types

| Concept            | Type                                           | Role                                                            |
| ------------------ | ---------------------------------------------- | --------------------------------------------------------------- |
| Display connection | `GdkDisplay` (+ `GdkWaylandDisplay`, …)        | One connection to a window system; owns the event source(s).    |
| Abstract window    | `GdkSurface`                                   | A rectangular on-screen region; base class. `gdk/gdksurface.c`. |
| Toplevel window    | `GdkToplevel` (interface)                      | App window: title, state, decorations. `gdk/gdktoplevel.c`.     |
| Popup window       | `GdkPopup` (interface)                         | Menu/tooltip anchored to a parent. `gdk/gdkpopup.c`.            |
| Frame scheduler    | `GdkFrameClock` / `GdkFrameClockIdle`          | Per-surface update/paint cycle. `gdk/gdkframeclockidle.c`.      |
| Input grouping     | `GdkSeat` / `GdkDevice`                        | A keyboard+pointer set; devices.                                |
| Event              | `GdkEvent` (+ `GdkKeyEvent`, `GdkScrollEvent`) | Immutable per-platform-translated event.                        |

A toplevel is created and shown through `gdk_surface_new_toplevel()` + `gdk_toplevel_present()` ([`gdk/gdksurface.c`][gdksurface-c] line 935; [`gdk/gdktoplevel.c`][gdktoplevel-c] line 366). There is no separate "map"/"show" call — `present()` is the single asynchronous entry point:

```c
// gdk/gdktoplevel.c — the single lifecycle entry point
void
gdk_toplevel_present (GdkToplevel       *toplevel,
                      GdkToplevelLayout *layout)
{
  ...
  GDK_TOPLEVEL_GET_IFACE (toplevel)->present (toplevel, layout);
}
```

> [!NOTE]
> Its doc comment underscores the Wayland-shaped contract that pervades GDK 4: "Presenting is asynchronous and the specified layout parameters are not guaranteed to be respected." The compositor, not the client, has the final say on size and state.

### The frame clock

`GdkFrameClockIdle` (`gdk/gdkframeclockidle.c`) is a state machine over the phases in `gdk/gdkframeclock.h`:

```c
// gdk/gdkframeclock.h — the painting cycle, requested per phase
typedef enum {
  GDK_FRAME_CLOCK_PHASE_NONE          = 0,
  GDK_FRAME_CLOCK_PHASE_FLUSH_EVENTS  = 1 << 0,
  GDK_FRAME_CLOCK_PHASE_BEFORE_PAINT  = 1 << 1,
  GDK_FRAME_CLOCK_PHASE_UPDATE        = 1 << 2,
  GDK_FRAME_CLOCK_PHASE_LAYOUT        = 1 << 3,
  GDK_FRAME_CLOCK_PHASE_PAINT         = 1 << 4,
  GDK_FRAME_CLOCK_PHASE_RESUME_EVENTS = 1 << 5,
  GDK_FRAME_CLOCK_PHASE_AFTER_PAINT   = 1 << 6
} GdkFrameClockPhase;
```

A clock is "idle until someone requests a frame" via `gdk_frame_clock_request_phase()`; it then runs each requested phase once, emitting a signal per phase ([`gdk/gdkframeclock.c`][gdkframeclock-c] doc comment). Default refresh interval is `#define FRAME_INTERVAL 16667` µs (~60 Hz) until real timings arrive ([`gdk/gdkframeclockidle.c`][gdkframeclockidle-c] line 38). Each backend connects `before-paint`/`after-paint` handlers to drive native presentation, e.g. on Wayland in `gdk/wayland/gdksurface-wayland.c` (line 949):

```c
// gdk/wayland/gdksurface-wayland.c — wire the surface into its frame clock
g_signal_connect (frame_clock, "before-paint", G_CALLBACK (on_frame_clock_before_paint), surface);
g_signal_connect (frame_clock, "after-paint",  G_CALLBACK (on_frame_clock_after_paint),  surface);
```

---

## 1. Window creation & lifecycle

**Per-platform native calls.** Each backend implements `GdkToplevel`/`GdkPopup` over its native primitive:

| Backend | Native creation                                                                   | Source                                                     |
| ------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Wayland | `wl_compositor_create_surface` → `xdg_surface_get_toplevel`/`get_popup`           | `gdk_wayland_surface_create_wl_surface` ([line 899][gwsw]) |
| X11     | `XCreateWindow` on the root window (1×1, resized on map)                          | `gdk_x11_surface_create_window` ([line 4904][gx11s])       |
| Win32   | `CreateWindowEx`                                                                  | `gdk/win32/gdksurface-win32.c`                             |
| macOS   | `[[GdkMacosWindow alloc] initWithContentRect:… backing:NSBackingStoreBuffered …]` | `gdk/macos/gdkmacostoplevelsurface.c` ([line 627][gmtl])   |

On Wayland the `wl_surface` is created first, assigned to the surface's own `wl_event_queue`, and given listeners; the role object (`xdg_toplevel`) and `wp_viewport`/`wp_fractional_scale_v1` are attached afterward:

```c
// gdk/wayland/gdksurface-wayland.c — create the bare wl_surface
wl_surface = wl_compositor_create_surface (display_wayland->compositor);
wl_proxy_set_queue ((struct wl_proxy *) wl_surface, self->event_queue);
wl_surface_add_listener (wl_surface, &surface_listener, self);
```

**Attribute model & per-platform gaps.** `GdkToplevel` exposes `title`, `decorated`, `state` (maximized/minimized/fullscreen/tiled), `modal`, `icon`, `transient-for`, etc. Several attributes are _silently dropped_ on Wayland because the protocol forbids them:

- **Client-set position** — absent. A Wayland client cannot place its own toplevel; GDK offers only `gdk_wayland_toplevel_begin_move`/`begin_resize`, which delegate to the compositor via `xdg_toplevel.move`/`resize` ([`gdk/wayland/gdktoplevel-wayland.c`][gtw] lines 2226/2298).
- **Always-on-top** — absent on Wayland (no `keep_above`/`set_above` exists in the backend); X11 sets `_NET_WM_STATE_ABOVE` ([`gdk/x11/gdksurface-x11.c`][gx11s] line 1415).
- **Transparency** — handled via an opaque region (`wl_surface_set_opaque_region` on Wayland; an RGBA visual + colormap on X11) rather than a per-window alpha attribute.

**Initial-frame handling** is the textbook [no-buffer-no-window][no-buffer-no-window] dance on Wayland and immediate mapping elsewhere. `gdk_wayland_surface_create_xdg_toplevel` calls `gdk_surface_freeze_updates(surface)` _before_ committing the bare surface, so the surface paints nothing until the compositor sends its first `xdg_surface.configure`. The configure handler thaws updates and marks the surface mapped:

```c
// gdk/wayland/gdksurface-wayland.c — first configure unblocks painting (and "maps")
static void
gdk_wayland_surface_configure (GdkSurface *surface)
{
  GdkWaylandSurface *impl = GDK_WAYLAND_SURFACE (surface);

  if (!impl->initial_configure_received)
    {
      gdk_surface_thaw_updates (surface);        /* now we may attach a buffer */
      impl->initial_configure_received = TRUE;
      impl->pending.is_initial_configure = TRUE;
      maybe_notify_mapped (surface);             /* surface is "mapped" only now */
    }
  ...
}
```

X11 and Win32 map immediately (`XMapWindow` / `ShowWindow`) without waiting for a server round-trip — the contrast that [no-buffer-no-window][no-buffer-no-window] is about.

**Surface/handle exposure for GPU/software rendering.** Each backend exposes the native handle through a typed getter: `gdk_wayland_surface_get_wl_surface()` ([`gdk/wayland/gdkwaylandsurface.h`][gwsh] line 44), `gdk_x11_surface_get_xid()` / the `GDK_SURFACE_XID` macro ([`gdk/x11/gdkx11surface.h`][gx11h] lines 56/98), and Win32/macOS equivalents. GDK itself builds GL/Vulkan/Cairo contexts (`GdkGLContext`, `GdkVulkanContext`, `GdkCairoContext`) on top.

**Destruction ordering.** Toplevel destroy tears down role objects before the `wl_surface` (`g_clear_pointer (&toplevel->display_server.xdg_toplevel, xdg_toplevel_destroy)` then the `xdg_surface`, then the `wl_surface`) — the reverse of creation, as the xdg-shell spec requires.

---

## 2. Event loop

**Who owns the loop: GLib, via a `GSource` — except on macOS.** GDK does not run its own loop. The dominant model integrates the native window system as a GLib `GSource`, so a single `GMainLoop` multiplexes windowing fds, timers, D-Bus, GIO and app idles. This is a [readiness][readiness-vs-completion]-style integration: GLib polls fds, then dispatches.

**Wayland** installs _two_ sources (`gdk/wayland/gdkeventsource.c`, `gdk_wayland_display_install_gsources`). A low-priority _event source_ drains the GDK event queue; a `G_MININT`-priority _poll source_ owns the `wl_display` fd and does the delicate `wl_display_prepare_read` / `wl_display_read_events` dance that lets Wayland be read safely from a poll loop. The comment is explicit about why it must run first:

```c
// gdk/wayland/gdkeventsource.c — the poll source must run FIRST after every poll
/* We must guarantee to ALWAYS be called and called FIRST after
 * every poll - or rather: after every prepare().
 * Any other source might call Wayland functions and in turn
 * block while waiting for us.
 ...
 */
g_source_set_priority (source, G_MININT);
```

`prepare()` calls `wl_display_prepare_read()` (and `wl_display_flush()`); `check()` calls `wl_display_read_events()` once `G_IO_IN` fires; `_gdk_wayland_display_queue_events` then runs `wl_display_dispatch_pending`, invoking the proxy listeners that build `GdkEvent`s. A `G_IO_ERR | G_IO_HUP` on the fd means the compositor died, and GDK `_exit(1)`s.

**X11** is simpler: one `GSource` over `ConnectionNumber(xdisplay)`, with `XPending`/`XNextEvent` in `dispatch` (`gdk/x11/gdkeventsource.c`, `gdk_x11_event_source_new`, lines 452-472).

**Win32** attaches a `GSource` whose `prepare`/`check` poll `GetQueueStatus(QS_ALLINPUT)` and whose `dispatch` runs the classic pump (`gdk/win32/gdkwin32messagesource.c`):

```c
// gdk/win32/gdkwin32messagesource.c — the Win32 pump lives inside a GSource
while (PeekMessage (&msg, NULL, 0, 0, PM_REMOVE))
  {
    TranslateMessage (&msg);
    DispatchMessage (&msg);
  }
```

The notorious [Win32 modal resize/move loop][win32-modal-loop] — where Windows runs its _own_ internal loop during `WM_ENTERSIZEMOVE`, starving GLib — is worked around with a `SetTimer` whose callback pumps GLib (`gdk/win32/gdkevents-win32.c`):

```c
// gdk/win32/gdkevents-win32.c — keep GLib alive during the modal move/resize loop
static VOID CALLBACK
modal_timer_proc (HWND hwnd, UINT msg, UINT_PTR id, DWORD time)
{
  int arbitrary_limit = 10;
  while (g_main_context_pending (NULL) && arbitrary_limit--)
    g_main_context_iteration (NULL, FALSE);
}
```

The timer is armed in `_gdk_win32_begin_modal_call` (`SetTimer (NULL, …, 10, modal_timer_proc)`, line 1228) on `WM_ENTERSIZEMOVE` and killed on `WM_EXITSIZEMOVE`.

**macOS inverts the relationship.** AppKit/`CFRunLoop` must own the loop (for modal resize, sheets, and DnD nested loops), so GDK runs GLib _inside_ `CFRunLoop`. `gdk/macos/gdkmacoseventsource.c` documents the three regimes in a long header comment:

> When the GLib main loop is in control we integrate in native event handling [...]. When CFRunLoop is in control, we integrate in GLib main loop handling by adding a "run loop observer" [...]. We map these points onto the corresponding stages of the GLib main loop (prepare, check, dispatch) [...].
>
> All cases share a single problem: the macOS API's don't allow us to wait simultaneously for file descriptors and for events. So when we need to do a blocking wait that includes file descriptor activity, we push the actual work of calling select() to a helper thread (the "select thread") [...].
>
> — `gdk/macos/gdkmacoseventsource.c` ([header comment][gmes])

That **select thread** is GDK's answer to AppKit's inability to wait on fds and `NSEvent`s at once.

**Timers / wakeups / cross-thread injection.** GLib provides `g_timeout_add`, `g_idle_add`, and `g_main_context_invoke` for posting work to the loop thread from another thread — this is the user-event mechanism (GDK has no bespoke "post custom event" API at the surface level). External async runtimes attach via `g_source_add_unix_fd` / a custom `GSource`; the async-I/O survey's discussion of [reactor integration][async-index] applies directly since GLib is itself a readiness reactor.

**Frame pacing & vsync.** The vsync source is per-backend, all funnelled through `GdkFrameClock`:

- **Wayland** uses `wl_surface_frame` callbacks. `gdk_wayland_surface_request_frame` arms a `wl_callback`; when the compositor fires `frame_callback`, GDK schedules the next clock cycle. To coalesce redraws, `on_frame_clock_after_paint` _freezes_ updates while a frame callback is outstanding ([`gdk/wayland/gdksurface-wayland.c`][gwsc] lines 455-475), so the client never out-runs the compositor — the [frame-callback-vsync][frame-callback-vsync] pattern. Presentation timing comes from `presentation-time` (`gdk/wayland/gdkwaylandpresentationtime.c`).
- **macOS** uses `CVDisplayLink` (`gdk/macos/gdkdisplaylinksource.c`, `CVDisplayLinkCreateWithCGDisplay`, `CVDisplayLinkSetOutputCallback`), forwarding the display-link thread's tick into a `GSource`. (The file notes `CVDisplayLink` is deprecated since macOS 15.0, line 34.)
- **Win32** falls back to the `16667 µs` interval timer with a `timeBeginPeriod` bump (`begin_period` bit in `gdk/gdkframeclockidle.c`).

---

## 3. Input

**Keyboard model: keysyms via xkbcommon (Wayland) / XKB (X11).** GDK reports both a hardware keycode and a translated `keyval` (a [keysym][scancode-keysym]). On Wayland the seat owns the `xkb_state` machine and translates each `wl_keyboard.key` itself:

```c
// gdk/wayland/gdkseat-wayland.c — client-side keysym translation via xkbcommon
translated.keyval   = xkb_state_key_get_one_sym (xkb_state, key);
modifiers           = xkb_state_serialize_mods (xkb_state, XKB_STATE_MODS_EFFECTIVE);
consumed            = modifiers & xkb_state_key_get_consumed_mods2 (xkb_state, key, XKB_CONSUMED_MODE_GTK);
translated.layout   = xkb_state_key_get_layout (xkb_state, key);
translated.level    = xkb_state_key_get_level  (xkb_state, key, translated.layout);
```

X11 owns an `XkbDescPtr` keymap (`gdk/x11/gdkkeys-x11.c`, `XkbGetKeyboard`/`KEYMAP_USE_XKB`); Win32 maps virtual-keys (`gdk/win32/gdkkeys-win32.c`); macOS reads `NSEvent` key codes (`gdk/macos/gdkmacoskeymap.c`).

**Key repeat — the client does it on Wayland.** Wayland sends only press/release plus a `repeat_info` (rate, delay); the client must synthesise repeats. GDK arms a `g_timeout_add` timer keyed off the server rate, then _pings the server_ before each repeat so a hung compositor can't strand a key down:

```c
// gdk/wayland/gdkseat-wayland.c — synthesise key repeat, but verify the server is alive
static gboolean
keyboard_repeat (gpointer data)
{
  GdkWaylandSeat *seat = data;
  /* Ping the server and wait for the timeout. We won't process
   * key repeat until it responds, since a hung server could lead
   * to a delayed key release event. ...
   */
  seat->repeat_callback = wl_display_sync (display->wl_display);
  wl_callback_add_listener (seat->repeat_callback, &sync_after_repeat_callback_listener, seat);
  ...
}
```

Defaults are `delay = 400`, `interval = 80` ms when the server gives no `repeat_info` (`get_key_repeat`, line 1134).

**Dead keys / compose** live in the GTK layer: `gtk/gtkimcontextsimple.c` (Compose tables, `gtk/gtkcomposetable.h`), not in GDK.

**IME / text input — handled above GDK, not in it.** This is a notable architectural split: **GDK Wayland binds no `zwp_text_input_v3`**; there is no `text_input` in the Wayland protocol list (`gdk/wayland/meson.build`, lines 56-177) nor any reference under `gdk/wayland/`. Instead IME is a `GtkIMContext` in `gtk/`:

| Platform | IME backend                                                                | Source                      |
| -------- | -------------------------------------------------------------------------- | --------------------------- |
| Wayland  | `zwp_text_input_v3` ([`text-input-unstable-v3.xml`][ti-xml])               | `gtk/gtkimcontextwayland.c` |
| Windows  | **Legacy IMM32** (`ImmGetContext`, `ImmGetCompositionStringW`) — _not_ TSF | `gtk/gtkimcontextime.c`     |
| Simple   | Compose / dead-key sequences                                               | `gtk/gtkimcontextsimple.c`  |

The Wayland IME maps [pre-edit/composition][pre-edit] onto GTK signals: `text_input_preedit` stages a pre-edit string and `text_input_preedit_apply` emits `preedit-start`/`preedit-changed`/`preedit-end` (`gtk/gtkimcontextwayland.c`, lines 200-249). Candidate-window placement is reported via `zwp_text_input_v3_set_cursor_rectangle` from the cached `cursor_rect` (line 447).

> [!NOTE]
> Putting IME above the windowing layer means a _single_ `GtkIMContext` implementation per protocol drives every widget, but it also means GDK alone is not a usable windowing backend for text input — a framework cloning "just GDK" would inherit no IME. The Windows path is still **IMM32**, the older API, rather than [TSF][tsf].

**Pointer.** Absolute motion is the norm; **relative/raw motion and pointer lock/confinement are absent** — there is no `zwp_relative_pointer`, `zwp_locked_pointer`, or `pointer-constraints` anywhere in the tree (a deliberate gap, since GTK is not a game/3D toolkit; see [raw-vs-accelerated-pointer][raw-vs-accel]). High-resolution scroll uses `wl_pointer.axis_value120` when the seat is new enough (`WL_POINTER_AXIS_VALUE120_SINCE_VERSION`, `gdk/wayland/gdkseat-wayland.c` line 548); axis source (`WHEEL`/`FINGER`/`CONTINUOUS`) is tracked. Win32 accumulates `WM_MOUSEWHEEL` deltas; macOS handles momentum phases.

**Touch & gestures** are bound on Wayland via `pointer-gestures-unstable-v1` and the `tablet-v2` protocol (`gdk/wayland/meson.build`). **Cursor** uses `wp_cursor_shape_v1` when available (`wp_cursor_shape_device_v1_set_shape`, `gdk/wayland/gdkdevice-wayland.c` line 282), falling back to a client-rendered cursor surface via `wl_pointer_set_cursor` (line 346) — i.e. [`cursor_shape_v1` with client fallback][raw-vs-accel].

---

## 4. Wayland specifics

**Decorations: GTK draws its own; otherwise the KDE protocol; never `libdecor` or `xdg-decoration`.** GTK's normal mode is full [client-side decorations][csd-vs-ssd] drawn by `GtkWindow` itself (the `GtkHeaderBar` titlebar). When a server wants [SSD][csd-vs-ssd], GDK only speaks the _KDE_ `org_kde_kwin_server_decoration` protocol, never the standard `zxdg_decoration_v1` and never `libdecor`:

```c
// gdk/wayland/gdktoplevel-wayland.c — the ONLY server-decoration path GDK knows
if (display_wayland->server_decoration_manager)
  {
    ...
    org_kde_kwin_server_decoration_request_mode (self->server_decoration,
                                                 decorated ? ORG_KDE_KWIN_SERVER_DECORATION_MANAGER_MODE_SERVER
                                                           : ORG_KDE_KWIN_SERVER_DECORATION_MANAGER_MODE_CLIENT);
  }
```

A repository-wide grep confirms neither `libdecor` nor `zxdg_decoration`/`xdg-decoration` appears under `gdk/`. On a compositor that only offers `zxdg_decoration_v1` (most wlroots compositors) GTK simply draws its own CSD — acceptable because GTK _always_ has a CSD path.

**Protocol coverage** is unusually broad (from `gdk/wayland/meson.build`, lines 56-177):

| Protocol                                                                     | Used for                                                |
| ---------------------------------------------------------------------------- | ------------------------------------------------------- |
| `xdg-shell` (v6 + stable)                                                    | toplevels & popups (core)                               |
| `fractional-scale-v1`                                                        | fractional DPI (see [§5](#5-dpi-scaling))               |
| `viewporter`                                                                 | buffer scaling for fractional scale                     |
| `xdg-activation-v1`                                                          | focus stealing / startup notification                   |
| `idle-inhibit-v1`                                                            | inhibit screen blanking                                 |
| `cursor-shape-v1`                                                            | server-side cursor themes                               |
| `pointer-gestures-v1`, `tablet-v2`                                           | touchpad gestures, stylus                               |
| `presentation-time`                                                          | vsync/frame timing feedback                             |
| `xdg-dialog-v1`                                                              | native modal dialogs (see [§6](#6-multi-window-popups)) |
| `xdg-toplevel-icon-v1`                                                       | per-window icons                                        |
| `xdg-foreign-v1/v2`                                                          | cross-process parenting (transient-for)                 |
| `keyboard-shortcuts-inhibit-v1`                                              | games/terminals grabbing shortcuts                      |
| `color-management-v1`, `single-pixel-buffer-v1`, `xdg-session-management-v1` | HDR/color, optimisation, session restore                |
| `gtk-shell` (private), `server-decoration` (KDE)                             | GTK-specific hints; SSD                                 |

**Protocol-absence handling** is uniform: each bind is gated on `wlprotocolsdep.version().version_compare(...)` at build time and on a non-NULL global at runtime (`XDG_SHELL_CALL` macros no-op when the object is absent). GDK also keeps a fallback to the _unstable_ `zxdg_shell_v6` (`zxdg_toplevel_v6`) for ancient compositors. The `gtk-shell` private protocol carries GTK-only hints (D-Bus app-menu paths, a11y bus, modal hints).

---

## 5. DPI & scaling

**The native unit is logical.** GTK widgets work in [logical][logical-vs-physical] pixels; GDK multiplies by an integer [scale factor][scale-factor] for the buffer. Historically Wayland only allowed _integer_ `wl_surface.set_buffer_scale`, so 150 % displays forced a choice between blurry 1× or oversized 2×.

**Fractional scaling.** GDK 4 binds `wp_fractional_scale_v1` + `wp_viewporter`. The compositor announces a _preferred_ fractional scale (in 1/120ths) via the fractional-scale listener, and GDK renders at that scale and uses a viewport to size the buffer exactly:

```c
// gdk/wayland/gdksurface-wayland.c — receive the compositor's preferred fractional scale
static void
gdk_wayland_surface_fractional_scale_preferred_scale_cb (void *data,
                                                         struct wp_fractional_scale_v1 *fractional_scale,
                                                         uint32_t scale)
{ ... }
```

`GdkFractionalScale` (`gdk/wayland/gdkfractionalscale-private.h`) stores the 1/120 value and offers `to_int`/`to_double`/`scale`. When fractional scaling is unavailable, GDK uses `wl_surface_set_buffer_scale` with the integer scale (`gdk/wayland/gdksurface-wayland.c` line 688). The classic "created at wrong scale, then rescaled" problem is handled by GDK applying a scale change as a configure-driven event and re-laying-out; a surface that hasn't received its first preferred scale renders at 1× and corrects on the first `preferred_scale` event.

**Per-monitor DPI on Windows.** GDK requests **Per-Monitor-V2** awareness at startup: `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`, falling back to `SetProcessDpiAwareness(PROCESS_DPI_AWARENESS)` and then `SYSTEM_AWARE` on older Windows (`gdk/win32/gdkdisplay-win32.c` lines 982-1085). The [`WM_DPICHANGED`][wm-dpichanged] dance — re-sizing the window to the suggested rect when it migrates to a differently-scaled monitor — is handled in `gdk/win32/gdkevents-win32.c` (`case WM_DPICHANGED:` line 2943; note at line 1309 that `dpi_x == dpi_y`).

**macOS** uses AppKit backing-scale (Retina = 2×) reported through the monitor; mixed-DPI multi-monitor migration is driven by AppKit move/resize notifications.

---

## 6. Multi-window & popups

**Popups are `xdg_popup` with a positioner and an optional grab.** A `GdkPopup` (menu/tooltip) is created via `xdg_surface_get_popup` against the parent's `xdg_surface`, positioned by an `xdg_positioner` built from a `GdkPopupLayout` (anchor/gravity/constraint), and — when it should auto-dismiss — takes a Wayland **popup grab** (`xdg_popup.grab`):

```c
// gdk/wayland/gdkpopup-wayland.c — autohide popups take an xdg_popup grab
if (grab_input_seat)
  {
    seat   = gdk_wayland_seat_get_wl_seat (GDK_SEAT (grab_input_seat));
    serial = _gdk_wayland_seat_get_last_implicit_grab_serial (grab_input_seat, NULL);
    XDG_SHELL_CALL (xdg_popup, grab, wayland_popup, seat, serial);
  }
```

This is the [`xdg_popup` grab vs X11 `override-redirect`][override-redirect] split: on Wayland the _compositor_ enforces the grab and the dismiss-on-click-outside semantics; the grab requires a "non-top-most parent" check (`can_map_grabbing_popup`, line 984). On **X11** the same popup is an `override_redirect` window (`xattributes.override_redirect = True` + `save_under`, `gdk/x11/gdksurface-x11.c` line 4972) that the WM ignores, with GDK doing its own pointer grab. Re-positioning uses `xdg_popup.reposition` with a token round-trip (`xdg_popup_repositioned`, line 491).

**Modal dialogs.** GDK prefers the native `xdg-dialog-v1` (`xdg_dialog_v1_set_modal`) — `maybe_set_xdg_dialog_modal`, falling back to the `gtk-shell` modal hint (`maybe_set_gtk_surface_modal`, `gdk/wayland/gdktoplevel-wayland.c` line 1020). X11 sets `_NET_WM_STATE_MODAL` (line 1437). **Parent/child stacking** uses `xdg_toplevel.set_parent` (line 328); cross-process parenting (e.g. a portal dialog) uses `xdg-foreign`.

---

## 7. Threading

**GDK is single-threaded: one main thread creates surfaces and receives events.** All `GdkSurface`/`GtkWidget` calls must run on the thread that owns the `GMainContext`. There is no `gdk_threads_enter`/leave (that GTK 3 API is gone); cross-thread work posts back via `g_main_context_invoke` / `g_idle_add`.

**The constraint is hardest on macOS**, where AppKit demands that `NSWindow` creation and all UI run on the main thread — which is precisely why `gdk/macos/gdkmacoseventsource.c` keeps `main_thread_run_loop` and offloads only the blocking `select()` to a helper "select thread" (see [§2](#2-event-loop)). Rendering can happen partly off-thread inside GDK's GL/Vulkan renderers (the GPU command submission), but the windowing calls — surface configure, buffer attach/commit on Wayland, `NSWindow` mutation on macOS, `DispatchMessage` on Win32 — are main-thread only.

---

## 8. Clipboard & DnD

**MIME-typed content, asynchronous on every backend.** GDK 4 models the clipboard as `GdkClipboard` holding `GdkContentFormats` (MIME types) and exchanging data through `GInputStream`/`GOutputStream`.

- **Wayland** uses `wl_data_device` / `wl_data_source` / `wl_data_offer`. A copy advertises MIME types via `wl_data_source`; on paste the consumer calls `wl_data_offer.receive(mime, fd)` and reads the fd (`gdk/wayland/gdkclipboard-wayland.c`, `gdk_wayland_clipboard_data_source_send`, line 101). Primary selection is the separate `primary-selection-unstable-v1`.
- **X11** implements full ICCCM selections, including the **INCR** protocol for transfers too large for one property: `gdk/x11/gdkselectionoutputstream-x11.c` sets the `INCR` atom and streams in chunks driven by `PropertyNotify`/`Delete` (lines 262-278, 590-596); `gdk/x11/gdkselectioninputstream-x11.c` is the read side.
- **Win32** does **delayed rendering**, documented at length in `gdk/win32/gdkclipdrop-win32.c`:

> If SetClipboardData() is given a NULL data value, the owner will later receive WM_RENDERFORMAT message, in response to which it must call SetClipboardData() with the provided handle and the actual data this time. This way applications can avoid storing everything in the clipboard all the time [...].
>
> — `gdk/win32/gdkclipdrop-win32.c` ([doc comment][gcw])

GDK offloads the blocking `OpenClipboard`/`CloseClipboard` work onto a dedicated thread with a 30-second timeout per operation (same file, lines 104-117).

**DnD** mirrors the clipboard: Wayland `wl_data_device` start-drag (`gdk/wayland/gdkdrag-wayland.c` / `gdkdrop-wayland.c`), X11 XDND, Win32 OLE drag (`gdk/win32/gdkdrag-win32.c`), and a nested `CFRunLoop` on macOS (`gdk/macos/gdkmacosdrag.c`).

---

## 9. Escape hatches

GDK ships small backend-specific public headers so apps can reach the native layer when the abstraction leaks:

- **Native handles:** `gdk_wayland_surface_get_wl_surface()`, `gdk_wayland_display_get_wl_display()`, `gdk_x11_surface_get_xid()` / `GDK_SURFACE_XID`, plus the Win32 `HWND` and macOS `NSWindow` getters. These are the GDK analogue of `raw-window-handle`.
- **Wayland protocol access:** because GDK exposes the `wl_display` and the `wl_surface`, an app can `wl_registry`-bind protocols GDK doesn't (the documented way to use, e.g., `wlr-layer-shell` from a GTK app, since GDK has no layer-shell binding).
- **Backend detection:** `GDK_IS_WAYLAND_DISPLAY` / `GDK_IS_X11_DISPLAY` macros let code branch per platform; `GDK_BACKEND=wayland|x11` forces a backend.
- **Event filtering:** X11 raw `XEvent` interception via `gdk_x11_display_add_event_filter`; on Win32 a `GdkWin32` message hook; there is **no** generic Wayland raw-event passthrough (you must bind the protocol yourself) — a known leak point for niche protocols.

The set of getters reveals where the abstraction is known to be incomplete: pointer constraints, layer-shell, and arbitrary protocols are all "drop to `wl_surface` and DIY".

---

## 10. History, redesigns & known regrets

**The `GdkWindow` → `GdkSurface` redesign (GTK 4, ~2016-2020) is the defining windowing change.** GTK 3 gave most widgets their own native `GdkWindow` (a recursive tree of X sub-windows / Wayland subsurfaces); GTK 4 collapsed this to **one `GdkSurface` per toplevel/popup**, with widgets drawing into a single surface via the render tree. The old `gdk/gdkwindow.c` is gone entirely from the tree (confirmed: no such file at [`817caae3`][gtk-commit]). The motivation was performance and Wayland-fit: per-widget native windows mapped badly onto Wayland's subsurface model and caused redraw/clipping complexity. See the [GTK 4.0 release news][gtk4-news] and the migration guide's ["Stop using GdkScreen / GdkWindow"][gtk4-migration] section.

**The frame clock (introduced in GTK 3.8, 2013)** was the precursor that made the GTK 4 model possible: a single per-surface scheduler synchronised to vsync, replacing ad-hoc `gtk_widget_queue_draw` timing. It is now the sole driver of the update/paint cycle ([`gdk/gdkframeclock.c`][gdkframeclock-c]).

**Wayland-first stance & the decoration debate.** GTK's choice to draw its own CSD and _not_ adopt `xdg-decoration` (preferring `org_kde_kwin_server_decoration` only) is a long-running source of friction with desktops that want consistent SSD; it is the practical reason GTK apps show their own titlebar even under KWin/Mutter SSD requests. The GNOME [Client-Side Decorations initiative][gtk-csd-issue] documents the rationale; GTK's position is that CSD is intrinsic to its design.

**Known leaks / gaps recorded above:** no pointer lock/relative motion (games can't use GTK for FPS-style input); no `wlr-layer-shell` (panels/launchers must use raw protocol); Windows IME still on IMM32 not TSF; `CVDisplayLink` deprecated on macOS 15 and awaiting a `CADisplayLink`-style replacement (noted in-source, `gdk/macos/gdkdisplaylinksource.c` line 34).

---

## Strengths

- **Reference-grade Wayland citizenship** — the broadest stable-protocol coverage of any toolkit surveyed (fractional scale, color management, session management, cursor-shape, presentation-time), and the integration other clients are tested against.
- **Clean loop integration** — being a GLib `GSource` means windowing shares one loop with D-Bus, GIO, timers and app code, with no bespoke runtime.
- **Frame-clock discipline** — a single vsync-synced scheduler gives coherent animation timing and automatic redraw coalescing (freeze-until-frame-callback).
- **One-surface-per-toplevel** — simpler, faster, and a much better fit for Wayland than GTK 3's per-widget windows.
- **Uniform async clipboard/DnD** over a MIME + stream model, with correct INCR (X11) and delayed-rendering (Win32) handling.
- **Honest escape hatches** — `wl_display`/`wl_surface`/`xid`/`HWND` getters let apps bind protocols GDK lacks.

## Weaknesses

- **IME lives above GDK** — GDK alone has no text-input; cloning "just the windowing layer" gets no IME, and the Windows path is still legacy IMM32.
- **No pointer lock / relative motion / confinement** — disqualifies GTK for FPS-style games and some CAD/3D input.
- **No `libdecor` / `xdg-decoration`** — SSD only via the KDE protocol; everywhere else GTK forces its own CSD, a perennial desktop-consistency complaint.
- **No layer-shell binding** — panels/overlays must drop to raw Wayland.
- **macOS loop is intricate** — the CFRunLoop-owns-the-loop + select-thread design is subtle and has documented limitations (no nested GLib iteration from a run-loop callback).
- **Heavy dependency surface** — GLib/GObject, Cairo, Pango, xkbcommon; "use GDK standalone" is not really supported.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                   | Trade-off                                                                               |
| --------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| One `GdkSurface` per toplevel (drop `GdkWindow`)          | Performance; clean fit to Wayland's subsurface model        | Massive GTK 3→4 break; widgets lost native input regions                                |
| Integrate as a GLib `GSource` (don't own the loop)        | Share one loop with D-Bus/GIO/timers; no runtime of its own | Inherits GLib priorities; macOS must invert to CFRunLoop with a select thread           |
| Per-surface `GdkFrameClock` synced to compositor vsync    | Coherent animation timing; automatic redraw coalescing      | Extra state machine; vsync source differs per backend                                   |
| Draw own CSD; speak only KDE server-decoration            | GTK always controls its chrome; uniform look                | No `xdg-decoration`/`libdecor` → SSD inconsistency, recurring desktop friction          |
| IME as `GtkIMContext` above GDK (not in the backend)      | One IME impl per protocol drives every widget               | GDK isn't a complete windowing layer alone; Windows stuck on IMM32                      |
| No pointer constraints / relative motion                  | GTK targets desktop apps, not games                         | Unusable for FPS/3D input without dropping to raw protocol                              |
| Logical coordinates as the API unit; viewporter for scale | Crisp fractional DPI via `wp_fractional_scale_v1`           | "Created at wrong scale, rescale on first event" transient; integer fallback on old WLs |

---

## Verdict: what a new framework should steal / avoid

**Steal:** the per-surface frame clock with explicit phases and freeze-until-frame-callback coalescing; the `GSource` integration pattern (windowing as one source in a shared loop) and its macOS inversion as the template for "the native loop must own things"; the [no-buffer-no-window][no-buffer-no-window] freeze/thaw on first configure; the broad-but-gated Wayland protocol table with build-time + runtime guards; the async MIME-stream clipboard with INCR/delayed-rendering done right.

**Avoid (or decide consciously):** pushing IME entirely above the windowing layer if you want the windowing layer to be reusable standalone; binding _only_ the KDE server-decoration protocol; omitting pointer constraints if any client might be a game; relying on a deprecated vsync API (`CVDisplayLink`) without a migration plan.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact GTK 3→4 `GdkWindow` removal commit/MR sequence.** The shallow clone has no tags; the answer is in the [GNOME/gtk][gtk-repo] git history around the 4.0 cycle and the GitLab MRs referenced from the [4.0 release news][gtk4-news].
- **Whether `xdg-decoration` support was ever proposed and rejected** (vs. just never added). Likely in the GNOME GitLab issue tracker; background in the [CSD initiative][gtk-csd-issue].
- **Android/Broadway windowing depth.** Both backends are present (`gdk/android/`, `gdk/broadway/`) but out of scope here; Broadway renders to HTML5 canvas over WebSocket and Android wraps `ANativeWindow` — each warrants its own pass.
- **TSF migration for Windows IME.** Whether `gtk/gtkimcontextime.c` will move from IMM32 to TSF — check the GNOME GitLab tracker.

---

## Sources

- [GNOME/gtk][gtk-repo] at commit [`817caae3`][gtk-commit] — all quoted file paths
- [`gdk/gdksurface.c`][gdksurface-c], [`gdk/gdktoplevel.c`][gdktoplevel-c], [`gdk/gdkpopup.c`][gdkpopup-c] — the abstract surface model
- [`gdk/gdkframeclock.c`][gdkframeclock-c], [`gdk/gdkframeclockidle.c`][gdkframeclockidle-c] — frame scheduling
- [`gdk/wayland/gdkeventsource.c`][gwes], [`gdk/wayland/gdksurface-wayland.c`][gwsc], [`gdk/wayland/gdktoplevel-wayland.c`][gtw], [`gdk/wayland/gdkpopup-wayland.c`][gpw], [`gdk/wayland/gdkseat-wayland.c`][gws], [`gdk/wayland/meson.build`][gwmeson] — Wayland backend
- [`gdk/x11/gdkeventsource.c`][gx11es], [`gdk/x11/gdksurface-x11.c`][gx11s] — X11 backend
- [`gdk/win32/gdkwin32messagesource.c`][gwms], [`gdk/win32/gdkevents-win32.c`][gwe], [`gdk/win32/gdkclipdrop-win32.c`][gcw], [`gdk/win32/gdkdisplay-win32.c`][gwd] — Win32 backend
- [`gdk/macos/gdkmacoseventsource.c`][gmes], [`gdk/macos/gdkdisplaylinksource.c`][gmdls], [`gdk/macos/gdkmacostoplevelsurface.c`][gmtl] — macOS backend
- [`gtk/gtkimcontextwayland.c`][gimw], [`gtk/gtkimcontextime.c`][gimi] — IME (above GDK)
- [GDK 4 API reference][gdk-docs], [GTK 4 migration guide][gtk4-migration], [GTK 4.0 release news][gtk4-news]
- Sibling docs: [concepts][concepts], [window-system index][wsi-index], [ui-layout survey][ui-layout], [async-io survey][async-index]

<!-- References -->

[gtk-repo]: https://github.com/GNOME/gtk
[gtk-commit]: https://github.com/GNOME/gtk/tree/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671
[gdk-docs]: https://docs.gtk.org/gdk4/
[gtk-docs]: https://docs.gtk.org/gtk4/
[gtk4-news]: https://blog.gtk.org/2020/12/16/gtk-4-0/
[gtk4-migration]: https://docs.gtk.org/gtk4/migrating-3to4.html
[gtk-csd-issue]: https://wiki.gnome.org/Initiatives/CSD
[gdksurface-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurface.c
[gdktoplevel-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdktoplevel.c
[gdkpopup-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdkpopup.c
[gdkframeclock-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdkframeclock.c
[gdkframeclockidle-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdkframeclockidle.c
[gwes]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdkeventsource.c
[gwsc]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdksurface-wayland.c
[gwsw]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdksurface-wayland.c#L899
[gtw]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdktoplevel-wayland.c
[gpw]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdkpopup-wayland.c
[gws]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdkseat-wayland.c
[gwmeson]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/meson.build
[gwsh]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdkwaylandsurface.h
[gx11es]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/x11/gdkeventsource.c
[gx11s]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/x11/gdksurface-x11.c
[gx11h]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/x11/gdkx11surface.h
[gwms]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/win32/gdkwin32messagesource.c
[gwe]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/win32/gdkevents-win32.c
[gcw]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/win32/gdkclipdrop-win32.c
[gwd]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/win32/gdkdisplay-win32.c
[gmes]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/macos/gdkmacoseventsource.c
[gmdls]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/macos/gdkdisplaylinksource.c
[gmtl]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/macos/gdkmacostoplevelsurface.c
[gimw]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkimcontextwayland.c
[gimi]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkimcontextime.c
[ti-xml]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/unstable/text-input/text-input-unstable-v3.xml
[wm-dpichanged]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[tsf]: https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework
[concepts]: ./concepts.md
[wsi-index]: ./index.md
[csd-vs-ssd]: ./concepts.md#csd-vs-ssd
[scancode-keysym]: ./concepts.md#scancode-keysym-virtualkey
[logical-vs-physical]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pre-edit]: ./concepts.md#pre-edit-composition
[override-redirect]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal-loop]: ./concepts.md#win32-modal-resize-loop
[raw-vs-accel]: ./concepts.md#raw-vs-accelerated-pointer
[no-buffer-no-window]: ./concepts.md#no-buffer-no-window
[frame-callback-vsync]: ./concepts.md#frame-callback-vsync
[readiness-vs-completion]: ./concepts.md#readiness-vs-completion-windowing
[ui-layout]: ../ui-layout/index.md
[async-index]: ../async-io/index.md
