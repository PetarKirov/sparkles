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

| Date       | Revision                                 | Matrix changes                                                                                                                                                                                                                                                                                                                                                                      | Evidence                                                                                                                                                                                                                                                                                                                                                               |
| ---------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-08-20 | `5c17ddf21`                              | initialized all `F01`–`F17` cells as `planned`; no implementation credit claimed                                                                                                                                                                                                                                                                                                    | normative spec plus pinned source audit                                                                                                                                                                                                                                                                                                                                |
| 2026-08-20 | M1 shared-input preparation              | no `F` cell changed; consolidated geometry, cell conversion, and pointer-shape imports before the WSI package consumes them                                                                                                                                                                                                                                                         | `dub test :input`, `:ui-sdl3`, `:ui-raylib`                                                                                                                                                                                                                                                                                                                            |
| 2026-08-20 | M3 core working tree                     | no native `F` cell changed; added unit-explicit values, generation ids, lossless events, typed handles/errors, pure backend selection, and a bounded non-reentrant recording lifecycle                                                                                                                                                                                              | `dub test :wsi` (11 tests); checked build; `win32-ldc2` core compile                                                                                                                                                                                                                                                                                                   |
| 2026-08-21 | M1 bounded UTF conversion                | no `F` cell changed; added shared allocation-free UTF-8/UTF-16 conversion for the future Win32 IMM32 and AppKit adapters, including safe NUL-terminated variants                                                                                                                                                                                                                    | `dub test :base` (461 tests; 6 UTF-16 conversion cases)                                                                                                                                                                                                                                                                                                                |
| 2026-08-21 | M2–M4 Win32 lifecycle, input + host wait | `F01`, `F02`, `F05`, `F06`, `F07`, and `F17` → `partial`; added native HWND lifecycle, typed handle, metrics, queued key/text/IMM32 events, and the Event Horizon User32/IOCP hosted wait                                                                                                                                                                                           | cross-compile plus Wine/Xvfb HWND/resize/close, scan-code + UTF-16 input, IMM32 pre-edit/commit, IOCP timer/foreign-waker smoke                                                                                                                                                                                                                                        |
| 2026-08-21 | M2/M3 AppKit lifecycle + host wait       | no `F` cell state changed; extended partial `F01`, `F02`, `F05`, and `F17` coverage with native NSWindow lifecycle, typed handles, point/pixel metrics, and the Event Horizon CFRunLoop/kqueue hosted wait                                                                                                                                                                          | arm64 macOS NSWindow first draw/resize/close, main-thread rejection, kqueue timer/foreign-waker smoke                                                                                                                                                                                                                                                                  |
| 2026-08-21 | M2/M3 X11 lifecycle + foreign fd         | no `F` cell state changed; extended partial `F01`, `F02`, `F05`, and `F17` coverage with native XCB lifecycle, typed handles, ordered metrics/close events, and the Event Horizon `OpPollAdd` path                                                                                                                                                                                  | Xvfb XCB create/expose/resize/close/destroy, wrong-thread rejection, timer/foreign-waker smoke; `cancelAndWait` unit                                                                                                                                                                                                                                                   |
| 2026-08-21 | M2/M3 Wayland lifecycle + foreign fd     | no `F` cell state changed; completed four-platform partial `F01`, `F02`, `F05`, and `F17` coverage with asynchronous registry discovery, immediate configure acknowledgement and `OpPollAdd` readiness                                                                                                                                                                              | no-compositor gate plus headless Weston configure/maximize/destroy, wrong-thread, timer/foreign-waker and cancellation smoke                                                                                                                                                                                                                                           |
| 2026-08-21 | M3/M6 native Vulkan surface bridge       | `WSI7` and `INT2` → `partial`; added typed Wayland/XCB/Win32 surface plans, target-native Vulkan dispatch, present-device selection and a Wayland native-I/O borrow around ICD display access                                                                                                                                                                                       | `dub test :vulkan`, `:vulkan-wsi`, `:ui-sdl3`; headless Weston handle → surface → present-device → re-arm; Win32 cross/Wine ABI plan                                                                                                                                                                                                                                   |
| 2026-08-21 | M6 shared Vulkan presentation resources  | no feature cell changed; extended partial `WSI7`/`INT2` with one backend-neutral `CommandPool`, `FrameSync`, `Swapchain`, acquire/resize decisions and deferred-retirement implementation consumed by native WSI and SDL                                                                                                                                                            | `dub test :vulkan-wsi` (18), `:ui-sdl3` (24); existing SDL Vulkan triangle builds unchanged and `--help` runs                                                                                                                                                                                                                                                          |
| 2026-08-21 | M6 native Wayland Vulkan triangle        | no feature cell state changed; extended partial `WSI7`/`INT2` with the first native frame loop — configure/frame/expose-paced presents, swapchain rebuild on compositor resize, and the native-I/O borrow widened to cover acquire and present ICD display access                                                                                                                   | native Mutter 150-frame run with `--resize-stress` under `VK_LAYER_VALIDATE_SYNC=1`; no-compositor SKIP and `--help` gates scripted; `dub test :vulkan-wsi` (19), `:ui-sdl3` (24); one shared renderer builds both hosts                                                                                                                                               |
| 2026-08-21 | M6 X11/Win32 runtime surface probes      | no feature cell state changed; extended partial `WSI7`/`INT2` with live-ICD runtime probes on the two remaining Linux/Windows backends — typed XCB and HWND handles create a real surface, select a present-capable device, and the integrated wait dispatches after the driver ran                                                                                                 | Xvfb XCB probe (lavapipe fallback when hardware ICDs cannot present) and winevulkan/Wine Win32 probe, both scripted with honest SKIP gates the lanes refuse                                                                                                                                                                                                            |
| 2026-08-21 | M6 scripted Wayland presentation gate    | no feature cell state changed; the native triangle reports the SDL handoff comparison counters (`framesOver50ms`/`framesOver100ms`, `reaps`, `maxDispatchMs`, slow-dispatch traces) and the presentation gate no longer needs a live desktop session                                                                                                                                | Weston X11-backend-in-Xvfb lane with the client pinned to lavapipe: 150 frames with `--resize-stress` under `VK_LAYER_VALIDATE_SYNC=1`, 4 compositor resizes, 5 swapchains, 0 out-of-date, 0 frames over 50 ms; lane scripted in `verify-native-wayland-triangle.sh`                                                                                                   |
| 2026-08-21 | M4 X11 keyboard slice                    | no `F06` state change; extended partial `F06` coverage with the X11 column — evdev-keycode physical identity, left/right/numpad location, core-state modifiers, and press/repeat/release with XKB detectable auto-repeat requested at open                                                                                                                                          | Xvfb XTEST shift-chorded press/release round trip through the integrated loop; pure location/modifier/held-key model tests in `dub test :wsi` (14); logical keys stay deferred to the xkbcommon slice                                                                                                                                                                  |
| 2026-08-21 | M4 Wayland keyboard slice                | no `F06` state change; extended partial `F06` coverage with the Wayland column — `wl_seat` binding with capability arrival/departure, keymap-fd consumption, keyboard focus from enter/leave, and press/release through one shared evdev-location/xkb-real-modifier policy also adopted by X11                                                                                      | full-stack lane: XTEST chord into Xvfb → Weston X11 backend → `wl_keyboard` → queued `KeyboardEvent` with left-shift location and chorded modifier state; the smoke maps a real shm buffer under the native-I/O borrow; `dub test :wsi` (15)                                                                                                                           |
| 2026-08-21 | M4 AppKit keyboard slice                 | no `F06` state change; completed partial `F06` physical coverage on all four backends — the content view takes first responder, `keyDown`/`keyUp` queue Carbon virtual-keycode identity/location/repeat, and modifier keys translate from `flagsChanged` flag state                                                                                                                 | arm64 macOS 26.6 smoke posts a synthetic left-shift chord through the real responder chain and drains it back as `KeyboardEvent`s; pure location/modifier model tests in `dub test :wsi` (14 on macOS)                                                                                                                                                                 |
| 2026-08-21 | conformance suite consolidation          | no feature cell changed; every cross-backend behavior assertion (ordered sequences, ready metrics, expose/frame opportunities, wrong-thread rejection, typed handles, resize reporting, chorded keys, single-wait timer/waker progress, close semantics, generation-safe destruction) moved into one `sparkles.wsi.conformance` suite; platform smokes became thin drivers          | recording fake passes the value contract inside `dub test :wsi` (16); X11 10/0, Wayland 8/2 headless and 9/1 chord lane, Win32 10/0 plus IMM32 addendum under Wine, AppKit 10/0 on arm64 macOS 26.6 — all against identical assertions                                                                                                                                 |
| 2026-08-21 | vulkan-wsi probe consolidation           | no feature cell changed; the three native surface probes now share one `sparkles.vulkan_wsi.conformance` check — window → typed handles → present-capable context on the live ICD → single-wait progress — with the native-I/O borrow applied by introspection wherever the backend exposes it; `VulkanContext` teardown is RAII                                                    | Xvfb XCB probe, headless-Weston Wayland probe, winevulkan/Wine Win32 probe, the scripted presentation gate, `dub test :vulkan-wsi` (19) and `:ui-sdl3` (24) all green against the shared check                                                                                                                                                                         |
| 2026-08-21 | M4 logical keys on all four backends     | no `F06` state change; extended partial `F06` with layout-derived unshifted `LogicalKey` identity everywhere — xkbcommon behind Wayland (keymap fd compiled under the listener) and X11 (core device map, state from the core mask), `MAPVK_VK_TO_CHAR` on Win32, `charactersIgnoringModifiers` on AppKit with private-range function keys as named                                 | the shared conformance chord now asserts the unshifted spelling on every backend: X11 10/0 and both Wayland lanes under Xvfb/Weston, Win32 under Wine, AppKit on arm64 macOS 26.6; keysym classifier model test in `dub test :wsi` (17)                                                                                                                                |
| 2026-08-21 | M4 pointer and scroll slice              | `F11` → `partial`; extended partial `WSI5` with pointer button/motion/enter/leave and scroll values on all four backends under one sign convention — Wayland frame-accumulated axes with source/discrete, X11 legacy wheel buttons, Win32 `TrackMouseEvent`-paired enter/leave plus wheel, AppKit hit-tested clicks (`acceptsFirstMouse`) with precise deltas and the inverted flag | conformance click property (exact position on X11/Win32) and scroll property on X11 12/0 Xvfb, Wayland 10/2 kiosk-Weston lane, Win32 12/0 Wine, AppKit 11/1 arm64 macOS; injection via XTEST buttons, `SendMessageW`, posted `NSEvent`s, and the gated external injector                                                                                               |
| 2026-08-21 | M4 scale and outputs slice               | `F08`/`F09` → `partial`; Wayland windows derive scale from entered outputs (max policy), request the matching buffer scale, and report one atomic logical/physical/scale transition, with `OutputEnteredEvent` tracking the active output set; a conformance `expectedScale` property waits for the environment-declared factor                                                     | kiosk-Weston lane at `--scale=2`: metrics reach scale 2 with physical = logical × 2 while chord/click/scroll still pass (11/2); Wine phase documents the per-monitor 96-DPI limitation honestly (12/1, scale skipped) — native Windows CI owes that column                                                                                                             |
| 2026-08-21 | M4 cursor slice                          | `F12` → `partial`; the seven shared CSS-named `PointerShape` shapes plus per-window visibility on all four backends — vendored `cursor-shape-v1` server-side shapes on Wayland, core cursor-font glyphs on X11, stock `IDC_*` on `WM_SETCURSOR` for Win32, stock `NSCursor` on AppKit — with unsupported reported as a typed error                                                  | cursor conformance property on every lane: X11 13/1 Xvfb, Wayland 9/5 headless and 12/2 kiosk, Win32 13/1 Wine with `GetCursor` proving the applied `IDC_IBEAM`, AppKit 12/2 with `currentCursor is IBeamCursor` on arm64 macOS 26.6                                                                                                                                   |
| 2026-08-21 | M4 drag-capture slice                    | `F10` → `partial`; a drag leaving the window keeps reporting — Win32 gains implicit `SetCapture` from first press to last release (unwound on `WM_CAPTURECHANGED`), X11 relies on the automatic core grab, AppKit on window drag routing — and the conformance drag property requires the release to arrive with outside coordinates                                                | X11 14/1 (release at 700,500 beyond a 640x480 window; the lane Xvfb screen grew past the window for the property to be expressible), Win32 14/1 with `GetCapture` proving engagement and release under Wine, AppKit 13/2 with the outside release routed to the mouseDown view; Wayland skips (kiosk fullscreen has no outside; the compositor owns its implicit grab) |
