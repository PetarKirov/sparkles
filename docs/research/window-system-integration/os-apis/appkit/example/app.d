// Minimal macOS/AppKit window — the irreducible Cocoa sequence GLFW/SDL/winit wrap
// on macOS: [NSApplication sharedApplication] -> [NSWindow initWithContentRect:…]
// -> makeKeyAndOrderFront: -> [NSApp run]. Objective-C is reached through D's
// built-in `extern(Objective-C)` + `@selector` interop, with the `objective-d`
// package providing the Objective-C runtime linkage and the scoped autorelease
// pool. AppKit classes are hand-declared (objective-d bundles Foundation, not
// AppKit). See ../index.md (the macOS/AppKit OS-API survey).
//
// Headless-safe: an SSH/headless session has no window server, so `CGMainDisplayID`
// returns 0 — we print `SKIP:` and exit 0 (creating an NSWindow without a window
// server is undefined). With a logged-in session it creates and shows a real
// window. Bounded: we create + order-front + return rather than block in
// `[NSApp run]` (a real app loops there — noted below) so CI never hangs.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d

// CoreGraphics (linked transitively by Cocoa): 0 when there is no window server.
extern (C) uint CGMainDisplayID() nothrow @nogc;

// Cocoa geometry (CGFloat == double on 64-bit). Plain C structs, not ObjC objects.
extern (C) struct NSPoint
{
    double x, y;
}

extern (C) struct NSSize
{
    double width, height;
}

extern (C) struct NSRect
{
    NSPoint origin;
    NSSize size;
}

extern (Objective-C):

extern class NSObject
{
    // `alloc` is declared on the leaf classes that need it (with their own return
    // type) to avoid an Objective-C covariant-return clash on the base method.
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
}

extern class NSResponder : NSObject
{
}

extern class NSApplication : NSResponder
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    void run() @selector("run");
}

extern class NSWindow : NSResponder
{
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
}

extern (D): // back to D linkage for the rest of the module

enum NSApplicationActivationPolicyRegular = 0;
enum : ulong
{
    NSWindowStyleMaskTitled = 1,
    NSWindowStyleMaskClosable = 2,
    NSWindowStyleMaskResizable = 8,
}

enum ulong NSBackingStoreBuffered = 2;

int main()
{
    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    // objective-d's autorelease pool wraps the AppKit object creation.
    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    // 1. The shared application object (connects to the WindowServer).
    NSApplication app = NSApplication.sharedApplication();
    app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    // 2. Create a titled, closable, resizable window with a buffered backing store.
    NSRect frame = NSRect(NSPoint(120, 120), NSSize(480, 320));
    NSWindow win = NSWindow.alloc().initWithContentRect(frame,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    win.setTitle(NSString.alloc().initWithUTF8String("Sparkles · macOS (AppKit)"));

    // 3. Order it front and activate. A real app would now block in `app.run()`;
    //    we return so CI is bounded.
    win.makeKeyAndOrderFront(null);
    app.activateIgnoringOtherApps(true);
    printf("ok: created and showed an NSWindow (a real app would call [NSApp run])\n");
    return 0;
}
