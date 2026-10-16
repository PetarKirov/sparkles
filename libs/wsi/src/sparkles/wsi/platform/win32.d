/**
Native Win32 window lifecycle and Event Horizon host adapter.

User32 callbacks only append owned events. Application code runs later at
`drain`; `dispatchPending` is the non-blocking half of Event Horizon's hosted
wait concept, and `wait` combines the IOCP mirror event with the thread message
queue through `MsgWaitForMultipleObjectsEx`.

The clipboard is owned by a hidden message-only helper window, so an offer
does not depend on an application window living. Offers use delayed
rendering: `WM_RENDERFORMAT` pulls the provider into a block the clipboard
owns, and a receive streams the clipboard's block into its sink one bounded
chunk per dispatch.
*/
module sparkles.wsi.platform.win32;

version (Windows):

import core.sys.windows.windows;
import core.sys.windows.imm : ATTR_CONVERTED, ATTR_FIXEDCONVERTED,
    ATTR_TARGET_CONVERTED, ATTR_TARGET_NOTCONVERTED, GCS_COMPATTR,
    GCS_COMPSTR, GCS_CURSORPOS, GCS_RESULTSTR,
    ISC_SHOWUICOMPOSITIONWINDOW, WM_IME_CHAR, WM_IME_COMPOSITION,
    WM_IME_ENDCOMPOSITION, WM_IME_SETCONTEXT, WM_IME_STARTCOMPOSITION;

import sparkles.base.buffer : HeapBuffer, Storage, UniqueBuffer;
import sparkles.base.pool.pool : Pool, PoolError;
import sparkles.base.text.utf16 : utf16ToUtf8, utf8ToUtf16, utf8ToUtf16z;
import sparkles.base.text.utf : decodeToken, encodeScalar, UtfMode, UtfStatus, scalarUnits;
import sparkles.base.text.source_map : SourceByteOffset, Utf16Offset,
    MapAffinity, MapResult, MapStatus;
import core.time : Duration, MonoTime;

import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr,
    ioOk;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi.clipboard;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.history : PointerSample;
import sparkles.wsi.loop : EventQueue;
import sparkles.wsi.types;

pragma(lib, "imm32");

private enum UINT WM_DPICHANGED_ = 0x02E0;
private enum DWORD QS_ALLINPUT_ = 0x04FF;
private enum DWORD MWMO_INPUTAVAILABLE_ = 0x0004;
private enum DWORD WAIT_FAILED_ = 0xFFFF_FFFF;
private enum DWORD WAIT_TIMEOUT_ = 258;
private enum int GWLP_USERDATA_ = -21;
private enum UINT WM_INPUT_ = 0x00FF;
private enum USHORT hidUsagePageGeneric = 0x01;
private enum USHORT hidUsageMouse = 0x02;
private enum UINT WM_CLIPBOARDUPDATE_ = 0x031D;

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
    BOOL AddClipboardFormatListener(HWND hwnd);
    BOOL RemoveClipboardFormatListener(HWND hwnd);
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
        bool ready;
        bool composing;
        bool pointerInside;
        bool cursorVisible = true;
        ubyte buttonsDown;
        // 0 = none pending. Explicit, because `wchar.init` is 0xFFFF and a
        // removed record resets to `.init`.
        wchar pendingHighSurrogate = 0;
        HCURSOR cursor;
        SurfaceMetrics metrics;
        PhysicalPosition lastPointer;
        PointerCaptureMode captureMode;
        bool relativePointer;
    }

    private HINSTANCE instance_;
    private DWORD ownerThread_;
    private DefaultLoop* hostLoop_;
    private bool modalPumping_;
    private Pool!(WindowId, Slot, maxWindows) windows_;
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

        auto helper = wsi.openClipboard();
        if (helper.hasError)
            return helper;
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
        if (auto fault = config.fault)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                fault, WsiErrorKind.invalidArgument);
        if (config.transparent
            || config.state == WindowStartupState.fullscreen)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "requested Win32 startup configuration is not implemented",
                WsiErrorKind.unsupported);

        if (windows_.full)
            return win32Failure!WindowId(WsiOperation.createWindow, 0,
                "Win32 window capacity reached", WsiErrorKind.capacity);

        auto parent = parentHandle(config.parent);
        if (parent.hasError)
            return wsiErr!WindowId(parent.error);

        // UTF-8 never expands into UTF-16, so the title's inline capacity plus
        // a terminator is the exact bound — stated as that, not as a literal
        // that would silently stop matching if the capacity changed.
        wchar[typeof(config.title).inlineCapacity + 1] title;
        auto converted = utf8ToUtf16z(config.title[], title[]);
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

        // The id exists before the window: `CreateWindowExW` sends messages
        // synchronously, and the window procedure finds this record by the
        // address it is given.
        auto reserved = windows_.reserve();
        assert(reserved.hasValue, "capacity was checked above");
        WindowId id = reserved.value;
        ref slot = windows_[id];
        slot.owner = &this;

        HWND hwnd = CreateWindowExW(0, className.ptr, title.ptr, style,
            CW_USEDEFAULT, CW_USEDEFAULT, outer.right - outer.left,
            outer.bottom - outer.top, parent.value, null, instance_, &slot);
        if (hwnd is null)
        {
            // Stale already if the procedure saw `WM_NCDESTROY`; either way
            // the id is retired.
            windows_.cancel(id);
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
        if (!DestroyWindow(windows_.at(slot.value).hwnd))
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
            cast(void*) windows_.at(slot.value).hwnd));
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
        // The clipboard's work runs here, after the window procedures: they
        // only note what happened, and sinks are called from this dispatch
        // (`DT2`).
        count += serviceClipboard();
        if (hasStickyError_)
            return wsiErr!size_t(stickyError_);
        return wsiOk(count);
    }

    /** Event Horizon native-host concept: non-blocking native dispatch. */
    /*
    F03 modal-loop survival: DefWindowProc's move/size and menu loops spin
    inside dispatchPending, so the hosted wait stops being pumped for their
    whole duration. A USER timer armed on entering the phase fires inside
    those loops, and its handler drives one non-blocking Event Horizon
    drain — completions, timers and wakers keep making progress until the
    phase ends and the ordinary wait resumes.
    */

    /// Presence-detected by `runHostedOnce`: the loop that drives this host.
    void noteHostLoop(ref DefaultLoop loop) nothrow @nogc
    {
        hostLoop_ = &loop;
    }

    private enum UINT_PTR modalPumpTimer = 0x5741; // 'WA'
    private enum UINT modalPumpMilliseconds = 16;

    private void pumpDuringModalPhase() nothrow
    {
        if (hostLoop_ is null || modalPumping_)
            return;
        modalPumping_ = true;
        scope (exit) modalPumping_ = false;
        auto progressed = hostLoop_.runOnce(Duration.zero);
        if (progressed.hasError)
            remember(wsiError(WsiErrorKind.nativeFailure,
                WsiOperation.dispatch, BackendKind.win32,
                progressed.error.code,
                "Event Horizon drain failed inside a modal loop"));
    }

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
        foreach (h; clipboard_.transfers.byLive)
            clipboard_.end(h, TransferStatus.failed);
        // An own offer still on the clipboard is rendered in full by
        // `WM_RENDERALLFORMATS` as the helper goes, so it outlives the
        // application, as Windows users expect.
        if (helper_ !is null)
        {
            RemoveClipboardFormatListener(helper_);
            DestroyWindow(helper_);
            helper_ = null;
        }
        // `WM_NCDESTROY` removes each record as its window goes, which the
        // live iteration allows.
        foreach (h; windows_.byLive)
            if (windows_[h].hwnd !is null)
                DestroyWindow(windows_[h].hwnd);
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
        return wsiOk(windows_.at(slot.value).hwnd);
    }

    private WsiResult!size_t checkedSlot(WindowId id, WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        auto index = windows_.resolve(id);
        if (index.hasError)
            return win32Failure!size_t(operation, 0,
                index.error == PoolError.invalid
                    ? "invalid Win32 window id" : "stale Win32 window id",
                WsiErrorKind.staleId);
        size_t slot = index.value;
        return wsiOk(slot);
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
        auto result = events_.pushCoalesced(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload), MonoTime.currTime));
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    /// Queues an event carrying `text`; see `EventQueue.pushText` (`ED8`).
    private void emitText(Make)(WindowId id, scope const(char)[] text,
        scope Make make) nothrow
    {
        auto result = events_.pushText(nextSequence_, id, text, make,
            MonoTime.currTime);
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    /// Calls `fn` with the text a delivered event names, during the drain
    /// that delivers it (`ED8`). See `EventQueue.withText`.
    WsiResult!void withText(Fn)(TextId id, scope Fn fn)
        => events_.withText(id, fn);

    /// Sets `id`'s motion policy (`ED9`): whether its pointer motion merges,
    /// and whether relative motion merges by summing.
    WsiResult!void setMotionPolicy(WindowId id, bool coalesce, bool sumRelative)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        return events_.setMotionPolicy(id, coalesce, sumRelative);
    }

    /// Copies the newest samples of `id`'s `pointer` into `into`, in
    /// arrival order, and returns how many (`ED3`).
    size_t copySamples(WindowId id, PointerId pointer, scope PointerSample[] into)
        const @safe pure nothrow @nogc => events_.copySamples(id, pointer, into);

    /// Copies an event's text into a `TextPool` the caller owns (`ED8`).
    /// See `EventQueue.retain`.
    WsiResult!WindowEvent retain(P)(WindowEvent event, ref P pool)
        => events_.retain(event, pool);

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

    /**
    The prefix of `wide` that can reach `maxEventText` UTF-8 bytes: every
    UTF-16 unit is at least one byte, so more units than that are never
    needed, and the queue truncates what they produce (`ED8`). The cut never
    separates a surrogate pair.
    */
    private static const(wchar)[] boundedUnits(return scope const(wchar)[] wide)
        @safe pure nothrow @nogc
    {
        if (wide.length <= maxEventText)
            return wide;
        size_t cut = maxEventText;
        if (wide[cut - 1] >= 0xD800 && wide[cut - 1] <= 0xDBFF)
            --cut;
        return wide[0 .. cut];
    }

    /// A UTF-8 offset into converted text, held where a composition field can
    /// represent it; `CompositionEvent.clampTo` then bounds it by what was kept.
    private static ushort boundedOffset(size_t offset) @safe pure nothrow @nogc
        => cast(ushort)(offset < maxEventText ? offset : maxEventText);

    private void emitCommittedText(WindowId id,
        scope const(wchar)[] wide) nothrow
    {
        wide = boundedUnits(wide);
        UniqueBuffer!(char, 256) bytes;
        bytes.length = wide.length * 3;
        auto converted = utf16ToUtf8(wide, bytes[]);
        if (converted.hasError)
        {
            rememberNative(WsiOperation.dispatch,
                cast(long) converted.error.required,
                "IMM32 commit is not valid UTF-16");
            return;
        }
        emitText(id, bytes[0 .. converted.value],
            (TextId text, size_t kept) => TextCommittedEvent(text));
    }

    private void emitComposition(WindowId id, scope const(wchar)[] wide,
        scope const(ubyte)[] attributes, size_t cursorUnits) nothrow
    {
        wide = boundedUnits(wide);
        if (cursorUnits > wide.length)
            cursorUnits = wide.length;
        UniqueBuffer!(char, 512) bytes;
        bytes.length = wide.length * 3;
        auto converted = utf16ToUtf8(wide, bytes[]);
        if (converted.hasError)
        {
            rememberNative(WsiOperation.dispatch,
                cast(long) converted.error.required,
                "IMM32 preedit is not valid UTF-16");
            return;
        }

        CompositionEvent composition;
        // utf16ToUtf8 above validated the complete source, not just this prefix.
        composition.cursor = boundedOffset(mapValidatedUtf16Offset(wide,
            Utf16Offset(cursorUnits), MapAffinity.before).value.value);

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

            const startByte = mapValidatedUtf16Offset(wide,
                Utf16Offset(at), MapAffinity.before).value.value;
            const endByte = mapValidatedUtf16Offset(wide,
                Utf16Offset(end), MapAffinity.after).value.value;
            composition.segments[composition.segmentCount++] =
                CompositionSegment(boundedOffset(startByte),
                    cast(ushort)(boundedOffset(endByte) - boundedOffset(startByte)),
                    style);
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
            composition.selectionStart = boundedOffset(firstTarget);
            composition.selectionLength = cast(ushort)(
                boundedOffset(targetEnd) - boundedOffset(firstTarget));
        }
        emitText(id, bytes[0 .. converted.value],
            (TextId text, size_t kept) {
                auto event = composition;
                event.preedit = text;
                event.clampTo(kept);
                return event;
            });
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
            UniqueBuffer!(wchar, 256) result;
            if (readImeString(context, GCS_RESULTSTR, result,
                "ImmGetCompositionStringW result failed"))
                emitCommittedText(id, result[]);
        }

        if ((flags & GCS_COMPSTR) != 0)
        {
            UniqueBuffer!(wchar, 256) preedit;
            if (!readImeString(context, GCS_COMPSTR, preedit,
                "ImmGetCompositionStringW preedit failed"))
                return;

            // One attribute byte per UTF-16 unit; only the units kept above
            // need one.
            UniqueBuffer!(ubyte, 256) attributes;
            if ((flags & GCS_COMPATTR) != 0)
            {
                attributes.length = preedit.length;
                const bytes = attributes.length == 0 ? 0
                    : ImmGetCompositionStringW(context, GCS_COMPATTR,
                        attributes[].ptr, cast(DWORD) attributes.length);
                if (bytes < 0)
                {
                    rememberNative(WsiOperation.dispatch, bytes,
                        "ImmGetCompositionStringW attributes failed");
                    return;
                }
                if (cast(size_t) bytes < attributes.length)
                    attributes.length = cast(size_t) bytes;
            }

            size_t cursorUnits;
            if ((flags & GCS_CURSORPOS) != 0)
            {
                const cursor = ImmGetCompositionStringW(context,
                    GCS_CURSORPOS, null, 0);
                if (cursor >= 0)
                    cursorUnits = cast(size_t) cursor;
            }
            emitComposition(id, preedit[], attributes[], cursorUnits);
        }
    }

    /**
    Reads an IMM32 string into `destination`, keeping at most the UTF-16
    units that can reach `maxEventText` UTF-8 bytes: the queue truncates
    beyond that anyway (`ED8`), so a longer composition is cut here rather
    than refused.
    */
    private bool readImeString(Units)(HIMC context, DWORD kind,
        ref Units destination,
        scope const(char)[] diagnostic) nothrow
    {
        const requiredBytes = ImmGetCompositionStringW(context, kind, null, 0);
        if (requiredBytes < 0 || (requiredBytes & 1) != 0)
        {
            rememberNative(WsiOperation.dispatch, requiredBytes, diagnostic);
            return false;
        }
        const units = cast(size_t) requiredBytes / wchar.sizeof;
        destination.length = units < maxEventText ? units : maxEventText;
        if (destination.length != 0)
        {
            const wanted = cast(DWORD)(destination.length * wchar.sizeof);
            const copied = ImmGetCompositionStringW(context, kind,
                destination[].ptr, wanted);
            if (copied != wanted)
            {
                rememberNative(WsiOperation.dispatch, copied, diagnostic);
                return false;
            }
        }
        destination.length = boundedUnits(destination[]).length;
        return true;
    }

    /**
    Maps an IMM UTF-16 index onto the event's converted UTF-8 byte identity.
    The complete wide source MUST already have passed utf16ToUtf8 strict validation.
    Interior pair boundaries require affinity; out-of-range native indices clamp.
    */
    private static MapResult!SourceByteOffset mapValidatedUtf16Offset(
        scope const(wchar)[] wide, Utf16Offset units, MapAffinity affinity)
        @safe pure nothrow @nogc
    {
        size_t bytes, at;
        while (at < wide.length)
        {
            if (units.value == at)
            {
                const boundary = SourceByteOffset(bytes);
                return MapResult!SourceByteOffset(value: boundary,
                    lower: boundary, upper: boundary, exact: true);
            }
            const decoded = decodeToken(wide[at .. $], UtfMode.strict, true, at);
            assert(decoded.result.status == UtfStatus.ok);
            const nextBytes = bytes + scalarUnits!char(decoded.token.scalar);
            if (units.value < decoded.token.end)
            {
                const lower = SourceByteOffset(bytes);
                const upper = SourceByteOffset(nextBytes);
                if (affinity == MapAffinity.exact)
                    return MapResult!SourceByteOffset(status: MapStatus.notBoundary,
                        lower: lower, upper: upper);
                return MapResult!SourceByteOffset(
                    value: affinity == MapAffinity.before ? lower : upper,
                    lower: lower, upper: upper, snapped: true);
            }
            bytes = nextBytes;
            at = decoded.token.end;
        }
        const boundary = SourceByteOffset(bytes);
        return MapResult!SourceByteOffset(value: boundary,
            lower: boundary, upper: boundary,
            exact: units.value == at, snapped: units.value != at);
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
        const wchar[1] single = [unit];
        const decoded = decodeToken(single[], UtfMode.strict, false);
        if (decoded.result.status == UtfStatus.needInput)
        {
            // A new high surrogate replaces any uncommitted previous one.
            slot.pendingHighSurrogate = unit;
            return;
        }
        if (slot.pendingHighSurrogate != 0)
        {
            const wchar[2] pair = [slot.pendingHighSurrogate, unit];
            slot.pendingHighSurrogate = 0;
            if (decodeToken(pair[], UtfMode.strict).result.status == UtfStatus.ok)
            {
                emitCommittedText(id, pair[]);
                return;
            }
        }
        // Malformed standalone units are rejected; the next unit still progresses.
        if (decoded.result.status == UtfStatus.ok)
            emitCommittedText(id, single[]);
    }

    // ── clipboard (`DT1`–`DT5`) ──────────────────────────────────────────────

    /// The largest chunk one dispatch reads from the clipboard: the bound on
    /// what a sink sees (`DT4`), and WSI's one buffer of clipboard bytes.
    enum size_t clipChunkBytes = 64 * 1024;

    /**
    Offers `mimeTypes` on the clipboard by delayed rendering; a request pulls
    the bytes from `provider`, which must outlive the offer (`DT3`). Each MIME
    type is the registered clipboard format of that name, and
    `text/plain;charset=utf-8` is also `CF_UNICODETEXT`, the format every
    Windows application reads.
    */
    WsiResult!OfferId offerClipboard(P)(WindowId window,
        scope const(char[])[] mimeTypes, ref P provider)
    if (isDataProvider!P)
    {
        auto checked = checkedSlot(window, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!OfferId(checked.error);
        auto added = clipboard_.add(window, mimeTypes, true);
        if (added.hasError)
            return added;
        clipboard_.offers[added.value].provider =
            (() @trusted => ProviderRef.to(provider))();
        return takeClipboard(added.value);
    }

    /// ditto, for a small whole value the backend keeps a copy of.
    WsiResult!OfferId offerClipboard(WindowId window, scope const(char)[] mimeType,
        scope const(ubyte)[] value)
    {
        auto checked = checkedSlot(window, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!OfferId(checked.error);
        auto added = clipboard_.add(window, mimeType, true);
        if (added.hasError)
            return added;
        ref record = clipboard_.offers[added.value];
        record.value.bytes ~= value;
        record.hasValue = true;
        return takeClipboard(added.value);
    }

    /// Ends an offer this application made: empties the clipboard if the
    /// offer is still on it, and reports `withdrawn` (`DT1`).
    WsiResult!void withdrawClipboard(OfferId offer)
    {
        auto owner = requireOwner!void(WsiOperation.command);
        if (owner.hasError)
            return owner;
        auto record = clipboard_.offers.get(offer);
        if (record is null || !record.own)
            return win32Failure!void(WsiOperation.command, 0,
                "no live offer of this application's", WsiErrorKind.staleId);
        if (clipboard_.current == offer && OpenClipboard(helper_))
        {
            if (GetClipboardOwner() == helper_)
                EmptyClipboard();
            CloseClipboard();
        }
        announce(offer, DataOfferAction.withdrawn);
        clipboard_.drop(offer);
        return wsiOk();
    }

    /**
    Starts reading `offer`'s `mimeType` into `sink` (`DT2`). Each dispatch
    opens the clipboard, copies at most `clipChunkBytes` of the format's
    block from the transfer's offset, closes the clipboard, and only then
    calls the sink: the clipboard is never held open across dispatches.
    `CF_UNICODETEXT` arrives as UTF-8. Only the clipboard's current offer is
    readable, and an own offer is read back through the clipboard like any
    other.
    */
    WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mimeType,
        ref S sink)
    if (isDataSink!S)
    {
        auto owner = requireOwner!TransferId(WsiOperation.command);
        if (owner.hasError)
            return owner;
        if (offer != clipboard_.current || !clipboard_.offers.isLive(offer))
            return win32Failure!TransferId(WsiOperation.command, 0,
                "the offer has ended", WsiErrorKind.staleId);
        auto begun = clipboard_.begin(offer, mimeType,
            (() @trusted => SinkRef.to(sink))());
        if (begun.hasError)
            return begun;
        fetches_[begun.value.index] = Fetch(formatFor(offer, mimeType));
        return begun;
    }

    /// Ends a transfer with `cancelled`; its sink then hears nothing more.
    WsiResult!void cancelTransfer(TransferId transfer)
    {
        auto owner = requireOwner!void(WsiOperation.command);
        if (owner.hasError)
            return owner;
        return clipboard_.cancel(transfer);
    }

    // One incoming transfer, by transfer slot: the clipboard format it reads
    // and how far into the format's block it has read, in bytes.
    private struct Fetch
    {
        UINT format;
        size_t offset;
    }

    private enum textMime = "text/plain;charset=utf-8";

    private HWND helper_;
    private ClipboardState!() clipboard_;
    private UINT[maxOfferTypes][4] offerFormats_; // per offer slot, per type
    private Fetch[8] fetches_;
    // The one chunk buffer: what a dispatch copies out of the clipboard
    // before calling a sink, and the UTF-8 a text rendering converts.
    private HeapBuffer!(ubyte, Storage.unique) chunk_;
    private bool clipboardChanged_; // a window procedure saw a change
    private DWORD seenSequence_;    // the clipboard sequence last examined

    // The helper window: it owns the clipboard while an offer of ours is on
    // it, answers `WM_RENDERFORMAT`, and listens for changes.
    private WsiResult!void openClipboard()
    {
        WNDCLASSEXW wc;
        wc.cbSize = WNDCLASSEXW.sizeof;
        wc.lpfnWndProc = &clipboardProcedure;
        wc.hInstance = instance_;
        wc.lpszClassName = clipboardClassName.ptr;
        if (RegisterClassExW(&wc) == 0)
        {
            const code = GetLastError();
            if (code != ERROR_CLASS_ALREADY_EXISTS)
                return win32Failure!void(WsiOperation.open, code,
                    "RegisterClassExW failed for the clipboard helper");
        }
        helper_ = CreateWindowExW(0, clipboardClassName.ptr, null, 0, 0, 0, 0, 0,
            HWND_MESSAGE, null, instance_, &this);
        if (helper_ is null)
            return win32Failure!void(WsiOperation.open, GetLastError(),
                "CreateWindowExW failed for the clipboard helper");
        if (!AddClipboardFormatListener(helper_))
        {
            const code = GetLastError();
            DestroyWindow(helper_);
            helper_ = null;
            return win32Failure!void(WsiOperation.open, code,
                "AddClipboardFormatListener failed");
        }
        seenSequence_ = GetClipboardSequenceNumber();
        return wsiOk();
    }

    // Empties the clipboard into the helper's ownership and lists `offer`'s
    // formats for delayed rendering.
    private WsiResult!OfferId takeClipboard(OfferId offer)
    {
        auto record = clipboard_.offers.get(offer);
        foreach (i, ref t; record.types[0 .. record.typeCount])
        {
            wchar[maxMimeType + 1] name;
            const converted = utf8ToUtf16z(t[], name[]);
            const format = converted.hasError ? 0
                : RegisterClipboardFormatW(name.ptr);
            if (format == 0)
            {
                const code = GetLastError();
                clipboard_.drop(offer);
                return win32Failure!OfferId(WsiOperation.command, code,
                    "a MIME type could not be registered as a clipboard format",
                    converted.hasError ? WsiErrorKind.invalidArgument
                        : WsiErrorKind.nativeFailure);
            }
            offerFormats_[offer.index][i] = format;
        }
        if (!OpenClipboard(helper_))
        {
            const code = GetLastError();
            clipboard_.drop(offer);
            return win32Failure!OfferId(WsiOperation.command, code,
                "OpenClipboard failed: another window holds the clipboard");
        }
        // A previous offer of ours gets `WM_DESTROYCLIPBOARD` from this; the
        // owner check in the dispatch tells it from another writer's.
        EmptyClipboard();
        foreach (format; offerFormats_[offer.index][0 .. record.typeCount])
            SetClipboardData(format, null);
        if (record.offers(textMime))
            SetClipboardData(CF_UNICODETEXT, null);
        CloseClipboard();
        publish(offer);
        return wsiOk(offer);
    }

    // The clipboard format a transfer of `offer`'s `mime` reads.
    private UINT formatFor(OfferId offer, scope const(char)[] mime)
    {
        auto record = clipboard_.offers.get(offer);
        foreach (i, ref t; record.types[0 .. record.typeCount])
            if (t[] == mime)
                return offerFormats_[offer.index][i];
        return 0;
    }

    // The dispatch half: what the helper's procedure noted, then one chunk
    // per transfer in flight. Returns how much work it did, so the hosted
    // loop does not block while a transfer has bytes left.
    private size_t serviceClipboard()
    {
        if (helper_ is null)
            return 0;
        size_t work;
        if (clipboardChanged_)
        {
            clipboardChanged_ = false;
            ++work;
            const sequence = GetClipboardSequenceNumber();
            if (sequence != seenSequence_ && GetClipboardOwner() != helper_)
            {
                if (noticeForeignOwner())
                    seenSequence_ = sequence;
                else
                    clipboardChanged_ = true; // the clipboard was busy
            }
        }
        foreach (h; clipboard_.transfers.byLive)
        {
            ++work;
            pumpTransfer(h);
        }
        return work;
    }

    // Another writer replaced the clipboard: this application's offer ended
    // (`DT1`), and the formats the writer lists become the foreign offer.
    // Returns `false` when the clipboard could not be opened, to retry.
    private bool noticeForeignOwner()
    {
        if (auto record = clipboard_.offers.get(clipboard_.current))
        {
            if (record.own)
                announce(clipboard_.current, DataOfferAction.withdrawn);
            clipboard_.drop(clipboard_.current);
        }
        if (!OpenClipboard(helper_))
            return false;
        char[maxMimeType][maxOfferTypes] names;
        const(char)[][maxOfferTypes] types;
        UINT[maxOfferTypes] formats;
        size_t n;
        bool unicodeText;
        bool text;
        for (UINT format = EnumClipboardFormats(0); format != 0;
            format = EnumClipboardFormats(format))
        {
            if (format == CF_UNICODETEXT)
            {
                unicodeText = true;
                continue;
            }
            // Registered formats start at 0xC000; the rest are predefined.
            if (format < 0xC000 || n == maxOfferTypes)
                continue;
            // One unit more than a MIME type may have, to see a longer name.
            wchar[maxMimeType + 2] wide;
            const units = GetClipboardFormatNameW(format, wide.ptr,
                cast(int) wide.length);
            if (units <= 0 || units > maxMimeType)
                continue;
            auto converted = utf16ToUtf8(wide[0 .. units], names[n][]);
            if (converted.hasError || !isMimeType(names[n][0 .. converted.value]))
                continue;
            types[n] = names[n][0 .. converted.value];
            text |= types[n] == textMime;
            formats[n++] = format;
        }
        CloseClipboard();
        // UTF-16 text is offered as UTF-8 unless the writer named the UTF-8
        // type itself; it displaces the last type when the offer is full.
        if (unicodeText && !text)
        {
            if (n == maxOfferTypes)
                --n;
            types[n] = textMime;
            formats[n++] = CF_UNICODETEXT;
        }
        if (n == 0)
            return true;
        auto added = clipboard_.add(firstWindow(), types[0 .. n], false);
        if (added.hasError)
            return true;
        offerFormats_[added.value.index][0 .. n] = formats[0 .. n];
        publish(added.value);
        return true;
    }

    private static bool isMimeType(scope const(char)[] name) @safe pure nothrow @nogc
    {
        foreach (c; name)
            if (c == '/')
                return true;
        return false;
    }

    // One step of transfer `h`: copies the next chunk of its format's block
    // out of the clipboard, closes the clipboard, then hands the chunk on.
    private void pumpTransfer(TransferId h)
    {
        ref fetch = fetches_[h.index];
        if (fetch.format == 0)
        {
            clipboard_.end(h, TransferStatus.failed);
            return;
        }
        // Another window holding the clipboard open is retried next dispatch.
        if (!OpenClipboard(helper_))
            return;
        if (chunk_.length < clipChunkBytes)
            chunk_.length = clipChunkBytes;
        // For an own offer the first request sends the helper
        // `WM_RENDERFORMAT`, which renders the value into the clipboard.
        HANDLE data = GetClipboardData(fetch.format);
        const total = data is null ? 0 : GlobalSize(data);
        auto block = total == 0 ? null : cast(const(ubyte)*) GlobalLock(data);
        if (data is null || (total != 0 && block is null))
        {
            CloseClipboard();
            clipboard_.end(h, TransferStatus.failed);
            return;
        }
        size_t n;
        bool last;
        if (fetch.format == CF_UNICODETEXT)
            n = readUnicodeChunk(fetch, block, total, last);
        else
        {
            const at = fetch.offset < total ? fetch.offset : total;
            n = total - at < clipChunkBytes ? total - at : clipChunkBytes;
            if (n != 0)
                chunk_[][0 .. n] = block[at .. at + n];
            fetch.offset = at + n;
            last = fetch.offset == total;
        }
        if (block !is null)
            GlobalUnlock(data);
        CloseClipboard();

        if (n != 0)
            if (auto record = clipboard_.transfers.get(h))
            {
                auto sink = record.sink;
                sink.chunk(h, chunk_[][0 .. n]);
            }
        // `end` ignores a transfer the sink cancelled meanwhile.
        if (last)
            clipboard_.end(h, TransferStatus.completed);
    }

    // `CF_UNICODETEXT` as UTF-8 into `chunk_`: at most a third of a chunk of
    // UTF-16 units, so the UTF-8 fits, never ending inside a surrogate pair,
    // and stopping at the terminating NUL.
    private size_t readUnicodeChunk(ref Fetch fetch, const(ubyte)* block,
        size_t totalBytes, out bool last)
    {
        const totalUnits = totalBytes / wchar.sizeof;
        const start = fetch.offset / wchar.sizeof;
        if (start >= totalUnits)
        {
            last = true;
            return 0;
        }
        const units = (cast(const(wchar)*) block)[start .. totalUnits];
        enum size_t maxUnits = clipChunkBytes / 3;
        size_t take = units.length < maxUnits ? units.length : maxUnits;
        foreach (i, u; units[0 .. take])
            if (u == 0)
            {
                take = i;
                last = true;
                break;
            }
        if (!last && take == units.length)
            last = true; // an unterminated block ends with the block
        if (!last && take > 1 && units[take - 1] >= 0xD800 && units[take - 1] <= 0xDBFF)
            --take;
        auto converted = utf16ToUtf8(units[0 .. take], cast(char[]) chunk_[],
            UtfMode.replacement);
        assert(converted.hasValue, "a third of a chunk of units fits a chunk");
        fetch.offset += take * wchar.sizeof;
        return converted.value;
    }

    // `WM_RENDERFORMAT`: the current own offer's `format`, rendered whole
    // into a block handed to the clipboard. Windows needs the value in one
    // block; it belongs to the clipboard, the requesting side (`DT4`).
    private void renderFormat(UINT format) nothrow
    {
        auto record = clipboard_.offers.get(clipboard_.current);
        if (record is null || !record.own)
            return;
        HGLOBAL block;
        if (format == CF_UNICODETEXT)
            block = renderUnicode(*record);
        else
            foreach (i, ref t; record.types[0 .. record.typeCount])
                if (offerFormats_[clipboard_.current.index][i] == format)
                {
                    block = renderBytes(*record, t[]);
                    break;
                }
        if (block !is null && SetClipboardData(format, block) is null)
            GlobalFree(block);
    }

    // `WM_RENDERALLFORMATS`: the helper is going while an offer of ours is
    // on the clipboard; every format is rendered so the data outlives it.
    private void renderAllFormats() nothrow
    {
        auto record = clipboard_.offers.get(clipboard_.current);
        if (record is null || !record.own || !OpenClipboard(helper_))
            return;
        if (GetClipboardOwner() == helper_)
        {
            const offer = clipboard_.current;
            foreach (format; offerFormats_[offer.index][0 .. record.typeCount])
                renderFormat(format);
            if (record.offers(textMime))
                renderFormat(CF_UNICODETEXT);
        }
        CloseClipboard();
    }

    // Grows the unlocked `block` to at least `wanted` bytes, by doubling.
    private static bool reserveBlock(ref HGLOBAL block, ref size_t capacity,
        size_t wanted) nothrow @nogc
    {
        if (wanted <= capacity)
            return true;
        size_t grown = capacity;
        while (grown < wanted)
            grown *= 2;
        auto moved = GlobalReAlloc(block, grown, GMEM_MOVEABLE);
        if (moved is null)
            return false;
        block = moved;
        capacity = grown;
        return true;
    }

    // Shrinks `block` to the value's exact size, which is how a reader
    // (`GlobalSize`) knows where the value ends; frees it on failure.
    private static HGLOBAL exactBlock(HGLOBAL block, size_t size) nothrow @nogc
    {
        auto exact = GlobalReAlloc(block, size, GMEM_MOVEABLE);
        if (exact is null)
            GlobalFree(block);
        return exact;
    }

    // The provider's bytes, pulled straight into the clipboard's block.
    private HGLOBAL renderBytes(ref OfferRecord record, scope const(char)[] mime)
        nothrow
    {
        size_t capacity = clipChunkBytes;
        HGLOBAL block = GlobalAlloc(GMEM_MOVEABLE, capacity);
        if (block is null)
            return null;
        size_t size;
        for (;;)
        {
            if (!reserveBlock(block, capacity, size + 1))
            {
                GlobalFree(block);
                return null;
            }
            auto memory = cast(ubyte*) GlobalLock(block);
            if (memory is null)
            {
                GlobalFree(block);
                return null;
            }
            const n = record.fill(mime, size, memory[size .. capacity]);
            GlobalUnlock(block);
            if (n == 0)
                break;
            size += n;
        }
        return exactBlock(block, size);
    }

    // The provider's UTF-8 text as NUL-terminated UTF-16, a chunk at a time
    // through `chunk_`; a sequence split across chunks carries over.
    private HGLOBAL renderUnicode(ref OfferRecord record) nothrow
    {
        if (chunk_.length < clipChunkBytes)
            chunk_.length = clipChunkBytes;
        auto staging = chunk_[];
        size_t capacity = clipChunkBytes;
        HGLOBAL block = GlobalAlloc(GMEM_MOVEABLE, capacity);
        if (block is null)
            return null;
        size_t units;  // UTF-16 units written
        ulong offset;  // provider bytes read
        size_t carry;  // a split sequence's bytes at the staging's start
        for (bool ended; !ended;)
        {
            const n = record.fill(textMime, offset, staging[carry .. $]);
            offset += n;
            ended = n == 0;
            const have = carry + n;
            const text = cast(const(char)[]) staging[0 .. have];
            // At the end a dangling sequence converts too, as U+FFFD.
            const complete = ended ? have : completeUtf8Prefix(text);
            // UTF-16 never needs more units than UTF-8 has bytes; plus NUL.
            if (!reserveBlock(block, capacity, (units + complete + 1) * wchar.sizeof))
            {
                GlobalFree(block);
                return null;
            }
            auto memory = cast(wchar*) GlobalLock(block);
            if (memory is null)
            {
                GlobalFree(block);
                return null;
            }
            auto converted = utf8ToUtf16(text[0 .. complete],
                memory[units .. capacity / wchar.sizeof], UtfMode.replacement);
            if (converted.hasValue)
                units += converted.value;
            if (ended)
                memory[units++] = 0;
            GlobalUnlock(block);
            if (converted.hasError)
            {
                GlobalFree(block);
                return null;
            }
            foreach (i; complete .. have)
                staging[i - complete] = staging[i];
            carry = have - complete;
        }
        return exactBlock(block, units * wchar.sizeof);
    }

    private void publish(OfferId offer)
    {
        const previous = clipboard_.current;
        if (previous != offer)
            if (auto old = clipboard_.offers.get(previous))
            {
                if (old.own)
                    announce(previous, DataOfferAction.withdrawn);
                clipboard_.drop(previous);
            }
        clipboard_.current = offer;
        announce(offer, DataOfferAction.offered);
    }

    private void announce(OfferId offer, DataOfferAction action)
    {
        auto record = clipboard_.offers.get(offer);
        assert(record !is null, "announcing a live offer");
        const window = record.window;
        const count = action == DataOfferAction.offered ? record.typeCount : 1;
        foreach (i; 0 .. count)
            emitText(window, record.types[i][],
                (TextId mime, size_t kept) => DataOfferEvent(offer, action, mime));
    }

    private WindowId firstWindow()
    {
        foreach (h; windows_.byLive)
            return h;
        return WindowId.init;
    }

    // The helper's procedure. Changes are only noted; the dispatch after the
    // pump acts on them. `WM_RENDERFORMAT` cannot be deferred: the requester
    // waits in `GetClipboardData` until it returns.
    private extern (Windows) static LRESULT clipboardProcedure(HWND hwnd,
        UINT message, WPARAM wParam, LPARAM lParam) nothrow
    {
        Win32Wsi* owner;
        if (message == WM_NCCREATE)
        {
            owner = cast(Win32Wsi*)(cast(CREATESTRUCTW*) lParam).lpCreateParams;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA_, cast(LONG_PTR) owner);
        }
        else
            owner = cast(Win32Wsi*) GetWindowLongPtrW(hwnd, GWLP_USERDATA_);
        if (owner is null)
            return DefWindowProcW(hwnd, message, wParam, lParam);
        switch (message)
        {
            case WM_CLIPBOARDUPDATE_:
            case WM_DESTROYCLIPBOARD:
                owner.clipboardChanged_ = true;
                return 0;
            case WM_RENDERFORMAT:
                owner.renderFormat(cast(UINT) wParam);
                return 0;
            case WM_RENDERALLFORMATS:
                owner.renderAllFormats();
                return 0;
            case WM_NCDESTROY:
                SetWindowLongPtrW(hwnd, GWLP_USERDATA_, 0);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            default:
                return DefWindowProcW(hwnd, message, wParam, lParam);
        }
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
        windows_.at(checked.value).cursor = cursor;
        return wsiOk();
    }

    /// Visibility is per-window here, applied by the same WM_SETCURSOR
    /// path rather than the thread-global ShowCursor counter.
    WsiResult!void setCursorVisible(WindowId id, bool visible)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        windows_.at(checked.value).cursorVisible = visible;
        return wsiOk();
    }

    /*
    F10 on Win32: explicit `capture` is `SetCapture` held past the buttons
    (the implicit press-to-release capture must not drop it), `confine` is
    `ClipCursor` over the client area in screen coordinates, re-clipped as
    the window moves or resizes and lifted while focus is elsewhere, and
    raw relative motion is Raw Input for the mouse usage targeted at the
    window: `WM_INPUT` carries `RAWMOUSE` deltas that no cursor clamp or
    acceleration touched. Capture loss (`WM_CAPTURECHANGED`) and destruction
    unwind all of it.
    */

    WsiResult!void setPointerCapture(WindowId id, PointerCaptureMode mode)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (slot.captureMode == PointerCaptureMode.capture
            && mode != PointerCaptureMode.capture)
        {
            slot.captureMode = PointerCaptureMode.none;
            if (GetCapture() == slot.hwnd && slot.buttonsDown == 0)
                ReleaseCapture();
        }
        if (slot.captureMode == PointerCaptureMode.confine
            && mode != PointerCaptureMode.confine)
        {
            slot.captureMode = PointerCaptureMode.none;
            ClipCursor(null);
        }
        final switch (mode)
        {
            case PointerCaptureMode.none:
                return wsiOk();
            case PointerCaptureMode.capture:
                slot.captureMode = mode;
                if (GetCapture() != slot.hwnd)
                    SetCapture(slot.hwnd);
                return wsiOk();
            case PointerCaptureMode.confine:
                slot.captureMode = mode;
                return clipToClient(slot)
                    ? wsiOk()
                    : win32Failure!void(WsiOperation.command,
                        GetLastError(), "ClipCursor failed");
        }
    }

    WsiResult!void setRelativePointer(WindowId id, bool enabled)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        ref slot = windows_.at(checked.value);
        if (slot.relativePointer == enabled)
            return wsiOk();
        if (!registerRawMouse(slot.hwnd, enabled))
            return win32Failure!void(WsiOperation.command, GetLastError(),
                "RegisterRawInputDevices failed");
        slot.relativePointer = enabled;
        return wsiOk();
    }

    /// The client rectangle in screen coordinates is the clip rectangle.
    private static bool clipToClient(ref Slot slot) nothrow @nogc
    {
        RECT client;
        if (!GetClientRect(slot.hwnd, &client))
            return false;
        POINT origin = POINT(client.left, client.top);
        POINT extent = POINT(client.right, client.bottom);
        if (!ClientToScreen(slot.hwnd, &origin)
            || !ClientToScreen(slot.hwnd, &extent))
            return false;
        RECT screen = RECT(origin.x, origin.y, extent.x, extent.y);
        return ClipCursor(&screen) != 0;
    }

    /// Raw mouse input is registered per target window; `RIDEV_REMOVE`
    /// unregisters the usage for the process.
    private static bool registerRawMouse(HWND hwnd, bool on) nothrow @nogc
    {
        RAWINPUTDEVICE device;
        device.usUsagePage = hidUsagePageGeneric;
        device.usUsage = hidUsageMouse;
        device.dwFlags = on ? 0 : RIDEV_REMOVE;
        device.hwndTarget = on ? hwnd : null;
        return RegisterRawInputDevices(&device, 1, RAWINPUTDEVICE.sizeof) != 0;
    }

    private void handleRawInput(ref Slot slot, WindowId id, LPARAM lParam)
        nothrow
    {
        RAWINPUT raw;
        UINT size = RAWINPUT.sizeof;
        const copied = GetRawInputData(cast(HRAWINPUT) lParam, RID_INPUT,
            &raw, &size, RAWINPUTHEADER.sizeof);
        if (copied == cast(UINT) -1 || copied < RAWINPUTHEADER.sizeof
            || raw.header.dwType != RIM_TYPEMOUSE
            || (raw.data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE) != 0)
            return;
        const dx = raw.data.mouse.lLastX;
        const dy = raw.data.mouse.lLastY;
        if ((dx == 0 && dy == 0) || !slot.relativePointer)
            return;
        emit(id, RelativePointerEvent(queuePointer, dx, dy, true));
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
    private enum queuePointer = PointerId(0, 1);

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
            if (slot.buttonsDown == 0
                && slot.captureMode != PointerCaptureMode.capture)
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
        // Only a live record has an owner, so the slot is live here.
        return slot.owner.windows_.handleAt(slot.owner.windows_.indexOf(&slot));
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
                if (slot.captureMode == PointerCaptureMode.confine)
                    clipToClient(*slot);
                owner.emit(id, FocusChangedEvent(true));
                return 0;
            case WM_KILLFOCUS:
                // The clip is a system-wide resource; it must not outlive
                // this window's focus.
                if (slot.captureMode == PointerCaptureMode.confine)
                    ClipCursor(null);
                owner.emit(id, FocusChangedEvent(false));
                return 0;
            case WM_INPUT_:
                owner.handleRawInput(*slot, id, lParam);
                // The system frees the raw input buffer in DefWindowProc.
                return DefWindowProcW(hwnd, message, wParam, lParam);
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
                if (wParam > dchar.max)
                    return 0;
                wchar[2] encoded;
                const converted = encodeScalar(cast(dchar) wParam, encoded[]);
                if (converted.status == UtfStatus.ok)
                {
                    slot.pendingHighSurrogate = 0;
                    owner.emitCommittedText(id, encoded[0 .. converted.written]);
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
                // later press starts a fresh implicit capture, and an
                // explicit capture is over too.
                slot.buttonsDown = 0;
                if (slot.captureMode == PointerCaptureMode.capture)
                    slot.captureMode = PointerCaptureMode.none;
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
                if (slot.captureMode == PointerCaptureMode.confine)
                    clipToClient(*slot);
                return 0;
            case WM_MOVE:
                const x = cast(short)(lParam & 0xFFFF);
                const y = cast(short)((lParam >> 16) & 0xFFFF);
                if (slot.ready)
                    owner.emit(id,
                        MovedEvent(PhysicalPosition(x, y)));
                if (slot.captureMode == PointerCaptureMode.confine)
                    clipToClient(*slot);
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
                if (slot.captureMode == PointerCaptureMode.confine)
                    ClipCursor(null);
                if (slot.relativePointer)
                    registerRawMouse(hwnd, false);
                slot.captureMode = PointerCaptureMode.none;
                slot.relativePointer = false;
                owner.emit(id, DestroyedEvent());
                SetWindowLongPtrW(hwnd, GWLP_USERDATA_, 0);
                // Resets the record, owner included: a late message for
                // this `hwnd` finds no record.
                owner.windows_.remove(id);
                owner.events_.forgetWindow(id);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            case WM_ENTERSIZEMOVE:
            case WM_ENTERMENULOOP:
                SetTimer(hwnd, modalPumpTimer, modalPumpMilliseconds, null);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            case WM_EXITSIZEMOVE:
            case WM_EXITMENULOOP:
                KillTimer(hwnd, modalPumpTimer);
                return DefWindowProcW(hwnd, message, wParam, lParam);
            case WM_TIMER:
                if (wParam == modalPumpTimer)
                {
                    owner.pumpDuringModalPhase();
                    return 0;
                }
                return DefWindowProcW(hwnd, message, wParam, lParam);
            default:
                return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }
}

private immutable wchar[] className = "sparkles-wsi-window"w;
private immutable wchar[] clipboardClassName = "sparkles-wsi-clipboard"w;

private WsiResult!T win32Failure(T)(WsiOperation operation, long nativeCode,
    scope const(char)[] diagnostic,
    WsiErrorKind kind = WsiErrorKind.nativeFailure)
{
    return wsiErr!T(wsiError(kind, operation, BackendKind.win32,
        nativeCode, diagnostic));
}

@("wsi.win32.utf16CompositionBoundaryAffinity")
@safe pure nothrow @nogc unittest
{
    const wide = "a😀b"w;
    const before = Win32Wsi.mapValidatedUtf16Offset(wide, Utf16Offset(2),
        MapAffinity.before);
    const after = Win32Wsi.mapValidatedUtf16Offset(wide, Utf16Offset(2),
        MapAffinity.after);
    assert(before.value.value == 1 && before.snapped);
    assert(after.value.value == 5 && after.snapped);
    assert(Win32Wsi.mapValidatedUtf16Offset(wide, Utf16Offset(2),
        MapAffinity.exact).status == MapStatus.notBoundary);
    const exact = Win32Wsi.mapValidatedUtf16Offset(wide, Utf16Offset(3),
        MapAffinity.exact);
    assert(exact.value.value == 5 && exact.exact);
    assert(Win32Wsi.mapValidatedUtf16Offset(wide, Utf16Offset(size_t.max),
        MapAffinity.before).value.value == 6);
}
