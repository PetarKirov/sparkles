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
import std.math : isFinite;

import sparkles.base.text.utf8 : validateUtf8;
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
}

private extern class NSDate : NSObject
{
    static NSDate distantPast() @selector("distantPast");
}

private extern class NSEvent : NSObject
{
}

private extern class NSResponder : NSObject
{
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
    void setFrameSize(NSSize size) @selector("setFrameSize:");
    void setNeedsDisplay(bool value) @selector("setNeedsDisplay:");
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
    void makeKeyAndOrderFront(NSObject sender)
        @selector("makeKeyAndOrderFront:");
    void orderOut(NSObject sender) @selector("orderOut:");
    void close() @selector("close");
    double backingScaleFactor() @selector("backingScaleFactor");
}

/** Private NSView subclass forwarding only lossless native observations. */
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
}

/** Private NSWindow subclass serving as its own delegate. */
private class SparklesWsiWindow : NSWindow
{
    static SparklesWsiWindow alloc() @selector("alloc");

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

private enum long NSApplicationActivationPolicyAccessory = 1;
private enum ulong NSWindowStyleMaskTitled = 1;
private enum ulong NSWindowStyleMaskClosable = 2;
private enum ulong NSWindowStyleMaskMiniaturizable = 4;
private enum ulong NSWindowStyleMaskResizable = 8;
private enum ulong NSBackingStoreBuffered = 2;

private __gshared AppKitWsi* activeOwner;

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
    static WsiResult!void open(out AppKitWsi wsi)
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
        wsi.application_.setActivationPolicy(
            NSApplicationActivationPolicyAccessory);
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
        if (config.logicalSize.width < 0 || config.logicalSize.height < 0
            || !config.logicalSize.width.isFinite
            || !config.logicalSize.height.isFinite)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "invalid logical window size",
                WsiErrorKind.invalidArgument);
        if (config.transparent
            || config.state != WindowStartupState.normal)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "requested AppKit startup configuration is not implemented",
                WsiErrorKind.unsupported);
        if (config.parent.valid)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "AppKit parent windows are not implemented",
                WsiErrorKind.unsupported);
        if (validateUtf8(config.title.value).hasError)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "window title is not valid UTF-8",
                WsiErrorKind.invalidArgument);
        foreach (byte_; config.title.value)
            if (byte_ == 0)
                return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                    "window title contains an embedded NUL",
                    WsiErrorKind.invalidArgument);

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
        const rect = NSRect(NSPoint(120, 120),
            NSSize(config.logicalSize.width, config.logicalSize.height));

        auto window = SparklesWsiWindow.alloc();
        if (window is null)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "SparklesWsiWindow.alloc returned nil");
        window = cast(SparklesWsiWindow) window.initWithContentRect(rect,
            style, NSBackingStoreBuffered, false);
        if (window is null)
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "NSWindow initialization failed");

        auto view = SparklesWsiView.alloc().initWithFrame(rect);
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

        char[257] title = 0;
        title[0 .. config.title.length] = config.title.value;
        auto nativeTitle = NSString.alloc().initWithUTF8String(title.ptr);
        if (nativeTitle is null)
        {
            destroySlot(index, false);
            return appKitFailure!WindowId(WsiOperation.createWindow, 0,
                "NSString title conversion failed");
        }
        window.setTitle(nativeTitle);
        nativeTitle.release();
        window.setReleasedWhenClosed(false);
        window.setContentView(view);
        window.setDelegate(window);

        slot.metrics = metricsOf(slot);
        slot.ready = true;
        auto id = idAt(index);
        auto queued = emit(id, ReadyEvent(slot.metrics));
        if (queued.hasError)
        {
            destroySlot(index, false);
            return wsiErr!WindowId(queued.error);
        }

        if (config.visible)
            window.makeKeyAndOrderFront(null);
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
        if (closed_)
            return wsiOk();

        foreach (i; 0 .. windows_.length)
            if (windows_[i].window !is null)
                destroySlot(i, windows_[i].live);
        removeKqueueBridge();
        closed_ = true;
        open_ = false;
        if (activeOwner is &this)
            activeOwner = null;
        return hasStickyError_ ? wsiErr!void(stickyError_) : wsiOk();
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

    private WsiResult!void emit(Payload)(WindowId id,
        Payload payload) nothrow
    {
        auto result = events_.push(WindowEvent(nextSequence_, id,
            WindowEventPayload(payload)));
        if (result.hasError)
        {
            remember(result.error);
            return wsiErr!void(stickyError_);
        }
        ++nextSequence_;
        return wsiOk();
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
            cast(void) emit(idAt(index),
                SurfaceMetricsChangedEvent(metrics));
        slot.metrics = metrics;
    }

    private void onViewDraw(SparklesWsiView view)
    {
        const index = indexOfView(view);
        if (index == size_t.max || !windows_[index].ready)
            return;
        cast(void) emit(idAt(index), ExposedEvent());
        cast(void) emit(idAt(index), FrameReadyEvent());
    }

    private void onCloseRequest(SparklesWsiWindow window)
    {
        const index = indexOfWindow(window);
        if (index != size_t.max)
            cast(void) emit(idAt(index), CloseRequestedEvent());
    }

    private void onFocus(SparklesWsiWindow window, bool focused)
    {
        const index = indexOfWindow(window);
        if (index != size_t.max && windows_[index].ready)
            cast(void) emit(idAt(index), FocusChangedEvent(focused));
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
            cast(void) emit(id, DestroyedEvent());
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

private WsiResult!T appKitFailure(T)(WsiOperation operation, long nativeCode,
    scope const(char)[] diagnostic,
    WsiErrorKind kind = WsiErrorKind.nativeFailure)
{
    return wsiErr!T(wsiError(kind, operation, BackendKind.appkit,
        nativeCode, diagnostic));
}
