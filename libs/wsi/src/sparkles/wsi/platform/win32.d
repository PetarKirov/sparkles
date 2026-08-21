/**
Native Win32 window lifecycle and Event Horizon host adapter.

User32 callbacks only append owned events. Application code runs later at
`drain`; `dispatchPending` is the non-blocking half of Event Horizon's hosted
wait concept, and `wait` combines the IOCP mirror event with the thread message
queue through `MsgWaitForMultipleObjectsEx`.
*/
module sparkles.wsi.platform.win32;

version (Windows):

import core.sys.windows.windows;
import core.sys.windows.imm : ATTR_CONVERTED, ATTR_FIXEDCONVERTED,
    ATTR_TARGET_CONVERTED, ATTR_TARGET_NOTCONVERTED, GCS_COMPATTR,
    GCS_COMPSTR, GCS_CURSORPOS, GCS_RESULTSTR,
    ISC_SHOWUICOMPOSITIONWINDOW, WM_IME_CHAR, WM_IME_COMPOSITION,
    WM_IME_ENDCOMPOSITION, WM_IME_SETCONTEXT, WM_IME_STARTCOMPOSITION;
import std.math : isFinite;

import sparkles.base.text.utf16 : utf16ToUtf8, utf8ToUtf16z;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr,
    ioOk;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.loop : EventQueue;
import sparkles.wsi.types;

pragma(lib, "imm32");

private enum UINT WM_DPICHANGED_ = 0x02E0;
private enum DWORD QS_ALLINPUT_ = 0x04FF;
private enum DWORD MWMO_INPUTAVAILABLE_ = 0x0004;
private enum DWORD WAIT_FAILED_ = 0xFFFF_FFFF;
private enum DWORD WAIT_TIMEOUT_ = 258;
private enum int GWLP_USERDATA_ = -21;

// druntime currently models HIMC as DWORD, but Win64 declares it as a
// pointer-sized handle. Redeclare the small IMM32 surface with the correct ABI
// and callback-compatible attributes.
private alias HIMC = HANDLE;

private extern (Windows) nothrow
{
    UINT GetDpiForWindow(HWND hwnd);
    BOOL SetProcessDpiAwarenessContext(void* context);
    LONG_PTR SetWindowLongPtrW(HWND hwnd, int index, LONG_PTR value);
    LONG_PTR GetWindowLongPtrW(HWND hwnd, int index);
    DWORD MsgWaitForMultipleObjectsEx(DWORD count, const(HANDLE)* handles,
        DWORD milliseconds, DWORD wakeMask, DWORD flags);
    HIMC ImmGetContext(HWND hwnd);
    BOOL ImmReleaseContext(HWND hwnd, HIMC context);
    LONG ImmGetCompositionStringW(HIMC context, DWORD index, PVOID buffer,
        DWORD bufferBytes);
}

/**
One main-thread Win32 WSI owner.

The fixed limits make callback delivery allocation-free and give overload a
typed failure path. The owner is address-pinned because `GWLP_USERDATA` points
into its slot array.
*/
struct Win32Wsi
{
    enum maxWindows = 16;
    enum maxEvents = 128;

    @disable this(this);

    private struct Slot
    {
        Win32Wsi* owner;
        HWND hwnd;
        uint generation;
        bool live;
        bool ready;
        bool composing;
        bool pointerInside;
        bool cursorVisible = true;
        ubyte buttonsDown;
        wchar pendingHighSurrogate;
        HCURSOR cursor;
        SurfaceMetrics metrics;
        PhysicalPosition lastPointer;
    }

    private HINSTANCE instance_;
    private DWORD ownerThread_;
    private Slot[maxWindows] windows_;
    private EventQueue!maxEvents events_;
    private ulong nextSequence_ = 1;
    private bool open_;
    private bool closed_;
    private bool hasStickyError_;
    private WsiError stickyError_;

    /** Opens the User32 adapter on the calling (UI) thread. */
    static WsiResult!void open(out Win32Wsi wsi)
    {
        wsi.instance_ = GetModuleHandleW(null);
        if (wsi.instance_ is null)
            return win32Failure!void(WsiOperation.open, GetLastError(),
                "GetModuleHandleW failed");

        wsi.ownerThread_ = GetCurrentThreadId();
        // Process-global and therefore best effort: a host may have selected
        // the same or another awareness context before opening WSI.
        SetProcessDpiAwarenessContext(cast(void*) -4);

        WNDCLASSEXW wc;
        wc.cbSize = WNDCLASSEXW.sizeof;
        wc.lpfnWndProc = &windowProcedure;
        wc.hInstance = wsi.instance_;
        wc.hCursor = LoadCursorW(null, IDC_ARROW);
        wc.lpszClassName = className.ptr;
        if (RegisterClassExW(&wc) == 0)
        {
            const code = GetLastError();
            if (code != ERROR_CLASS_ALREADY_EXISTS)
                return win32Failure!void(WsiOperation.open, code,
                    "RegisterClassExW failed");
        }

        wsi.open_ = true;
        return wsiOk();
    }

    /** Creates a native HWND and emits `Ready` before its first expose. */
    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        auto owner = requireOwner!WindowId(WsiOperation.createWindow);
        if (owner.hasError)
            return owner;
        if (closed_)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "WSI is closed", WsiErrorKind.closed);
        if (config.logicalSize.width < 0 || config.logicalSize.height < 0
            || !config.logicalSize.width.isFinite
            || !config.logicalSize.height.isFinite
            || config.logicalSize.width > int.max
            || config.logicalSize.height > int.max)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "invalid logical window size", WsiErrorKind.invalidArgument);
        if (config.transparent
            || config.state == WindowStartupState.fullscreen)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "requested Win32 startup configuration is not implemented",
                WsiErrorKind.unsupported);

        size_t index = size_t.max;
        foreach (i, ref slot; windows_)
            if (!slot.live)
            {
                index = i;
                break;
            }
        if (index == size_t.max)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "Win32 window capacity reached", WsiErrorKind.capacity);

        auto parent = parentHandle(config.parent);
        if (parent.hasError)
            return wsiErr!WindowId(parent.error);

        wchar[257] title;
        auto converted = utf8ToUtf16z(config.title.value, title[]);
        if (converted.hasError)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "window title is not valid bounded UTF-8",
                WsiErrorKind.invalidArgument);

        DWORD style = config.decorations == DecorationPreference.none
            ? WS_POPUP : WS_OVERLAPPEDWINDOW;
        if (!config.resizable)
            style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);

        RECT outer = RECT(0, 0, cast(int) config.logicalSize.width,
            cast(int) config.logicalSize.height);
        if (!AdjustWindowRectEx(&outer, style, FALSE, 0))
            return win32Failure!WindowId(WsiOperation.createWindow,
                GetLastError(), "AdjustWindowRectEx failed");

        ref slot = windows_[index];
        ++slot.generation;
        if (slot.generation == 0)
            ++slot.generation;
        slot.owner = &this;
        slot.live = true;
        slot.ready = false;
        slot.hwnd = null;
        auto id = WindowId(cast(uint) index + 1, slot.generation);

        HWND hwnd = CreateWindowExW(0, className.ptr, title.ptr, style,
            CW_USEDEFAULT, CW_USEDEFAULT, outer.right - outer.left,
            outer.bottom - outer.top, parent.value, null, instance_, &slot);
        if (hwnd is null)
        {
            slot.live = false;
            slot.owner = null;
            return win32Failure!WindowId(WsiOperation.createWindow,
                GetLastError(), "CreateWindowExW failed");
        }
        slot.hwnd = hwnd;
        slot.metrics = metricsOf(hwnd);
        slot.ready = true;
        const hadSticky = hasStickyError_;
        emit(id, ReadyEvent(slot.metrics));
        if (!hadSticky && hasStickyError_)
        {
            DestroyWindow(hwnd);
            return wsiErr!WindowId(stickyError_);
        }

        if (config.visible)
        {
            final switch (config.state)
            {
                case WindowStartupState.normal:
                    ShowWindow(hwnd, SW_SHOW);
                    break;
                case WindowStartupState.minimized:
                    ShowWindow(hwnd, SW_SHOWMINIMIZED);
                    break;
                case WindowStartupState.maximized:
                    ShowWindow(hwnd, SW_SHOWMAXIMIZED);
                    break;
                case WindowStartupState.fullscreen:
                    // Rejected before native creation; retained for the
                    // exhaustive enum switch.
                    break;
            }
        }
        if (config.visible)
            UpdateWindow(hwnd);
        return wsiOk(id);
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto slot = checkedSlot(id, WsiOperation.close);
        if (slot.hasError)
            return wsiErr!void(slot.error);
        if (!DestroyWindow(windows_[slot.value].hwnd))
            return win32Failure!void(WsiOperation.close, GetLastError(),
                "DestroyWindow failed");
        return wsiOk();
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto slot = checkedSlot(id, WsiOperation.queryHandle);
        if (slot.hasError)
            return wsiErr!NativeHandles(slot.error);

        NativeHandles handles;
        handles.display = DisplayHandle(Win32DisplayHandle(cast(void*) instance_));
        handles.window = WindowHandle(Win32WindowHandle(
            cast(void*) windows_[slot.value].hwnd));
        return wsiOk(handles);
    }

    /** Drains all currently queued messages for this thread; never waits. */
    WsiResult!size_t pumpMessages()
    {
        auto owner = requireOwner!size_t(WsiOperation.dispatch);
        if (owner.hasError)
            return owner;

        size_t count;
        MSG message;
        while (PeekMessageW(&message, null, 0, 0, PM_REMOVE))
        {
            ++count;
            if (message.message == WM_QUIT)
                continue;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if (hasStickyError_)
            return wsiErr!size_t(stickyError_);
        return wsiOk(count);
    }

    /** Event Horizon native-host concept: non-blocking native dispatch. */
    bool dispatchPending()
    {
        auto pumped = pumpMessages();
        return pumped.hasValue && pumped.value != 0;
    }

    /**
    Event Horizon native-host concept: the single combined blocking wait.

    `completionHandle` is Event Horizon's IOCP mirror event. User32 owns the
    other implicit source, the current thread's message queue.
    */
    IoResult!bool wait(void* completionHandle, uint timeoutMilliseconds)
    {
        HANDLE handle = cast(HANDLE) completionHandle;
        const result = MsgWaitForMultipleObjectsEx(1, &handle,
            timeoutMilliseconds, QS_ALLINPUT_, MWMO_INPUTAVAILABLE_);
        if (result == WAIT_FAILED_)
            return ioErr!bool(cast(int) GetLastError(), OpKind.none,
                IoErrorStage.completion,
                "MsgWaitForMultipleObjectsEx failed");
        return ioOk(result != WAIT_TIMEOUT_);
    }

    WsiResult!size_t drain(Sink)(scope Sink sink) => events_.drain(sink);

    size_t pendingEvents() const pure nothrow @nogc => events_.length;

    /** Destroys every live HWND on the owner thread. */
    WsiResult!void close()
    {
        auto owner = requireOwner!void(WsiOperation.close);
        if (owner.hasError)
            return owner;
        closeNow();
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
    }

    /// RAII teardown: idempotent and best-effort; errors join the sticky slot.
    private void closeNow()
    {
        if (closed_ || !open_)
            return;
        foreach (ref slot; windows_)
            if (slot.live && slot.hwnd !is null)
                DestroyWindow(slot.hwnd);
        closed_ = true;
        open_ = false;
    }

    ~this()
    {
        closeNow();
    }

    private WsiResult!HWND parentHandle(WindowId id)
    {
        if (!id.valid)
            return wsiOk(cast(HWND) null);
        auto slot = checkedSlot(id, WsiOperation.createWindow);
        if (slot.hasError)
            return wsiErr!HWND(slot.error);
        return wsiOk(windows_[slot.value].hwnd);
    }

    private WsiResult!size_t checkedSlot(WindowId id, WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        if (!id.valid || id.slot > maxWindows)
            return win32Failure!size_t(operation, 0, "invalid Win32 window id",
                WsiErrorKind.staleId);
        size_t index = cast(size_t) id.slot - 1;
        const slot = windows_[index];
        if (!slot.live || slot.generation != id.generation)
            return win32Failure!size_t(operation, 0, "stale Win32 window id",
                WsiErrorKind.staleId);
        return wsiOk(index);
    }

    private WsiResult!T requireOwner(T)(WsiOperation operation)
    {
        if (!open_ && !closed_)
            return win32Failure!T(operation, 0, "Win32 WSI is not open",
                WsiErrorKind.closed);
        if (ownerThread_ != GetCurrentThreadId())
            return win32Failure!T(operation, 0,
                "Win32 WSI called from a non-owner thread",
                WsiErrorKind.wrongThread);
        static if (is(T == void))
            return wsiOk();
        else
            return wsiOk(T.init);
    }

    // Fire-and-forget by design: a full queue lands in the sticky error,
    // which the next fallible operation reports.
    private void emit(Payload)(WindowId id, Payload payload) nothrow
    {
        auto result = events_.push(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload)));
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    private void remember(WsiError error) nothrow
    {
        if (!hasStickyError_)
        {
            error.backend = BackendKind.win32;
            stickyError_ = error;
            hasStickyError_ = true;
        }
    }

    private void rememberNative(WsiOperation operation, long nativeCode,
        scope const(char)[] diagnostic,
        WsiErrorKind kind = WsiErrorKind.nativeFailure) nothrow
    {
        remember(wsiError(kind, operation, BackendKind.win32, nativeCode,
            diagnostic));
    }

    private void emitCommittedText(WindowId id,
        scope const(wchar)[] wide) nothrow
    {
        char[256] bytes;
        auto converted = utf16ToUtf8(wide, bytes[]);
        if (converted.hasError)
        {
            rememberNative(WsiOperation.dispatch,
                cast(long) converted.error.required,
                "IMM32 commit exceeds bounded UTF-8 storage",
                converted.error.required > bytes.length
                    ? WsiErrorKind.capacity : WsiErrorKind.nativeFailure);
            return;
        }

        TextCommittedEvent committed;
        if (!committed.text.assign(bytes[0 .. converted.value]))
        {
            rememberNative(WsiOperation.dispatch, cast(long) converted.value,
                "IMM32 commit exceeds bounded event storage",
                WsiErrorKind.capacity);
            return;
        }
        emit(id, committed);
    }

    private void emitComposition(WindowId id, scope const(wchar)[] wide,
        scope const(ubyte)[] attributes, size_t cursorUnits) nothrow
    {
        char[512] bytes;
        auto converted = utf16ToUtf8(wide, bytes[]);
        if (converted.hasError)
        {
            rememberNative(WsiOperation.dispatch,
                cast(long) converted.error.required,
                "IMM32 preedit exceeds bounded UTF-8 storage",
                converted.error.required > bytes.length
                    ? WsiErrorKind.capacity : WsiErrorKind.nativeFailure);
            return;
        }

        CompositionEvent composition;
        if (!composition.preedit.assign(bytes[0 .. converted.value]))
        {
            rememberNative(WsiOperation.dispatch, cast(long) converted.value,
                "IMM32 preedit exceeds bounded event storage",
                WsiErrorKind.capacity);
            return;
        }
        composition.cursor = cast(ushort) utf8Offset(wide, cursorUnits);

        const attributeCount = attributes.length < wide.length
            ? attributes.length : wide.length;
        size_t firstTarget = size_t.max;
        size_t targetEnd;
        size_t at;
        while (at < attributeCount
            && composition.segmentCount < composition.segments.length)
        {
            const style = compositionStyle(attributes[at]);
            size_t end = at + 1;
            while (end < attributeCount
                && compositionStyle(attributes[end]) == style)
                ++end;

            const startByte = utf8Offset(wide, at);
            const endByte = utf8Offset(wide, end);
            composition.segments[composition.segmentCount++] =
                CompositionSegment(cast(ushort) startByte,
                    cast(ushort)(endByte - startByte), style);
            if (style == CompositionSegmentStyle.selected)
            {
                if (firstTarget == size_t.max)
                    firstTarget = startByte;
                targetEnd = endByte;
            }
            at = end;
        }
        if (firstTarget != size_t.max)
        {
            composition.selectionStart = cast(ushort) firstTarget;
            composition.selectionLength = cast(ushort)(targetEnd - firstTarget);
        }
        emit(id, composition);
    }

    private void handleImeComposition(ref Slot slot, WindowId id,
        LPARAM flags) nothrow
    {
        auto context = ImmGetContext(slot.hwnd);
        if (context is null)
        {
            rememberNative(WsiOperation.dispatch, GetLastError(),
                "ImmGetContext failed");
            return;
        }
        scope (exit) ImmReleaseContext(slot.hwnd, context);

        if ((flags & GCS_RESULTSTR) != 0)
        {
            wchar[256] result;
            size_t resultUnits;
            if (readImeString(context, GCS_RESULTSTR, result,
                resultUnits, "ImmGetCompositionStringW result failed"))
                emitCommittedText(id, result[0 .. resultUnits]);
        }

        if ((flags & GCS_COMPSTR) != 0)
        {
            wchar[256] preedit;
            size_t preeditUnits;
            if (!readImeString(context, GCS_COMPSTR, preedit,
                preeditUnits, "ImmGetCompositionStringW preedit failed"))
                return;

            ubyte[256] attributes;
            size_t attributeCount;
            if ((flags & GCS_COMPATTR) != 0)
            {
                const bytes = ImmGetCompositionStringW(context, GCS_COMPATTR,
                    attributes.ptr, cast(DWORD) attributes.length);
                if (bytes < 0)
                {
                    rememberNative(WsiOperation.dispatch, bytes,
                        "ImmGetCompositionStringW attributes failed");
                    return;
                }
                attributeCount = cast(size_t) bytes;
                if (attributeCount > attributes.length)
                {
                    rememberNative(WsiOperation.dispatch, bytes,
                        "IMM32 attributes exceed bounded storage",
                        WsiErrorKind.capacity);
                    return;
                }
            }

            size_t cursorUnits;
            if ((flags & GCS_CURSORPOS) != 0)
            {
                const cursor = ImmGetCompositionStringW(context,
                    GCS_CURSORPOS, null, 0);
                if (cursor >= 0)
                    cursorUnits = cast(size_t) cursor;
            }
            emitComposition(id, preedit[0 .. preeditUnits],
                attributes[0 .. attributeCount], cursorUnits);
        }
    }

    private bool readImeString(size_t N)(HIMC context, DWORD kind,
        ref wchar[N] destination, out size_t units,
        scope const(char)[] diagnostic) nothrow
    {
        const requiredBytes = ImmGetCompositionStringW(context, kind, null, 0);
        if (requiredBytes < 0 || (requiredBytes & 1) != 0)
        {
            rememberNative(WsiOperation.dispatch, requiredBytes, diagnostic);
            return false;
        }
        if (requiredBytes > destination.length * wchar.sizeof)
        {
            rememberNative(WsiOperation.dispatch, requiredBytes,
                "IMM32 UTF-16 string exceeds bounded storage",
                WsiErrorKind.capacity);
            return false;
        }
        if (requiredBytes != 0)
        {
            const copied = ImmGetCompositionStringW(context, kind,
                destination.ptr, cast(DWORD) requiredBytes);
            if (copied != requiredBytes)
            {
                rememberNative(WsiOperation.dispatch, copied, diagnostic);
                return false;
            }
        }
        units = cast(size_t) requiredBytes / wchar.sizeof;
        return true;
    }

    private static size_t utf8Offset(scope const(wchar)[] wide,
        size_t units) pure nothrow @nogc
    {
        if (units > wide.length)
            units = wide.length;
        size_t bytes;
        size_t at;
        while (at < units)
        {
            const unit = wide[at];
            if (unit >= 0xD800 && unit <= 0xDBFF)
            {
                // An IMM attribute may put a boundary between surrogate code
                // units. Both sides map to the scalar's UTF-8 start/end.
                if (at + 1 >= units)
                    break;
                bytes += 4;
                at += 2;
            }
            else
            {
                bytes += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
                ++at;
            }
        }
        return bytes;
    }

    private static CompositionSegmentStyle compositionStyle(
        ubyte attribute) pure nothrow @nogc
    {
        switch (attribute)
        {
            case ATTR_TARGET_CONVERTED:
            case ATTR_TARGET_NOTCONVERTED:
                return CompositionSegmentStyle.selected;
            case ATTR_CONVERTED:
            case ATTR_FIXEDCONVERTED:
                return CompositionSegmentStyle.converted;
            default:
                return CompositionSegmentStyle.underline;
        }
    }

    private void handleUtf16Unit(ref Slot slot, WindowId id,
        wchar unit) nothrow
    {
        if (unit >= 0xD800 && unit <= 0xDBFF)
        {
            slot.pendingHighSurrogate = unit;
            return;
        }
        if (unit >= 0xDC00 && unit <= 0xDFFF)
        {
            if (slot.pendingHighSurrogate == 0)
                return;
            const wchar[2] pair = [slot.pendingHighSurrogate, unit];
            slot.pendingHighSurrogate = 0;
            emitCommittedText(id, pair[]);
            return;
        }
        slot.pendingHighSurrogate = 0;
        const wchar[1] scalar = [unit];
        emitCommittedText(id, scalar[]);
    }

    /**
    Stores the window's standard cursor and applies it on `WM_SETCURSOR`
    (the correct Win32 pattern — setting it eagerly is undone by the next
    mouse message). CSS `grab`/`grabbing` have no stock cursor and use
    `IDC_SIZEALL` as the documented nearest shape; custom images are a
    later slice.
    */
    WsiResult!void setCursor(WindowId id, PointerShape shape)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        auto cursor = LoadCursorW(null, win32CursorId(shape));
        if (cursor is null)
            return win32Failure!void(WsiOperation.command, GetLastError(),
                "LoadCursorW failed for a stock cursor");
        windows_[checked.value].cursor = cursor;
        return wsiOk();
    }

    /// Visibility is per-window here, applied by the same WM_SETCURSOR
    /// path rather than the thread-global ShowCursor counter.
    WsiResult!void setCursorVisible(WindowId id, bool visible)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        windows_[checked.value].cursorVisible = visible;
        return wsiOk();
    }

    /// Stock cursor ids (IDC_*).
    package static const(wchar)* win32CursorId(PointerShape shape)
        @trusted pure nothrow @nogc
    {
        final switch (shape)
        {
            case PointerShape.default_: return IDC_ARROW;
            case PointerShape.text: return IDC_IBEAM;
            case PointerShape.pointer: return IDC_HAND;
            case PointerShape.ewResize: return IDC_SIZEWE;
            case PointerShape.nsResize: return IDC_SIZENS;
            case PointerShape.grab: return IDC_SIZEALL; // nearest stock
            case PointerShape.grabbing: return IDC_SIZEALL; // nearest stock
        }
    }

    /// One pointer per User32 message queue.
    private enum queuePointer = PointerId(1, 1);

    private static PhysicalPosition pointFrom(LPARAM lParam)
        pure nothrow @nogc
        => PhysicalPosition(cast(short)(lParam & 0xFFFF),
            cast(short)((lParam >> 16) & 0xFFFF));

    private void handleMouseMove(ref Slot slot, WindowId id,
        LPARAM lParam) nothrow
    {
        const at = pointFrom(lParam);
        if (!slot.pointerInside)
        {
            slot.pointerInside = true;
            // Ask for the WM_MOUSELEAVE that completes the pair.
            TRACKMOUSEEVENT track;
            track.cbSize = TRACKMOUSEEVENT.sizeof;
            track.dwFlags = TME_LEAVE;
            track.hwndTrack = slot.hwnd;
            TrackMouseEvent(&track);
            emitPointer(slot, id, PointerPhase.entered, at);
        }
        emitPointer(slot, id, PointerPhase.moved, at);
    }

    /*
    User32 delivers no client messages outside the window unless captured,
    so a drag would silently lose its motion and release the moment the
    pointer crosses the border. Implicit capture spans the first press to
    the last release, exactly the toolkit drag contract.
    */
    private void emitButton(ref Slot slot, WindowId id, bool pressed,
        PhysicalPosition at, PointerButton button) nothrow
    {
        if (pressed)
        {
            if (slot.buttonsDown == 0)
                SetCapture(slot.hwnd);
            ++slot.buttonsDown;
        }
        else if (slot.buttonsDown != 0)
        {
            --slot.buttonsDown;
            if (slot.buttonsDown == 0)
                ReleaseCapture();
        }
        emitPointer(slot, id,
            pressed ? PointerPhase.pressed : PointerPhase.released, at,
            button);
    }

    private void emitPointer(ref Slot slot, WindowId id, PointerPhase phase,
        PhysicalPosition at,
        PointerButton button = PointerButton.none) nothrow
    {
        slot.lastPointer = at;
        PointerEvent event;
        event.pointer = queuePointer;
        event.phase = phase;
        event.button = button;
        event.logicalPosition = LogicalPosition(at.x, at.y);
        event.physicalPosition = at;
        event.modifiers = currentModifiers();
        emit(id, event);
    }

    // Wheel deltas are multiples of 120 with away-from-user positive;
    // the shared convention is positive-down, so vertical flips sign.
    private void handleWheel(ref Slot slot, WindowId id, bool vertical,
        WPARAM wParam, LPARAM lParam) nothrow
    {
        const delta = cast(short)((wParam >> 16) & 0xFFFF);
        // Wheel coordinates are screen coordinates, unlike button messages.
        POINT at = POINT(cast(short)(lParam & 0xFFFF),
            cast(short)((lParam >> 16) & 0xFFFF));
        ScreenToClient(slot.hwnd, &at);
        ScrollEvent scroll;
        scroll.logicalPosition = LogicalPosition(at.x, at.y);
        scroll.physicalPosition = PhysicalPosition(at.x, at.y);
        const steps = -delta / 120.0;
        if (vertical)
        {
            scroll.dy = steps;
            scroll.discreteY = cast(int) steps;
        }
        else
        {
            scroll.dx = steps;
            scroll.discreteX = cast(int) steps;
        }
        scroll.source = ScrollSource.wheel;
        scroll.unit = ScrollUnit.logical;
        scroll.modifiers = currentModifiers();
        emit(id, scroll);
    }

    private void emitKeyboard(ref Slot slot, WindowId id, WPARAM wParam,
        LPARAM lParam, bool pressed) nothrow
    {
        const bits = cast(ULONG_PTR) lParam;
        const scanCode = cast(uint)((bits >> 16) & 0xFF);
        const extended = ((bits >> 24) & 1) != 0;
        const repeated = ((bits >> 30) & 1) != 0;

        KeyboardEvent event;
        event.physical = PhysicalKey(scanCode | (extended ? 0x100 : 0), 0);
        event.logical = win32Logical(cast(uint) wParam);
        event.location = keyLocation(cast(uint) wParam, scanCode, extended);
        event.action = pressed
            ? (repeated ? KeyAction.repeat : KeyAction.press)
            : KeyAction.release;
        event.modifiers = currentModifiers();
        event.composing = slot.composing;
        emit(id, event);
    }

    /*
    Unshifted layout identity: MAPVK_VK_TO_CHAR is the layout's base
    spelling for the virtual key (dead keys flagged in the top bit are not
    a committed spelling); keys without one keep the VK as named identity.
    */
    private static LogicalKey win32Logical(uint virtualKey) nothrow @nogc
    {
        enum uint mapVkToChar = 2; // MAPVK_VK_TO_CHAR
        const mapped = MapVirtualKeyW(virtualKey, mapVkToChar);
        const deadKey = (mapped & 0x8000_0000) != 0;
        const character = mapped & 0xFFFF;
        if (!deadKey && character >= 0x20)
            return LogicalKey(LogicalKeyKind.character,
                cast(dchar) character, virtualKey);
        return LogicalKey(LogicalKeyKind.named, dchar.init, virtualKey);
    }

    private static KeyLocation keyLocation(uint virtualKey, uint scanCode,
        bool extended) pure nothrow @nogc
    {
        switch (virtualKey)
        {
            case VK_SHIFT:
                return scanCode == 0x36 ? KeyLocation.right : KeyLocation.left;
            case VK_CONTROL:
            case VK_MENU:
                return extended ? KeyLocation.right : KeyLocation.left;
            case VK_NUMPAD0: .. case VK_DIVIDE:
                return KeyLocation.numpad;
            default:
                return KeyLocation.standard;
        }
    }

    private static Mods currentModifiers() nothrow @nogc
    {
        return Mods(
            (GetKeyState(VK_CONTROL) & 0x8000) != 0,
            (GetKeyState(VK_MENU) & 0x8000) != 0,
            (GetKeyState(VK_SHIFT) & 0x8000) != 0,
            (GetKeyState(VK_LWIN) & 0x8000) != 0
                || (GetKeyState(VK_RWIN) & 0x8000) != 0);
    }

    private static SurfaceMetrics metricsOf(HWND hwnd) nothrow
    {
        RECT client;
        GetClientRect(hwnd, &client);
        const width = client.right > client.left
            ? cast(uint)(client.right - client.left) : 0;
        const height = client.bottom > client.top
            ? cast(uint)(client.bottom - client.top) : 0;
        uint dpi = GetDpiForWindow(hwnd);
        if (dpi == 0)
            dpi = 96;
        const scale = cast(double) dpi / 96.0;
        return SurfaceMetrics(LogicalSize(width / scale, height / scale),
            PhysicalSize(width, height), ScaleFactor(scale));
    }

    private static WindowId idOf(ref Slot slot) nothrow
    {
        const index = cast(size_t)(&slot - slot.owner.windows_.ptr);
        return WindowId(cast(uint) index + 1, slot.generation);
    }

    private extern (Windows) static LRESULT windowProcedure(HWND hwnd, UINT message,
        WPARAM wParam, LPARAM lParam) nothrow
    {
        Slot* slot;
        if (message == WM_NCCREATE)
        {
            auto creation = cast(CREATESTRUCTW*) lParam;
            slot = cast(Slot*) creation.lpCreateParams;
            slot.hwnd = hwnd;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA_, cast(LONG_PTR) slot);
        }
        else
            slot = cast(Slot*) GetWindowLongPtrW(hwnd, GWLP_USERDATA_);

        if (slot is null || slot.owner is null)
            return DefWindowProcW(hwnd, message, wParam, lParam);
        auto owner = slot.owner;
        const id = idOf(*slot);

        switch (message)
        {
            case WM_NCCREATE:
                return TRUE;
            case WM_ERASEBKGND:
                return TRUE;
            case WM_CLOSE:
                owner.emit(id, CloseRequestedEvent());
                return 0;
            case WM_SETFOCUS:
                owner.emit(id, FocusChangedEvent(true));
                return 0;
            case WM_KILLFOCUS:
                owner.emit(id, FocusChangedEvent(false));
                return 0;
            case WM_KEYDOWN:
            case WM_SYSKEYDOWN:
                owner.emitKeyboard(*slot, id, wParam, lParam, true);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            case WM_KEYUP:
            case WM_SYSKEYUP:
                owner.emitKeyboard(*slot, id, wParam, lParam, false);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            case WM_CHAR:
                owner.handleUtf16Unit(*slot, id, cast(wchar) wParam);
                return 0;
            case WM_UNICHAR:
                if (wParam == UNICODE_NOCHAR)
                    return TRUE;
                if (wParam <= 0xFFFF)
                    owner.handleUtf16Unit(*slot, id, cast(wchar) wParam);
                else if (wParam <= 0x10FFFF)
                {
                    const scalar = cast(uint) wParam - 0x1_0000;
                    owner.handleUtf16Unit(*slot, id,
                        cast(wchar)(0xD800 + (scalar >> 10)));
                    owner.handleUtf16Unit(*slot, id,
                        cast(wchar)(0xDC00 + (scalar & 0x3FF)));
                }
                return 0;
            case WM_IME_STARTCOMPOSITION:
                slot.composing = true;
                owner.emit(id, CompositionEvent());
                return 0;
            case WM_IME_COMPOSITION:
                slot.composing = true;
                owner.handleImeComposition(*slot, id, lParam);
                return 0;
            case WM_IME_ENDCOMPOSITION:
                slot.composing = false;
                owner.emit(id, CompositionEvent());
                return 0;
            case WM_IME_SETCONTEXT:
                // The application renders preedit itself. Keep candidate UI
                // enabled, but suppress IMM's separate composition window.
                return DefWindowProcW(hwnd, message, wParam,
                    lParam & ~cast(LPARAM) ISC_SHOWUICOMPOSITIONWINDOW);
            case WM_IME_CHAR:
                // GCS_RESULTSTR is the single commit source. DefWindowProc
                // would turn this into WM_CHAR and duplicate the text.
                return 0;
            case WM_SETCURSOR:
                if ((lParam & 0xFFFF) == HTCLIENT)
                {
                    SetCursor(slot.cursorVisible
                        ? (slot.cursor !is null
                            ? slot.cursor
                            : LoadCursorW(null, IDC_ARROW))
                        : null);
                    return TRUE;
                }
                return DefWindowProcW(hwnd, message, wParam, lParam);
            case WM_MOUSEMOVE:
                owner.handleMouseMove(*slot, id, lParam);
                return 0;
            case WM_MOUSELEAVE:
                if (slot.pointerInside)
                {
                    slot.pointerInside = false;
                    owner.emitPointer(*slot, id, PointerPhase.left,
                        slot.lastPointer);
                }
                return 0;
            case WM_LBUTTONDOWN:
            case WM_LBUTTONUP:
                owner.emitButton(*slot, id, message == WM_LBUTTONDOWN,
                    pointFrom(lParam), PointerButton.left);
                return 0;
            case WM_MBUTTONDOWN:
            case WM_MBUTTONUP:
                owner.emitButton(*slot, id, message == WM_MBUTTONDOWN,
                    pointFrom(lParam), PointerButton.middle);
                return 0;
            case WM_RBUTTONDOWN:
            case WM_RBUTTONUP:
                owner.emitButton(*slot, id, message == WM_RBUTTONDOWN,
                    pointFrom(lParam), PointerButton.right);
                return 0;
            case WM_XBUTTONDOWN:
            case WM_XBUTTONUP:
                owner.emitButton(*slot, id, message == WM_XBUTTONDOWN,
                    pointFrom(lParam),
                    ((wParam >> 16) & 0xFFFF) == 1
                        ? PointerButton.back : PointerButton.forward);
                return TRUE;
            case WM_CAPTURECHANGED:
                // Capture was taken elsewhere; forget the held buttons so a
                // later press starts a fresh implicit capture.
                slot.buttonsDown = 0;
                return 0;
            case WM_MOUSEWHEEL:
            case WM_MOUSEHWHEEL:
                owner.handleWheel(*slot, id, message == WM_MOUSEWHEEL,
                    wParam, lParam);
                return 0;
            case WM_SIZE:
                const metrics = metricsOf(hwnd);
                if (slot.ready && metrics != slot.metrics)
                    owner.emit(id,
                        SurfaceMetricsChangedEvent(metrics));
                slot.metrics = metrics;
                return 0;
            case WM_MOVE:
                const x = cast(short)(lParam & 0xFFFF);
                const y = cast(short)((lParam >> 16) & 0xFFFF);
                if (slot.ready)
                    owner.emit(id,
                        MovedEvent(PhysicalPosition(x, y)));
                return 0;
            case WM_DPICHANGED_:
                auto suggested = cast(RECT*) lParam;
                SetWindowPos(hwnd, null, suggested.left, suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    SWP_NOACTIVATE | SWP_NOZORDER);
                const metrics = metricsOf(hwnd);
                if (slot.ready && metrics != slot.metrics)
                    owner.emit(id,
                        SurfaceMetricsChangedEvent(metrics));
                slot.metrics = metrics;
                return 0;
            case WM_PAINT:
                PAINTSTRUCT paint;
                BeginPaint(hwnd, &paint);
                EndPaint(hwnd, &paint);
                if (slot.ready)
                {
                    owner.emit(id, ExposedEvent());
                    owner.emit(id, FrameReadyEvent());
                }
                return 0;
            case WM_NCDESTROY:
                if (slot.live)
                    owner.emit(id, DestroyedEvent());
                slot.live = false;
                slot.ready = false;
                slot.composing = false;
                slot.pendingHighSurrogate = 0;
                slot.hwnd = null;
                SetWindowLongPtrW(hwnd, GWLP_USERDATA_, 0);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            default:
                return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }
}

private immutable wchar[] className = "sparkles-wsi-window"w;

private WsiResult!T win32Failure(T)(WsiOperation operation, long nativeCode,
    scope const(char)[] diagnostic,
    WsiErrorKind kind = WsiErrorKind.nativeFailure)
{
    return wsiErr!T(wsiError(kind, operation, BackendKind.win32,
        nativeCode, diagnostic));
}
