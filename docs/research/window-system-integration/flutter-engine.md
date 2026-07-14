# Flutter Engine (C++)

A portable C++ rendering/runtime engine that delegates **all** window-system integration to a thin per-platform "embedder": the engine itself owns no windows, no event loop, and no native widgets — it asks an embedder, through a stable C ABI ([`embedder.h`][embedder-h]), to create surfaces, deliver input, and signal vsync.

| Field             | Value                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------ |
| Version / commit  | [`flutter/flutter`][flutter-repo] @ `feab40b83b8d1954106e83bb1d7b52265a41cb45` (studied June 8, 2026)        |
| Language          | C / C++ (engine + embedders), Objective-C++ (`darwin`), Swift (`darwin` run loop), C with GObject (`linux`)  |
| License           | BSD-3-Clause                                                                                                 |
| Repository        | [flutter/flutter][flutter-repo] (the engine is the `engine/` subtree; was a separate `flutter/engine` repo)  |
| Documentation     | [Flutter Engine architecture][engine-arch-wiki] / [Custom Flutter Engine Embedders][embedder-wiki]           |
| Category          | engine / embedder framework                                                                                  |
| Platforms covered | GTK 3 (Wayland + X11 via GDK), Win32 (ANGLE/D3D11), AppKit (macOS), UIKit (iOS), Android, plus generic C API |
| Loop ownership    | **Embedder owns the native loop**; the engine posts tasks back onto embedder-supplied **task runners**       |
| Native coord unit | Logical (device-independent) at the framework boundary; metrics sent to the engine are **physical** pixels   |
| Repo paths        | `engine/src/flutter/shell/platform/{embedder,common,linux,windows,darwin}/`                                  |

---

## Overview

### What it solves

Flutter renders its entire UI itself (no native controls), so the only thing it needs from an operating system is: a drawable surface, a stream of input events, a vsync signal, and a thread on which to run tasks. The **embedder API** is the contract that isolates those four needs from the cross-platform engine. The header is explicit that it is an ABI, not just an API:

> [!NOTE]
> From [`shell/platform/embedder/embedder.h`][embedder-h] (lines 12-15):
>
> > This file defines an Application Binary Interface (ABI), which requires more stability than regular code to remain functional for exchanging messages between different versions of the embedding and the engine, to allow for both forward and backward compatibility.

Every struct in `embedder.h` opens with a `size_t struct_size;` member that the caller sets to `sizeof(Type)`, so the engine can detect which trailing fields a given embedder build knows about. This is how the same compiled engine binary serves a GTK embedder, a Win32 embedder, and a macOS embedder that were each built against different header revisions.

The first-party embedders (`linux/`, `windows/`, `darwin/macos`, `darwin/ios`, `android/`) are themselves consumers of that ABI; third parties (e.g. embedded-Linux compositors, game engines) consume `embedder.h` directly. The generic C entry points are [`FlutterEngineRun`][embedder-h] / `FlutterEngineInitialize`, and input/resize are pushed in with `FlutterEngineSendPointerEvent`, `FlutterEngineSendKeyEvent`, and `FlutterEngineSendWindowMetricsEvent`.

### Design philosophy

- **Engine/embedder split.** The engine is platform-agnostic; the embedder is the _only_ code that touches `wl_surface`, `HWND`, or `NSView`. The boundary is a frozen C ABI, which is why a Flutter app can run on Wayland, Win32, and AppKit from one engine.
- **The embedder owns the event loop.** Unlike a typical toolkit that _runs_ a `main()` loop for you, Flutter inverts control: the embedder runs the native loop ([`GMainLoop`][gmainloop], the Win32 message pump, [`CFRunLoop`][cfrunloop]) and feeds the engine through **task runners**. The engine never blocks on an OS event queue.
- **Four thread roles, decoupled from threads.** The engine names four runner roles — _platform_, _UI_ (the Dart isolate), _raster_, and _IO_ — but lets the embedder map them onto real threads via [`FlutterCustomTaskRunners`][embedder-h]. Desktop embedders collapse platform+UI onto one thread; mobile keeps them split.
- **Surface, not window.** The engine asks for backing stores / drawables (`make_current`, `present`, `get_next_drawable`); it has no concept of "window". Windowing — title, decorations, monitors, popups — lives entirely in the embedder.
- **Vsync as a callback, never a syscall.** The engine asks "wake me at the next frame" via `vsync_callback` and a _baton_; the embedder returns the baton through `FlutterEngineOnVsync`. The engine never talks to [`CVDisplayLink`][cvdisplaylink] or DXGI itself.

---

## How it works

### The engine/embedder ABI surface

The core types in [`embedder.h`][embedder-h]:

| Concept         | Type / symbol                                                       | Role                                                                  |
| --------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Engine handle   | `FLUTTER_API_SYMBOL(FlutterEngine)`                                 | Opaque per-instance handle returned by `FlutterEngineRun`.            |
| Renderer config | `FlutterRendererConfig` (`kOpenGL`/`kMetal`/`kVulkan`/`kSoftware`)  | How the engine acquires & presents surfaces.                          |
| Project args    | `FlutterProjectArgs`                                                | Assets path, vsync callback, task runners, platform-message callback. |
| Task runner     | `FlutterTaskRunnerDescription`                                      | `post_task_callback` + `runs_task_on_current_thread_callback`.        |
| Custom runners  | `FlutterCustomTaskRunners`                                          | Maps platform/UI/raster runners onto embedder threads.                |
| Vsync           | `VsyncCallback` + `FlutterEngineOnVsync`                            | Engine requests a frame; embedder returns a _baton_ at next vsync.    |
| Window metrics  | `FlutterWindowMetricsEvent` + `FlutterEngineSendWindowMetricsEvent` | Physical size, `pixel_ratio`, `view_id`, `display_id`.                |
| Pointer         | `FlutterPointerEvent` + `FlutterEngineSendPointerEvent`             | Phase, device kind, signal kind (scroll/scale), physical coords.      |
| Key             | `FlutterKeyEvent` + `FlutterEngineSendKeyEvent`                     | Physical (USB HID) + logical key, separate from text.                 |
| Multi-view      | `FlutterAddViewInfo` / `FlutterEngineAddView`                       | Multiple views (windows) per engine; the _implicit view_ is view 0.   |
| Compositor      | `FlutterCompositor` (backing-store + present callbacks)             | Lets the embedder composite Flutter layers with platform views.       |

### The task-runner loop

The engine never owns a loop. It hands the embedder tasks tagged with a target time; the embedder must run them on the correct thread. The contract, from [`embedder.h`][embedder-h]:

```c
// shell/platform/embedder/embedder.h (FlutterTaskRunnerDescription, abridged)
typedef struct {
  size_t struct_size;
  void* user_data;
  // May be called from any thread. Should return true if tasks posted on the
  // calling thread will be run on that same thread.
  BoolCallback runs_task_on_current_thread_callback;   // REQUIRED
  // The given task should be executed by the embedder on the thread associated
  // with that task runner by calling `FlutterEngineRunTask` at the given target
  // time. ... The target time is the absolute time from epoch (NOT a delta).
  FlutterTaskRunnerPostTaskCallback post_task_callback; // REQUIRED
  size_t identifier;
  VoidCallback destruction_callback;
} FlutterTaskRunnerDescription;
```

When the engine wants work done on the platform thread it calls `post_task_callback(task, target_time_nanos, user_data)`. The embedder schedules a wakeup at `target_time_nanos` on its native loop, and at that time calls `FlutterEngineRunTask(engine, &task)` back on the right thread. This is why the embedder, not the engine, integrates with [`GMainLoop`][gmainloop] / the Win32 message pump / [`CFRunLoop`][cfrunloop].

### The vsync baton

The frame pacing protocol is a closed loop between engine and embedder. `FlutterProjectArgs.vsync_callback` is invoked by the engine (on an internal thread) with an opaque `baton`; the embedder waits for the next display vsync and returns it:

```c
// shell/platform/embedder/embedder.h (vsync_callback doc, abridged)
// The engine will give the platform a baton that needs to be returned back to
// the engine via `FlutterEngineOnVsync`. ... While the call to
// `FlutterEngineOnVsync` must occur on the thread that made the call to
// `FlutterEngineRun`, the engine will make this callback on an internal
// engine-managed thread.
typedef void (*VsyncCallback)(void* /* user data */, intptr_t /* baton */);
```

`FlutterEngineOnVsync(engine, baton, frame_start_time_nanos, frame_target_time_nanos)` then unblocks the engine's UI thread to produce a frame, with `frame_target_time_nanos` used to schedule Dart GC during idle periods. Each embedder supplies the vsync source: [`CVDisplayLink`][cvdisplaylink] on macOS, [`DwmGetCompositionTimingInfo`][dwm-timing] on Windows, GTK's frame clock / a fallback on Linux.

---

## 1. Window creation & lifecycle

The engine creates no windows. Each embedder wraps a native widget/window and feeds the engine a _view_. The shared idea: a native surface is created, a GL/Metal context is bound, the embedder calls `FlutterEngineSendWindowMetricsEvent`, and only then does the engine produce a first frame for that view.

**Linux (GTK 3).** A Flutter view is a `GtkWidget` subclass. [`fl_view.h`][fl-view-h] declares `FlView` as a `GtkBox` (`G_DECLARE_FINAL_TYPE(FlView, fl_view, FL, VIEW, GtkBox)`), and the top-level window is a stock [`GtkApplicationWindow`][gtk-app-window] created in [`fl_application.cc`][fl-application] via `gtk_application_window_new`. Inside `FlView`, a `GtkDrawingArea` (`render_area`) hosts the GL context created with `gdk_window_create_gl_context` ([`fl_view.cc`][fl-view-cc] near line 482). Decorations, title, fullscreen, transparency, always-on-top — none are a Flutter API; they are whatever the app sets on the `GtkApplicationWindow` directly. Wayland vs X11 is GDK's choice (`GDK_IS_WAYLAND_DISPLAY` is checked at `fl_view.cc` ~498). The renderer config (`x11`, `gtk+-3.0`, `epoxy`) is pinned in [`config/BUILD.gn`][linux-config-build].

**Windows (Win32).** [`FlutterWindow`][flutter-window-cc] registers a window class (`RegisterClass`, `lpfnWndProc = WndProc`) and creates the window with `CreateWindowEx` (`flutter_window.cc` ~438). The `HWND` user-data trick stores `this` on `WM_NCCREATE` via `SetWindowLongPtr(window, GWLP_USERDATA, ...)`. A newer multi-window layer (`host_window_regular.cc`, `host_window_dialog.cc`, `host_window_popup.cc`, `host_window_tooltip.cc`) wraps creation per archetype (see [§6](#_6-multi-window-popups)). The GL surface is ANGLE-on-D3D11 (see [§2](#_2-event-loop)).

**macOS (AppKit).** A `FlutterViewController` owns an `NSView` (`FlutterViewWrapper : NSView`, [`FlutterViewController.mm`][macos-vc] ~154) and is driven from a `FlutterEngine`. The view is created in `-loadView`. Window chrome is the host app's `NSWindow`; a newer `FlutterWindowController` adds engine-managed windows.

**Surface/handle exposure.** The engine's `FlutterRendererConfig` is the GPU handle boundary: `kOpenGL` exposes `make_current`/`clear_current`/`present`/`fbo_with_frame_info_callback`; `kMetal` exposes `FlutterMetalTexture` (a wrapped `id<MTLTexture>` the embedder owns); `kVulkan` exposes image/queue callbacks; `kSoftware` exposes a pixel buffer. The embedder owns the texture/framebuffer; the engine renders into it and calls back to present.

**Initial-frame handling.** Because the engine produces a frame only after `FlutterEngineSendWindowMetricsEvent`, the [no-buffer-no-window][concepts-no-buffer] Wayland constraint is satisfied naturally: the GTK embedder waits for the widget to be realized (`realize_cb` in `fl_view.cc`) before sending metrics, so no frame is presented before a `wl_surface` exists. `FlView` even has a `first_frame_emitted`-style gate (`have got the first frame to render`).

> [!WARNING]
> Destruction ordering is delicate across the ABI: `embedder.h` notes that _all batons must be returned to the engine before `FlutterEngineShutdown`_ or you leak. Embedders must also keep the GL context valid until the engine's last `present` lands.

---

## 2. Event loop

**Who owns the loop: the embedder, always.** The engine is loop-less by construction; it posts tasks and waits for vsync batons. Each embedder integrates a native loop differently.

**Linux — GLib `GMainLoop`.** The platform task runner ([`fl_engine.cc`][fl-engine-cc] ~794) registers `fl_engine_post_task`, which forwards to [`fl_task_runner.cc`][fl-task-runner]. Delayed tasks are scheduled with `g_timeout_add` and torn down with `g_source_remove` — i.e. the engine's tasks become GLib timeout sources on the GTK main context. The default UI-thread policy runs the UI isolate **on the platform thread** (`custom_task_runners.ui_task_runner = &platform_task_runner` at `fl_engine.cc` ~811), unless `FL_UI_THREAD_POLICY_RUN_ON_SEPARATE_THREAD` is set.

**Windows — Win32 message pump.** [`task_runner_window.cc`][task-runner-window] runs a classic pump: `GetMessage` → `TranslateMessage` → `DispatchMessage` (~167), with a `WM_TIMER` (`SetTimer(window_handle_, kPollTimeoutTimerId, ...)`, ~166) used to wake the pump at a task's target time, then `ProcessTasks()` drains due tasks and arms the next timer. The view's `FlutterWindow::WndProc` (~513) is a separate window proc handling input.

**macOS — a custom `CFRunLoop` mode.** Rather than `DispatchQueue.async`, macOS uses [`FlutterRunLoop.swift`][macos-runloop], which adds a `CFRunLoopSource` + `CFRunLoopTimer` to **both** common modes and a private mode, so Flutter tasks are serviced even inside nested/modal run loops (menu tracking, the [Win32-style resize loop][concepts-modal] equivalent). The file states its own rationale:

> [!NOTE]
> From [`darwin/macos/framework/Source/FlutterRunLoop.swift`][macos-runloop] (lines 9-13):
>
> > The main difference between using `FlutterRunLoop` to schedule tasks compared to `DispatchQueue.async` or `RunLoop.perform(_:)` is that `FlutterRunLoop` schedules the task in both common run loop mode and a private run loop mode, which allows it to run in a mode where it only processes Flutter messages (`pollFlutterMessagesOnce()`).

The macOS platform task runner's `post_task_callback` calls `postMainThreadTask:` → `[FlutterRunLoop.mainRunLoop performAfterDelay:...]` ([`FlutterEngine.mm`][macos-engine] ~633, ~1805).

**Frame pacing & vsync sources.**

- **macOS / iOS:** [`FlutterDisplayLink.mm`][macos-displaylink] wraps [`CVDisplayLink`][cvdisplaylink] (`CVDisplayLinkCreateWithCGDisplay`, `CVDisplayLinkSetOutputHandler`, `CVDisplayLinkStart`), feeding [`FlutterVSyncWaiter.mm`][macos-vsync]. iOS uses [`CADisplayLink`][cadisplaylink] (`FlutterMetalLayer.mm`). The waiter returns the baton ~1ms before vsync so events are processed first.
- **Windows:** _software-computed_ vsync. `FlutterWindowsEngine::OnVsync` ([`flutter_windows_engine.cc`][windows-engine] ~671) snaps `GetCurrentTime()` to the next tick using `FrameInterval()`, which reads [`DwmGetCompositionTimingInfo`][dwm-timing] (~688, falling back to 16.6ms = 60Hz). The display refresh rate also comes from `dmDisplayFrequency` in [`display_manager.cc`][windows-display]. Notably this is **not** a DXGI waitable swapchain — it is a phase-locked timer.
- **Linux:** vsync is driven off GTK's frame clock / draw cycle; `fl_view.cc` calls `gtk_widget_queue_draw` to request frames.

> [!IMPORTANT]
> Cross-link: the readiness-vs-completion and loop-ownership themes overlap the async-I/O survey — see [readiness vs completion (windowing)][concepts-readiness] and the [async-io catalog][async-io-index]. Flutter is squarely a **callback-driven, embedder-owned** loop; the engine is a _guest_ on the host loop.

---

## 3. Input

Flutter's embedder API separates **raw key events** from **text/composition** events, and uses a physical/logical key model rather than raw OS keysyms at the framework boundary.

**Key model — physical (USB HID) + logical.** `FlutterKeyEvent` carries a `physical` key (a stable USB-HID-derived code) and a `logical` key (layout-dependent). Each embedder maps OS codes into this space:

- **Windows** ([`keyboard_key_embedder_handler.cc`][windows-key-embedder] ~160): `GetPhysicalKey(scancode, extended)` derives the physical key from the Win32 `lParam` scancode (`(lparam >> 16) & 0xff`, extended bit `(lparam >> 24) & 0x01` in [`keyboard_manager.cc`][windows-keyboard-mgr] ~187), and `ResolveKeyCode` calls `MapVirtualKey(scancode, MAPVK_VSC_TO_VK_EX)` to disambiguate left/right modifiers. See [scancode/keysym/virtual-key][concepts-scancode].
- **Linux** ([`fl_keyboard_manager.cc`][linux-key-mgr]): owns a `GdkKeymap` (`gdk_keymap_get_for_display`, ~350) and uses `gdk_keymap_lookup_key` (~222) to resolve layouts. The xkb state machine is _inside GDK_ — the embedder defers to it rather than driving `xkbcommon` directly.
- **macOS** uses `KeyCodeMap.g.mm` and `FlutterKeyboardLayout.mm`.

**Key repeat.** Repeat is reported explicitly: `FlutterKeyEventType` has `kFlutterKeyEventTypeRepeat`. On Linux the GDK key-press events already carry repeats; the embedder forwards them (the [Wayland client-side repeat][concepts-readiness] burden is absorbed by GTK/GDK, not by Flutter). On Windows the embedder tracks pressing records (`pressingRecords_`) to synthesize the down/repeat/up sequence the framework expects.

**IME / text input.** Each embedder punts composition to the platform's native text-input stack, and routes the committed/pre-edit text through a _text-input channel_ separate from key events. See [pre-edit / composition][concepts-preedit].

- **Linux:** [`fl_text_input_handler.cc`][linux-text] uses a `GtkIMContext` from `gtk_im_multicontext_new()` (~446), wiring the `preedit-start`/`preedit-changed`/`commit`/`preedit-end` signals (~453-462). Candidate positioning is `gtk_im_context_set_cursor_location` (~356). This means XIM/ibus/fcitx all work _through GTK's_ IM modules — Flutter writes no XIM code.
- **Windows:** legacy **IMM32**, not TSF. [`text_input_manager.cc`][windows-text] uses `ImmGetContext` (~20), reads `GCS_COMPSTR`/`GCS_RESULTSTR` via `ImmGetCompositionString` (~119-123), and positions the candidate window with `ImmSetCompositionWindow` + `ImmSetCandidateWindow` (~178-183). A code comment notes _some IMEs ignore `ImmSetCandidateWindow()`_.
- **macOS:** the [`NSTextInputClient`][nstextinputclient] protocol on `FlutterTextInputPlugin` (`insertText:`, `setMarkedText:`, `markedRange`, `hasMarkedText`, `firstRectForCharacterRange:` — [`FlutterTextInputPlugin.mm`][macos-text] ~760-1025). Key events that the IME doesn't consume become `FlutterKeyEvent`s; consumed ones become marked/committed text.

**Pointer.** `FlutterPointerEvent` distinguishes device kinds (`kFlutterPointerDeviceKindMouse`/`Touch`/`Stylus`/`Trackpad`) and signal kinds (`kFlutterPointerSignalKindScroll`/`ScrollInertiaCancel`/`Scale`). Scroll deltas are `scroll_delta_x`/`scroll_delta_y` doubles. Windows handles both `WM_MOUSEWHEEL`-style and Pointer-input (`WM_POINTERDOWN`/`WM_POINTERUPDATE`/`WM_POINTERUP`) paths in `flutter_window.cc` (~561-611), plus `DirectManipulation` (`direct_manipulation.cc`) for high-resolution/precision touchpad scrolling. macOS momentum phases map onto the inertia signal kinds. See [raw vs accelerated pointer][concepts-pointer].

**Cursor.** Linux maps Flutter's cursor kinds onto **named** (CSS-style) cursors in [`fl_mouse_cursor_handler.cc`][linux-cursor] (a `GHashTable` populated by `populate_system_cursor_table`, e.g. `"click" → "pointer"`, `"forbidden" → "not-allowed"`), resolved by GDK to themed cursors — i.e. server/theme cursors, not client-rendered bitmaps. Windows has `cursor_handler.cc`.

---

## 4. Wayland specifics

> [!IMPORTANT]
> Flutter's first-party Linux embedder is **GTK 3** ([`config/BUILD.gn`][linux-config-build] pins `gtk+-3.0` and `x11`). It therefore does **not** speak the Wayland protocol directly at all — it delegates everything (surface, input, decorations, scale) to **GDK**. Wayland protocol coverage, decoration policy, and compositor quirks are GDK's, not Flutter's.

- **Decorations.** Flutter draws no decorations and implements no `xdg-decoration` path itself. Because the window is a `GtkApplicationWindow`, decorations are whatever GTK provides: GTK's own client-side decorations (CSD/header bars) on Wayland, or server-side on compositors that negotiate them. See [client vs server decoration][concepts-csd]. Flutter has nothing equivalent to a `libdecor` integration of its own.
- **Protocol coverage** (`fractional-scale-v1`, `viewporter`, `xdg-activation`, `idle-inhibit`, `layer-shell`) is entirely GDK's. Flutter's view only learns an **integer** scale factor (see [§5](#_5-dpi-scaling)) — GTK 3's GDK does not surface `fractional-scale-v1` to it, which is a concrete limitation acknowledged in code:

> [!NOTE]
> From [`fl_view.cc`][fl-view-cc] (lines 224-227):
>
> > Note we can't detect if a window is moved between monitors - this information is provided by Wayland but GTK only notifies us if the scale has changed, so moving between two monitors of the same scale doesn't provide any information.

- **Compositor workarounds.** Being a GTK app, Flutter inherits GDK's compositor handling (mutter/kwin/sway/weston); the embedder itself contains essentially no per-compositor `#ifdef`s. The one Wayland-specific check is `GDK_IS_WAYLAND_DISPLAY` in `fl_view.cc` to branch GL-context behaviour.
- **Embedded Linux.** Third-party embedders that _do_ speak Wayland directly (e.g. `flutter-pi`, `flutter-embedded-linux`) exist precisely because the first-party GTK embedder is desktop-only; they consume `embedder.h` and implement `wl_surface`/`xdg_toplevel` themselves.

---

## 5. DPI & scaling

**Native unit at the engine boundary is physical pixels + a ratio.** `FlutterWindowMetricsEvent` carries `width`/`height` in physical pixels and a `pixel_ratio` (`device_pixel_ratio`); the framework derives logical pixels by dividing. See [logical vs physical coords][concepts-coords] and [scale factor][concepts-scale].

- **Linux:** scale is **integer-only** via [`gtk_widget_get_scale_factor`][gtk-scale] ([`fl_view.cc`][fl-view-cc] ~222). Metrics are sent as `allocation.width * scale_factor` with `scale_factor` as the pixel ratio (`fl_engine_send_window_metrics_event`, ~248). Consequences: (1) no fractional scaling (125%, 150%) — only 1×, 2×, 3×; (2) the _created-at-wrong-scale_ problem is visible in the `realize_cb` ordering note ("we shouldn't be generating anything until the window is created. Another event with the correct display ID is generated soon after", `fl_view.cc` ~231-237); (3) same-scale monitor migration is undetectable (quoted above in [§4](#_4-wayland-specifics)).
- **Windows:** per-monitor DPI v2. `current_dpi_` is read with `GetDpiForHWND` ([`flutter_window.cc`][flutter-window-cc] ~544) and the rescale handler reacts to `kWmDpiChangedBeforeParent` (i.e. [`WM_DPICHANGED_BEFOREPARENT`][wm-dpichanged-beforeparent], ~543) — Flutter handles the _before-parent_ variant so child windows rescale correctly. `dpi_utils.cc` dynamically resolves `GetDpiForMonitor` and `EnableNonClientDpiScaling` from `shcore`/`user32`, the standard runtime-bind approach for older Windows compatibility. `base_dpi = 96`; pixel ratio = `dpi / 96`.
- **macOS:** backing scale from the `NSWindow`/`NSScreen` (`backingScaleFactor`), surfaced through the view; the engine receives metrics in physical pixels.

> [!WARNING]
> The Linux integer-scale limitation is the most-felt gap: on a 150%-scaled Wayland desktop, GTK 3 hands Flutter a scale of `1` (or `2`) and the compositor up/downscales the buffer, producing blur. This is an upstream GTK-3/GDK constraint, not a Flutter bug; the fix path is the long-running GTK 4 migration. See [issue #41980][gh-fractional].

---

## 6. Multi-window & popups

Historically a Flutter engine drove a **single** view (the _implicit view_, `view_id` 0). The multi-view embedder API (`FlutterEngineAddView`/`FlutterEngineRemoveView`, `FlutterAddViewInfo`/`FlutterRemoveViewInfo` in [`embedder.h`][embedder-h]) lets one engine drive several views, which the desktop embedders use for multi-window.

The newer desktop multi-window support classifies windows by archetype. From [`shell/platform/common/windowing.h`][windowing-h]:

```cpp
// shell/platform/common/windowing.h
enum class WindowArchetype {
  kRegular,   // Regular top-level window.
  kDialog,    // Dialog window.
  kTooltip,   // Tooltip window.
  kPopup,     // Popup window.
};
```

The Windows embedder implements one host-window class per archetype: `host_window_regular.cc`, `host_window_dialog.cc`, `host_window_popup.cc`, `host_window_tooltip.cc`, coordinated by `window_manager.cc`. macOS adds `FlutterWindowController`.

- **Popups/menus.** On Win32 these are top-level windows with popup styling; the grab semantics are Win32's. On Wayland (through GTK) popups become `xdg_popup`s with the compositor's grab semantics — see [override-redirect vs xdg_popup grab][concepts-popup]. Flutter itself does not author `xdg_popup` grabs; it relies on GTK.
- **Modality / stacking** is expressed at the archetype level (dialog) and realized by the per-platform host-window code; parent/child relationships are passed through `FlutterAddViewInfo`.

> [!NOTE]
> Multi-window is comparatively young; for years Flutter desktop was effectively one-window-per-engine, and the framework-level API is still stabilizing ([multi-window design][gh-multiwindow]).

---

## 7. Threading

The engine defines four runner roles ([`embedder.h`][embedder-h] `FlutterNativeThreadType`): `kFlutterNativeThreadTypePlatform`, `...Render`, `...UI`, `...Worker`. The mapping onto OS threads is the embedder's choice via `FlutterCustomTaskRunners`.

- **The platform thread is the embedder's main/UI thread.** `embedder.h` states the thread that calls `FlutterEngineRun` _is_ the platform thread, and there is exactly one per engine. Windowing calls (resize, metrics, vsync return) must happen there.
- **macOS forces main-thread.** AppKit is main-thread-only, so the macOS embedder's `runs_task_on_current_thread_callback` is literally `[[NSThread currentThread] isMainThread]` ([`FlutterEngine.mm`][macos-engine] ~631), and engine APIs assert it: `NSAssert([[NSThread currentThread] isMainThread], @"Must be called on the main thread.")` (~1362). This is the classic constraint that shapes the whole model.
- **Desktop collapses platform + UI.** Linux runs the UI isolate on the platform thread by default ([`fl_engine.cc`][fl-engine-cc] ~811); macOS/Windows similarly merge to simplify desktop integration. Mobile keeps UI on its own thread for jank isolation.
- **Rendering off the event thread.** The _raster_ runner can be a different thread; the engine rasterizes there while the platform thread keeps handling input. The engine internally also runs raster/UI/IO thread merging when needed (e.g. platform views), but that lives in the engine's shell, below the embedder ABI.

---

## 8. Clipboard & DnD

Clipboard is a platform-channel feature, implemented per embedder, and on desktop it is **text-centric**.

- **Linux:** [`fl_platform_handler.cc`][linux-platform] uses [`GtkClipboard`][gtk-clipboard]: `gtk_clipboard_get_default(gdk_display_get_default())`, `gtk_clipboard_set_text` (set), and `gtk_clipboard_request_text` / `clipboard_text_cb` (get, async). The Wayland `wl_data_device` selection model and X11 selections + INCR are handled _inside GTK_; Flutter only deals with `text/plain`.
- **Windows / macOS:** clipboard handlers translate the `Clipboard.setData`/`getData` channel calls onto the OS clipboard.
- **Drag-and-drop** is not a first-party engine feature; it is provided by plugins (e.g. `super_drag_and_drop`, `desktop_drop`) that hook the native drop targets via the embedder's [escape hatches](#_9-escape-hatches), or via platform-view interop. The engine ABI has no DnD types.

> [!NOTE]
> Because clipboard is text-first in the first-party embedders, rich formats (images, files, custom MIME) require a plugin. The Wayland delayed-rendering / Win32 delayed-rendering / X11 INCR machinery is never touched by Flutter directly — it is the platform clipboard layer's job.

---

## 9. Escape hatches

The embedder split _is_ the escape hatch: the entire native layer is the embedder, which the app controls.

- **Native handle access.** The embedder hands the engine native handles (`HWND`, `NSView`, `GtkWidget`, `id<MTLTexture>`) and exposes them back to plugin code. On Linux a plugin gets the `FlView`/`GtkWidget`; on Windows the engine exposes `GetView()`/the `HWND`; macOS exposes the `FlutterViewController`/`NSView`.
- **Win32 message-pump hooks.** [`window_proc_delegate_manager.cc`][windows-wndproc-delegate] lets plugins register a `WindowProcDelegate` to observe/handle raw `WM_*` messages _before_ Flutter — the explicit raw-event passthrough where the abstraction leaks (e.g. tray icons, custom hit-testing).
- **Platform views.** `FlutterCompositor` + `kFlutterLayerContentTypePlatformView` let the embedder composite a native view (a `WKWebView`, a video surface) _inside_ the Flutter scene — the abstraction's GPU-level escape hatch.
- **Texture registrar.** `FlutterEngineRegisterExternalTexture` / the per-platform `TextureRegistrar` lets an app push externally-produced GPU textures (camera, video) into the Flutter scene.

---

## 10. History, redesigns & known regrets

- **The engine repo merge.** The engine lived in its own `flutter/engine` repository for most of Flutter's life and was merged into the `flutter/flutter` monorepo as the `engine/` subtree; the studied tree has [`engine/README.md`][engine-readme] at the monorepo root. This unified versioning of framework + engine, but the engine is still a distinct, ABI-stable component.
- **The embedder API as the stabilizing decision.** Freezing `embedder.h` as an ABI (the `struct_size` discipline, "Enum values must not change", "New function instead of modifying core behavior") is _the_ design that made third-party embedders (embedded Linux, game engines, alt-Wayland) possible. The header's own ABI rules (lines 12-51) read as a list of hard-won constraints.
- **Linux GTK embedder maturation.** The GTK embedder evolved from a GLFW prototype (`shell/platform/glfw`, now legacy) to the GObject `fl_*` API. Its GTK-3 base is the source of the integer-scale / no-fractional-scaling regret ([§5](#_5-dpi-scaling)); GTK 4 / direct-Wayland is the long-running fix discussion ([issue #41980][gh-fractional]).
- **Software-computed Windows vsync.** Windows pacing via `DwmGetCompositionTimingInfo` + a snap-to-tick timer ([§2](#_2-event-loop)) rather than a DXGI waitable swapchain is a pragmatic choice with known jank edge-cases under variable refresh; tracked in the engine's frame-scheduling history.
- **Impeller's impact on presentation.** Impeller (the Skia replacement renderer) changes what the engine asks of the embedder at present time and shifted desktop toward always passing `--impeller-use-sdfs` ([`fl_engine.cc`][fl-engine-cc] ~834). It is a rendering-pipeline change, but it touches the windowing layer because backing-store formats and present timing flow through the same embedder callbacks. [inference] The push to Impeller is partly to remove first-frame shader-compilation jank that the embedder-present path exposed.
- **Multi-window lateness.** Single-view-per-engine was a long-standing limitation; the multi-view ABI and `WindowArchetype` are recent ([§6](#_6-multi-window-popups)), and the framework-side API is still settling ([multi-window tracking][gh-multiwindow]).

---

## Strengths

- **Clean engine/embedder split** behind a frozen C ABI: one engine binary, many window systems, third-party embedders welcome.
- **Loop-agnostic.** By posting tasks onto embedder runners instead of owning a loop, Flutter coexists with any host loop (`GMainLoop`, Win32 pump, `CFRunLoop`) — including nested/modal loops (the macOS custom run-loop mode is a clean solution).
- **Vsync as a baton protocol** decouples the engine from `CVDisplayLink`/DXGI/GTK specifics while still letting each platform supply an accurate source.
- **Physical+logical key model** plus channel-based text input gives consistent cross-platform keyboard semantics; IME is delegated to the _native_ stack (`GtkIMContext`, IMM32, `NSTextInputClient`) so it actually works with ibus/fcitx/Windows IME.
- **Platform views + texture registrar** are first-class GPU-level escape hatches, not afterthoughts.

## Weaknesses

- **Linux is GTK-3-only, integer-scale-only.** No native fractional scaling, no direct Wayland; same-scale monitor migration is undetectable. The compositor up/downscales, causing blur.
- **No direct Wayland/X11 in-tree.** First-party Linux is desktop-GTK; embedded/alt-Wayland needs a third-party embedder.
- **Windows vsync is timer-derived**, not a true waitable swapchain — variable-refresh edge cases.
- **Windowing is barely abstracted.** Title/decoration/fullscreen/transparency are not engine APIs; they are whatever the embedder's native window offers, so behaviour differs per platform and is "silently unsupported" where the native window lacks it.
- **Multi-window is young**; for years it was one window per engine.
- **Clipboard is text-first**; rich formats and DnD need plugins.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                    | Trade-off                                                                                   |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Engine owns no window / no loop; embedder owns both                       | One engine binary serves every window system; third-party embedders possible | Every platform reimplements windowing; behaviour & feature coverage diverge per embedder    |
| Frozen C ABI (`struct_size`, no enum reordering)                          | Forward/backward compat between mismatched engine/embedder builds            | Verbose, append-only structs; can't refactor the boundary cleanly                           |
| Task-runner abstraction over real threads                                 | Lets desktop merge platform+UI, mobile split them, all from one engine       | Embedder must correctly answer `runs_task_on_current_thread`; mis-threading is UB           |
| Vsync baton callback instead of engine-owned display link                 | Engine stays platform-agnostic; each OS supplies an accurate vsync source    | Baton lifetime is a leak hazard; Windows ends up with a timer-derived approximation         |
| Linux embedder = GTK 3 (delegate to GDK)                                  | Reuse GTK's mature Wayland/X11/IME/clipboard; tiny embedder                  | Inherits GTK-3 limits: integer scale, no fractional scaling, no direct protocol access      |
| IME delegated to native stacks (IMM32 / GtkIMContext / NSTextInputClient) | Real-world IME (ibus/fcitx/Windows/macOS) works without bespoke code         | IMM32 (not TSF) on Windows; behaviour varies; some IMEs ignore candidate-window positioning |
| Physical (USB HID) + logical key model                                    | Layout-stable physical keys + layout-aware logical keys, cross-platform      | Each embedder maintains large generated key-map tables (`*.g.cc`)                           |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **engine/embedder ABI split** with `struct_size` versioning — it is the cleanest way to get "one core, many window systems" with binary compatibility.
- The **vsync-baton** protocol: ask the host for "wake me next frame", let the host own the actual display link. It keeps the core free of `CVDisplayLink`/DXGI/GTK.
- **Task runners with a `runs_on_current_thread` predicate** — a tidy way to be a polite guest on any host loop and to let the _embedder_ decide the threading model.
- The **macOS custom-run-loop-mode** trick (source+timer in common _and_ private modes) for surviving nested/modal native loops — a recurring pain point for any guest-on-host-loop design.
- **Delegate IME to the native stack** rather than reimplementing XIM/TSF — it is the only way IME actually works in the wild.

**Avoid:**

- **Under-specifying windowing in the abstraction.** Flutter pushed _all_ of title/decoration/fullscreen/transparency/popups onto embedders, so coverage is inconsistent and "silently unsupported" per platform. A new framework should define a windowing contract, even a minimal one.
- **Pinning Linux to GTK 3.** The integer-scale / no-fractional-scaling / no-direct-Wayland constraints all trace to that choice.
- **Timer-derived vsync** where a waitable-swapchain / present API exists.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact engine-internal raster/UI/IO thread-merging policy** (when platform-view composition forces merges). Lives below the embedder ABI in `engine/src/flutter/shell/common/` (the `Shell`, `Rasterizer`, `TaskRunners`), outside the sparse checkout used here.
- **Whether the GTK-4 / direct-Wayland Linux embedder has landed or is still proposed.** Likely answered in [issue #41980][gh-fractional] and the linux-embedder design discussions.
- **Precise frame-scheduling/jank behaviour of the Windows snap-to-tick vsync under VRR.** Lives in the engine's frame-scheduler and the `flutter_windows_engine` tests; not fully determinable from the header + embedder source alone.
- **iOS `CADisplayLink` ProMotion (variable refresh) handling.** Lives in `darwin/ios/framework/Source/FlutterMetalLayer.mm` and the iOS vsync waiter (only partly in the sparse checkout).

---

## Sources

- [flutter/flutter][flutter-repo] — monorepo (engine is the `engine/` subtree); all quoted paths are under `engine/src/flutter/shell/platform/` at commit `feab40b8`.
- [`embedder.h`][embedder-h] — the C ABI: task runners, vsync, renderer configs, multi-view, key/pointer/metrics events (the ABI-stability quote is lines 12-15).
- [`fl_view.cc`][fl-view-cc] / [`fl_view.h`][fl-view-h] / [`fl_engine.cc`][fl-engine-cc] — GTK 3 embedder window/view/loop (Wayland-scale quote is lines 224-227).
- [`fl_text_input_handler.cc`][linux-text] / [`fl_keyboard_manager.cc`][linux-key-mgr] / [`fl_platform_handler.cc`][linux-platform] / [`fl_mouse_cursor_handler.cc`][linux-cursor] — Linux IME (`GtkIMContext`), keys (`GdkKeymap`), clipboard (`GtkClipboard`), cursors.
- [`flutter_window.cc`][flutter-window-cc] / [`task_runner_window.cc`][task-runner-window] / [`flutter_windows_engine.cc`][windows-engine] / [`text_input_manager.cc`][windows-text] — Win32 creation, message pump, DWM vsync, IMM32.
- [`FlutterRunLoop.swift`][macos-runloop] / [`FlutterEngine.mm`][macos-engine] / [`FlutterViewController.mm`][macos-vc] / [`FlutterDisplayLink.mm`][macos-displaylink] / [`FlutterTextInputPlugin.mm`][macos-text] — macOS run loop, threading, `CVDisplayLink`, `NSTextInputClient` (run-loop quote is lines 9-13).
- [`windowing.h`][windowing-h] — `WindowArchetype` multi-window enum.
- [Flutter Engine architecture][engine-arch-wiki] / [Custom embedders][embedder-wiki] — the WHY of the engine/embedder split.
- Sibling docs: [concepts][concepts-csd], [async-io catalog][async-io-index], [ui-layout: Flutter][ui-layout-flutter].

<!-- References -->

[flutter-repo]: https://github.com/flutter/flutter
[embedder-h]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/embedder/embedder.h
[fl-view-cc]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_view.cc
[fl-view-h]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/public/flutter_linux/fl_view.h
[fl-engine-cc]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_engine.cc
[fl-task-runner]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_task_runner.cc
[fl-application]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_application.cc
[linux-config-build]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/config/BUILD.gn
[linux-text]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_text_input_handler.cc
[linux-key-mgr]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_keyboard_manager.cc
[linux-platform]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_platform_handler.cc
[linux-cursor]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/linux/fl_mouse_cursor_handler.cc
[flutter-window-cc]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/flutter_window.cc
[task-runner-window]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/task_runner_window.cc
[windows-engine]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/flutter_windows_engine.cc
[windows-display]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/display_manager.cc
[windows-text]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/text_input_manager.cc
[windows-key-embedder]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/keyboard_key_embedder_handler.cc
[windows-keyboard-mgr]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/keyboard_manager.cc
[windows-wndproc-delegate]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/windows/window_proc_delegate_manager.cc
[macos-runloop]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterRunLoop.swift
[macos-engine]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterEngine.mm
[macos-vc]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterViewController.mm
[macos-displaylink]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterDisplayLink.mm
[macos-vsync]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterVSyncWaiter.mm
[macos-text]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterTextInputPlugin.mm
[windowing-h]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/shell/platform/common/windowing.h
[engine-readme]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/README.md
[engine-arch-wiki]: https://github.com/flutter/flutter/blob/2ac447c8ae5d9e05442dc0b9ce57a80a108734e7/docs/about/The-Engine-architecture.md
[embedder-wiki]: https://github.com/flutter/flutter/tree/2ac447c8ae5d9e05442dc0b9ce57a80a108734e7/engine/src/flutter/shell/platform/embedder
[gh-fractional]: https://github.com/flutter/flutter/issues/41980
[gh-multiwindow]: https://github.com/flutter/flutter/issues/30701
[gmainloop]: https://docs.gtk.org/glib/main-loop.html
[cfrunloop]: https://developer.apple.com/documentation/corefoundation/cfrunloop
[cvdisplaylink]: https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k
[cadisplaylink]: https://developer.apple.com/documentation/quartzcore/cadisplaylink
[nstextinputclient]: https://developer.apple.com/documentation/appkit/nstextinputclient
[dwm-timing]: https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmgetcompositiontiminginfo
[wm-dpichanged-beforeparent]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged-beforeparent
[gtk-app-window]: https://docs.gtk.org/gtk3/class.ApplicationWindow.html
[gtk-clipboard]: https://docs.gtk.org/gtk3/class.Clipboard.html
[gtk-scale]: https://docs.gtk.org/gtk3/method.Widget.get_scale_factor.html
[concepts-csd]: ./concepts.md#client-vs-server-decoration
[concepts-scancode]: ./concepts.md#scancode-keysym-virtualkey
[concepts-coords]: ./concepts.md#logical-vs-physical-coords
[concepts-scale]: ./concepts.md#scale-factor
[concepts-preedit]: ./concepts.md#pre-edit-composition
[concepts-popup]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[concepts-modal]: ./concepts.md#win32-modal-resize-loop
[concepts-pointer]: ./concepts.md#raw-vs-accelerated-pointer
[concepts-no-buffer]: ./concepts.md#no-buffer-no-window
[concepts-readiness]: ./concepts.md#readiness-vs-completion-windowing
[async-io-index]: ../async-io/index.md
[ui-layout-flutter]: ../ui-layout/flutter.md
