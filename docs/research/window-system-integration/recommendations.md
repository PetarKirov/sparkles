# Architecture Recommendations for a New Cross-Platform Windowing Layer

The proposal leaf of the [window-system-integration survey][index]. Where
[comparison][comparison] lays out the design forks side by side and refuses to pick a
winner, this document **takes a position on each one** — a concrete, opinionated
architecture for a _new, from-scratch_ cross-platform windowing layer for Sparkles,
targeting **Wayland, X11, Win32, and AppKit first**, with **Android/iOS** as a deliberate
later phase. Every call is grounded in what the fifteen deep-dives actually do, names the
subject it copies (or the mistake it avoids), and carries its trade-off out loud.

> [!NOTE]
> **Scope.** This is the _recommendations_ capstone, the bridge target that
> [comparison][comparison] hands off to. It assumes the shared vocabulary
> ([concepts][concepts]) and the cross-library synthesis ([comparison][comparison]) as
> given and cross-links rather than re-deriving them. It is a windowing-layer proposal —
> the [renderer][ui-layout] and the [event-loop substrate][async-io] that sit below and
> beside it are surveyed in their own trees and are treated here only at the seam. The
> niche is the same one [winit][winit] occupies in Rust: window lifecycle + event loop +
> input, no widgets, native handle handed to a GPU/software renderer.

> [!IMPORTANT]
> **One design principle dominates all the others, and the whole survey converges on it:
> own the pixels.** Every framework that _wrapped_ a lower layer — [wxWidgets][wxwidgets]
> (on GTK), [.NET MAUI][maui] (on native controls), [Avalonia][avalonia] /
> [Uno][uno] / [JUCE][juce] (on X11/XWayland, no native Wayland) — is _perpetually a
> step behind_ on the modern Wayland feature set: fractional scale, frame-callback vsync,
> `xdg_popup` grabs, inline pre-edit. The frameworks that own the window and merely hand a
> handle to a renderer ([winit][winit], [GTK 4][gtk4], [Chromium Ozone][ozone],
> [Slint][slint]) are the ones that can speak each protocol natively. Sparkles should be
> the latter.

**Last reviewed:** June 8, 2026

---

## 1. Master recommendation table

The headline calls, one row per architectural fork from [comparison][comparison]. Each is
unpacked in [§2](#_2-resolved-positions-on-each-fork); the roadmap that sequences them is
[§3](#_3-prioritized-roadmap).

| Decision                   | Recommendation                                                                                | Rationale (grounded in the deep-dives)                                                                                                                                                         | Trade-off                                                                                                        |
| -------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Own-vs-delegate**        | **Own the window**; draw nothing; hand a native handle to the renderer                        | Every wrapper ([wxWidgets][wxwidgets], [MAUI][maui], [JUCE][juce]) lags on Wayland; the owns-the-pixels set ([winit][winit], [GTK 4][gtk4], [Ozone][ozone]) speaks each protocol natively      | Must implement every backend by hand; no native-widget fidelity/accessibility for free                           |
| **Loop ownership**         | **Callback-first**, with a pollable-fd escape hatch on Linux                                  | Only the callback model survives where the OS owns the loop (macOS `CFRunLoop`, iOS, Web) — the reason [winit][winit] abandoned its `poll_events()` iterator                                   | More boilerplate than a `glfwPollEvents` loop; lifecycle (`resumed` vs surface-create) is subtle                 |
| **Native coordinate unit** | **Logical (device-independent) by default**, physical at the OS seam, both queryable          | The framework consensus ([Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia], [Slint][slint], [JUCE][juce]); [SDL3][sdl3]'s per-platform-native unit causes the macOS-vs-Win32 size mismatch      | Must thread scale through every geometry; never size the render target off logical size (size off pixel events)  |
| **Wayland decoration**     | **SSD-first via `xdg-decoration`, own-drawn CSD fallback** (no [libdecor][libdecor] hard dep) | SSD is "only a hint" ([concepts][csd]); GNOME never offers it, so a CSD path is mandatory ([Smithay][smithay]); own-drawn ([winit][winit]/[Qt 6][qt6]/[Ozone][ozone]) avoids the C dep         | Must draw and maintain a titlebar/frame; consistent look but extra work vs delegating to [libdecor][libdecor]    |
| **Threading**              | **Single UI/main thread** owns windows + events; renderer may move threads                    | AppKit _forces_ main-thread `NSWindow`/`NSApplication`; every framework standardizes on it because of macOS ([winit][winit] `MainThreadMarker`, [JUCE][juce], [Qt 6][qt6])                     | One thread is the windowing bottleneck; cross-thread work must marshal through a coalesced waker                 |
| **Input / IME ownership**  | **Own the pre-edit consumer**; xkbcommon on Linux; **TSF** on Win32                           | [GTK 4][gtk4] pushing IME above the windowing layer makes GDK incomplete standalone; _nobody_ uses TSF and every toolkit regrets IMM32 ([concepts][pec])                                       | TSF is far harder than IMM32; xkbcommon is a C dep; owning pre-edit is real work most toolkits skip              |
| **GPU handle handoff**     | **A typed `raw-window-handle`-style trait**, versioned independently                          | The reason the whole Rust stack interoperates ([winit][winit]); [JUCE][juce]'s type-erased `void*` and [sokol][sokol]'s `const void*` getters are the anti-pattern                             | A major version bump forces the renderer side to upgrade in lockstep (the rwh ecosystem pain)                    |
| **Popups / menus / grabs** | **Own `xdg_popup` / override-redirect grab** as a first-class abstraction                     | The biggest gap [winit][winit] admits; the layer that owns the loop is the right place ([concepts][orx]); in-canvas popups ([Uno][uno]/[Slint][slint]) lose compositor-enforced dismiss        | A popup abstraction can't be "place window at (x,y)" — must model anchor/gravity (Wayland) and grab on both      |
| **Frame pacing / vsync**   | **One frame-clock abstraction** folding each platform's native vsync source                   | No cross-platform vsync primitive ([concepts][fcv]); [GTK 4][gtk4]'s `GdkFrameClock` and [JUCE][juce]'s per-screen display-link are the models; sleep-based timers ([Avalonia][avalonia]) tear | Per-platform source plumbing; `CVDisplayLink` is deprecated, needs a `CADisplayLink` migration plan from day one |

---

## 2. Resolved positions on each fork

Each subsection states the position, the evidence, and the explicit cost. The forks are
the ones [comparison][comparison] enumerates; here they are decided.

### 2.1 Own-vs-delegate: own the window, draw nothing

**Position.** Sparkles is a _pure windowing substrate_ in the [winit][winit] mould: it
owns the OS window, the event loop, and input translation, and hands a native handle to a
renderer ([§2.7](#_2-7-gpu-handle-handoff-a-typed-raw-handle)). It wraps **no** native
widget set and draws **no** application content. The renderer (`wgpu`-style GPU layer,
software, or the Sparkles [ui-layout][ui-layout] tree) lives above the seam.

**Why.** This is the single clearest lesson of the survey, and the four wrapper subjects
all teach it the hard way:

- [wxWidgets][wxwidgets] wraps GTK on Linux and is, in its own deep-dive's words,
  "perpetually a step behind on Wayland," even hacking around its own dependency
  (`src/gtk/wayland.cpp` opens a _second_ `wl_display` to reach past GDK for
  `pointer-warp-v1`).
- [.NET MAUI][maui] wraps native controls and inherits every native quirk; its
  `WindowHandler.Standard.cs` throws `NotImplementedException`, so a non-mobile,
  non-Windows build has _no window and no loop at all_.
- [JUCE][juce] and [Avalonia][avalonia] own their pixels but punted Wayland; both run only
  through XWayland, inheriting integer-only scale, legacy clipboard, and no
  frame-callback vsync. Avalonia's [own verdict][avalonia] is blunt: "Don't punt on
  Wayland … `ManagedPopupPositioner` is a dead end."

The owns-the-pixels set is exactly the set that keeps up: [winit][winit], [GTK 4][gtk4],
and [Chromium Ozone][ozone] each bind Wayland protocols directly and so get fractional
scale, `xdg_popup`, frame callbacks, and `text-input-v3` natively.

> [!WARNING]
> **The cost is real and must be accepted up front: owning the window means hand-writing
> every backend** — Wayland, X11, Win32, AppKit — with no native-widget accessibility or
> theming for free. [MAUI][maui]'s native fidelity and [wxWidgets][wxwidgets]' native
> look are genuine advantages Sparkles forgoes. The bet (validated by [winit][winit] +
> the entire Rust GUI ecosystem riding on it) is that control over the modern feature set
> is worth more than free widgets for a renderer-backed toolkit.

### 2.2 Loop ownership: callback-first, with a pollable fd on Linux

**Position.** Sparkles **owns the native loop and calls the application back** through a
handler interface (the [winit][winit] `ApplicationHandler` model), _not_ an
app-owned `pollEvents()` pump as the primary API. On Linux, expose the loop as a
**pollable fd** so an external async runtime can drive it; offer a `pump`-style escape
hatch elsewhere for embedders.

**Why.** The [loop-ownership fork][rvc] is forced by the platforms that own the loop
themselves: macOS `CFRunLoop`, iOS `UIApplicationMain`, and the Web animation-frame loop
_cannot_ be expressed as an iterator the app pulls from. [winit][winit] abandoned exactly
that iterator for callbacks for this reason (quoted verbatim in its deep-dive), and
[SDL3][sdl3] retrofitted an opt-in `SDL_MAIN_USE_CALLBACKS` inversion to run on those same
platforms. Designing callback-first from the start avoids SDL3's two-model split.

The Linux integration story should copy [winit][winit]'s best idea: the loop _is_ an fd
multiplexer (winit uses `calloop`; its `EventLoop` implements `AsFd` so the whole
windowing loop can be polled inside a larger reactor). This is the clean answer to "how
does the windowing loop coexist with an [async-io][async-io] runtime that also wants to
own the blocking wait" — make the windowing loop a source the reactor can poll, rather
than forcing one onto its own thread. [GLFW][glfw] and [SDL3][sdl3] have **no portable
external-fd injection**, and that is a recurring pain the survey records.

The macOS reality to plan for: there is no Sparkles-owned loop on macOS at all. Like
[winit][winit], hang observers off `CFRunLoop` (`AfterWaiting` → new-events,
`BeforeWaiting` → about-to-wait) and override `NSApplication`'s `sendEvent:` to route
events through Sparkles state.

**Trade-off.** Callbacks are more boilerplate than a three-line poll loop, and the
lifecycle is subtle — winit re-cut `resumed` vs `can_create_surfaces` _twice_ because
conflating "app resumed" with "you may now make a surface" was wrong on Android. Nail
that vocabulary before 1.0 ([§3](#_3-prioritized-roadmap)) rather than re-cutting it across
point releases (winit's own stated regret).

### 2.3 Native coordinate unit: logical by default

**Position.** The public API speaks **logical (device-independent) coordinates** by
default, with **physical pixels exposed at the OS seam and explicitly queryable**. The
[scale factor][scale-factor] bridges them; a `*SizeChanged`/pixel-size event always fires
with the physical surface size for sizing the render target.

**Why.** This is the framework consensus — [Qt 6][qt6], [GTK 4][gtk4], [Avalonia][avalonia],
[JUCE][juce], [Slint][slint], and [MAUI][maui] all default to logical units ([concepts
table][lpc]) — because application layout code is overwhelmingly resolution-independent.
[winit][winit] is the principled dissenter (physical-native, app converts via
`scale_factor`), and its own verdict concedes the physical default "surprises developers
coming from logical-unit toolkits." For a renderer-backed _framework_ (as opposed to a
minimal substrate), logical-default is the lower-friction choice.

The cautionary tale is [SDL3][sdl3]'s deliberate per-platform-native unit: the _same_
default window reports `1920×1080` from `SDL_GetWindowSize` on macOS but `3840×2160` on
Windows for one 4K/200% display ([concepts][lpc]). That portability hazard is exactly what
a single logical default avoids.

> [!IMPORTANT]
> The rule the survey re-learns constantly ([concepts][lpc]): **never size the render
> target off the logical window size** — size it off the physical/framebuffer size or the
> pixel-size-changed event, or you render blurry. Borrow [winit][winit]'s
> `surface_size_writer` idea for the [created-at-wrong-scale][scale-factor] transient: let
> the scale-changed callback rewrite the resulting physical size in place.

**Trade-off.** Logical-default means scale must be threaded through every geometry
operation and the physical/logical boundary must be unambiguous in the API (the source of
real bugs when blurred). [GLFW][glfw]'s explicit split — window-size vs framebuffer-size as
_two distinct queries_ — is the disambiguation discipline to copy.

### 2.4 Wayland decoration: SSD-first, own-drawn CSD fallback

**Position.** Request **server-side decorations via `zxdg_decoration_manager_v1`** and
honour the compositor's reply; when SSD is unavailable, **draw the frame yourself**. Do
**not** take a hard dependency on [libdecor][libdecor] — treat it (if at all) as an
optional backend, not the load-bearing path.

**Why.** The decoration handshake is a [negotiation, not a boolean][csd]: per the
`xdg-decoration` protocol, SSD "is just a hint and there is no reliable way of disabling
all decorations" (quoted from libdecor's own source in [concepts][csd]). GNOME/Mutter
advertises **no** `zxdg_decoration_manager_v1` at all, so _every serious toolkit carries a
CSD path_ ([Smithay][smithay]'s verdict: "always have a CSD path … the lesson GNOME forced
on the whole ecosystem"). The fork is _who draws the CSD_:

- [winit][winit], [Qt 6][qt6], [Ozone][ozone], and [GTK 4][gtk4] all **draw their own**
  (winit via `sctk-adwaita`, no C dep).
- [SDL3][sdl3] and [GLFW][glfw] **delegate to [libdecor][libdecor]**, paying a runtime C
  dependency and its `dlopen` plugin model ([Smithay/libdecor][smithay] documents the
  gtk-HIGH / cairo-MEDIUM priority resolution).

Own-drawn is the better default for a renderer-backed toolkit: it already has a drawing
pipeline, so a titlebar is cheap, and it avoids libdecor's plugin/symbol-conflict surface
(the [libdecor][smithay] gtk plugin refuses to load if `png_free`/`gdk_get_use_xshm`
clash). The [GTK 4][gtk4] outlier is the mistake to _not_ copy: GDK binds **neither**
libdecor **nor** `zxdg-decoration-v1`, so on wlroots it _always_ falls back to its own CSD
even where SSD was available — request SSD properly so KDE/wlroots users get native frames.

**Trade-off.** Drawing and maintaining a titlebar/frame (buttons, drag regions, resize
edges, shadow) is ongoing work, and a hand-drawn frame will never perfectly match every
desktop's native chrome the way true SSD does.

### 2.5 Threading: single UI thread, renderer may move

**Position.** Windows are created on, and all events are delivered to, **one UI/main
thread**. The renderer may run on another thread (it holds the native handle). Cross-thread
work marshals back through a **single coalesced waker** (the [winit][winit] `EventLoopProxy`
model). Window objects are non-`Send`/non-`Sync` analogues so they cannot escape the loop
thread.

**Why.** macOS AppKit _mandates_ `NSWindow`/`NSApplication` on the main thread, and this
single constraint is why **every** surveyed framework standardizes on a main-thread
windowing model: [winit][winit] enforces it with a `MainThreadMarker` that panics off-main,
[JUCE][juce] with `JUCE_ASSERT_MESSAGE_MANAGER_IS_LOCKED`, [Qt 6][qt6] and
[GTK 4][gtk4] likewise. Linux and Win32 _relax_ it (winit exposes `with_any_thread`), but
designing for the strictest platform keeps the model uniform.

The renderer is the part that genuinely benefits from off-thread execution, and the
owns-the-pixels design already supports it: hand the [raw handle][rwh]
([§2.7](#_2-7-gpu-handle-handoff-a-typed-raw-handle)) to the render thread. [winit][winit]
makes the handle `Send` precisely for this; [Chromium Ozone][ozone] renders in a separate
sandboxed GPU process entirely.

**Trade-off.** A single UI thread is a throughput bottleneck for input/event handling, and
all cross-thread communication pays the coalesced-wakeup hop. Note the live caveat to
inherit: winit's Win32 `EventLoopProxy::wake_up` "may be ignored under high contention"
(#3687) — a cross-thread waker needs a contention-safe implementation, not a naive
`PostMessage`.

### 2.6 Input / IME ownership: own the pre-edit consumer

**Position.** Sparkles **owns input translation end to end**: xkbcommon for the
scancode→keysym state machine on Linux, and a **first-class IME pre-edit consumer on every
platform** — including the harder-but-correct choices: `zwp_text_input_v3` on Wayland,
XIM on X11, `NSTextInputClient` on macOS, and **TSF (not legacy IMM32) on Win32**.

**Why.** Two findings dominate the [IME concept page][pec], and both argue for owning it:

1. **Pushing IME above the windowing layer makes that layer incomplete standalone.**
   [GTK 4][gtk4] binds _no_ `zwp_text_input_v3` in GDK — IME lives entirely in
   `gtk/gtkimcontextwayland.c` _above_ GDK — so GDK alone "has no text input." A reusable
   windowing substrate must own the pre-edit consumer, exactly the gap [Smithay][smithay]
   flags ("IME is table-stakes; don't make every app reinvent pre-edit handling").

2. **The universal IMM32-over-TSF regret on Windows.** _Not one_ surveyed toolkit uses the
   modern [TSF][pec] — [SDL3][sdl3], [winit][winit], [Qt 6][qt6], [GTK 4][gtk4],
   [JUCE][juce], and [Avalonia][avalonia] all fall back to legacy IMM32. Their verdicts
   converge ([Avalonia][avalonia]: "Prefer TSF over IMM32 … if advanced IME/a11y matter";
   [SDL3][sdl3]: "Avoid: legacy IMM32 instead of TSF"). A _new_ framework has the rare
   chance to do TSF correctly from the start and surpass the whole field.

Use the [scancode/keysym/virtual-key][skv] three-way split that [winit][winit] models
(physical key + logical key + commit text), and delegate to **xkbcommon** rather than a
hand-rolled table — the toolkits that ship their own ([Avalonia][avalonia]'s
`X11KeyTransform`, [JUCE][juce]'s `XLookupString`-only path) inherit layout bugs. Keep the
[raw/relative pointer][rap] motion path as a _separate_ event source from accelerated
motion, and bind `pointer-constraints`/`relative-pointer` so games work — the gap
[GTK 4][gtk4] deliberately leaves (it binds none, so it "cannot do FPS-style raw input at
all"), which is fine for a document toolkit but wrong for a general one.

**Trade-off.** TSF is materially harder to implement than IMM32 (it is why everyone skipped
it), xkbcommon is a C dependency, and owning pre-edit/candidate-window positioning on four
platforms is significant, fiddly work. This is the recommendation with the highest
effort-to-table-stakes ratio — but skipping it is precisely the corner the survey says a
real backend cannot cut.

### 2.7 GPU handle handoff: a typed raw handle

**Position.** Expose a **typed, `raw-window-handle`-style trait/struct** (per-platform
variants: `wl_surface`+`wl_display`, X11 `Window`+display, `HWND`, `NSView`/`NSWindow`)
versioned as its own contract, plus a `RawDisplayHandle` analogue. This is the _sanctioned_
seam between windowing and rendering.

**Why.** [raw-window-handle][rwh] is "the reason the entire Rust graphics stack
standardizes on it" ([winit][winit]) — one handle that `wgpu`, `glutin`, and `softbuffer`
all consume, decoupling the windowing and GPU ecosystems so they version independently. The
anti-patterns are explicit in the survey: [JUCE][juce]'s `getNativeHandle()` returns a
type-erased `void*` with the doc warning "there's no guarantees what you'll get back" (its
verdict: "prefer a typed, `raw-window-handle`-style accessor"), and [sokol][sokol] tunnels
`const void*` getters (and Objective-C `id`s via `__bridge`). Even [Smithay SCTK][smithay]
_not_ implementing the trait — forcing every consumer to hand-build the handle from
`display_ptr()`/`surface.id()` — is recorded as a friction point.

**Trade-off.** The one genuine cost, learned from the rwh ecosystem: a **major version bump
forces the renderer side to upgrade in lockstep** (winit's repeated `rwh 0.4 → 0.5 → 0.6`
churn forced the whole `winit`/`wgpu`/`glutin` stack to move together). Mitigate by getting
the handle vocabulary right early and bumping its major version rarely.

### 2.8 Popups, menus & grabs: own them (the gap to close)

**Position.** Own a **first-class popup/menu/tooltip abstraction with grab semantics** —
`xdg_popup` + `xdg_positioner` (anchor/gravity/constraint) with an explicit compositor grab
on Wayland, and `override_redirect` + client-side grab on X11. Do **not** leave this to the
application.

**Why.** This is the most-cited _gap_ in the survey. [winit][winit] has "no first-class
popup/menu/tooltip abstraction" — only X11 `_NET_WM_WINDOW_TYPE` hints, no real grab — and
its own verdict says so: "a windowing layer that owns the loop is the right place to own
`xdg_popup`/override-redirect grabs." The two display servers solve transient surfaces with
[fundamentally different mechanisms][orx] (X11 absolute-positioned override-redirect with a
client grab; Wayland parent-relative `xdg_popup` with a _compositor_-owned grab), so the
abstraction **cannot** be a simple "place this window at (x, y)" call — that maps onto
neither model. The frameworks that dodge the fork by rendering popups **in-canvas**
([Uno][uno], [Slint][slint]'s winit backend) get cross-platform simplicity but **lose
compositor-enforced click-outside dismiss** — acceptable for a self-contained app, wrong for
a reusable layer that wants real native menus.

**Trade-off.** A grab-aware popup abstraction is more complex than positioned child windows
and must model Wayland's anchor/gravity/slide positioner and the grab on both servers.
[Avalonia][avalonia]'s `ManagedPopupPositioner` (it does its own flip/slide math over
override-redirect windows) shows both the work involved and the dead-end of doing it without
compositor grabs.

### 2.9 Frame pacing & vsync: one frame-clock, native sources folded in

**Position.** Provide **one frame-clock abstraction** that folds in each platform's native
vsync source: `wl_surface.frame` callbacks on Wayland, `CADisplayLink` on macOS (with
`CVDisplayLink` only as the legacy fallback), DXGI `WaitForVBlank` / DWM timing on Win32,
and a redraw cadence on X11. Throttle redraws to vsync and to _zero_ when occluded.

**Why.** There is [no single cross-platform vsync primitive][fcv]; each platform has its
own source and a toolkit must funnel them into one scheduler. The models to copy:

- [GTK 4][gtk4]'s per-surface `GdkFrameClock` with explicit UPDATE/LAYOUT/PAINT phases that
  **freezes until the frame callback fires** so the client "never out-runs the compositor"
  (its verdict's top "steal").
- [JUCE][juce]'s per-screen `CVDisplayLink` (macOS) and dedicated highest-priority
  `WaitForVBlank` thread (Windows), **decoupled from the message loop**.
- [Qt 6][qt6] running a _dedicated second event thread_ for frame callbacks so they are not
  starved by the main queue.

The anti-pattern is [Avalonia][avalonia]'s **sleep-based** fixed-60 Hz render timer (no
vsync), which "tears/judders on high-refresh displays" — its verdict: "Don't ship a
sleep-based render timer. Wire vsync … per platform from the start."

> [!WARNING]
> **Plan the `CVDisplayLink` → `CADisplayLink` migration from day one.** `CVDisplayLink`
> is deprecated since macOS 15, noted in-source by both [GTK 4][gtk4] and [Qt 6][qt6], and
> [winit][winit] has _no_ macOS frame pacing at all (an open question in its deep-dive).
> Prefer `CADisplayLink` and keep `CVDisplayLink` only as the older-OS fallback.

**Trade-off.** Per-platform vsync plumbing is real work, and the macOS deprecation means
carrying two code paths there. The payoff — smooth, occlusion-aware, telemetry-bearing
pacing — is something [GLFW][glfw] (swap-interval only) and the X11 paths generally never
get.

### 2.10 The Win32 modal resize loop and the no-buffer-no-window rule

Two cross-cutting hazards every backend must handle, decided here so they are not
rediscovered per platform:

- **[The Win32 modal resize/move loop][modal].** When the user grabs the titlebar/resize
  edge, Windows enters its own nested modal loop inside `DefWindowProc` and **freezes
  redraws**. The survey-wide fix is identical: on `WM_ENTERSIZEMOVE`, install a `SetTimer`
  and drive a frame from each `WM_TIMER` ([SDL3][sdl3], [GTK 4][gtk4] pumping
  `g_main_context_iteration`, [sokol][sokol]). Adopt it, plus the finer trick
  ([winit][winit], [sokol][sokol]) of posting a dummy `WM_MOUSEMOVE` on `WM_NCLBUTTONDOWN`
  to cancel the ~500 ms first-click pause. Accept that the loop is mitigated, not
  eliminated.
- **[The Wayland no-buffer-no-window rule][nbnw].** "Create window" is **not synchronous**
  on Wayland — a surface is invisible until a buffer is committed _and_ the initial
  `xdg_surface.configure` has been acked. **Model the window lifecycle as explicit state
  from the start** ([SDL3][sdl3]'s verdict, learned from its KDE-bug-448856 tail), rather
  than blocking in the constructor on the configure handshake the way [winit][winit] does
  (`while !is_configured() { blocking_dispatch() }`) and then bolting on workarounds. Draw
  the first frame _inside_ the configure handler ([Smithay][smithay]). The corollary
  ([concepts][nbnw]): clients cannot set their own toplevel position on Wayland, so
  `setPosition` on a toplevel is a documented no-op, not a silent failure.

---

## 3. Prioritized roadmap

Sequenced so each phase is independently useful and each builds on the last. The
ordering mirrors the survey's recurring advice: get the loop and a window on screen first,
nail the coordinate/lifecycle vocabulary _before_ committing to an API, and treat IME,
popups, and frame pacing as the load-bearing "do it right or don't bother" tier.

| Phase | Deliverable                                                                                                                                                         | Forks resolved                                     | Why here                                                                                                                                                                                      |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0** | Callback loop + one window on screen; Wayland + Win32 backends; the [raw-handle][rwh] trait; logical-coords seam                                                    | [§2.1][s21], [§2.2][s22], [§2.3][s23], [§2.7][s27] | The substrate everything rides on; pick the two most-divergent backends (async Wayland, message-pump Win32) to force the abstraction honest early                                             |
| **1** | X11 + AppKit backends; `CFRunLoop`-observer integration; the no-buffer-no-window + modal-resize hazards handled                                                     | [§2.2][s22], [§2.10][s210]                         | Completes the four desktop targets; macOS forces the [main-thread model][s25] and proves the callback design                                                                                  |
| **2** | Keyboard via **xkbcommon**, raw/relative pointer + constraints, high-res scroll; [scale factor][scale-factor] + fractional scaling; the **frame-clock** abstraction | [§2.3][s23], [§2.6][s26] (input), [§2.9][s29]      | Input + correct DPI + vsync are what make it usable for a real renderer; nail the coordinate vocabulary here, pre-1.0                                                                         |
| **3** | **SSD-first + own-drawn CSD** on Wayland; the **popup/grab** abstraction; clipboard + DnD                                                                           | [§2.4][s24], [§2.8][s28]                           | The hard Wayland-specific pieces; popups need the loop + window lifecycle from phases 0–1 to exist first                                                                                      |
| **4** | **IME pre-edit** on all four platforms (**TSF** on Win32, `text_input_v3`, XIM, `NSTextInputClient`); a11y hooks                                                    | [§2.6][s26] (IME)                                  | Table-stakes but highest-effort; deliberately last among desktop work so the rest ships without waiting on TSF                                                                                |
| **5** | **Android / iOS** backends (lifecycle: surface create/destroy split from resume/suspend); Web/wasm if warranted                                                     | [§2.2][s22] (lifecycle)                            | The deferred targets; the callback loop ([§2.1][s21]) was chosen _because_ these platforms own the loop — winit's `can_create_surfaces`-vs-`resumed` split is the lifecycle lesson to bake in |

> [!IMPORTANT]
> **Get the vocabulary right before 1.0.** [winit][winit]'s clearest stated regret is the
> stream of breaking renames (`inner_size → surface_size`, `user_event → proxy_wake_up`,
> the `resumed`/`can_create_surfaces` re-cut _twice_). Phases 0–2 are where the
> coordinate-unit, lifecycle, and handle vocabulary must be settled — _not_ across point
> releases afterward.

---

## 4. What to steal, in one list

The concrete patterns worth lifting, each with its source named:

- **Callback `ApplicationHandler` loop** — [winit][winit] (the only model that survives Web/iOS/macOS).
- **Loop-as-pollable-fd for runtime integration** — [winit][winit] (`calloop`, `AsFd`); the answer to coexisting with an [async-io][async-io] reactor.
- **Typed `raw-window-handle` GPU seam** — [winit][winit] (vs [JUCE][juce]/[sokol][sokol]'s `void*`).
- **`surface_size_writer` for the created-at-wrong-scale transient** — [winit][winit].
- **Per-surface frame clock with freeze-until-frame-callback** — [GTK 4][gtk4]; **display-link/vblank decoupled from the loop** — [JUCE][juce].
- **`GSource`-style "windowing is one source in a shared loop," inverted on macOS** — [GTK 4][gtk4].
- **Hybrid simple-pump-plus-callback option** and **honest separate pixel-density/content-scale/display-scale** — [SDL3][sdl3].
- **Capability probing via `TryGetFeature<T>` over an ever-widening interface**, and **the two-layer priority `Dispatcher` over native loops** — [Avalonia][avalonia].
- **Destruction-ordering encoded in the type system (children-first)** and the **client-side key-repeat timer** — [Smithay/libdecor][smithay].
- **Explicit per-backend detection (`IsWayland`/`IsX11`) so quirks are branched, not papered over**, and **disciplined native-loop nesting** — [wxWidgets][wxwidgets].
- **`PlatformView`/native-handle escape hatch that admits the abstraction's limits** — [MAUI][maui].

And the mistakes to avoid: **wrapping a higher toolkit** ([wxWidgets][wxwidgets]),
**punting Wayland to XWayland** ([JUCE][juce]/[Avalonia][avalonia]/[Uno][uno]),
**legacy IMM32 over TSF** (universal), **own-CSD-only, never requesting SSD**
([GTK 4][gtk4]), **sleep-based render timers** ([Avalonia][avalonia]),
**type-erased `void*` handles** ([JUCE][juce]/[sokol][sokol]), **leaving popups/grabs to
the app** ([winit][winit]), and **silent per-platform no-ops instead of an explicit
"unsupported" contract** ([MAUI][maui]).

---

## Sources

- Shared vocabulary and the design forks this document resolves: [concepts][concepts], [comparison][comparison].
- Per-subject deep-dives cited for each position: [winit][winit], [SDL3][sdl3], [GLFW][glfw],
  [sokol][sokol], [Qt 6][qt6], [GTK 4][gtk4], [Flutter Engine][flutter], [Chromium Ozone][ozone],
  [Avalonia][avalonia], [.NET MAUI][maui], [Uno][uno], [Slint][slint], [wxWidgets][wxwidgets],
  [JUCE][juce], [Smithay/libdecor][smithay] — each carries its own primary-source citations.
- Cross-tree siblings at the seam: the [renderer/UI-layout catalog][ui-layout]; the
  [async-I/O survey][async-io] (loop ownership, readiness-vs-completion); the survey
  [index][index].

<!-- References -->

<!-- Tree siblings -->

[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Deep-dives -->

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

<!-- Concept anchors -->

[csd]: ./concepts.md#csd-vs-ssd
[skv]: ./concepts.md#scancode-keysym-virtualkey
[lpc]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pec]: ./concepts.md#pre-edit-composition
[orx]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[modal]: ./concepts.md#win32-modal-resize-loop
[rap]: ./concepts.md#raw-vs-accelerated-pointer
[nbnw]: ./concepts.md#no-buffer-no-window
[fcv]: ./concepts.md#frame-callback-vsync
[rvc]: ./concepts.md#readiness-vs-completion-windowing

<!-- In-page section anchors -->

[s21]: #_2-1-own-vs-delegate-own-the-window-draw-nothing
[s22]: #_2-2-loop-ownership-callback-first-with-a-pollable-fd-on-linux
[s23]: #_2-3-native-coordinate-unit-logical-by-default
[s24]: #_2-4-wayland-decoration-ssd-first-own-drawn-csd-fallback
[s25]: #_2-5-threading-single-ui-thread-renderer-may-move
[s26]: #_2-6-input-ime-ownership-own-the-pre-edit-consumer
[s27]: #_2-7-gpu-handle-handoff-a-typed-raw-handle
[s28]: #_2-8-popups-menus-grabs-own-them-the-gap-to-close
[s29]: #_2-9-frame-pacing-vsync-one-frame-clock-native-sources-folded-in
[s210]: #_2-10-the-win32-modal-resize-loop-and-the-no-buffer-no-window-rule

<!-- Cross-tree -->

[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
[rwh]: https://github.com/rust-windowing/raw-window-handle
[libdecor]: https://gitlab.freedesktop.org/libdecor/libdecor
