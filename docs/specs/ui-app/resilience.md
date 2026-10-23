---
status: draft
owner: sparkles:ui-app
reviewed: 2026-10-23
---

# `sparkles:ui-app` — Resilience to external and user-initiated change

## Abstract

A Sparkles application runs for as long as its user wants it to, while the
world around it changes: windows are resized and rotated, moved to a monitor
with another density or refresh rate, hidden, minimized and uncovered; on a
phone the surface is destroyed while the process lives on; a GPU driver
resets; memory runs short; the user changes the font, the theme or the
present mode from a settings page. This page states what the application
host, [`sparkles:ui-app`](./feature-requirements.md), guarantees through all
of that — that the application never restarts, never loses state, never
leaks, keeps responding, and draws, after each change, what a fresh start in
the new conditions would draw — and the scenarios that check it. The
scenarios are executable: each names the test that runs it, and a test reads
this page to keep the two in step.

## Introduction

The host sits between an application (its `setup`, `handle`, `present` and
`shutdown`) and the machinery that changes under it: the window system
([`sparkles:wsi`](../window-system-integration/SPEC.md)), the GPU canvas
([`sparkles:ui-vulkan`](../ui-vulkan/SPEC.md), or raylib) and the platform's
process lifecycle. Each of those already specifies its own part. The window
system reports a lost surface before its successor
([`ED4`](../window-system-integration/SPEC.md#45-event-delivery)); the canvas
keeps its device objects across surfaces (`UVK26`) and rebuilds after a lost
device (`UVK33`). What none of them can state is the property an application
author relies on: _whatever happened, my state is intact and my next frame is
right_. That property spans all three layers, and this page owns it.

It owns it as **host obligations and cross-layer scenarios**, not as a second
copy of the layers' contracts. Where a requirement depends on a layer's
guarantee, it cites that guarantee by ID; where a layer is missing one, the
requirement says which library owes it. The governing idea is one oracle,
used throughout:

> **Cold-start equivalence.** After any change, once the host has settled,
> the application's next frame equals the frame a fresh process, started
> directly into the new conditions with the same application state, would
> draw.

"Equals" is byte equality of the operation stream on the recording host and
the native arm's replay, and the canvas's readback tolerance
([testing](../ui-vulkan/testing.md)) on a GPU. The oracle is independent of
the code under test: the expected frame comes from a separate run that never
saw the change.

Reading map: §1 defines the vocabulary (scopes, host states) the rest uses.
§2–§8 are the requirements, one section per concern. §9 says how the
scenarios run, §10 is the scenario catalog, and §11 the ledger of what is
verified.

## 1. Model

### Scopes

Every resource the host or an application creates has exactly one **scope**,
the lifetime it is tied to:

| Scope       | Begins                                   | Ends                                   | Examples                                                                                                |
| ----------- | ---------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **process** | `run` starts                             | `run` returns                          | application state, settings, ptys and sessions, font faces, the image registry's pixels, the event loop |
| **window**  | the WSI window is created                | the window is destroyed                | `WindowId`, the window's input state, its title                                                         |
| **device**  | the GPU device is created                | device loss, a release policy, or exit | pipelines, glyph atlases on the GPU, uploaded images, the memory sub-allocator (`VKM*`)                 |
| **surface** | a native surface is attached to a window | the surface is destroyed or replaced   | `VkSurfaceKHR`, the swapchain, its image views, per-target framebuffers (`UVK26`)                       |
| **frame**   | `beginFrameState`                        | the frame is presented or abandoned    | the frame arena, the operation list, transient uploads                                                  |

A device- or surface-scoped object is a **cache**: it must be derivable at
any time from process-scoped state. The host is the only code that ends the
window, device and surface scopes.

### Host states

The host is in exactly one of these states. They are observable through the
events an application receives and through what the host presents.

| State        | Meaning                                                                   | Presents frames | `present` called      |
| ------------ | ------------------------------------------------------------------------- | --------------- | --------------------- |
| `starting`   | `setup` has run; no surface yet                                           | no              | no                    |
| `visible`    | a surface exists and some of it can be seen                               | yes             | on change or request  |
| `hidden`     | a surface exists, none of it can be seen (occluded, minimized, other tab) | no              | no (timers still run) |
| `suspended`  | the window exists, its surface does not (Android between activities)      | no              | no                    |
| `recovering` | the device or surface is being rebuilt after a loss                       | no              | no                    |
| `stopping`   | quit or close accepted; `shutdown` pending                                | no              | no                    |

Transitions: `starting → visible` on the first configured surface;
`visible ⇄ hidden` on occlusion; `visible|hidden → suspended` on surface
loss with the window alive; `suspended → visible` on a new surface;
`visible → recovering → visible` on device or surface loss; any state
`→ stopping` on quit, accepted close or a fatal failure (`RES27`). No other
transition exists; in particular, nothing leads back to `starting`.

## 2. The application never restarts (`RES1`–`RES3`)

**RES1: One setup, one shutdown.** For each `run`, the host **must** call the
application's `setup` exactly once, before the first `handle` or `present`,
and `shutdown` exactly once, after the last of them — on quit, on an accepted
close, on a fatal host failure and when `handle` or `present` throws. No
change in §3–§8 may call either again. _Detect:_ the probe application
(§9) counts both calls in every scenario.

**RES2: Process state survives every change.** No change in §3–§8 may
reset, reallocate or reorder process-scoped application state. The host
never copies, moves or re-creates the application object. _Detect:_ the
probe's state token (a value it changed in `handle`) and its object address
are unchanged after the change.

**RES3: Settled frames are cold-start equivalent.** After a change in §4–§8,
once the host is `visible` and has drawn one frame, that frame **must** equal
the frame a fresh `run` would draw with the same application state, started
in the post-change conditions (size, scale, refresh rate, settings, device).
A change that cannot meet this for a stated reason (for example, a font that
failed to load) falls under `RES52` instead. _Detect:_ the cold-start
differential (§9.2).

## 3. Resource ownership (`RES4`–`RES9`)

**RES4: Scoped release.** When a scope (§1) ends, the host **must** release
every resource of that scope, and **must not** release a resource of a scope
that has not ended. In particular, losing a surface releases surface-scoped
objects only (`UVK26`), and losing a device releases device- and
surface-scoped objects only. _Detect:_ the ledger counts creations and
destructions per scope; at each scope end, that scope's count returns to the
value it had when the scope began, and no other scope's count changes.

**RES5: Teardown order.** On `stopping`, the host **must** end scopes in the
order frame, surface, device, window, process, and call `shutdown` after the
last frame and before the device is destroyed, so that an application may
release its own device-scoped objects in `shutdown`. GPU objects are
destroyed only after the frames that read them completed (`UVK31`).

**RES6: Caches are derivable.** An application **must not** be required to
re-supply anything after a device or surface scope ends: images re-upload
from the registry (`UVK23`), glyphs re-rasterize from the faces, pipelines
rebuild from their SPIR-V. Device memory holds no data that exists nowhere
else.

**RES7: Bounded growth under churn.** For each resource kind an application
can create and remove at run time — windows, panes, images in a registry,
cached font sizes — a sequence of _N_ create/remove cycles **must** leave
the host's and the canvas's live counts of that kind at their starting value
plus a bound that does not grow with _N_. In particular, an image removed
from its registry **must** be evicted from the canvas's device cache within a
bounded number of frames. _Detect:_ churn scenarios with _N_ = 1000 compare
the counts after 10 and after 1000 cycles.

**RES8: Idempotent teardown.** Destroying an already-destroyed object, and a
second notification of the same loss, **must** be no-ops. (The layers' own
`destroy` functions already are; this requires the host not to depend on
anything more.)

**RES9: Borrowed registries are restored.** A component that binds its own
resource registry on a shared host object (an image registry on the canvas)
for part of a frame **must** restore the previous binding before control
returns to its caller. _Detect:_ an image the application draws after an
embedded component draws its own pixels.

## 4. Lifecycle (`RES10`–`RES19`)

**RES10: Lifecycle is reported.** The host **must** deliver to `handle` an
event for each state change of §1 an application can act on: visible,
hidden, suspended, resumed and leaving (`RES13`), carrying no data beyond
the new state. Today's `sparkles:input` vocabulary has no such event; adding
it is part of this requirement (owner: `sparkles:input`).

**RES11: Hidden draws nothing.** While `hidden`, the host **must not**
present frames or call `present`, **must** keep delivering events, and
**must** keep honouring timed wakes (`HST16`), at a period no shorter than
the one the host declares for hidden windows. The window system's occlusion
report is a prerequisite (owner: `sparkles:wsi`, `F14`); until a backend
provides it, that backend's windows are never `hidden`.

**RES12: Suspension.** On a surface loss with the window alive, the host
**must**, before acknowledging the loss to the window system: release every
surface-scoped object (swapchain and views included), stop presenting, and
enter `suspended`. It **must** keep the device unless a release policy says
otherwise (`RES17`). The acknowledgement **must** happen within the window
system's bound (§9.5 of its spec: two seconds on Android).

**RES13: Leaving.** When the platform signals that the process may be killed
without further notice (Android `onPause`/`onStop`; a desktop session
ending), the host **must** deliver a _leaving_ event before returning from
the platform callback, so the application can persist (for example
[`TSS14`](../terminal/sessions.md)). The host persists nothing itself.

**RES14: Resumption.** On a new surface after `suspended`, the host **must**
rebuild surface-scoped objects, mark the next frame as one that must draw
(`HST6`), and present it before any frame of the old surface could be shown.
It **must not** re-run `setup`. With unchanged state and conditions, the
first frame equals the last frame presented before suspension.

**RES15: Recreation is not a restart.** Destroying and recreating the
platform's activity, or its equivalent, while the process lives **must** be
handled as suspension followed by resumption. A host arm that cannot
(today: the raylib arm on Android, which exits the process) **must**
declare so, and its application **must** then persist on `RES13`.

**RES16: Close.** A window's close request **must** reach `handle` and be
vetoable; an accepted close or a quit moves to `stopping` within one loop
iteration, without waiting for a pending timed wake.

**RES17: Memory pressure.** On a moderate pressure report the host **must**
release the canvas's caches (`UVK32`); on a critical report while not
`visible`, it **may** release the device (window-system spec §10.1). In both
cases it **must** deliver the report to `handle`, so the application can
drop its own caches. The frame after recovery is cold-start equivalent
(`RES3`).

**RES18: Events during suspension.** Events, settings changes and timed
wakes that arrive while `hidden` or `suspended` **must** be applied to
application state as they arrive, and be visible in the first frame
afterwards; none is dropped or deferred past that frame.

**RES19: Background work continues.** Work an application runs outside the
frame (daemons, ptys, network) **must** keep running in `hidden` and
`suspended` unless the platform stops the process.

## 5. Context loss (`RES20`–`RES27`)

**RES20: Device loss is transparent.** On a lost device at any frame, the
host **must** enter `recovering`, end the device scope (`RES4`), create a new
device and canvas, and draw a frame equal to the one that was lost
(`UVK33`). The application sees no event and no `setup` call. The frame
after recovery is drawn with the must-draw flag set.

**RES21: Out-of-date targets.** An out-of-date or suboptimal swapchain
**must** be rebuilt without ending the device scope
([`INT2`](../window-system-integration/feature-requirements.md)).

**RES22: Surface loss.** When presenting reports the surface itself lost, the
host **must** end the surface scope, create a new surface from the window's
current native handles, and continue; if the window has no native surface at
that moment, it **must** enter `suspended` (`RES12`). A lost surface never
ends the run.

**RES23: Loss during a change.** A loss that occurs while a previous loss,
a resize or a settings change is being handled **must** be handled after it
completes, with the same outcome as if it had occurred alone afterwards.

**RES24: Exhausted device memory.** An exhausted device **must** abandon the
frame and release caches (`UVK34`); the next frame draws.

**RES25: Losses during teardown.** A loss during `stopping` **must not**
prevent `shutdown` from running or the remaining scopes from ending.

**RES26: The raylib arm's context.** The raylib arm **must** state what it
does on a lost GL context; today it does not detect one. Until it does, a
lost context on that arm is out of this page's guarantees.

**RES27: Bounded recovery.** If recovering fails _K_ times in a row (_K_ =
3), or the device is lost more than _K_ times within 10 seconds, the host
**must** stop recovering, enter `stopping` with a typed failure that names
the cause, and return `false` from `run`. It never spins.

## 6. Responsiveness (`RES30`–`RES37`)

**RES30: Idle is idle.** A `visible` window with no input, no animation and
no timed wake **must** present no frame and wake no more than the host's
declared idle period (none on the native arm; the hidden-window period on the
raylib arm) over a ten-second window.

**RES31: One frame of latency.** An input event's effect **must** be in the
first frame built after the drain that delivered it; the host never defers a
frame it may draw to a later frame opportunity.

**RES32: Paced, not queued.** On a paced window, the host draws only on a
frame opportunity (`FrameReadyEvent`) or a change, and **must** skip, not
queue, opportunities missed while busy
([`F04`](../window-system-integration/feature-requirements.md)).

**RES33: Coalesced reconfiguration.** Any number of size, scale or settings
changes drained together **must** cause at most one swapchain rebuild and
one frame, at the last values.

**RES34: Time is real time.** The `frameSeconds` an application reads
**must** be the time since the previous frame was presented (clamped to a
declared maximum after `hidden` or `suspended`), not the time the frame took
to build, so animations run at the same speed on every refresh rate.

**RES35: Dispatch budget.** The host **must** count frames whose `handle`
plus `present` time exceeds 50 ms and report them, and **must not** block in
a platform lifecycle callback longer than the window system's bound
(`RES12`). Long work belongs to daemons (`HST15`); a host arm without them
**must** say so (the native arm's `spawnDaemon` returns `false`).

**RES36: Prompt quit.** From an accepted close or quit to `run` returning,
the host **must** not wait on any timer or frame opportunity; only GPU
completion of in-flight frames (`RES5`) may delay it.

**RES37: Startup.** The host **must** report the time from `run` to the first
presented frame. No threshold is required yet; a later revision sets one
from measurements.

## 7. Adapting to the environment (`RES40`–`RES47`)

**RES40: Resize.** A size change **must** reach `handle` as a resize event
with the real size (`HST7`) before the first frame at that size, and that
frame **must** cover the new surface exactly; no frame of the old size is
presented on the new surface.

**RES41: Orientation.** A rotation is a resize (`RES40`), with the
swapchain's pre-rotation applied (`INT2`); application state that is
anchored in content (scroll position, selection) **must** stay on the same
content.

**RES42: Density.** A change of scale (a move to another monitor, a
fractional-scale change, a density change on Android) **must** arrive
atomically with the logical and physical sizes
([`F08`](../window-system-integration/feature-requirements.md)). The host
**must** re-measure cell metrics at the new scale while keeping the font size
the user chose in points, re-rasterize what depends on scale, and deliver
the change as a resize. No input event is translated with the old scale
after the change is drained.

**RES43: Refresh rate.** When the display's refresh rate changes, the host's
frame pacing **must** follow it: frame opportunities on the native arm, the
frame target on the raylib arm. Animations are unaffected (`RES34`).

**RES44: Outputs come and go.** When the output a window is on is removed,
the window **must** survive and report its new metrics; when outputs are
added, nothing changes until the window moves. (The window system's output
events are a prerequisite: `F09`.)

**RES45: System appearance.** Changes to the system color scheme, reduced
motion, contrast and text scale **must** reach `handle` as events
(`ColorSchemeEvent` exists; the others are owed by `sparkles:input` and the
design system's [`ACC5`](../design-system/SPEC.md)). An application that
follows them re-themes without a restart, and the result is cold-start
equivalent (`RES3`; [`THM7`](../ui/theme.md)).

**RES46: Insets.** Changes to the safe area (a soft keyboard, a cutout, a
system bar) **must** arrive as metrics changes and be cold-start equivalent.

**RES47: Locale.** A locale change **must** reach `handle` as an event, or the
host **must** declare that it applies only at start.

## 8. User-initiated settings (`RES50`–`RES56`)

The settings below are the host's and the canvas's own. An application's
settings (its theme, its key bindings) follow the same rules through
`RES51`–`RES52`, applied by the application.

**RES50: Live or declared.** Each setting **must** either apply while
running or be declared, in the interface that offers it, as taking effect on
the next start. The host's settings and their required class:

| Setting                       | Class   | Rebuilds                   |
| ----------------------------- | ------- | -------------------------- |
| cell font size (`HST14`)      | live    | cell metrics, glyph atlas  |
| cell font family              | live    | faces, cell metrics, atlas |
| scale override                | live    | as `RES42`                 |
| present mode (vsync, mailbox) | live    | the swapchain only         |
| frame-rate cap                | live    | nothing                    |
| fullscreen                    | live    | as `RES40`                 |
| reduced motion override       | live    | nothing                    |
| backend (raylib, Vulkan, TUI) | restart | —                          |
| GPU device selection          | restart | —                          |

**RES51: Live equals cold.** After a live setting is applied, the next frame
**must** be cold-start equivalent (`RES3`) to a start with that setting.

**RES52: All or nothing.** A setting that cannot be applied (a font family
not installed, a present mode the surface does not offer) **must** leave the
previous value in effect everywhere, be reported to the application as a
typed refusal, and change no frame.

**RES53: Least rebuild.** Applying a setting **must** end no scope beyond the
one its "Rebuilds" column names; a present-mode change keeps the device and
all device-scoped resources.

**RES54: One path for all sources.** A setting changed by the user, by a
configuration reload, or by another process (the terminal's
`termux-reload-settings`, [`NOD21`](../terminal/android.md)) **must** go
through the same application path and give the same result.

**RES55: User choices outlive the environment.** A setting the user chose
(font size, scale override) **must** survive any later change of §7; an
environment change re-derives only what the user did not choose.

**RES56: Settings while away.** A setting applied while `hidden` or
`suspended` **must** take effect in the first frame after (`RES18`).

## 9. How the scenarios run

### 9.1 Lanes

Each scenario runs on one or more **lanes**, from cheapest to most real. A
pass on one lane is evidence for that lane only.

| Lane       | What runs                                                                                         | Where                         |
| ---------- | ------------------------------------------------------------------------------------------------- | ----------------------------- |
| `model`    | the host's lifecycle machine: window events and frame outcomes in, host actions out (sans-I/O)    | `dub test :ui-app`            |
| `recorder` | the probe application on the recording host (`TST1`)                                              | `dub test :ui-app`            |
| `replay`   | the probe on the native arm's own translation and frame steps (`replayNative`, `TST3`)            | `dub test :ui-app`            |
| `gpu`      | the native arm on a headless Vulkan device with readback (lavapipe, validation layer)             | `SPARKLES_VULKAN_READBACK=1`  |
| `desktop`  | the native and raylib arms under Xvfb and headless Weston, driven by `xdotool` and output changes | lane scripts                  |
| `android`  | the phone or emulator lane: rotation, density, background, trim memory, activity recreation       | lane scripts, `.debug` app id |

### 9.2 The probe and the cold-start differential

The **probe application** is a test component that: counts `setup`,
`shutdown`, `handle` and `present`; keeps a state token it changes on input;
records every lifecycle, resize and settings event; and draws a frame that
depends on its state, the surface size, the cell metrics and the settings it
was told about. It owns resources in each scope through a ledger the host
can inspect.

The **cold-start differential** runs the scenario's script on one host,
records the settled frame, then starts a second host directly in the final
conditions, replays only the state-changing input, and compares frames. The
second run never sees the change, so a host that adapts wrongly cannot also
produce the expected frame.

### 9.3 The page and the suite stay in step

The scenario catalog below is data. A test in `sparkles:ui-app` reads this
page (`resilience_spec.d`) and fails when a scenario marked runnable has no
registered implementation, when an implementation has no row here, or when
a requirement has no scenario.

## 10. Scenario catalog

Status: `runs: <lanes>` — implemented and green on those lanes (the row's
other lanes are still to come); `planned` — specified, not implemented;
`blocked: <prerequisite>` — waits on it. A parenthesis names evidence that
lives outside this suite.
Scenario IDs are `RSC` numbers; they are never reused.

<!-- scenario-catalog:begin -->

| ID    | Requirements        | Lanes                   | Scenario                                                                                                                     | Expected                                                                                                      | Status                            |
| ----- | ------------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| RSC1  | RES1, RES2          | recorder, replay        | Every external change of §4–§8 in sequence on one run: resize, scale, hide, show, suspend, resume, memory pressure, settings | `setup` and `shutdown` once each; state token and object address unchanged                                    | planned                           |
| RSC2  | RES1                | recorder                | `handle` throws on the third event                                                                                           | `shutdown` runs exactly once; `run` reports the failure                                                       | runs: recorder                    |
| RSC3  | RES1, RES16, RES36  | model, recorder         | Close requested, vetoed, requested again and accepted                                                                        | the first close reaches `handle` and changes nothing; the second stops within one iteration                   | runs: model                       |
| RSC4  | RES3, RES40         | model, recorder, replay | Resize 80×24 → 120×40 → 60×20                                                                                                | each settled frame equals a cold start at that size; resize event precedes the frame                          | runs: model, recorder             |
| RSC5  | RES33               | model, replay           | 50 size changes and 3 scale changes drained in one batch                                                                     | one rebuild, one frame, at the last size and scale                                                            | runs: model                       |
| RSC6  | RES42, RES55        | model, replay           | User sets font size 22 px, then the scale changes 1 → 2 → 1, then the window resizes                                         | cell metrics follow the scale while the chosen size is kept; never reverts to the start size                  | runs: model                       |
| RSC7  | RES42               | replay                  | Scale change drained between a press and a drag                                                                              | the drag's position uses the new scale; no event mixes scales                                                 | planned                           |
| RSC8  | RES41               | android                 | Rotate portrait → landscape → portrait with a selection and a scrolled view                                                  | selection and scroll anchored to the same content; frames equal cold starts                                   | planned                           |
| RSC9  | RES12, RES14, RES18 | model, replay           | Suspend (zero extent), deliver input and a setting, resume with the same size                                                | swapchain released before the acknowledgement; no frame while suspended; first frame after shows the input    | runs: model                       |
| RSC10 | RES14               | model, gpu              | Suspend and resume with no change                                                                                            | the first frame after equals the last frame before; `setup` not called                                        | runs: model                       |
| RSC11 | RES15, RES13        | android                 | Activity destroyed and recreated (configuration change, "don't keep activities")                                             | process survives; leaving event before destruction; state intact                                              | blocked: V7                       |
| RSC12 | RES11, RES30        | model, desktop          | Window occluded for 5 s with a 1 s timed wake, then uncovered                                                                | no frame while hidden; wakes delivered; one frame on uncovering                                               | runs: model; desktop blocked: F14 |
| RSC13 | RES17               | model, replay, gpu      | Moderate pressure while visible; critical pressure while hidden                                                              | caches released then re-uploaded; device released only in the second; next frame cold-start equivalent        | runs: model                       |
| RSC14 | RES20, RES3         | model, gpu              | Device lost at frame 1, 2 and 100                                                                                            | one rebuild each; the frame equals the lost one; no event to the application                                  | runs: model                       |
| RSC15 | RES27               | model                   | Device creation fails three times after a loss; or the device is lost four times within 10 s                                 | `stopping` with a typed failure; `run` returns `false`; `shutdown` once                                       | runs: model                       |
| RSC16 | RES22               | model, gpu              | Present reports the surface lost; once with the window's handles still valid, once with none                                 | a new surface and a frame; or `suspended`; the run continues in both                                          | runs: model                       |
| RSC17 | RES21               | model, desktop          | Swapchain out of date during a drag-resize                                                                                   | rebuilt without a new device; frames keep coming                                                              | runs: model                       |
| RSC18 | RES23               | model                   | Device lost while a suspension is being acknowledged; resize during recovery                                                 | same final state as the losses applied one after another                                                      | runs: model                       |
| RSC19 | RES24               | gpu                     | Allocation fails during a frame                                                                                              | frame abandoned, caches released, next frame drawn                                                            | runs: gpu (`UVK34`)               |
| RSC20 | RES25, RES5         | model, gpu              | Device lost during `stopping`                                                                                                | `shutdown` runs; scopes end in order; no validation error                                                     | runs: model                       |
| RSC21 | RES4, RES5, RES8    | model, gpu              | A full run with the ledger: start, resize, suspend, resume, lose the device, quit                                            | every scope's count returns to its start value at its end; teardown order frame→surface→device→window→process | runs: model                       |
| RSC22 | RES7                | gpu                     | Register, draw and remove 1000 images across frames                                                                          | live device images after 1000 cycles ≤ after 10                                                               | planned                           |
| RSC23 | RES7                | recorder                | Open and close 1000 panes or windows                                                                                         | live counts return to baseline plus a constant                                                                | planned                           |
| RSC24 | RES9                | gpu                     | An embedded component binds its own image registry, then the application draws an image                                      | the application's image draws its own pixels                                                                  | planned                           |
| RSC25 | RES6                | gpu                     | Device lost after images and glyphs were uploaded                                                                            | everything redraws with no call into the application                                                          | planned                           |
| RSC26 | RES30               | desktop                 | A visible idle window for 10 s                                                                                               | no frame presented; loop wakes bounded                                                                        | runs: desktop (V4 gate, manual)   |
| RSC27 | RES31               | model, replay           | A key press drained together with a frame opportunity                                                                        | its effect is in that iteration's frame                                                                       | runs: model                       |
| RSC28 | RES32               | model                   | Frame opportunities arrive while a frame is being built                                                                      | at most one pending; missed ones skipped                                                                      | runs: model                       |
| RSC29 | RES34, RES43        | model, replay           | Frames presented at 60 Hz, then 144 Hz, then after 3 s suspended                                                             | `frameSeconds` is the interval, clamped after suspension                                                      | runs: model                       |
| RSC30 | RES35               | recorder                | `handle` takes 80 ms                                                                                                         | one slow frame counted and reported                                                                           | planned                           |
| RSC31 | RES43               | desktop                 | The output's mode changes from 60 to 30 Hz under the window                                                                  | frame opportunities follow                                                                                    | blocked: F09                      |
| RSC32 | RES44               | desktop                 | The window's output is unplugged (Weston output removal)                                                                     | the window survives with new metrics                                                                          | blocked: F09                      |
| RSC33 | RES45               | recorder                | System color scheme flips light → dark → light                                                                               | each settled frame equals a cold start in that scheme                                                         | planned                           |
| RSC34 | RES45               | recorder                | Reduced motion turned on during an animation                                                                                 | the animation completes without motion; frame equals a cold start                                             | blocked: ACC5                     |
| RSC35 | RES46               | android                 | The soft keyboard opens and closes                                                                                           | insets change, frames cold-start equivalent                                                                   | planned                           |
| RSC36 | RES50, RES51        | recorder, replay        | Each live setting of the `RES50` table changed once                                                                          | next frame equals a cold start with that setting                                                              | planned                           |
| RSC37 | RES52               | recorder, replay        | Set an unavailable font family; set a present mode the surface lacks                                                         | typed refusal; previous value in effect; no frame changes                                                     | planned                           |
| RSC38 | RES53               | model, gpu              | Switch present mode fifo → mailbox → fifo                                                                                    | swapchain rebuilt; device and its resources kept (ledger)                                                     | planned                           |
| RSC39 | RES54               | recorder                | The same setting from the settings page and from a configuration reload                                                      | identical state and frame                                                                                     | planned                           |
| RSC40 | RES56, RES18        | model, replay           | Font size changed while suspended                                                                                            | first frame after resumption uses it                                                                          | runs: model                       |
| RSC41 | RES19               | android                 | Background the terminal for 60 s while a command prints                                                                      | all output present on return                                                                                  | runs: android (`NOD9`, manual)    |
| RSC42 | RES10, RES13        | android                 | Press Home, then return                                                                                                      | hidden then leaving delivered before `onStop` returns; visible on return                                      | planned                           |
| RSC43 | RES37               | desktop                 | Cold start                                                                                                                   | time to first frame reported                                                                                  | planned                           |
| RSC44 | RES47               | recorder                | Locale changes while running                                                                                                 | event delivered, or declared start-only                                                                       | planned                           |
| RSC45 | RES26               | desktop                 | raylib arm: GL context lost                                                                                                  | declared behaviour holds                                                                                      | blocked: RES26 decision           |
| RSC46 | RES30, RES31        | model, replay           | The application asks for another frame in every frame (an animation), then stops asking                                      | a frame every iteration while it asks; none after                                                             | runs: model                       |

<!-- scenario-catalog:end -->

## 11. Ledger

Requirement status: `not started`, `partial` (the missing case named), or
`verified` on the named lanes. A `model` pass checks the native arm's own
decisions (`Lifecycle`, which `runNative` executes), not the GPU work they
lead to.

| ID    | Status      | Evidence                                                                                                                                          |
| ----- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| RES1  | partial     | `resilience.RSC2.recorder.aThrowingHandlerStillShutsDownOnce`, `ui_app.run_app.shutdownReleasesResourcesOnQuitAndException` — no change exercised |
| RES2  | not started | RSC1                                                                                                                                              |
| RES3  | partial     | `resilience.RSC4.recorder.aResizedRunSettlesLikeAColdStart` — size only                                                                           |
| RES4  | partial     | `resilience.RSC21.model.everyScopeEndsWithItsCause`, `ui_vulkan.canvas.aNewTargetRebuildsOnlyWhatIsTheTargets` — no GPU ledger                    |
| RES5  | partial     | `ui_vulkan.canvas.aReleasedImageOutlivesTheFramesThatReadIt` — fences only; order untested                                                        |
| RES6  | partial     | `ui_vulkan.canvas.aRebuiltDeviceDrawsTheSameFrame` — images; glyphs wait on V3                                                                    |
| RES7  | not started | known defect: removed images stay resident                                                                                                        |
| RES8  | partial     | `vulkan_wsi.window_surface.destroyIsIdempotentWithoutHandles`                                                                                     |
| RES9  | not started | known defect: the terminal's Vulkan painter does not restore the registry                                                                         |
| RES10 | not started | no lifecycle event in `sparkles:input`                                                                                                            |
| RES11 | partial     | `resilience.RSC12.model.hiddenDrawsNothingAndKeepsWaking` — no desktop backend reports occlusion (`F14`)                                          |
| RES12 | partial     | `resilience.RSC9.model.suspensionReleasesTheSurfaceAndKeepsWhatArrives` — model                                                                   |
| RES13 | not started | `TSS14` saves on focus loss instead                                                                                                               |
| RES14 | partial     | `resilience.RSC10.model.resumingUnchangedRedrawsWithoutANewDevice`, `ui_app.host.skipFrameIsRefusedOntoAFreshSurface` — model                     |
| RES15 | not started | the raylib arm exits on destroy                                                                                                                   |
| RES16 | partial     | `resilience.RSC3.model.anAcceptedCloseStopsAtOnce`, `wsi.loop.lifecycleIsOrderedAndGenerationSafe` — the native arm offers no veto                |
| RES17 | partial     | `resilience.RSC13.model.pressureReleasesCachesThenTheDevice` — not delivered to `handle` (`RES10`)                                                |
| RES18 | partial     | `resilience.RSC9.model.suspensionReleasesTheSurfaceAndKeepsWhatArrives`, `resilience.RSC40.model.aFontSizeSetWhileSuspendedIsInTheFirstFrame`     |
| RES19 | partial     | `NOD9` on the terminal (manual)                                                                                                                   |
| RES20 | partial     | `resilience.RSC14.model.aLostDeviceIsRebuiltAndTheFrameRedrawn`, `ui_vulkan.canvas.aRebuiltDeviceDrawsTheSameFrame` — simulated loss              |
| RES21 | partial     | `resilience.RSC17.model.anOutOfDateTargetIsRebuiltAlone`, `vulkan_wsi.swapchain.suboptimalAndOutOfDateBothMeanRecreate`                           |
| RES22 | partial     | `resilience.RSC16.model.aLostSurfaceIsReplacedOrSuspends` — model                                                                                 |
| RES23 | partial     | `resilience.RSC18.model.aLossDuringSuspensionResolvesOnResume` — model                                                                            |
| RES24 | verified    | `ui_vulkan.canvas.exhaustedMemoryAbandonsTheFrame` (gpu)                                                                                          |
| RES25 | partial     | `resilience.RSC20.model.aCloseDuringRecoveryStillStops` — model                                                                                   |
| RES26 | not started | no decision                                                                                                                                       |
| RES27 | partial     | `resilience.RSC15.model.recoveryIsBounded` — model                                                                                                |
| RES30 | partial     | V4 gate, manual (`SPARKLES_NATIVE_TRACE_FRAMES`)                                                                                                  |
| RES31 | partial     | `resilience.RSC27.model.inputIsInTheSameIterationsFrame` — model                                                                                  |
| RES32 | partial     | `resilience.RSC28.model.pacedFramesWaitAndMissedOnesAreNotQueued` — model; frame opportunities on every backend wait on `F04`                     |
| RES33 | partial     | `resilience.RSC5.model.aFloodOfChangesIsOneRebuildAndOneFrame`, `wsi.loop.eventQueueSurvivesAResizeFloodByCoalescing`                             |
| RES34 | partial     | `resilience.RSC29.model.frameSecondsIsTheIntervalClamped` — model                                                                                 |
| RES35 | not started | RSC30                                                                                                                                             |
| RES36 | partial     | `resilience.RSC3.model.anAcceptedCloseStopsAtOnce` — model                                                                                        |
| RES37 | not started | RSC43                                                                                                                                             |
| RES40 | partial     | `resilience.RSC4.model.eachResizeRebuildsTheTargetAndDraws`, `resilience.RSC4.recorder.aResizedRunSettlesLikeAColdStart`                          |
| RES41 | partial     | `vulkan_wsi.test_pattern.aTurnedSwapchainSwapsItsDisplayExtent` — the swapchain's half                                                            |
| RES42 | partial     | `resilience.RSC6.model.theChosenFontSizeOutlivesScaleAndSize` — cell metrics only; rasterization and input scale untested                         |
| RES43 | not started | blocked on `F09`                                                                                                                                  |
| RES44 | not started | blocked on `F09`                                                                                                                                  |
| RES45 | partial     | `ui_app.assembler.colorSchemeReports` — the event; equivalence untested                                                                           |
| RES46 | partial     | `wsi.types.safeRegionIsTheSurfaceInsideItsInsets`                                                                                                 |
| RES47 | not started | RSC44                                                                                                                                             |
| RES50 | not started | RSC36                                                                                                                                             |
| RES51 | not started | RSC36                                                                                                                                             |
| RES52 | not started | RSC37                                                                                                                                             |
| RES53 | not started | present mode is fixed at swapchain creation                                                                                                       |
| RES54 | partial     | `settings_page.activate.controlsCommitApplyAndSave` — the terminal's settings page only                                                           |
| RES55 | partial     | `resilience.RSC6.model.theChosenFontSizeOutlivesScaleAndSize` — model                                                                             |
| RES56 | partial     | `resilience.RSC40.model.aFontSizeSetWhileSuspendedIsInTheFirstFrame` — model                                                                      |

## 12. Open questions

- **RQ1: Where lifecycle events live.** `RES10` needs app-facing visible,
  hidden, suspended, resumed and leaving events. One `LifecycleEvent` with a
  state field in `sparkles:input`, or separate events? Decide before RSC12 and
  RSC42.
- **RQ2: The raylib arm's place.** `RES15` and `RES26` cannot be met by raylib
  on Android without patching it further. Accept the declared exceptions, or
  require the native arm for every Android application? Decide before RSC11.
- **RQ3: Device release policy.** `RES17` permits releasing the device on
  critical pressure while hidden. Default on, off, or per application?
  Measurements from window-system slice MA5 should decide it.
