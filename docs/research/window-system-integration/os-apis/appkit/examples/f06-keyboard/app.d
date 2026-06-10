// macOS/AppKit F06 demo — keyboard & keymap (../../../features/f06-keyboard.md).
// Scancode -> keysym -> text is three different questions, and AppKit splits the work
// between the hardware keyCode, the layout engine (UCKeyTranslate / the `uchr` data),
// and the text-input layer (interpretKeyEvents: -> insertText:/doCommandBySelector:).
// This demo logs all three levels and probes the boundaries.
//
// A custom NSView (KeyView, acceptsFirstResponder = YES) logs keyDown:/keyUp:/
// flagsChanged: as `key code=<scancode> sym=<charsIgnoringMods> text=<characters>
// state=down|up repeat=0|1`, then routes each keyDown through interpretKeyEvents:,
// implementing insertText:replacementRange:, the legacy insertText:, and
// doCommandBySelector: — logging which one the text system actually calls (the
// NSTextInputClient marked-text methods are F07; here we observe what arrives without
// them, which is the boundary finding F07 builds on).
//
// Three demonstrations, choreographed under WSI_AUTO_EXIT=1:
//   1. Layout engine (synchronous, no run loop / injection — robust over SSH):
//      UCKeyTranslate on the current `uchr` proves the three-level split (keyCode 0 ->
//      "a"; +shift -> "A"; option-e sets a deadKeyState + no text, then keyCode 14
//      composes "é"); an installed German `uchr` is pulled WITHOUT switching to show
//      the same scancode (keyCode 6) yield 'z' US vs 'y' QWERTZ; a TISSelectInputSource
//      switch is attempted and its OSStatus captured.
//   2. App-side chain (route 1 — synthetic NSEvent + [window sendEvent:], always works
//      in-process): a letter, shifted digit ('!'), arrow (-> doCommandBySelector:), the
//      option-e + e dead-key pair, and a repeat (isARepeat:YES) — logging what
//      interpretKeyEvents: forwards to insertText:/doCommandBySelector:.
//   3. Real HID injection (route 2 — CGEventPost): does it reach keyDown: under a
//      locked screen / over SSH? Either outcome is a finding.
// Also logs NSEvent.keyRepeatDelay / .keyRepeatInterval (the system repeat contract).
//
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server.
module app;

import core.attribute : selector;
import core.stdc.config : c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strstr;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL;

// --- Carbon / CoreFoundation C API (layout engine + input sources) --------------
// UCKeyTranslate, the TIS* functions, LMGetKbdType, and the kTISProperty* globals
// live in Carbon (HIToolbox); the build links `-framework Carbon` in addition to
// Cocoa. CFData/CFArray/CFString helpers come with CoreFoundation (via Cocoa).

alias OSStatus = int;
alias TISInputSourceRef = void*;
alias CFStringRef = void*;
alias CFDataRef = void*;
alias CFArrayRef = void*;

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();

    TISInputSourceRef TISCopyCurrentKeyboardLayoutInputSource();
    void* TISGetInputSourceProperty(TISInputSourceRef source, CFStringRef key);
    CFArrayRef TISCreateInputSourceList(void* properties, bool includeAllInstalled);
    OSStatus TISSelectInputSource(TISInputSourceRef source);
    extern __gshared CFStringRef kTISPropertyUnicodeKeyLayoutData;
    extern __gshared CFStringRef kTISPropertyInputSourceID;

    const(ubyte)* CFDataGetBytePtr(CFDataRef d);
    long CFArrayGetCount(CFArrayRef a);
    const(void)* CFArrayGetValueAtIndex(CFArrayRef a, long idx);
    bool CFStringGetCString(CFStringRef s, char* buf, long bufSize, uint encoding);
    void CFRelease(void* o);

    uint LMGetKbdType();
    OSStatus UCKeyTranslate(const(void)* keyLayoutPtr, ushort virtualKeyCode,
        ushort keyAction, uint modifierKeyState, uint keyboardType,
        uint keyTranslateOptions, uint* deadKeyState, c_ulong maxStringLength,
        c_ulong* actualStringLength, ushort* unicodeString);

    // CoreGraphics event injection (route 2)
    void* CGEventCreateKeyboardEvent(void* source, ushort vk, bool keyDown);
    void CGEventPost(uint tapLocation, void* event);
    void CGEventSetFlags(void* event, ulong flags);
}

enum ushort kUCKeyActionDown = 0;
enum uint kCFStringEncodingUTF8 = 0x0800_0100;
enum uint kCGHIDEventTap = 0;
enum uint kCGSessionEventTap = 1;

// UCKeyTranslate modifier-key state is the classic high-byte modifiers >> 8.
enum uint uckShift = 2; // shiftKey (0x0200) >> 8
enum uint uckOption = 8; // optionKey (0x0800) >> 8

// --- Cocoa geometry / NSRange ---------------------------------------------------

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

extern (C) struct NSRange
{
    ulong location, length; // NSUInteger
}

// --- AppKit class declarations --------------------------------------------------

extern (Objective-C):

extern class NSObject
{
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
    const(char)* UTF8String() @selector("UTF8String");
}

extern class NSArray : NSObject
{
    static NSArray arrayWithObject(NSObject o) @selector("arrayWithObject:");
}

extern class NSResponder : NSObject
{
    void interpretKeyEvents(NSArray events) @selector("interpretKeyEvents:");
}

extern class NSEvent : NSObject
{
    static NSEvent keyEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, NSString characters,
        NSString charactersIgnoringModifiers, bool isARepeat, ushort keyCode)
        @selector("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:");
    ushort keyCode() @selector("keyCode");
    NSString characters() @selector("characters");
    NSString charactersIgnoringModifiers() @selector("charactersIgnoringModifiers");
    bool isARepeat() @selector("isARepeat");
    ulong modifierFlags() @selector("modifierFlags");
    static double keyRepeatDelay() @selector("keyRepeatDelay");
    static double keyRepeatInterval() @selector("keyRepeatInterval");
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
}

extern class NSTimer : NSObject
{
    static NSTimer scheduledTimerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
}

extern class NSApplication : NSResponder
{
    static NSApplication sharedApplication() @selector("sharedApplication");
    void setActivationPolicy(long policy) @selector("setActivationPolicy:");
    void activateIgnoringOtherApps(bool flag) @selector("activateIgnoringOtherApps:");
    void run() @selector("run");
    void stop(NSObject sender) @selector("stop:");
    void postEvent(NSEvent event, bool atStart) @selector("postEvent:atStart:");
}

extern class NSView : NSResponder
{
    bool acceptsFirstResponder() @selector("acceptsFirstResponder");
}

extern class NSWindow : NSResponder
{
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSObject view) @selector("setContentView:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    bool makeFirstResponder(NSObject responder) @selector("makeFirstResponder:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
    long windowNumber() @selector("windowNumber");
}

// The custom view: logs the three key levels and routes through the text system.
class KeyView : NSView
{
    static KeyView alloc() @selector("alloc");
    KeyView initWithFrame(NSRect frame) @selector("initWithFrame:");

    override bool acceptsFirstResponder() @selector("acceptsFirstResponder")
    {
        return true;
    }

    void keyDown(NSEvent e) @selector("keyDown:")
    {
        logKey("down", e);
        if (e.keyCode() == g_cgWatchCode)
            g_cgArrived = true;
        // Route through the text-input system: this is what turns keysym-level events
        // into insertText:/doCommandBySelector: callbacks.
        instr("step", "name=interpretKeyEvents code=%u", e.keyCode());
        this.interpretKeyEvents(NSArray.arrayWithObject(e));
    }

    void keyUp(NSEvent e) @selector("keyUp:")
    {
        logKey("up", e);
    }

    void flagsChanged(NSEvent e) @selector("flagsChanged:")
    {
        instr("flags_changed", "code=%u flags=0x%llx", e.keyCode(), e.modifierFlags());
    }

    // Modern NSTextInputClient text insertion (the one F07 will round out).
    void insertText_(NSString s, NSRange r) @selector("insertText:replacementRange:")
    {
        instr("insert_text", "variant=replacementRange text=%s loc=%llu len=%llu",
            s !is null ? s.UTF8String() : "", r.location, r.length);
    }

    // Legacy single-argument insertText: (pre-NSTextInputClient NSResponder path).
    void insertTextLegacy(NSObject s) @selector("insertText:")
    {
        auto str = cast(NSString) s;
        instr("insert_text", "variant=legacy text=%s",
            str !is null ? str.UTF8String() : "");
    }

    void doCommandBySelector(SEL sel) @selector("doCommandBySelector:")
    {
        instr("do_command", "selector=%s", sel.name);
    }
}

extern (D): // back to D linkage

enum NSApplicationActivationPolicyRegular = 0;
enum : ulong
{
    NSWindowStyleMaskTitled = 1,
    NSWindowStyleMaskClosable = 2,
    NSWindowStyleMaskResizable = 8,
}

enum ulong NSBackingStoreBuffered = 2;

enum long NSEventTypeKeyDown = 10;
enum long NSEventTypeKeyUp = 11;
enum long NSEventTypeApplicationDefined = 15;

enum : ulong
{
    NSEventModifierFlagShift = 1UL << 17,
    NSEventModifierFlagControl = 1UL << 18,
    NSEventModifierFlagOption = 1UL << 19,
    NSEventModifierFlagCommand = 1UL << 20,
    NSEventModifierFlagNumericPad = 1UL << 21,
    NSEventModifierFlagFunction = 1UL << 23,
}

enum ulong kCGEventFlagMaskAlternate = 1UL << 19; // option, for CGEvent route

// --- Demo state -----------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared KeyView g_view;
__gshared long g_winNum;
__gshared int g_step;
__gshared ushort g_cgWatchCode = 2; // 'd' on US ANSI — used only by route 2
__gshared bool g_cgArrived;

// Route-1 synthetic key script. `chars`/`charsNoMod` are D string literals (always
// NUL-terminated), so `.ptr` is a valid C string for initWithUTF8String.
struct KeySpec
{
    ushort code;
    ulong flags;
    string chars; // -[NSEvent characters]
    string charsNoMod; // -[NSEvent charactersIgnoringModifiers]
    bool repeat;
    string label;
}

// keyCode 18 = '1', 123 = LeftArrow, 14 = 'e'. The option-e event carries the spacing
// acute U+00B4 in `characters` (what a US dead-acute keyDown reports); the boundary
// question is whether interpretKeyEvents re-composes "é" or just forwards it.
immutable KeySpec[] g_script = [
    KeySpec(0, 0, "a", "a", false, "letter_a"),
    KeySpec(18, NSEventModifierFlagShift, "!", "1", false, "shift_1_bang"),
    KeySpec(123, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad,
        "", "", false, "arrow_left"),
    KeySpec(14, NSEventModifierFlagOption, "´", "e", false, "opt_e_deadacute"),
    KeySpec(14, 0, "e", "e", false, "e_after_dead"),
    KeySpec(0, 0, "a", "a", true, "repeat_a"),
];

NSEvent makeKey(long type, in KeySpec k)
{
    NSString ch = NSString.alloc().initWithUTF8String(k.chars.ptr);
    NSString cm = NSString.alloc().initWithUTF8String(k.charsNoMod.ptr);
    return NSEvent.keyEventWithType(type, NSPoint(0, 0), k.flags, 0, g_winNum, null,
        ch, cm, k.repeat, k.code);
}

void logKey(const(char)* state, NSEvent e)
{
    NSString sym = e.charactersIgnoringModifiers();
    NSString txt = e.characters();
    instr("key", "code=%u sym=%s text=%s state=%s repeat=%d flags=0x%llx",
        e.keyCode(), sym !is null ? sym.UTF8String() : "",
        txt !is null ? txt.UTF8String() : "", state, e.isARepeat() ? 1 : 0,
        e.modifierFlags());
}

// --- UCKeyTranslate layout-engine demonstration (synchronous) -------------------

// BMP-only UTF-16 -> UTF-8 (enough for a/A/é/z/y); writes a NUL-terminated C string.
void utf16ToUtf8(const(ushort)* s, size_t n, char* o) nothrow @nogc
{
    size_t j = 0;
    foreach (i; 0 .. n)
    {
        immutable uint c = s[i];
        if (c < 0x80)
            o[j++] = cast(char) c;
        else if (c < 0x800)
        {
            o[j++] = cast(char)(0xC0 | (c >> 6));
            o[j++] = cast(char)(0x80 | (c & 0x3F));
        }
        else
        {
            o[j++] = cast(char)(0xE0 | (c >> 12));
            o[j++] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            o[j++] = cast(char)(0x80 | (c & 0x3F));
        }
    }
    o[j] = 0;
}

// One UCKeyTranslate call; returns the number of UTF-16 units produced and updates
// *deadState (kept across calls so a dead key can compose with the next press).
size_t uck(const(void)* layout, ushort vk, uint modState, uint* deadState,
    ushort* outUtf16, size_t cap) nothrow @nogc
{
    c_ulong actual = 0;
    UCKeyTranslate(layout, vk, kUCKeyActionDown, modState, LMGetKbdType(), 0,
        deadState, cap, &actual, outUtf16);
    return cast(size_t) actual;
}

void layoutDemo(const(void)* layout, const(char)* label)
{
    ushort[8] u;
    char[32] s;
    uint dead;

    dead = 0;
    auto n = uck(layout, 0, 0, &dead, u.ptr, u.length);
    utf16ToUtf8(u.ptr, n, s.ptr);
    instr("uckey", "layout=%s code=0 mods=none text=%s", label, s.ptr);

    dead = 0;
    n = uck(layout, 0, uckShift, &dead, u.ptr, u.length);
    utf16ToUtf8(u.ptr, n, s.ptr);
    instr("uckey", "layout=%s code=0 mods=shift text=%s", label, s.ptr);

    // keyCode 6: 'z' on US ANSI, 'y' on German QWERTZ — same scancode, different text.
    dead = 0;
    n = uck(layout, 6, 0, &dead, u.ptr, u.length);
    utf16ToUtf8(u.ptr, n, s.ptr);
    instr("uckey", "layout=%s code=6 mods=none text=%s", label, s.ptr);

    // Dead key: option-e sets a dead state and emits nothing...
    dead = 0;
    n = uck(layout, 14, uckOption, &dead, u.ptr, u.length);
    utf16ToUtf8(u.ptr, n, s.ptr);
    instr("compose", "layout=%s state=dead_set code=14 mods=option dead_state=%u text_len=%zu text=%s",
        label, dead, n, s.ptr);

    // ...then the next 'e' composes "é" using the retained dead state.
    n = uck(layout, 14, 0, &dead, u.ptr, u.length);
    utf16ToUtf8(u.ptr, n, s.ptr);
    instr("compose", "layout=%s state=composed code=14 mods=none dead_state=%u text=%s",
        label, dead, s.ptr);
}

const(void)* layoutData(TISInputSourceRef src)
{
    if (src is null)
        return null;
    CFDataRef d = cast(CFDataRef) TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData);
    return d is null ? null : cast(const(void)*) CFDataGetBytePtr(d);
}

void sourceId(TISInputSourceRef src, char* buf, long bufSize)
{
    buf[0] = 0;
    if (src is null)
        return;
    CFStringRef id = cast(CFStringRef) TISGetInputSourceProperty(src, kTISPropertyInputSourceID);
    if (id !is null)
        CFStringGetCString(id, buf, bufSize, kCFStringEncodingUTF8);
}

void runLayoutDemos()
{
    instr("repeat_info", "delay_s=%.3f interval_s=%.3f",
        NSEvent.keyRepeatDelay(), NSEvent.keyRepeatInterval());

    TISInputSourceRef cur = TISCopyCurrentKeyboardLayoutInputSource();
    char[256] idbuf;
    sourceId(cur, idbuf.ptr, idbuf.length);
    instr("input_source", "role=current id=%s", idbuf.ptr);
    const(void)* curLayout = layoutData(cur);
    if (curLayout !is null)
        layoutDemo(curLayout, "current");
    else
        instr("uckey", "layout=current text=<no_uchr> note=current_source_has_no_unicode_layout");

    // Enumerate installed sources; pull a German keylayout's uchr WITHOUT switching.
    CFArrayRef list = TISCreateInputSourceList(null, true);
    TISInputSourceRef german = null;
    if (list !is null)
    {
        immutable count = CFArrayGetCount(list);
        foreach (i; 0 .. count)
        {
            auto src = cast(TISInputSourceRef) CFArrayGetValueAtIndex(list, i);
            sourceId(src, idbuf.ptr, idbuf.length);
            if (strstr(idbuf.ptr, "German") !is null && layoutData(src) !is null)
            {
                german = src;
                break;
            }
        }
    }

    if (german !is null)
    {
        sourceId(german, idbuf.ptr, idbuf.length);
        instr("input_source", "role=german_found id=%s", idbuf.ptr);
        layoutDemo(layoutData(german), "german");

        // Attempt a runtime system layout switch and capture the status.
        immutable st = TISSelectInputSource(german);
        instr("layout_switch", "target=german status=%d note=%s", st,
            st == 0 ? "selected".ptr : "rejected".ptr);
        if (st == 0 && cur !is null)
        {
            immutable back = TISSelectInputSource(cur);
            instr("layout_switch", "target=restore status=%d", back);
        }
    }
    else
    {
        instr("input_source", "role=german_found id=<none> note=german_layout_not_installed");
    }

    if (cur !is null)
        CFRelease(cur);
    if (list !is null)
        CFRelease(list);
}

// --- Route 2: real HID injection via CGEventPost --------------------------------

void postCGKey(ushort code)
{
    void* down = CGEventCreateKeyboardEvent(null, code, true);
    void* up = CGEventCreateKeyboardEvent(null, code, false);
    if (down is null || up is null)
    {
        instr("cgevent_post", "result=create_failed");
        return;
    }
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

// --- Run-loop script (route 1 injection + the CGEventPost probe) ------------------

void stopApp()
{
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    // stop: only takes effect after the next event dispatch; post a synthetic
    // application-defined event so [NSApp run] wakes up and returns (scaffold finding).
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true);
}

void onStep()
{
    if (g_step < cast(int) g_script.length)
    {
        immutable k = g_script[g_step];
        instr("inject", "route=1 label=%.*s code=%u repeat=%d",
            cast(int) k.label.length, k.label.ptr, k.code, k.repeat ? 1 : 0);
        g_win.sendEvent(makeKey(NSEventTypeKeyDown, k));
        g_win.sendEvent(makeKey(NSEventTypeKeyUp, k));
    }
    else if (g_step == cast(int) g_script.length)
    {
        instr("step", "name=cgevent_post tap=session code=%u", g_cgWatchCode);
        g_cgArrived = false;
        postCGKey(g_cgWatchCode);
    }
    else if (g_step == cast(int) g_script.length + 3)
    {
        // Grace period elapsed: did the HID event reach our keyDown:?
        instr("cgevent_result", "tap=session code=%u reached=%d note=%s",
            g_cgWatchCode, g_cgArrived ? 1 : 0,
            g_cgArrived ? "delivered".ptr : "blocked_or_not_routed".ptr);
    }
    else if (g_step >= cast(int) g_script.length + 4)
    {
        stopApp();
    }
    ++g_step;
}

extern (Objective-C) class StepTarget : NSObject
{
    static StepTarget alloc() @selector("alloc");
    StepTarget init() @selector("init");

    void step(NSTimer t) @selector("step:")
    {
        onStep();
    }
}

int main()
{
    immutable autoExit = getenv("WSI_AUTO_EXIT") !is null;
    instrInit("APPKIT_F06");
    instr("init_start", "auto_exit=%d", autoExit ? 1 : 0);

    instr("step", "name=CGMainDisplayID");
    if (CGMainDisplayID() == 0)
    {
        printf("SKIP: no macOS window server (CGMainDisplayID == 0)\n");
        return 0;
    }

    auto pool = autoreleasepool_push();
    scope (exit)
        autoreleasepool_pop(pool);

    g_app = NSApplication.sharedApplication();
    g_app.setActivationPolicy(NSApplicationActivationPolicyRegular);

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(360, 240));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f06-keyboard"));
    g_view = KeyView.alloc().initWithFrame(contentRect);
    g_win.setContentView(g_view);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    g_win.makeFirstResponder(g_view);
    g_winNum = g_win.windowNumber();
    instr("window_created", "win_num=%ld first_responder=KeyView", g_winNum);

    // Synchronous layout-engine + input-source demonstrations (no run loop needed).
    runLayoutDemos();

    // Drive the route-1 script and the route-2 probe from a repeating timer inside
    // [NSApp run] (interpretKeyEvents: needs the running loop / live input context).
    StepTarget target = StepTarget.alloc().init();
    instr("step", "name=script_timer_start interval_ms=200");
    NSTimer.scheduledTimerWithTimeInterval(0.2, target, SEL.register("step:"), null, true);

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "steps=%d", g_step);
    return 0;
}
