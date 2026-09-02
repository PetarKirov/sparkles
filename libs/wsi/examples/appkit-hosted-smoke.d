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
}

private extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* text)
        @selector("initWithUTF8String:");
}

private extern class NSEvent : NSObject
{
    static NSEvent mouseEventWithType(ulong type, NSPoint location,
        ulong modifierFlags, double timestamp, long windowNumber,
        NSObject context, long eventNumber, long clickCount, float pressure)
        @selector("mouseEventWithType:location:modifierFlags:timestamp:"
            ~ "windowNumber:context:eventNumber:clickCount:pressure:");
    static NSEvent keyEventWithType(ulong type, NSPoint location,
        ulong modifierFlags, double timestamp, long windowNumber,
        NSObject context, NSString characters,
        NSString charactersIgnoringModifiers, bool isARepeat, ushort keyCode)
        @selector("keyEventWithType:location:modifierFlags:timestamp:"
            ~ "windowNumber:context:characters:charactersIgnoringModifiers:"
            ~ "isARepeat:keyCode:");
}

private extern class NSApplication : NSObject
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void postEvent(NSEvent event, bool atStart) @selector("postEvent:atStart:");
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

extern (D):

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
    return 0;
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
                assert(composition.preedit[] == "にほん");
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
                assert(text.text[] == "日本");
                sawCommit = true;
            },
            (in CompositionEvent composition) {
                assert(composition.preedit.empty);
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
