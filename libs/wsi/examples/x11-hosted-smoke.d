/**
X11 driver for the shared WSI conformance suite.

Every behavior assertion lives in `sparkles.wsi.conformance`; this driver
only supplies what X11 alone can: the integrated Event Horizon step, XCB
resize/close requests, and an XTEST-injected key chord (X keycodes are
evdev + 8). Run through `scripts/verify-x11-xvfb.sh`.
*/
module x11_hosted_smoke;

version (linux):

import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : text;
import std.stdio : writeln;
import std.sumtype : match;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.wsi;
import xcb_native : xcb_connection_t;
import xcb_test_input : ForeignClipboardOwner, focusWindow, resizeWindow,
    sendButton, sendClose,
    sendKey, sendRelativeMotion, warpPointerOnScreen;

private struct X11Hooks
{
    X11Wsi* wsi;
    DefaultLoop* loop;
    xcb_connection_t* connection;
    uint window;
    WindowId windowId;
    bool imeEnabled;

    enum uint chordShiftCode = 50; // X keycode: KEY_LEFTSHIFT + 8
    enum uint chordKeyCode = 38; // X keycode: KEY_A + 8
    enum clickPosition = PhysicalPosition(120, 80);
    enum bool expectPointerMotion = true;
    // Layout-derived unshifted spelling the chorded key must carry.
    enum dchar chordKeyCharacter = 'a';
    enum string chordTypedText = "A";
    enum bool expectFocusEvent = true;

    void step(Duration timeout)
    {
        wsi.runIntegratedOnce(*loop, timeout).value;
    }

    void onWindowReady(WindowId id)
    {
        windowId = id;
        auto handles = wsi.nativeHandles(id).value;
        connection = handles.display.match!(
            (in X11DisplayHandle handle)
                => cast(xcb_connection_t*) handle.connection,
            (_) => null);
        window = handles.window.match!(
            (in X11WindowHandle handle) => handle.window,
            (_) => 0u);
        assert(connection !is null && window != 0);
    }

    void checkHandles(in NativeHandles handles)
    {
        assert(handles.display.match!(
            (in X11DisplayHandle handle) => handle.connection !is null,
            (_) => false));
        assert(handles.window.match!(
            (in X11WindowHandle handle) => handle.window != 0,
            (_) => false));
    }

    void requestResize(uint width, uint height)
    {
        assert(resizeWindow(connection, window, width, height) == 0);
    }

    void requestClose()
    {
        assert(sendClose(connection, window) == 0);
    }

    enum uint holdKeyCode = chordKeyCode;

    // The lane's test XIM server commits "xim" for the commit key
    // (X keycode 54, evdev KEY_C) and bounces every other key back.
    enum string imeCommittedText = "xim";
    enum uint imeCommitKeyCode = 54;

    void injectImeCommit()
    {
        // The XIM handshake (discovery, open, create-ic) races window
        // creation; inject only once the input context is live, or the
        // key would be delivered as a bare key and no commit could come.
        foreach (_; 0 .. 400)
        {
            if (wsi.textInputReady(windowId))
                break;
            step(25.msecs);
        }
        assert(wsi.textInputReady(windowId),
            "the XIM input context never became ready");
        assert(sendKey(connection, imeCommitKeyCode, true) == 0);
        assert(sendKey(connection, imeCommitKeyCode, false) == 0);
    }

    void holdKey()
    {
        assert(sendKey(connection, holdKeyCode, true) == 0);
    }

    void releaseHold()
    {
        assert(sendKey(connection, holdKeyCode, false) == 0);
    }

    void injectChord()
    {
        assert(focusWindow(connection, window) == 0);
        assert(sendKey(connection, chordShiftCode, true) == 0);
        assert(sendKey(connection, chordKeyCode, true) == 0);
        assert(sendKey(connection, chordKeyCode, false) == 0);
        assert(sendKey(connection, chordShiftCode, false) == 0);
    }

    void injectClick()
    {
        // No window manager: the window sits at the root origin, so root
        // and window coordinates coincide.
        assert(warpPointerOnScreen(connection, 120, 80) == 0);
        assert(sendButton(connection, 1, true) == 0);
        assert(sendButton(connection, 1, false) == 0);
    }

    void injectScroll()
    {
        assert(sendButton(connection, 5, true) == 0);
        assert(sendButton(connection, 5, false) == 0);
    }

    void injectDragOutside()
    {
        // Press inside; the core protocol's automatic press–release grab
        // must keep routing after the warp beyond the 640x480 window.
        assert(warpPointerOnScreen(connection, 120, 80) == 0);
        assert(sendButton(connection, 1, true) == 0);
        assert(warpPointerOnScreen(connection, 700, 500) == 0);
        assert(sendButton(connection, 1, false) == 0);
    }

    void injectMotionOutside()
    {
        // No button held and no inside warp first: only an explicit grab
        // (F10) routes motion beyond the 640x480 window back to it, and a
        // confining grab clamps each warp to a different edge point, so the
        // pointer moves inside the bounds. Without a grab nothing arrives.
        assert(warpPointerOnScreen(connection, 700, 500) == 0);
        assert(warpPointerOnScreen(connection, 700, 300) == 0);
    }

    void injectRelativeMotion()
    {
        // A core WarpPointer is a server-side move and raises no raw event;
        // XTEST motion comes from the virtual XTEST slave pointer, so XI2
        // RawMotion on every device sees it like a real mouse.
        assert(warpPointerOnScreen(connection, 120, 80) == 0);
        assert(sendRelativeMotion(connection, 20, 20) == 0);
    }
}

int main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    X11Wsi wsi;
    auto opened = X11Wsi.open(wsi);
    if (opened.hasError && opened.error.kind == WsiErrorKind.unavailable)
    {
        writeln("SKIP: no X11 display");
        return 0;
    }
    assert(!opened.hasError);
    assert(!wsi.attach(loop).hasError);

    auto hooks = X11Hooks(&wsi, &loop);
    {
        import core.stdc.stdlib : getenv;

        // The IME property needs the lane's XIM server on $XMODIFIERS.
        hooks.imeEnabled = getenv("WSI_XIM_LANE") !is null;
    }
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi X11 conformance");
    writeln("ok: X11 WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");

    /*
    Addendum: one device motion is one `RelativePointerEvent`. XInput 2
    raises a raw event per slave device that reported the motion and, since
    2.1, a copy under the master's id; only the slave's own delivery from a
    relative-axis device may come through (Xwayland's absolute pointer
    beside its relative one would otherwise double every move).
    */
    {
        WindowConfig config;
        assert(config.title.assign("sparkles:wsi X11 raw motion"));
        const id = wsi.createWindow(config).value;
        bool ready;
        const readyDeadline = MonoTime.currTime + 5.seconds;
        while (!ready)
        {
            assert(MonoTime.currTime < readyDeadline,
                "no ReadyEvent for the raw-motion window");
            hooks.step(200.msecs);
            assert(!wsi.drain((WindowEvent event) {
                if (event.window == id)
                    event.payload.match!(
                        (in ReadyEvent _) { ready = true; },
                        (_) {});
            }).hasError);
        }
        assert(!wsi.setRelativePointer(id, true).hasError);
        assert(sendRelativeMotion(hooks.connection, 20, 20) == 0);
        uint relativeEvents;
        double dx = 0;
        // Wait long enough for every copy the server might send.
        foreach (_; 0 .. 5)
        {
            hooks.step(100.msecs);
            assert(!wsi.drain((WindowEvent event) {
                event.payload.match!(
                    (in RelativePointerEvent value) {
                        ++relativeEvents;
                        dx = value.dx;
                    },
                    (_) {});
            }).hasError);
        }
        assert(relativeEvents == 1,
            "one device motion must be exactly one RelativePointerEvent");
        assert(dx == 20, "the raw delta must be the device's own value");
        assert(!wsi.setRelativePointer(id, false).hasError);
        assert(!wsi.destroyWindow(id).hasError);
        writeln("ok: X11 raw motion is one event per device motion");
    }

    /*
    Addendum: floods (`ED2`, `ED3`, `ED5`). XTEST delivers far more events in
    one dispatch than the 128-slot queue holds. Motion merges in place, so a
    motion flood drops nothing: the relative delta arrives summed and the
    samples stay readable beside the queue. Clicks never merge, so a click
    flood overflows: the excess is counted, the drain reports it last as an
    `EventsDropped` event, and the loop keeps running.
    */
    {
        WindowConfig config;
        assert(config.title.assign("sparkles:wsi X11 flood"));
        const id = wsi.createWindow(config).value;
        bool ready;
        const readyDeadline = MonoTime.currTime + 5.seconds;
        while (!ready)
        {
            assert(MonoTime.currTime < readyDeadline,
                "no ReadyEvent for the flood window");
            hooks.step(200.msecs);
            assert(!wsi.drain((WindowEvent event) {
                if (event.window == id)
                    event.payload.match!(
                        (in ReadyEvent _) { ready = true; },
                        (_) {});
            }).hasError);
        }
        assert(!wsi.setRelativePointer(id, true).hasError);

        // Every motion raises a core and a raw event: several times the
        // queue's capacity, all of it merging.
        foreach (_; 0 .. 400)
            assert(sendRelativeMotion(hooks.connection, 1, 0) == 0);
        foreach (_; 0 .. 4)
            hooks.step(100.msecs);

        double dx = 0;
        uint samples;
        uint motionDropped;
        ulong last;
        assert(!wsi.drain((WindowEvent event) {
            assert(event.sequence > last, "drained order stays increasing");
            last = event.sequence;
            event.payload.match!(
                (in RelativePointerEvent value) {
                    dx += value.dx;
                    samples += value.samples;
                },
                (in EventsDroppedEvent value) { motionDropped = value.count; },
                (_) {});
        }).hasError, "the motion flood must not fail the drain");
        assert(motionDropped == 0, "merging motion overflowed the queue");
        assert(dx == 400 && samples == 400, "the merged delta is the flood's sum");
        PointerSample[64] kept;
        assert(wsi.copySamples(id, PointerId(0, 1), kept[]) == kept.length,
            "the history ring holds the newest samples");
        assert(!wsi.setRelativePointer(id, false).hasError);

        // Clicks anchor the order and never merge: 200 clicks are 400
        // events in one dispatch, more than the queue holds.
        assert(warpPointerOnScreen(hooks.connection, 120, 80) == 0);
        foreach (_; 0 .. 200)
        {
            assert(sendButton(hooks.connection, 1, true) == 0);
            assert(sendButton(hooks.connection, 1, false) == 0);
        }
        foreach (_; 0 .. 4)
            hooks.step(100.msecs);

        uint dropped;
        ulong noticeSequence;
        size_t delivered;
        last = 0;
        assert(!wsi.drain((WindowEvent event) {
            assert(event.sequence > last, "drained order stays increasing");
            last = event.sequence;
            ++delivered;
            event.payload.match!(
                (in EventsDroppedEvent value) {
                    dropped = value.count;
                    noticeSequence = event.sequence;
                },
                (_) {});
        }).hasError, "the flood must not fail the drain");
        assert(dropped != 0, "the click flood did not overflow the queue");
        assert(noticeSequence == last, "the notice is delivered last");

        // The regression: the dispatch after an overflow used to fail.
        hooks.step(100.msecs);
        assert(!wsi.destroyWindow(id).hasError);
        writeln("ok: X11 motion flood merged (", samples, " samples, none dropped)");
        writeln("ok: X11 queue overflow reported, not fatal (", dropped,
            " dropped of ", dropped + delivered, ")");
    }

    /*
    Addendum: the clipboard (`DT1`–`DT5`). The shared suite round-trips 1 MiB
    through the X server, which this backend serves and reads `INCR` in
    64 KiB chunks. Then another client takes the selection: its offer is
    announced from its `TARGETS`, with `UTF8_STRING` as UTF-8 text, and reads
    back through the same path.
    */
    {
        WindowConfig config;
        assert(config.title.assign("sparkles:wsi X11 clipboard"));
        const id = wsi.createWindow(config).value;
        ForeignClipboardOwner foreign;
        static struct ClipboardHooks
        {
            X11Wsi* wsi;
            DefaultLoop* loop;
            ForeignClipboardOwner* foreign;
            ulong transferBytes = 32UL << 20; // `DT5`
            enum size_t maxChunkBytes = X11Wsi.clipChunkBytes;

            void step(Duration timeout)
            {
                wsi.runIntegratedOnce(*loop, timeout).value;
                if (foreign.connection !is null)
                    foreign.pump();
            }
        }
        auto clipHooks = ClipboardHooks(&wsi, &loop, &foreign);
        const before = residentKiB();
        const started = MonoTime.currTime;
        const clip = checkClipboardConformance(wsi, loop, clipHooks, id);
        const grew = residentKiB() - before;
        // `DT4`: one 64 KiB chunk per transfer in flight; the sink checks
        // each byte and keeps none, so 32 MiB must not show up here.
        assert(grew < 4 * 1024, text("resident memory grew by ", grew,
            " KiB across a 32 MiB round trip"));
        writeln("ok: X11 clipboard conformance (", clip.checked,
            " checked, 32 MiB through INCR in ",
            (MonoTime.currTime - started).total!"msecs", " ms, resident +", grew, " KiB)");

        static immutable string theirs = "copied in another client: ünïcode";
        assert(foreign.open(theirs), "the foreign client could not take CLIPBOARD");
        scope (exit) foreign.close();
        OfferId offer;
        const deadline = MonoTime.currTime + 5.seconds;
        while (offer == OfferId.init)
        {
            assert(MonoTime.currTime < deadline, "the foreign offer was never announced");
            clipHooks.step(50.msecs);
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
            char[128] text;
            size_t length;
            bool done, ok;

            void chunk(TransferId, scope const(ubyte)[] bytes) @safe nothrow
            {
                text[length .. length + bytes.length] = cast(const(char)[]) bytes;
                length += bytes.length;
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
            clipHooks.step(50.msecs);
        }
        assert(paste.ok && paste.text[0 .. paste.length] == theirs,
            "another client's text did not arrive intact");
        assert(!wsi.destroyWindow(id).hasError);
        writeln("ok: X11 reads another client's clipboard");
    }
    return 0;
}

/// This process' resident set, from `/proc/self/statm`, in KiB.
private long residentKiB()
{
    import std.file : readText;
    import std.string : split;
    import std.conv : to;
    import core.sys.posix.unistd : sysconf, _SC_PAGESIZE;

    const pages = readText("/proc/self/statm").split[1].to!long;
    return pages * sysconf(_SC_PAGESIZE) / 1024;
}
