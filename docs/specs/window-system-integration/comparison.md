# WSI supported-feature comparison

This is the implementation ledger for [`sparkles:wsi`](./SPEC.md) and a
source-pinned comparison with nine third-party designs. It answers a narrower question
than the fifteen-library [research synthesis](../../research/window-system-integration/comparison.md):
what can an application obtain through each subject's window-system-facing API across
the four Sparkles desktop targets?

**Last reviewed:** August 21, 2026

> [!IMPORTANT]
> An internal backend implementation is not automatically a public capability. `Qt QPA`
> is explicitly marked `internal`; raylib and OpenTK may delegate a platform; and
> `raw-window-handle` intentionally creates no window or event. Those are architectural
> facts, not quality rankings.
>
> Every capability-bearing `sparkles:wsi` commit updates the first column and cites its
> test evidence. `planned` is a contract only, `partial` is implemented with a named
> semantic/platform gap, and `verified` means the evidence lanes in
> [SPEC §11](./SPEC.md#_11-testing-and-evidence) are complete.

## Legend

| Mark       | Meaning                                                                                |
| ---------- | -------------------------------------------------------------------------------------- |
| `✓`        | verified public capability across the subject's claimed desktop platforms              |
| `◐`        | public but semantically/platform incomplete for the `F` row                            |
| `◇`        | delegated to another WSI/backend rather than owned by the subject                      |
| `internal` | implemented by a private/internal platform abstraction, not a supported standalone API |
| `—`        | absent                                                                                 |
| `N/A`      | intentionally outside the subject's scope                                              |

## Pinned revisions

The source trees follow the repository research convention: existing language buckets
under `$REPOS/<lang>` are reused; no flat `$REPOS` clones are introduced.

| Subject           | Revision reviewed                                                                                                                                                                                   | Local evidence root                         | Positioning                                                        |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------ |
| `sparkles:wsi`    | this branch                                                                                                                                                                                         | `libs/wsi`, this spec tree                  | native WSI implementation in progress                              |
| GLFW 3            | [`1e59848`](https://github.com/glfw/glfw/tree/1e59848ba2856c25515a80f52e97c78d5412395e) (after 3.5.1)                                                                                               | `$REPOS/c/glfw`                             | focused window/input library                                       |
| raylib            | [`dbc56a8`](https://github.com/raysan5/raylib/tree/dbc56a87da87d973a9c5baa4e7438a9d20121d28) (6.0)                                                                                                  | `$REPOS/c/raylib`                           | game framework; desktop WSI delegated to GLFW by default           |
| SDL3              | [`b53f1b0`](https://github.com/libsdl-org/SDL/tree/b53f1b06447cfe699e2649afc52a1a54e5f19f71)                                                                                                        | `$REPOS/c/sdl`                              | broad public platform abstraction                                  |
| SFML 3            | [`d8b93d1`](https://github.com/SFML/SFML/tree/d8b93d1f711521b58b4d5289679d6e868729aab9) (after 3.1.0)                                                                                               | `$REPOS/cpp/sfml`                           | multimedia window library; no Wayland backend                      |
| Qt QPA            | Qt Base [`f18845a`](https://github.com/qt/qtbase/tree/f18845a55e194aae789f55407cfdb86077ae92b6), Wayland [`9638a7d`](https://github.com/qt/qtwayland/tree/9638a7d1d1c5609cb37130fc200a5f6db331ec85) | `$REPOS/cpp/qtbase`, `$REPOS/cpp/qtwayland` | internal Qt platform abstraction                                   |
| Gio               | [`c035a61`](https://github.com/gioui/gio/tree/c035a6190b0bcb4c8f90e5830d7410307f7c58e8) (after 0.10.2)                                                                                              | `$REPOS/go/gio`                             | immediate-mode app/window integration                              |
| winit             | [`81b2729`](https://github.com/rust-windowing/winit/tree/81b272976588c767954df51b26999723fdb7cab4)                                                                                                  | `$REPOS/rust/winit`                         | callback-first window/event library                                |
| raw-window-handle | [`1b85948`](https://github.com/rust-windowing/raw-window-handle/tree/1b859486d7bb9dffd4505c6663da7e2afa78732a) (after 0.6.2)                                                                        | `$REPOS/rust/raw-window-handle`             | typed borrowed/owned handles only                                  |
| OpenTK 5          | [`5.0-pre.16`](https://github.com/opentk/opentk/tree/bf55b84185a076617a3e147ea7100fe5482789cf) (`bf55b84`)                                                                                          | `$REPOS/csharp/opentk`, tag object          | prerelease PAL2; native Win32/X11/macOS plus SDL component backend |

## `F01`–`F17` matrix

The row definitions are normative in
[feature requirements](./feature-requirements.md#desktop-feature-baseline-f01f17).
For third parties, `✓` means the public surface substantially covers the row on the
desktop backends the library itself claims; the platform table immediately below makes
missing Sparkles targets visible.

| ID                             | `sparkles:wsi` | GLFW 3 | raylib | SDL3 | SFML 3 | Qt QPA   | Gio | winit | raw-window-handle | OpenTK 5 |
| ------------------------------ | -------------- | ------ | ------ | ---- | ------ | -------- | --- | ----- | ----------------- | -------- |
| F01 first pixel/init           | partial        | ✓      | ◇      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F02 resize                     | partial        | ✓      | ◇      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F03 modal-loop survival        | planned        | ◐      | ◇      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F04 frame pacing               | planned        | ◐      | ◐      | ◐    | ◐      | internal | ✓   | ◐     | N/A               | ◐        |
| F05 loop wake/external sources | partial        | ◐      | —      | ◐    | —      | internal | ◐   | ◐     | N/A               | ✓        |
| F06 keyboard/keymap            | partial        | ✓      | ✓      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F07 IME/text input             | partial        | ◐      | ◐      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F08 DPI/runtime rescale        | planned        | ◐      | ◐      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F09 outputs/hotplug            | planned        | ✓      | ◐      | ✓    | ◐      | internal | ◐   | ✓     | N/A               | ✓        |
| F10 pointer capture/raw        | planned        | ✓      | ✓      | ✓    | ◐      | internal | ◐   | ✓     | N/A               | ◐        |
| F11 scroll fidelity            | planned        | ◐      | ◐      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F12 cursors                    | planned        | ✓      | ◐      | ✓    | ✓      | internal | ✓   | ✓     | N/A               | ✓        |
| F13 decorations                | planned        | ✓      | ◇      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |
| F14 state/vetoable close       | planned        | ✓      | ◐      | ✓    | ✓      | internal | ✓   | ✓     | N/A               | ✓        |
| F15 grabbed popup              | planned        | —      | —      | ✓    | —      | internal | —   | —     | N/A               | —        |
| F16 clipboard + DnD            | planned        | ◐      | ◐      | ◐    | ◐      | internal | ◐   | ◐     | N/A               | ◐        |
| F17 threading/reentrancy       | partial        | ✓      | ◇      | ✓    | ◐      | internal | ✓   | ✓     | N/A               | ◐        |

### Reading the dense rows

- GLFW commits text but has no public pre-edit model; clipboard is text and file-drop is
  receive-only; frame pacing remains application/graphics-API work.
- raylib's desktop window semantics mostly inherit GLFW, while its public event surface
  deliberately simplifies scroll, display and window-state detail.
- SDL3 has the broadest public C surface in this set. `F05` remains partial because it
  has wake/user events and hooks but no portable public external-fd integration;
  `F16` lacks a general public drag-source peer to its drop target.
- SFML implements X11, Win32 and Cocoa directly but no Wayland client. Rows that would
  otherwise be complete therefore remain partial for Sparkles' four-desktop target.
- Qt implements most rows, often deeply, but QPA is a private plugin contract. Public
  applications consume `QWindow`/QtGui rather than QPA as a standalone WSI library.
- Gio integrates editor/IME state and frame scheduling unusually well; grabbed native
  popup windows and a full bidirectional data-transfer surface are not its abstraction.
- winit provides strong window/input/lifecycle coverage but intentionally omits
  clipboard and native popup abstractions; file hover/drop is receive-side only.
- raw-window-handle's `N/A` cells are correct success: it standardizes handle handoff
  without claiming lifecycle or events.
- OpenTK 5 PAL2 is prerelease. Its component model is broad, but Wayland currently comes
  through its SDL component rather than the native X11/Win32/macOS implementations.

## Platform ownership

| Subject           | Wayland         | X11             | Win32           | AppKit          | Cross-platform fallback/delegation                       |
| ----------------- | --------------- | --------------- | --------------- | --------------- | -------------------------------------------------------- |
| `sparkles:wsi`    | native partial  | native partial  | native partial  | native partial  | SDL only as explicit separate package                    |
| GLFW 3            | native          | native          | native          | native          | optional Wayland libdecor decoration helper              |
| raylib            | delegated GLFW  | delegated GLFW  | delegated GLFW  | delegated GLFW  | GLFW default; other ports exist outside this desktop row |
| SDL3              | native          | native          | native          | native          | runtime video-driver selection                           |
| SFML 3            | —               | native          | native          | native          | none                                                     |
| Qt QPA            | plugin          | plugin          | plugin          | plugin          | internal plugin selection                                |
| Gio               | native          | native          | native          | native          | platform files selected by Go build constraints          |
| winit             | native          | native          | native          | native          | backend chosen by target/runtime                         |
| raw-window-handle | handle variants | handle variants | handle variants | handle variants | no implementation                                        |
| OpenTK 5          | SDL `◇`         | native + SDL    | native + SDL    | native + SDL    | PAL2 component selection, prerelease                     |

## Architectural comparison

| Subject           | Loop ownership                              | Public coordinate default                           | Typed renderer handle                                              | Threading rule                                         | Dependency posture                              |
| ----------------- | ------------------------------------------- | --------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------ | ----------------------------------------------- |
| `sparkles:wsi`    | Event Horizon only; native sources attach   | logical plus mandatory physical surface metrics     | closed backend sum                                                 | UI/main thread                                         | OS APIs only in native core                     |
| GLFW 3            | application polls/waits                     | screen coordinates plus explicit framebuffer pixels | per-platform native getters                                        | main thread required on macOS; documented restrictions | X11/Wayland client libraries; optional libdecor |
| raylib            | application frame loop                      | physical-ish pixels through simplified API          | public native handle helper is backend-dependent                   | delegated/backend rule                                 | GLFW by default plus graphics/audio stack       |
| SDL3              | poll/wait or main callbacks                 | platform-native logical policy plus pixel queries   | property bag/native properties                                     | main-thread API annotations                            | owns platform backends; optional helpers        |
| SFML 3            | application poll/wait                       | pixels                                              | `getNativeHandle`, type varies by platform                         | window thread restrictions by platform                 | native X11/Win32/Cocoa, no Wayland              |
| Qt QPA            | Qt dispatcher owns loop                     | device-independent Qt coordinates                   | private `QPlatform*` objects and native interfaces                 | GUI thread                                             | Qt plugin stack                                 |
| Gio               | callback/event channel around platform loop | device-independent units with metric                | renderer selected inside app driver, not generic public raw handle | platform main thread plus Go event loop                | direct platform code                            |
| winit             | callback-first `ApplicationHandler`         | physical-native with explicit logical conversion    | raw-window-handle traits                                           | main thread by default/required on AppKit              | direct backends plus Rust ecosystem helpers     |
| raw-window-handle | N/A                                         | N/A                                                 | its entire public purpose                                          | handle safety/lifetime contract only                   | zero WSI implementation                         |
| OpenTK 5          | component event queue/poll/wakeup           | pixel-oriented component values                     | typed `WindowHandle` plus Vulkan component                         | component/backend-specific                             | native PAL2 plus selectable SDL                 |

## Handle handoff specifically

| Subject           | Shape                                           | Lifetime signal                   | Cross-backend misuse resistance      |
| ----------------- | ----------------------------------------------- | --------------------------------- | ------------------------------------ |
| `sparkles:wsi`    | closed display/window sum with exact variants   | `ready` through destruction start | compile-/match-time variant          |
| GLFW 3            | separate native-access functions per platform   | documented window lifetime        | function/platform selected by caller |
| raylib            | backend-dependent `GetWindowHandle`-style value | window lifetime                   | weak; generic pointer/value          |
| SDL3              | typed property keys over an SDL window          | window/property lifetime          | runtime property lookup              |
| SFML 3            | platform typedef `WindowHandle`                 | window lifetime                   | build-target type                    |
| Qt QPA            | internal platform-native interfaces             | QObject/platform object lifetime  | runtime plugin/native-interface type |
| Gio               | renderer integration is internal to app driver  | frame/window driver lifetime      | not a general public handoff         |
| winit             | `HasWindowHandle`/`HasDisplayHandle`            | borrowed handle tied to owner     | strong typed variants                |
| raw-window-handle | borrowed/owned display and window enums         | explicit borrow/ownership traits  | strong typed variants                |
| OpenTK 5          | `WindowHandle` discriminated platform handle    | component window lifetime         | typed enum/fields, prerelease        |

## Primary source anchors

The matrix was read against these public contracts and backend seams; the broader
behavioral rationale remains in the linked research deep-dives.

- **GLFW:** [`glfw3.h`](https://github.com/glfw/glfw/blob/1e59848ba2856c25515a80f52e97c78d5412395e/include/GLFW/glfw3.h),
  [`wl_window.c`](https://github.com/glfw/glfw/blob/1e59848ba2856c25515a80f52e97c78d5412395e/src/wl_window.c),
  and the [Sparkles GLFW deep-dive](../../research/window-system-integration/glfw.md).
- **raylib:** [`raylib.h`](https://github.com/raysan5/raylib/blob/dbc56a87da87d973a9c5baa4e7438a9d20121d28/src/raylib.h),
  [`rcore.c`](https://github.com/raysan5/raylib/blob/dbc56a87da87d973a9c5baa4e7438a9d20121d28/src/rcore.c),
  and [`rcore_desktop_glfw.c`](https://github.com/raysan5/raylib/blob/dbc56a87da87d973a9c5baa4e7438a9d20121d28/src/platforms/rcore_desktop_glfw.c).
- **SDL3:** [`SDL_video.h`](https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_video.h),
  [`SDL_events.h`](https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_events.h),
  and the [Sparkles SDL3 deep-dive](../../research/window-system-integration/sdl3.md).
- **SFML 3:** [`WindowBase.hpp`](https://github.com/SFML/SFML/blob/d8b93d1f711521b58b4d5289679d6e868729aab9/include/SFML/Window/WindowBase.hpp),
  [`Event.hpp`](https://github.com/SFML/SFML/blob/d8b93d1f711521b58b4d5289679d6e868729aab9/include/SFML/Window/Event.hpp),
  and the direct [X11](https://github.com/SFML/SFML/blob/d8b93d1f711521b58b4d5289679d6e868729aab9/src/SFML/Window/Unix/WindowImplX11.cpp),
  [Win32](https://github.com/SFML/SFML/blob/d8b93d1f711521b58b4d5289679d6e868729aab9/src/SFML/Window/Win32/WindowImplWin32.cpp), and
  [Cocoa](https://github.com/SFML/SFML/blob/d8b93d1f711521b58b4d5289679d6e868729aab9/src/SFML/Window/macOS/WindowImplCocoa.mm) implementations.
- **Qt QPA:** [`qplatformwindow.h`](https://github.com/qt/qtbase/blob/f18845a55e194aae789f55407cfdb86077ae92b6/src/gui/kernel/qplatformwindow.h),
  [`qwindow.h`](https://github.com/qt/qtbase/blob/f18845a55e194aae789f55407cfdb86077ae92b6/src/gui/kernel/qwindow.h),
  the [`qwindowswindow.cpp`](https://github.com/qt/qtbase/blob/f18845a55e194aae789f55407cfdb86077ae92b6/src/plugins/platforms/windows/qwindowswindow.cpp) plugin, and the
  [Sparkles Qt QPA deep-dive](../../research/window-system-integration/qt6.md).
- **Gio:** [`app.go`](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/app.go),
  [`os.go`](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/os.go),
  [`ime.go`](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/ime.go), and the native
  [Wayland](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/os_wayland.go),
  [X11](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/os_x11.go),
  [Windows](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/os_windows.go), and
  [macOS](https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/app/os_macos.m) drivers.
- **winit:** [`event.rs`](https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/event.rs),
  [`window.rs`](https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/window.rs),
  and the [Sparkles winit deep-dive](../../research/window-system-integration/winit.md).
- **raw-window-handle:** [`lib.rs`](https://github.com/rust-windowing/raw-window-handle/blob/1b859486d7bb9dffd4505c6663da7e2afa78732a/src/lib.rs),
  [`borrowed.rs`](https://github.com/rust-windowing/raw-window-handle/blob/1b859486d7bb9dffd4505c6663da7e2afa78732a/src/borrowed.rs), and
  [`owned.rs`](https://github.com/rust-windowing/raw-window-handle/blob/1b859486d7bb9dffd4505c6663da7e2afa78732a/src/owned.rs).
- **OpenTK 5:** [PAL2 README](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/README.md),
  [`IWindowComponent`](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/Interfaces/IWindowComponent.cs),
  [`WindowHandle`](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/Handles/WindowHandle.cs), and the native
  [Windows](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/Native/Windows/WindowComponent.cs),
  [X11](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/Native/X11/X11WindowComponent.cs),
  [macOS](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/Native/macOS/MacOSWindowComponent.cs), and
  [SDL](https://github.com/opentk/opentk/blob/bf55b84185a076617a3e147ea7100fe5482789cf/src/OpenTK.Platform/Native/SDL/SDLWindowComponent.cs) components.

## Sparkles evidence log

| Date       | Revision                                 | Matrix changes                                                                                                                                                                                                                                                    | Evidence                                                                                                                                                                                                                 |
| ---------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2026-08-20 | `5c17ddf21`                              | initialized all `F01`–`F17` cells as `planned`; no implementation credit claimed                                                                                                                                                                                  | normative spec plus pinned source audit                                                                                                                                                                                  |
| 2026-08-20 | M1 shared-input preparation              | no `F` cell changed; consolidated geometry, cell conversion, and pointer-shape imports before the WSI package consumes them                                                                                                                                       | `dub test :input`, `:ui-sdl3`, `:ui-raylib`                                                                                                                                                                              |
| 2026-08-20 | M3 core working tree                     | no native `F` cell changed; added unit-explicit values, generation ids, lossless events, typed handles/errors, pure backend selection, and a bounded non-reentrant recording lifecycle                                                                            | `dub test :wsi` (11 tests); checked build; `win32-ldc2` core compile                                                                                                                                                     |
| 2026-08-21 | M1 bounded UTF conversion                | no `F` cell changed; added shared allocation-free UTF-8/UTF-16 conversion for the future Win32 IMM32 and AppKit adapters, including safe NUL-terminated variants                                                                                                  | `dub test :base` (461 tests; 6 UTF-16 conversion cases)                                                                                                                                                                  |
| 2026-08-21 | M2–M4 Win32 lifecycle, input + host wait | `F01`, `F02`, `F05`, `F06`, `F07`, and `F17` → `partial`; added native HWND lifecycle, typed handle, metrics, queued key/text/IMM32 events, and the Event Horizon User32/IOCP hosted wait                                                                         | cross-compile plus Wine/Xvfb HWND/resize/close, scan-code + UTF-16 input, IMM32 pre-edit/commit, IOCP timer/foreign-waker smoke                                                                                          |
| 2026-08-21 | M2/M3 AppKit lifecycle + host wait       | no `F` cell state changed; extended partial `F01`, `F02`, `F05`, and `F17` coverage with native NSWindow lifecycle, typed handles, point/pixel metrics, and the Event Horizon CFRunLoop/kqueue hosted wait                                                        | arm64 macOS NSWindow first draw/resize/close, main-thread rejection, kqueue timer/foreign-waker smoke                                                                                                                    |
| 2026-08-21 | M2/M3 X11 lifecycle + foreign fd         | no `F` cell state changed; extended partial `F01`, `F02`, `F05`, and `F17` coverage with native XCB lifecycle, typed handles, ordered metrics/close events, and the Event Horizon `OpPollAdd` path                                                                | Xvfb XCB create/expose/resize/close/destroy, wrong-thread rejection, timer/foreign-waker smoke; `cancelAndWait` unit                                                                                                     |
| 2026-08-21 | M2/M3 Wayland lifecycle + foreign fd     | no `F` cell state changed; completed four-platform partial `F01`, `F02`, `F05`, and `F17` coverage with asynchronous registry discovery, immediate configure acknowledgement and `OpPollAdd` readiness                                                            | no-compositor gate plus headless Weston configure/maximize/destroy, wrong-thread, timer/foreign-waker and cancellation smoke                                                                                             |
| 2026-08-21 | M3/M6 native Vulkan surface bridge       | `WSI7` and `INT2` → `partial`; added typed Wayland/XCB/Win32 surface plans, target-native Vulkan dispatch, present-device selection and a Wayland native-I/O borrow around ICD display access                                                                     | `dub test :vulkan`, `:vulkan-wsi`, `:ui-sdl3`; headless Weston handle → surface → present-device → re-arm; Win32 cross/Wine ABI plan                                                                                     |
| 2026-08-21 | M6 shared Vulkan presentation resources  | no feature cell changed; extended partial `WSI7`/`INT2` with one backend-neutral `CommandPool`, `FrameSync`, `Swapchain`, acquire/resize decisions and deferred-retirement implementation consumed by native WSI and SDL                                          | `dub test :vulkan-wsi` (18), `:ui-sdl3` (24); existing SDL Vulkan triangle builds unchanged and `--help` runs                                                                                                            |
| 2026-08-21 | M6 native Wayland Vulkan triangle        | no feature cell state changed; extended partial `WSI7`/`INT2` with the first native frame loop — configure/frame/expose-paced presents, swapchain rebuild on compositor resize, and the native-I/O borrow widened to cover acquire and present ICD display access | native Mutter 150-frame run with `--resize-stress` under `VK_LAYER_VALIDATE_SYNC=1`; no-compositor SKIP and `--help` gates scripted; `dub test :vulkan-wsi` (19), `:ui-sdl3` (24); one shared renderer builds both hosts |
