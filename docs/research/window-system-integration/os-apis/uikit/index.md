# iOS / iPadOS (UIKit)

The native application framework of iOS, iPadOS, and tvOS: an object-and-delegate Objective-C framework where you do **not** create a desktop window — the system owns the surface. The app supplies a [`UIWindow`][uiwindow] hosting a root [`UIViewController`][uiviewcontroller], attaches it to a system-owned [`UIScene`][uiscene], and cedes the process's main thread to a `CFRunLoop`-backed run loop entered by `UIApplicationMain`. This is the layer the iOS backends of [winit][winit-ios], [SDL3][sdl3], [Flutter][flutter], and [Qt 6][qt6] all reduce to.

**Last reviewed:** June 9, 2026

| Field                    | Value                                                                                                                                                        |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Native API               | **UIKit** (`UIApplication` / `UIWindow` / `UIViewController` / `UIScene` / `UIResponder` / `UITouch`)                                                        |
| Library / framework      | `UIKit.framework` (window/UI) over `Foundation`, `QuartzCore`, and `CoreGraphics`; linked with `-framework UIKit`                                            |
| Header / protocol source | Objective-C class interfaces in `UIKit.framework/Headers/` (e.g. `UIWindow.h`, `UIViewController.h`, `UIScreen.h`); reached from D via `@selector`           |
| Window handle type       | `UIWindow*` (an Objective-C object pointer; not a user-movable desktop window — a full-screen surface attached to a `UIScene`)                               |
| Event-loop primitive     | `UIApplicationMain` driving an `NSRunLoop` backed by [`CFRunLoop`][rvc]; events dispatch through the [responder chain][uiresponder] of `UIResponder` objects |
| Coordinate unit          | **Points** (logical, device-independent); pixels via [`UIScreen.scale`][uiscreen] / [`contentScaleFactor`][contentscalefactor]                               |
| Decoration owner         | **System** — N/A at this layer: scenes are full-screen and the OS owns all chrome (status bar, home indicator); there is no app-drawn titlebar               |
| Example                  | [`./example/app.d`](./example/app.d)                                                                                                                         |

> [!NOTE]
> **There are no user-created windows on iOS.** Unlike [AppKit][appkit] on macOS, an iOS app does not open, move, resize, or decorate top-level windows. The system creates a full-screen `UIScene`, the app installs exactly one `UIWindow` per scene as the [backdrop][uiwindow] for its view hierarchy, and the OS owns placement, the status bar, multitasking, and all chrome. A `UIWindow` is "window" in name only — it is a root `UIView` container, not a draggable frame. This is the same system-owns-the-surface model as [Android][android], reached through a very different (Objective-C, not JNI) API.

---

## What it is

UIKit is the iOS/iPadOS application framework: it owns the application object, the window/view hierarchy, the event loop, drawing, touch, and the text-input stack. Apple's one-line summary is verbatim:

> Construct and manage a graphical, event-driven user interface for your iOS, iPadOS, or tvOS app.

— [UIKit framework overview][uikit], Apple Developer Documentation

Like [AppKit][appkit], UIKit is object-oriented Objective-C and **delegate-driven**: rather than subclass everything, an app installs delegate objects ([`UIApplicationDelegate`][uiappdelegate], `UISceneDelegate`) that UIKit calls back at lifecycle points, and routes input through a **responder chain** of [`UIResponder`][uiresponder] objects ("An abstract interface for responding to and handling events") that runs view → view controller → window → application. The window itself is, per Apple, "The backdrop for your app's user interface and the object that dispatches events to your views" ([`UIWindow`][uiwindow]).

Two facts dominate the rest of this survey. First, **UIKit is main-thread-only**: `UIApplication`, `UIWindow`, and `UIView` must be created and messaged from the main thread, and the run loop runs there. Second, **the OS owns the loop and the surface** — `UIApplicationMain` does not return, and the window/scene are handed to the app rather than created by it. Together these put iOS at the **completion/callback** end of the [readiness-vs-completion windowing][rvc] fork, alongside macOS and the Web.

The example here reaches UIKit through D's built-in `extern(Objective-C)` interop, where the D compiler emits real Objective-C message sends for methods tagged with the `@selector` attribute. The D specification states the contract verbatim:

> D supports interfacing with Objective-C. It supports protocols, classes, subclasses, instance variables, instance methods and class methods. Platform support might vary between different compilers.

— [_Interfacing to Objective-C_][dlang-objc], the D language specification

> [!IMPORTANT]
> **D can call Objective-C but cannot define an Objective-C class.** A real iOS app is launched by `UIApplicationMain`, which instantiates an **app-delegate Objective-C class** named in the bundle. D's `extern(Objective-C)` interop can _send messages to_ existing Objective-C classes, but it cannot _declare a new_ Objective-C class with the runtime metadata `UIApplicationMain` requires. So a pure-D UIKit app cannot supply the delegate — the delegate is normally written in Objective-C or Swift and calls into D. The example therefore demonstrates the UIKit bindings and the window/view-controller construction, not a full app launch.

> [!NOTE]
> Core Graphics geometry types (`CGPoint`, `CGSize`, `CGRect`) are plain C structs of `CGFloat` (a `double` on 64-bit), **not** Objective-C objects, so the example declares them `extern(C)` and passes them by value. Only the classes (`NSObject` and its descendants) cross the Objective-C message-send boundary.

---

## The minimal program

The example, [`./example/app.d`](./example/app.d), is the irreducible UIKit object graph a real app builds: a `UIWindow` sized to the screen, a root `UIViewController`, then `makeKeyAndVisible`. It declares the UIKit classes it needs as `extern(Objective-C)` with `@selector`-tagged methods, then runs:

1. **Screen bounds.** `UIScreen.mainScreen().bounds()` sends `+[UIScreen mainScreen]` then `-bounds`, returning the main screen's rectangle as a `CGRect` in **points** (logical units — see [Coordinates & scaling](#coordinates--scaling)). On iOS the app does not pick a window size; it adopts the screen's.
2. **The window.** `UIWindow.alloc().initWithFrame(bounds)` sends `+alloc` then `-initWithFrame:`, creating the full-screen `UIWindow` that will host the view hierarchy. There is no style mask and no decoration choice — the scene is full-screen and the OS owns the chrome.
3. **The root view controller.** `UIViewController.alloc().init()` builds the [root `UIViewController`][uiviewcontroller]; `win.setRootViewController(root)` installs it. Every `UIWindow` must have a root view controller — it is the top of the responder chain for the window's content and the owner of its view's lifecycle.
4. **Show.** `win.makeKeyAndVisible()` makes the window key (the one that receives events) and visible — the UIKit analogue of AppKit's `-makeKeyAndOrderFront:`. On a live device this is the moment the view hierarchy is attached to the scene's surface.
5. **Report + exit.** The example prints the adopted point dimensions with `printf` and returns `0`. A real app would never reach a `return` here — it would have handed control to `UIApplicationMain` long before.

> [!IMPORTANT]
> **This example is cross-compiled for the iOS Simulator, not run on the host.** iOS code cannot run on the Linux/`x86_64` host, so CI verification is a **compile-for-target** check: the canonical build is `ldc2 -mtriple=arm64-apple-ios<ver>-simulator app.d -L-framework -LUIKit -L-framework -LFoundation` with the official LDC (which bundles the iOS-Simulator druntime). A **full Simulator run** is a documented manual step: it needs (a) an **app-delegate Objective-C class** (which D cannot define — see [What it is](#what-it-is)), (b) an `Info.plist` + app bundle, and (c) launch through `simctl` (`xcrun simctl install` / `launch`) on a macOS host with Xcode. The example deliberately stops at building the binding graph so it stays CI-checkable without a Simulator.

---

## Window creation & lifecycle

There is **no user-facing window creation** — that is the defining feature, shared with [Android][android]. The app instantiates one `UIWindow` per scene as the content backdrop, but the _scene_ that gives the window a place on screen is created and owned by the system. Since iOS 13 the unit of UI is the [`UIScene`][uiscene] — "An object that represents one instance of your app's user interface" — and a window is attached to a `UIWindowScene`. An iPad app may have several scenes (multitasking, Stage Manager); a phone app typically has one.

The lifecycle is **callback-driven through two delegates**:

- **`UIApplicationDelegate`** ([`UIApplicationDelegate`][uiappdelegate]) — process-level milestones: `application:didFinishLaunchingWithOptions:`, and (pre-scene) the foreground/background transitions.
- **`UISceneDelegate`** — per-scene lifecycle, which is where the foreground/background state machine lives on modern iOS: `sceneWillEnterForeground:`, `sceneDidBecomeActive:`, `sceneWillResignActive:`, `sceneDidEnterBackground:`, and `sceneDidDisconnect:`. Apple's [app life cycle guide][applifecycle] documents the states (not-running → foreground-inactive → foreground-active → background → suspended) and the rule that a backgrounded app must stop work quickly or be suspended/terminated.

The hard rule the lifecycle imposes is the iOS analogue of Android's `INIT_WINDOW`/`TERM_WINDOW` churn: **a scene can connect and disconnect many times over a process's life**, and the surface can vanish when the app is backgrounded. A renderer must build and tear down to match scene connection/disconnection and foreground/background transitions, not assume a window that exists for the whole process. This is the same lesson [winit's][winit-ios] split of surface-creation from resume/suspend encodes on every platform.

App startup goes through `UIApplicationMain`, which reads the bundle, creates the `UIApplication`, instantiates the named **app-delegate Objective-C class**, loads the scene configuration, and enters the run loop. Because D cannot define that delegate class (see [What it is](#what-it-is)), `UIApplicationMain` is described here rather than linked as a callable symbol from D; the example builds the window graph that the delegate would otherwise own.

---

## Event loop & frame pacing

The loop is the one `UIApplicationMain` enters and never leaves: an `NSRunLoop` layered on Core Foundation's [`CFRunLoop`][rvc], the same primitive [AppKit][appkit] uses. The OS owns the loop; the app is called back through its delegates and the responder chain. This is the **completion/callback** end of the [readiness-vs-completion][rvc] fork, and it is precisely why [winit][winit-ios] abandoned its old poll-iterator model — on iOS (as on macOS and the Web) you cannot run your own top-level loop, so winit hangs `CFRunLoop` observers off the UIKit run loop and surfaces an `ApplicationHandler` callback model instead.

> [!IMPORTANT]
> **The run loop never returns to your `main`.** As on macOS, teardown happens in delegate callbacks (`sceneDidDisconnect:`, `applicationWillTerminate:`), not after the call that started the loop. A binding must move all cleanup into callbacks. The example sidesteps this entirely by not calling `UIApplicationMain`.

**Frame pacing.** The run loop paces input, not redraw. Vsync comes from a separate, higher-priority source: [`CADisplayLink`][cadisplaylink] ([frame-callback / vsync][fcv]), "A timer object that allows your app to synchronize its drawing to the refresh rate of the display." A renderer creates a `CADisplayLink` with a target/selector, adds it to the run loop, and draws one frame per callback; the link is paused automatically when the app is backgrounded or the screen is off, the iOS equivalent of how a Wayland `wl_surface.frame` callback throttles a hidden surface to zero. On ProMotion (120 Hz) displays the app declares its preferred frame-rate range via `preferredFrameRateRange`. `CADisplayLink` is the long-standing UIKit class that macOS only recently adopted (after deprecating `CVDisplayLink`), so the iOS pacing story is the simpler, older one. The example does no rendering, so it installs no display link.

> [!NOTE]
> An app that must also service its own work — an [async-io][async-io] runtime, a network socket — faces the same "the OS owns the blocking wait" trap as macOS: there is no portable way to inject an arbitrary fd into the UIKit run loop's wait set, so a custom event source is either driven from a `CFRunLoopSource`/timer hung off the main run loop or run on a separate thread.

---

## Input

**Touch is primary.** UIKit's native input is multi-touch, delivered as [`UITouch`][uitouch] objects through the responder chain. A `UIView`/`UIViewController` receives `touchesBegan:withEvent:`, `touchesMoved:withEvent:`, `touchesEnded:withEvent:`, and `touchesCancelled:withEvent:`; each `UITouch` carries `locationInView:` (in **points**, window/view-relative), a `phase`, a `force` (on supported displays), and `majorRadius`. Touch is **absolute by construction** — there is no [accelerated-vs-raw / relative-motion][rap] distinction at this layer the way desktop pointers have it; pointer capture and trackpad-relative motion on iPad are higher-level concerns.

**Gestures.** Most apps do not decode raw touches; they attach a [`UIGestureRecognizer`][uigesturerecognizer] (`UITapGestureRecognizer`, `UIPanGestureRecognizer`, `UIPinchGestureRecognizer`, …) to a view, which recognizes higher-level gestures from the touch stream and fires a target/action. This is the idiomatic input path and the one cross-platform toolkits map their pan/zoom/tap abstractions onto.

> [!NOTE]
> **Keysyms barely apply on iOS.** The [scancode / keysym / virtual-key][skv] split is a desktop-keyboard concept; the primary iOS input is touch, which has none of it. A connected hardware keyboard is surfaced as `UIKey` (with `keyCode`, `charactersIgnoringModifiers`, and `modifierFlags`) routed through `pressesBegan:withEvent:` on the responder chain — a secondary path, not the main one. As on macOS, there is no X11-style keysym layer; the layout-dependent text comes from the text-input system below.

**IME / text input & the on-screen keyboard.** A view that wants text adopts the [`UITextInput`][uitextinput] protocol (the iOS counterpart of AppKit's `NSTextInputClient`) and becomes the **first responder**; becoming first responder is what raises the **software keyboard**. The composition pipeline — provisional **marked (pre-edit) text** versus the final commit ([pre-edit / composition][pec]) — flows through `UITextInput`'s `setMarkedText:selectedRange:` / `unmarkUText` and the [`UITextInputDelegate`][uitextinputdelegate] callbacks (`textWillChange:` / `textDidChange:` / `selectionDidChange:`), with the candidate bar positioned by the system. CJK, dead-key, dictation, and emoji input all ride this protocol. A bespoke rendering view (a Metal layer with no `UITextInput` adoption) gets **no** keyboard and **no** IME — the same trap toolkits hit on macOS — so a windowing layer that wants text input must implement `UITextInput` on its content view, exactly as [SDL3][sdl3] and [Flutter][flutter] do.

---

## Coordinates & scaling

UIKit's native unit is the **point** — a logical, device-independent coordinate ([logical vs physical coords][lpc]). The example's screen `bounds` are points, not pixels. The bridge to pixels is [`UIScreen.scale`][uiscreen] (and the per-view [`contentScaleFactor`][contentscalefactor]); Apple's own description of the factor is verbatim:

> The natural scale factor associated with the screen.

— [`UIScreen.scale`][uiscreen]; its discussion adds that the value is `3.0`, `2.0`, or `1.0` (one point maps to nine, four, or one pixel respectively).

The factor is therefore **integer-only in practice** — `1.0`, `2.0`, or `3.0` — and the OS composites everything else, so there is no client-visible fractional scale the way Wayland's `wp_fractional_scale_v1` exposes one ([scale-factor][sf]). A renderer sizes its drawable off the physical pixel count (`bounds.size × scale`, or by setting the backing `CAMetalLayer`/`CAEAGLLayer`'s `contentsScale` to the view's `contentScaleFactor`), never off the logical point size, or it renders blurry — the same rule the cross-platform survey keeps re-learning.

> [!NOTE]
> **No mixed-DPI migration on iOS.** Because a scene is full-screen on one display and the scale is a fixed property of that display, the [mixed-DPI migration][sf] hazard that bites X11 (and that drives `WM_DPICHANGED` on Win32) does not arise: there is no dragging a window between differently-scaled monitors. The scale story on iOS is the simplest of any platform in the survey — read `scale` once per scene/display.

---

## Decorations & multi-window/popups

> [!NOTE]
> **N/A at this layer — the system owns all chrome.** There is no titlebar, border, resize handle, or close-button concept in UIKit ([CSD vs SSD][csd] does not apply): a scene is **full-screen** (or a fixed multitasking tile), and the OS draws the status bar and home indicator. A `UIWindow` is the content backdrop, not a framed window, and the app cannot draw its own titlebar because there is no frame to replace. This is purest server-side ownership, the same as [Android][android] and even less negotiable than [AppKit][appkit], where an app can at least pick an `NSWindowStyleMask`.

**Multi-window** on iOS means **multi-scene**, and it is an iPad/iPadOS feature (Split View, Slide Over, Stage Manager, external displays). Each window is a separate `UIScene` the system creates in response to user multitasking gestures or `UIApplication`'s `requestSceneSessionActivation:`; the app does not freely spawn top-level windows the way a desktop app calls `CreateWindowEx`/`alloc+init`. On iPhone, an app is effectively single-scene.

**Popups, menus, and sheets** are UIKit **presentation**, not separate OS sub-surfaces. Alerts (`UIAlertController`), action sheets, context menus (`UIContextMenuInteraction`), and modal sheets are presented _within_ the scene's window via `presentViewController:animated:completion:` and a presentation/transition system; dismiss-on-tap-outside is handled by UIKit. There is therefore **no analogue** of the [X11 override-redirect vs Wayland xdg_popup grab][orx] fork that the Linux backends must navigate — on iOS, popups never become real OS windows, so the grab/dismiss is entirely the framework's job (closer to the in-canvas approach toolkits like [Flutter][flutter] take everywhere).

---

## Clipboard & drag-and-drop

**Clipboard** is the [`UIPasteboard`][uipasteboard] API — "An object that helps a user share data from one place to another within your app, and from your app to other apps." The system `UIPasteboard.general` holds typed items keyed by Uniform Type Identifier (`public.utf8-plain-text`, `public.png`, …), written and read through `setItems:` / `items` and the convenience `string`/`image`/`url` accessors. It is a typed, multi-item model, conceptually the same shape as macOS's `NSPasteboard`.

**Drag-and-drop** is an **iPad** feature ([`UIDragInteraction`][uidraginteraction]). A drag **source** view attaches a `UIDragInteraction` and supplies `UIDragItem`s (each backed by an `NSItemProvider`) via the `UIDragInteractionDelegate`; a **destination** attaches a `UIDropInteraction` and accepts items through the `UIDropInteractionDelegate`. This is a full bidirectional model (source and destination), and it is **iPad-only** — there is no system drag-and-drop on iPhone — so a cross-platform layer treats it as an iPad capability, not a universal iOS one.

> [!NOTE]
> Anything that is a system _service_ rather than a windowing primitive — share sheets (`UIActivityViewController`), the keyboard, multitasking — is owned by UIKit/the system, so a reusable windowing layer on iOS necessarily routes through these UIKit objects rather than a low-level surface API. The structural shape (the OS hands you a surface and an input stream and owns everything else) is the same as [Android][android], reached through Objective-C instead of JNI.

---

## What toolkits build on this

Every iOS-capable toolkit in the survey bottoms out in the same UIKit object graph this survey describes — a `UIWindow` + root `UIViewController` under a system `UIScene`, driven by the `UIApplicationMain`/`CFRunLoop` loop:

- **[winit][winit-ios]** — its `winit-uikit` backend creates a `UIWindow` and a UIKit view, cedes the loop to `UIApplicationMain`, and hangs `CFRunLoop` observers off the run loop (the same inversion as its AppKit backend); the `UIWindow`/view is what it hands out as the iOS `RawWindowHandle`, paced by `CADisplayLink`.
- **[SDL3][sdl3]** — its `SDL_uikitwindow.m`/`SDL_uikitviewcontroller.m` build the `UIWindow` + `UIViewController`, run the loop via the UIKit run loop (with `SDL_MAIN_USE_CALLBACKS` for the OS-owns-the-loop case), implement `UITextInput` for the on-screen keyboard/IME, and deliberately report the surface in **logical points** on iOS (the [logical-coordinate][lpc] side of its per-platform unit choice).
- **[Flutter][flutter]** — its darwin embedder shares a UIKit/AppKit core; on iOS a `FlutterViewController` (a `UIViewController`) hosts the engine's surface, the engine paces off `CADisplayLink`, and text/IME is bridged through `UITextInput`.
- **[Qt 6][qt6]** — the `qios` QPA plugin wraps `UIWindow`/`UIView` (`quiview.mm`, `qiosviewcontroller.mm`), the event dispatcher wraps `CFRunLoop`, and text input wraps `UITextInput`.

[winit][winit-ios] is again the cleanest reference for the "cede the loop to the OS, hang `CFRunLoop` observers, treat surface creation as a scene-lifecycle event" pattern that iOS forces.

---

## Sources

- **UIKit framework reference** (Apple Developer, Wayback-pinned — Apple docs are bot-hostile to the link checker): [UIKit overview][uikit], [`UIWindow`][uiwindow], [`UIViewController`][uiviewcontroller], [`UIScene`][uiscene], [`UIApplicationDelegate`][uiappdelegate], [app life cycle guide][applifecycle], [`UIResponder`][uiresponder], [`UITouch`][uitouch], [`UIGestureRecognizer`][uigesturerecognizer], [`UITextInput`][uitextinput], [`UITextInputDelegate`][uitextinputdelegate], [`UIScreen`][uiscreen], [`contentScaleFactor`][contentscalefactor], [`UIPasteboard`][uipasteboard], [`UIDragInteraction`][uidraginteraction], and [`CADisplayLink`][cadisplaylink] (`QuartzCore`).
- **D ↔ Objective-C interop** — the D specification's [_Interfacing to Objective-C_][dlang-objc] (`extern(Objective-C)` + `@selector`); the call-not-define limitation that forces the app delegate into Objective-C/Swift.
- **This survey's example** — [`./example/app.d`](./example/app.d).
- **Cross-references** — the [window-system index][index] and shared [concepts][concepts]; the iOS rows of [platform-gotchas][gotchas]; the sibling [AppKit][appkit] and [Android][android] OS-API surveys; the per-toolkit iOS findings in [winit][winit-ios], [SDL3][sdl3], [Flutter][flutter], [Qt 6][qt6]; cross-tree [async-io][async-io].

<!-- References -->

<!-- Survey siblings (deep-dives one level up) -->

[index]: ../../index.md
[concepts]: ../../concepts.md
[gotchas]: ../../platform-gotchas.md
[winit-ios]: ../../winit.md
[sdl3]: ../../sdl3.md
[qt6]: ../../qt6.md
[flutter]: ../../flutter-engine.md

<!-- Sibling OS-API surveys -->

[appkit]: ../appkit/index.md
[android]: ../android/index.md

<!-- Concept anchors -->

[csd]: ../../concepts.md#csd-vs-ssd
[skv]: ../../concepts.md#scancode-keysym-virtualkey
[lpc]: ../../concepts.md#logical-vs-physical-coords
[sf]: ../../concepts.md#scale-factor
[pec]: ../../concepts.md#pre-edit-composition
[orx]: ../../concepts.md#override-redirect-vs-xdg-popup-grab
[rap]: ../../concepts.md#raw-vs-accelerated-pointer
[fcv]: ../../concepts.md#frame-callback-vsync
[rvc]: ../../concepts.md#readiness-vs-completion-windowing

<!-- Cross-tree -->

[async-io]: ../../../async-io/index.md

<!-- D primary source -->

[dlang-objc]: https://dlang.org/spec/objc_interface.html

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[uikit]: https://web.archive.org/web/20251231131637/https://developer.apple.com/documentation/uikit/
[uiwindow]: https://web.archive.org/web/20260108001523/https://developer.apple.com/documentation/uikit/uiwindow
[uiviewcontroller]: https://web.archive.org/web/20260104211547/https://developer.apple.com/documentation/uikit/uiviewcontroller
[uiscene]: https://web.archive.org/web/20251116202523/https://developer.apple.com/documentation/uikit/uiscene
[uiappdelegate]: https://web.archive.org/web/20250304004010/https://developer.apple.com/documentation/uikit/uiapplicationdelegate
[applifecycle]: https://web.archive.org/web/20240910072047/https://developer.apple.com/documentation/uikit/app_and_environment/managing_your_app_s_life_cycle
[uiresponder]: https://web.archive.org/web/20260603234149/https://developer.apple.com/documentation/uikit/uiresponder
[uitouch]: https://web.archive.org/web/20250311180556/https://developer.apple.com/documentation/uikit/uitouch
[uigesturerecognizer]: https://web.archive.org/web/20250609161547/https://developer.apple.com/documentation/uikit/uigesturerecognizer
[uitextinput]: https://web.archive.org/web/20250609162313/https://developer.apple.com/documentation/uikit/uitextinput
[uitextinputdelegate]: https://web.archive.org/web/20250213080155/https://developer.apple.com/documentation/uikit/uitextinputdelegate
[uiscreen]: https://web.archive.org/web/20250609162015/https://developer.apple.com/documentation/uikit/uiscreen
[contentscalefactor]: https://web.archive.org/web/20251115125849/https://developer.apple.com/documentation/uikit/uiview/contentscalefactor
[uipasteboard]: https://web.archive.org/web/20250604034624/https://developer.apple.com/documentation/uikit/uipasteboard
[uidraginteraction]: https://web.archive.org/web/20251008154703/https://developer.apple.com/documentation/uikit/uidraginteraction
[cadisplaylink]: https://web.archive.org/web/20250605141835/https://developer.apple.com/documentation/quartzcore/cadisplaylink
