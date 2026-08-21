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
    return 0;
}
