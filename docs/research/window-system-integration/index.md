# Window-System Integration

A breadth-first survey of how fifteen toolkits, frameworks, and shims actually talk to
the platform window system — the seam between an application and Wayland, X11, Win32,
AppKit, and the mobile/web hosts. It maps the recurring hazards and design forks of the
windowing layer (decorations, coordinates, input translation, the loop, popups, frame
pacing) against the consensus the field has converged on, to inform a **from-scratch,
cross-platform windowing layer for Sparkles** — targeting Wayland, X11, Windows (Win32), and
macOS (AppKit) first, with Android and iOS/iPadOS to follow. ("Wayland-first" below means
_preferring Wayland over X11 on Linux_, not prioritizing Linux over Windows or macOS.)

This survey answers six questions:

1. **Concepts** — what is the shared vocabulary of the windowing layer, from
   [client-vs-server decorations][csd] and the [scale factor][scale] to the
   [no-buffer-no-window][nobuffer] handshake and [readiness-vs-completion][readiness] loop
   ownership? See [concepts][concepts].
2. **How each toolkit integrates** — for each surveyed system, how does it create windows,
   own (or cede) the loop, translate input, speak Wayland, scale, handle multi-window and
   popups, thread, manage the clipboard, and expose escape hatches? See the
   [master catalog](#master-catalog) and the per-library [deep-dives](#library-deep-dives).
3. **Where the field is unanimous vs where it forks** — which behaviours are table stakes a
   new toolkit should simply adopt, and which are genuine architectural decisions with a
   strong argument on each side? See [comparison][comparison].
4. **The per-platform gotchas** — the concrete, citation-backed traps each platform
   (Wayland, X11, Win32, macOS) springs on a windowing layer, as a quick-reference cheat
   sheet. See [platform-gotchas][gotchas].
5. **The gap a green-field framework faces** — where a brand-new windowing layer stands
   today against the consensus, per dimension. See the
   [delta table][comparison-delta] in [comparison][comparison].
6. **What Sparkles should build** — the resolved positions on each fork and a milestoned
   roadmap for the cross-platform windowing layer. See [recommendations][recommendations].

> [!NOTE]
> **Scope.** This is the master index for the window-system-integration research tree.
> Each row links to a deep-dive that was written and fact-checked independently against the
> upstream source tree at a pinned commit; where this index summarizes a system, the
> deep-dive is the source of truth. Each deep-dive applies the same ten-dimension analysis
> spine (window lifecycle, event loop, input/IME, Wayland specifics, DPI/scaling,
> multi-window/popups, threading, clipboard/DnD, escape hatches, history/regrets); where a
> dimension does not apply to a subject, the _absence_ is recorded as a finding.

**Last reviewed:** June 8, 2026

---

## Master Catalog

One row per surveyed system; **the library name links to its deep-dive**. **Loop
ownership** is the [readiness-vs-completion][readiness] loop-ownership fork (poll =
app-owned; callback = library/OS-owned; hybrid = both, behind one dispatcher). The six
**platform** columns mark the backends each deep-dive covers — `✓` supported, `–` not. The
**Wayland** column means a native (or GTK-delegated) Wayland client, so [Avalonia][avalonia]
and [Uno][uno] — which reach Wayland only through XWayland — show `–`; additional targets
(Web/WASM, KMS/DRM, embedded) are noted in each deep-dive. **Wayland decoration** is the
[CSD/SSD][csd] strategy — mostly `N/A` because most subjects are not native Wayland clients,
itself the survey's headline finding.

| Library                                | Language    | Category                            | Loop ownership                | Wayland | X11 | Win32 | macOS | Android | iOS | Wayland decoration                           |
| -------------------------------------- | ----------- | ----------------------------------- | ----------------------------- | :-----: | :-: | :---: | :---: | :-----: | :-: | -------------------------------------------- |
| **[Winit][winit]**                     | Rust        | windowing library                   | callback (own loop)           |    ✓    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | own-drawn Adwaita (`sctk-adwaita`)           |
| **[SDL3][sdl3]**                       | C           | windowing + media library           | **hybrid** (poll / callbacks) |    ✓    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | SSD-first → [libdecor][libdecor] CSD         |
| **[GLFW][glfw]**                       | C           | minimal windowing library           | **poll** (app-owned)          |    ✓    |  ✓  |   ✓   |   ✓   |    –    |  –  | [libdecor][libdecor] → SSD → own-drawn       |
| **[sokol_app.h][sokol]**               | C99         | single-header app shim              | callback (own loop)           |    –    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | **N/A — no Wayland backend** (X11 only)      |
| **[Qt 6 (QPA)][qt6]**                  | C++         | full GUI framework (QPA layer)      | hybrid (Qt owns `QEventLoop`) |    ✓    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | own-drawn CSD plugins (predates libdecor)    |
| **[GTK 4 / GDK][gtk4]**                | C (GObject) | full framework (ref. WL client)     | callback/hybrid (GLib source) |    ✓    |  ✓  |   ✓   |   ✓   |    ✓    |  –  | own-drawn CSD; **only** KDE SSD protocol     |
| **[Flutter Engine][flutter]**          | C/C++       | engine / embedder framework         | callback/hybrid (embedder)    |    ✓    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | **N/A — delegates to GTK 3 / GDK**           |
| **[Chromium Ozone][ozone]**            | C++         | browser platform-abstraction        | hybrid (fd → `MessagePump`)   |    ✓    |  ✓  |   –   |   –   |    –    |  –  | SSD-first → own Views-drawn CSD              |
| **[Avalonia][avalonia]**               | C# (.NET)   | from-scratch Skia UI framework      | hybrid (managed Dispatcher)   |    –    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | **N/A — no native Wayland** (X11/XWayland)   |
| **[.NET MAUI][maui]**                  | C# (.NET)   | native-control-wrapping framework   | **callback** (owns no loop)   |    –    |  –  |   ✓   |   ✓   |    ✓    |  ✓  | **N/A — no Linux desktop backend**           |
| **[Uno Platform][uno]**                | C# (.NET)   | WinUI-over-Skia framework           | hybrid (per-platform)         |    –    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | **N/A — no native Wayland** (XWayland)       |
| **[Slint][slint]**                     | Rust        | reactive UI on a backend abstr.     | hybrid (winit / calloop KMS)  |    ✓    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | own-drawn CSD via winit (`sctk-adwaita`)     |
| **[wxWidgets][wxwidgets]**             | C++         | native-widget-wrapping framework    | callback/delegated (native)   |    ✓    |  ✓  |   ✓   |   ✓   |    –    |  –  | **N/A — delegated to GTK**                   |
| **[JUCE][juce]**                       | C++         | audio-focused GUI framework         | hybrid (own / host-as-plugin) |    –    |  ✓  |   ✓   |   ✓   |    ✓    |  ✓  | **N/A — no Wayland backend** (X11 only)      |
| **[Smithay SCTK + libdecor][smithay]** | Rust + C    | Wayland client toolkit + CSD helper | **poll** (caller-owned)       |    ✓    |  –  |   –   |   –   |    –    |  –  | three-tier: SSD → `FallbackFrame` → libdecor |

> Two structural facts fall straight out of this table and frame the whole survey: **the
> "Wayland decoration" column is mostly empty** — only ~6 of 15 speak Wayland natively, so
> **native Wayland is the field's single biggest gap** (see
> [comparison §Dimension 4][comparison-dim4]); and **loop ownership and native coordinate
> unit are the two axes that genuinely fork** — every other dimension trends to a consensus
> ([comparison Part 3][comparison-consensus]).

---

## Taxonomy

Each table re-cuts the same fifteen subjects by one axis; every row links back to a
deep-dive. The full per-dimension treatment is in [comparison][comparison].

### By loop ownership

The [readiness-vs-completion][readiness] loop-ownership fork: who calls whom. On Linux every
loop is, underneath, a readiness reactor over the display-socket fd.

| Loop ownership                               | Who drives                                     | Subjects                                                                                                                                                        |
| -------------------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Poll (app-owned)**                         | app calls `PollEvents` / dispatches the loop   | [GLFW][glfw], default [SDL3][sdl3], [Smithay SCTK][smithay]                                                                                                     |
| **Callback (library/OS-owned)**              | control inverted; the OS/library calls the app | [Winit][winit], [sokol][sokol], [MAUI][maui], opt-in [SDL3][sdl3]                                                                                               |
| **Hybrid (own dispatcher over native pump)** | toolkit owns a loop wrapping the native source | [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [Uno][uno], [JUCE][juce], [Flutter][flutter], [Chromium Ozone][ozone], [wxWidgets][wxwidgets], [Slint][slint] |

### By Wayland decoration strategy

The [CSD/SSD][csd] choice. "SSD is only a hint", so every native client carries a CSD path;
the rest sidestep the question by not being a native Wayland client.

| Decoration strategy                          | Subjects                                                                                          |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Own-drawn CSD** (no [libdecor][libdecor])  | [Winit][winit] (`sctk-adwaita`), [Qt 6][qt6] (plugins), [GTK 4][gtk4], [Slint][slint] (via winit) |
| **SSD-first, own CSD fallback**              | [Chromium Ozone][ozone] (Views-drawn fallback)                                                    |
| **SSD-first, [libdecor][libdecor] fallback** | [SDL3][sdl3]                                                                                      |
| **[libdecor][libdecor]-first chain**         | [GLFW][glfw] (libdecor → SSD → own), [Smithay SCTK][smithay] (SSD → `FallbackFrame` → libdecor)   |
| **N/A — delegates to GTK**                   | [Flutter][flutter], [wxWidgets][wxwidgets]                                                        |
| **N/A — X11-only / XWayland**                | [sokol][sokol], [Avalonia][avalonia], [Uno][uno], [JUCE][juce]                                    |
| **N/A — no Linux desktop backend**           | [MAUI][maui]                                                                                      |

### By native coordinate unit

The [logical-vs-physical][coords] design choice — which unit the API speaks natively.

| Native unit                                      | Subjects                                                                                                                                                        |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Physical** (app converts via scale factor)     | [Winit][winit] (`PhysicalSize`/`PhysicalPosition`)                                                                                                              |
| **Logical** (DIPs; physical only at the OS seam) | [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [JUCE][juce], [Slint][slint], [MAUI][maui], [Uno][uno], [wxWidgets][wxwidgets], [Chromium Ozone][ozone] (DIP) |
| **Mixed / per-platform native unit**             | [SDL3][sdl3], [GLFW][glfw] (window-size vs framebuffer-size), [Flutter][flutter] (logical + ratio), [sokol][sokol]                                              |
| **Logical, integer scale only**                  | [Smithay SCTK][smithay] (no fractional-scale — the cautionary tale)                                                                                             |

### By threading model

The most unanimous dimension: **GUI = main thread, forced by macOS AppKit** (see
[comparison §Dimension 7][comparison-dim7]).

| Threading posture                           | Subjects                                                                                                                                                                                              |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Main-thread-only for windows/events**     | [SDL3][sdl3], [GLFW][glfw], [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [MAUI][maui], [wxWidgets][wxwidgets], [JUCE][juce], [Flutter][flutter], [Chromium Ozone][ozone] (UI thread), [Uno][uno] |
| **Main-thread on macOS, relaxed elsewhere** | [Winit][winit] (`MainThreadMarker`; `with_any_thread` on Linux/Win), [Slint][slint]                                                                                                                   |
| **No main-thread rule**                     | [Smithay SCTK][smithay] (Wayland has no such constraint)                                                                                                                                              |

### By escape-hatch shape

How the [native handle][comparison-dim9] is exposed for GPU interop and raw passthrough.
Every toolkit exposes _something_; the fork is how typed it is.

| Escape-hatch shape                            | Subjects                                                                                                                                                        |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Typed `raw-window-handle` (rwh 0.6)**       | [Winit][winit], [Slint][slint] (caller bridges raw pointers in [Smithay][smithay])                                                                              |
| **Typed per-platform accessors**              | [GLFW][glfw] (`glfwGet*Window`), [Qt 6][qt6] (`QNativeInterface`), [Avalonia][avalonia], [GTK 4][gtk4]                                                          |
| **ABI-stable property / value-struct lookup** | [SDL3][sdl3] (properties bag), [sokol][sokol] (`sapp_get_swapchain`)                                                                                            |
| **Type-erased `void*`**                       | [sokol][sokol], [JUCE][juce] ("no guarantees what you'll get back")                                                                                             |
| **Literal native window object**              | [MAUI][maui] (`handler.PlatformView`), [Flutter][flutter] (`HWND`/`NSView`/`GtkWidget`)                                                                         |
| **Raw message-pump passthrough**              | [SDL3][sdl3], [Qt 6][qt6], [Avalonia][avalonia], [Uno][uno], [wxWidgets][wxwidgets], [JUCE][juce], [Winit][winit] (Win32 `msg_hook`); **[GLFW][glfw] has none** |
| **Capability probing / mix-in extensions**    | [Avalonia][avalonia] (`TryGetFeature<T>`), [Chromium Ozone][ozone] (`X11Extension`), [Slint][slint] (`WindowAdapter`)                                           |

---

## Milestones

A timeline of windowing-layer redesigns across the field, drawn from the per-subject history
sections. Entries dated 2025–2026 are taken from each project's **development tree at the
pinned commit** ("as observed in this checkout") and are forward-dated relative to general
public knowledge; they are marked `*`.

| Year        | Windowing-layer milestone                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2012        | **Qt 5** ships [QPA][qt6] (originally "Lighthouse"): runtime-loaded platform plugins over `QWindow`, replacing Qt 4's native per-platform code   |
| 2013        | **GTK 3.8** introduces [GdkFrameClock][gtk4] — one per-surface vsync-synced scheduler                                                            |
| 2013–2016   | **Chromium Ozone** introduced as the Aura platform-abstraction layer ("[Interfaces, not ifdefs][ozone]")                                         |
| 2013–2014   | **GNOME/Mutter** drops server-side decorations; GTK CSD becomes the de-facto model every Wayland client copies ([Smithay/libdecor][smithay])     |
| 2016        | **GLFW 3.2** adds a [Wayland backend][glfw] (crude own-drawn fallback decorations); **Qt 5.6** adds opt-in high-DPI scaling                      |
| 2017        | **Avalonia** [Wayland backend tracked][avalonia] (#1243) — still unshipped at the studied commit                                                 |
| 2017–2019   | **[libdecor][smithay]** created (Ådahl/Rauch) to extract reusable, compositor-portable CSD with a `dlopen` plugin model                          |
| 2018–2020   | **Winit** [Event Loop 2.0][winit] (issue #459): the `poll_events()` iterator replaced by a callback model for Web/iOS/macOS                      |
| ~2018–2019  | **Flutter** Linux desktop [embedder][flutter] evolves from a GLFW prototype to the GObject `fl_*` GTK 3 API                                      |
| 2019        | **GLFW 3.3** adds the [per-monitor content-scale model][glfw]; **JUCE** [Wayland gap][juce] reported (#549, XWayland-only)                       |
| ~2020       | **Smithay SCTK** [rewritten][smithay] onto the wayland-rs 0.30+ handler-trait + `Dispatch` object model                                          |
| 2020        | **GTK 4.0** removes per-widget `GdkWindow` for [one `GdkSurface` per toplevel][gtk4]; `gdk_toplevel_present()` single async entry                |
| 2020        | **Qt 6.0** makes [high-DPI scaling always-on][qt6] (no default rounding); per-monitor-v2 DPI on Windows                                          |
| 2020        | **sokol** [Wayland support requested][sokol] (issue #245) — still open/unimplemented at the studied commit                                       |
| 2021        | **Chromium Ozone** adds a [dedicated Wayland fd-watch thread][ozone] (`prepare_read`/EGL deadlock fix); legacy non-Ozone X11 removed             |
| 2021+       | **GTK 4** [Wayland-first protocol expansion][gtk4]: fractional-scale-v1, xdg-activation, cursor-shape-v1, presentation-time                      |
| 2022        | **.NET MAUI 1.0** replaces Xamarin.Forms renderers with the [handler / `PropertyMapper`][maui] architecture                                      |
| 2022–2023   | **Flutter** multi-view [embedder API][flutter] (`FlutterEngineAddView`) breaks the one-view-per-engine constraint                                |
| 2023        | **Avalonia** [Dispatcher rewrite][avalonia] (#10691): ports the WPF priority model over a tiny per-platform `IDispatcherImpl`                    |
| 2023–2024   | **Avalonia 11** marks [platform windowing interfaces][avalonia] `[Unstable]`/`[PrivateApi]`, removed from the public API                         |
| 2024        | **GLFW 3.4** adds runtime platform selection (single binary holds Wayland+X11) and [libdecor decorations][glfw] (PR #2285)                       |
| 2024        | **JUCE 8** ships the [Direct2D rendering backend][juce] on Windows alongside legacy GDI                                                          |
| 2024        | **Uno 5.2** introduces [from-scratch Skia desktop hosts][uno] (X11/Win32/macOS), dropping GTK+3 (−200 MB); multi-window                          |
| 2024        | **Slint 1.7** upgrades to [winit 0.30][slint], forcing the `ApplicationHandler` + lazy `WinitWindowOrNone` redesign                              |
| 2024        | **Winit 0.30** ships the [`ApplicationHandler`][winit] trait; deprecates closure-based `EventLoop::run` for `run_app`                            |
| 2024–2025\* | **Flutter** desktop multi-window with [`WindowArchetype`][flutter]; the `flutter/engine` repo merges into the `flutter/flutter` monorepo         |
| 2025\*      | **SDL 3.2.0** (first stable SDL3): [main-callbacks model][sdl3] + properties bag + native-coordinate high-DPI overhaul                           |
| 2025\*      | **wxWidgets 3.3.x**: [`src/gtk/wayland.cpp`][wxwidgets] opens its own `wl_display` for `pointer-warp-v1`, bypassing GDK; GTK4 still not shipping |
| 2025–2026\* | **sokol** [decouples window/swapchain][sokol] from sokol-gfx; macOS/iOS migrate MTKView → CAMetalLayer + CADisplayLink                           |
| 2025–2026\* | **Smithay SCTK 0.20.0** + the [`delegate_dispatch2!`][smithay] collapse (breaking dispatch-model simplification)                                 |
| 2026\*      | **Slint 1.16**: [winit becomes the default backend][slint] on all platforms (Qt no longer default on Linux)                                      |

The two redesigns **every** verdict converges on regretting: **(a)** deferring native
Wayland inherits XWayland's ceiling (no fractional scale, no frame-callback vsync, no
`xdg_popup` grabs) — the [Avalonia][avalonia] (8-year delay), [JUCE][juce], [Uno][uno],
[sokol][sokol], and [MAUI][maui] story; and **(b)** under-specifying the windowing contract
(pushing title/decoration/popups/fullscreen onto embedders) yields "silently unsupported per
platform" — the [Flutter][flutter] and [MAUI][maui] story.

---

## Quick Navigation

### Suggested reading paths

- **"I want the vocabulary first."** [concepts][concepts] → one native-Wayland deep-dive
  ([Winit][winit] or [SDL3][sdl3]) → [Smithay + libdecor][smithay] (the Wayland authority).
- **"I want the cross-toolkit comparison."** [Master catalog](#master-catalog) →
  [comparison][comparison] → individual deep-dive rows of interest.
- **"I want to see raw OS API bootstrap examples."** See [OS Windowing APIs](./os-apis/index.md), containing minimal window-bootstrap programs: [Wayland](./os-apis/wayland/example/app.d), [X11](./os-apis/x11/example/app.d), [Win32](./os-apis/win32/example/app.d), [AppKit](./os-apis/appkit/example/app.d), [iOS](./os-apis/uikit/example/app.d), and [Android](./os-apis/android/example/app.d).
- **"I want to browse the empirical feature demos."** Check the [feature matrix](./os-apis/feature-matrix.md) and browse the implementation folders: [Wayland Demos](./os-apis/wayland/examples/), [X11 Demos](./os-apis/x11/examples/), [Win32 Demos](./os-apis/win32/examples/), and [AppKit Demos](./os-apis/appkit/examples/).
- **"I want the per-platform traps."** [platform-gotchas][gotchas] (Wayland / X11 / Win32 /
  macOS cheat sheet) → the relevant dimension in [comparison][comparison].
- **"I care about a specific dimension"** (e.g. IME, DPI, decorations). [concepts][concepts]
  section for the term → the matching [comparison][comparison] dimension → the deep-dives it
  cites.
- **"I am designing the new framework windowing layer."** [comparison][comparison] (consensus
  - forks + the [delta table][comparison-delta]) → [recommendations][recommendations] (resolved
    positions + milestoned roadmap), with [platform-gotchas][gotchas] as the trap checklist and
    [Smithay + libdecor][smithay] as the Wayland-client implementation reference. The
    windowing loop's relationship to an external async runtime is in the async-io
    [readiness][readiness] concept.

### Concepts

- **[Window-System Concepts][concepts]** — the shared vocabulary every deep-dive references:
  [CSD vs SSD][csd], [scancode/keysym/virtual-key][scancode], [logical vs physical
  coordinates][coords], [the scale factor & fractional scaling][scale], [IME
  pre-edit][preedit], [override-redirect vs `xdg_popup` grab][popup], [the Win32 modal resize
  loop][modalloop], [raw vs accelerated pointer][pointer], [no-buffer-no-window][nobuffer],
  [frame-callback vsync][vsync], and [readiness vs completion in the loop][readiness]. Several
  concepts carry a CI-verified runnable D snippet.

### Synthesis

- **[Comparison][comparison]** — the capstone: the at-a-glance master table, the
  ten-dimension head-to-head, the [consensus standards][comparison-consensus], the four
  [architectural forks][comparison-forks], and the [delta table][comparison-delta] for a
  green-field framework.
- **[Platform Gotchas][gotchas]** — the per-platform (Wayland / X11 / Win32 / macOS) trap
  cheat sheet, cross-linked to the deep-dive that hit each one.
- **[Recommendations][recommendations]** — the resolved position on every fork and a
  prioritized roadmap for the cross-platform Sparkles windowing layer.

### Library deep-dives

Grouped by how they relate to the windowing layer. **Tier 1** are windowing-layer
specialists — native clients you would study to build one. **Tier 2** own the pixels (draw
everything; the OS window is just a surface). **Tier 3** wrap or delegate to a native
toolkit, inheriting its windowing posture.

#### Tier 1 — Windowing libraries & native clients

| Library                            | One-line                                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| [Winit][winit]                     | Rust's de-facto windowing library: callback `ApplicationHandler`, draws nothing, hands a `raw-window-handle` to the GPU. |
| [SDL3][sdl3]                       | C windowing + media library: hybrid poll/main-callbacks loop, properties-bag native handles, native-coordinate high-DPI. |
| [GLFW][glfw]                       | Minimal C windowing library: app-owned poll loop, window-vs-framebuffer split, libdecor→SSD→own CSD.                     |
| [Qt 6 (QPA)][qt6]                  | Full C++ framework whose QPA layer is a runtime-loaded platform plugin over `QWindow`; own-drawn Wayland CSD.            |
| [GTK 4 / GDK][gtk4]                | The reference Wayland client: one `GdkSurface` per toplevel, GLib-`GSource` loop, `GdkFrameClock` vsync.                 |
| [Smithay SCTK + libdecor][smithay] | Rust Wayland client toolkit + C CSD helper — the **Wayland authority** for the survey; caller-owned poll loop.           |

#### Tier 2 — Own-the-pixels frameworks

| Library                   | One-line                                                                                                             |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| [Chromium Ozone][ozone]   | The browser's platform-abstraction layer ("interfaces, not ifdefs"); native Wayland + X11, fd → `base::MessagePump`. |
| [Avalonia][avalonia]      | From-scratch .NET/Skia UI framework: own windowing, WPF-style managed Dispatcher; X11-only (no native Wayland).      |
| [Uno Platform][uno]       | WinUI-over-Skia .NET framework: from-scratch X11/Win32/macOS hosts (dropped GTK+3); XWayland on Wayland sessions.    |
| [Slint][slint]            | Rust reactive UI on a `Platform`/`WindowAdapter` abstraction stacked over winit (+ a bare-KMS backend).              |
| [Flutter Engine][flutter] | Engine + per-platform embedder behind a frozen C ABI; Linux embedder is GTK 3 delegating to GDK.                     |
| [sokol_app.h][sokol]      | Single-header C99 app shim (window + 3D context + input + entry point); one global window, X11-only on Linux.        |

#### Tier 3 — Native-toolkit-wrapping frameworks

| Library                | One-line                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------ |
| [wxWidgets][wxwidgets] | C++ framework wrapping Win32/Cocoa/GTK for native controls; Linux is GTK (X11 + Wayland via GDK).                  |
| [JUCE][juce]           | Audio-focused C++ framework: small `ComponentPeer` interface with hand-written native backends; X11-only on Linux. |
| [.NET MAUI][maui]      | Native-control-wrapping .NET framework (Windows/Mac Catalyst/iOS/Android/Tizen); no Linux desktop backend.         |

---

## Sources

Each deep-dive carries its own primary-source citations, pinned to a specific upstream
commit and quoting the source tree verbatim. The cross-cutting artifacts behind this index's
classifications are:

- **Shared vocabulary** — the [concepts][concepts] page (decorations, coordinates, scale,
  IME, popups, the loop), each term grounded in a cited deep-dive and the canonical external
  reference (Wayland protocols on wayland.app, the X11 [ICCCM][x11-icccm] spec,
  [xkbcommon][xkbcommon], [libdecor][libdecor], and Wayback-pinned Win32/AppKit docs).
- **Per-subject sources** — the upstream repository trees and official docs cited in each
  linked deep-dive: [Winit][winit], [SDL3][sdl3], [GLFW][glfw], [sokol][sokol], [Qt 6][qt6],
  [GTK 4][gtk4], [Flutter Engine][flutter], [Chromium Ozone][ozone], [Avalonia][avalonia],
  [.NET MAUI][maui], [Uno][uno], [Slint][slint], [wxWidgets][wxwidgets], [JUCE][juce],
  [Smithay SCTK + libdecor][smithay].
- **Cross-tree siblings** — the async-io [readiness][readiness] loop concepts the windowing
  loop shares, and the [ui-layout][ui-layout] catalog of the rendering/layout layers that sit
  _on top_ of a windowing substrate.

<!-- References -->

<!-- Topic siblings -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md
[recommendations]: ./recommendations.md
[gotchas]: ./platform-gotchas.md

<!-- Comparison sub-section anchors -->

[comparison-dim4]: ./comparison.md#dimension-4-wayland-specifics
[comparison-dim7]: ./comparison.md#dimension-7-threading
[comparison-dim9]: ./comparison.md#dimension-9-escape-hatches
[comparison-consensus]: ./comparison.md#part-3-the-consensus-standards
[comparison-forks]: ./comparison.md#part-4-the-architectural-trade-offs-where-the-field-forks
[comparison-delta]: ./comparison.md#part-5-the-delta-table

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

[ui-layout]: ../ui-layout/index.md

<!-- External specs -->

[x11-icccm]: https://tronche.com/gui/x/icccm/sec-2.html
[xkbcommon]: https://xkbcommon.org/
[libdecor]: https://gitlab.freedesktop.org/libdecor/libdecor
