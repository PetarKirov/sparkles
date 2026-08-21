/**
Win32 lifecycle + Event Horizon hosted-wait smoke test.

Cross-compile and run through `scripts/verify-win32-wine.sh`. The bounded run
creates a real HWND, observes ready/expose/resize/close/destroy events, proves
the typed handle, and drives an IOCP timer plus a foreign-thread waker through
the same `MsgWaitForMultipleObjectsEx` wait as User32 messages.
*/
module win32_hosted_smoke;

version (Windows):

import core.sys.windows.windows;
import core.sys.windows.imm : CPS_COMPLETE, NI_COMPOSITIONSTR, SCS_SETSTR;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.stdio : writeln;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op : Completion;
import sparkles.input.events : KeyAction;
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

private __gshared Win32Wsi* wrongThreadWsi;
private __gshared WsiErrorKind wrongThreadKind;

private void timerComplete(void* context, ref Completion completion)
    nothrow @nogc
{
    *cast(bool*) context = completion.res == 0;
}

int main()
{
    DefaultLoop loop;
    auto openedLoop = DefaultLoop.create(loop, LoopConfig());
    if (openedLoop.hasError)
    {
        writeln("SKIP: IOCP unavailable");
        return 0;
    }

    auto armed = loop.waker();
    assert(armed.hasValue);
    auto waker = armed.value;

    Win32Wsi wsi;
    auto openedWsi = Win32Wsi.open(wsi);
    assert(!openedWsi.hasError);

    WindowConfig config;
    assert(config.title.assign("sparkles:wsi Wine smoke"));
    config.logicalSize = LogicalSize(480, 320);
    const created = wsi.createWindow(config);
    assert(created.hasValue);
    const id = created.value;

    bool ready;
    bool exposed;
    bool frameReady;
    ulong lastSequence;
    auto drain = () {
        auto result = wsi.drain((WindowEvent event) {
            assert(event.sequence > lastSequence);
            lastSequence = event.sequence;
            event.payload.match!(
                (in ReadyEvent _) { ready = true; },
                (in ExposedEvent _) { exposed = true; },
                (in FrameReadyEvent _) { frameReady = true; },
                (_) {});
        });
        assert(result.hasValue);
    };
    drain();
    assert(ready && exposed && frameReady);

    wrongThreadWsi = &wsi;
    auto wrongThread = new Thread({
        auto result = wrongThreadWsi.pumpMessages();
        if (result.hasError)
            wrongThreadKind = result.error.kind;
    });
    wrongThread.start();
    wrongThread.join();
    assert(wrongThreadKind == WsiErrorKind.wrongThread);
    wrongThreadWsi = null;

    auto queried = wsi.nativeHandles(id);
    assert(queried.hasValue);
    HWND hwnd = queried.value.window.match!(
        (in Win32WindowHandle handle) => cast(HWND) handle.hwnd,
        (_) => cast(HWND) null);
    assert(hwnd !is null);

    // Exercise the physical-key and UTF-16 commit channels independently of
    // Wine's installed keyboard layouts.
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
                charCommitted |= text.text.value == "a";
            },
            (_) {});
    });
    assert(keyDrain.hasValue && keyPressed && keyReleased && charCommitted);

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
                if (composition.preedit.value == "nihao")
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
                sawImeCommit |= text.text.value == "nihao";
            },
            (_) {});
    });
    assert(imeDrain.hasValue && sawPreedit && sawCompositionEnd
        && sawImeCommit);

    // Programmatic size messages are delivered synchronously inside User32.
    assert(SetWindowPos(hwnd, null, 0, 0, 640, 480,
        SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER));
    bool resized;
    auto resizedDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in SurfaceMetricsChangedEvent metrics) {
                resized = metrics.metrics.physicalSize.width > 0
                    && metrics.metrics.physicalSize.height > 0;
            },
            (_) {});
    });
    assert(resizedDrain.hasValue && resized);

    bool timerFired;
    auto timer = loop.submitAfter(25.msecs, &timerComplete, &timerFired);
    assert(timer.hasValue);

    auto worker = new Thread({
        Thread.sleep(10.msecs);
        waker.wake();
    });
    worker.start();

    const started = MonoTime.currTime;
    auto first = loop.runHostedOnce(wsi, 5.seconds);
    assert(first.hasValue && first.value == RunStatus.dispatched);
    while (!timerFired)
    {
        auto step = loop.runHostedOnce(wsi, 5.seconds);
        assert(step.hasValue && step.value == RunStatus.dispatched);
    }
    const elapsed = MonoTime.currTime - started;
    worker.join();
    assert(elapsed < 2.seconds);

    assert(PostMessageW(hwnd, WM_CLOSE, 0, 0));
    assert(wsi.pumpMessages().hasValue);
    bool closeRequested;
    auto closeDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in CloseRequestedEvent _) { closeRequested = true; },
            (_) {});
    });
    assert(closeDrain.hasValue && closeRequested);

    assert(!wsi.destroyWindow(id).hasError);
    bool destroyed;
    auto destroyedDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in DestroyedEvent _) { destroyed = true; },
            (_) {});
    });
    assert(destroyedDrain.hasValue && destroyed);

    writeln("ok: Win32 HWND + keyboard/IMM32 + IOCP hosted wait");
    return 0;
}
