# OS Windowing APIs — Cross-Platform Summary

A side-by-side reading of the six raw OS windowing APIs surveyed in this sub-tree: how each models
"a window", delivers events, handles input and text, scales, decorates, and exchanges data. It is
the capstone of the [OS-API surveys][index] and the lower-level counterpart to the framework-level
[comparison & recommendations][comparison]; shared terms link to [concepts][concepts].

**Last reviewed:** June 11, 2026

## At a glance

| Platform         | Window object                 | Who creates the window           | Event delivery                          | Coordinate unit + scale source            | Decoration owner             | IME entry point            | Clipboard model                   |
| ---------------- | ----------------------------- | -------------------------------- | --------------------------------------- | ----------------------------------------- | ---------------------------- | -------------------------- | --------------------------------- |
| [Wayland][s-wl]  | `wl_surface` + `xdg_toplevel` | **App** (bind globals, commit)   | `wl_display` fd ([readiness][rvc])      | logical; `wp_fractional_scale_v1` (1/120) | **client** (CSD); SSD opt-in | `zwp_text_input_v3`        | `wl_data_device` selections       |
| [X11][s-x11]     | `Window` (`XID`)              | **App** (`XCreateWindow`)        | connection fd, `XNextEvent` (readiness) | physical px; `Xft.dpi`/RANDR (no native)  | **window manager**           | `XIM`                      | selections + `INCR` chunking      |
| [Win32][s-w32]   | `HWND`                        | **App** (`CreateWindowExW`)      | thread message queue (readiness)        | physical px; per-monitor DPI v2           | **OS / DWM**                 | TSF (legacy IMM32)         | clipboard + **delayed rendering** |
| [AppKit][s-ak]   | `NSWindow` (+ `NSView`)       | **App** (`NSWindow alloc/init`)  | `[NSApp run]` → `CFRunLoop`             | points; `backingScaleFactor`              | **OS** (`NSWindowStyleMask`) | `NSTextInputClient`        | `NSPasteboard`                    |
| [UIKit][s-ui]    | `UIWindow` (in a `UIScene`)   | **App supplies, system owns**    | `UIApplicationMain` → `CFRunLoop`       | points; `UIScreen.scale`                  | **system** (full-screen)     | `UITextInput`              | `UIPasteboard`                    |
| [Android][s-and] | `ANativeWindow`               | **System** (delivered to native) | `ALooper` (`epoll`)                     | physical px; `AConfiguration` density     | **system** (`WindowManager`) | `InputMethodManager` (JNI) | `ClipboardManager` (JNI)          |

## The window-object model

The deepest fork is **who owns the window object and where it lives**. X11's `Window` is a
server-side resource named by a 32-bit [`XID`][s-x11] — valid across the wire, not a process
pointer. Wayland's window is not one object but a _stack of roles_ — a `wl_surface` made a toplevel
via `xdg_surface`/`xdg_toplevel`, and it does not exist on screen until a buffer is committed (the
[no-buffer-no-window][nobuf] rule). Win32's `HWND` and AppKit's `NSWindow` are local handles the
**app** creates and owns. The two mobile APIs invert this: on [UIKit][s-ui] and [Android][s-and]
the **system** owns the surface and hands it to you (a `UIWindow` attached to a `UIScene`, or an
`ANativeWindow` delivered by the looper) — there are no user-movable desktop windows at all.

## Event delivery & frame pacing

Every platform is a **[readiness][rvc] loop**, never a completion model — you wait for "something
happened", then pull and dispatch it. The primitive differs: a **file descriptor** drained with
`wl_display_dispatch` (Wayland) / `XNextEvent` (X11) / `ALooper_pollOnce` (Android), versus a
**per-thread message queue** pulled with `GetMessage` (Win32), versus a **run loop** (`CFRunLoop`
under `[NSApp run]` / `UIApplicationMain` on Apple). Frame pacing is where the OS leaks most: a
Wayland `wl_surface.frame` callback, a `CADisplayLink` (Apple), DXGI/DWM vblank (Win32), or the
`AChoreographer` (Android) — each a different [frame-callback / vsync source][fcv]; X11 has no
native vsync (the `present` extension or a swap-interval is the substitute).

## Input & IME

Keyboards diverge on the [scancode vs keysym vs virtual-key][skv] axis: Wayland and X11 hand the
client an `xkbcommon` keymap and raw key codes (on Wayland the client even drives key _repeat_),
Win32 delivers virtual-keys + scancodes via `WM_KEYDOWN`, and Apple/Android deliver
already-interpreted key events. **IME is the least portable corner** ([pre-edit/composition][pec]):
six different contracts — `zwp_text_input_v3`, `XIM`, the Text Services Framework, `NSTextInputClient`,
`UITextInput`, and Java's `InputMethodManager` reached over JNI — with no common shape. High-res
and [raw vs accelerated pointer][rap] input is similarly per-platform (`wl_pointer` `axis_v120`,
`WM_MOUSEWHEEL` deltas, momentum scrolling on macOS).

## Coordinates & HiDPI

Two camps. **Physical pixels**: X11, Win32, and Android expose device pixels and bolt scaling on
top (X11 has no native model beyond `Xft.dpi`/RANDR; Win32 layers per-monitor DPI v2 +
`WM_DPICHANGED`; Android queries density via `AConfiguration`). **Logical units**: Apple's _points_
(× `backingScaleFactor` / `UIScreen.scale`) and Wayland's logical surface coordinates (with
fractional scale arriving as an integer in [1/120ths][scale]) are device-independent by design.
This is the same [logical-vs-physical][lvp] fork the framework layer must paper over.

## Decorations & popups

Decoration ownership splits three ways: **client** (Wayland CSD by default, with `xdg-decoration`
as an optional server-side hint — see [CSD vs SSD][csd]), **a separate server process** (the X11
**window manager** reparents and draws the frame; the OS DWM on Win32; AppKit's `NSWindowStyleMask`
on macOS), and **the system, with no app titlebar at all** (UIKit/Android full-screen surfaces).
Popups/menus fork too — Wayland `xdg_popup` grabs vs X11 `override-redirect` windows
([override-redirect vs xdg_popup grab][orx]) — while the mobile APIs have no concept of a top-level
popup window.

## Clipboard & drag-and-drop

All are asynchronous, MIME/format-negotiated transfers, but the mechanics differ: Wayland's
`wl_data_device` selection model, X11's selections plus the `INCR` protocol for large transfers,
Win32's clipboard with **delayed rendering** (`WM_RENDERFORMAT`), `NSPasteboard` / `UIPasteboard`
on Apple, and Android's `ClipboardManager` over JNI.

## Consensus vs divergence

> [!NOTE]
> The contrasts below are now backed by a MEASURED layer: the
> [feature matrix](./feature-matrix.md) (17 demos x 4 platforms, every cell verified) and
> its three syntheses — the [divergence map](./divergence-map.md),
> [event sequences](./event-sequences.md), and [design constraints](./design-constraints.md).

**The field agrees on more than it looks.** Every platform is a readiness loop; every one separates
raw key events from composed text; every one negotiates clipboard formats asynchronously; and the
two "logical-unit" platforms (Apple, Wayland) versus the three "physical-pixel" platforms (X11,
Win32, Android) is a clean two-way split, not six bespoke models. **Where it genuinely diverges** is
the window-object lifetime (app-owned handle vs server resource vs system-owned surface), decoration
ownership (client / WM / OS / system), and IME — the one area with six incompatible contracts and
no consensus. Those are exactly the seams a cross-platform toolkit must abstract; the framework
[comparison & recommendations][comparison] takes up how the surveyed toolkits do it.

## Sources

The six per-platform surveys ([Wayland][s-wl], [X11][s-x11], [Win32][s-w32], [AppKit][s-ak],
[UIKit][s-ui], [Android][s-and]), each citing primary OS documentation; [concepts][concepts] for
the shared vocabulary; the framework-level [comparison][comparison].

<!-- References -->

[index]: ./index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md
[rvc]: ../concepts.md#readiness-vs-completion-windowing
[nobuf]: ../concepts.md#no-buffer-no-window
[fcv]: ../concepts.md#frame-callback-vsync
[skv]: ../concepts.md#scancode-keysym-virtualkey
[pec]: ../concepts.md#pre-edit-composition
[rap]: ../concepts.md#raw-vs-accelerated-pointer
[scale]: ../concepts.md#scale-factor
[lvp]: ../concepts.md#logical-vs-physical-coords
[csd]: ../concepts.md#csd-vs-ssd
[orx]: ../concepts.md#override-redirect-vs-xdg-popup-grab
[s-wl]: ./wayland/
[s-x11]: ./x11/
[s-w32]: ./win32/
[s-ak]: ./appkit/
[s-ui]: ./uikit/
[s-and]: ./android/
