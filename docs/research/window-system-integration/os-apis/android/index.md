# Android (NDK native-activity API)

The raw native-windowing surface Android exposes to C/C++: you do **not** create a window — the Android framework creates the `Activity`'s `Surface` and hands native code an [`ANativeWindow`][nw-ref] (the producer end of a buffer queue) through a lifecycle command delivered on an [`ALooper`][looper-ref] event queue. This is the irreducible layer the Android backends of [winit][winit], [SDL3][sdl3], and [GLFW][glfw] wrap.

**Last reviewed:** June 9, 2026

| Field                    | Value                                                                                                                                                                                         |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native API               | Android NDK native-activity ([`ANativeActivity`][na-ref] + `android_native_app_glue`)                                                                                                         |
| Library / framework      | NDK platform libraries `libandroid.so` (`-landroid`) + `liblog.so` (`-llog`); the `android_native_app_glue` static helper                                                                     |
| Header / protocol source | [`<android/native_activity.h>`][na-ref], [`<android/native_window.h>`][nw-ref], [`<android/looper.h>`][looper-src], [`<android/input.h>`][input-ref], [`android_native_app_glue.h`][glue-src] |
| Window handle type       | `ANativeWindow*` (the C counterpart of Java `android.view.Surface`)                                                                                                                           |
| Event-loop primitive     | `ALooper` (`ALooper_pollOnce`) — an `epoll`-backed readiness loop over file descriptors                                                                                                       |
| Coordinate unit          | **Physical pixels** (`ANativeWindow_getWidth`/`_getHeight`); density / `dp` queried separately via [`AConfiguration`][config-ref]                                                             |
| Decoration owner         | **System** — the framework / `WindowManager` owns the `Activity` window and any system chrome; native code only ever sees the content `Surface` (no titlebar concept)                         |
| Example                  | [`./example/app.d`](./example/app.d)                                                                                                                                                          |

> [!NOTE]
> **The native side is a guest, not the host.** Every Android app is a Java/Kotlin process whose lifecycle the `ActivityManager` drives. The NDK lets a C/C++ `.so` run inside that process — but the `Activity`, its `Window`, its `Surface`, the IME, and the clipboard are all **Java-owned objects**. The NDK surfaces a small subset of them (the `Surface` as `ANativeWindow`, the input channel as `AInputQueue`, the config as `AConfiguration`); everything else stays behind a JNI boundary. This is the opposite of [X11][x11]/[Wayland][wayland]/[Win32][win32], where the C API _is_ the windowing system.

---

## What it is

Android's native-windowing entry point is [`android.app.NativeActivity`][java-na], a stock Java `Activity` subclass that forwards its lifecycle and surface callbacks to a native shared library named in the manifest. The C contract lives in `<android/native_activity.h>`: the framework fills in an `ANativeActivity` struct and calls an application-supplied `ANativeActivity_onCreate`, which wires up the `ANativeActivityCallbacks` function-pointer table. The reference is blunt about who is in charge and on which thread:

> These are the callbacks the framework makes into a native application. All of these callbacks happen on the main thread of the application.
>
> — [`<android/native_activity.h>`, `ANativeActivityCallbacks`][na-ref]

That "all on the main thread" rule is the central hazard, and the reason almost nobody uses `ANativeActivity` raw. A callback such as `onNativeWindowCreated`, `onInputQueueCreated`, `onStart`/`onResume`/`onPause`/`onStop`, or `onSaveInstanceState` runs on the same UI thread that the `ActivityManager` watches for responsiveness; block it and the system shows an "Application Not Responding" dialog and may force-close the app. The NDK ships a static helper — `android_native_app_glue` — that moves the application's loop off that thread. Its header states the design directly:

> The native activity interface provided by `<android/native_activity.h>` is based on a set of application-provided callbacks that will be called by the Activity's main thread when certain events occur. … This means that each one of these callbacks _should_ _not_ block, or they risk having the system force-close the application. … the application can implement its own main event loop in a different thread instead.
>
> — [`android_native_app_glue.h`][glue-src]

The glue spawns a second thread, runs the application's `android_main` on it with that thread's own `ALooper`, and turns each main-thread framework callback into a **command byte** written down a pipe. The application drains that pipe (plus the input queue) from its own loop, so a slow frame never stalls the UI thread. The handle the app ultimately wants — the drawable surface — is an [`ANativeWindow`][nw-ref]:

> `ANativeWindow` represents the producer end of an image queue. … It is the C counterpart of the `android.view.Surface` object in Java, and can be converted both ways. Depending on the consumer, images submitted to `ANativeWindow` can be shown on the display or sent to other consumers, such as video encoders.
>
> — [`<android/native_window.h>`, `ANativeWindow`][nw-ref]

Crucially, that surface does **not exist when `android_main` starts**. It arrives later, as the `APP_CMD_INIT_WINDOW` command, once the framework has created the `Activity`'s window — and it can be destroyed and recreated (rotation, backgrounding) any number of times during the process's life. So Android shares the [no-buffer-no-window][nbnw] shape of Wayland from a different direction: there is a window-handle-shaped hole in your program that the OS fills and empties asynchronously, and the renderer must be built and torn down to match.

---

## The minimal program

The example — [`./example/app.d`](./example/app.d) — is the smallest faithful `android_native_app_glue` client: it takes the `ANativeWindow` from the looper and reports its geometry. The NDK headers are bound with **ImportC** through the shim [`c.c`](./example/c.c), which `#include`s `android_native_app_glue.h`, `<android/native_window.h>`, and `<android/log.h>` so nothing is hand-declared — though the glue header in particular currently defeats ImportC (see [Building and cross-compiling](#building-and-cross-compiling)). The exact sequence:

1. **Entry point.** The glue's `ANativeActivity_onCreate` (compiled in from `$NDK/sources/android/native_app_glue/android_native_app_glue.c`) spawns the second thread and calls the app's `extern (C) void android_main(android_app* app)`. This runs **off** the UI thread, on a thread that already has an `ALooper` prepared and the lifecycle/input sources attached.

2. **Register the command handler.** `app.onAppCmd = &handleCmd;` installs a callback the glue invokes for each `APP_CMD_*` lifecycle command drained from its pipe.

3. **Drain the looper.** The loop calls `ALooper_pollOnce(-1, null, &events, cast(void**)&source)`. The `-1` timeout means block indefinitely until something is ready (per [`ALooper_pollOnce`][looper-ref]: _"If the timeout is negative, waits indefinitely until an event appears"_). `pollOnce` returns the `ident` of the ready source — `LOOPER_ID_MAIN` for the glue's command pipe, `LOOPER_ID_INPUT` for the input queue — and fills `source` with the matching `android_poll_source*`.

4. **Dispatch.** `source.process(app, source)` runs the glue's processing function for that source, which reads the queued command and calls back into `handleCmd` (for main) or the input handler (for input). The example checks `ALOOPER_POLL_ERROR` first and returns on error.

5. **Take the window.** Inside `handleCmd`, on `APP_CMD_INIT_WINDOW` the surface is ready: `app.window` is now a usable `ANativeWindow*`. The example reads `ANativeWindow_getWidth(app.window)` / `ANativeWindow_getHeight(app.window)` (both in physical pixels) and emits them with `__android_log_print(ANDROID_LOG_INFO, "sparkles", ...)`, which is the canonical way to get output off a native Android process (there is no stdout to a terminal — output goes to `logcat`). On `APP_CMD_TERM_WINDOW` it would release per-window resources; `app.window` becomes invalid after that command returns.

6. **Exit.** The loop checks `app.destroyRequested` after each dispatch and returns when the glue has flagged that the `Activity` is being destroyed (the glue sets this when it processes `APP_CMD_DESTROY`).

> [!IMPORTANT]
> **Not CI-verified.** Mobile is out of CI scope for this catalog, so this example is **not** auto-run. It is cross-compiled with the NDK to `aarch64-linux-android`, emitted as `lib<name>.so`, packaged into an APK with a `NativeActivity` manifest, and run on a device/emulator — and because LDC ships no prebuilt Android druntime, the runtime must first be built from source against the NDK. The mechanics (a reproducible `nix develop .#android` toolchain, the verified build command, and a hard ImportC limitation this example actually hits) are written up in [Building and cross-compiling](#building-and-cross-compiling) below. A real renderer would, at step 5, bind EGL or Vulkan to `app.window` instead of just measuring it.

> [!NOTE]
> The example uses bare `ALooper_pollOnce` rather than the deprecated `ALooper_pollAll`. The NDK now warns that `pollAll` _"will not reliably respond to `ALooper_wake`"_ and that callers _"should migrate to `ALooper_pollOnce`"_ ([`<android/looper.h>`][looper-ref]); the loop simply re-polls, treating any return as a wake.

---

## Building and cross-compiling

There is no `dub run` for Android: the binary is a cross-compiled `aarch64-linux-android` shared object, and LDC publishes **no prebuilt Android druntime**, so the D runtime must be built from source first. This repo carries a reproducible, opt-in toolchain for exactly that:

```bash
nix develop .#android      # NDK + `ldc-android` (host LDC taught to target Android aarch64)
```

The shell provides an `ldc-android` compiler (LDC plus a from-source aarch64 druntime/phobos) and the NDK, and exports `NDK`/`ANDROID_NDK_ROOT`/`ANDROID_CC`. The `ldc-android` enablement lives in [`dlang.nix`](https://github.com/PetarKirov/dlang.nix); the shell is **x86_64-linux-only** (the only host the NDK ships prebuilt for) and pulls the **unfree** Android SDK NDK, which is why it is kept out of the default shell. Two facts about the runtime build are worth recording:

- **The Android druntime must be static.** Building the _shared_ druntime fails to link against bionic — `ld.lld: error: undefined symbol: __tls_get_addr` (bionic's TLS model). The Android link path uses the static runtime anyway (`-link-defaultlib-shared=false`), so the runtime is built `BUILD_SHARED_LIBS=OFF`.
- **The target triple is `aarch64--linux-android`** (double dash, empty vendor). LDC matches the runtime/linker config by regex against the triple (`aarch64-.*-linux-android`); `aarch64-linux-android21` has no vendor segment and **does not match**, so the API level goes on the NDK clang (`aarch64-linux-android21-clang`), not the triple.

The verified invocation (inside the shell, where `ldc-android` already knows the NDK clang and runtime paths) is:

```bash
glue="$NDK/sources/android/native_app_glue"
ldc2 -mtriple=aarch64--linux-android -relocation-model=pic \
    -P-I"$glue" \
    app.d c.c "$glue/android_native_app_glue.c" \
    -L-llog -L-landroid -shared -of=build/libwin_android.so
```

The `-P-I` flag passes an include directory to LDC's **ImportC** preprocessor: `android_native_app_glue.h` lives under `$NDK/sources/`, not on the sysroot include path, so without it `c.c` fails with `'android_native_app_glue.h' file not found`.

> [!WARNING]
> **ImportC cannot currently parse the full `android_native_app_glue.h`.** That header transitively includes `<android/looper.h>` → `<sys/epoll.h>` → Linux **kernel** headers (`asm-generic/siginfo.h`, `linux/types.h`) that LDC's ImportC frontend rejects — `__int128 not supported` and parse errors on `__alignof__(void *)`. So the glue-based `c.c` shim does **not** compile via ImportC today; this is a limitation of ImportC, not of the cross-toolchain. The _lighter_ NDK headers the example also uses — `<android/native_window.h>` and `<android/log.h>` — **do** parse, and a D + ImportC program built from just those links `libandroid`/`liblog` into a valid aarch64 `.so` cleanly (verified). To take the glue path all the way to a running APK, hand-declare the `android_app` / `ALooper` / `APP_CMD_*` surface in D (sidestepping the kernel headers) or pre-expand the header with the NDK clang instead of feeding it to ImportC.

---

## Window creation & lifecycle

There is **no creation call** — that is the defining feature. The window's existence is a function of the `Activity` lifecycle, surfaced as `android_native_app_glue` commands you receive (never call):

| Command                                               | Meaning                                                           |
| ----------------------------------------------------- | ----------------------------------------------------------------- |
| `APP_CMD_INIT_WINDOW`                                 | `app.window` is now a valid `ANativeWindow*`; build the renderer  |
| `APP_CMD_TERM_WINDOW`                                 | `app.window` is going away; destroy the renderer before returning |
| `APP_CMD_WINDOW_RESIZED`                              | Surface dimensions changed                                        |
| `APP_CMD_WINDOW_REDRAW_NEEDED`                        | Compositor needs a fresh frame                                    |
| `APP_CMD_CONTENT_RECT_CHANGED`                        | The visible content rectangle moved (e.g. soft keyboard appeared) |
| `APP_CMD_GAINED_FOCUS` / `APP_CMD_LOST_FOCUS`         | Input focus changed                                               |
| `APP_CMD_START`/`_RESUME`/`_PAUSE`/`_STOP`/`_DESTROY` | The Java `Activity` lifecycle, mirrored                           |
| `APP_CMD_SAVE_STATE`                                  | Persist `app.savedState` (malloc'd) for process-death restart     |
| `APP_CMD_CONFIG_CHANGED` / `APP_CMD_LOW_MEMORY`       | Configuration changed / memory pressure                           |

These map directly to `ANativeActivityCallbacks` (`onNativeWindowCreated`/`onNativeWindowDestroyed`/`onStart`/…), which the glue intercepts on the UI thread and forwards as commands. The hard rule the lifecycle imposes: **`INIT_WINDOW`/`TERM_WINDOW` are not balanced once.** A single process may see the pair many times (every rotation, every return from background), so the renderer's setup/teardown must be idempotent and re-entrant — exactly the lesson [winit's 0.31 split][winit] of `can_create_surfaces`/`destroy_surfaces` away from `resumed`/`suspended` encodes. The surface is also reference-counted: native code that retains an `ANativeWindow*` past the loop iteration must `ANativeWindow_acquire` it and later `ANativeWindow_release`, or it dangles.

Once you have `app.window`, the drawable bytes are reached one of three ways: bind **EGL**/**Vulkan** to it (the normal path), or use the built-in software path — `ANativeWindow_setBuffersGeometry(window, w, h, format)` to set buffer size/format, then `ANativeWindow_lock` / draw into the returned `ANativeWindow_Buffer` / `ANativeWindow_unlockAndPost` to present. The geometry call documents the [physical/logical split](#coordinates--scaling): _"The width and height control the number of pixels in the buffers, not the dimensions of the window on screen. If these are different than the window's physical size, then its buffer will be scaled"_ ([`<android/native_window.h>`][nw-ref]).

---

## Event loop & frame pacing

The loop primitive is the [`ALooper`][looper-ref], and it is a textbook [readiness reactor][rvc] — an `epoll`-style multiplexer over file descriptors, not a windowing-specific construct:

> A looper is the state tracking an event loop for a thread. … An "event" here is simply data available on a file descriptor: each attached object has an associated file descriptor, and waiting for "events" means (internally) polling on all of these file descriptors until one or more of them have data available. A thread can have only one ALooper associated with it.
>
> — [`<android/looper.h>`, `ALooper`][looper-ref]

The glue attaches two fds to `android_main`'s looper: its **command pipe** (`LOOPER_ID_MAIN`) and the **`AInputQueue`** (`LOOPER_ID_INPUT`). `ALooper_pollOnce(timeoutMillis, …)` blocks for up to `timeoutMillis` (`-1` = forever, `0` = non-blocking poll) and returns the `ident` of a ready non-callback source or one of `ALOOPER_POLL_WAKE`/`_CALLBACK`/`_TIMEOUT`/`_ERROR`. Because the looper is just an fd reactor, an application can **add its own fds** with `ALooper_addFd(looper, fd, ident, events, callback, data)` — the one clean way to fold a custom event source (a timer fd, a network socket, an [async-io][async-io] runtime's eventfd) into the Android loop. This is the readiness-driven analogue of the Linux backends in [winit][winit]/[SDL3][sdl3].

**Frame pacing is a separate subsystem: the [`AChoreographer`][choreographer-ref]** ([frame-callback / vsync][fcv]). There is no `wl_surface.frame`-style per-surface callback baked into the window; instead, on a looper thread you call `AChoreographer_getInstance()` (_"This must be called on an ALooper thread"_) and post a frame callback:

> Post a callback to be run when the application should begin rendering the next frame. … The callback will only be run on the next frame, not all subsequent frames, so to render continuously the callback should itself call `AChoreographer_postVsyncCallback`.
>
> — [`<android/choreographer.h>`][choreographer-ref]

The callback is handed the target frame time as nanoseconds in the `CLOCK_MONOTONIC` base, so all work for a frame shares one timestamp. `AChoreographer_postFrameCallback64` (API 29) and `AChoreographer_postVsyncCallback` (API 33) supersede the deprecated `AChoreographer_postFrameCallback`. This is the Android equivalent of macOS's `CADisplayLink` — a vsync source decoupled from the message loop — and a renderer that paces off `ALooper` cadence instead of the Choreographer renders too fast and adds latency.

---

## Input

Input arrives as a **second looper source**, not as a callback on the window. The framework hands the glue an `AInputQueue` (surfaced as `app.inputQueue` and on the `APP_CMD_INPUT_CHANGED` command); the glue attaches it to the looper with `AInputQueue_attachLooper(queue, looper, ident, callback, data)`, so a readable input fd wakes `pollOnce` with `LOOPER_ID_INPUT`. The drain protocol is explicit and **must finish each event**:

1. `AInputQueue_getEvent(queue, &event)` — pull the next `AInputEvent*`.
2. `AInputQueue_preDispatchEvent(queue, event)` — _optional but important_: offer the key to the IME first (see below). If it returns non-zero the IME consumed it; do nothing more.
3. Handle it, then `AInputQueue_finishEvent(queue, event, handled)` — **mandatory**; failing to finish stalls the queue.

**Keyboard / keysym.** `AInputEvent_getType(event)` returns `AINPUT_EVENT_TYPE_KEY` or `AINPUT_EVENT_TYPE_MOTION`. For key events the API exposes the two identities of the [scancode / keysym / virtual-key][skv] split: `AKeyEvent_getScanCode` (the hardware key id, layout-independent) and `AKeyEvent_getKeyCode` (the Android `AKEYCODE_*` symbolic code, layout-dependent). Android's `keyCode` is its closest analogue to a virtual-key; winit's `NativeKeyCode::Android(u32)` carries exactly this value when it cannot map a key.

**Pointer / touch.** Motion events are pointer/touch/stylus; `AMotionEvent_getX(event, pointerIndex)` / `_getY` return per-pointer coordinates in the window's pixel space, with multi-touch exposed through the pointer index and `AMotionEvent_getPointerCount`. There is no [accelerated-vs-raw][rap] distinction at this layer the way desktop has it: touch is absolute by construction, and pointer capture (relative motion, for trackpad/mouse) is a higher-level concern routed through Java `View.requestPointerCapture()` rather than the raw queue.

**IME / text entry — Java-side.** Composed text does **not** come through `AInputQueue`. The soft keyboard is an `android.view.inputmethod.InputMethodManager` ([pre-edit / composition][pec]); native code only gets `preDispatchEvent` as a hook to let the IME swallow hardware-key events before the app sees them. To raise the keyboard or read composed text, native code must **call into Java over JNI** — `InputMethodManager.showSoftInput(...)` / `hideSoftInputFromWindow(...)` — using the `JNIEnv*` reachable from `app.activity.vm`/`app.activity.clazz`. There is no NDK text-input API.

---

## Coordinates & scaling

The window API speaks **physical device pixels**: `ANativeWindow_getWidth`/`_getHeight` _"Return the current width/height in pixels of the window surface"_ ([`<android/native_window.h>`][nw-ref]). The [logical unit][lpc] — Android's **density-independent pixel (`dp`)** — is a separate query against [`AConfiguration`][config-ref], and the [scale factor][sf] is the device's density bucket divided by the 160-dpi baseline:

`pixels = dp × (AConfiguration_getDensity() / 160)`

`AConfiguration_getDensity()` returns an `ACONFIGURATION_DENSITY_*` bucket — `…_MEDIUM = 160` (the `mdpi` baseline, scale 1.0), `…_HIGH = 240` (1.5×), `…_XHIGH = 320` (2.0×), `…_XXHIGH = 480` (3.0×), `…_XXXHIGH = 640` (4.0×) — while `AConfiguration_getScreenWidthDp`/`_getScreenHeightDp` give the available area in `dp`. The richer source of truth (exact `densityDpi`, `xdpi`/`ydpi`, font scale) is the Java `DisplayMetrics` object, again reachable only over JNI. Because density is a per-`Activity` configuration value, a fold to a new display or a multi-window resize arrives as `APP_CMD_CONFIG_CHANGED` carrying a fresh `AConfiguration`, not as a per-window scale event — the [mixed-DPI migration][sf] story is "re-read the config", closer to X11's global model than to Wayland's per-surface `preferred_scale`.

---

## Decorations & multi-window/popups

> [!NOTE]
> **N/A at the native layer — the system owns all chrome.** There is no titlebar, border, or close button concept in the NDK ([CSD vs SSD][csd] does not apply): the `Activity` window is owned by the framework `WindowManager`, which draws the status bar / navigation bar and (in split-screen/freeform) any window frame. Native code receives only the content `Surface`. This is purest server-side ownership — even further than Win32, since the application cannot draw its own frame at this layer at all.

**Multi-window** is likewise a Java/`WindowManager` affair. A single `NativeActivity` is one content surface; an app does not open additional native top-levels from `android_main`. Multi-window (split-screen, freeform, picture-in-picture) and multi-display are negotiated through the Java `Activity`/`WindowManager` APIs and surface to native code only as configuration changes and `INIT`/`TERM_WINDOW` churn. **Popups, menus, and dialogs** ([override-redirect vs xdg_popup grab][orx]) have no NDK equivalent — they are Java `PopupWindow`/`Dialog`/`Menu` objects, so a native app that needs them must build them in Java or render them itself inside its one surface.

---

## Clipboard & drag-and-drop

> [!WARNING]
> **No NDK clipboard or drag-and-drop API.** Both are Java framework services reachable only through JNI. The clipboard is `android.content.ClipboardManager` (`getSystemService(CLIPBOARD_SERVICE)`, then `setPrimaryClip`/`getPrimaryClip` over a `JNIEnv*`); drag-and-drop is the `View.startDragAndDrop` / `View.OnDragListener` / `DragEvent` machinery on the Java side. Neither has any presence in `<android/*.h>`.

This is the recurring Android pattern: the NDK gives native code the **drawing surface and the input/lifecycle stream**, and nothing else. Anything that is a framework _service_ (clipboard, IME, sharing, notifications, sensors beyond `<android/sensor.h>`, multi-window) lives behind the JVM and is reached with `JNIEnv*` from `app.activity`. A reusable windowing layer on Android therefore necessarily ships a JNI bridge alongside the NDK calls — the clipboard/IME gap is structural, not an oversight.

---

## What toolkits build on this

- **[winit][winit]** — its `winit-android` backend is built on `android-activity` (the successor to `ndk-glue`), which is `android_native_app_glue` re-implemented in Rust: it runs `android_main`, owns the `ALooper`, and turns `APP_CMD_INIT_WINDOW`/`TERM_WINDOW` into the `can_create_surfaces`/`destroy_surfaces` lifecycle hooks. The `ANativeWindow*` is what winit hands out as the Android `RawWindowHandle`. (winit also supports `GameActivity` as an alternative to `NativeActivity`.)
- **[SDL3][sdl3]** — its Android backend uses a Java `SDLActivity` (not `NativeActivity`), but underneath it consumes the same `ANativeWindow` for its EGL/Vulkan surface and bridges input/IME/clipboard through JNI exactly as described here. On Android, SDL deliberately reports the surface in **physical pixels** (the [physical-coordinate][lpc] platform).
- **[GLFW][glfw]** — has no official Android backend; the niche is filled by `android_native_app_glue` directly or by SDL/winit, which is itself a finding about where the raw API's ergonomics give out.

---

## Sources

- [Native Activity — NDK reference][na-ref] — `ANativeActivity`, `ANativeActivityCallbacks`, main-thread rule
- [Native Window — NDK reference][nw-ref] — `ANativeWindow` ("producer end of an image queue"), `getWidth`/`getHeight`/`setBuffersGeometry`/`lock`/`unlockAndPost`/`acquire`/`release`
- [Looper — NDK reference][looper-ref] — `ALooper`, `ALooper_pollOnce`, `ALooper_addFd`, `ALOOPER_POLL_*`
- [Input — NDK reference][input-ref] — `AInputQueue`, `AInputEvent`, `attachLooper`/`getEvent`/`preDispatchEvent`/`finishEvent`, `AKeyEvent_*`, `AMotionEvent_*`
- [Choreographer — NDK reference][choreographer-ref] — `AChoreographer`, `postFrameCallback64`/`postVsyncCallback`, vsync pacing
- [Configuration — NDK reference][config-ref] — `AConfiguration_getDensity`, `ACONFIGURATION_DENSITY_*`, `dp`/density baseline
- [`android_native_app_glue.h`][glue-src] / [`.c`][glue-c] (AOSP) — the threading rationale, `android_app`, `android_poll_source`, `APP_CMD_*`, `LOOPER_ID_*`
- [`android.app.NativeActivity`][java-na] (Java reference) — the Java side of the bridge
- [Screen densities guide][densities] — `dp` ↔ px, density buckets
- This survey's runnable example: [`./example/app.d`](./example/app.d) (+ ImportC shim [`./example/c.c`](./example/c.c), [`./example/dub.sdl`](./example/dub.sdl))
- Shared vocabulary: [concepts][concepts]; sibling deep-dives [winit][winit], [SDL3][sdl3], [GLFW][glfw]; cross-tree [async-io][async-io]

<!-- References -->

<!-- NDK reference docs -->

[na-ref]: https://developer.android.com/ndk/reference/group/native-activity
[nw-ref]: https://developer.android.com/ndk/reference/group/a-native-window
[looper-ref]: https://developer.android.com/ndk/reference/group/looper
[looper-src]: https://cs.android.com/android/platform/superproject/main/+/main:frameworks/native/include/android/looper.h
[input-ref]: https://developer.android.com/ndk/reference/group/input
[choreographer-ref]: https://developer.android.com/ndk/reference/group/choreographer
[config-ref]: https://developer.android.com/ndk/reference/group/configuration

<!-- AOSP / glue source -->

[glue-src]: https://cs.android.com/android/platform/superproject/main/+/main:frameworks/base/native/android/native_app_glue/android_native_app_glue.h
[glue-c]: https://cs.android.com/android/platform/superproject/main/+/main:frameworks/base/native/android/native_app_glue/android_native_app_glue.c

<!-- Java framework docs -->

[java-na]: https://developer.android.com/reference/android/app/NativeActivity
[densities]: https://developer.android.com/training/multiscreen/screendensities

<!-- Sibling deep-dives -->

[winit]: ../../winit.md
[sdl3]: ../../sdl3.md
[glfw]: ../../glfw.md
[x11]: ../x11/
[wayland]: ../wayland/
[win32]: ../win32/

<!-- Cross-tree -->

[async-io]: ../../../async-io/index.md

<!-- Shared concepts -->

[concepts]: ../../concepts.md
[csd]: ../../concepts.md#csd-vs-ssd
[skv]: ../../concepts.md#scancode-keysym-virtualkey
[lpc]: ../../concepts.md#logical-vs-physical-coords
[sf]: ../../concepts.md#scale-factor
[pec]: ../../concepts.md#pre-edit-composition
[orx]: ../../concepts.md#override-redirect-vs-xdg-popup-grab
[rap]: ../../concepts.md#raw-vs-accelerated-pointer
[nbnw]: ../../concepts.md#no-buffer-no-window
[fcv]: ../../concepts.md#frame-callback-vsync
[rvc]: ../../concepts.md#readiness-vs-completion-windowing
