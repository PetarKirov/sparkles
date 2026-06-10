# Cross-Library Synthesis: How Fifteen Toolkits Integrate with the Window System

The capstone of the [window-system-integration][index] survey. It distils the fifteen
deep-dives — [Winit][winit], [SDL3][sdl3], [GLFW][glfw], [sokol_app.h][sokol], [Qt 6][qt6],
[GTK 4][gtk4], [Flutter Engine][flutter], [Chromium Ozone][ozone], [Avalonia][avalonia],
[.NET MAUI][maui], [Uno Platform][uno], [Slint][slint], [wxWidgets][wxwidgets],
[JUCE][juce], and [Smithay SCTK + libdecor][smithay] — and the shared
[concepts][concepts] vocabulary into a single head-to-head comparison along the ten
dimensions every deep-dive analyses: window lifecycle, the event loop, input (incl. IME),
Wayland specifics, DPI/scaling, multi-window/popups, threading, clipboard/DnD, escape
hatches, and history/regrets.

The goal is not to crown a winner — these systems occupy different niches, from a
3-D-app shim ([sokol][sokol]) to a browser's platform layer ([Chromium Ozone][ozone]) — but
to surface **where the field is unanimous** (the consensus standards a new toolkit should
simply adopt), **where it forks** (the genuine architectural decisions, with the strongest
argument on each side drawn from the evidence), and **what gap a from-scratch framework
faces today** (the [delta table](#part-5-the-delta-table) that bridges into
[recommendations][recommendations]).

> [!NOTE]
> **Scope.** This is the _synthesis_ leaf of the survey. It assumes the shared mechanics —
> [client-vs-server decorations][csd], [scancode/keysym/virtual-key][scancode],
> [logical vs physical coordinates][coords], [the scale factor][scale],
> [IME pre-edit][preedit], [override-redirect vs xdg_popup grab][popup],
> [the Win32 modal resize loop][modalloop], [raw vs accelerated pointer][pointer],
> [no-buffer-no-window][nobuffer], [frame-callback vsync][vsync], and
> [readiness vs completion in the loop][readiness] — as defined in [concepts][concepts],
> and cross-links rather than re-derives them. Each per-subject deep-dive is the source of
> truth for its own claims.

**Last reviewed:** June 8, 2026

---

## Part 1 — The systems at a glance

One row per surveyed system. **Loop ownership** is the [readiness-vs-completion][readiness]
loop-ownership fork (poll = app-owned; callback = library/OS-owned; hybrid = both).
**Native coord unit** is the [logical-vs-physical][coords] design choice. **Wayland
decoration** is the [CSD/SSD][csd] strategy. **Escape hatch** is the raw-handle / native
passthrough shape (dimension 9).

| Library                                | Language    | Category                            | Loop ownership                | Native coord unit             | Wayland decoration                           | Threading                       | Escape hatch                                           |
| -------------------------------------- | ----------- | ----------------------------------- | ----------------------------- | ----------------------------- | -------------------------------------------- | ------------------------------- | ------------------------------------------------------ |
| **[Winit][winit]**                     | Rust        | windowing library                   | callback (own loop)           | **physical**                  | own-drawn Adwaita (`sctk-adwaita`)           | main-thread; `with_any_thread`  | `raw-window-handle` + per-platform getters             |
| **[SDL3][sdl3]**                       | C           | windowing + media library           | **hybrid** (poll / callbacks) | **mixed** (per-platform)      | SSD-first → libdecor CSD                     | main-thread (AppKit/UIKit)      | properties bag + message-pump hooks                    |
| **[GLFW][glfw]**                       | C           | minimal windowing library           | **poll** (app-owned)          | **mixed** (window vs fb size) | libdecor → SSD → own-drawn fallback          | main-thread                     | typed `glfwGet*Window` accessors                       |
| **[sokol_app.h][sokol]**               | C99         | single-header app shim              | callback (own loop)           | mixed (physical fb)           | **N/A — no Wayland backend** (X11 only)      | callbacks one thread            | type-erased `void*` getters                            |
| **[Qt 6 (QPA)][qt6]**                  | C++         | full GUI framework (QPA layer)      | hybrid (Qt owns `QEventLoop`) | **logical**                   | own-drawn CSD plugins (predates libdecor)    | GUI = main thread               | `QNativeInterface` + native event filter               |
| **[GTK 4 / GDK][gtk4]**                | C (GObject) | full framework (ref. WL client)     | callback/hybrid (GLib source) | **logical**                   | own-drawn CSD; **only** KDE SSD protocol     | single main thread              | native handle getters + `wl_display` exposure          |
| **[Flutter Engine][flutter]**          | C/C++       | engine / embedder framework         | callback/hybrid (embedder)    | **mixed** (logical + ratio)   | **N/A — delegates to GTK 3 / GDK**           | platform = embedder main thread | native handle getters + `WindowProcDelegate`           |
| **[Chromium Ozone][ozone]**            | C++         | browser platform-abstraction        | hybrid (fd → `MessagePump`)   | **mixed** (DIP + pixel)       | SSD-first → own Views-drawn CSD              | UI thread; GPU off-thread       | `gfx::AcceleratedWidget` + mix-in extension interfaces |
| **[Avalonia][avalonia]**               | C# (.NET)   | from-scratch Skia UI framework      | hybrid (managed Dispatcher)   | **logical** (DIPs)            | **N/A — no native Wayland** (X11/XWayland)   | UI thread; render off-thread    | `TryGetPlatformHandle` + `WndProcHookCallback`         |
| **[.NET MAUI][maui]**                  | C# (.NET)   | native-control-wrapping framework   | **callback** (owns no loop)   | **logical** (DIPs)            | **N/A — no Linux desktop backend**           | main-thread only                | `handler.PlatformView` (literal native window)         |
| **[Uno Platform][uno]**                | C# (.NET)   | WinUI-over-Skia framework           | hybrid (per-platform)         | **logical** (view pixels)     | **N/A — no native Wayland** (XWayland)       | dispatcher thread; render off   | `NativeWindow` handle getters + per-window `WndProc`   |
| **[Slint][slint]**                     | Rust        | reactive UI on a backend abstr.     | hybrid (winit / calloop KMS)  | **logical**                   | own-drawn CSD via winit (`sctk-adwaita`)     | loop thread; main on macOS      | `with_winit_window` + `raw-window-handle`              |
| **[wxWidgets][wxwidgets]**             | C++         | native-widget-wrapping framework    | callback/delegated (native)   | **logical** (DIPs)            | **N/A — delegated to GTK**                   | main-thread only                | `GetHandle()` + `MSWWindowProc` + `wxNativeWindow`     |
| **[JUCE][juce]**                       | C++         | audio-focused GUI framework         | hybrid (own / host-as-plugin) | **mixed** (logical Component) | **N/A — no Wayland backend** (X11 only)      | single message thread           | `getNativeHandle()` `void*` + FD registration          |
| **[Smithay SCTK + libdecor][smithay]** | Rust + C    | Wayland client toolkit + CSD helper | **poll** (caller-owned)       | **logical** (integer only)    | three-tier: SSD → `FallbackFrame` → libdecor | no main-thread rule             | raw proxy getters; caller bridges `raw-window-handle`  |

Two structural observations fall straight out of the table and frame the rest of this
document:

1. **The "Wayland decoration" column is mostly empty.** Of fifteen, only six speak Wayland
   natively ([Winit][winit], [SDL3][sdl3], [GLFW][glfw], [Qt 6][qt6], [GTK 4][gtk4],
   [Chromium Ozone][ozone], [Slint][slint] via winit, [Smithay][smithay]); the rest either
   have no Linux backend ([MAUI][maui]), run under XWayland as an X11 client
   ([Avalonia][avalonia], [Uno][uno], [JUCE][juce], [sokol][sokol]), or delegate to GTK
   ([Flutter][flutter], [wxWidgets][wxwidgets]). **Native Wayland is the single biggest gap
   in the field** — and the headline finding for a new toolkit (see
   [§Dimension 4](#dimension-4-wayland-specifics) and [§Part 5](#part-5-the-delta-table)).
2. **Loop ownership and native coordinate unit are the two axes that genuinely fork.** Every
   other dimension trends toward a consensus (Part 3); these two are real decisions with
   strong arguments on both sides (Part 4).

---

## Part 2 — Per-dimension comparison

Each subsection cuts one of the ten analysis-spine dimensions across all fifteen subjects.

### Dimension 1 — Window creation & lifecycle

The fork is **synchronous map (X11/Win32) vs the asynchronous [no-buffer-no-window][nobuffer]
handshake (Wayland)**. On X11/Win32, `CreateWindowEx`+`ShowWindow` / `XMapWindow` puts the
window on screen immediately; on Wayland a `wl_surface` is invisible until a buffer is
committed _and_ the compositor has sent the initial `xdg_surface.configure`.

| Library                                                        | Create-window model                                                                  |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| [Winit][winit]                                                 | constructor **blocks** in `roundtrip`+`blocking_dispatch` until `is_configured()`    |
| [SDL3][sdl3]                                                   | `Wayland_ShowWindow` spins on `libdecor_dispatch` until the first configure          |
| [GLFW][glfw]                                                   | `xdg_toplevel` created only if visible/monitor; commit+roundtrip before first buffer |
| [Smithay SCTK][smithay]                                        | draws the first frame **inside** `WindowHandler::configure`, never on creation       |
| [Chromium Ozone][ozone]                                        | surface unmapped until buffer; `set_window_geometry` silently dropped without one    |
| [Slint][slint]                                                 | **destroys** the window on hide (winit won't create an invisible Wayland window)     |
| [Qt 6][qt6]                                                    | `QWaylandWindow::isExposed()` false until configure; expose fires only after it      |
| [GTK 4][gtk4]                                                  | `gdk_toplevel_present()` single async entry; freeze/thaw on first configure          |
| [Flutter][flutter]                                             | lifecycle delegated to GDK; engine itself owns no window                             |
| [Avalonia][avalonia], [Uno][uno], [JUCE][juce], [sokol][sokol] | synchronous X11 map (no Wayland to negotiate)                                        |
| [MAUI][maui], [wxWidgets][wxwidgets]                           | delegated to the native/host stack (WinUI, GTK, UIKit)                               |

The recurring lesson, recorded most sharply in [SDL3][sdl3]'s bug tail (KDE bug 448856):
**retrofitting a synchronous "create then show" API onto the async handshake is fragile —
model the lifecycle as explicit state from the start.** The same rule produces the
universal Wayland no-op: clients **cannot set their own toplevel position**
([SDL3][sdl3], [GLFW][glfw], [GTK 4][gtk4], [Chromium Ozone][ozone], [Smithay][smithay] all
record `SetWindowPosition` as a silent no-op), because the compositor owns placement.

### Dimension 2 — The event loop

Three loop-ownership models, mapped to [readiness vs completion in the loop][readiness]:

| Model                                    | Who drives                                         | Subjects                                                                                                                                                        |
| ---------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Poll (app-owned)**                     | app calls `PollEvents` / dispatches the loop       | [GLFW][glfw], default [SDL3][sdl3], [Smithay SCTK][smithay]                                                                                                     |
| **Callback (library/OS-owned)**          | control inverted; the OS/library calls the app     | [Winit][winit] (`ApplicationHandler`), [sokol][sokol], [MAUI][maui], opt-in [SDL3][sdl3]                                                                        |
| **Hybrid (own loop over native source)** | toolkit owns a dispatcher wrapping the native pump | [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [Uno][uno], [JUCE][juce], [Flutter][flutter], [Chromium Ozone][ozone], [wxWidgets][wxwidgets], [Slint][slint] |

On Linux the loop is, underneath, a **readiness reactor over the display socket fd**.
[Winit][winit] wraps the Wayland socket as a `calloop` `WaylandSource` and exposes `AsFd` so
embedders can poll it; [Smithay][smithay] integrates via `calloop-wayland-source`;
[Chromium Ozone][ozone] plugs the fd into `base::MessagePump` and runs a **dedicated fd-watch
thread** to dodge the libwayland `prepare_read` single-reader deadlock when a GPU/EGL also
reads it; [GTK 4][gtk4] integrates as a GLib `GSource` (and **inverts** on macOS so
`CFRunLoop` drives GLib via a `select` thread).

Two pervasive event-loop hazards recur:

- **The [Win32 modal resize/move loop][modalloop]** freezes redraws during a titlebar drag.
  The survey-wide fix is identical: `SetTimer` on `WM_ENTERSIZEMOVE`, drive a frame from
  `WM_TIMER` ([SDL3][sdl3], [GTK 4][gtk4], [sokol][sokol], [Uno][uno]). [Winit][winit] and
  [sokol][sokol] add the dummy-`WM_MOUSEMOVE` trick to cancel the ~500 ms first-click pause.
  [Qt 6][qt6], [JUCE][juce], [wxWidgets][wxwidgets] track an in-size-move flag and accept the
  loop is mitigated, not eliminated.
- **Nested native loops on macOS.** [wxWidgets][wxwidgets] and [Avalonia][avalonia] document
  at length that `[NSApp run]` may only be the outermost loop; nested loops must use
  `nextEventMatchingMask:`. [Flutter][flutter] adds a custom `CFRunLoopMode`
  (`FlutterRunLoopMode`) to common+private modes to survive modal run loops — the cleanest
  recorded fix for a guest-on-host-loop design.

### Dimension 3 — Input (keyboard, pointer, IME)

Keyboard input splits the [scancode / keysym / virtual-key][scancode] identities. On Linux
the consensus translator is **[xkbcommon][xkbcommon]**; the cautionary cases are the toolkits
that ship their own table and inherit layout bugs.

| Concern                | Consensus / fork                                                                                                                                                                                                                                                     |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keymap state machine   | **xkbcommon** everywhere on Linux ([Winit][winit], [SDL3][sdl3], [GTK 4][gtk4], [Chromium Ozone][ozone], [Smithay][smithay]); own table = bug ([Avalonia][avalonia]'s `X11KeyTransform`, [JUCE][juce]'s `XLookupString`-only, [wxWidgets][wxwidgets] hardcoded `us`) |
| Wayland keycode offset | universal **`+8`** before every xkb call (wl_keyboard delivers raw evdev)                                                                                                                                                                                            |
| Key repeat (Wayland)   | **client-synthesised** (timer per held key) everywhere — the protocol only sends rate/delay                                                                                                                                                                          |
| High-res scroll        | universal **`axis_value120` / `WHEEL_DELTA=120`** accumulator (1/120-detent) ([SDL3][sdl3], [Smithay][smithay], [GLFW][glfw], [Qt 6][qt6], [GTK 4][gtk4])                                                                                                            |
| Raw/relative pointer   | separate event source (`zwp_relative_pointer_v1` / `WM_INPUT`); [GTK 4][gtk4] binds **none** (not a game toolkit)                                                                                                                                                    |

IME ([pre-edit/composition][preedit]) is the most uneven dimension and produces two
field-wide findings:

| Platform | Modern protocol                    | What the field actually does                                                                                                                            |
| -------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wayland  | `zwp_text_input_v3`                | [SDL3][sdl3], [Winit][winit], [Qt 6][qt6] bind it; **GDK does not** ([GTK 4][gtk4] does IME above GDK); [Smithay][smithay] ships no consumer            |
| Win32    | [Text Services Framework][tsf]     | **nobody** uses TSF — [SDL3][sdl3], [Winit][winit], [Qt 6][qt6], [GTK 4][gtk4], [JUCE][juce], [Avalonia][avalonia], [Uno][uno] all use **legacy IMM32** |
| macOS    | [`NSTextInputClient`][nstextinput] | [SDL3][sdl3], [Winit][winit], [JUCE][juce] implement it; [GLFW][glfw] mispositions the candidate window                                                 |
| X11      | XIM (or D-Bus IBus/Fcitx)          | [Winit][winit]/[SDL3][sdl3] use XIM; [Uno][uno] uses D-Bus IBus/Fcitx; [GLFW][glfw], [JUCE][juce], [sokol][sokol] omit pre-edit entirely                |

**Finding 1: the universal IMM32-over-TSF choice on Windows** — not one toolkit uses the
modern TSF. **Finding 2: IME is frequently absent** — [GLFW][glfw] (issue #41 open since
2013), [JUCE][juce]'s X11, [sokol][sokol], [Smithay][smithay], and [MAUI][maui] all punt it,
confirming that pre-edit is table-stakes-but-tedious and a reusable windowing layer should
own the consumer rather than push it upward (as [GTK 4][gtk4] does to GDK).

### Dimension 4 — Wayland specifics

The dimension that most sharply separates the field. **Only six subjects are native Wayland
clients**; the rest are absences-as-findings.

| Wayland posture                     | Subjects                                                                                                                                              |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Native Wayland client**           | [Winit][winit], [SDL3][sdl3], [GLFW][glfw], [Qt 6][qt6], [GTK 4][gtk4], [Chromium Ozone][ozone], [Smithay SCTK][smithay] (+ [Slint][slint] via winit) |
| **Delegates to GTK/GDK**            | [Flutter][flutter] (GTK 3), [wxWidgets][wxwidgets] (GTK 3)                                                                                            |
| **XWayland only (X11 client)**      | [Avalonia][avalonia], [Uno][uno], [JUCE][juce], [sokol][sokol]                                                                                        |
| **No Linux desktop backend at all** | [MAUI][maui]                                                                                                                                          |

Even among native clients, the protocol coverage is patchy and itself a finding:

- **Decorations:** [GTK 4][gtk4] binds **neither** libdecor **nor** `zxdg-decoration-v1`
  (only the KDE protocol), so on wlroots it always falls back to own CSD. [Chromium
  Ozone][ozone] and [SDL3][sdl3] prefer SSD then fall back (Ozone to own Views-drawn CSD,
  SDL3 to libdecor) because **GNOME/Mutter advertises no `xdg-decoration` at all**.
- **Fractional scale:** [Smithay SCTK][smithay] implements **none** (integer only) — the
  cautionary tale; [GTK 4][gtk4]/[Qt 6][qt6]/[GLFW][glfw] bind `wp_fractional_scale_v1`+`viewporter`.
- **Pointer constraints / relative motion:** [GTK 4][gtk4] binds none — no FPS-style input.
- **layer-shell / idle-inhibit:** unbound by [GTK 4][gtk4] and upstream [Qt 6][qt6] 6.8.

[Smithay SCTK + libdecor][smithay] is the **catalog authority** for this dimension: it is the
only Wayland-only subject, and its three-tier decoration story (compositor SSD →
`FallbackFrame` → libdecor `dlopen` plugin) is the reference model.

### Dimension 5 — DPI & scaling

The native-coordinate fork (dimension covered in [§Part 4](#fork-b-logical-vs-physical-native-coordinates))
plays out here as **where the scale comes from** and **two hazards**. See [the scale
factor][scale].

| Platform | Scale source (consensus)                                                                 |
| -------- | ---------------------------------------------------------------------------------------- |
| Wayland  | `wp_fractional_scale_v1` (preferred scale as integer 1/120ths) + `wp_viewporter`         |
| Win32    | Per-Monitor-V2 awareness; [`WM_DPICHANGED`][wmdpichanged] (`scale = dpi/96`)             |
| macOS    | `NSWindow.backingScaleFactor` (integer 1×/2× only)                                       |
| X11      | **no per-surface protocol** — scrape global `Xft.dpi` or guess (the universal weak spot) |

- **Created-at-wrong-scale:** [Winit][winit]'s `ScaleFactorChanged` ships a
  `surface_size_writer`; [Slint][slint] dispatches `ScaleFactorChanged` on creation _before_
  first paint — the two cleanest cures. [GTK 4][gtk4]/[wxWidgets][wxwidgets] correct after
  realization on the first configure.
- **Mixed-DPI migration:** Win32 re-fires `WM_DPICHANGED` and Wayland re-fires
  `preferred_scale`; **X11 single-global-DPI cannot** — so every XWayland/X11-only toolkit
  ([Avalonia][avalonia] (`#13450`), [Uno][uno], [JUCE][juce] integer-only + `dconf` shell-out,
  [sokol][sokol] high-DPI TODO) inherits blurry mixed-DPI.

### Dimension 6 — Multi-window & popups

Two independent capabilities: multiple top-levels, and transient
[override-redirect / xdg_popup grab][popup] surfaces (menus, tooltips, dropdowns).

| Capability                               | Subjects                                                                                                                                                  |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Multi-window first-class                 | most frameworks ([Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [Uno][uno] (5.2), [Flutter][flutter] (settling), [wxWidgets][wxwidgets], [JUCE][juce]) |
| **Single window only**                   | [sokol][sokol] (static `_sapp` precludes it architecturally)                                                                                              |
| **No cross-platform popup grab**         | [Winit][winit] (only X11 `_NET_WM_WINDOW_TYPE` hints — punts entirely)                                                                                    |
| Real OS popups (X11 override-redirect)   | [SDL3][sdl3], [Avalonia][avalonia] (`ManagedPopupPositioner`), [Qt 6][qt6] (`BypassWindowManagerHint`)                                                    |
| Real OS popups (`xdg_popup` grab)        | [SDL3][sdl3], [Smithay][smithay] (`Popup`/`XdgPositioner`), libdecor window-menu grab                                                                     |
| **In-canvas popups** (no OS sub-surface) | [Uno][uno], [Slint][slint] (winit backend) — sidestep the fork, lose compositor dismiss                                                                   |

The cross-platform consequence the survey keeps hitting: a popup abstraction **cannot** be a
simple "place this window at (x, y)" call, because that maps onto neither the X11
override-redirect model nor the Wayland parent-relative `xdg_positioner` model cleanly.
[Winit][winit] punts it to consumers; the framework toolkits either draw in-canvas or carry
both native paths.

### Dimension 7 — Threading

The most unanimous dimension in the survey: **GUI = main thread, forced by macOS AppKit.**

| Threading posture                       | Subjects                                                                                                                                                                                  |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Main-thread-only for windows/events** | [SDL3][sdl3], [GLFW][glfw], [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [MAUI][maui], [wxWidgets][wxwidgets], [JUCE][juce], [Flutter][flutter], [Chromium Ozone][ozone] (UI thread) |
| Main-thread on macOS, relaxed elsewhere | [Winit][winit] (`MainThreadMarker` panics off-main; `with_any_thread` on Linux/Win), [Slint][slint]                                                                                       |
| **No main-thread rule**                 | [Smithay SCTK][smithay] (Wayland has no such constraint; events on the dispatch thread)                                                                                                   |

The constraint is **driven by one platform** — every deep-dive that explains _why_ it is
main-thread-only ([JUCE][juce], [Qt 6][qt6], [wxWidgets][wxwidgets], [Avalonia][avalonia])
names AppKit. Rendering is commonly off-thread ([Avalonia][avalonia], [Uno][uno],
[Chromium Ozone][ozone]'s sandboxed GPU process); cross-thread work marshals back via a
dispatcher/`CallAfter`/`MessageManagerLock`. The only escapee is [Smithay][smithay], because
it never touches AppKit.

### Dimension 8 — Clipboard & drag-and-drop

The consensus is that clipboard is a **negotiated, MIME/atom-typed, chunked** transfer, and
that doing it _well_ (large transfers, rich formats, DnD) is where toolkits cut corners.

| Behaviour                    | Field finding                                                                                                                                                                            |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| X11 large transfers (`INCR`) | done right by [Qt 6][qt6], [GTK 4][gtk4]; **deliberately skipped** by [JUCE][juce] (~1 MB cap, "a pain in the \*ss"), [sokol][sokol] (detected, not implemented), [Uno][uno] (read-only) |
| Async MIME-stream clipboard  | [GTK 4][gtk4] (with delayed rendering) is the model                                                                                                                                      |
| Wayland MIME mapping         | [wxWidgets][wxwidgets] needs an X11-atom→Wayland-MIME table (`wxGTKGetAltWaylandFormat`)                                                                                                 |
| Text-only clipboard          | [Slint][slint], [Flutter][flutter] (Linux `text/plain` only) — DnD/rich formats punted                                                                                                   |
| **No portable drag-source**  | [SDL3][sdl3] (drop-target only); DnD is plugin territory for [Flutter][flutter]                                                                                                          |

DnD is consistently the weakest corner: no surveyed minimal/windowing library offers a
portable drag **source**, and frameworks that have it inherit it from the wrapped native
toolkit.

### Dimension 9 — Escape hatches

Universal: **every toolkit exposes the native handle.** The fork is _how typed_ it is, and
whether raw native-event passthrough exists. The consensus modern shape is
**`raw-window-handle`-style typed handoff** for GPU interop.

| Escape-hatch shape                       | Subjects                                                                                                                                                                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Typed `raw-window-handle` (rwh 0.6)**  | [Winit][winit], [Slint][slint] (caller bridges in [Smithay][smithay])                                                                                                                                                                      |
| Typed per-platform accessors             | [GLFW][glfw] (`glfwGet*Window`), [Qt 6][qt6] (`QNativeInterface`), [Avalonia][avalonia] (`IMacOSTopLevelPlatformHandle`)                                                                                                                   |
| ABI-stable property/struct lookup        | [SDL3][sdl3] (properties bag), [sokol][sokol] (`sapp_get_swapchain` value struct)                                                                                                                                                          |
| **Type-erased `void*`**                  | [sokol][sokol], [JUCE][juce] ("no guarantees what you'll get back")                                                                                                                                                                        |
| Literal native window object             | [MAUI][maui] (`handler.PlatformView`), [Flutter][flutter] (`HWND`/`NSView`/`GtkWidget`)                                                                                                                                                    |
| Raw message-pump passthrough             | [SDL3][sdl3] (`SetWindowsMessageHook`/`SetX11EventHook`), [Qt 6][qt6] (native event filter), [Avalonia][avalonia]/[Uno][uno]/[wxWidgets][wxwidgets]/[JUCE][juce] (`WndProc`); [Winit][winit] (Win32 `msg_hook`); **[GLFW][glfw] has none** |
| Capability probing (not a fat interface) | [Avalonia][avalonia] (`TryGetFeature<T>`), [Qt 6][qt6] (`hasCapability`), [Slint][slint] (`WindowAdapter` trait), [Chromium Ozone][ozone] (mix-in extension interfaces)                                                                    |

The strongest recorded pattern is **naming the leak**: [Chromium Ozone][ozone]'s
`X11Extension` and [Avalonia][avalonia]'s `[PrivateApi]`/`TryGetFeature<T>` document exactly
where the abstraction is incomplete instead of pretending completeness — the opposite of
[JUCE][juce]'s un-typed `void*`.

### Dimension 10 — History, redesigns & known regrets

The field's collective scar tissue, and the most direct input to a new design:

| Library                 | Defining redesign / standing regret                                                                                    |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| [Winit][winit]          | Event Loop 2.0 (iterator → callback, 2018-20); 0.30 `ApplicationHandler`; recurring renames                            |
| [SDL3][sdl3]            | main-callbacks model; properties bag replaces typed getters; gestures removed (no replacement)                         |
| [GLFW][glfw]            | Wayland 3.2 (2016), libdecor 3.4 (2024); IME still omitted (issue #41 since 2013)                                      |
| [sokol][sokol]          | window/swapchain decoupled (2025); MTKView → CAMetalLayer+CADisplayLink (2026); Wayland open since 2020                |
| [Qt 6][qt6]             | QPA "Lighthouse" (2012); high-DPI always-on in 6.0; QPA contract kept `\internal`                                      |
| [GTK 4][gtk4]           | GdkWindow removed → one GdkSurface per toplevel (4.0); Wayland-first protocol expansion                                |
| [Flutter][flutter]      | GLFW prototype → GObject GTK 3; multi-view (2022-23); multi-window (2024-25, settling); GTK 3 pin                      |
| [Chromium Ozone][ozone] | "Interfaces not ifdefs" (2013-16); dedicated Wayland fd thread (2021); legacy X11 removed (2021)                       |
| [Avalonia][avalonia]    | Dispatcher rewrite (2023, WPF model); platform interfaces marked `[PrivateApi]` (v11); Wayland open since 2017 (#1243) |
| [MAUI][maui]            | Xamarin.Forms renderers → handler/`PropertyMapper` (2022); Linux desktop repeatedly declined                           |
| [Uno][uno]              | from-scratch X11/Win32 hosts replace GTK+3 (5.2, 2024, −200 MB); multi-window (5.2)                                    |
| [Slint][slint]          | winit 0.30 forced `ApplicationHandler` + lazy `WinitWindowOrNone` (1.7); winit default everywhere (1.16)               |
| [wxWidgets][wxwidgets]  | GTK1→2→3 migrations; GTK4 still not shipping (no `--with-gtk=4`); own `wl_display` for pointer-warp                    |
| [JUCE][juce]            | Direct2D backend (JUCE 8, 2024); X11-only on Linux (Wayland gap since 2019, #549)                                      |
| [Smithay][smithay]      | rewritten onto wayland-rs 0.30+ handler-trait model (~2020); `delegate_dispatch2!` collapse (2025-26)                  |

The two regrets that **every** verdict converges on: **(a) deferring native Wayland**
inherits XWayland's ceiling (no fractional scale, no frame-callback vsync, no `xdg_popup`
grabs) — voiced by [Avalonia][avalonia] (8-year delay), [JUCE][juce], [Uno][uno],
[sokol][sokol], [MAUI][maui]; and **(b) under-specifying the windowing contract** (pushing
title/decoration/popups/fullscreen onto embedders) yields "silently unsupported per platform"
— voiced by [Flutter][flutter] and [MAUI][maui].

---

## Part 3 — The consensus standards

Where the field is unanimous, a new toolkit should simply adopt the standard and move on.
The survey establishes these:

1. **xkbcommon for keymaps on Linux.** Every native Linux backend uses
   [xkbcommon][xkbcommon] for scancode→keysym translation; the toolkits that ship their own
   table ([Avalonia][avalonia], [JUCE][juce], [wxWidgets][wxwidgets]) are explicitly recorded
   as inheriting layout bugs. Corollary standards: the **`+8` evdev→xkb keycode offset** and
   **client-side key-repeat synthesis** on Wayland.
2. **GUI on the main thread.** Forced by macOS AppKit and adopted uniformly
   ([§Dimension 7](#dimension-7-threading)); rendering goes off-thread, cross-thread work
   marshals back through a dispatcher.
3. **`raw-window-handle`-style typed handle handoff** for windowing↔rendering decoupling.
   [Winit][winit] pioneered drawing _nothing_ and handing a typed handle to the GPU layer;
   it is now the reference shape ([Slint][slint], and the pattern [JUCE][juce]'s `void*` is
   critiqued against).
4. **The `axis_value120` / `WHEEL_DELTA=120` high-resolution scroll accumulator** — the
   1/120-detent convention shared verbatim between Wayland and Win32, accumulated per frame
   ([SDL3][sdl3], [Smithay][smithay], [GLFW][glfw], [Qt 6][qt6], [GTK 4][gtk4]).
5. **Per-Monitor-V2 DPI awareness + `WM_DPICHANGED` (`scale = dpi/96`)** on Win32, and
   **`wp_fractional_scale_v1` + `viewporter`** on Wayland, as the scale sources.
6. **"SSD is only a hint."** Per the `xdg-decoration` protocol there is no reliable way to
   force or forbid server-side decorations, so **every serious toolkit must carry a CSD
   path** ([§Dimension 4](#dimension-4-wayland-specifics)) — the lesson GNOME forced on the
   ecosystem.
7. **Model the Wayland window lifecycle as explicit async state** — the
   [no-buffer-no-window][nobuffer] handshake (commit-without-buffer → wait for configure →
   ack → attach buffer) cannot be hidden behind a synchronous "create then show" without
   fragility.
8. **The Win32 `SetTimer`-driven live-resize workaround** for the
   [modal resize loop][modalloop] — identical in spirit across every Win32 backend.

These are not decisions; they are table stakes.

---

## Part 4 — The architectural trade-offs (where the field forks)

Four genuine forks, each presented as a decision with the strongest argument for each side
drawn from the evidence.

### Fork A — Poll vs callback event loop

| Side                         | Strongest argument (from the evidence)                                                                                                                                                                                                                               |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Poll (app-owned)**         | The smallest honest API; the app stays in control and can add its own fd sources. [GLFW][glfw]'s `PollEvents`/`WaitEvents`/`PostEmptyEvent` is "the smallest honest event-loop API."                                                                                 |
| **Callback (library-owned)** | The **only** model that survives Web/iOS/macOS, where the OS owns the loop. [Winit][winit] abandoned its `poll_events()` iterator for exactly this reason; [SDL3][sdl3] added opt-in `SDL_MAIN_USE_CALLBACKS` to run where the OS owns the loop _without `#ifdef`s_. |

**Resolution the evidence points to:** the **hybrid** ([SDL3][sdl3]) — a dead-simple
app-owned pump as the default _plus_ an opt-in inverted callback model — is the design most
verdicts praise, because the callback model is mandatory on some platforms but the poll model
is the more ergonomic default everywhere else. The deeper requirement, voiced by [GLFW][glfw]
and [sokol][sokol]'s verdicts and the [readiness][readiness] concept, is an **external-fd
integration point** so an [async runtime][asyncio] and the windowing loop can share the
process's blocking wait — [Winit][winit]'s `calloop`/`AsFd` story is the reference; its
absence in [GLFW][glfw]/[SDL3][sdl3] is the recorded gap.

### Fork B — Logical vs physical native coordinates

| Side                          | Strongest argument (from the evidence)                                                                                                                                                                                                                                                  |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Physical (device pixels)**  | No hidden conversion; the app sees exactly what the GPU rasterizes and converts itself. [Winit][winit]'s `PhysicalSize`/`PhysicalPosition` are the API-native unit; its `surface_size_writer` lets the app rewrite the post-rescale physical size in-callback.                          |
| **Logical (DIPs)**            | The app lays out resolution-independently; physical pixels appear only at the OS seam. The **majority** of frameworks ([Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [JUCE][juce], [Slint][slint], [MAUI][maui]) choose this, converting at the QPA-style seam (`QHighDpiScaling`). |
| **Mixed (per-platform unit)** | Honest to each OS but inconsistent. [SDL3][sdl3] uses each platform's native unit and **exposes** scale rather than hiding it (distinct pixel-density / content-scale / display-scale with guaranteed change events); [GLFW][glfw] splits window-size vs framebuffer-size.              |

**Resolution the evidence points to:** for an _application_ framework, **logical** is the
majority and the ergonomic default — but the universal corollary, learned the hard way
across the survey, is **never size the render target off the logical window size; size it off
the physical/framebuffer size (or the pixel-size-changed event)**, or you render blurry. The
cleanest cure for the [created-at-wrong-scale][scale] transient is [Slint][slint]'s "learn
the scale before first paint."

### Fork C — Wayland decorations: libdecor vs own-drawn CSD vs punt

| Side                                  | Strongest argument (from the evidence)                                                                                                                                                                                                                                                                          |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **libdecor (delegate CSD)**           | No per-toolkit decoration maintenance; native-looking frames via the desktop's plugin. [Chromium Ozone][ozone]'s verdict: "Don't reimplement CSD by hand if you can integrate libdecor — Chromium's own-drawn path is a maintenance tax." [SDL3][sdl3], [GLFW][glfw], [Smithay][smithay] take this route.       |
| **Own-drawn CSD**                     | Consistent look, no C dependency, full control. [Winit][winit] (`sctk-adwaita`, no libdecor C dep), [Qt 6][qt6] (predates libdecor), [GTK 4][gtk4], [Chromium Ozone][ozone] draw their own — but [Qt 6][qt6]'s own verdict concedes its plugin approach "now diverges from the desktop."                        |
| **Punt (delegate to GTK / X11-only)** | Zero Wayland decoration code at all. [Flutter][flutter]/[wxWidgets][wxwidgets] delegate to GTK; [Avalonia][avalonia]/[Uno][uno]/[JUCE][juce]/[sokol][sokol] are X11-only and inherit the WM's frame. The cost: XWayland's ceiling ([§Dimension 10](#dimension-10-history-redesigns--known-regrets) regret (a)). |

**Resolution the evidence points to:** **carry a CSD path regardless** (SSD is only a hint),
and **prefer libdecor over hand-rolled CSD** unless you have a strong reason for a bespoke
frame — multiple verdicts ([Chromium Ozone][ozone], [Qt 6][qt6]) treat own-drawn CSD as a
tax that drifts from the desktop. [Smithay + libdecor][smithay]'s three-tier model (SSD →
minimal `FallbackFrame` → libdecor) is the reference fallback chain.

### Fork D — Own the windowing layer vs delegate to native

| Side                                                              | Strongest argument (from the evidence)                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Own the pixels** (draw everything, OS window is just a surface) | Full control of frame pacing, raw pointer, inline pre-edit, Wayland popups, custom chrome — none of which a wrapper can add. [Avalonia][avalonia], [Flutter][flutter], [Uno][uno], [Slint][slint], and [winit][winit]-based stacks fill exactly this niche; [MAUI][maui]'s own verdict says a wrapper "cannot get there." |
| **Delegate to native** (wrap the platform toolkit/controls)       | Native fidelity, accessibility, and IME "for free"; far less code. [wxWidgets][wxwidgets]/[MAUI][maui] wrap native controls; [Flutter][flutter]/[wxWidgets][wxwidgets] delegate Linux to GTK to reuse its mature Wayland/IME/clipboard stack.                                                                             |

**The cost of delegating, recorded repeatedly:** you are **perpetually a step behind** on the
display server ([wxWidgets][wxwidgets] is "perpetually a step behind on Wayland and must hack
around its own dependency"), you inherit every native quirk, and capabilities silently no-op
where the wrapped stack lacks them ([MAUI][maui]'s size/position/decorations work on only two
of four platforms). **The cost of owning:** you must build Wayland, IME, frame pacing, and
popup grabs yourself — which is precisely the gap analysed next.

**Resolution the evidence points to:** for a toolkit that wants modern frame pacing, raw
pointer, inline pre-edit, Wayland-native popups, and custom chrome on every OS, **owning the
windowing layer is the only path** — but it must own [the CSD layer][csd], the
[popup/grab model][popup], and the [frame-clock][vsync] from day one, not defer them
(the [Avalonia][avalonia]/[winit][winit] stance the verdicts endorse).

---

## Part 5 — The delta table {#part-5-the-delta-table}

Where a **brand-new from-scratch windowing framework** stands today against the field's
consensus, per dimension — the gap analysis that bridges into
[recommendations][recommendations]. "Field consensus" is the standard from
[Part 3](#part-3-the-consensus-standards) and the resolution from
[Part 4](#part-4-the-architectural-trade-offs-where-the-field-forks); "Gap for a new
framework" is the work that consensus implies a green-field toolkit must do.

| Dimension                        | Field consensus / best-in-class                                                             | Gap for a new framework (build this)                                                            | Reference to steal from                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| **Window lifecycle**             | Async [no-buffer-no-window][nobuffer] state on Wayland; sync map on X11/Win32               | Model lifecycle as explicit async state from day one; one async `present()` entry               | [GTK 4][gtk4] `gdk_toplevel_present`, [Smithay][smithay]      |
| **Event loop**                   | Hybrid poll+callback; **external-fd integration**; Win32 `SetTimer` live-resize             | A pollable-fd loop ([calloop][readiness]-style) that an [async runtime][asyncio] can drive      | [Winit][winit] `calloop`/`AsFd`, [SDL3][sdl3] hybrid          |
| **Input — keymaps**              | [xkbcommon][xkbcommon] + `+8` offset + client-side repeat                                   | Use xkbcommon (don't ship your own table); synthesise Wayland key repeat                        | [Chromium Ozone][ozone], [Smithay][smithay]                   |
| **Input — IME**                  | Separate pre-edit event stream; **own the consumer**; IMM32 on Win32, `text_input_v3` on WL | Own `zwp_text_input_v3` + `NSTextInputClient` + IMM32 (TSF is the open opportunity)             | [SDL3][sdl3], [Winit][winit]                                  |
| **Wayland specifics**            | Native client; SSD-is-a-hint + CSD path; fractional scale; popups                           | **Build a native Wayland client** (the field's biggest gap) — libdecor CSD, fractional scale    | [Smithay + libdecor][smithay] (authority)                     |
| **DPI / scaling**                | Logical native unit; learn scale before first paint; re-fire on migration                   | Protocol-driven scale (not heuristic `Xft.dpi`); size render target off physical size           | [Slint][slint], [Winit][winit] `surface_size_writer`          |
| **Multi-window / popups**        | First-class window handles; both override-redirect **and** `xdg_popup` popup paths          | A popup primitive that maps onto both servers (not "place at (x,y)"); avoid in-canvas-only      | [SDL3][sdl3], [Smithay][smithay] `XdgPositioner`              |
| **Threading**                    | GUI = main thread (AppKit-forced); render off-thread; marshal back                          | Adopt main-thread rule; provide a dispatcher for cross-thread marshalling                       | [Avalonia][avalonia] two-layer `Dispatcher`                   |
| **Clipboard / DnD**              | Async MIME-typed transfer; `INCR` chunking; portable drag **source** (rare)                 | Do `INCR`/async clipboard right; provide a real drag-source (the field's weakest corner)        | [GTK 4][gtk4] async MIME-stream clipboard                     |
| **Escape hatches**               | Typed `raw-window-handle` handoff; capability probing; **name the leaks**                   | Typed handle accessor + `TryGetFeature`-style probe; raw message-pump hook                      | [Winit][winit] rwh, [Avalonia][avalonia] `TryGetFeature`      |
| **Frame pacing** (cross-cutting) | Per-platform [vsync source][vsync] folded into one frame clock; `CADisplayLink` plan        | One frame-clock abstraction over `wl_surface.frame`/`CVDisplayLink`→`CADisplayLink`/DXGI vblank | [GTK 4][gtk4] `GdkFrameClock`, [Slint][slint] `FrameThrottle` |

The single highest-leverage finding for a new framework: **native Wayland is the field's
biggest collective gap** (only ~6 of 15 even attempt it, and the universal regret is having
deferred it), so **on Linux a green-field toolkit's strongest differentiator is to be
Wayland-first** — treating X11 as the legacy path, owning the [CSD][csd]/[popup][popup]/[frame-clock][vsync]
layers itself, and using [Smithay + libdecor][smithay] as the implementation authority. This
is a Linux-backend stance within an otherwise cross-platform design (Win32 and AppKit are
first-class, not afterthoughts); the concrete, milestoned plan for that build-out is
[recommendations][recommendations].

---

## Sources

- Shared vocabulary: [concepts][concepts] (decorations, coordinates, scale, IME, popups, the
  loop) — every term cross-linked above is defined and grounded there.
- Per-subject deep-dives: [Winit][winit], [SDL3][sdl3], [GLFW][glfw], [sokol][sokol],
  [Qt 6][qt6], [GTK 4][gtk4], [Flutter Engine][flutter], [Chromium Ozone][ozone],
  [Avalonia][avalonia], [.NET MAUI][maui], [Uno Platform][uno], [Slint][slint],
  [wxWidgets][wxwidgets], [JUCE][juce], [Smithay SCTK + libdecor][smithay] — each carries its
  own primary-source citations.
- Cross-tree siblings: the [async-io][asyncio] survey (the [readiness][readiness] loop
  concepts the windowing loop shares), the [ui-layout][ui-layout] catalog (the
  rendering/layout layers that sit _on top_ of a windowing substrate), and Sparkles'
  [Design by Introspection][dbi] guideline (the capability-trait ethos
  [Slint][slint]'s `WindowAdapter` mirrors).
- Survey index: [the window-system-integration index][index]; the design plan this synthesis
  bridges into: [recommendations][recommendations].

<!-- References -->

<!-- Topic siblings -->

[index]: ./index.md
[concepts]: ./concepts.md
[recommendations]: ./recommendations.md

<!-- Deep-dives (siblings) -->

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

<!-- Concept anchors (same tree) -->

[csd]: ./concepts.md#csd-vs-ssd
[scancode]: ./concepts.md#scancode-keysym-virtualkey
[coords]: ./concepts.md#logical-vs-physical-coords
[scale]: ./concepts.md#scale-factor
[preedit]: ./concepts.md#pre-edit-composition
[popup]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[modalloop]: ./concepts.md#win32-modal-resize-loop
[pointer]: ./concepts.md#raw-vs-accelerated-pointer
[nobuffer]: ./concepts.md#no-buffer-no-window
[vsync]: ./concepts.md#frame-callback-vsync
[readiness]: ./concepts.md#readiness-vs-completion-windowing

<!-- Cross-tree siblings -->

[asyncio]: ../async-io/index.md
[ui-layout]: ../ui-layout/index.md
[dbi]: ../../guidelines/design-by-introspection-00-intro.md

<!-- External specs -->

[xkbcommon]: https://xkbcommon.org/

<!-- Win32 / macOS (Wayback-pinned, bot-hostile host) -->

[wmdpichanged]: https://web.archive.org/web/20260428034332/https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[tsf]: https://web.archive.org/web/20221114201716/https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework
[nstextinput]: https://web.archive.org/web/20260115025403/https://developer.apple.com/documentation/appkit/nstextinputclient
