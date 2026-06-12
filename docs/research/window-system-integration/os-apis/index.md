# OS Windowing APIs

The [library deep-dives][catalog] document how fifteen toolkits talk to the platform window
system. This sub-tree documents the layer **beneath** them: the **raw OS windowing API** each
platform exposes — the exact functions and objects that `winit`, `SDL`, `GTK`, `Qt`, and the rest
ultimately call, and the irreducible code to open a window yourself. Every platform here carries a
**minimal, dependency-light D program** that opens (or bootstraps) a window by calling the OS API
directly, with no windowing-abstraction library.

**Last reviewed:** June 11, 2026

## Catalog

| Platform                     | Native API                             | Window handle                      | Event-loop primitive                                      | Coordinate unit                   | Decoration owner                      | Survey · Example                   |
| ---------------------------- | -------------------------------------- | ---------------------------------- | --------------------------------------------------------- | --------------------------------- | ------------------------------------- | ---------------------------------- |
| [Wayland][s-wl]              | Wayland protocol (`libwayland-client`) | `wl_surface` + `xdg_toplevel` role | `wl_display` fd, `wl_display_dispatch` ([readiness][rvc]) | **Logical** (1/120ths fractional) | **Client-side** (CSD); SSD optional   | [survey][s-wl] · [`app.d`][e-wl]   |
| [X11][s-x11]                 | Xlib (X11 protocol)                    | `Window` (an `XID`)                | X connection fd, `XNextEvent` ([readiness][rvc])          | **Physical** pixels               | **Server-side** (window manager)      | [survey][s-x11] · [`app.d`][e-x11] |
| [Windows (Win32)][s-w32]     | Win32 / User32                         | `HWND`                             | thread message queue, `GetMessage` ([readiness][rvc])     | **Physical** px (per-monitor DPI) | **Server-side** (DWM)                 | [survey][s-w32] · [`app.d`][e-w32] |
| [macOS (AppKit)][s-ak]       | Cocoa / AppKit                         | `NSWindow`                         | `[NSApp run]` → `NSRunLoop`/`CFRunLoop`                   | **Points** (logical)              | **Server-side** (`NSWindowStyleMask`) | [survey][s-ak] · [`app.d`][e-ak]   |
| [iOS / iPadOS (UIKit)][s-ui] | UIKit                                  | `UIWindow`                         | `UIApplicationMain` → `CFRunLoop`                         | **Points** (logical)              | **System** (full-screen; N/A)         | [survey][s-ui] · [`app.d`][e-ui]   |
| [Android (NDK)][s-and]       | NDK native-activity                    | `ANativeWindow`                    | `ALooper` (`ALooper_pollOnce`, `epoll`)                   | **Physical** px                   | **System** (`WindowManager`)          | [survey][s-and] · [`app.d`][e-and] |

## How to read these

Each survey follows the same shape (metadata table → "What it is" → a walk of the minimal program
→ the windowing spine: lifecycle, event loop & frame pacing, input/IME, coordinates & scaling,
decorations & popups, clipboard/DnD → what toolkits build on it). The shared vocabulary they link
to lives in [concepts][concepts]; the cross-platform contrasts are drawn together in the
[summary][summary].

## The empirical demo matrix

Beneath the surveys sits a second, **measured** layer: 17 feature clusters
([specs][specs]) × the four desktop platforms, each cell a small instrumented D demo
(located in the `examples/` directory for each platform: [Wayland](./wayland/examples/), [X11](./x11/examples/), [Win32](./win32/examples/), and [AppKit](./appkit/examples/)) with a
findings doc next to the survey it extends. The grid is the
[feature matrix][matrix]; the cross-platform synthesis is drawn in three capstones —
the [divergence map][divmap] (per-feature agree/fork/consequence), the
[event sequences][evseq] (eight lifecycle transitions aligned four ways), and the
[design constraints][constraints] (the thirteen things a framework cannot abstract away,
each with its measured evidence). Items needing real hardware or an interactive session
are queued in the [manual-run queue][queue].

The minimal programs bind the OS directly, choosing the most honest mechanism per platform:

- **X11, Wayland, Android** use **[ImportC][importc]** — a tiny `c.c` shim that `#include`s the
  real system header, so the D compiler parses the actual types/signatures (no hand-written
  bindings to drift). See the ImportC guide for the pkg-config wiring.
- **macOS / iOS** use D's built-in **`extern(Objective-C)`** + `@selector` (the same mechanism the
  [`objective-d`][objd] package wraps), since ImportC does not parse Objective-C.
- **Win32** uses druntime's built-in **`core.sys.windows`** (zero third-party); the
  [`RolandTaverner/windows-d`][winsd] fork is the full-SDK option for when that is insufficient.

> [!NOTE]
> **What is verified, and how.** X11 and Wayland build and run on Linux (X11 opens a real window;
> Wayland completes the `wl_registry` bootstrap), and print `SKIP` + exit 0 when headless. AppKit
> builds and shows a real `NSWindow` on macOS. iOS and Win32 are **compile-for-target verified**
> (an iOS-Simulator `arm64` object; a Windows `amd64` object), with a real Win32 run on the
> `windows-latest` CI runner and the iOS Simulator run documented as manual. Android cross-compiles
> via the opt-in `nix develop .#android` shell (note the [glue-header ImportC limitation][s-and]);
> its emulator run is a documented manual step. Mobile (iOS/Android) is out of CI scope.

## Sources

- The per-platform surveys below, each grounded in primary sources (protocol XML, the Xlib manual,
  Microsoft Learn, Apple developer docs, the Android NDK reference, and the OS headers themselves).
- [Concepts][concepts] — the shared windowing vocabulary these surveys reference.
- [Comparison & recommendations][comparison] — the framework-level synthesis this layer underpins.

<!-- References -->

[catalog]: ../index.md
[specs]: ./features/
[matrix]: ./feature-matrix.md
[divmap]: ./divergence-map.md
[evseq]: ./event-sequences.md
[constraints]: ./design-constraints.md
[queue]: ./manual-run-queue.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md
[summary]: ./summary.md
[importc]: ../../../guidelines/importc-c-libraries.md
[objd]: https://github.com/KitsunebiGames/objective-d
[winsd]: https://github.com/RolandTaverner/windows-d
[rvc]: ../concepts.md#readiness-vs-completion-windowing
[s-wl]: ./wayland/
[s-x11]: ./x11/
[s-w32]: ./win32/
[s-ak]: ./appkit/
[s-ui]: ./uikit/
[s-and]: ./android/
[e-wl]: ./wayland/example/app.d
[e-x11]: ./x11/example/app.d
[e-w32]: ./win32/example/app.d
[e-ak]: ./appkit/example/app.d
[e-ui]: ./uikit/example/app.d
[e-and]: ./android/example/app.d
