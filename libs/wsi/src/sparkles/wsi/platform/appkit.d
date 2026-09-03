/**
Native AppKit lifecycle and Event Horizon host adapter.

AppKit owns the main thread's CFRunLoop. Event Horizon's kqueue descriptor is
wrapped in a `CFFileDescriptor` source, so Cocoa sources, kqueue I/O, timers,
and the cross-thread waker share one run-loop wait. Native callbacks append
owned WSI events; application code runs only when the caller drains them.
*/
module sparkles.wsi.platform.appkit;

version (OSX):

import core.attribute : selector;

import sparkles.base.buffer : InlineBuffer;
import sparkles.base.text.cstring : toTempStringz;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.input.events : KeyAction, Mods, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr,
    ioOk;
import sparkles.wsi.events;
import sparkles.wsi.handles;
import sparkles.wsi.loop : EventQueue;
import sparkles.wsi.types;

// CoreFoundation's public C surface. These opaque values are owned according
// to the Create Rule and released explicitly by `AppKitWsi.close`.
private alias CFRunLoopRef = void*;
private alias CFRunLoopSourceRef = void*;
private alias CFFileDescriptorRef = void*;
private alias CFStringRef = void*;
private alias CFAllocatorRef = void*;
private alias CFIndex = long;
private alias CFOptionFlags = ulong;

private extern (C) struct CFRunLoopSourceContext
{
    CFIndex version_;
    void* info;
    void* retain;
    void* release;
    void* copyDescription;
    void* equal;
    void* hash;
    void* schedule;
    void* cancel;
    void* perform;
}

private extern (C) struct CFFileDescriptorContext
{
    CFIndex version_;
    void* info;
    void* retain;
    void* release;
    void* copyDescription;
}

private extern (C) nothrow @nogc
{
    int pthread_main_np();
    void* objc_autoreleasePoolPush();
    void objc_autoreleasePoolPop(void* pool);

    CFRunLoopRef CFRunLoopGetCurrent();
    int CFRunLoopRunInMode(CFStringRef mode, double seconds,
        bool returnAfterSourceHandled);
    void CFRunLoopAddSource(CFRunLoopRef runLoop,
        CFRunLoopSourceRef source, CFStringRef mode);
    void CFRunLoopRemoveSource(CFRunLoopRef runLoop,
        CFRunLoopSourceRef source, CFStringRef mode);
    CFFileDescriptorRef CFFileDescriptorCreate(CFAllocatorRef allocator,
        int fd, bool closeOnInvalidate, void* callout,
        CFFileDescriptorContext* context);
    void CFFileDescriptorEnableCallBacks(CFFileDescriptorRef descriptor,
        CFOptionFlags callbackTypes);
    void CFFileDescriptorInvalidate(CFFileDescriptorRef descriptor);
    CFRunLoopSourceRef CFFileDescriptorCreateRunLoopSource(
        CFAllocatorRef allocator, CFFileDescriptorRef descriptor,
        CFIndex order);
    void CFRelease(void* value);

    extern __gshared CFStringRef kCFRunLoopDefaultMode;
    extern __gshared CFStringRef kCFRunLoopCommonModes;
}

private enum CFOptionFlags kCFFileDescriptorReadCallBack = 1;
private enum int kCFRunLoopRunHandledSource = 4;

// CGFloat is double on every macOS architecture supported by this package.
private extern (C) struct NSPoint
{
    double x;
    double y;
}

private extern (C) struct NSSize
{
    double width;
    double height;
}

private extern (C) struct NSRect
{
    NSPoint origin;
    NSSize size;
}

private extern (C) struct NSRange
{
    ulong location;
    ulong length;
}

/// AppKit's NSNotFound (NSIntegerMax) for "no range".
private enum ulong nsNotFound = long.max;

// The Objective-C runtime calls that register NSTextInputClient conformance
// on the D-defined view class: NSView's `inputContext` is non-nil only for
// views whose class adopts the protocol, and D's extern(Objective-C) has no
// protocol-adoption syntax.
private extern (C) nothrow @nogc
{
    void* objc_getProtocol(const(char)* name);
    void* object_getClass(void* object);
    byte class_addProtocol(void* cls, void* protocol);
    void* sel_registerName(const(char)* name);
}

extern (Objective-C):

private extern class NSObject
{
    void release() @selector("release");
}

private extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* text)
        @selector("initWithUTF8String:");
    const(char)* UTF8String() @selector("UTF8String");
    // The insertText:/setMarkedText: payload is typed NSString here but is
    // NSAttributedString when an IME composes; only the attributed one
    // answers `string`, and dispatch is by instance, not static type.
    bool respondsToSelector(void* selector)
        @selector("respondsToSelector:");
    NSString stringValue() @selector("string");
}

private extern class NSArray : NSObject
{
    static NSArray array() @selector("array");
}

private extern class NSDate : NSObject
{
    static NSDate distantPast() @selector("distantPast");
}

private extern class NSEvent : NSObject
{
    ulong type() @selector("type");
    ushort keyCode() @selector("keyCode");
    ulong modifierFlags() @selector("modifierFlags");
    bool isARepeat() @selector("isARepeat");
    NSString charactersIgnoringModifiers()
        @selector("charactersIgnoringModifiers");
    NSPoint locationInWindow() @selector("locationInWindow");
    long buttonNumber() @selector("buttonNumber");
    double scrollingDeltaX() @selector("scrollingDeltaX");
    double scrollingDeltaY() @selector("scrollingDeltaY");
    bool hasPreciseScrollingDeltas()
        @selector("hasPreciseScrollingDeltas");
    bool isDirectionInvertedFromDevice()
        @selector("isDirectionInvertedFromDevice");
}

private extern class NSResponder : NSObject
{
}

private extern class NSCursor : NSObject
{
    static NSCursor arrowCursor() @selector("arrowCursor");
    static NSCursor IBeamCursor() @selector("IBeamCursor");
    static NSCursor pointingHandCursor() @selector("pointingHandCursor");
    static NSCursor resizeLeftRightCursor()
        @selector("resizeLeftRightCursor");
    static NSCursor resizeUpDownCursor() @selector("resizeUpDownCursor");
    static NSCursor openHandCursor() @selector("openHandCursor");
    static NSCursor closedHandCursor() @selector("closedHandCursor");
    static NSCursor currentCursor() @selector("currentCursor");
    static void hide() @selector("hide");
    static void unhide() @selector("unhide");
    void set() @selector("set");
}

private extern class NSApplication : NSResponder
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    NSEvent nextEventMatchingMask(ulong mask, NSDate untilDate,
        NSString mode, bool dequeue)
        @selector("nextEventMatchingMask:untilDate:inMode:dequeue:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
    void updateWindows() @selector("updateWindows");
}

private extern class NSView : NSResponder
{
    NSRect bounds() @selector("bounds");
    NSPoint convertPoint(NSPoint point, NSView view)
        @selector("convertPoint:fromView:");
    void setFrameSize(NSSize size) @selector("setFrameSize:");
    void setNeedsDisplay(bool value) @selector("setNeedsDisplay:");
    NSTextInputContext inputContext() @selector("inputContext");
}

private extern class NSTextInputContext : NSObject
{
    bool handleEvent(NSEvent event) @selector("handleEvent:");
    void discardMarkedText() @selector("discardMarkedText");
}


private extern class NSWindow : NSResponder
{
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSView view) @selector("setContentView:");
    void setDelegate(NSObject delegate_) @selector("setDelegate:");
    void setReleasedWhenClosed(bool value)
        @selector("setReleasedWhenClosed:");
    void center()
        @selector("center");
    void makeKeyAndOrderFront(NSObject sender)
        @selector("makeKeyAndOrderFront:");
    bool makeFirstResponder(NSResponder responder)
        @selector("makeFirstResponder:");
    void setAcceptsMouseMovedEvents(bool value)
        @selector("setAcceptsMouseMovedEvents:");
    void orderOut(NSObject sender) @selector("orderOut:");
    void close() @selector("close");
    double backingScaleFactor() @selector("backingScaleFactor");
}

/** Private NSView subclass forwarding only lossless native observations. */
/// UTF-8 view of an insertText/setMarkedText payload (NSString, or
/// NSAttributedString unwrapped through `string`); empty when absent.
/// (`extern (D)`: the module-wide Objective-C linkage label reaches here.)
private extern (D) const(char)[] payloadUtf8(NSString text)
{
    import core.stdc.string : strlen;

    if (text is null)
        return null;
    auto resolved = text.respondsToSelector(sel_registerName("string"))
        ? text.stringValue() : text;
    if (resolved is null)
        return null;
    auto utf8 = resolved.UTF8String();
    return utf8 is null ? null : utf8[0 .. strlen(utf8)];
}

private class SparklesWsiView : NSView
{
    static SparklesWsiView alloc() @selector("alloc");
    SparklesWsiView initWithFrame(NSRect frame) @selector("initWithFrame:");

    override void setFrameSize(NSSize size) @selector("setFrameSize:")
    {
        super.setFrameSize(size);
        if (activeOwner !is null)
            activeOwner.onViewMetrics(this);
    }

    void drawRect(NSRect dirty) @selector("drawRect:")
    {
        if (activeOwner !is null)
            activeOwner.onViewDraw(this);
    }

    bool acceptsFirstResponder() @selector("acceptsFirstResponder")
        => true;

    // Deliver the activating click too; without this an inactive window
    // swallows the first mouseDown as click-through activation.
    bool acceptsFirstMouse(NSEvent event) @selector("acceptsFirstMouse:")
        => true;

    // --- NSTextInputClient (adopted at view creation via class_addProtocol)

    void insertText(NSString text, NSRange replacementRange)
        @selector("insertText:replacementRange:")
    {
        if (activeOwner !is null)
            activeOwner.onInsertText(this, payloadUtf8(text));
    }

    void setMarkedText(NSString text, NSRange selectedRange,
        NSRange replacementRange)
        @selector("setMarkedText:selectedRange:replacementRange:")
    {
        if (activeOwner !is null)
            activeOwner.onSetMarkedText(this, payloadUtf8(text),
                selectedRange);
    }

    void unmarkText() @selector("unmarkText")
    {
        if (activeOwner !is null)
            activeOwner.onUnmarkText(this);
    }

    bool hasMarkedText() @selector("hasMarkedText")
        => activeOwner !is null && activeOwner.markedUtf16Length(this) != 0;

    NSRange markedRange() @selector("markedRange")
    {
        const units = activeOwner is null
            ? 0 : activeOwner.markedUtf16Length(this);
        return units == 0 ? NSRange(nsNotFound, 0) : NSRange(0, units);
    }

    NSRange selectedRange() @selector("selectedRange")
        => NSRange(nsNotFound, 0);

    NSString attributedSubstringForProposedRange(NSRange range,
        NSRange* actual)
        @selector("attributedSubstringForProposedRange:actualRange:")
        => null;

    // Candidate-window placement is a later refinement (F07 remaining);
    // a zero rect keeps the protocol total.
    NSRect firstRectForCharacterRange(NSRange range, NSRange* actual)
        @selector("firstRectForCharacterRange:actualRange:")
        => NSRect(NSPoint(0, 0), NSSize(0, 0));

    ulong characterIndexForPoint(NSPoint point)
        @selector("characterIndexForPoint:")
        => nsNotFound;

    // Required by the protocol; no attributed pre-edit styling is consumed.
    NSArray validAttributesForMarkedText()
        @selector("validAttributesForMarkedText")
        => NSArray.array();

    // Non-text keys (arrows, return, escape) surface here during
    // interpretation; they are already delivered as physical keys.
    void doCommandBySelector(void* selector)
        @selector("doCommandBySelector:")
    {
    }

    void keyDown(NSEvent event) @selector("keyDown:")
    {
        if (activeOwner !is null)
            activeOwner.onKey(this, event, true);
        // Text arrives through the NSTextInputClient protocol, never from
        // raw keys: route the event to the input context (non-nil once the
        // class adopted the protocol), which calls insertText/setMarkedText
        // back on this view — for an IME and for plain typing alike.
        auto context = this.inputContext();
        if (context !is null)
            context.handleEvent(event);
    }

    void keyUp(NSEvent event) @selector("keyUp:")
    {
        if (activeOwner !is null)
            activeOwner.onKey(this, event, false);
    }

    void flagsChanged(NSEvent event) @selector("flagsChanged:")
    {
        if (activeOwner !is null)
            activeOwner.onFlagsChanged(this, event);
    }

    void mouseDown(NSEvent event) @selector("mouseDown:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.pressed);
    }

    void mouseUp(NSEvent event) @selector("mouseUp:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.released);
    }

    void rightMouseDown(NSEvent event) @selector("rightMouseDown:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.pressed);
    }

    void rightMouseUp(NSEvent event) @selector("rightMouseUp:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.released);
    }

    void otherMouseDown(NSEvent event) @selector("otherMouseDown:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.pressed);
    }

    void otherMouseUp(NSEvent event) @selector("otherMouseUp:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.released);
    }

    void mouseMoved(NSEvent event) @selector("mouseMoved:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.moved);
    }

    void mouseDragged(NSEvent event) @selector("mouseDragged:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.moved);
    }

    void mouseEntered(NSEvent event) @selector("mouseEntered:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.entered);
    }

    void mouseExited(NSEvent event) @selector("mouseExited:")
    {
        if (activeOwner !is null)
            activeOwner.onMouse(this, event, PointerPhase.left);
    }

    void scrollWheel(NSEvent event) @selector("scrollWheel:")
    {
        if (activeOwner !is null)
            activeOwner.onScrollWheel(this, event);
    }
}

/** Private NSWindow subclass serving as its own delegate. */
private class SparklesWsiWindow : NSWindow
{
    static SparklesWsiWindow alloc() @selector("alloc");
    override SparklesWsiWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer_)
        @selector("initWithContentRect:styleMask:backing:defer:");

    bool windowShouldClose(NSObject sender) @selector("windowShouldClose:")
    {
        if (activeOwner !is null)
            activeOwner.onCloseRequest(this);
        return false;
    }

    void windowDidResize(NSObject notification) @selector("windowDidResize:")
    {
        if (activeOwner !is null)
            activeOwner.onWindowMetrics(this);
    }

    void windowDidChangeBackingProperties(NSObject notification)
        @selector("windowDidChangeBackingProperties:")
    {
        if (activeOwner !is null)
            activeOwner.onWindowMetrics(this);
    }

    void windowDidBecomeKey(NSObject notification)
        @selector("windowDidBecomeKey:")
    {
        if (activeOwner !is null)
            activeOwner.onFocus(this, true);
    }

    void windowDidResignKey(NSObject notification)
        @selector("windowDidResignKey:")
    {
        if (activeOwner !is null)
            activeOwner.onFocus(this, false);
    }
}

extern (D):

private enum long NSApplicationActivationPolicyRegular = 0;
private enum long NSApplicationActivationPolicyAccessory = 1;
private enum ulong NSWindowStyleMaskTitled = 1;
private enum ulong NSWindowStyleMaskClosable = 2;
private enum ulong NSWindowStyleMaskMiniaturizable = 4;
private enum ulong NSWindowStyleMaskResizable = 8;
private enum ulong NSBackingStoreBuffered = 2;

// AppKit is main-thread-only: every native callback and owner call runs on
// the main thread, so plain TLS is the correct storage for the pin.
private AppKitWsi* activeOwner;

/**
One process-main-thread AppKit WSI owner.

Only one owner may be open because AppKit itself exposes one shared application
and the D-defined delegate classes route through one process-global owner. The
owner is address-pinned for that same reason.
*/
struct AppKitWsi
{
    enum maxWindows = 16;
    enum maxEvents = 128;

    @disable this(this);

    private struct Slot
    {
        SparklesWsiWindow window;
        SparklesWsiView view;
        uint generation;
        bool live;
        bool ready;
        SurfaceMetrics metrics;
        InlineBuffer!(char, 512) marked;
        ulong markedUnits16;
    }

    private NSApplication application_;
    private Slot[maxWindows] windows_;
    private EventQueue!maxEvents events_;
    private ulong nextSequence_ = 1;
    private bool open_;
    private bool closed_;
    private bool hasStickyError_;
    private WsiError stickyError_;

    // Event Horizon kqueue → CFRunLoop bridge.
    private int bridgedKqueue_ = -1;
    private CFRunLoopRef runLoop_;
    private CFFileDescriptorRef kqueueDescriptor_;
    private CFRunLoopSourceRef kqueueSource_;
    private bool completionReady_;

    /** Opens the AppKit adapter on the process main thread. */
    static WsiResult!void open(out AppKitWsi wsi,
        in WsiConfig config = WsiConfig.init)
    {
        if (pthread_main_np() == 0)
            return appKitFailure!void(WsiOperation.open, 0,
                "AppKit WSI must open on the process main thread",
                WsiErrorKind.wrongThread);
        if (activeOwner !is null)
            return appKitFailure!void(WsiOperation.open, 0,
                "an AppKit WSI owner is already open",
                WsiErrorKind.unavailable);

        auto pool = objc_autoreleasePoolPush();
        scope (exit) objc_autoreleasePoolPop(pool);
        wsi.application_ = NSApplication.sharedApplication();
        if (wsi.application_ is null)
            return appKitFailure!void(WsiOperation.open, 0,
                "NSApplication.sharedApplication returned nil");
        // Regular by default: a process that opens a window is an application,
        // and an accessory one cannot be brought frontmost by the user. A host
        // that really is an accessory — a panel beside a terminal session —
        // says so in its `WsiConfig`.
        wsi.application_.setActivationPolicy(
            config.activation == ActivationPolicy.accessory
                ? NSApplicationActivationPolicyAccessory
                : NSApplicationActivationPolicyRegular);
        wsi.runLoop_ = CFRunLoopGetCurrent();
        if (wsi.runLoop_ is null)
            return appKitFailure!void(WsiOperation.open, 0,
                "CFRunLoopGetCurrent returned null");

        wsi.open_ = true;
        activeOwner = &wsi;
        return wsiOk();
    }

    /** Creates a native NSWindow and emits ready before its first draw. */
    WsiResult!WindowId createWindow(in WindowConfig config)
    {
        auto owner = requireOwner!WindowId(WsiOperation.createWindow);
        if (owner.hasError)
            return owner;
        if (closed_)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "WSI is closed", WsiErrorKind.closed);
        if (auto fault = config.fault)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                fault, WsiErrorKind.invalidArgument);
        if (config.transparent
            || config.state != WindowStartupState.normal)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "requested AppKit startup configuration is not implemented",
                WsiErrorKind.unsupported);
        if (config.parent.valid)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "AppKit parent windows are not implemented",
                WsiErrorKind.unsupported);

        size_t index = size_t.max;
        foreach (i, ref slot; windows_)
            if (!slot.live && slot.window is null)
            {
                index = i;
                break;
            }
        if (index == size_t.max)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "AppKit window capacity reached", WsiErrorKind.capacity);

        auto pool = objc_autoreleasePoolPush();
        scope (exit) objc_autoreleasePoolPop(pool);

        ulong style = config.decorations == DecorationPreference.none
            ? 0 : NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                | NSWindowStyleMaskMiniaturizable;
        if (config.resizable && config.decorations != DecorationPreference.none)
            style |= NSWindowStyleMaskResizable;
        // The origin is a placeholder: `center` below is what places the
        // window, so a second one does not land exactly on top of the first and
        // a screen smaller than 120 points of inset still shows the title bar.
        const rect = NSRect(NSPoint(0, 0),
            NSSize(config.logicalSize.width, config.logicalSize.height));

        auto window = SparklesWsiWindow.alloc();
        if (window is null)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "SparklesWsiWindow.alloc returned nil");
        window = window.initWithContentRect(rect,
            style, NSBackingStoreBuffered, false);
        if (window is null)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "NSWindow initialization failed");

        auto view = SparklesWsiView.alloc().initWithFrame(rect);
        adoptTextInputProtocol(view);
        if (view is null)
        {
            window.release();
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "NSView initialization failed");
        }

        ref slot = windows_[index];
        ++slot.generation;
        if (slot.generation == 0)
            ++slot.generation;
        slot.window = window;
        slot.view = view;
        slot.live = true;
        slot.ready = false;

        // Terminated at the seam. The array this used to copy into was one byte
        // wider than `WindowConfig.title`'s inline capacity — a coincidence, not
        // a guarantee, and widening the title by one would have had
        // `initWithUTF8String` read past the end.
        auto nativeTitle = NSString.alloc()
            .initWithUTF8String(config.title[].toTempStringz.ptr);
        if (nativeTitle is null)
        {
            destroySlot(index, false);
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "NSString title conversion failed");
        }
        window.setTitle(nativeTitle);
        nativeTitle.release();
        window.center();
        window.setReleasedWhenClosed(false);
        window.setContentView(view);
        window.setDelegate(window);

        slot.metrics = metricsOf(slot);
        slot.ready = true;
        auto id = idAt(index);
        const hadSticky = hasStickyError_;
        emit(id, ReadyEvent(slot.metrics));
        if (!hadSticky && hasStickyError_)
        {
            destroySlot(index, false);
            return wsiErr!WindowId(stickyError_);
        }

        if (config.visible)
            window.makeKeyAndOrderFront(null);
        // NSView refuses first-responder status by default; without it the
        // responder chain never delivers keyDown/keyUp to the view.
        window.makeFirstResponder(view);
        window.setAcceptsMouseMovedEvents(true);
        view.setNeedsDisplay(true);
        return wsiOk(id);
    }

    WsiResult!void destroyWindow(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.close);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        destroySlot(checked.value, true);
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
    }

    WsiResult!NativeHandles nativeHandles(WindowId id)
    {
        auto checked = checkedSlot(id, WsiOperation.queryHandle);
        if (checked.hasError)
            return wsiErr!NativeHandles(checked.error);
        ref slot = windows_[checked.value];

        NativeHandles handles;
        handles.display = DisplayHandle(AppKitDisplayHandle(
            cast(void*) application_));
        handles.window = WindowHandle(AppKitWindowHandle(
            cast(void*) slot.window, cast(void*) slot.view));
        return wsiOk(handles);
    }

    /** Drains AppKit's queued NSEvents without blocking. */
    WsiResult!size_t pumpEvents()
    {
        auto owner = requireOwner!size_t(WsiOperation.dispatch);
        if (owner.hasError)
            return owner;

        auto pool = objc_autoreleasePoolPush();
        scope (exit) objc_autoreleasePoolPop(pool);
        size_t count;
        for (;;)
        {
            auto event = application_.nextEventMatchingMask(ulong.max,
                NSDate.distantPast(),
                cast(NSString) kCFRunLoopDefaultMode, true);
            if (event is null)
                break;
            application_.sendEvent(event);
            ++count;
        }
        if (count != 0)
            application_.updateWindows();
        if (hasStickyError_)
            return wsiErr!size_t(stickyError_);
        return wsiOk(count);
    }

    /** Event Horizon native-host concept: non-blocking native dispatch. */
    bool dispatchPending()
    {
        auto pumped = pumpEvents();
        return pumped.hasValue && pumped.value != 0;
    }

    /**
    Event Horizon native-host concept: one CFRunLoop wait.

    `completionHandle` is the kqueue descriptor encoded as an opaque token by
    Event Horizon. CFFileDescriptor folds it into AppKit's main run loop.
    */
    IoResult!bool wait(void* completionHandle, uint timeoutMilliseconds)
    {
        if (pthread_main_np() == 0)
            return ioErr!bool(0, OpKind.none, IoErrorStage.completion,
                "AppKit wait called off the process main thread");
        const descriptor = cast(int) cast(size_t) completionHandle;
        if (!installKqueueBridge(descriptor))
            return ioErr!bool(0, OpKind.none, IoErrorStage.completion,
                "CFFileDescriptor kqueue bridge creation failed");

        completionReady_ = false;
        CFFileDescriptorEnableCallBacks(kqueueDescriptor_,
            kCFFileDescriptorReadCallBack);
        const seconds = timeoutMilliseconds == uint.max
            ? 1.0e20 : cast(double) timeoutMilliseconds / 1000.0;
        const result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds,
            true);
        return ioOk(completionReady_
            || result == kCFRunLoopRunHandledSource);
    }

    WsiResult!size_t drain(Sink)(scope Sink sink) => events_.drain(sink);

    size_t pendingEvents() const pure nothrow @nogc => events_.length;

    /** Closes every native window and removes the kqueue run-loop source. */
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
        foreach (i; 0 .. windows_.length)
            if (windows_[i].window !is null)
                destroySlot(i, windows_[i].live);
        removeKqueueBridge();
        if (cursorHidden_)
        {
            NSCursor.unhide();
            cursorHidden_ = false;
        }
        closed_ = true;
        open_ = false;
        if (activeOwner is &this)
            activeOwner = null;
    }

    ~this()
    {
        closeNow();
    }

    private WsiResult!size_t checkedSlot(WindowId id,
        WsiOperation operation)
    {
        auto owner = requireOwner!size_t(operation);
        if (owner.hasError)
            return owner;
        if (!id.valid || id.slot > maxWindows)
            return appKitFailure!size_t(operation, 0,
                "invalid AppKit window id", WsiErrorKind.staleId);
        size_t index = cast(size_t) id.slot - 1;
        const slot = windows_[index];
        if (!slot.live || slot.generation != id.generation)
            return appKitFailure!size_t(operation, 0,
                "stale AppKit window id", WsiErrorKind.staleId);
        return wsiOk(index);
    }

    private WsiResult!T requireOwner(T)(WsiOperation operation)
    {
        if (!open_ && !closed_)
            return appKitFailure!T(operation, 0,
                "AppKit WSI is not open", WsiErrorKind.closed);
        if (pthread_main_np() == 0)
            return appKitFailure!T(operation, 0,
                "AppKit WSI called from a non-main thread",
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
        auto result = events_.push(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload)));
        if (result.hasError)
        {
            remember(result.error);
            return;
        }
        ++nextSequence_;
    }

    private void remember(WsiError error) nothrow
    {
        if (!hasStickyError_)
        {
            error.backend = BackendKind.appkit;
            stickyError_ = error;
            hasStickyError_ = true;
        }
    }

    private WindowId idAt(size_t index) const pure nothrow @nogc
        => WindowId(cast(uint) index + 1, windows_[index].generation);

    private size_t indexOfWindow(SparklesWsiWindow window) const
        pure nothrow @nogc
    {
        foreach (i, const ref slot; windows_)
            if (slot.live && slot.window is window)
                return i;
        return size_t.max;
    }

    private size_t indexOfView(SparklesWsiView view) const
        pure nothrow @nogc
    {
        foreach (i, const ref slot; windows_)
            if (slot.live && slot.view is view)
                return i;
        return size_t.max;
    }

    private static SurfaceMetrics metricsOf(ref Slot slot)
    {
        const bounds = slot.view.bounds();
        double scale = slot.window.backingScaleFactor();
        if (scale <= 0)
            scale = 1;
        const width = bounds.size.width > 0 ? bounds.size.width : 0;
        const height = bounds.size.height > 0 ? bounds.size.height : 0;
        return SurfaceMetrics(LogicalSize(width, height),
            PhysicalSize(cast(uint)(width * scale + 0.5),
                cast(uint)(height * scale + 0.5)),
            ScaleFactor(scale));
    }

    private void onViewMetrics(SparklesWsiView view)
    {
        const index = indexOfView(view);
        if (index == size_t.max)
            return;
        updateMetrics(index);
    }

    private void onWindowMetrics(SparklesWsiWindow window)
    {
        const index = indexOfWindow(window);
        if (index == size_t.max)
            return;
        updateMetrics(index);
    }

    private void updateMetrics(size_t index)
    {
        ref slot = windows_[index];
        const metrics = metricsOf(slot);
        if (slot.ready && metrics != slot.metrics)
            emit(idAt(index),
                SurfaceMetricsChangedEvent(metrics));
        slot.metrics = metrics;
    }

    private void onInsertText(SparklesWsiView view, scope const(char)[] bytes)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        ref slot = windows_[index];
        const id = idAt(index);
        if (bytes.length != 0 && !validateUtf8(bytes).hasError)
        {
            TextCommittedEvent committed;
            // An oversized commit degrades to none rather than to a cut
            // multi-byte sequence.
            if (committed.text.assign(bytes))
                emit(id, committed);
        }
        // insertText replaces any marked text: the composition is over.
        if (!slot.marked.empty)
        {
            slot.marked.clear();
            slot.markedUnits16 = 0;
            emit(id, CompositionEvent());
        }
    }

    private void onSetMarkedText(SparklesWsiView view,
        scope const(char)[] bytes, NSRange selectedRange)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        ref slot = windows_[index];
        const id = idAt(index);
        if (bytes.length == 0 || validateUtf8(bytes).hasError)
        {
            onUnmarkText(view);
            return;
        }
        if (!slot.marked.assign(bytes))
        {
            onUnmarkText(view);
            return;
        }
        slot.markedUnits16 = utf16Length(bytes);
        emit(id, appKitComposition(bytes, selectedRange.location,
            selectedRange.length));
    }

    private void onUnmarkText(SparklesWsiView view)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        ref slot = windows_[index];
        if (slot.marked.empty)
            return;
        slot.marked.clear();
        slot.markedUnits16 = 0;
        emit(idAt(index), CompositionEvent());
    }

    private ulong markedUtf16Length(SparklesWsiView view)
    {
        const index = indexOfView(view);
        return index == size_t.max ? 0 : windows_[index].markedUnits16;
    }

    private void onKey(SparklesWsiView view, NSEvent event, bool pressed)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        KeyboardEvent keyboard;
        keyboard.physical = PhysicalKey(event.keyCode, 0);
        keyboard.logical = appKitLogical(event.charactersIgnoringModifiers());
        keyboard.location = appKitKeyLocation(event.keyCode);
        keyboard.action = pressed
            ? (event.isARepeat ? KeyAction.repeat : KeyAction.press)
            : KeyAction.release;
        keyboard.modifiers = appKitMods(event.modifierFlags);
        emit(idAt(index), keyboard);
    }

    /*
    Unshifted layout identity: charactersIgnoringModifiers is the layout's
    base spelling, and AppKit spells function keys as scalars in the Unicode
    private range 0xF700–0xF8FF (NSUpArrowFunctionKey and friends) — those
    are macOS's named identity.
    */
    private static LogicalKey appKitLogical(NSString text)
    {
        if (text is null)
            return LogicalKey.init;
        auto utf8 = text.UTF8String();
        if (utf8 is null)
            return LogicalKey.init;
        import core.stdc.string : strlen;

        const scalar = firstScalar(utf8[0 .. strlen(utf8)]);
        if (scalar >= 0xF700 && scalar <= 0xF8FF)
            return LogicalKey(LogicalKeyKind.named, dchar.init, scalar);
        if (scalar >= 0x20 && scalar != 0x7F)
            return LogicalKey(LogicalKeyKind.character, scalar, scalar);
        return LogicalKey.init;
    }

    /// First Unicode scalar of a UTF-8 string; `dchar.init` when empty or
    /// malformed.
    package static dchar firstScalar(scope const(char)[] text)
        @safe pure nothrow @nogc
    {
        if (text.length == 0)
            return dchar.init;
        const first = text[0];
        if (first < 0x80)
            return first;
        uint continuations;
        uint value;
        if ((first & 0xE0) == 0xC0)
        {
            continuations = 1;
            value = first & 0x1F;
        }
        else if ((first & 0xF0) == 0xE0)
        {
            continuations = 2;
            value = first & 0x0F;
        }
        else if ((first & 0xF8) == 0xF0)
        {
            continuations = 3;
            value = first & 0x07;
        }
        else
            return dchar.init;
        if (text.length < 1 + continuations)
            return dchar.init;
        foreach (i; 0 .. continuations)
        {
            const unit = text[1 + i];
            if ((unit & 0xC0) != 0x80)
                return dchar.init;
            value = (value << 6) | (unit & 0x3F);
        }
        return cast(dchar) value;
    }

    private bool cursorHidden_;

    /**
    Applies a standard cursor shape immediately. All seven shared shapes
    map to stock NSCursor instances; per-view cursor rectangles and custom
    images are a later slice.
    */
    WsiResult!void setCursor(WindowId id, PointerShape shape)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        appKitCursor(shape).set();
        return wsiOk();
    }

    /// NSCursor.hide/unhide is a balanced global counter, so the hidden
    /// state is tracked and only toggled on transitions.
    WsiResult!void setCursorVisible(WindowId id, bool visible)
    {
        auto checked = checkedSlot(id, WsiOperation.command);
        if (checked.hasError)
            return wsiErr!void(checked.error);
        if (visible == !cursorHidden_)
            return wsiOk();
        if (visible)
            NSCursor.unhide();
        else
            NSCursor.hide();
        cursorHidden_ = !visible;
        return wsiOk();
    }

    /// Every shared shape has a stock NSCursor.
    package static NSCursor appKitCursor(PointerShape shape)
    {
        final switch (shape)
        {
            case PointerShape.default_: return NSCursor.arrowCursor();
            case PointerShape.text: return NSCursor.IBeamCursor();
            case PointerShape.pointer:
                return NSCursor.pointingHandCursor();
            case PointerShape.ewResize:
                return NSCursor.resizeLeftRightCursor();
            case PointerShape.nsResize:
                return NSCursor.resizeUpDownCursor();
            case PointerShape.grab: return NSCursor.openHandCursor();
            case PointerShape.grabbing: return NSCursor.closedHandCursor();
        }
    }

    /// One pointer per NSApplication event stream.
    private enum viewPointer = PointerId(1, 1);

    /// Window coordinates are bottom-left; the toolkit contract is
    /// top-left, so the view's own coordinate space flips y.
    private LogicalPosition pointerPositionOf(ref Slot slot, NSEvent event)
    {
        const inView = slot.view.convertPoint(event.locationInWindow(), null);
        const bounds = slot.view.bounds();
        return LogicalPosition(inView.x, bounds.size.height - inView.y);
    }

    private void onMouse(SparklesWsiView view, NSEvent event,
        PointerPhase phase)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        ref slot = windows_[index];
        const at = pointerPositionOf(slot, event);
        double scale = slot.window.backingScaleFactor();
        if (scale <= 0)
            scale = 1;
        PointerEvent pointer;
        pointer.pointer = viewPointer;
        pointer.phase = phase;
        if (phase == PointerPhase.pressed || phase == PointerPhase.released)
            pointer.button = appKitPointerButton(event.buttonNumber());
        pointer.logicalPosition = at;
        pointer.physicalPosition = PhysicalPosition(
            cast(int)(at.x * scale + 0.5), cast(int)(at.y * scale + 0.5));
        pointer.modifiers = appKitMods(event.modifierFlags());
        emit(idAt(index), pointer);
    }

    // AppKit's scrollingDelta is positive when content moves down toward
    // natural scrolling; the shared convention is positive-down of the
    // viewport, so both axes flip sign.
    private void onScrollWheel(SparklesWsiView view, NSEvent event)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        ref slot = windows_[index];
        const at = pointerPositionOf(slot, event);
        double scale = slot.window.backingScaleFactor();
        if (scale <= 0)
            scale = 1;
        ScrollEvent scroll;
        scroll.logicalPosition = at;
        scroll.physicalPosition = PhysicalPosition(
            cast(int)(at.x * scale + 0.5), cast(int)(at.y * scale + 0.5));
        scroll.dx = -event.scrollingDeltaX();
        scroll.dy = -event.scrollingDeltaY();
        const precise = event.hasPreciseScrollingDeltas();
        if (!precise)
        {
            scroll.discreteX = cast(int) scroll.dx;
            scroll.discreteY = cast(int) scroll.dy;
        }
        scroll.source = precise ? ScrollSource.continuous : ScrollSource.wheel;
        scroll.unit = precise ? ScrollUnit.pixel : ScrollUnit.logical;
        scroll.inverted = event.isDirectionInvertedFromDevice();
        scroll.modifiers = appKitMods(event.modifierFlags());
        emit(idAt(index), scroll);
    }

    /// AppKit button numbers: 0/1/2 are left/right/middle, 3/4 the thumbs.
    package static PointerButton appKitPointerButton(long number)
        @safe pure nothrow @nogc
    {
        switch (number)
        {
            case 0: return PointerButton.left;
            case 1: return PointerButton.right;
            case 2: return PointerButton.middle;
            case 3: return PointerButton.back;
            case 4: return PointerButton.forward;
            default: return PointerButton.none;
        }
    }

    // Modifier keys never reach keyDown/keyUp; AppKit reports them through
    // flagsChanged, and press versus release is whether that key's flag is
    // set in the event's own modifier state.
    private void onFlagsChanged(SparklesWsiView view, NSEvent event)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        const flag = appKitModifierFlagFor(event.keyCode);
        if (flag == 0)
            return;
        KeyboardEvent keyboard;
        keyboard.physical = PhysicalKey(event.keyCode, 0);
        keyboard.location = appKitKeyLocation(event.keyCode);
        keyboard.action = (event.modifierFlags & flag) != 0
            ? KeyAction.press : KeyAction.release;
        keyboard.modifiers = appKitMods(event.modifierFlags);
        emit(idAt(index), keyboard);
    }

    /*
    Carbon virtual keycodes are layout-independent hardware identity, the
    same level the Win32 scan-code and Linux evdev slices report. Location
    falls back to `standard` on unknown codes, never to a wrong pairing.
    */
    package static KeyLocation appKitKeyLocation(uint keyCode)
        @safe pure nothrow @nogc
    {
        switch (keyCode)
        {
            case 0x38: // kVK_Shift
            case 0x3B: // kVK_Control
            case 0x3A: // kVK_Option
            case 0x37: // kVK_Command
                return KeyLocation.left;
            case 0x3C: // kVK_RightShift
            case 0x3E: // kVK_RightControl
            case 0x3D: // kVK_RightOption
            case 0x36: // kVK_RightCommand
                return KeyLocation.right;
            case 0x41: // kVK_ANSI_KeypadDecimal
            case 0x43: // kVK_ANSI_KeypadMultiply
            case 0x45: // kVK_ANSI_KeypadPlus
            case 0x47: // kVK_ANSI_KeypadClear
            case 0x4B: // kVK_ANSI_KeypadDivide
            case 0x4C: // kVK_ANSI_KeypadEnter
            case 0x4E: // kVK_ANSI_KeypadMinus
            case 0x51: // kVK_ANSI_KeypadEquals
            case 0x52: .. case 0x59: // kVK_ANSI_Keypad0 .. Keypad7
            case 0x5B: // kVK_ANSI_Keypad8
            case 0x5C: // kVK_ANSI_Keypad9
                return KeyLocation.numpad;
            default:
                return KeyLocation.standard;
        }
    }

    /// Chord modifiers only; caps lock (1 << 16) is a latched state.
    package static Mods appKitMods(ulong flags) @safe pure nothrow @nogc
        => Mods(
            ctrl: (flags & (1UL << 18)) != 0,
            alt: (flags & (1UL << 19)) != 0,
            shift: (flags & (1UL << 17)) != 0,
            super_: (flags & (1UL << 20)) != 0);

    package static ulong appKitModifierFlagFor(uint keyCode)
        @safe pure nothrow @nogc
    {
        switch (keyCode)
        {
            case 0x38: case 0x3C: return 1UL << 17;
            case 0x3B: case 0x3E: return 1UL << 18;
            case 0x3A: case 0x3D: return 1UL << 19;
            case 0x37: case 0x36: return 1UL << 20;
            default: return 0;
        }
    }

    private void onViewDraw(SparklesWsiView view)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        emit(idAt(index), ExposedEvent());
        emit(idAt(index), FrameReadyEvent());
    }

    private void onCloseRequest(SparklesWsiWindow window)
    {
        const index = indexOfWindow(window);
        if (index != size_t.max)
            emit(idAt(index), CloseRequestedEvent());
    }

    private void onFocus(SparklesWsiWindow window, bool focused)
    {
        const index = indexOfWindow(window);
        if (index != size_t.max && windows_[index].ready)
            emit(idAt(index), FocusChangedEvent(focused));
    }

    private void destroySlot(size_t index, bool notify)
    {
        ref slot = windows_[index];
        const id = idAt(index);
        slot.ready = false;
        slot.live = false;
        if (slot.window !is null)
        {
            slot.window.setDelegate(null);
            slot.window.orderOut(null);
            slot.window.close();
        }
        if (notify)
            emit(id, DestroyedEvent());
        if (slot.view !is null)
            slot.view.release();
        if (slot.window !is null)
            slot.window.release();
        slot.view = null;
        slot.window = null;
    }

    private bool installKqueueBridge(int descriptor)
    {
        if (kqueueDescriptor_ !is null)
            return descriptor == bridgedKqueue_;
        if (descriptor < 0)
            return false;

        CFFileDescriptorContext context;
        context.info = &this;
        kqueueDescriptor_ = CFFileDescriptorCreate(null, descriptor, false,
            cast(void*) &onKqueueReady, &context);
        if (kqueueDescriptor_ is null)
            return false;
        kqueueSource_ = CFFileDescriptorCreateRunLoopSource(null,
            kqueueDescriptor_, 0);
        if (kqueueSource_ is null)
        {
            CFFileDescriptorInvalidate(kqueueDescriptor_);
            CFRelease(kqueueDescriptor_);
            kqueueDescriptor_ = null;
            return false;
        }
        CFRunLoopAddSource(runLoop_, kqueueSource_, kCFRunLoopCommonModes);
        bridgedKqueue_ = descriptor;
        return true;
    }

    private void removeKqueueBridge()
    {
        if (kqueueSource_ !is null)
        {
            CFRunLoopRemoveSource(runLoop_, kqueueSource_,
                kCFRunLoopCommonModes);
            CFRelease(kqueueSource_);
            kqueueSource_ = null;
        }
        if (kqueueDescriptor_ !is null)
        {
            CFFileDescriptorInvalidate(kqueueDescriptor_);
            CFRelease(kqueueDescriptor_);
            kqueueDescriptor_ = null;
        }
        bridgedKqueue_ = -1;
    }
}

private extern (C) void onKqueueReady(CFFileDescriptorRef descriptor,
    CFOptionFlags types, void* info) nothrow @nogc
{
    auto owner = cast(AppKitWsi*) info;
    if (owner !is null)
        owner.completionReady_ = true;
}

/*
D's extern(Objective-C) cannot declare protocol adoption, and NSView's
`inputContext` is non-nil only when the class conforms, so the first view
registers NSTextInputClient on its class through the runtime.
*/
private extern (D) void adoptTextInputProtocol(SparklesWsiView view)
{
    static bool adopted;
    if (adopted || view is null)
        return;
    adopted = true;
    auto protocol = objc_getProtocol("NSTextInputClient");
    auto cls = object_getClass(cast(void*) view);
    if (protocol !is null && cls !is null)
        class_addProtocol(cls, protocol);
}

/// UTF-16 code units of a valid UTF-8 string (astral scalars count two).
package extern (D) ulong utf16Length(scope const(char)[] text)
    @safe pure nothrow @nogc
{
    ulong units;
    size_t i;
    while (i < text.length)
    {
        const lead = text[i];
        const step = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
        units += step == 4 ? 2 : 1;
        i += step;
    }
    return units;
}

/// Byte offset of a UTF-16 code-unit index into a valid UTF-8 string,
/// clamped to the end.
package extern (D) size_t utf16UnitsToByteOffset(scope const(char)[] text,
    ulong units) @safe pure nothrow @nogc
{
    size_t i;
    ulong seen;
    while (i < text.length && seen < units)
    {
        const lead = text[i];
        const step = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
        seen += step == 4 ? 2 : 1;
        i += step;
    }
    return i;
}

/**
Maps one setMarkedText batch to the shared composition vocabulary. AppKit's
`selectedRange` is in UTF-16 code units within the marked text; the cursor
sits at the selection start, the selection (when non-empty) becomes both
the selection fields and a `selected` segment over the conventional
whole-pre-edit underline.
*/
extern (D) CompositionEvent appKitComposition(scope const(char)[] preedit,
    ulong selLocation16, ulong selLength16) @safe pure nothrow @nogc
{
    CompositionEvent event;
    if (!event.preedit.assign(preedit))
        return event;
    if (preedit.length == 0)
        return event;
    const selStart = selLocation16 == nsNotFound
        ? preedit.length
        : utf16UnitsToByteOffset(preedit, selLocation16);
    const selEnd = selLocation16 == nsNotFound
        ? preedit.length
        : utf16UnitsToByteOffset(preedit, selLocation16 + selLength16);
    event.cursor = cast(ushort) selStart;
    event.segments[0] = CompositionSegment(0, cast(ushort) preedit.length,
        CompositionSegmentStyle.underline);
    event.segmentCount = 1;
    if (selEnd > selStart)
    {
        event.selectionStart = cast(ushort) selStart;
        event.selectionLength = cast(ushort) (selEnd - selStart);
        event.segments[1] = CompositionSegment(cast(ushort) selStart,
            cast(ushort) (selEnd - selStart), CompositionSegmentStyle.selected);
        event.segmentCount = 2;
    }
    return event;
}

@("wsi.appkit.appKitComposition.utf16UnitsBecomeByteOffsets")
@safe pure nothrow @nogc
unittest
{
    // Selection over the second of three kana (3 bytes each, 1 unit each).
    const kana = appKitComposition("にほん", 1, 1);
    assert(kana.preedit[] == "にほん");
    assert(kana.cursor == 3);
    assert(kana.selectionStart == 3 && kana.selectionLength == 3);
    assert(kana.segmentCount == 2);
    assert(kana.segments[1] == CompositionSegment(3, 3,
        CompositionSegmentStyle.selected));

    // An astral scalar is one 4-byte sequence but two UTF-16 units.
    const astral = appKitComposition("a😀b", 1, 2);
    assert(astral.selectionStart == 1 && astral.selectionLength == 4);

    // A caret with no selection: cursor only, single underline segment.
    const caret = appKitComposition("ab", 2, 0);
    assert(caret.cursor == 2 && caret.segmentCount == 1);

    // NSNotFound parks the caret at the end.
    const parked = appKitComposition("ab", nsNotFound, 0);
    assert(parked.cursor == 2 && parked.selectionLength == 0);

    assert(utf16Length("a😀b") == 4);
}

private WsiResult!T appKitFailure(T)(WsiOperation operation, long nativeCode,
    scope const(char)[] diagnostic,
    WsiErrorKind kind = WsiErrorKind.nativeFailure)
{
    return wsiErr!T(wsiError(kind, operation, BackendKind.appkit,
        nativeCode, diagnostic));
}

@("wsi.appkit.keyLocationFollowsCarbonVirtualCodes")
@safe pure nothrow @nogc
unittest
{
    assert(AppKitWsi.appKitKeyLocation(0x38) == KeyLocation.left);
    assert(AppKitWsi.appKitKeyLocation(0x3C) == KeyLocation.right);
    assert(AppKitWsi.appKitKeyLocation(0x37) == KeyLocation.left);
    assert(AppKitWsi.appKitKeyLocation(0x36) == KeyLocation.right);
    assert(AppKitWsi.appKitKeyLocation(0x4C) == KeyLocation.numpad);
    assert(AppKitWsi.appKitKeyLocation(0x52) == KeyLocation.numpad);
    assert(AppKitWsi.appKitKeyLocation(0x5C) == KeyLocation.numpad);
    assert(AppKitWsi.appKitKeyLocation(0x00) == KeyLocation.standard);
}

@("wsi.appkit.modifiersComeFromNSEventFlags")
@safe pure nothrow @nogc
unittest
{
    assert(AppKitWsi.appKitMods(0) == Mods());
    assert(AppKitWsi.appKitMods(1UL << 17) == Mods(shift: true));
    assert(AppKitWsi.appKitMods(1UL << 18) == Mods(ctrl: true));
    assert(AppKitWsi.appKitMods(1UL << 19) == Mods(alt: true));
    assert(AppKitWsi.appKitMods(1UL << 20) == Mods(super_: true));
    // Caps lock is a latched state, not a chord modifier.
    assert(AppKitWsi.appKitMods(1UL << 16) == Mods());
    assert(AppKitWsi.appKitModifierFlagFor(0x3C) == 1UL << 17);
    assert(AppKitWsi.appKitModifierFlagFor(0x00) == 0);
}

@("wsi.appkit.firstScalarDecodesTheLeadingCodePoint")
@safe pure nothrow @nogc
unittest
{
    assert(AppKitWsi.firstScalar("a") == 'a');
    assert(AppKitWsi.firstScalar("λx") == 'λ');
    assert(AppKitWsi.firstScalar("\uF700") == 0xF700);
    assert(AppKitWsi.firstScalar("") == dchar.init);
    assert(AppKitWsi.firstScalar("\xC3") == dchar.init);
    assert(AppKitWsi.firstScalar("\xFF") == dchar.init);
}
