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

extern (D):

private struct AppKitHooks
{
    AppKitWsi* wsi;
    DefaultLoop* loop;
    NSWindow nativeWindow;

    enum uint chordShiftCode = 0x38; // kVK_Shift
    enum uint chordKeyCode = 0x00; // kVK_ANSI_A
    enum bool resizeExact = false; // physical size scales with the backing

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
        void post(ulong type, ulong flags, NSString characters,
            ushort keyCode)
        {
            auto event = NSEvent.keyEventWithType(type, NSPoint(0, 0), flags,
                0, number, null, characters, characters, false, keyCode);
            assert(event !is null);
            application.postEvent(event, false);
        }

        post(flagsChangedType, shiftFlag, lower, chordShiftCode);
        post(keyDownType, shiftFlag, upper, chordKeyCode);
        post(keyUpType, shiftFlag, upper, chordKeyCode);
        post(flagsChangedType, 0, lower, chordShiftCode);
    }
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
