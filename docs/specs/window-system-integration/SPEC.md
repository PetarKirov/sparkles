# `sparkles:wsi` — Specification

_Audience: contributors implementing window-system backends and renderer hosts. This
document is normative. Requirements are enumerated in
[feature-requirements.md](./feature-requirements.md), delivery order is in
[PLAN.md](./PLAN.md), unresolved questions are isolated in
[open-issues.md](./open-issues.md), and the evidence base is the
[window-system-integration research](../../research/window-system-integration/index.md)._

**Status:** M0 specification; implementation in progress

**Last reviewed:** August 20, 2026

## 1. Purpose and scope

`sparkles:wsi` is Sparkles' dependency-light native window-system integration layer.
It creates and owns desktop windows, translates native input without losing
information, exposes typed native handles to renderers, and joins native event sources
to the one [`sparkles:event-horizon`](../event-horizon/SPEC.md#_15-the-ui-event-loop)
application loop.

The first complete platform set is:

| Platform | Native backend | Required client APIs                                              |
| -------- | -------------- | ----------------------------------------------------------------- |
| Linux    | Wayland        | `libwayland-client`, generated protocol declarations, `xkbcommon` |
| Linux    | X11            | XCB/Xlib where required by XIM, `xkbcommon-x11`                   |
| Windows  | Win32          | User32, DWM, DPI, raw input, IMM32                                |
| macOS    | AppKit         | AppKit, Foundation, CoreGraphics, QuartzCore                      |

These operating-system client libraries are platform APIs for this specification. The
native package does **not** depend on SDL, GLFW, raylib, Qt, winit, a widget toolkit, a
renderer, or Skia. SDL 3 remains a separately named compatibility implementation; it is
never a hidden fallback selected by `sparkles:wsi`.

The layer owns no widgets and draws no application content. Wayland client-side window
decorations are the one exception: when the compositor declines server-side
decorations, the backend reports decoration regions and frame actions through the WSI
contract; the renderer above WSI paints them.

## 2. Package and dependency boundaries

| Identifier      | Value                        |
| --------------- | ---------------------------- |
| Dub sub-package | `sparkles:wsi`               |
| Source root     | `libs/wsi/src/sparkles/wsi/` |
| Package module  | `sparkles.wsi`               |
| Optional SDL    | future `sparkles:wsi-sdl3`   |
| Vulkan bridge   | future `sparkles:vulkan-wsi` |

The native package's direct Sparkles dependencies are deliberately small:

```text
sparkles:wsi -> sparkles:base
             -> sparkles:input
             -> sparkles:event-horizon
             -> expected
             -> sparkles:math (source import only, like sparkles:input)
```

The import directions are load-bearing:

- `sparkles:wsi` never imports `sparkles:ui`, `sparkles:ui-app`, Vulkan, Skia, SDL,
  raylib, or application code;
- `sparkles:input` remains the toolkit-facing, cell-space interaction vocabulary;
- render bridges depend on WSI, not the reverse;
- `sparkles:ui-app` owns backend choice and converts lossless `WindowEvent` values into
  the application/toolkit event vocabulary;
- no native platform source is compiled on a different platform merely to satisfy a
  shared module import.

The planned module layout is:

| Module             | Contract                                                                                |
| ------------------ | --------------------------------------------------------------------------------------- |
| `types`            | identifiers, logical/physical geometry aliases, scale, configuration, errors            |
| `events`           | lossless `WindowEvent`, key, composition, pointer, scroll, output, and lifecycle values |
| `handles`          | closed typed native display/window handles and renderer-handoff query                   |
| `loop`             | `Wsi`, command queue, event drain, Event Horizon attachment, wake/coalescing policy     |
| `platform.wayland` | Wayland connection, protocols, seats, outputs, surfaces, popups, data devices           |
| `platform.x11`     | XCB/XIM connection, atoms, selections, grabs, outputs, windows                          |
| `platform.win32`   | HWND lifecycle, messages, raw input, DPI, IMM32, clipboard and OLE drop                 |
| `platform.appkit`  | `NSApplication`/`NSWindow`, responder and text-input client, pasteboard, displays       |

## 3. Ownership and threading

One process has one WSI owner on the UI/main thread. Every window, native callback, and
mutation belongs to that thread. A `WindowId` is a generation-checked value, not a
pointer; events and commands may therefore be recorded without borrowing a native
object.

Other threads may only:

1. enqueue a value command through the bounded command channel; and
2. call the coalescing `Waker` obtained from Event Horizon.

They may copy a typed raw handle for renderer setup only when the platform-specific
handle contract says its lifetime is stable. They may not call window-system APIs
through that handle. Destroying `Wsi` invalidates every `WindowId` and handle view.

`Wsi` is neither shared nor movable after attachment because native callbacks retain
its address. `WindowId`, configuration values, events, and raw-handle values are
Regular values.

## 4. The single integrated loop

There is no WSI-owned blocking loop beside Event Horizon. `sparkles:event-horizon` is
the application's only scheduler, timer source, cross-thread wake mechanism, and
blocking wait.

The public shape is callback-free at the application boundary while still respecting
platform callbacks internally:

```d
WsiResult!Wsi openWsi(ref Sched sched, WsiConfig config = {});

struct Wsi
{
    WsiResult!WindowId createWindow(WindowConfig config);
    WsiResult!void command(WindowCommand command);
    size_t drain(scope void delegate(scope ref const WindowEvent) @safe consumer);
    void close();
}
```

`openWsi` attaches the selected native source to `sched`; it does not create a second
thread and it does not run the scheduler. `drain` never blocks and preserves native
ordering. A caller normally drains after the scheduler reports readiness and before
building the next frame.

### 4.1 Linux

The Wayland display fd or X11 connection fd is submitted through Event Horizon's
`waitReadable`/`OpPollAdd` path. The backend performs the required non-blocking native
dispatch sequence when readiness completes. It never blocks inside
`wl_display_dispatch`, `xcb_wait_for_event`, or an equivalent foreign pump.

Wayland obeys the prepare-read protocol exactly: dispatch pending events, prepare the
read, flush requests, let Event Horizon wait, then read and dispatch; cancellation
cancels the prepared read. A writable poll is armed only while `wl_display_flush`
reports backpressure.

### 4.2 Windows

The UI thread owns a message-only wake window plus every application `HWND`. Native
messages are drained with `PeekMessage` after IOCP or the WSI waker makes the scheduler
runnable. The Event Horizon IOCP backend supplies the blocking wait; WSI does not call
an unbounded `GetMessage` or `WaitMessage`.

Modal Win32 loops can dispatch messages while the normal scheduler stack is not at its
drain point. The window procedure therefore performs the minimum synchronous native
reply, appends a Regular event, and wakes the scheduler. Re-entrant delivery never calls
application code.

### 4.3 macOS

AppKit owns the outer main-thread run loop. Event Horizon integrates through
`CFRunLoopSource`/observer hooks and its kqueue waker rather than starting a competing
`NSApplication` pump. Native delegates append events; application callbacks run only at
the WSI drain boundary. `openWsi` fails with `wrongThread` unless called on the process
main thread.

### 4.4 Pacing

WSI reports frame opportunities; it does not sleep to manufacture vsync. Wayland frame
callbacks, DWM composition timing, display-link notifications, and explicit fallback
deadlines become a coalesced `FrameReady` event. Event Horizon `Ticker` is used only
where the platform has no usable frame signal or a caller explicitly asks for a capped
cadence. Missed frame ticks are skipped, never replayed.

## 5. Core values

### 5.1 Geometry and scale

Public names carry units. Implementations reuse `sparkles:math` vector storage instead
of defining a second point/size implementation.

| Alias              | Meaning                                                         |
| ------------------ | --------------------------------------------------------------- |
| `LogicalPosition`  | top-left-relative device-independent position, floating point   |
| `LogicalSize`      | device-independent extent, floating point                       |
| `PhysicalPosition` | signed pixel position; signed because a point may be off-screen |
| `PhysicalSize`     | framebuffer/surface extent in pixels                            |
| `ScaleFactor`      | physical pixels per logical unit                                |

Every resize or scale transition reports logical size, physical surface size, and
scale together in one `SurfaceMetricsChanged` event. Consumers size GPU swapchains only
from `physicalSize`. A zero physical extent means suspended/minimized and is not an
error. Conversions specify rounding: positions use nearest integer; enclosing extents
round outward; suggested native rectangles remain exact physical values.

### 5.2 Identity and errors

`WindowId`, `OutputId`, `SeatId`, `PointerId`, and `OfferId` carry an index plus a
generation. The all-zero value is invalid. Stale identifiers return
`WsiErrorKind.staleId`, never address a recycled native object.

Every fallible synchronous API returns `Expected!(T, WsiError)`. `WsiError` records:

- stable `WsiErrorKind`;
- backend and operation;
- native error code when one exists; and
- an inline diagnostic suitable for logs.

Native WSI errors are not `IoError`: a refused Wayland global, failed Objective-C
selector, or unsupported cursor is not a byte-stream operation.

## 6. Window lifecycle and commands

`WindowConfig` includes title, initial logical size, visibility, decorations,
resizability, transparency, startup state, and optional parent. Creation is two-phase:
the returned `WindowId` identifies a live native object, while `WindowEvent.ready`
declares that handles and the first authoritative metrics are usable by a renderer.

The command algebra includes:

- show/hide, close, set title, request redraw;
- set logical size and constraints;
- maximize, minimize, restore, fullscreen, and attention;
- accept or cancel a close request;
- set cursor shape/visibility, begin/end capture and relative mode;
- set IME enabled state and candidate/pre-edit rectangle;
- create/reposition/destroy a grabbed popup;
- read/write clipboard and accept/reject a data offer.

Commands issued while a platform transaction is pending are coalesced where later
state supersedes earlier state (title, cursor, redraw), and ordered where every edge
matters (capture, clipboard offers, popup grabs). A command that cannot be represented
on the active backend returns `unsupported`; it never silently succeeds.

Close is vetoable. A native close request produces `closeRequested`; only an explicit
accept or a configured default destroys the window. Destruction produces exactly one
`destroyed` event after the native handle is no longer usable.

## 7. Event vocabulary

`WindowEvent` is a sum type whose payloads own their small text and metadata. It is a
lossless platform boundary, not an alias for `sparkles.input.Event`: the latter is a
toolkit-facing vocabulary whose coordinates are already converted to cells and whose
wheel values are already policy-normalized.

The required event families are:

| Family        | Required information                                                  |
| ------------- | --------------------------------------------------------------------- |
| lifecycle     | ready, exposed, occluded, close requested, destroyed                  |
| metrics       | logical/physical size, scale, move, output enter/leave                |
| frame         | frame opportunity and presentation feedback where available           |
| focus         | window focus, keyboard focus, pointer enter/leave                     |
| keyboard      | physical key, logical key, location, press/repeat/release, modifiers  |
| text/IME      | committed UTF-8, pre-edit UTF-8, selection, cursor and segment spans  |
| pointer       | id, logical and physical position, button, motion, raw relative delta |
| scroll        | logical/pixel deltas, discrete steps, source, phase, inversion        |
| touch         | contact id, phase, pressure/shape where supplied                      |
| output        | add/change/remove, work area, modes, scale, refresh                   |
| clipboard/DnD | offer MIME types, data completion/error, enter/move/leave/drop        |
| popup         | configured rectangle, reposition token, dismissed                     |

Unknown native keys retain their physical platform code. Text commits are separate
from key events because IME commits may have no corresponding key and one key may
produce no text. UTF-8 is the public encoding. Shared UTF-8/UTF-16 conversion belongs
in `sparkles:base`, is allocation-conscious, and rejects ill-formed input without
silently replacing it at a system boundary.

All composition cursor, selection, and segment offsets are byte offsets into the
event's owned UTF-8 pre-edit value. A backend converts native UTF-16 code-unit or
platform-string indices before enqueueing the event; consumers never reinterpret
those fields as code points or native indices. Segments are ordered, non-overlapping,
and may be coalesced when adjacent native spans have the same public style.

The `sparkles:ui-app` adapter is the sole normalizer into `sparkles:input`: it applies
cell metrics, scroll policy, and capability degradation once. Pure conversion helpers
live in `sparkles:input` so SDL and raylib compatibility producers use the same rules.

## 8. Typed native handles

The renderer handoff is a closed sum, not `void*` and not a bag of nullable fields:

```d
alias DisplayHandle = SumType!(WaylandDisplayHandle, X11DisplayHandle,
                               Win32DisplayHandle, AppKitDisplayHandle);
alias WindowHandle = SumType!(WaylandWindowHandle, X11WindowHandle,
                              Win32WindowHandle, AppKitWindowHandle);

struct NativeHandles
{
    DisplayHandle display;
    WindowHandle window;
}
```

Each variant contains only the exact native objects a renderer needs. Wayland exposes
`wl_display*` plus `wl_surface*`; X11 exposes connection/display plus window/visual;
Win32 exposes `HINSTANCE` and `HWND`; AppKit exposes `NSWindow*` and `NSView*`. The
variant is queryable only after `ready` and until destruction begins. Backends may add
new variants only in a versioned API change; field reinterpretation is forbidden.

## 9. Platform contracts

### 9.1 Wayland

- Bind globals by advertised version capped at the implementation version.
- Ack every `xdg_surface.configure` before returning from its listener; state and
  physical-size decisions may be deferred, acknowledgement may not.
- First commit follows the no-buffer/initial-configure handshake.
- Use `xdg-decoration` for SSD when present; otherwise expose own-drawn CSD regions. No
  libdecor dependency.
- Bind fractional scale with viewporter, presentation time, relative pointer/pointer
  constraints, text-input-v3, data-device, primary selection when present, and
  xdg-output/standard output state as capabilities rather than hard requirements.
- Popups use `xdg_positioner` and an explicit grab serial.

### 9.2 X11

- Use XCB for event and window operations; use Xlib only where XIM interoperation
  requires it, with one owned connection/display relationship.
- Preserve both keycode and translated key identity through xkbcommon-x11.
- Implement selections incrementally, including `INCR`, `TARGETS`, and XDND.
- Use RandR for output topology and best-effort scale. The API reports that X11 has no
  authoritative per-surface fractional scale.
- Popups are override-redirect windows with an active pointer/keyboard grab and
  explicit dismissal.

### 9.3 Win32

- Opt into Per-Monitor-V2 DPI awareness before creating a window; handle
  `WM_DPICHANGED` atomically with its suggested rectangle.
- Separate physical scan code, virtual/logical key, committed text, and raw input.
- The first IME implementation uses IMM32 (`WM_IME_*`, composition/candidate windows).
  TSF is a later milestone and must preserve this public event contract.
- Keep the window responsive through sizing/moving and other modal loops; native
  replies happen synchronously while application work remains queued.
- Clipboard uses delayed rendering where useful; drag-and-drop uses OLE on an STA UI
  thread.

### 9.4 AppKit

- All AppKit work runs on the process main thread.
- The content `NSView` supplies a layer suitable for Metal and exposes its pixel size
  from backing conversion, not logical bounds alone.
- Keyboard text and composition implement `NSTextInputClient`; key events remain
  separate from insert/marked-text callbacks.
- Live resize produces metrics/frame opportunities without blocking Event Horizon.
- Pasteboard, dragging destination/source, cursor rectangles, tracking areas, and
  display notifications feed the common event/command algebra.

## 10. Compatibility and renderer layers

`sparkles:wsi-sdl3` implements the WSI-facing host contract by delegation and is selected
only by the explicit `gui-skia-sdl` application configuration. It is useful for platform
bring-up and regression comparison; it is not part of the native package and cannot
claim a native feature that SDL does not expose publicly.

`sparkles:vulkan-wsi` owns Vulkan instance extension selection, native surface creation,
swapchain/frame synchronization, and present/rebuild policy. It reuses the Vulkan
loader/command types in `sparkles:vulkan` and extracts the proven resource-retirement
logic from `sparkles:ui-sdl3`; WSI itself contains no Vulkan type.

Skia Graphite sits above those seams:

```text
ui-app -> ui-skia -> Skia Graphite -> Vulkan (Linux/Windows) -> vulkan-wsi -> wsi
                         |-> Metal (macOS) -------------------------------> wsi

ui-app -> ui-skia-sdl -> Skia Graphite -> SDL compatibility host
ui-app -> ui-raylib   -> existing raylib host
```

## 11. Testing and evidence

Every feature-bearing WSI commit updates
[comparison.md](./comparison.md): the `sparkles:wsi` cell moves only from `planned` to
`partial` or `verified` when the named automated and manual evidence exists.

The minimum evidence lanes are:

| Lane      | Required evidence                                                                                                          |
| --------- | -------------------------------------------------------------------------------------------------------------------------- |
| pure/core | unit tests under the repository test runner; recording/replay invariants                                                   |
| Wayland   | headless compositor protocol tests plus Mutter live-resize and input pass                                                  |
| X11       | Xvfb automation plus a real WM pass for grabs, state and resize                                                            |
| Win32     | cross-compile; fresh Wine prefixes under winewayland and Xvfb/winex11; native Windows CI for behaviors Wine cannot certify |
| AppKit    | dedicated `mac-bsn` worktree; automated build/tests plus manual live window, IME, scale and Metal handoff                  |

Wine results are labelled `A[wine]`, Xvfb `A[xvfb]`, compositor harnesses
`A[headless]`, native automation `A[native]`, and human-in-the-loop measurements
`H[platform]`. A compatibility implementation does not substitute for native-backend
evidence.

## 12. Non-goals

- widgets, layout, themes, accessibility trees, or app navigation;
- graphics-device creation, shader compilation, or swapchains;
- silently loading a third-party windowing library;
- mobile/web support before all four desktop backends satisfy the baseline;
- TSF before the IMM32 contract and native desktop integration are complete;
- reproducing Event Horizon's scheduler, timers, channels, IOCP, kqueue, or wake logic.

## 13. Completion definition

The native-desktop baseline is complete only when all `F01`–`F17` requirements are
`verified` on Wayland, X11, Win32, and AppKit; the comparison matrix cites the evidence;
the native handle bridge creates a real Vulkan surface on Linux/Windows and a real Metal
layer on macOS; and `sparkles:ui-app` can select the native host without application
code naming a backend.

Graphite and `ui-app` integration follow that baseline. TSF follows native Graphite and
application-host integration so it improves the Windows IME implementation behind an
already stable event contract.
