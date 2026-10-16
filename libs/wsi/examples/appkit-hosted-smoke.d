/**
AppKit driver for the shared WSI conformance suite.

Every cross-backend assertion lives in `sparkles.wsi.conformance`; this
driver supplies the CFRunLoop/kqueue hosted step, `setContentSize` and
`performClose:` requests, and a synthetic key chord posted through the real
responder chain (`NSEvent.keyEventWithType` + `postEvent:`) — the modifier
travels as `flagsChanged` and the letter as `keyDown`/`keyUp`, with real
modifier flags on the events themselves. Run on macOS through
`scripts/verify-appkit-macos.sh`.
*/
module appkit_hosted_smoke;

version (OSX):

import core.attribute : selector;
import core.time : Duration, seconds;
import std.stdio : writeln;
import std.string : toStringz;

import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.input.pointer : PointerShape;
import sparkles.wsi;

private extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    void* objc_autoreleasePoolPush();
    void objc_autoreleasePoolPop(void* pool);
}

private extern (C) struct NSSize
{
    double width;
    double height;
}

private extern (C) struct NSPoint
{
    double x;
    double y;
}

extern (Objective-C):

private extern class NSObject
{
}

private extern class NSWindow : NSObject
{
    void setContentSize(NSSize size) @selector("setContentSize:");
    void performClose(NSObject sender) @selector("performClose:");
    long windowNumber() @selector("windowNumber");
    NSPoint convertPointToScreen(NSPoint point)
        @selector("convertPointToScreen:");
}

private extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* text)
        @selector("initWithUTF8String:");
}

private extern class NSEvent : NSObject
{
    // Each selector is one string literal. The frontend hands a `@selector`
    // argument to a NUL-scanning lookup (`dmd/objc.d`: `peekString().ptr`). A
    // lexed literal is NUL-terminated in the compiler's memory; a `~`
    // concatenated at CTFE need not be, and the scan baked whatever followed
    // into the selector itself (`keyCode:sparkles.math.vector...`).
    static NSEvent mouseEventWithType(ulong type, NSPoint location,
        ulong modifierFlags, double timestamp, long windowNumber,
        NSObject context, long eventNumber, long clickCount, float pressure)
        @selector("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:");
    static NSEvent otherEventWithType(ulong type, NSPoint location,
        ulong modifierFlags, double timestamp, long windowNumber,
        NSObject context, short subtype, long data1, long data2)
        nothrow @nogc
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    static NSEvent eventWithCGEvent(void* cgEvent)
        @selector("eventWithCGEvent:");
    static NSEvent keyEventWithType(ulong type, NSPoint location,
        ulong modifierFlags, double timestamp, long windowNumber,
        NSObject context, NSString characters,
        NSString charactersIgnoringModifiers, bool isARepeat, ushort keyCode)
        @selector("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:");
}

private extern class NSApplication : NSObject
{
    static NSApplication sharedApplication() nothrow @nogc
        @selector("sharedApplication");
    void postEvent(NSEvent event, bool atStart) nothrow @nogc
        @selector("postEvent:atStart:");
    long runModalForWindow(NSWindow window)
        @selector("runModalForWindow:");
    void stopModal() nothrow @nogc @selector("stopModal");
}

private extern (C) struct NSRange
{
    ulong location;
    ulong length;
}

/*
The backend's content view, seen through its NSTextInputClient surface:
the addendum drives the protocol exactly as AppKit's input context would,
so the marked-text translation is exercised without depending on a system
IME being scriptable in this session.
*/
/*
Declared as the real (linkable) NSView class: the handle's object is the
backend's NSView subclass, and Objective-C dispatch resolves the protocol
selectors on the instance, not the static type.
*/
private extern class NSView : NSObject
{
    void insertText(NSString text, NSRange replacementRange)
        @selector("insertText:replacementRange:");
    void setMarkedText(NSString text, NSRange selectedRange,
        NSRange replacementRange)
        @selector("setMarkedText:selectedRange:replacementRange:");
    void unmarkText() @selector("unmarkText");
    bool hasMarkedText() @selector("hasMarkedText");
}

private extern class NSCursor : NSObject
{
    static NSCursor IBeamCursor() @selector("IBeamCursor");
    static NSCursor currentCursor() @selector("currentCursor");
}

// The pasteboard as another application writes it: straight through AppKit.
private extern class NSPasteboard : NSObject
{
    static NSPasteboard generalPasteboard() @selector("generalPasteboard");
    long clearContents() @selector("clearContents");
    bool setString(NSString text, NSString type) @selector("setString:forType:");
}

extern (D):

private extern (C) struct CGPoint
{
    double x;
    double y;
}

private extern (C) struct CGSize
{
    double width;
    double height;
}

private extern (C) struct CGRect
{
    CGPoint origin;
    CGSize size;
}

private extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    CGRect CGDisplayBounds(uint display);
    void* CGEventCreateMouseEvent(void* source, uint type, CGPoint location,
        uint button);
    void CGEventSetIntegerValueField(void* event, uint field, long value);
    void CFRelease(void* value);
}

private struct AppKitHooks
{
    AppKitWsi* wsi;
    DefaultLoop* loop;
    NSWindow nativeWindow;

    enum uint chordShiftCode = 0x38; // kVK_Shift
    enum uint chordKeyCode = 0x00; // kVK_ANSI_A
    // Layout-derived unshifted spelling the chorded key must carry.
    enum dchar chordKeyCharacter = 'a';
    enum bool resizeExact = false; // physical size scales with the backing
    enum bool expectPointerMotion = true; // position scales with the backing

    void step(Duration timeout)
    {
        loop.runHostedOnce(*wsi, timeout).value;
    }

    void onWindowReady(WindowId id)
    {
        nativeWindow = wsi.nativeHandles(id).value.window.match!(
            (in AppKitWindowHandle handle) => cast(NSWindow) handle.window,
            (_) => cast(NSWindow) null);
        assert(nativeWindow !is null);
    }

    void checkHandles(in NativeHandles handles)
    {
        assert(handles.window.match!(
            (in AppKitWindowHandle handle) => handle.window !is null
                && handle.view !is null,
            (_) => false));
    }

    void requestResize(uint width, uint height)
    {
        nativeWindow.setContentSize(NSSize(width, height));
    }

    /*
    runModalForWindow blocks in AppKit's modal session — a nested run loop
    this host does not own. The kqueue source lives in the common modes, so
    Event Horizon completions still fire; the property's timer callback
    calls stopModal, which is the only way this call returns.
    */
    void enterModalPhase()
    {
        NSApplication.sharedApplication().runModalForWindow(nativeWindow);
    }

    /*
    stopModal only takes effect from within one of the modal session's own
    event callouts; from a CFRunLoop source callout the session keeps
    waiting for its next event — so post one.
    */
    void exitModalPhase() nothrow @nogc
    {
        enum ulong applicationDefinedType = 15;
        auto application = NSApplication.sharedApplication();
        application.stopModal();
        auto wake = NSEvent.otherEventWithType(applicationDefinedType,
            NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
        if (wake !is null)
            application.postEvent(wake, true);
    }

    void requestClose()
    {
        nativeWindow.performClose(null);
    }

    void injectChord()
    {
        enum ulong keyDownType = 10;
        enum ulong keyUpType = 11;
        enum ulong flagsChangedType = 12;
        enum ulong shiftFlag = 1UL << 17;
        auto application = NSApplication.sharedApplication();
        auto lower = NSString.alloc().initWithUTF8String("a");
        auto upper = NSString.alloc().initWithUTF8String("A");
        const number = nativeWindow.windowNumber();
        // characters is the effective spelling, charactersIgnoringModifiers
        // the unshifted one the LogicalKey property asserts.
        void post(ulong type, ulong flags, NSString characters,
            NSString unshifted, ushort keyCode)
        {
            auto event = NSEvent.keyEventWithType(type, NSPoint(0, 0), flags,
                0, number, null, characters, unshifted, false, keyCode);
            assert(event !is null);
            application.postEvent(event, false);
        }

        post(flagsChangedType, shiftFlag, lower, lower, chordShiftCode);
        post(keyDownType, shiftFlag, upper, lower, chordKeyCode);
        post(keyUpType, shiftFlag, upper, lower, chordKeyCode);
        post(flagsChangedType, 0, lower, lower, chordShiftCode);
    }

    // Text on AppKit only ever arrives through the NSTextInputClient
    // protocol; for plain keys the input context commits the event's
    // characters, so a posted "x" proves the whole route.
    enum string imeCommittedText = "x";

    void injectImeCommit()
    {
        enum ulong keyDownType = 10;
        enum ulong keyUpType = 11;
        enum ushort xKeyCode = 0x07; // kVK_ANSI_X
        auto application = NSApplication.sharedApplication();
        auto text = NSString.alloc().initWithUTF8String("x");
        const number = nativeWindow.windowNumber();
        void post(ulong type)
        {
            auto event = NSEvent.keyEventWithType(type, NSPoint(0, 0), 0,
                0, number, null, text, text, false, xKeyCode);
            assert(event !is null);
            application.postEvent(event, false);
        }

        post(keyDownType);
        post(keyUpType);
    }

    // NSWindow keeps routing the drag to the mouseDown view, so the
    // outside release must come back through the same path.
    /*
    A posted NSEvent carries no deltas, so the relative property needs a
    Core Graphics event: the delta fields are set on it, it names the
    window under the pointer so AppKit resolves the target without a
    hit test on screen state this headless lane cannot rely on, and its
    location is the window's (120, 400) in Quartz's top-left screen space.
    Capture and confinement are typed `unsupported` here, which the
    properties accept as the honest answer; the hook exists so they run,
    and must never be reached.
    */
    void injectMotionOutside()
    {
        assert(false, "AppKit answered a capture mode with success");
    }

    void injectRelativeMotion()
    {
        enum uint mouseMovedType = 5; // kCGEventMouseMoved
        enum uint deltaXField = 4; // kCGMouseEventDeltaX
        enum uint deltaYField = 5; // kCGMouseEventDeltaY
        enum uint windowField = 91; // kCGMouseEventWindowUnderMousePointer
        const inScreen = nativeWindow.convertPointToScreen(NSPoint(120, 400));
        const screen = CGDisplayBounds(CGMainDisplayID());
        const at = CGPoint(inScreen.x, screen.size.height - inScreen.y);
        auto cgEvent = CGEventCreateMouseEvent(null, mouseMovedType, at, 0);
        assert(cgEvent !is null);
        CGEventSetIntegerValueField(cgEvent, deltaXField, 20);
        CGEventSetIntegerValueField(cgEvent, deltaYField, 20);
        CGEventSetIntegerValueField(cgEvent, windowField,
            nativeWindow.windowNumber());
        auto event = NSEvent.eventWithCGEvent(cgEvent);
        assert(event !is null);
        NSApplication.sharedApplication().postEvent(event, false);
        CFRelease(cgEvent);
    }

    void injectDragOutside()
    {
        enum ulong leftDownType = 1;
        enum ulong leftUpType = 2;
        enum ulong draggedType = 6; // NSEventTypeLeftMouseDragged
        auto application = NSApplication.sharedApplication();
        const number = nativeWindow.windowNumber();
        void post(ulong type, NSPoint at)
        {
            auto event = NSEvent.mouseEventWithType(type, at, 0, 0, number,
                null, 0, 1, 0);
            assert(event !is null);
            application.postEvent(event, false);
        }

        post(leftDownType, NSPoint(120, 400));
        post(draggedType, NSPoint(700, -50));
        post(leftUpType, NSPoint(700, -50));
    }

    void checkCursorApplied(PointerShape shape)
    {
        assert(shape == PointerShape.text);
        assert(NSCursor.currentCursor() is NSCursor.IBeamCursor(),
            "NSCursor.set did not make the shape current");
    }

    /*
    Synthetic mouse events route through NSWindow.sendEvent's hit test by
    windowNumber and location. Window coordinates are bottom-left; the
    resize property has set the content to 640x480 by now, so window
    (120, 400) is the view's (120, 80). No exact position is declared —
    the physical position scales with the backing store.
    */
    void injectClick()
    {
        enum ulong movedType = 5; // NSEventTypeMouseMoved
        enum ulong leftDownType = 1;
        enum ulong leftUpType = 2;
        auto application = NSApplication.sharedApplication();
        const number = nativeWindow.windowNumber();
        const at = NSPoint(120, 400);
        void post(ulong type)
        {
            auto event = NSEvent.mouseEventWithType(type, at, 0, 0, number,
                null, 0, type == movedType ? 0 : 1, 0);
            assert(event !is null);
            application.postEvent(event, false);
        }

        post(movedType);
        post(leftDownType);
        post(leftUpType);
    }

    // Synthetic scrollWheel events cannot carry scrolling deltas through
    // the public NSEvent factories, so the scroll property stays skipped.
}

int main()
{
    if (CGMainDisplayID() == 0)
    {
        writeln("SKIP: no macOS WindowServer");
        return 0;
    }

    auto pool = objc_autoreleasePoolPush();
    scope (exit) objc_autoreleasePoolPop(pool);

    DefaultLoop loop;
    assert(!DefaultLoop.create(loop, LoopConfig()).hasError);

    AppKitWsi wsi;
    assert(!AppKitWsi.open(wsi).hasError);

    auto hooks = AppKitHooks(&wsi, &loop);
    const outcome = checkWsiConformance(wsi, loop, hooks,
        "sparkles:wsi AppKit conformance");
    writeln("ok: AppKit WSI conformance (", outcome.checked, " checked, ",
        outcome.skipped, " skipped)");
    checkMarkedText(wsi);
    writeln("ok: AppKit marked-text round trip");
    checkClipboard(wsi, loop);
    return 0;
}

private extern (C) nothrow @nogc
{
    int task_info(uint task, int flavor, int* info, uint* count);
    extern __gshared uint mach_task_self_;
}

/// This process' resident set and its high-water mark, in KiB, from
/// `mach_task_basic_info`.
private long[2] residentKiB()
{
    enum int machTaskBasicInfo = 20; // MACH_TASK_BASIC_INFO
    // virtual, resident, resident_max (8 bytes each), two time_value_t,
    // policy, suspend_count: 12 natural_t under `#pragma pack(4)`.
    int[12] info;
    uint count = info.length;
    const kr = task_info(mach_task_self_, machTaskBasicInfo, info.ptr, &count);
    assert(kr == 0, "task_info failed");
    const resident = *cast(const(ulong)*) &info[2];
    const peak = *cast(const(ulong)*) &info[4];
    return [cast(long)(resident / 1024), cast(long)(peak / 1024)];
}

/*
AppKit-only addendum: the clipboard (`DT1`–`DT5`). The shared suite
round-trips 32 MiB through `NSPasteboard`: the backend's data provider pulls
the pattern into the pasteboard's `NSData`, and the paste reads it back in
64 KiB chunks. Then the pasteboard is written as another application would,
straight through AppKit, and the backend must report its own offer there
`withdrawn`, announce the new contents as a foreign offer, and read the text
back intact.
*/
private void checkClipboard(ref AppKitWsi wsi, ref DefaultLoop loop)
{
    import core.time : MonoTime, msecs;

    WindowConfig config;
    assert(config.title.assign("sparkles:wsi AppKit clipboard"));
    config.logicalSize = LogicalSize(320, 200);
    const id = wsi.createWindow(config).value;

    static struct ClipboardHooks
    {
        AppKitWsi* wsi;
        DefaultLoop* loop;
        ulong transferBytes = 32UL << 20; // `DT5`
        enum size_t maxChunkBytes = AppKitWsi.clipChunkBytes;

        void step(Duration timeout)
        {
            loop.runHostedOnce(*wsi, timeout).value;
        }
    }

    auto hooks = ClipboardHooks(&wsi, &loop);
    const before = residentKiB();
    const started = MonoTime.currTime;
    const clip = checkClipboardConformance(wsi, loop, hooks, id);
    const elapsed = (MonoTime.currTime - started).total!"msecs";
    const after = residentKiB();
    // The pasteboard's own `NSData` lives in this process, since this
    // process is its provider: 32 MiB the pasteboard asked for, which the
    // offer's withdrawal hands back to malloc. WSI's share is one chunk; a
    // copy of its own would show as a third 32 MiB.
    const peakGrew = after[1] - before[1];
    assert(peakGrew < 3 * 32 * 1024, "the round trip held more than the "
        ~ "pasteboard's copies");
    writeln("ok: AppKit clipboard conformance (", clip.checked,
        " checked, 32 MiB through NSPasteboard in ", elapsed,
        " ms, resident ", before[0] / 1024, " -> ", after[0] / 1024,
        " MiB, peak +", peakGrew / 1024, " MiB)");

    // An offer of this application's, for the other writer to replace.
    static immutable ubyte[4] ours = cast(immutable(ubyte)[4]) "ours";
    const own = wsi.offerClipboard(id, "text/plain;charset=utf-8", ours[]).value;
    // Drain what the suite left, so only the foreign offer is looked for.
    assert(!wsi.drain((WindowEvent event) {}).hasError);

    static immutable string theirs = "copied by another writer: ünïcode ✓";
    {
        auto pasteboard = NSPasteboard.generalPasteboard();
        auto text = NSString.alloc().initWithUTF8String(theirs.toStringz);
        auto type = NSString.alloc().initWithUTF8String("public.utf8-plain-text");
        pasteboard.clearContents();
        assert(pasteboard.setString(text, type), "writing the pasteboard failed");
    }

    OfferId offer;
    bool ownWithdrawn;
    const deadline = MonoTime.currTime + 5.seconds;
    while (offer == OfferId.init)
    {
        assert(MonoTime.currTime < deadline, "the foreign offer was never announced");
        hooks.step(50.msecs);
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in DataOfferEvent e) {
                    if (e.action == DataOfferAction.withdrawn)
                    {
                        assert(e.offer == own, "only an own offer is withdrawn");
                        ownWithdrawn = true;
                        return;
                    }
                    assert(e.offer != own, "the replaced offer was announced again");
                    assert(!wsi.withText(e.mimeType, (scope const(char)[] mime) {
                        if (mime == "text/plain;charset=utf-8")
                            offer = e.offer;
                    }).hasError);
                },
                (_) {});
        }).hasError);
    }
    assert(ownWithdrawn, "the replaced own offer was not reported withdrawn");
    PatternSink late;
    assert(wsi.receive(own, "text/plain;charset=utf-8", late).error.kind
        == WsiErrorKind.staleId, "a replaced own offer was still readable");

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
        hooks.step(50.msecs);
    }
    assert(paste.ok && paste.text[0 .. paste.length] == theirs,
        "another writer's text did not arrive intact");
    assert(!wsi.destroyWindow(id).hasError);
    writeln("ok: AppKit reads another writer's pasteboard");
}

/// AppKit-only addendum: the NSTextInputClient marked-text contract on a
/// fresh window, driven exactly as the input context drives it.
private void checkMarkedText(ref AppKitWsi wsi)
{
    WindowConfig config;
    assert(config.title.assign("sparkles:wsi AppKit text"));
    config.logicalSize = LogicalSize(320, 200);
    const id = wsi.createWindow(config).value;
    ulong lastSequence;
    bool ready;
    auto readyDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        if (event.window == id)
            event.payload.match!((in ReadyEvent _) { ready = true; },
                (_) {});
    });
    assert(!readyDrain.hasError && ready);
    auto view = wsi.nativeHandles(id).value.window.match!(
        (in AppKitWindowHandle handle) => cast(NSView) handle.view,
        (_) => cast(NSView) null);
    assert(view !is null);

    // Event text is read through the WSI while the drain delivers it (`ED8`).
    bool textIs(TextId id, string expected)
    {
        bool same;
        assert(!wsi.withText(id, (scope const(char)[] text) {
            same = text == expected;
        }).hasError);
        return same;
    }

    // Composition: three kana with the middle one selected — UTF-16 units
    // in, byte offsets out.
    auto kana = NSString.alloc().initWithUTF8String("にほん");
    view.setMarkedText(kana, NSRange(1, 1), NSRange(long.max, 0));
    assert(view.hasMarkedText());
    bool sawComposition;
    auto compositionDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in CompositionEvent composition) {
                assert(textIs(composition.preedit, "にほん"));
                assert(composition.cursor == 3);
                assert(composition.selectionStart == 3
                    && composition.selectionLength == 3);
                assert(composition.segmentCount == 2);
                sawComposition = true;
            },
            (_) {});
    });
    assert(!compositionDrain.hasError && sawComposition);

    // The commit replaces the marked text: committed bytes, then exactly
    // one empty composition-ended event.
    auto nihon = NSString.alloc().initWithUTF8String("日本");
    view.insertText(nihon, NSRange(long.max, 0));
    assert(!view.hasMarkedText());
    bool sawCommit;
    bool sawEnd;
    auto commitDrain = wsi.drain((WindowEvent event) {
        assert(event.sequence > lastSequence);
        lastSequence = event.sequence;
        event.payload.match!(
            (in TextCommittedEvent text) {
                assert(textIs(text.text, "日本"));
                sawCommit = true;
            },
            (in CompositionEvent composition) {
                assert(composition.preedit == TextId.init);
                sawEnd = true;
            },
            (_) {});
    });
    assert(!commitDrain.hasError && sawCommit && sawEnd);

    // unmarkText with nothing marked stays silent.
    view.unmarkText();
    auto quietDrain = wsi.drain((WindowEvent event) {
        assert(event.payload.match!(
            (in CompositionEvent _) => false, (_) => true),
            "unmarkText with no marked text emitted a composition");
    });
    assert(!quietDrain.hasError);
    assert(!wsi.destroyWindow(id).hasError);
}
