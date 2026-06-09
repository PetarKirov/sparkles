# Windows (Win32)

The native windowing API of Windows: a **message-driven** C API where the application registers a window class with a callback (`WndProc`), creates an `HWND` with `CreateWindowExW`, and then cedes its thread to a [`GetMessage`][getmessage]/`TranslateMessage`/`DispatchMessageW` pump that delivers `WM_*` messages back to that `WndProc`. This is the layer the Windows backends of [winit][winit], [SDL3][sdl3], [Qt 6][qt6], and [Chromium Ozone][ozone] all reduce to.

**Last reviewed:** June 9, 2026

| Field                    | Value                                                                                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native API               | **Win32 / User32** (`RegisterClassExW` / `CreateWindowExW` / `WndProc` / `WM_*` messages)                                                                                                                                       |
| Library / framework      | druntime's built-in `core.sys.windows` (the `<windows.h>` projection that ships with LDC/DMD); `user32.dll` / `gdi32.dll` at runtime. For the full SDK, the [`RolandTaverner/windows-d`][windows-d] fork (see the binding note) |
| Header / protocol source | The `<windows.h>` projection — `core.sys.windows.windows` (re-exports `winuser`, `windef`, `wingdi`, `winbase`); the canonical C headers are `WinUser.h` / `WinDef.h`                                                           |
| Window handle type       | `HWND` (an opaque window handle; the kernel/`csrss`-owned window object)                                                                                                                                                        |
| Event-loop primitive     | The **thread message queue** ([`GetMessage`][getmessage] + `DispatchMessageW`) — a [readiness][rvc]-style pull loop over the per-thread queue                                                                                   |
| Coordinate unit          | **Physical pixels** (per-monitor DPI); logical 96-DPI units only after a DPI-awareness opt-out — see [Coordinates & scaling](#coordinates--scaling)                                                                             |
| Decoration owner         | **Server-side** — the non-client area (titlebar, border, min/max/close, shadow) is drawn by the OS (`DefWindowProcW` + the DWM), selected by the window styles                                                                  |
| Example                  | [`./example/app.d`](./example/app.d)                                                                                                                                                                                            |

> [!IMPORTANT]
> **Binding note — `core.sys.windows` vs `windows-d`.** The minimal example uses druntime's built-in `core.sys.windows` bindings, which ship with LDC/DMD and need **zero third-party packages** — they cover the classic User32/GDI windowing surface (`RegisterClassExW`, `CreateWindowExW`, `GetMessageW`, the `WM_*` constants, `HWND`/`HDC`/`PAINTSTRUCT`) used throughout this survey. They are **sufficient for opening and pumping a window**. For the _full_ modern Windows SDK — the `windows.win32.*` projection covering DirectX, COM, Direct2D/DirectWrite, the Text Services Framework, and the modern UI surfaces — use the actively-maintained fork [`RolandTaverner/windows-d`][windows-d], **not** the unmaintained original [`rumbu13/windows-d`][windows-d-orig]. `windows-d` is only needed when `core.sys.windows` is insufficient; a window opener like the example never reaches for it.

---

## What it is

Win32 is the C-level application and windowing API of Windows. Unlike the object-oriented [AppKit][appkit] or the role-and-protocol [Wayland][wayland] model, it is a flat set of free functions (`RegisterClassExW`, `CreateWindowExW`, `ShowWindow`, `DefWindowProcW`) plus a single, defining abstraction: every window is associated with a **window procedure** (`WndProc`), and the OS communicates with the window by sending it **messages**. The application's job is to register a window class that names that procedure, create windows, and run a loop that pulls messages off its thread's queue and dispatches them so the OS can call the procedure back.

The model is documented as message-driven from the ground up. The Win32 message-queue overview states the contract verbatim:

> A Microsoft Win32-based application does not make explicit function calls to obtain input. Instead, it waits for the system to pass input to it. The system passes all input for an application to the various windows in the application. Each window has a function, called a window procedure, that the system calls whenever it has input for the window. The window procedure processes the input and returns control to the system.
>
> — [_About Messages and Message Queues_][msgqueue], Microsoft Learn

A window is referred to by an opaque `HWND` (window handle). A window's behaviour is fixed by its **window class**, registered with `RegisterClassExW`, which binds a class name to the `WndProc` and to defaults (cursor, background brush, icon). The first-program tutorial is explicit that the class is the prerequisite for creation:

> The window class identifies the window procedure that is responsible for processing all messages sent to the window. … Before creating a window, you must register a window class by calling the `RegisterClass` function.
>
> — [_Creating a window_ / _Window Classes_][winclasses], Microsoft Learn

The example here reaches all of this through druntime's built-in `core.sys.windows.windows`, which projects `<windows.h>`; there is no generated binding and no third-party dependency.

> [!NOTE]
> The `W` suffix on `RegisterClassExW`/`CreateWindowExW`/`GetMessageW`/`DispatchMessageW` selects the **wide (UTF-16) `WCHAR`** entry points over the legacy `A` (ANSI) ones. Every modern binding uses the `W` family; the example passes UTF-16 string literals (`"SparklesWin32"w`) for exactly this reason.

---

## The minimal program

The example, [`./example/app.d`](./example/app.d), is the irreducible Win32 window-open sequence that [winit][winit], [SDL3][sdl3], and [Qt 6][qt6] each wrap on Windows. It imports `core.sys.windows.windows` and runs:

1. **Module handle.** `GetModuleHandleW(null)` returns the `HINSTANCE` for the running executable — the instance handle every window-class and window-creation call wants.

2. **Register the window class.** A `WNDCLASSEXW` is filled in — `cbSize`, `lpfnWndProc = &wndProc` (the message callback), `hInstance`, `lpszClassName`, and an `hCursor` from `LoadCursorW(null, IDC_ARROW)` — and passed to [`RegisterClassExW`][registerclassex]. A `false` return means the class did not register; the example prints `GetLastError()` and exits `1`. This is the prerequisite the [_Window Classes_][winclasses] doc describes: the class is what ties the `HWND`-to-be to its `WndProc`.

3. **Create the window.** [`CreateWindowExW`][createwindowex] is called with `WS_OVERLAPPEDWINDOW` (the standard titled, resizable, min/max top-level style), `CW_USEDEFAULT` for the position, and an explicit `480 × 320` size. A `null` return is checked the same way. On success the call has produced a live `HWND` — and, because Win32 windows map synchronously, the OS has already sent the new window its `WM_CREATE`/`WM_NCCREATE` messages before `CreateWindowExW` returns.

4. **Show it.** `ShowWindow(hwnd, SW_SHOW)` makes the window visible and `UpdateWindow(hwnd)` forces an immediate `WM_PAINT` (rather than waiting for the queue). Unlike Wayland's [no-buffer-no-window][nbnw] handshake, this is synchronous — the window is on screen now.

5. **Run the message pump.** The loop is the canonical three-call pump:

   ```d
   MSG msg;
   while (GetMessageW(&msg, null, 0, 0) > 0)
   {
       TranslateMessage(&msg);
       DispatchMessageW(&msg);
   }
   ```

   [`GetMessageW`][getmessage] blocks until a message is available, returns `> 0` for a normal message, `0` when it dequeues `WM_QUIT`, and `-1` on error; `TranslateMessage` synthesizes `WM_CHAR` from key messages; `DispatchMessageW` hands the message to the window's `WndProc`.

6. **The window procedure.** `extern (Windows) LRESULT wndProc(HWND, UINT, WPARAM, LPARAM)` is the heart of the program. It `switch`es on the message:
   - `WM_PAINT` — `BeginPaint`/`GetClientRect`/`FillRect`(`COLOR_WINDOW + 1`)/`EndPaint` paints the client area once, then calls `PostQuitMessage(0)` so the program is **bounded** — it exits after the first paint so CI never blocks.
   - `WM_DESTROY` — `PostQuitMessage(0)` (the conventional response, posting `WM_QUIT` to end the pump).
   - **default** — `DefWindowProcW(hwnd, msg, wParam, lParam)`, the OS default handler that draws the non-client area and provides standard behaviour. Forwarding unhandled messages to [`DefWindowProcW`][defwindowproc] is mandatory.

`PostQuitMessage` makes the next `GetMessageW` return `0`, the loop ends, and `main` returns `msg.wParam`.

> [!NOTE]
> **No `SKIP:` gate is needed.** Unlike the [AppKit][appkit] example (which checks `CGMainDisplayID()` for a window server), Windows always has a window station and desktop — even a headless CI runner — so creating and pumping a window never has an undefined-no-display case. The example is bounded by `PostQuitMessage`, not by a host-capability guard.

> [!WARNING]
> **`WndProc` is `nothrow`.** The callback is invoked by the OS across the C ABI; a D exception unwinding through `DefWindowProcW` into kernel code is undefined behaviour. The example marks `wndProc` `nothrow` for this reason, and a real binding must catch everything at the `WndProc` boundary.

---

## Window creation & lifecycle

Creation is two synchronous steps: register a class, then create one or more windows from it.

**The window class** ([`RegisterClassExW`][registerclassex]) names the `WndProc` and supplies class-wide defaults. A class is registered once and any number of `HWND`s can be created from it; toolkits register one class per window "kind" (a main-window class, a popup class, a message-only class). The class also carries `cbWndExtra`/`cbClsExtra` bytes — the conventional place a binding stashes its per-window `this` pointer (alternatively via `SetWindowLongPtrW(GWLP_USERDATA)`), so the static `extern(Windows)` `WndProc` can recover the owning object.

**Window creation** ([`CreateWindowExW`][createwindowex]) takes an extended style (`WS_EX_*`), the class name, the title, the **window style** (`WS_*`), position/size, parent/owner, menu, instance, and a `void*` creation parameter delivered in `WM_CREATE`'s `lParam`. The style word is the decoration-and-behaviour selector: `WS_OVERLAPPEDWINDOW` (the example's choice) is the macro union of `WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX` — a titled, resizable top-level window. Removing `WS_THICKFRAME` removes the resize border; `WS_POPUP` makes a borderless popup (see [Decorations](#decorations--multi-window-popups)).

**Mapping is synchronous.** `CreateWindowExW` (plus `ShowWindow`) puts the window on screen immediately — the same model as X11's `XMapWindow`, and the opposite of Wayland's [no-buffer-no-window][nbnw] rule where a surface stays invisible until the first buffer commit and the initial `xdg_surface.configure` round-trip. A Win32 binding never has to model "created but not yet shown" as a negotiated state.

**Lifecycle is message-delivered.** Key lifecycle messages arriving at the `WndProc`:

| Message                     | Meaning                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------- |
| `WM_NCCREATE` / `WM_CREATE` | Window being created (before `CreateWindowExW` returns); init per-window state           |
| `WM_SIZE` / `WM_MOVE`       | Client size / position changed                                                           |
| `WM_PAINT`                  | The window (or a region of it) must be repainted                                         |
| `WM_CLOSE`                  | The user clicked close; the app decides whether to `DestroyWindow`                       |
| `WM_DESTROY`                | The window is being destroyed; conventionally responds with `PostQuitMessage`            |
| `WM_QUIT`                   | Not delivered to a `WndProc` — it terminates the message pump (`GetMessage` returns `0`) |

The `WM_CLOSE` → `DestroyWindow` → `WM_DESTROY` → `PostQuitMessage` → `WM_QUIT` chain is the standard teardown path; the example short-circuits it by posting quit straight from the first `WM_PAINT`.

---

## Event loop & frame pacing

The loop is the [`GetMessageW`][getmessage]/`TranslateMessage`/`DispatchMessageW` pump described above, driving the **per-thread message queue**. It is a [readiness][rvc]-style pull model: the app owns the loop and calls `GetMessageW` to pull the next ready message, mirroring the poll-driven backends ([GLFW][glfw], default [SDL3][sdl3]). `GetMessageW` blocks the thread when the queue is empty; `PeekMessageW` is the non-blocking variant a game loop uses to interleave rendering. The window-procedure tutorial spells out the inversion of control:

> Recall that the operating system communicates with your window by passing messages to it. … `DispatchMessage` tells the operating system to call the window procedure of the window that is the target of the message.
>
> — [_Writing the Window Procedure_][wndproc], Microsoft Learn

> [!WARNING]
> **The modal resize/move loop blocks the pump.** When the user grabs the titlebar or a resize edge, Windows enters its **own nested modal message loop inside `DefWindowProcW`** and stops returning to the application's `GetMessageW` — timers stop, redraws freeze, and a live-resize shows a frozen window for the whole drag. The loop is bracketed by `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` ([the Win32 modal resize/move loop][modal]). The survey-wide workaround is to `SetTimer` on `WM_ENTERSIZEMOVE` and drive a frame from each `WM_TIMER` while `DefWindowProcW` blocks — [SDL3][sdl3], [GTK 4][gtk4], and [Qt 6][qt6] all do a variant of this. The example never resizes, so it never enters the loop.

**Multiplexing other sources.** Because the pump is a thread-queue reactor, folding in a non-window event source (a socket, a timer, an [async runtime][async-io]'s waitable) uses `MsgWaitForMultipleObjectsEx`, which waits on both the message queue and a set of `HANDLE`s at once — the Windows answer to the "no portable external-fd injection" problem the Linux backends hit. A worker thread can also post into the GUI thread's queue with `PostMessageW`/`PostThreadMessageW`.

**Frame pacing** is a separate subsystem from the message loop ([frame callbacks & per-platform vsync][fcv]). There is no `wl_surface.frame`-style per-window vsync message; instead a renderer paces off **DXGI present** (`IDXGISwapChain::Present` with a sync interval, or `IDXGIOutput::WaitForVBlank`) or the **DWM composition clock** (`DwmGetCompositionTimingInfo`). [JUCE][juce] runs a dedicated highest-priority `WaitForVBlank` thread on Windows; the example does no rendering, so it does no pacing.

---

## Input

**Keyboard.** Key presses arrive as `WM_KEYDOWN`/`WM_KEYUP` (and `WM_SYSKEYDOWN`/`WM_SYSKEYUP` for Alt-combinations). The message carries **both identities** of the [scancode / keysym / virtual-key][skv] split: the `wParam` is the **virtual-key code** (`VK_*` — Win32's layout-dependent _keysym_, e.g. `VK_ESCAPE`, `VK_A`), and the `lParam` bitfield carries the **OEM scancode** (the layout-independent physical key) in bits 16–23, plus the extended-key flag in bit 24. The keyboard-input docs describe the pair:

> The keyboard driver provides … a virtual-key code, which is a device-independent value that identifies the purpose of the key, [and] a scan code, which is the value the keyboard hardware generates when the user presses a key.
>
> — [_Keyboard Input_][keyboardinput], Microsoft Learn

`TranslateMessage` is what turns a `WM_KEYDOWN` into a `WM_CHAR` (the produced **text**) using the active layout — which is why the pump calls it before `DispatchMessageW`. Toolkits keep raw `WM_KEYDOWN` virtual-keys (for shortcuts and physical-key gameplay) separate from `WM_CHAR` text, exactly the three-way scancode/keysym/text separation the concept describes.

**IME / text input.** The modern composition API is the [Text Services Framework (TSF)][tsf] ([IME pre-edit / composition][pec]) — but the survey-wide finding is that **no surveyed toolkit uses TSF**; every one falls back to legacy **IMM32**, handling `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION` (reading `GCS_COMPSTR` for the **pre-edit** string and `GCS_RESULTSTR` for the **commit** string via `ImmGetCompositionStringW`) and positioning the candidate window with `ImmSetCandidateWindow`. The pre-edit/commit distinction is the same one Wayland's `zwp_text_input_v3` and AppKit's `NSTextInputClient` expose; on Win32 it lives in the IMM32 composition messages.

**Pointer.** Cursor motion and buttons arrive as `WM_MOUSEMOVE`, `WM_LBUTTONDOWN`, etc., with the position packed (in client pixels) into `lParam` — this is the **accelerated/absolute** stream a GUI wants. The **raw/relative** stream for first-person cameras is a separate source ([raw vs accelerated pointer][rap]): the app calls [`RegisterRawInputDevices`][regrawinput] and then reads un-accelerated deltas from `WM_INPUT` via [`GetRawInputData`][getrawinputdata]. The [_Raw Input_][rawinput] model is the Windows counterpart of Wayland's `zwp_relative_pointer_v1` + pointer-constraints.

> [!NOTE]
> **Wheel delta accumulation.** `WM_MOUSEWHEEL` reports rotation in the high word of `wParam` as a multiple of `WHEEL_DELTA` (`120`) — the same **120-per-detent** convention Wayland's `wl_pointer.axis_value120` uses ([Chromium Ozone][ozone] notes the shared convention). A high-resolution wheel or precision touchpad sends sub-`120` deltas, so the client **accumulates** them and emits one notch per `120` units accumulated, carrying the remainder — the accumulator shown under [raw vs accelerated pointer][rap]. [`WM_MOUSEWHEEL`][wmmousewheel] documents the `WHEEL_DELTA` quantum.

---

## Coordinates & scaling

Win32's native unit is the **physical pixel**, and the DPI story is the platform's sharpest edge ([logical vs physical coords][lpc], [the scale factor][scale]). A process declares its **DPI awareness** up front; the recommended mode is **Per-Monitor-V2** (`DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, set with `SetProcessDpiAwarenessContext` or in the manifest), under which the OS reports true physical pixels and hands the app the scale per monitor. The DPI-awareness modes are enumerated in [`DPI_AWARENESS`][dpiawareness]; the high-DPI guide frames the choice:

> If a desktop application declares itself … Per Monitor (V2) DPI aware, the system will not bitmap-stretch its UI. … it is the application's responsibility to adjust the scale of its content in response to DPI changes.
>
> — [_High DPI Desktop Application Development on Windows_][hidpi], Microsoft Learn

A Per-Monitor-V2 window that crosses a monitor boundary (or whose monitor's scale changes) receives [`WM_DPICHANGED`][wmdpichanged] ([mixed-DPI migration][scale]): the new X DPI is in the **low word** of `wParam`, the new Y DPI in the **high word** (`scale = dpi / 96`), and `lParam` points at the OS-suggested new window rectangle the handler should adopt with `SetWindowPos`. The arithmetic is the byte-deterministic `WM_DPICHANGED` snippet in [the scale-factor concept][scale]. A process that does **not** opt in is silently DPI-virtualized: the OS lies that the screen is 96 DPI and bitmap-stretches the result (blurry). This per-window, message-driven DPI model is richer than X11's single global `Xft.dpi` and closer in spirit to Wayland's per-surface `preferred_scale`.

> [!NOTE]
> **Origin convention.** Win32 window/client coordinates are **y-down** with the origin at the top-left — the same as X11 and Wayland, the opposite of [AppKit][appkit]'s y-up default. `GetClientRect` (used by the example) returns the drawable client area with its origin at `(0, 0)`.

---

## Decorations & multi-window/popups

**Decorations are server-side** ([CSD vs SSD][csd]). The non-client area — titlebar, the system menu and min/max/close buttons, the resize border, and the drop shadow — is drawn by the OS: `DefWindowProcW` handles the non-client `WM_NC*` messages, and the Desktop Window Manager (DWM) composites the frame. The application selects _which_ elements appear through the `WS_*` window style passed to `CreateWindowExW` (the example's `WS_OVERLAPPEDWINDOW` asks for the full titled-resizable set); there is no negotiation handshake as on Wayland. An app that wants custom chrome uses `WS_POPUP` (or extends the client area into the frame via `WM_NCCALCSIZE` + the DWM) and draws the titlebar itself — but the **default is OS-drawn**.

**Multi-window** is first-class and cheap: any number of top-level `HWND`s share the thread's one message queue and `WndProc`-dispatch loop. Stacking and ownership are expressed at creation — an **owned** window (a non-`null` `hWndParent` on a top-level) stays above its owner and minimizes with it; `WS_EX_TOPMOST` pins a window above non-topmost windows; `WS_CHILD` clips a window inside a parent's client area.

**Popups / menus.** Transient surfaces use `WS_POPUP` windows, typically with `WS_EX_TOOLWINDOW` (no taskbar button) and `WS_EX_NOACTIVATE` (does not steal focus). Native menus are real OS objects — `CreatePopupMenu` + `TrackPopupMenu`, which the [_Menus_][menus] API documents and which spins its own tracking loop and dismisses on click-outside for you. This contrasts with the Linux [override-redirect vs xdg_popup grab][orx] fork: on Win32 a popup _can_ be placed at an absolute screen coordinate (like X11 override-redirect), and click-outside dismissal for a custom popup is the app's job (commonly via `SetCapture` or a `WH_MOUSE` hook) — whereas Wayland's compositor owns popup placement and the grab. Pure windowing libraries ([winit][winit], [GLFW][glfw]) expose none of the menu machinery and leave it to the app.

---

## Clipboard & drag-and-drop

**Clipboard** is the User32 clipboard API: `OpenClipboard(hwnd)` / `EmptyClipboard` / `SetClipboardData(format, handle)` / `GetClipboardData(format)` / `CloseClipboard`, with data tagged by a clipboard format (`CF_UNICODETEXT`, `CF_BITMAP`, `CF_HDROP`, or a registered custom format). The key Win32-specific feature is **delayed rendering**: a source can place a format on the clipboard with a `null` handle, promising to produce the bytes only if some consumer actually asks. The clipboard-operations doc describes the contract:

> A window can delay rendering clipboard data in one or more formats … by passing a `NULL` handle to `SetClipboardData`. … the system sends the clipboard owner a `WM_RENDERFORMAT` message when [a format] is requested … and a `WM_RENDERALLFORMATS` message before the owner is destroyed.
>
> — [_Clipboard Operations_][clipops], Microsoft Learn

So a window that owns the clipboard must handle `WM_RENDERFORMAT` (render one format on demand) and `WM_RENDERALLFORMATS` (render everything before it closes). This lazy, pull-on-demand model is conceptually close to AppKit's promised-`NSPasteboard` data and unlike X11's eager selection-and-`INCR` chunking. The set of standard formats is enumerated in [_Clipboard Formats_][clipformats].

**Drag-and-drop** is **OLE-based**, not part of the windowing API proper: a drop target implements the `IDropTarget` COM interface and registers with `RegisterDragDrop(hwnd, pDropTarget)`; a drag source uses `DoDragDrop` with an `IDataObject` and `IDropSource`. (The simpler receive-only path — accepting dropped files — uses `DragAcceptFiles` + the `WM_DROPFILES`/`CF_HDROP` shell mechanism.) Reaching the full OLE DnD surface from D is one of the cases the binding note flags: it is COM, so a full implementation pulls in the [`windows-d`][windows-d] projection rather than `core.sys.windows`.

---

## What toolkits build on this

Every Windows-capable toolkit in the survey bottoms out in the same `RegisterClassExW` → `CreateWindowExW` → `WndProc` + message-pump calls this survey describes:

- **[winit][winit]** — its Win32 backend (`winit-win32`) registers a window class, creates the `HWND`, and runs the `GetMessage` pump; it sets Per-Monitor-V2 awareness and handles `WM_DPICHANGED`, keeps `WM_KEYDOWN` virtual-keys separate from `WM_CHAR`, uses `WM_INPUT` for raw mouse motion, and carries the `WM_ENTERSIZEMOVE` + dummy-`WM_MOUSEMOVE` trick for the modal resize loop.
- **[SDL3][sdl3]** — `SDL_windowswindow.c` creates the `HWND` and `SDL_windowsevents.c` runs the pump; it arms a `SetTimer` to keep iterating during the modal resize loop, accumulates `WM_MOUSEWHEEL` deltas against `WHEEL_DELTA`, and reports the window in **physical pixels** (the physical-coordinate platform).
- **[Qt 6][qt6]** — the `qwindows` QPA plugin wraps the `HWND` (`qwindowswindow.cpp`), its event dispatcher wraps the message pump, and it carefully separates the `WM_GETDPISCALEDSIZE`/`WM_DPICHANGED` handling from spontaneous drags to avoid double-scaling.
- **[Chromium Ozone][ozone]** — on Windows, Ozone's `HWND`-backed surface plugs the message loop into Chromium's `base::MessagePump`, and it notes the `WM_MOUSEWHEEL` "120-per-detent convention shared with Windows" when normalizing wheel deltas.

---

## Sources

- **Win32 messaging & windowing** (Microsoft Learn, Wayback-pinned — `learn.microsoft.com` is bot-hostile to the link checker): [_About Messages and Message Queues_][msgqueue], [_Window Classes_][winclasses], [_About Window Classes_][aboutwinclasses], [_Window Messages_][winmessages], [_Writing the Window Procedure_][wndproc], [_Your First Windows Program_][firstprog].
- **API reference**: [`RegisterClassExW`][registerclassex], [`CreateWindowExW`][createwindowex], [`ShowWindow`][showwindow], [`GetMessage`][getmessage], [`DefWindowProcW`][defwindowproc].
- **DPI / scaling**: [_High DPI Desktop Application Development_][hidpi], [`DPI_AWARENESS`][dpiawareness], [`WM_DPICHANGED`][wmdpichanged].
- **Input**: [_Keyboard Input_][keyboardinput], [_Raw Input_][rawinput], [`RegisterRawInputDevices`][regrawinput], [`GetRawInputData`][getrawinputdata], [`WM_MOUSEWHEEL`][wmmousewheel], the [Text Services Framework][tsf].
- **Clipboard & decorations**: [_Clipboard Operations_][clipops] (delayed rendering, `WM_RENDERFORMAT`), [_Clipboard Formats_][clipformats], [_Menus_][menus].
- **D bindings** — druntime's built-in [`core.sys.windows`][coresyswindows] (used by the example, zero third-party); the actively-maintained full-SDK fork [`RolandTaverner/windows-d`][windows-d] (use this, **not** the unmaintained [`rumbu13/windows-d`][windows-d-orig]).
- **This survey's example** — [`./example/app.d`](./example/app.d).
- **Cross-references** — the [window-system index][index] and shared [concepts][concepts]; sibling OS-API surveys [X11][x11], [Wayland][wayland], [AppKit][appkit]; the per-toolkit Win32 findings in [winit][winit], [SDL3][sdl3], [Qt 6][qt6], [Chromium Ozone][ozone], [GLFW][glfw], [GTK 4][gtk4], [JUCE][juce]; cross-tree [async-io][async-io].

<!-- References -->

<!-- Sibling deep-dives (two levels up) -->

[index]: ../../index.md
[concepts]: ../../concepts.md
[winit]: ../../winit.md
[sdl3]: ../../sdl3.md
[qt6]: ../../qt6.md
[ozone]: ../../chromium-ozone.md
[glfw]: ../../glfw.md
[gtk4]: ../../gtk4.md
[juce]: ../../juce.md

<!-- Sibling OS-API surveys (one level up) -->

[x11]: ../x11/
[wayland]: ../wayland/
[appkit]: ../appkit/

<!-- Cross-tree -->

[async-io]: ../../../async-io/index.md

<!-- Concept anchors -->

[csd]: ../../concepts.md#csd-vs-ssd
[skv]: ../../concepts.md#scancode-keysym-virtualkey
[lpc]: ../../concepts.md#logical-vs-physical-coords
[scale]: ../../concepts.md#scale-factor
[pec]: ../../concepts.md#pre-edit-composition
[orx]: ../../concepts.md#override-redirect-vs-xdg-popup-grab
[rap]: ../../concepts.md#raw-vs-accelerated-pointer
[nbnw]: ../../concepts.md#no-buffer-no-window
[fcv]: ../../concepts.md#frame-callback-vsync
[rvc]: ../../concepts.md#readiness-vs-completion-windowing
[modal]: ../../concepts.md#win32-modal-resize-loop

<!-- D bindings (GitHub) -->

[coresyswindows]: https://github.com/dlang/dmd/tree/master/druntime/src/core/sys/windows
[windows-d]: https://github.com/RolandTaverner/windows-d
[windows-d-orig]: https://github.com/rumbu13/windows-d

<!-- Microsoft Learn (Wayback-pinned, bot-hostile host) -->

[msgqueue]: https://web.archive.org/web/20260609094943/https://learn.microsoft.com/en-us/windows/win32/winmsg/about-messages-and-message-queues
[winclasses]: https://web.archive.org/web/20260430182649/https://learn.microsoft.com/en-us/windows/win32/winmsg/window-classes
[aboutwinclasses]: https://web.archive.org/web/20260516074324/https://learn.microsoft.com/en-us/windows/win32/winmsg/about-window-classes
[winmessages]: https://web.archive.org/web/20260425191009/https://learn.microsoft.com/en-us/windows/win32/learnwin32/window-messages
[wndproc]: https://web.archive.org/web/20260424155728/https://learn.microsoft.com/en-us/windows/win32/learnwin32/writing-the-window-procedure
[firstprog]: https://web.archive.org/web/20260420213210/https://learn.microsoft.com/en-us/windows/win32/learnwin32/your-first-windows-program
[registerclassex]: https://web.archive.org/web/20260601024121/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclassexw
[createwindowex]: https://web.archive.org/web/20260504062536/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createwindowexw
[showwindow]: https://web.archive.org/web/20260528084618/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow
[getmessage]: https://web.archive.org/web/20260420210137/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessage
[defwindowproc]: https://web.archive.org/web/20260609095226/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-defwindowprocw
[hidpi]: https://web.archive.org/web/20260602171007/https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
[dpiawareness]: https://web.archive.org/web/20260428034343/https://learn.microsoft.com/en-us/windows/win32/api/windef/ne-windef-dpi_awareness
[wmdpichanged]: https://web.archive.org/web/20260428034332/https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[keyboardinput]: https://web.archive.org/web/20260528084618/https://learn.microsoft.com/en-us/windows/win32/inputdev/keyboard-input
[rawinput]: https://web.archive.org/web/20260421141757/https://learn.microsoft.com/en-us/windows/win32/inputdev/raw-input
[regrawinput]: https://web.archive.org/web/20260306223227/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerrawinputdevices
[getrawinputdata]: https://web.archive.org/web/20260227023243/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getrawinputdata
[wmmousewheel]: https://web.archive.org/web/20260609095045/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel
[tsf]: https://web.archive.org/web/20221114201716/https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework
[clipops]: https://web.archive.org/web/20260217132918/https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations
[clipformats]: https://web.archive.org/web/20260413003418/https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats
[menus]: https://web.archive.org/web/20260520182433/https://learn.microsoft.com/en-us/windows/win32/menurc/menus
