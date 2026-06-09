# macOS (Cocoa / AppKit)

The native windowing API of macOS: an object-and-delegate Objective-C framework where the application creates an [`NSApplication`][nsapplication] singleton, builds [`NSWindow`][nswindow]/[`NSView`][nsview] objects, and cedes the process's main thread to AppKit's `CFRunLoop`-backed run loop. This is the layer [GLFW][glfw], [SDL3][sdl3], [Qt 6][qt6], and [JUCE][juce] all reduce to on the Mac.

**Last reviewed:** June 9, 2026

| Field                    | Value                                                                                                                                          |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Native API               | Cocoa / **AppKit** (`NSApplication` / `NSWindow` / `NSView` / `NSResponder` / `NSEvent`)                                                       |
| Library / framework      | `AppKit.framework` (window/UI) over `Foundation` and `CoreGraphics`; linked via the `Cocoa` umbrella framework                                 |
| Header / protocol source | Objective-C class interfaces in `AppKit.framework/Headers/` (e.g. `NSApplication.h`, `NSWindow.h`, `NSView.h`); reached from D via `@selector` |
| Window handle type       | `NSWindow*` (an Objective-C object pointer; its content area is an `NSView*`)                                                                  |
| Event-loop primitive     | `[NSApp run]` driving an `NSRunLoop` backed by `CFRunLoop`; events are `NSEvent` objects dispatched through the [responder chain][nsresponder] |
| Coordinate unit          | **Points** (logical, device-independent); pixels via [`backingScaleFactor`][backingscalefactor]                                                |
| Decoration owner         | **Server-side** — the AppKit window frame (titlebar, traffic-light buttons, shadow) is drawn by the OS, selected by `NSWindowStyleMask`        |
| Example                  | [`./example/app.d`](./example/app.d)                                                                                                           |

---

## What it is

AppKit is the macOS application framework: it owns the application object, the window and view hierarchy, the event loop, drawing, and the input/text stack. It is object-oriented Objective-C through and through — you do not call free functions to make a window, you send messages to classes and instances (`[NSWindow alloc]`, `[window makeKeyAndOrderFront:nil]`). The framework is **delegate-driven**: rather than subclass everything, an app installs delegate objects (`NSApplicationDelegate`, `NSWindowDelegate`) that AppKit calls back at lifecycle points, and routes input through a **responder chain** of [`NSResponder`][nsresponder] objects (view → window → application).

Two facts dominate every other design choice and recur across the entire survey. First, **AppKit is main-thread-only**: `NSApplication`, `NSWindow`, and `NSView` must be created and messaged from the process's first thread, and the run loop must run there. Second, **`[NSApp run]` does not return** under normal operation — it is the application's terminal call, and teardown happens in delegate callbacks (`applicationWillTerminate:`), not after `run`. Together these force the "GUI lives on the main thread, the OS owns the loop" model that the [readiness-vs-completion windowing][rvc] concept describes, and that every cross-platform toolkit standardizes on partly _because_ of macOS.

The example here does not use Objective-C source or a bridging header. It reaches AppKit through D's built-in `extern(Objective-C)` interop, where the D compiler emits real Objective-C message sends for methods tagged with the `@selector` attribute. The D specification states the contract verbatim:

> D supports interfacing with Objective-C. It supports protocols, classes, subclasses, instance variables, instance methods and class methods. Platform support might vary between different compilers.

— [_Interfacing to Objective-C_][dlang-objc], the D language specification

The Objective-C **runtime linkage** and the scoped autorelease pool (the memory-management context every Cocoa object-creation site needs) come from the [`objective-d`][objd] package, whose `objc.autorelease` module the example imports for `autoreleasepool_push`/`autoreleasepool_pop`.

> [!NOTE]
> Cocoa geometry types (`NSPoint`, `NSSize`, `NSRect`) are plain C structs of `CGFloat` (a `double` on 64-bit), **not** Objective-C objects, so the example declares them with `extern(C)` and passes them by value. Only the classes (`NSObject` and its descendants) cross the Objective-C message-send boundary.

---

## The minimal program

The example, [`./example/app.d`](./example/app.d), is the irreducible Cocoa window-open sequence that [GLFW][glfw], [SDL3][sdl3], and [winit][winit-mac] each wrap on macOS. It declares the AppKit classes it needs as `extern(Objective-C)` (objective-d bundles `Foundation`, not `AppKit`), then runs:

1. **Headless guard.** `CGMainDisplayID()` (a CoreGraphics C function, linked transitively by `Cocoa`) returns `0` when there is no window server — an SSH/headless session, or CI. The program prints `SKIP:` and exits `0`, because creating an `NSWindow` with no window server is undefined. This is the `SKIP:`/exit-`0` discipline the research-doc guidelines require for host-capability gating.
2. **Autorelease pool.** `autoreleasepool_push()` (from `objc.autorelease`) opens the scope that balances the `+alloc`/`-init`/autoreleased objects created below; `scope (exit)` pops it. Cocoa convention requires an autorelease pool to be in place around any AppKit object creation.
3. **The application singleton.** `NSApplication.sharedApplication()` (`+sharedApplication`) creates the process-wide `NSApp` and connects to the WindowServer. `setActivationPolicy(NSApplicationActivationPolicyRegular)` makes it a normal, Dock-visible GUI app (a bare executable defaults to a background "prohibited" policy and would show no window).
4. **The window.** `NSWindow.alloc().initWithContentRect(...)` sends `+alloc` then `-initWithContentRect:styleMask:backing:defer:` — AppKit's designated `NSWindow` initializer. The `contentRect` is the content area in **screen points** (`NSRect(NSPoint(120, 120), NSSize(480, 320))`); the `styleMask` (`NSWindowStyleMaskTitled | …Closable | …Resizable`) selects which **server-side** frame elements AppKit draws; `backing` is `NSBackingStoreBuffered`; `defer:false` creates the window device immediately. `setTitle:` takes an `NSString` built via `[[NSString alloc] initWithUTF8String:]`.
5. **Show + activate.** `makeKeyAndOrderFront(null)` makes the window key (focused) and orders it to the front of its level — the moment it becomes visible. `activateIgnoringOtherApps(true)` brings the app forward.
6. **Bounded exit.** A real app would now call `app.run()` (`-[NSApplication run]`), which blocks forever pumping `NSEvent`s. The example deliberately **returns instead** so CI never hangs — it prints `ok:` and exits. The `run()` selector is declared but not invoked; the survey below describes what it would do.

> [!IMPORTANT]
> The whole sequence runs on the **main thread** because `main` runs there; AppKit would assert or misbehave otherwise. The example does not spawn threads, so it sidesteps the `MainThreadMarker`/`+[NSThread isMainThread]` checks that [winit][winit-mac] and [SDL3][sdl3] enforce at runtime — but a real binding must respect the same constraint.

---

## Window creation & lifecycle

Windows are full Objective-C objects, created with the standard two-step `+alloc` / `-init…` dance. The designated initializer is `-[NSWindow initWithContentRect:styleMask:backing:defer:]`: it takes the **content** rect (the drawable area, excluding the OS-drawn titlebar) in screen points, an `NSWindowStyleMask` bitset, the backing-store type (`NSBackingStoreBuffered` is the only non-deprecated value), and a `defer` flag controlling whether the backing window device is allocated now or on first display. The example's call is exactly this.

The `NSWindowStyleMask` bitset is the decoration-and-behaviour selector — `NSWindowStyleMaskTitled`, `…Closable`, `…Miniaturizable`, `…Resizable`, plus borderless/fullscreen/utility variants. Because the frame is server-side (see [Decorations](#decorations--multi-window--popups)), changing the mask is how an app gets or removes the titlebar; there is no "draw your own chrome into the same surface" default.

A window is shown with `-makeKeyAndOrderFront:` (key + front), `-orderFront:` (front, not key), or `-orderBack:`; hidden with `-orderOut:`. Unlike Wayland's [no-buffer-no-window][nbnw] handshake, **window creation and display are synchronous** — `makeKeyAndOrderFront:` maps the window immediately, like Win32 `ShowWindow` and X11 `XMapWindow`. Lifecycle notifications arrive through the window's delegate (`NSWindowDelegate`: `windowDidResize:`, `windowWillClose:`, `windowDidBecomeKey:`) and the app delegate (`applicationDidFinishLaunching:`, `applicationWillTerminate:`).

> [!WARNING]
> **The `releasedWhenClosed` footgun.** By default an `NSWindow` releases itself when the user closes it; if the app also holds a reference and over-releases, it crashes. The survey records both directions: [JUCE][juce] sets `setReleasedWhenClosed: YES` _and_ explicitly retains for plugin-host robustness, while [Avalonia][avalonia] uses `setReleasedWhenClosed: false` (with `defer:false`) to dodge a resize bug. A binding must pick a policy deliberately. The example sidesteps this by never closing the window.

App startup in a full app normally goes through `NSApplicationMain` (which loads the main nib/storyboard, creates `NSApp`, installs the delegate, and calls `run`) — see [`NSApplicationMain`][nsapplicationmain]. The example instead builds `NSApplication` by hand with `+sharedApplication`, the lower-level path a non-bundle, code-only window opener uses.

---

## Event loop & frame pacing

The loop is `-[NSApplication run]`: it repeatedly pulls the next `NSEvent` (internally `-nextEventMatchingMask:untilDate:inMode:dequeue:`), sends it via `-sendEvent:`, and drains the `NSRunLoop` — which is layered on Core Foundation's `CFRunLoop`. The OS owns the loop; the app is called back. This is the **completion/callback** end of the [readiness-vs-completion][rvc] fork, and it is _why_ [winit][winit-mac] abandoned its old poll-iterator model: on macOS you cannot run your own top-level loop, so winit instead hangs `CFRunLoop` observers (`kCFRunLoopAfterWaiting` ≈ new-events, `kCFRunLoopBeforeWaiting` ≈ about-to-wait) off `NSApp`'s run loop and overrides `-sendEvent:`. A toolkit that wants to drive the loop itself instead pumps `-nextEventMatchingMask:…` manually ([GLFW][glfw] does this — and its source admits a `dequeue:NO` variant "mysteriously hangs").

Two structural hazards live here:

- **`[NSApp run]` never returns**, so cleanup must move into `applicationWillTerminate:` (the survey notes [sokol][sokol] carries a verbatim comment to this effect). The example avoids the issue entirely by not calling `run`.
- **Nested / modal run loops.** Menu tracking and modal sheets spin a _nested_ `CFRunLoop` in a private mode (`NSModalPanelRunLoopMode`, `NSEventTrackingRunLoopMode`), which **starves** a guest loop registered only in `kCFRunLoopCommonModes`. Toolkits service their sources in the private modes too ([Flutter][flutter]'s `FlutterRunLoop` adds a source+timer to both common and a private mode).

> [!NOTE]
> **AppKit cannot wait on file descriptors and `NSEvent`s in one call.** A loop that must also watch a socket (the recurring problem when integrating an [async runtime][async-io]) cannot simply `poll(2)` — there is no portable way to inject an fd into the `NSEvent` wait set. [GTK 4][gtk4]'s `gdkmacoseventsource.c` solves it by pushing the blocking `select()` onto a dedicated helper thread. This is the macOS face of the "no portable external-fd injection" trap.

**Frame pacing.** `NSEvent`/`CFRunLoop` paces input, not redraw. Vsync comes from a separate, higher-priority source: historically [`CVDisplayLink`][cvdisplaylink], a callback fired from a display-driven thread before each refresh. Apple **deprecated `CVDisplayLink` in macOS 15** in favour of [`CADisplayLink`][cadisplaylink] (the AppKit/`NSView` analogue of the long-standing UIKit class). The survey-wide guidance, from [frame-callback vsync][fcv], is to use a per-screen `CVDisplayLink` today with a `CADisplayLink` migration planned ([JUCE][juce], [Qt 6][qt6], [GTK 4][gtk4] all note the deprecation in-source; [sokol][sokol] already migrated). A known wrinkle: `CADisplayLink` pauses when the window is minimized/obscured, so a 60 Hz fallback `NSTimer` is the documented backstop. The example does no rendering, so it installs no display link.

---

## Input

**Keyboard.** Key presses arrive as `NSEvent` objects of type `NSEventTypeKeyDown`/`KeyUp` routed through the [responder chain][nsresponder] to the first responder's `-keyDown:`. An event carries a `keyCode` (a hardware key location), `characters` (the produced text), and `charactersIgnoringModifiers`. Crucially, **macOS has no keysym or virtual-key concept** the way X11 and Win32 do — the `keyCode` is a raw, layout-independent [scancode][skv] and nothing more. [winit][winit-mac]'s key model says so verbatim: _"There does not appear to be any direct analogue to either keysyms or 'virtual-key' codes in macOS, so we report the scancode instead."_ Text-producing keys are normally not decoded by hand; the view calls `-interpretKeyEvents:`, which feeds the key stream into the text input system below.

**IME / text input.** The composition pipeline is the [`NSTextInputClient`][nstextinput] protocol ([pre-edit / composition][pec]). A view that wants CJK/dead-key/emoji input implements `NSTextInputClient` and lets `-interpretKeyEvents:` route through its `NSTextInputContext`; the context delivers provisional **marked (pre-edit) text** via `-setMarkedText:selectedRange:replacementRange:` and the final **commit** via `-insertText:replacementRange:`, and asks the client for the caret rectangle via `-firstRectForCharacterRange:actualRange:` to place the candidate window. This is implemented by [SDL3][sdl3], [winit][winit-mac], and [JUCE][juce]; the survey records two recurring failures — [GLFW][glfw] discards the marked text and returns a zero rect (mispositioned candidate window), and a bespoke rendering view (`MTKView`-style) may expose **no** `inputContext`, silently bypassing the IME entirely ([Uno][uno] had to override `inputContext`; [sokol][sokol] reads `event.characters` directly and so gets no CJK).

**Pointer.** Mouse motion/buttons are `NSEvent`s (`NSEventTypeMouseMoved`, `…LeftMouseDown`, `…ScrollWheel`) with `locationInWindow` in window points; window-relative coordinates come from `-[NSView convertPoint:fromView:]`. There is no separate accelerated-vs-raw split as starkly as the Linux [raw vs accelerated pointer][rap] protocols — relative deltas come from the same `NSEvent` (`deltaX`/`deltaY`), and cursor hiding/association uses `CGAssociateMouseAndMouseCursorPosition` from CoreGraphics. Scroll has a precise/non-precise distinction: `-hasPreciseScrollingDeltas` is `YES` for trackpads, and the survey notes non-precise wheel deltas are ~10× coarser, so toolkits branch on the flag (or multiply by 10) — and momentum-phase scrolling (`-momentumPhase`) is a macOS-specific extra that [GLFW][glfw] drops.

---

## Coordinates & scaling

AppKit's native unit is the **point** — a logical, device-independent coordinate ([logical vs physical coords][lpc]). The example's `480 × 320` content rect is points, not pixels. The bridge to pixels is [`backingScaleFactor`][backingscalefactor] on `NSWindow`/`NSScreen`, and it is **integer-only in practice** (1.0 on a standard display, 2.0 on a Retina display); the OS composites everything else, so there is no client-visible fractional scale the way Wayland's `wp_fractional_scale_v1` exposes one. A renderer converts a points rect to backing pixels with `-[NSView convertRectToBacking:]` and sets the layer's `contentsScale` to match — [GLFW][glfw] does exactly this on Cocoa.

> [!NOTE]
> **Origin convention.** AppKit's default coordinate space is **y-up** — the origin is the bottom-left of the screen/view, the opposite of Win32, X11, and Wayland's top-left. The example's `NSPoint(120, 120)` therefore positions the window measured up from the bottom of the screen. A view can flip to y-down by overriding `-isFlipped`.

Because the scale factor is integer and OS-composited, the [created-at-wrong-scale and mixed-DPI-migration][scale-factor] hazards that bite Wayland and X11 are largely absent on macOS: moving a window between a 1× and a 2× display fires `windowDidChangeBackingProperties:` and the OS handles the rest. This is the simplest scaling story of any platform in the survey.

---

## Decorations & multi-window / popups

**Decorations are server-side** ([CSD vs SSD][csd]). The titlebar, the red/yellow/green "traffic-light" buttons, the resize border, and the drop shadow are drawn by the window server; the application selects _which_ of them appear through the `NSWindowStyleMask` passed to the initializer (the example asks for `Titled | Closable | Resizable`). There is no negotiation handshake as on Wayland — the app states the mask and the OS honours it. An app that wants custom chrome uses `NSWindowStyleMaskBorderless` (or `NSWindowStyleMaskFullSizeContentView` plus a transparent titlebar) and draws into the content view itself, but the _default_ is OS-drawn.

**Multi-window** is first-class: any number of top-level `NSWindow`s share the one `NSApplication` and run loop. Window stacking is controlled by **window levels** (`-[NSWindow setLevel:]` with `NSNormalWindowLevel`, `NSFloatingWindowLevel`, `NSStatusWindowLevel`, …) — this is what [GLFW][glfw] maps its always-on-top "floating" hint onto. Parent/child relationships use `-addChildWindow:ordered:`.

**Popups / menus.** AppKit has real native menu and popup infrastructure that the cross-platform layer in this survey mostly does _not_ use: `NSMenu`/`-popUpContextMenu:withEvent:forView:` for context menus, and `NSPanel` (a borderless utility `NSWindow` subclass) for transient surfaces. Dismiss-on-click-outside and the nested tracking loop are handled by AppKit's menu/event machinery, not by the client. This is unlike the X11 [override-redirect vs Wayland xdg_popup grab][orx] fork the Linux backends must navigate — on macOS the grab/dismiss is the framework's job. Pure windowing libraries ([winit][winit-mac], [GLFW][glfw]) expose none of this and leave menus to the app.

---

## Clipboard & drag-and-drop

**Clipboard** is the [`NSPasteboard`][nspasteboard] API: a named pasteboard (`NSPasteboardNameGeneral` for the clipboard) holds typed items, declared with `-declareTypes:owner:` and written/read by Uniform Type Identifier (`NSPasteboardTypeString`, `…PNG`, …). It is a typed, pull-on-demand model (an owner can promise data and supply it lazily), conceptually closer to Win32's delayed-rendering clipboard than to X11's selection-and-`INCR` chunking. [GLFW][glfw]'s macOS clipboard is `NSPasteboard`; [Qt 6][qt6]'s `qmacclipboard.mm` wraps it.

**Drag-and-drop** is `NSPasteboard`-backed too. A drag **source** starts a session with `-[NSView beginDraggingSessionWithItems:event:source:]`, yielding an [`NSDraggingSession`][nsdraggingsession]; a drag **destination** view adopts the `NSDraggingDestination` informal protocol (`-draggingEntered:`, `-performDragOperation:`) and registers the types it accepts with `-registerForDraggedTypes:`. This is a full bidirectional DnD model (both source and destination), richer than the receive-only file-drop path several toolkits expose — [winit][winit-mac] and [GLFW][glfw] implement only the destination side (file drops) on Cocoa, reading `NSURL` file URLs in `-performDragOperation:`.

---

## What toolkits build on this

Every macOS-capable toolkit in the survey bottoms out in the same AppKit calls this survey describes:

- **[GLFW][glfw]** — creates a `GLFWWindow : NSWindow` subclass, drives the loop by manually pulling `-nextEventMatchingMask:untilDate:inMode:dequeue:` (it does **not** call `[NSApp run]`), uses `backingScaleFactor` + `-convertRectToBacking:` for HiDPI, implements `NSTextInputClient` (but drops the pre-edit), and reads `NSPasteboard` for clipboard/file-drop.
- **[SDL3][sdl3]** — its `SDL_cocoawindow.m` builds the `NSWindow`, `SDL_cocoaevents.m` runs the pump, and it enforces the main-thread rule with `SDL_RunOnMainThread`; IME goes through `NSTextInputClient`.
- **[Qt 6][qt6]** — the `qcocoa` QPA plugin wraps `NSWindow` (`qcocoawindow.mm`), the event dispatcher wraps `CFRunLoop` (`qcocoaeventdispatcher.mm`), text input wraps the input client (`qnsview_complextext.mm`), and the clipboard wraps `NSPasteboard` (`qmacclipboard.mm`).
- **[JUCE][juce]** — its `juce_NSViewComponentPeer_mac.mm` is an `NSView`/`NSWindow` peer; it runs a per-screen `CVDisplayLink` for vsync and carries the `setReleasedWhenClosed`/retain dance for plugin embedding.

[winit][winit-mac] (its `winit-appkit` backend) is the cleanest reference for the "cede the loop to `[NSApp run]`, hang `CFRunLoop` observers, enforce `MainThreadMarker`" pattern.

---

## Sources

- **AppKit framework reference** (Apple Developer, Wayback-pinned — Apple docs are bot-hostile to the link checker): [AppKit overview][appkit], [`NSApplication`][nsapplication], [`NSApplicationMain`][nsapplicationmain], [`NSWindow`][nswindow], [`NSView`][nsview], [`NSResponder`][nsresponder], [`NSEvent`][nsevent], [`NSPasteboard`][nspasteboard], [`NSDraggingSession`][nsdraggingsession], [`backingScaleFactor`][backingscalefactor], [`NSTextInputClient`][nstextinput], [`CVDisplayLink`][cvdisplaylink], [`CADisplayLink`][cadisplaylink].
- **D ↔ Objective-C interop** — the D specification's [_Interfacing to Objective-C_][dlang-objc] (`extern(Objective-C)` + `@selector`) and the [`objective-d`][objd] package (runtime linkage + autorelease pool; the example imports its `objc.autorelease`).
- **This survey's example** — [`./example/app.d`](./example/app.d).
- **Cross-references** — the [window-system index][index] and shared [concepts][concepts]; the macOS rows of [platform-gotchas][gotchas]; the per-toolkit AppKit findings in [GLFW][glfw], [SDL3][sdl3], [Qt 6][qt6], [JUCE][juce], [winit][winit-mac], [sokol][sokol], [GTK 4][gtk4], [Avalonia][avalonia], [Flutter][flutter], [Uno][uno].

<!-- References -->

<!-- Survey siblings (deep-dives one level up) -->

[index]: ../../index.md
[concepts]: ../../concepts.md
[gotchas]: ../../platform-gotchas.md
[winit-mac]: ../../winit.md
[glfw]: ../../glfw.md
[sdl3]: ../../sdl3.md
[qt6]: ../../qt6.md
[gtk4]: ../../gtk4.md
[juce]: ../../juce.md
[sokol]: ../../sokol.md
[avalonia]: ../../avalonia.md
[flutter]: ../../flutter-engine.md
[uno]: ../../uno-platform.md

<!-- Concept anchors -->

[csd]: ../../concepts.md#csd-vs-ssd
[skv]: ../../concepts.md#scancode-keysym-virtualkey
[lpc]: ../../concepts.md#logical-vs-physical-coords
[scale-factor]: ../../concepts.md#scale-factor
[pec]: ../../concepts.md#pre-edit-composition
[orx]: ../../concepts.md#override-redirect-vs-xdg-popup-grab
[rap]: ../../concepts.md#raw-vs-accelerated-pointer
[nbnw]: ../../concepts.md#no-buffer-no-window
[fcv]: ../../concepts.md#frame-callback-vsync
[rvc]: ../../concepts.md#readiness-vs-completion-windowing

<!-- Cross-tree -->

[async-io]: ../../../async-io/index.md

<!-- D / objective-d primary sources -->

[dlang-objc]: https://dlang.org/spec/objc_interface.html
[objd]: https://github.com/KitsunebiGames/objective-d

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[appkit]: https://web.archive.org/web/20260603130837/https://developer.apple.com/documentation/appkit
[nsapplication]: https://web.archive.org/web/20260426230241/https://developer.apple.com/documentation/appkit/nsapplication
[nsapplicationmain]: https://web.archive.org/web/20260429182717/https://developer.apple.com/documentation/appkit/nsapplicationmain(_:_:)
[nswindow]: https://web.archive.org/web/20260503224546/https://developer.apple.com/documentation/appkit/nswindow
[nsview]: https://web.archive.org/web/20260417192253/https://developer.apple.com/documentation/appkit/nsview
[nsresponder]: https://web.archive.org/web/20260603234149/https://developer.apple.com/documentation/appkit/nsresponder
[nsevent]: https://web.archive.org/web/20260415062104/https://developer.apple.com/documentation/appkit/nsevent
[nspasteboard]: https://web.archive.org/web/20260207134741/https://developer.apple.com/documentation/appkit/nspasteboard
[nsdraggingsession]: https://web.archive.org/web/20260105004404/https://developer.apple.com/documentation/appkit/nsdraggingsession
[backingscalefactor]: https://web.archive.org/web/20251102044301/https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor
[nstextinput]: https://web.archive.org/web/20260115025403/https://developer.apple.com/documentation/appkit/nstextinputclient
[cvdisplaylink]: https://web.archive.org/web/20250609094433/https://developer.apple.com/documentation/corevideo/cvdisplaylink
[cadisplaylink]: https://web.archive.org/web/20190614134451/https://developer.apple.com/documentation/quartzcore/cadisplaylink
