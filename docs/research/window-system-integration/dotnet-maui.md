# .NET MAUI (C# / .NET)

Microsoft's cross-platform UI framework and the successor to Xamarin.Forms: it **wraps each platform's native UI stack** behind a thin C# `handler` abstraction and owns essentially _none_ of the windowing layer itself — there is no MAUI window server, no MAUI event loop, and (deliberately) no Linux desktop target.

| Field                  | Value                                                                                                                                                                 |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit studied | [`dotnet/maui`][maui-repo] @ `c389325ecfebf1d07b03d9a928ebf921a78670c7` (main, June 8, 2026)                                                                          |
| Language               | C# (.NET 8/9/10); platform code compiled per-TFM with `#if` guards                                                                                                    |
| License                | MIT                                                                                                                                                                   |
| Repository             | [dotnet/maui][maui-repo]                                                                                                                                              |
| Documentation          | [Supported platforms][supported-platforms] / [Handlers][handlers-docs]                                                                                                |
| Category               | Native-control-wrapping framework (delegating windowing to per-platform UI stacks)                                                                                    |
| Platforms covered      | Windows (WinUI 3 / Windows App SDK), macOS (**Mac Catalyst**, _not_ AppKit), iOS, Android, Tizen (Samsung)                                                            |
| Loop ownership         | **None** — MAUI never owns a loop; it lives inside `CFRunLoop`/`NSRunLoop` (iOS/Catalyst), the Win32 message pump (WinUI 3), and the Android `Looper`/`Handler` queue |
| Repo paths (platform)  | `src/Core/src/Platform/{Windows,iOS,Android,Tizen}/`, `src/Core/src/Handlers/`, `src/Core/src/Dispatching/`                                                           |

> [!NOTE]
> This is the **opposite philosophy to Avalonia**. Where Avalonia draws every pixel itself and talks to Win32/X11/Wayland/AppKit directly, MAUI instantiates _native widgets_ (`UITextField`, `Android.Widget.EditText`, WinUI `TextBox`) and lets the underlying OS run the window, the loop, input, IME, and decorations. The interesting findings here are therefore about **what is gained and lost by not owning the windowing layer** — and about the seams where that abstraction leaks.

---

## Overview

### What it solves

.NET MAUI lets a single C# codebase target four OS UI stacks. The framework's own positioning makes the wrapping stance explicit — from [`docs/supported-platforms.md`][supported-platforms]:

> .NET Multi-platform App UI (.NET MAUI) apps can be written for the following platforms:
>
> - Android 5.0 (API 21) or higher is required.
> - iOS 12.2 or higher is required.
> - macOS 12 or higher, using Mac Catalyst.
> - Windows 11 and Windows 10 version 1809 or higher, using Windows UI Library (WinUI) 3.

Three load-bearing facts hide in that list: macOS is reached via **Mac Catalyst** (the UIKit-on-Mac compatibility layer), _not_ AppKit; Windows is **[WinUI 3][winui3] / Windows App SDK**, not raw Win32 or WPF; and **Linux is simply not there**. Tizen is mentioned separately as "Additional platform support … provided by Samsung." MAUI's job is to map a portable `IWindow`/`IView` tree onto whatever each of those stacks calls a window and a view.

### Design philosophy

- **Wrap, don't reimplement.** Every cross-platform element (`IWindow`, `IButton`, `IEntry`) has a per-platform _handler_ that creates and drives a real native control. The window is no exception: the handler's `PlatformView` is literally `Microsoft.UI.Xaml.Window`, `UIKit.UIWindow`, or `Android.App.Activity` — see the `using PlatformView =` aliases in [`WindowHandler.cs`][wh-shared].
- **No loop, no surface, no decorations of its own.** Because the platform owns the window, it also owns the event loop, frame pacing, DPI, IME, server-side vs client-side decorations ([CSD vs SSD][csd-vs-ssd]), and the [no-buffer-no-window][nbnw] dance on Wayland — none of which MAUI ever sees, because MAUI never runs on Wayland.
- **A property/command mapper instead of a render tree.** State flows one-way: a virtual-view property change is dispatched through a `PropertyMapper` to a static `MapXxx` method that pokes the native control. This is the architectural heir to Xamarin.Forms' _renderers_, redesigned as the lighter **handler** model (see [§10](#10-history-redesigns-known-regrets)).
- **The Dispatcher is the only loop primitive MAUI exposes**, and it is a thin shim over the native main-thread queue (`DispatchQueue.MainQueue`, WinUI `DispatcherQueue`, Android `Handler`).

> [!IMPORTANT]
> Because MAUI delegates the windowing layer wholesale, several dimensions of this study (Wayland specifics, X11 selections, raw pointer motion, frame-callback vsync) **do not apply at the framework level**. That absence is itself the central finding and is documented under each heading rather than skipped.

---

## How it works

### The handler architecture

The base abstraction is [`ElementHandler`][eh-base] (`src/Core/src/Handlers/Element/ElementHandler.cs`) and its generic subclass [`ElementHandler<TVirtualView, TPlatformView>`][eh-of-t]. A handler owns two objects: the cross-platform `VirtualView` (an `IElement`) and the native `PlatformView` (`object`). `SetVirtualView` lazily creates the platform view and runs `ConnectHandler`:

```cs
// src/Core/src/Handlers/Element/ElementHandler.cs (SetVirtualView, abridged)
VirtualView = view;
if (PlatformView is null)
{
    _handlerState = ElementHandlerState.Connecting;
    PlatformView = CreatePlatformElement();   // instantiates the native control
}
// ...
if (setupPlatformView)
    ConnectHandler(PlatformView);             // wires native events
_mapper.UpdateProperties(this, VirtualView);  // pushes every mapped property
```

Property changes are routed through a static `PropertyMapper`. For windows, [`WindowHandler.cs`][wh-shared] declares the map; note how it is **conditionally compiled per platform** — `MaximumWidth`/`TitleBar` only exist on Windows + Mac Catalyst, `FlowDirection`/`IsMinimizable` only on Windows:

```cs
// src/Core/src/Handlers/Window/WindowHandler.cs
public static IPropertyMapper<IWindow, IWindowHandler> Mapper = new PropertyMapper<IWindow, IWindowHandler>(ElementHandler.ElementMapper)
{
    [nameof(IWindow.Title)] = MapTitle,
    [nameof(IWindow.Content)] = MapContent,
    [nameof(IWindow.X)] = MapX,
    // ...
#if WINDOWS || MACCATALYST
    [nameof(IWindow.MaximumWidth)] = MapMaximumWidth,
    [nameof(IWindow.TitleBar)] = MapTitleBar,
#endif
#if WINDOWS
    [nameof(IWindow.FlowDirection)] = MapFlowDirection,
    [nameof(IWindow.IsMinimizable)] = MapIsMinimizable,
#endif
};
```

### The platform-view alias is the whole story

The single most revealing file is [`WindowHandler.cs`][wh-shared], whose header type alias declares exactly what a "MAUI window" _is_ per platform:

```cs
// src/Core/src/Handlers/Window/WindowHandler.cs
#if __IOS__ || MACCATALYST
using PlatformView = UIKit.UIWindow;
#elif MONOANDROID
using PlatformView = Android.App.Activity;
#elif WINDOWS
using PlatformView = Microsoft.UI.Xaml.Window;
#elif TIZEN
using PlatformView = Tizen.NUI.Window;
#endif
```

There is no `#elif LINUX`. The desktop-fallback handler, [`WindowHandler.Standard.cs`][wh-standard], throws:

```cs
// src/Core/src/Handlers/Window/WindowHandler.Standard.cs
protected override object CreatePlatformElement() => throw new NotImplementedException();
```

So a non-mobile, non-Windows build has _no window at all_. The same `NotImplementedException` pattern repeats in [`Dispatcher.Standard.cs`][disp-standard] — MAUI has no loop where it has no platform.

---

## 1. Window creation & lifecycle

There is no portable "create window" call. Each platform constructs its native window object and hands it to a `MauiContext` window scope.

| Platform       | Native window type                                        | Creation call                                           | Creation site                              |
| -------------- | --------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------ |
| Windows        | `Microsoft.UI.Xaml.Window` (subclassed `MauiWinUIWindow`) | `new MauiWinUIWindow(); …; winuiWindow.Activate();`     | [`ApplicationExtensions.cs`][win-appext]   |
| iOS / Catalyst | `UIKit.UIWindow`                                          | `new UIWindow(windowScene)`; then `MakeKeyAndVisible()` | [`ApplicationExtensions.cs`][ios-appext]   |
| Android        | `Android.App.Activity` (the Activity _is_ the "window")   | `Activity.SetContentView(rootView)`                     | [`WindowHandler.Android.cs`][wh-android]   |
| Tizen          | `Tizen.NUI.Window`                                        | resolved from DI; `SetContent(...)`                     | [`WindowHandler.Tizen.cs`][wh-tizen]       |
| Linux/desktop  | —                                                         | `throw new NotImplementedException()`                   | [`WindowHandler.Standard.cs`][wh-standard] |

On **Windows**, [`MauiWinUIWindow`][maui-winui-window] derives from `Microsoft.UI.Xaml.Window` and is created with `new MauiWinUIWindow()` then `.Activate()` ([`ApplicationExtensions.cs`][win-appext], `CreatePlatformWindow`). Its constructor immediately reaches for the [Windows App SDK `AppWindow`][appwindow] and `AppWindowTitleBar` to extend content into the title bar and apply a Mica backdrop:

```cs
// src/Core/src/Platform/Windows/MauiWinUIWindow.cs (constructor, abridged)
if (AppWindowTitleBar.IsCustomizationSupported())
{
    var titleBar = this.GetAppWindow()?.TitleBar;
    if (titleBar is not null)
        titleBar.ExtendsContentIntoTitleBar = true;
}
if (MicaController.IsSupported())
    base.SystemBackdrop = new MicaBackdrop() { Kind = MicaKind.BaseAlt };
SubClassingWin32();   // installs a custom WndProc — see §2 and §9
```

On **iOS/Catalyst**, the lifecycle is driven by UIKit's scene/app-delegate callbacks (see [§2](#2-event-loop)); `CreatePlatformWindow` builds a `UIWindow` and calls `MakeKeyAndVisible()` ([`ApplicationExtensions.cs`][ios-appext]). On **Android**, the `Activity` _is_ the window; `MapContent` calls `Activity.SetContentView(rootView)` ([`WindowHandler.Android.cs`][wh-android]).

**Window-attributes model.** The portable `IWindow` exposes `X`/`Y`/`Width`/`Height`, plus `Minimum*`/`Maximum*`/`IsMinimizable`/`IsMaximizable`/`TitleBar` — but only some platforms implement each. The mapper in [`WindowHandler.cs`][wh-shared] gates size/min-max/title-bar behind `#if WINDOWS || MACCATALYST` and minimizable/maximizable/flow-direction behind `#if WINDOWS`. On **Android and iOS, `X`/`Y`/size are largely no-ops** because the OS positions and sizes app windows; the mapper still runs but the native side often ignores it (e.g. iOS `UpdateX`/`UpdateY` exist but a phone window fills the screen). Positioning on Windows goes through [`WindowExtensions.UpdatePosition`][win-windowext], which calls `AppWindow.Move`, and sizing calls `AppWindow.Resize`; minimize/maximize state flows through the [`OverlappedPresenter`][overlappedpresenter]:

```cs
// src/Core/src/Platform/Windows/WindowExtensions.cs (UpdateIsMinimizable)
if (appWindow?.Presenter is UI.Windowing.OverlappedPresenter presenter)
    presenter.IsMinimizable = window.IsMinimizable;
```

**Surface/handle exposure.** Because the platform owns rendering, there is no MAUI-level GPU surface or `raw-window-handle` equivalent. The closest analogue is `WindowExtensions.GetWindowHandle` ([`WindowExtensions.cs`][win-windowext]), which returns the Win32 `HWND` via `WinRT.Interop.WindowNative.GetWindowHandle` — the documented [retrieve-an-HWND][retrieve-hwnd] escape hatch (see [§9](#9-escape-hatches)).

**Destruction ordering.** `ElementHandler.DisconnectHandler` nulls `PlatformView` _before_ calling the platform `DisconnectHandler(oldPlatformView)` so nobody re-enters a half-torn-down handler ([`ElementHandler.cs`][eh-base]). On Windows, `MauiWinUIWindow.OnClosedPrivate` unhooks `Activated`/`Closed`/`VisibilityChanged`, destroys the window icon via the `DestroyIcon` P/Invoke, and clears the back-reference — a hand-rolled teardown because the underlying Win32 resources are unmanaged.

---

## 2. Event loop

**MAUI owns no event loop.** This is the defining consequence of the wrapping design: the loop belongs to the host UI stack, and MAUI code runs only as callbacks the platform invokes.

- **iOS / Mac Catalyst** — the loop is UIKit's, backed by `CFRunLoop`/`NSRunLoop`. MAUI plugs in via the application delegate ([`MauiUIApplicationDelegate.cs`][ios-appdelegate]) and, for multi-window, the scene delegate ([`MauiUISceneDelegate.cs`][ios-scenedelegate]). Each native callback is `[Export(...)]`-ed and fans the event out to registered lifecycle handlers:

  ```cs
  // src/Core/src/Platform/iOS/MauiUIApplicationDelegate.cs
  [Export("application:didFinishLaunchingWithOptions:")]
  public virtual bool FinishedLaunching(UIApplication application, NSDictionary? launchOptions)
  {
      _application = _services!.GetRequiredService<IApplication>();
      this.SetApplicationHandler(_application, _applicationContext);
      if (!this.HasSceneManifest())
          this.CreatePlatformWindow(_application, application, launchOptions);
      _services?.InvokeLifecycleEvents<iOSLifecycle.FinishedLaunching>(del => del(application!, launchOptions!));
      return true;
  }
  ```

- **Windows** — the loop is the Win32 message pump that WinUI 3 / the Windows App SDK runs. MAUI's `MauiWinUIApplication.OnLaunched` ([`MauiWinUIApplication.cs`][maui-winui-app]) creates the app and the first window. To intercept native messages (the [Win32 modal resize/move loop][win32-modal-resize-loop] is part of this pump), MAUI **subclasses the `WndProc`** — see below and [§9](#9-escape-hatches).

- **Android** — the loop is the Android main-thread `Looper`; the `Activity` lifecycle callbacks drive MAUI.

**Win32 message interception.** `MauiWinUIWindow.SubClassingWin32` ([`MauiWinUIWindow.cs`][maui-winui-window]) routes raw window messages through MAUI so it can implement min/max-size clamping (`WM_GETMINMAXINFO`) and react to title-bar style changes (`WM_STYLECHANGING`):

```cs
// src/Core/src/Platform/Windows/MauiWinUIWindow.cs (OnWindowMessage, abridged)
if (e.MessageId == PlatformMethods.MessageIds.WM_GETMINMAXINFO)
{
    var win = this as IPlatformSizeRestrictedWindow;
    var rect = Marshal.PtrToStructure<PlatformMethods.MinMaxInfo>(e.LParam);
    // clamp rect.MinTrackSize / rect.MaxTrackSize to the user's Minimum*/Maximum*
    Marshal.StructureToPtr(rect, e.LParam, true);
}
```

The subclassing itself is done by `WindowMessageManager` ([`WindowMessageManager.windows.cs`][win-msg-mgr]), which swaps the window procedure with `SetWindowLongPtr(GWL_WNDPROC, …)` and chains to the original via `CallWindowProc` — the standard Win32 subclassing dance, exposed to apps as a lifecycle event (see [§9](#9-escape-hatches)).

**Timers, wakeups & cross-thread injection.** MAUI's only loop-facing primitive is the [`IDispatcher`][idispatcher]. Each platform's `Dispatcher` wraps the native main-thread queue:

```cs
// src/Core/src/Dispatching/Dispatcher.iOS.cs
bool DispatchImplementation(Action action)
{
    _dispatchQueue.DispatchAsync(() => action());   // Grand Central Dispatch main queue
    return true;
}
// src/Core/src/Dispatching/Dispatcher.Windows.cs
bool DispatchImplementation(Action action) =>
    _dispatcherQueue.TryEnqueue(() => action());    // WinUI DispatcherQueue
// src/Core/src/Dispatching/Dispatcher.Android.cs
bool DispatchImplementation(Action action) =>
    _dispatcher.Post(() => action());               // Android Handler/Looper
```

`IsDispatchRequired` checks whether the caller is off the UI thread (`DispatchQueue.CurrentQueueLabel` on iOS; `DispatcherQueue.HasThreadAccess` on Windows), so cross-thread "user-event injection" is just enqueueing onto the native main queue. `DispatcherTimer` likewise delegates to `DispatchAfter` (iOS), `DispatcherQueueTimer` (Windows), or `Handler.PostDelayed` (Android).

**Frame pacing & vsync.** MAUI does not pace frames — the native compositor does. There is no MAUI access to Wayland [frame callbacks][frame-callback-vsync], `CVDisplayLink`/[`CADisplayLink`][cadisplaylink], or DXGI waitable swapchains; redraw coalescing happens inside WinUI's composition, Core Animation, and the Android view system, below MAUI's floor. Where this study's sibling subjects (winit, sokol, SDL3) must explicitly drive vsync, MAUI is entirely passive.

> [!NOTE]
> The [readiness-vs-completion][rvc] axis used elsewhere in this catalog does not apply: MAUI never multiplexes file descriptors or a display connection. Its concurrency story is the .NET thread pool plus the native UI dispatcher, not an I/O reactor — cross-link [async-io][async-io] for the runtime side.

---

## 3. Input

MAUI's input model is **almost entirely delegated to native controls.** It does _not_ implement a scancode/keysym translator, an `xkbcommon` state machine, key-repeat synthesis, or a compose/dead-key engine — those live in UIKit, the Android input stack, and Win32/WinUI, which deliver already-cooked text to the native widgets MAUI hosts.

**The "Keyboard" abstraction is the soft keyboard, not physical keys.** MAUI's portable `Keyboard` type selects an _on-screen keyboard variant / input scope_, mapped to native enums. On iOS it sets `UIKeyboardType`/autocapitalization on the native text input ([`KeyboardExtensions.cs`][ios-kbext]); on Windows it builds a WinUI `InputScope` ([`KeyboardExtensions.cs`][win-kbext]):

```cs
// src/Core/src/Platform/iOS/KeyboardExtensions.cs
else if (keyboard == Keyboard.Email)   textInput.SetKeyboardType(UIKeyboardType.EmailAddress);
else if (keyboard == Keyboard.Numeric) textInput.SetKeyboardType(UIKeyboardType.DecimalPad);
else if (keyboard == Keyboard.Telephone) textInput.SetKeyboardType(UIKeyboardType.PhonePad);
```

**Physical keys exist only as menu accelerators.** The one place MAUI touches the [scancode/keysym/virtual-key][scancode-keysym-virtualkey] model is `KeyboardAccelerator`, used for menu shortcuts. On Windows it maps to the WinUI `VirtualKey`/`VirtualKeyModifiers` enums ([`KeyboardAcceleratorExtensions.cs`][win-kbaccel]):

```cs
// src/Core/src/Platform/Windows/KeyboardAcceleratorExtensions.cs
accelerator.Key = key.ToVirtualKey();          // string -> Windows.System.VirtualKey
accelerator.Modifiers = modifiers.ToVirtualKeyModifiers();
```

The same file records a hard limitation in a comment: "Gamepad virtual keys are not supported." There is no general per-keystroke `KeyDown`/`KeyUp` surface in MAUI core; apps that need raw key events reach into the native control via the handler (see [§9](#9-escape-hatches)).

**IME / text input / composition.** MAUI implements **none** of the [pre-edit/composition][pre-edit-composition] machinery itself — no `zwp_text_input_v3`, no Windows TSF/IMM32 wiring, no `NSTextInputClient`, no XIM. Composition, candidate windows, and dead keys are handled by the native widget (`UITextField`, WinUI `TextBox`, Android `EditText`), which already speaks the platform IME. MAUI only observes the resulting text via `TextChanged`. The one IME-adjacent feature MAUI _does_ own is **keyboard avoidance**: `KeyboardAutoManager` ([`KeyboardAutoManager.cs`][ios-kbauto], `KeyboardAutoManagerScroll.cs`) scrolls the focused field above the iOS soft keyboard.

**Pointer, scroll, touch, gestures.** Gesture recognition is layered on top of native pointer events, not raw motion. On Windows, `GesturePlatformManager` ([`GesturePlatformManager.Windows.cs`][gpm-windows]) subscribes to WinUI `PointerPressed`/`PointerMoved`/`PointerReleased` and `ManipulationDelta`, tracking fingers by `PointerRoutedEventArgs.Pointer.PointerId` and synthesizing pan/pinch/swipe — so absolute vs [relative/raw motion][raw-vs-accelerated-pointer], high-resolution scroll (`wl_pointer` `axis_v120`, `WM_MOUSEWHEEL` accumulation, macOS momentum phases), and pointer capture are all resolved by the native stack before MAUI sees them. There is no MAUI pointer-confinement or pointer-lock API.

**Cursor.** Cursor handling is delegated; MAUI exposes a `PointerOver` visual state and lets the native control pick the cursor shape. There is no [`cursor_shape_v1`][raw-vs-accelerated-pointer]-style choice at the MAUI layer because MAUI never renders on Wayland.

---

## 4. Wayland specifics

> [!WARNING]
> **Not applicable: .NET MAUI has no Wayland, X11, or any Linux desktop backend.** There is no `xdg-shell`, no [`xdg-decoration`][csd-vs-ssd], no `libdecor`, no `fractional-scale-v1`/`viewporter`/`xdg-activation`/`layer-shell`, and no compositor-specific (mutter/kwin/sway/weston) workaround anywhere in the tree — because the [`WindowHandler.Standard.cs`][wh-standard] fallback throws `NotImplementedException` on any non-iOS/Android/Windows/Tizen target.

The absence is by design and is the most-requested missing feature (see [§10](#10-history-redesigns-known-regrets)). The closest the ecosystem gets to Wayland/X11 is the **community** [Maui.Gtk][maui-gtk] project (a GTK4 back-end via GirCore bindings, [covered by Phoronix][phoronix-gtk]), which is out of tree and unofficial. Tizen — the only non-Microsoft, non-Apple-or-Google desktop-ish target — uses `Tizen.NUI.Window` ([`WindowHandler.Tizen.cs`][wh-tizen]); NUI is Samsung's own compositor-backed UI toolkit, not Wayland-protocol code that MAUI authored. Server-side vs client-side decoration ([CSD vs SSD][csd-vs-ssd]) is therefore decided entirely by the host stack (DWM on Windows, the compositor on Tizen), never by MAUI.

---

## 5. DPI & scaling

MAUI's portable coordinates are **device-independent units (DIPs)** — [logical, not physical][logical-vs-physical-coords]. Each platform converts to physical pixels using a [scale factor][scale-factor] it queries from the OS; MAUI never owns the awareness model.

- **Windows** — `WindowExtensions.GetDisplayDensity` ([`WindowExtensions.cs`][win-windowext]) computes the factor from the Win32 [`GetDpiForWindow`][getdpiforwindow] divided by `DeviceDisplay.BaseLogicalDpi` (96):

  ```cs
  // src/Core/src/Platform/Windows/WindowExtensions.cs
  return PlatformMethods.GetDpiForWindow(hwnd) / DeviceDisplay.BaseLogicalDpi;
  ```

  All window geometry is multiplied by this density before being handed to `AppWindow.Move`/`AppWindow.Resize`, and the reverse division is applied in `UpdateVirtualViewFrame` to report logical coordinates back ([`WindowHandler.Windows.cs`][wh-windows]). Per-monitor DPI awareness (v2) and the `WM_DPICHANGED` dance are handled _inside_ WinUI 3 / the Windows App SDK; MAUI does not process `WM_DPICHANGED` itself (it is not in the `WindowMessageManager` switch).

- **iOS / Catalyst** — backing scale is UIKit's `contentScaleFactor`/`UIScreen.scale`; MAUI reads frame geometry already in points.

- **Android** — density comes from the `Activity`'s resources; `GetDisplayDensity` returns the device's scaled density.

Fractional scaling on Wayland and the "created-at-wrong-scale-then-rescaled" problem are **not MAUI concerns** — there is no Wayland, and on the supported platforms the native window arrives already at the correct scale, with the OS firing native resize/DPI events that MAUI observes (e.g. the Catalyst `effectiveGeometry` KVO observer in [`WindowHandler.iOS.cs`][wh-ios]). Mixed-DPI multi-monitor migration is likewise resolved by WinUI/UIKit before MAUI's `FrameChanged` runs.

---

## 6. Multi-window & popups

Multi-window is supported on the desktop-class targets by asking the **native** windowing system to spawn a window; MAUI never stacks or grabs windows itself.

- **Windows** — `ApplicationHandler.MapOpenWindow` ([`ApplicationHandler.Windows.cs`][app-windows]) calls `CreatePlatformWindow`, which does `new MauiWinUIWindow(); winuiWindow.Activate();` ([`ApplicationExtensions.cs`][win-appext]). `MapCloseWindow`/`MapActivateWindow` call WinUI `Window.Close()`/`Window.Activate()`.
- **iOS / Catalyst** — multi-window means **multiple [`UIScene`/`UIWindowScene`][uiwindowscene]s**. `RequestNewWindow` ([`ApplicationExtensions.cs`][ios-appext]) calls `UISceneSessionActivationRequest` (iOS 17+) or `UIApplication.RequestSceneSessionActivation`, and the new scene is wired up in `MauiUISceneDelegate.WillConnect` ([`MauiUISceneDelegate.cs`][ios-scenedelegate]).
- **Android / Tizen** — single-window-centric; `OpenWindowRequest` ([`OpenWindowRequest.cs`][open-window-req]) carries only persisted state, with no Windows-style `LaunchActivatedEventArgs`.

**Modal dialogs, tooltips, menus, and popups are native.** MAUI uses native flyouts/menus (`MenuFlyout`, `UIMenuSystem`) and modal page presentation; it does not implement [`xdg_popup` grab semantics or X11 override-redirect][override-redirect-vs-xdg-popup-grab] — popup stacking, grabs, and dismissal are the platform's job. Parent/child stacking and window groups are likewise whatever WinUI/UIKit provide.

---

## 7. Threading

The threading model is dictated by the native stacks MAUI wraps, and it is the familiar one: **the UI thread is sacred.**

- **Windows must create and touch the window on the thread that owns its [`DispatcherQueue`][dispatcherqueue]** (WinUI 3's single-threaded apartment for UI). `Dispatcher.Windows` checks `DispatcherQueue.HasThreadAccess` to decide whether marshalling is required ([`Dispatcher.Windows.cs`][disp-windows]).
- **iOS / Mac Catalyst force the main thread** because UIKit (and hence Mac Catalyst) is main-thread-only — the recurring "main-thread AppKit/UIKit" constraint. `DispatcherProvider.GetForCurrentThreadImplementation` returns a dispatcher only when the current GCD queue is the [`DispatchQueue.MainQueue`][gcd-mainqueue] ([`Dispatcher.iOS.cs`][disp-ios]):

  ```cs
  // src/Core/src/Dispatching/Dispatcher.iOS.cs
  var q = DispatchQueue.CurrentQueue;
  if (q != DispatchQueue.MainQueue)
      return null;
  return new Dispatcher(q);
  ```

- **Android** events arrive on the main `Looper` thread; off-thread work marshals back via the `Handler`.

Events are delivered on the UI thread by the platform. **Rendering off the event thread is possible only to the extent the native stack allows it** (e.g. WinUI composition and Core Animation composite on their own threads), but that is invisible to MAUI — MAUI's own work (handler mapping, layout) runs on the UI thread. Background work uses ordinary .NET tasks and marshals UI updates through `IDispatcher.Dispatch`.

---

## 8. Clipboard & DnD

Clipboard is a thin wrapper over each platform's native data-transfer API (in MAUI **Essentials**), not a hand-rolled selection protocol.

- **Windows** — uses the WinRT [`DataPackage`][datapackage] / `Clipboard` ([`Clipboard.windows.cs`][clip-windows]). MIME negotiation and the Win32 delayed-rendering protocol are handled inside WinRT; MAUI just sets/gets text and subscribes to `ContentChanged`:

  ```cs
  // src/Essentials/src/Clipboard/Clipboard.windows.cs
  var dataPackage = new DataPackage();
  dataPackage.SetText(text);
  WindowsClipboard.SetContent(dataPackage);
  ```

- **iOS / Catalyst** — `UIPasteboard`; **macOS** Essentials uses `NSPasteboard` ([`Clipboard.macos.cs`][clip-macos], a legacy AppKit path retained for Essentials).
- **Android** — `ClipboardManager`.

The portable [`IClipboard`][clip-shared] surface is text-centric (`SetTextAsync`/`GetTextAsync`/`HasText`); rich formats, the **Wayland selection model**, Win32 **delayed rendering**, and **X11 `INCR`** are entirely below MAUI's API — and X11/Wayland never appear because there is no Linux backend. Drag-and-drop is exposed at the Controls layer via gesture recognizers backed by the native DnD stacks (WinUI `DragStarting`, UIKit drag interactions); MAUI authors no transfer protocol.

---

## 9. Escape hatches

Because the abstraction is thin, the escape hatches are short — and they reveal exactly where it leaks.

- **Native view access via the handler.** `handler.PlatformView` _is_ the native control (`UIWindow`, WinUI `Window`, `Activity`). `IElementHandler.PlatformView` ([`IElementHandler.cs`][ielement-handler]) is the documented door to the underlying widget; for raw key events, custom drawing, or platform tweaks, apps cast it and use it directly.
- **`HWND` access.** `WindowExtensions.GetWindowHandle` ([`WindowExtensions.cs`][win-windowext]) returns the Win32 handle (the [retrieve-an-HWND][retrieve-hwnd] pattern) so apps can call `user32`/`shell32` directly — MAUI itself uses it for `GetDpiForWindow`, `ShowWindow`, and icon extraction.
- **`WndProc` subclassing / raw Win32 message hook.** The most powerful hatch: apps subscribe to the `OnPlatformMessage` lifecycle event, which fires for every window message because `MauiWinUIWindow` subclasses the window procedure via `WindowMessageManager` ([`WindowMessageManager.windows.cs`][win-msg-mgr]). The manager swaps `GWL_WNDPROC` with `SetWindowLongPtr` and chains the original with `CallWindowProc` — letting apps mark a message `Handled` and return their own result. The existence of this hook is an admission that the WinUI surface is sometimes insufficient.
- **Per-platform lifecycle events.** `ConfigureLifecycleEvents` exposes `iOSLifecycle`/`WindowsLifecycle`/`AndroidLifecycle` delegates (e.g. `FinishedLaunching`, `OnPlatformWindowSubclassed`, `OnLaunched`) so apps can run code at native lifecycle points the portable model omits.

---

## 10. History, redesigns & known regrets

**Lineage: Xamarin.Forms → MAUI.** MAUI is the successor to Xamarin.Forms (2014). Forms wrapped native controls via **renderers** — heavy `[assembly:ExportRenderer]`-registered classes that subclassed a base renderer per control. MAUI's flagship redesign replaced renderers with the lighter **handler** architecture studied above: a flat `PropertyMapper`/`CommandMapper` of static methods instead of a renderer subclass, decoupled from the Forms view hierarchy. This is the migration that made `handler.PlatformView` and the per-property `MapXxx` model the core abstraction (see [Handlers docs][handlers-docs]).

**The declined Linux desktop target — the biggest regret.** Xamarin.Forms had a community GTK backend, and a Linux/GTK target was repeatedly requested for MAUI. Microsoft declined to ship or own it. The long-running discussion [dotnet/maui#339 "First class Linux support developed by Microsoft"][maui-linux-discussion] (700+ replies) records the position: Microsoft invests in platforms "relevant to most of our current customers," scoping MAUI to mobile (iOS, Android) + desktop (Windows, macOS), with the expectation that **Linux support would be community-led** rather than first-party. The newer issue [dotnet/maui#32023 "Official Support for .NET MAUI on Linux"][maui-linux-issue] continues to collect feedback, and an earlier workload request [dotnet/maui#3564][maui-gtk-workload] asked for a `maui-gtk` workload. The outcome to date: **no official Linux backend**, only the community [Maui.Gtk][maui-gtk] GTK4 project. The `NotImplementedException` in [`WindowHandler.Standard.cs`][wh-standard] is the codified result.

**Other consequences of the wrapping stance.** Because MAUI delegates the windowing layer, its bug surface is concentrated in the _seams_ — title-bar customization, DPI conversion, scene/activity lifecycle, and the WinUI `OnActivated`-fires-twice quirk that `MauiWinUIWindow.OnActivated` works around with a comment citing [microsoft-ui-xaml#7343][microsoft-ui-xaml-7343]:

> // We have to track isActivated calls because WinUI will call OnActivated Twice
> // when maximizing a window

That single workaround is emblematic: MAUI inherits both the strengths and the unfixable quirks of the stacks it wraps.

---

## Strengths

- **Tiny windowing surface to maintain.** By delegating windows, loops, input, IME, DPI, and decorations to native stacks, MAUI carries no compositor, no `xkbcommon`, no DPI-awareness state machine — orders of magnitude less platform code than an owns-the-pixels toolkit.
- **Native look, feel, and behavior for free.** Controls _are_ the platform's controls, so platform conventions (IME, accessibility, text selection, momentum scroll) work without reimplementation.
- **Clean per-property abstraction.** The `PropertyMapper`/handler model is small, testable, and extensible; `handler.PlatformView` is a first-class, documented escape hatch.
- **Real multi-window on desktop** via the native primitives (WinUI windows, UIKit scenes).
- **First-party Windows + Apple integration** (Mica, title-bar extension, scenes, Catalyst) tracking the latest OS APIs.

## Weaknesses

- **No Linux desktop, by policy** — the most-requested feature is permanently community-only ([#339][maui-linux-discussion]).
- **No raw windowing control.** No frame pacing, no surface/`raw-window-handle`, no pointer lock/confinement, no per-keystroke key events in core; apps must drop to the native handle for any of it.
- **Inconsistent attribute support.** Window size/position/min-max/decorations are Windows-(+Catalyst-)only; the same `IWindow` property silently no-ops on mobile.
- **Inherits every native quirk.** The WinUI double-`OnActivated`, Catalyst geometry timing, and Win32 min/max clamping are all worked around in MAUI rather than fixed.
- **Mac is Catalyst, not AppKit** — so MAUI macOS apps carry UIKit-on-Mac compromises rather than native AppKit windowing.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                       | Trade-off                                                                       |
| ------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Wrap native controls/windows instead of drawing         | Native fidelity & accessibility for free; minimal platform code | Zero control over the windowing layer; every quirk inherited                    |
| Handler + `PropertyMapper` (replaces Forms renderers)   | Lighter, flat, testable, decoupled mapping                      | One-way property push; complex custom controls still need native code           |
| `PlatformView` is the literal native window             | Trivial, transparent escape hatch                               | The abstraction is shallow; portable `IWindow` is the lowest common denominator |
| Dispatcher = thin shim over native main-thread queue    | No bespoke loop to maintain; correct threading by construction  | No timers/wakeups/external-fd integration beyond what the OS queue offers       |
| Scope to Win/macOS/iOS/Android (+Tizen by Samsung)      | Focus on platforms "relevant to most customers"                 | No Linux desktop; the `Standard` handler throws                                 |
| Win32 `WndProc` subclassing for missing window behavior | Implement min/max clamp & title-bar reaction WinUI won't        | Fragile P/Invoke + marshalling; Windows-only                                    |
| Logical (DIP) coordinates, density applied per platform | Single portable unit across very different scale models         | Must trust each native stack's DPI awareness; MAUI can't fix mis-scaling        |

---

## Verdict: what a new framework should steal / avoid

**Steal:** the handler/`PropertyMapper` seam — making the native object directly reachable as `PlatformView` is a clean, honest escape hatch that admits the abstraction's limits instead of hiding them. The per-platform `Dispatcher`-over-native-queue shim is the right minimal loop primitive when you do _not_ own the loop. And the conditional-compilation `Mapper` that simply omits unsupported properties per platform is a pragmatic way to express partial capability.

**Avoid:** treating "size/position/decorations" as portable when they only work on two of four platforms — silent no-ops are a worse contract than an explicit "unsupported" signal (contrast the per-dimension honesty this catalog asks of itself). And note the cost of _not_ owning the windowing layer: a project that wants Wayland, frame pacing, pointer lock, or a custom title bar on every OS cannot get there by wrapping — that is precisely the niche an owns-the-pixels toolkit (Avalonia, Flutter, [winit][winit]-based stacks) fills.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact frame-pacing behavior on each platform under MAUI's `GraphicsView`/SkiaSharp drawing path.** MAUI's own drawing surfaces (`PlatformTouchGraphicsView`) sit on native invalidation; the cadence is set by WinUI composition / Core Animation. Likely answer: `src/Graphics` + the SkiaSharp views, plus native compositor docs.
- **Whether any portable per-keystroke key-event API is planned.** Core only exposes `KeyboardAccelerator`. Likely answer: `dotnet/maui` discussions tagged `area-keyboard`/`proposal`.
- **The precise lifetime/ownership of `MauiContext` window scopes across scene reconnection on iOS.** `MakeWindowScope` + the scene delegate's `DidDisconnect` hint at it; the definitive answer is in `src/Core/src/MauiContext*` and the DI scope code (outside the sparse paths studied).
- **Tizen NUI windowing depth** (Samsung-maintained) — coverage of decorations/DPI there was not studied in source beyond `WindowHandler.Tizen.cs`.

---

## Sources

- [dotnet/maui][maui-repo] — main repository (source for all quoted file paths) @ `c389325`
- [`WindowHandler.cs`][wh-shared] / [`WindowHandler.Windows.cs`][wh-windows] / [`WindowHandler.iOS.cs`][wh-ios] / [`WindowHandler.Android.cs`][wh-android] / [`WindowHandler.Standard.cs`][wh-standard] / [`WindowHandler.Tizen.cs`][wh-tizen] — per-platform window handlers
- [`ElementHandler.cs`][eh-base] / [`ElementHandlerOfT.cs`][eh-of-t] / [`IElementHandler.cs`][ielement-handler] — the handler architecture
- [`MauiWinUIWindow.cs`][maui-winui-window] / [`MauiWinUIApplication.cs`][maui-winui-app] / [`WindowExtensions.cs`][win-windowext] / [`ApplicationExtensions.cs`][win-appext] / [`WindowMessageManager.windows.cs`][win-msg-mgr] — Windows/WinUI 3 windowing
- [`MauiUIApplicationDelegate.cs`][ios-appdelegate] / [`MauiUISceneDelegate.cs`][ios-scenedelegate] / [`ApplicationExtensions.cs`][ios-appext] — iOS/Catalyst lifecycle & multi-window
- [`Dispatcher.iOS.cs`][disp-ios] / [`Dispatcher.Windows.cs`][disp-windows] / [`Dispatcher.Android.cs`][disp-android] / [`Dispatcher.Standard.cs`][disp-standard] — the only loop primitive
- [`KeyboardExtensions.cs` (iOS)][ios-kbext] / [`KeyboardExtensions.cs` (Windows)][win-kbext] / [`KeyboardAcceleratorExtensions.cs`][win-kbaccel] / [`GesturePlatformManager.Windows.cs`][gpm-windows] — input
- [`Clipboard.windows.cs`][clip-windows] / [`IClipboard`][clip-shared] — clipboard
- [Supported platforms][supported-platforms] / [Handlers][handlers-docs] — official docs
- [dotnet/maui#339][maui-linux-discussion] / [#32023][maui-linux-issue] / [#3564][maui-gtk-workload] / [microsoft-ui-xaml#7343][microsoft-ui-xaml-7343] — history & regrets
- [Maui.Gtk][maui-gtk] / [Phoronix coverage][phoronix-gtk] — community Linux/GTK4 backend
- Sibling docs: [concepts][concepts], [ui-layout][ui-layout], [async-io][async-io], [winit][winit]

<!-- References -->

[maui-repo]: https://github.com/dotnet/maui
[supported-platforms]: https://learn.microsoft.com/en-us/dotnet/maui/supported-platforms
[handlers-docs]: https://learn.microsoft.com/en-us/dotnet/maui/user-interface/handlers/
[winui3]: https://learn.microsoft.com/en-us/windows/apps/winui/winui3/
[appwindow]: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindow
[overlappedpresenter]: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.overlappedpresenter
[dispatcherqueue]: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.dispatching.dispatcherqueue
[getdpiforwindow]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow
[retrieve-hwnd]: https://learn.microsoft.com/en-us/windows/apps/develop/ui-input/retrieve-hwnd
[datapackage]: https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.datatransfer.datapackage
[cadisplaylink]: https://web.archive.org/web/20190614134451/https://developer.apple.com/documentation/quartzcore/cadisplaylink
[uiwindowscene]: https://web.archive.org/web/20251210151637/https://developer.apple.com/documentation/uikit/uiwindowscene
[gcd-mainqueue]: https://web.archive.org/web/20260209115552/https://developer.apple.com/documentation/dispatch/dispatchqueue
[maui-linux-discussion]: https://github.com/dotnet/maui/discussions/339
[maui-linux-issue]: https://github.com/dotnet/maui/issues/32023
[maui-gtk-workload]: https://github.com/dotnet/maui/issues/3564
[microsoft-ui-xaml-7343]: https://github.com/microsoft/microsoft-ui-xaml/issues/7343
[maui-gtk]: https://github.com/jsuarezruiz/maui-linux
[phoronix-gtk]: https://www.phoronix.com/news/Microsoft-dotNET-MAUI-GTK4
[wh-shared]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Window/WindowHandler.cs
[wh-windows]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Window/WindowHandler.Windows.cs
[wh-ios]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Window/WindowHandler.iOS.cs
[wh-android]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Window/WindowHandler.Android.cs
[wh-standard]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Window/WindowHandler.Standard.cs
[wh-tizen]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Window/WindowHandler.Tizen.cs
[eh-base]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Element/ElementHandler.cs
[eh-of-t]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Element/ElementHandlerOfT.cs
[ielement-handler]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/IElementHandler.cs
[maui-winui-window]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Windows/MauiWinUIWindow.cs
[maui-winui-app]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Windows/MauiWinUIApplication.cs
[win-windowext]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Windows/WindowExtensions.cs
[win-appext]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Windows/ApplicationExtensions.cs
[win-msg-mgr]: https://github.com/dotnet/maui/blob/main/src/Essentials/src/Platform/WindowMessageManager.windows.cs
[ios-appdelegate]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/iOS/MauiUIApplicationDelegate.cs
[ios-scenedelegate]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/iOS/MauiUISceneDelegate.cs
[ios-appext]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/iOS/ApplicationExtensions.cs
[disp-ios]: https://github.com/dotnet/maui/blob/main/src/Core/src/Dispatching/Dispatcher.iOS.cs
[disp-windows]: https://github.com/dotnet/maui/blob/main/src/Core/src/Dispatching/Dispatcher.Windows.cs
[disp-android]: https://github.com/dotnet/maui/blob/main/src/Core/src/Dispatching/Dispatcher.Android.cs
[disp-standard]: https://github.com/dotnet/maui/blob/main/src/Core/src/Dispatching/Dispatcher.Standard.cs
[idispatcher]: https://github.com/dotnet/maui/blob/main/src/Core/src/Dispatching/IDispatcher.cs
[ios-kbext]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/iOS/KeyboardExtensions.cs
[ios-kbauto]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/iOS/KeyboardAutoManager.cs
[win-kbext]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Windows/KeyboardExtensions.cs
[win-kbaccel]: https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Windows/KeyboardAcceleratorExtensions.cs
[gpm-windows]: https://github.com/dotnet/maui/blob/main/src/Controls/src/Core/Platform/GestureManager/GesturePlatformManager.Windows.cs
[clip-windows]: https://github.com/dotnet/maui/blob/main/src/Essentials/src/Clipboard/Clipboard.windows.cs
[clip-macos]: https://github.com/dotnet/maui/blob/main/src/Essentials/src/Clipboard/Clipboard.macos.cs
[clip-shared]: https://github.com/dotnet/maui/blob/main/src/Essentials/src/Clipboard/Clipboard.shared.cs
[app-windows]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/Application/ApplicationHandler.Windows.cs
[open-window-req]: https://github.com/dotnet/maui/blob/main/src/Core/src/Handlers/OpenWindowRequest.cs
[concepts]: ./concepts.md
[csd-vs-ssd]: ./concepts.md#client-vs-server-decoration
[scancode-keysym-virtualkey]: ./concepts.md#scancode-keysym-virtualkey
[logical-vs-physical-coords]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pre-edit-composition]: ./concepts.md#pre-edit-composition
[override-redirect-vs-xdg-popup-grab]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal-resize-loop]: ./concepts.md#win32-modal-resize-loop
[raw-vs-accelerated-pointer]: ./concepts.md#raw-vs-accelerated-pointer
[nbnw]: ./concepts.md#no-buffer-no-window
[frame-callback-vsync]: ./concepts.md#frame-callback-vsync
[rvc]: ./concepts.md#readiness-vs-completion-windowing
[winit]: ./winit.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
