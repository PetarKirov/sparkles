#!/usr/bin/env dub
/+ dub.sdl:
    name "win32_hosted_smoke"
    dependency "sparkles:wsi" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:input" path="../../.."
    dependency "expected" version="~>0.4.1"
    platforms "windows"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Win32 driver for the shared WSI conformance suite.

Every cross-backend assertion lives in `sparkles.wsi.conformance`; this
driver supplies the User32/IOCP hosted step, `SetWindowPos`/`WM_CLOSE`
requests, and a `SendMessageW` key chord. Injected messages bypass the
thread key-state table, so the chord's modifier assertion is relaxed
(`chordModifierObserved = false`) while identity, location, and ordering
stay strict. The Win32-only channels — UTF-16 `WM_CHAR` commits and the
IMM32 composition round trip Wine implements deterministically — follow as
a platform addendum. Run through `scripts/verify-win32-wine.sh`.
*/
module win32_hosted_smoke;

version (Windows):

import core.sys.windows.imm : CPS_COMPLETE, ImmGetIMEFileNameW, ImmIsIME,
    NI_COMPOSITIONSTR, SCS_SETSTR;
import core.sys.windows.psapi : PROCESS_MEMORY_COUNTERS;
import core.sys.windows.windows;
import core.time : Duration, MonoTime, msecs, seconds;
import std.array : replicate;
import std.conv : text;
import std.stdio : writefln, writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.input.events : KeyAction;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi;

pragma(lib, "imm32");

// See platform.win32: druntime's HIMC is incorrectly 32-bit on Win64.
private alias HIMC = HANDLE;
private extern (Windows) nothrow @nogc
{
    HIMC ImmGetContext(HWND hwnd);
    BOOL ImmReleaseContext(HWND hwnd, HIMC context);
    BOOL ImmSetCompositionStringW(HIMC context, DWORD index,
        PCVOID composition, DWORD compositionBytes, PCVOID reading,
        DWORD readingBytes);
    BOOL ImmNotifyIME(HIMC context, DWORD action, DWORD index, DWORD value);
}

private struct Win32Hooks
{
    Win32Wsi* wsi;
    DefaultLoop* loop;
    HWND hwnd;
    double expectedScale = 0;

    enum uint chordShiftCode = 0x2A; // scan code: left shift
    enum uint chordKeyCode = 0x1E; // scan code: A
    // Layout-derived unshifted spelling the chorded key must carry.
    enum dchar chordKeyCharacter = 'A';
    enum bool chordModifierObserved = false;
    enum bool resizeExact = false;
    enum clickPosition = PhysicalPosition(120, 80);
    enum bool expectPointerMotion = true;

    void step(Duration timeout)
    {
        loop.runHostedOnce(*wsi, timeout).value;
    }

    void onWindowReady(WindowId id)
    {
        hwnd = wsi.nativeHandles(id).value.window.match!(
            (in Win32WindowHandle handle) => cast(HWND) handle.hwnd,
            (_) => cast(HWND) null);
        assert(hwnd !is null);
    }

    void checkHandles(in NativeHandles handles)
    {
        assert(handles.window.match!(
            (in Win32WindowHandle handle) => handle.hwnd !is null,
            (_) => false));
    }

    void requestResize(uint width, uint height)
    {
        assert(SetWindowPos(hwnd, null, 0, 0, width, height,
            SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER));
    }

    /*
    TrackPopupMenu runs User32's menu modal loop inside this very call
    (WM_ENTERMENULOOP arms the backend's pump timer): the thread spins in
    the native loop until the menu is dismissed. Only the Event Horizon
    timer's completion — delivered by that WM_TIMER pump — calls
    exitModalPhase, so returning from here is itself the survival proof.
    */
    void enterModalPhase()
    {
        auto menu = CreatePopupMenu();
        assert(menu !is null);
        scope (exit) DestroyMenu(menu);
        assert(AppendMenuW(menu, MF_STRING, 1, "sparkles"w.ptr));
        SetForegroundWindow(hwnd);
        SetActiveWindow(hwnd);
        assert(TrackPopupMenu(menu, 0, 10, 10, 0, hwnd, null));
    }

    void exitModalPhase() nothrow @nogc
    {
        enum UINT WM_CANCELMODE_ = 0x001F;
        SendMessageW(hwnd, WM_CANCELMODE_, 0, 0);
    }

    void requestClose()
    {
        assert(PostMessageW(hwnd, WM_CLOSE, 0, 0));
    }

    void injectChord()
    {
        SendMessageW(hwnd, WM_KEYDOWN, VK_SHIFT, 0x002A_0001);
        SendMessageW(hwnd, WM_KEYDOWN, 'A', 0x001E_0001);
        SendMessageW(hwnd, WM_KEYUP, 'A', 0xC01E_0001);
        SendMessageW(hwnd, WM_KEYUP, VK_SHIFT, 0xC02A_0001);
    }

    void injectClick()
    {
        enum LPARAM at = (80 << 16) | 120; // client (120, 80)
        SendMessageW(hwnd, WM_MOUSEMOVE, 0, at);
        SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, at);
        SendMessageW(hwnd, WM_LBUTTONUP, 0, at);
    }

    /*
    A captured window receives client-space messages with negative or
    beyond-size coordinates while dragging outside; this simulates that
    delivery and asserts the implicit capture itself through GetCapture —
    engaged by the press, released by the release.
    */
    void injectDragOutside()
    {
        enum LPARAM inside = (80 << 16) | 120;
        SendMessageW(hwnd, WM_MOUSEMOVE, 0, inside);
        SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, inside);
        assert(GetCapture() == hwnd,
            "the press did not engage implicit capture");
        const LPARAM outside = cast(LPARAM)(
            (cast(uint) cast(ushort) cast(short) -40 << 16)
            | cast(ushort) cast(short) -30);
        SendMessageW(hwnd, WM_MOUSEMOVE, MK_LBUTTON, outside);
        SendMessageW(hwnd, WM_LBUTTONUP, 0, outside);
        assert(GetCapture() is null,
            "the release did not drop implicit capture");
    }

    void checkCursorApplied(PointerShape shape)
    {
        assert(shape == PointerShape.text);
        SendMessageW(hwnd, WM_SETCURSOR, cast(WPARAM) hwnd, HTCLIENT);
        assert(GetCursor() == LoadCursorW(null, IDC_IBEAM),
            "WM_SETCURSOR did not apply the stored cursor");
    }

    /*
    Real cursor moves, not posted messages: only User32's own routing
    shows that an explicitly captured window receives motion from beyond
    its client area and that a clip clamps the landing point inside it.
    Two distinct points, neither inside first, so an uncaptured window
    receives nothing and the property times out.
    */
    void injectMotionOutside()
    {
        RECT client;
        assert(GetClientRect(hwnd, &client));
        POINT origin;
        assert(ClientToScreen(hwnd, &origin));
        assert(SetCursorPos(origin.x + client.right + 60,
            origin.y + client.bottom + 40));
        assert(SetCursorPos(origin.x + client.right + 60, origin.y + 20));
    }

    /// Injected input reaches Raw Input; a `SetCursorPos` warp does not.
    void injectRelativeMotion()
    {
        INPUT input;
        input.type = INPUT_MOUSE;
        input.mi.dx = 20;
        input.mi.dy = 20;
        input.mi.dwFlags = MOUSEEVENTF_MOVE;
        assert(SendInput(1, &input, INPUT.sizeof) == 1);
    }

    void injectScroll()
    {
        // Wheel messages carry screen coordinates.
        POINT at = POINT(120, 80);
        ClientToScreen(hwnd, &at);
        const position = cast(LPARAM)(
            (cast(uint) cast(ushort) at.y << 16) | cast(ushort) at.x);
        // -120: one detent toward the user, positive-down in WSI terms.
        SendMessageW(hwnd, WM_MOUSEWHEEL,
            cast(WPARAM)(cast(uint) cast(ushort) -120 << 16), position);
    }
}

int main()
{
    DefaultLoop loop;
    if (DefaultLoop.create(loop, LoopConfig()).hasError)
    {
        writeln("SKIP: IOCP unavailable");
        return 0;
    }

    Win32Wsi wsi;
    assert(!Win32Wsi.open(wsi).hasError);

    import core.stdc.stdlib : atof, getenv;

    const scaleText = getenv("WSI_EXPECT_SCALE");
    auto hooks = Win32Hooks(&wsi, &loop,
        expectedScale: scaleText !is null ? atof(scaleText) : 0);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi Win32 conformance");
    writeln("ok: Win32 WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");

    if (checkTextAndComposition(wsi))
        writeln("ok: Win32 text commit + IMM32 composition round trip");
    else
        writeln("ok: Win32 text commit + IMM32 result commit (no preedit "
            ~ "phase: the active keyboard layout has no IME UI)");

    checkClipboard(wsi, loop);
    return 0;
}

private extern (Windows) nothrow @nogc
BOOL K32GetProcessMemoryInfo(HANDLE process, PROCESS_MEMORY_COUNTERS* counters,
    DWORD size);

/// This process' working set and its peak, in KiB.
private SIZE_T[2] workingSetKiB()
{
    PROCESS_MEMORY_COUNTERS counters;
    counters.cb = PROCESS_MEMORY_COUNTERS.sizeof;
    assert(K32GetProcessMemoryInfo(GetCurrentProcess(), &counters,
        counters.cb));
    return [counters.WorkingSetSize / 1024, counters.PeakWorkingSetSize / 1024];
}

/**
Addendum: the clipboard (`DT1`–`DT5`). The shared suite round-trips 32 MiB
through the Win32 clipboard: the offer is delay-rendered into one block the
clipboard owns, and the receive streams it out in 64 KiB chunks. Then another
party that does not go through the WSI reads offered UTF-8 text as
`CF_UNICODETEXT`, and sets UTF-16 text of its own: that offer is announced as
UTF-8 text and reads back intact.
*/
private void checkClipboard(ref Win32Wsi wsi, ref DefaultLoop loop)
{
    WindowConfig config;
    assert(config.title.assign("sparkles:wsi Win32 clipboard"));
    const id = wsi.createWindow(config).value;

    static struct ClipboardHooks
    {
        Win32Wsi* wsi;
        DefaultLoop* loop;
        ulong transferBytes = 32UL << 20; // `DT5`
        enum size_t maxChunkBytes = Win32Wsi.clipChunkBytes;

        void step(Duration timeout)
        {
            loop.runHostedOnce(*wsi, timeout).value;
        }
    }

    auto hooks = ClipboardHooks(&wsi, &loop);
    const before = workingSetKiB();
    const started = MonoTime.currTime;
    const clip = checkClipboardConformance(wsi, loop, hooks, id);
    const elapsed = (MonoTime.currTime - started).total!"msecs";
    const after = workingSetKiB();
    // `DT4`: WSI keeps one 64 KiB chunk; the 32 MiB lives in the block
    // `WM_RENDERFORMAT` hands the clipboard (the requester's side), freed
    // when the next offer empties the clipboard. So the working set may
    // peak by about the value's size, and must settle back afterwards.
    const peakGrew = cast(long) after[1] - cast(long) before[1];
    const settled = cast(long) after[0] - cast(long) before[0];
    enum long valueKiB = 32 * 1024;
    assert(peakGrew < valueKiB * 2 + 8 * 1024, text("the working set peaked ",
        peakGrew, " KiB above its start across a 32 MiB round trip"));
    assert(settled < 4 * 1024, text("the working set stayed ", settled,
        " KiB above its start after a 32 MiB round trip"));
    writeln("ok: Win32 clipboard conformance (", clip.checked,
        " checked, 32 MiB through delayed rendering in ", elapsed,
        " ms, working set peak +", peakGrew, " KiB, settled ", settled,
        " KiB)");

    // Another party: a window of its own, not the WSI's, that reads and
    // writes the clipboard the plain Win32 way. `OpenClipboard(null)` would
    // not do for writing: an ownerless clipboard refuses `SetClipboardData`.
    auto writer = CreateWindowExW(0, "STATIC"w.ptr, null, 0, 0, 0, 0, 0,
        HWND_MESSAGE, null, GetModuleHandleW(null), null);
    assert(writer !is null, "the other party's window could not be made");
    scope (exit) DestroyWindow(writer);

    // It reads an offer of UTF-8 text as `CF_UNICODETEXT`, rendered on
    // request in 64 KiB pieces of UTF-8: over 64 KiB of text whose 2-, 3-
    // and 4-byte sequences straddle those pieces must arrive whole.
    {
        import std.utf : toUTF16;

        static struct TextProvider
        {
            string text;

            size_t fill(scope const(char)[], ulong offset, scope ubyte[] buffer)
                @safe pure nothrow @nogc
            {
                if (offset >= text.length)
                    return 0;
                const at = cast(size_t) offset;
                const n = text.length - at < buffer.length
                    ? text.length - at : buffer.length;
                buffer[0 .. n] = cast(const(ubyte)[]) text[at .. at + n];
                return n;
            }
        }

        auto ours = TextProvider("ünïcode ✓ 😀 ".replicate(9000));
        const(char)[][1] plain = ["text/plain;charset=utf-8"];
        const offered = wsi.offerClipboard(id, plain[], ours);
        assert(!offered.hasError, "offering text failed");
        assert(OpenClipboard(writer), "the other party could not open the clipboard");
        auto data = GetClipboardData(CF_UNICODETEXT);
        assert(data !is null, "CF_UNICODETEXT was not rendered");
        const units = cast(const(wchar)*) GlobalLock(data);
        const expected = ours.text.toUTF16;
        const size = GlobalSize(data) / wchar.sizeof;
        const intact = size == expected.length + 1
            && units[0 .. expected.length] == expected && units[expected.length] == 0;
        GlobalUnlock(data);
        assert(CloseClipboard());
        assert(intact, "the CF_UNICODETEXT rendering did not match the UTF-8 offered");
        assert(!wsi.withdrawClipboard(offered.value).hasError);
        // Its `offered` and `withdrawn` events are not the foreign offer's.
        assert(!wsi.drain((WindowEvent event) {}).hasError);
        writeln("ok: Win32 offers UTF-8 text as CF_UNICODETEXT (",
            ours.text.length / 1024, " KiB intact)");
    }

    // Over 64 KiB, so its UTF-16 is read in several chunks, with surrogate
    // pairs at their edges.
    const string theirs = "copied by another writer: ünïcode ✓ 😀 ".replicate(3000);
    {
        import std.utf : toUTF16;

        const wide = theirs.toUTF16;
        auto block = GlobalAlloc(GMEM_MOVEABLE, (wide.length + 1) * wchar.sizeof);
        assert(block !is null);
        auto units = cast(wchar*) GlobalLock(block);
        units[0 .. wide.length] = wide[];
        units[wide.length] = 0;
        GlobalUnlock(block);
        assert(OpenClipboard(writer), "the second writer could not open the clipboard");
        assert(EmptyClipboard());
        assert(SetClipboardData(CF_UNICODETEXT, block) !is null,
            "the second writer could not set its text");
        assert(CloseClipboard());
    }

    OfferId offer;
    const deadline = MonoTime.currTime + 5.seconds;
    while (offer == OfferId.init)
    {
        assert(MonoTime.currTime < deadline, "the foreign offer was never announced");
        hooks.step(50.msecs);
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in DataOfferEvent e) {
                    if (e.action != DataOfferAction.offered)
                        return;
                    assert(!wsi.withText(e.mimeType, (scope const(char)[] mime) {
                        if (mime == "text/plain;charset=utf-8")
                            offer = e.offer;
                    }).hasError);
                },
                (_) {});
        }).hasError);
    }
    static struct Collect
    {
        char[] text;
        size_t largest;
        bool done, ok;

        void chunk(TransferId, scope const(ubyte)[] bytes) @safe nothrow
        {
            text ~= cast(const(char)[]) bytes;
            largest = bytes.length > largest ? bytes.length : largest;
        }

        void finish(TransferId, TransferStatus status) @safe nothrow
        {
            done = true;
            ok = status == TransferStatus.completed;
        }
    }
    Collect paste;
    assert(!wsi.receive(offer, "text/plain;charset=utf-8", paste).hasError);
    while (!paste.done)
    {
        assert(MonoTime.currTime < deadline + 5.seconds, "the paste never finished");
        hooks.step(50.msecs);
    }
    assert(paste.ok && paste.text == theirs,
        "another writer's text did not arrive intact");
    assert(paste.largest <= Win32Wsi.clipChunkBytes,
        "a chunk exceeded the bound a sink may receive");
    assert(!wsi.destroyWindow(id).hasError);
    writeln("ok: Win32 reads another writer's clipboard (",
        theirs.length / 1024, " KiB of UTF-16 text intact)");
}

/// Win32-only addendum: VK logical identity, UTF-16 commits, and the IMM32
/// preedit/result contract, on a fresh window. Returns whether the IMM32
/// preedit phase was seen. `CPS_COMPLETE` commits the result string on every
/// host — that is asserted unconditionally — but only an IME UI shows a
/// preedit first: Wine's IMM32 does on any layout, native Windows on a
/// hosted CI runner's US layout does not, and IMM32's static queries cannot
/// tell the two apart (`ImmIsIME` answers true for the plain US layout on
/// both, and the IME file name is empty on both). So the preedit phase is
/// reported where it appears, a composition that started must end, and the
/// report line carries what the layout claimed next to what was seen.
private bool checkTextAndComposition(ref Win32Wsi wsi)
{
    WindowConfig config;
    assert(config.title.assign("sparkles:wsi Win32 text"));
    config.logicalSize = LogicalSize(480, 320);
    const id = wsi.createWindow(config).value;
    ulong lastSequence;
    bool ready;
    auto readyDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        if (event.window == id)
            event.payload.match!(
                (in ReadyEvent _) { ready = true; },
                (_) {});
    });
    assert(!readyDrain.hasError && ready);
    HWND hwnd = wsi.nativeHandles(id).value.window.match!(
        (in Win32WindowHandle handle) => cast(HWND) handle.hwnd,
        (_) => cast(HWND) null);
    assert(hwnd !is null);

    // Event text is read through the WSI while the drain delivers it (`ED8`).
    bool textIs(TextId id, string expected)
    {
        bool same;
        assert(!wsi.withText(id, (scope const(char)[] text) {
            same = text == expected;
        }).hasError);
        return same;
    }

    // Physical-key and UTF-16 commit channels, independent of Wine's
    // installed keyboard layouts.
    SendMessageW(hwnd, WM_KEYDOWN, 'A', 0x001E_0001);
    SendMessageW(hwnd, WM_CHAR, 'a', 0);
    SendMessageW(hwnd, WM_KEYUP, 'A', 0xC01E_0001);
    bool keyPressed;
    bool keyReleased;
    bool charCommitted;
    auto keyDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in KeyboardEvent key) {
                assert(key.physical.nativeCode == 0x1E);
                assert(key.logical.nativeCode == 'A');
                keyPressed |= key.action == KeyAction.press;
                keyReleased |= key.action == KeyAction.release;
            },
            (in TextCommittedEvent text) {
                charCommitted |= textIs(text.text, "a");
            },
            (_) {});
    });
    assert(!keyDrain.hasError && keyPressed && keyReleased && charCommitted);

    // Wine's IMM32 implementation provides a deterministic, headless IME
    // round trip: setting the composition synchronously emits preedit, and
    // completing it emits GCS_RESULTSTR plus end-composition.
    auto context = ImmGetContext(hwnd);
    assert(context !is null);
    immutable preedit = "nihao"w;
    assert(ImmSetCompositionStringW(context, SCS_SETSTR, preedit.ptr,
        cast(DWORD)(preedit.length * wchar.sizeof), null, 0));
    assert(ImmNotifyIME(context, NI_COMPOSITIONSTR, CPS_COMPLETE, 0));
    assert(ImmReleaseContext(hwnd, context));

    bool sawPreedit;
    bool sawCompositionEnd;
    bool sawImeCommit;
    auto imeDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in CompositionEvent composition) {
                if (textIs(composition.preedit, "nihao"))
                {
                    sawPreedit = true;
                    assert(composition.cursor == 5);
                    assert(composition.segmentCount == 1);
                    assert(composition.segments[0].style
                        == CompositionSegmentStyle.underline);
                }
                else if (sawPreedit && composition.preedit == TextId.init)
                    sawCompositionEnd = true;
            },
            (in TextCommittedEvent text) {
                sawImeCommit |= textIs(text.text, "nihao");
            },
            (_) {});
    });
    assert(!imeDrain.hasError);
    const composed = sawPreedit && sawCompositionEnd && sawImeCommit;
    auto layout = GetKeyboardLayout(0);
    const layoutHasIme = ImmIsIME(layout) != 0;
    // The report carries what IMM32 says about the layout next to what was
    // observed, so a skip (or a failure) can be read without a debugger.
    wchar[260] imeFile = void;
    const imeFileLength = ImmGetIMEFileNameW(layout, imeFile.ptr,
        cast(UINT) imeFile.length);
    writefln("info: Win32 keyboard layout %08x ImmIsIME=%s imeFile=%s "
        ~ "preedit=%s compositionEnd=%s commit=%s",
        cast(size_t) layout, layoutHasIme, imeFile[0 .. imeFileLength],
        sawPreedit, sawCompositionEnd, sawImeCommit);
    assert(sawImeCommit, "IMM32 CPS_COMPLETE must commit the result string");
    assert(!sawPreedit || sawCompositionEnd,
        "a composition that started must also end");

    assert(!wsi.destroyWindow(id).hasError);
    return composed;
}
