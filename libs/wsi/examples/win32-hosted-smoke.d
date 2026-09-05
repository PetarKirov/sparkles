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
import core.sys.windows.windows;
import core.time : Duration, MonoTime, seconds;
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
    return 0;
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
                charCommitted |= text.text[] == "a";
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
                if (composition.preedit[] == "nihao")
                {
                    sawPreedit = true;
                    assert(composition.cursor == 5);
                    assert(composition.segmentCount == 1);
                    assert(composition.segments[0].style
                        == CompositionSegmentStyle.underline);
                }
                else if (sawPreedit && composition.preedit.empty)
                    sawCompositionEnd = true;
            },
            (in TextCommittedEvent text) {
                sawImeCommit |= text.text[] == "nihao";
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
