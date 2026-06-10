// macOS/AppKit F07 demo — IME / text input via NSTextInputClient
// (../../../features/f07-text-input.md).
// F06 proved the boundary: WITHOUT NSTextInputClient, interpretKeyEvents: routes to
// the legacy single-arg insertText: and a synthetic dead key passes through verbatim
// (´ then e, never é). This demo implements the FULL NSTextInputClient protocol on a
// custom view and shows the boundary flipping: the same synthetic option-e + e pair
// now produces setMarkedText:"´" (composition pending, rendered inline with an
// underline) followed by insertText:"é" replacing the marked text.
//
// The view keeps a single-line editor model (committed UTF-16 buffer + inline marked
// text + caret) and logs EVERY protocol callback with its arguments — the call
// choreography is the deliverable. Conformance is attached at runtime
// (class_addProtocol with the AppKit-registered NSTextInputClient protocol), and the
// demo logs conformsToProtocol: before/after plus -[NSView inputContext] for a
// conforming vs a plain view (the "bespoke view exposes no inputContext" trap).
//
// Choreographed under WSI_AUTO_EXIT=1 (synthetic NSEvents through [window sendEvent:]
// -> keyDown: -> interpretKeyEvents:, the f06 route 1):
//   a. plain text "hi"            -> which insertText variant fires now?
//   b. option-e then e            -> dead-key composition through marked text
//   c. option-e then Esc          -> cancel mid-composition (unmarkText? cancelOperation:?)
//   d. option-e then focus loss   -> marked-text fate on resignFirstResponder
//   e. insertText:"X" range={0,2} -> direct replacementRange semantics on committed text
//   f. firstRectForCharacterRange at both ends -> the caret/candidate-window anchor math
// Real CJK (Pinyin) input needs an unlocked session + enabled IME -> Tier C script in
// ../../f07-text-input.md.
//
// Headless-safe: prints `SKIP:` and exits 0 when there is no window server.
module app;

import core.attribute : selector;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv;

import instrument : instr, instrInit;
import objc.autorelease : autoreleasepool_push, autoreleasepool_pop; // objective-d
import objc.rt : SEL, Class, Protocol;

extern (C) nothrow @nogc
{
    uint CGMainDisplayID();
    void CGContextSetRGBFillColor(void* ctx, double r, double g, double b, double a);
    void CGContextFillRect(void* ctx, NSRect rect);

    // Route 2 (cgevent_wrap): a CGEvent created against a private event source gives
    // the NSEvent a real HID-style event backing (and the source owns dead-key state),
    // WITHOUT posting through the WindowServer tap (which f06 showed is not routed to
    // a locked, non-frontmost app). The CGEvent is wrapped in-process via
    // +[NSEvent eventWithCGEvent:] and dispatched straight to the view.
    void* CGEventSourceCreate(int stateID);
    void* CGEventCreateKeyboardEvent(void* source, ushort vk, bool keyDown);
    void CGEventSetFlags(void* event, ulong flags);
    void CFRelease(void* o);
}

enum int kCGEventSourceStatePrivate = -1;
enum ulong kCGEventFlagMaskAlternate = 1UL << 19;

// --- Cocoa geometry / NSRange ----------------------------------------------------

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

enum ulong NSNotFound = 0x7FFF_FFFF_FFFF_FFFF; // NSIntegerMax

// --- AppKit class declarations ---------------------------------------------------

extern (Objective-C):

extern class NSObject
{
    bool respondsToSelector(SEL sel) @selector("respondsToSelector:");
    Class objcClass() @selector("class");
}

extern class NSString : NSObject
{
    static NSString alloc() @selector("alloc");
    NSString initWithUTF8String(const(char)* s) @selector("initWithUTF8String:");
    NSString initWithCharacters(const(ushort)* chars, ulong length)
        @selector("initWithCharacters:length:");
    const(char)* UTF8String() @selector("UTF8String");
    ulong length() @selector("length");
    ushort characterAtIndex(ulong index) @selector("characterAtIndex:");
}

extern class NSAttributedString : NSObject
{
    static NSAttributedString alloc() @selector("alloc");
    NSAttributedString initWithString(NSString s) @selector("initWithString:");
    NSString string() @selector("string");
}

extern class NSArray : NSObject
{
    static NSArray array() @selector("array");
    static NSArray arrayWithObject(NSObject o) @selector("arrayWithObject:");
}

extern class NSResponder : NSObject
{
    void interpretKeyEvents(NSArray events) @selector("interpretKeyEvents:");
    bool becomeFirstResponder() @selector("becomeFirstResponder");
    bool resignFirstResponder() @selector("resignFirstResponder");
}

extern class NSEvent : NSObject
{
    static NSEvent keyEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, NSString characters,
        NSString charactersIgnoringModifiers, bool isARepeat, ushort keyCode)
        @selector("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:");
    static NSEvent otherEventWithType(long type, NSPoint location, ulong modifierFlags,
        double timestamp, long windowNumber, NSObject context, short subtype,
        long data1, long data2)
        @selector("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:");
    static NSEvent eventWithCGEvent(void* cgEvent) @selector("eventWithCGEvent:");
    ushort keyCode() @selector("keyCode");
    long type() @selector("type");
    NSString characters() @selector("characters");
    ulong modifierFlags() @selector("modifierFlags");
}

extern class NSTimer : NSObject
{
    static NSTimer scheduledTimerWithTimeInterval(double interval, NSObject target,
        SEL sel, NSObject userInfo, bool repeats)
        @selector("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
}

extern class NSGraphicsContext : NSObject
{
    static NSGraphicsContext currentContext() @selector("currentContext");
    void* CGContext() @selector("CGContext");
}

extern class NSTextInputContext : NSObject
{
    void activate() @selector("activate");
    bool handleEvent(NSEvent e) @selector("handleEvent:");
    NSString selectedKeyboardInputSource() @selector("selectedKeyboardInputSource");
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
    NSRect bounds() @selector("bounds");
    void setNeedsDisplay(bool flag) @selector("setNeedsDisplay:");
    NSRect convertRect(NSRect rect, NSView view) @selector("convertRect:toView:");
    NSPoint convertPoint(NSPoint point, NSView view) @selector("convertPoint:fromView:");
    NSTextInputContext inputContext() @selector("inputContext");
}

extern class NSWindow : NSResponder
{
    static NSWindow alloc() @selector("alloc");
    NSWindow initWithContentRect(NSRect contentRect, ulong styleMask,
        ulong backing, bool defer) @selector("initWithContentRect:styleMask:backing:defer:");
    void setTitle(NSString title) @selector("setTitle:");
    void setContentView(NSView view) @selector("setContentView:");
    void setDelegate(NSObject anObject) @selector("setDelegate:");
    void makeKeyAndOrderFront(NSObject sender) @selector("makeKeyAndOrderFront:");
    bool makeFirstResponder(NSObject responder) @selector("makeFirstResponder:");
    void sendEvent(NSEvent event) @selector("sendEvent:");
    long windowNumber() @selector("windowNumber");
    NSRect convertRectToScreen(NSRect rect) @selector("convertRectToScreen:");
    NSRect convertRectFromScreen(NSRect rect) @selector("convertRectFromScreen:");
}

// A focusable view WITHOUT NSTextInputClient: the focus-loss target, and the negative
// control for -[NSView inputContext] (a bespoke view that never told AppKit it can
// accept text input gets no input context at all — the Uno/sokol trap from the survey).
class PlainView : NSView
{
    static PlainView alloc() @selector("alloc");
    PlainView initWithFrame(NSRect frame) @selector("initWithFrame:");

    override bool acceptsFirstResponder() @selector("acceptsFirstResponder")
    {
        return true;
    }
}

// The editor view. Bodied methods implement NSTextInputClient (conformance metadata is
// attached at runtime in main — see attachProtocol); the editor model lives in module
// globals (g_text/g_marked/g_caret).
class TextView : NSView
{
    static TextView alloc() @selector("alloc");
    TextView initWithFrame(NSRect frame) @selector("initWithFrame:");

    override bool acceptsFirstResponder() @selector("acceptsFirstResponder")
    {
        return true;
    }

    override bool becomeFirstResponder() @selector("becomeFirstResponder")
    {
        instr("focus", "state=become");
        return super.becomeFirstResponder();
    }

    override bool resignFirstResponder() @selector("resignFirstResponder")
    {
        instr("focus", "state=resign has_marked=%d", g_hasMarked ? 1 : 0);
        immutable r = super.resignFirstResponder();
        logState("after_resign");
        return r;
    }

    void keyDown(NSEvent e) @selector("keyDown:")
    {
        NSString txt = e.characters();
        instr("key", "code=%u text=%s", e.keyCode(), txt !is null ? txt.UTF8String() : "");
        if (g_useIke) // WSI_USE_IKE=1: the NSResponder-convenience route
        {
            this.interpretKeyEvents(NSArray.arrayWithObject(e));
            instr("interpret_key_events", "returned code=%u", e.keyCode());
            return;
        }
        // The real-app pattern (interpretKeyEvents: does the same internally): offer
        // the event to the input context; only if it declines run the key bindings.
        NSTextInputContext ctx = this.inputContext();
        immutable handled = ctx !is null && ctx.handleEvent(e);
        instr("handle_event", "ctx=%s handled=%d",
            ctx !is null ? "non-nil".ptr : "nil".ptr, handled ? 1 : 0);
        if (!handled)
            this.interpretKeyEvents(NSArray.arrayWithObject(e));
    }

    // --- NSTextInputClient -------------------------------------------------------

    void insertTextRR(NSObject s, NSRange repl) @selector("insertText:replacementRange:")
    {
        char[48] rb;
        NSString str = stringOf(s);
        instr("tic_insert_text", "text=%s class=%s repl=%s",
            u8(str), s !is null ? s.objcClass().name : "<nil>", rs(repl, rb));
        size_t loc = g_caret, del = 0;
        if (g_hasMarked)
        {
            loc = g_markedLoc; // insert replaces the pending marked text
            clearMarked();
        }
        else if (repl.location != NSNotFound)
        {
            loc = cast(size_t) repl.location;
            del = cast(size_t) repl.length;
        }
        spliceCommitted(loc, del, str);
        g_caret = loc + nsLen(str);
        logState("insert");
        this.setNeedsDisplay(true);
    }

    // Legacy pre-NSTextInputClient sink — with conformance attached this must go dead
    // (in f06, without conformance, ALL text landed here).
    void insertTextLegacy(NSObject s) @selector("insertText:")
    {
        instr("insert_text_legacy", "text=%s", u8(stringOf(s)));
    }

    void setMarkedTextSR(NSObject s, NSRange sel, NSRange repl)
        @selector("setMarkedText:selectedRange:replacementRange:")
    {
        char[48] rb1, rb2;
        NSString str = stringOf(s);
        instr("tic_set_marked_text", "text=%s class=%s sel=%s repl=%s",
            u8(str), s !is null ? s.objcClass().name : "<nil>", rs(sel, rb1), rs(repl, rb2));
        if (!g_hasMarked)
            g_markedLoc = repl.location != NSNotFound ? cast(size_t) repl.location : g_caret;
        g_markedLen = nsLen(str);
        foreach (i; 0 .. g_markedLen)
            g_marked[i] = str.characterAtIndex(i);
        g_hasMarked = g_markedLen > 0; // an empty string unmarks per the protocol docs
        g_selInMarked = sel;
        logState("set_marked");
        this.setNeedsDisplay(true);
    }

    void unmarkText() @selector("unmarkText")
    {
        instr("tic_unmark_text", "marked_len=%zu note=committing_pending_text", g_markedLen);
        // Per the protocol: accept the marked text as if it had been inserted normally.
        if (g_hasMarked)
        {
            spliceUtf16(g_markedLoc, 0, g_marked[0 .. g_markedLen]);
            g_caret = g_markedLoc + g_markedLen;
            clearMarked();
        }
        logState("unmark");
        this.setNeedsDisplay(true);
    }

    NSRange selectedRange() @selector("selectedRange")
    {
        NSRange r = g_hasMarked
            ? NSRange(g_markedLoc + g_selInMarked.location, g_selInMarked.length)
            : NSRange(g_caret, 0);
        char[48] rb;
        instr("tic_selected_range", "-> %s", rs(r, rb));
        return r;
    }

    NSRange markedRange() @selector("markedRange")
    {
        NSRange r = g_hasMarked ? NSRange(g_markedLoc, g_markedLen) : NSRange(NSNotFound, 0);
        char[48] rb;
        instr("tic_marked_range", "-> %s", rs(r, rb));
        return r;
    }

    bool hasMarkedText() @selector("hasMarkedText")
    {
        instr("tic_has_marked_text", "-> %d", g_hasMarked ? 1 : 0);
        return g_hasMarked;
    }

    NSAttributedString attributedSubstring(NSRange range, NSRange* actual)
        @selector("attributedSubstringForProposedRange:actualRange:")
    {
        immutable total = docLen();
        size_t loc = range.location > total ? total : cast(size_t) range.location;
        size_t len = loc + range.length > total ? total - loc : cast(size_t) range.length;
        ushort[256] tmp;
        foreach (i; 0 .. len)
            tmp[i] = docCharAt(loc + i);
        if (actual !is null)
            *actual = NSRange(loc, len);
        char[48] rb;
        instr("tic_attributed_substring", "range=%s actual={%zu,%zu}", rs(range, rb), loc, len);
        NSString sub = NSString.alloc().initWithCharacters(tmp.ptr, len);
        return NSAttributedString.alloc().initWithString(sub);
    }

    NSArray validAttributesForMarkedText() @selector("validAttributesForMarkedText")
    {
        instr("tic_valid_attributes", "-> empty");
        return NSArray.array();
    }

    // The candidate-window anchor: the IME asks for the on-screen rect of a character
    // range; the answer must be in SCREEN coordinates. Logged on every call — this is
    // how a candidate window follows the caret.
    NSRect firstRect(NSRange range, NSRange* actual)
        @selector("firstRectForCharacterRange:actualRange:")
    {
        immutable total = docLen();
        size_t loc = range.location == NSNotFound || range.location > total
            ? g_caret : cast(size_t) range.location;
        immutable len = range.length == 0 ? 1 : cast(size_t) range.length;
        immutable viewRect = NSRect(NSPoint(textX + cellW * loc, baseY),
            NSSize(cellW * len, cellH));
        immutable winRect = this.convertRect(viewRect, null);
        immutable scr = g_win.convertRectToScreen(winRect);
        if (actual !is null)
            *actual = NSRange(loc, range.length);
        char[48] rb;
        instr("tic_first_rect", "range=%s view=(%.0f,%.0f %.0fx%.0f) screen=(%.0f,%.0f %.0fx%.0f)",
            rs(range, rb), viewRect.origin.x, viewRect.origin.y,
            viewRect.size.width, viewRect.size.height, scr.origin.x, scr.origin.y,
            scr.size.width, scr.size.height);
        return scr;
    }

    ulong characterIndexForPoint(NSPoint screenPoint) @selector("characterIndexForPoint:")
    {
        immutable winRect = g_win.convertRectFromScreen(
            NSRect(screenPoint, NSSize(0, 0)));
        immutable vp = this.convertPoint(winRect.origin, null);
        immutable double rel = (vp.x - textX) / cellW;
        immutable total = docLen();
        size_t idx = rel < 0 ? 0 : cast(size_t) rel;
        if (idx > total)
            idx = total;
        instr("tic_character_index", "screen=(%.0f,%.0f) view_x=%.1f -> %zu",
            screenPoint.x, screenPoint.y, vp.x, idx);
        return idx;
    }

    void doCommandBySelector(SEL sel) @selector("doCommandBySelector:")
    {
        instr("do_command", "selector=%s has_marked=%d", sel.name, g_hasMarked ? 1 : 0);
    }

    // --- rendering: committed cells gray, marked cells blue with an underline -----
    // (Text is rendered as colored character cells, not glyphs — the locked-screen
    // A[ssh] session composites nothing anyway; the marked/committed distinction and
    // the underline are what F07 requires to be visible in the model.)

    void drawRect(NSRect dirty) @selector("drawRect:")
    {
        void* ctx = NSGraphicsContext.currentContext().CGContext();
        CGContextSetRGBFillColor(ctx, 0.12, 0.12, 0.14, 1);
        CGContextFillRect(ctx, this.bounds());
        immutable total = docLen();
        foreach (i; 0 .. total)
        {
            immutable marked = g_hasMarked && i >= g_markedLoc && i < g_markedLoc + g_markedLen;
            immutable x = textX + cellW * i;
            if (marked)
            {
                CGContextSetRGBFillColor(ctx, 0.35, 0.55, 0.95, 1); // marked: blue cell
                CGContextFillRect(ctx, NSRect(NSPoint(x, baseY), NSSize(cellW - 1, cellH)));
                CGContextSetRGBFillColor(ctx, 1, 1, 1, 1); // + 2 pt underline
                CGContextFillRect(ctx, NSRect(NSPoint(x, baseY - 3), NSSize(cellW - 1, 2)));
            }
            else
            {
                CGContextSetRGBFillColor(ctx, 0.7, 0.7, 0.7, 1); // committed: gray cell
                CGContextFillRect(ctx, NSRect(NSPoint(x, baseY), NSSize(cellW - 1, cellH)));
            }
        }
        // caret: 1 pt vertical bar at the insertion point (display position)
        immutable caretDisp = g_hasMarked ? g_markedLoc + g_markedLen : g_caret;
        CGContextSetRGBFillColor(ctx, 1, 0.85, 0.3, 1);
        CGContextFillRect(ctx, NSRect(NSPoint(textX + cellW * caretDisp, baseY - 1),
            NSSize(1, cellH + 2)));
    }

    void windowWillClose(NSObject notification) @selector("windowWillClose:")
    {
        instr("close_requested");
        g_app.stop(null);
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
enum ulong NSEventModifierFlagOption = 1UL << 19;

// Single-line editor cell metrics (points; also the firstRect/characterIndex math).
enum double textX = 10, baseY = 20, cellW = 9, cellH = 16;

// --- Demo state -------------------------------------------------------------------

__gshared NSApplication g_app;
__gshared NSWindow g_win;
__gshared TextView g_view;
__gshared PlainView g_plain;
__gshared long g_winNum;
__gshared int g_step;
__gshared void* g_cgSrc; // private CGEventSource: owns dead-key state for route 2
__gshared bool g_useIke; // WSI_USE_IKE=1: interpretKeyEvents: instead of handleEvent:

__gshared ushort[512] g_text; // committed text, UTF-16 units
__gshared size_t g_textLen;
__gshared size_t g_caret;
__gshared ushort[64] g_marked; // pending (pre-edit) text, rendered inline at g_markedLoc
__gshared size_t g_markedLoc, g_markedLen;
__gshared bool g_hasMarked;
__gshared NSRange g_selInMarked;

size_t nsLen(NSString s)
{
    return s is null ? 0 : cast(size_t) s.length();
}

const(char)* u8(NSString s)
{
    return s is null ? "<nil>" : s.UTF8String();
}

// The `id` params of insertText:/setMarkedText: are NSString OR NSAttributedString.
NSString stringOf(NSObject s)
{
    if (s is null)
        return null;
    if (s.respondsToSelector(SEL.register("string")))
        return (cast(NSAttributedString) s).string();
    return cast(NSString) s;
}

const(char)* rs(in NSRange r, char[] buf)
{
    if (r.location == NSNotFound)
        snprintf(buf.ptr, buf.length, "{NSNotFound,%llu}", r.length);
    else
        snprintf(buf.ptr, buf.length, "{%llu,%llu}", r.location, r.length);
    return buf.ptr;
}

void clearMarked()
{
    g_hasMarked = false;
    g_markedLen = 0;
    g_selInMarked = NSRange(0, 0);
}

void spliceUtf16(size_t loc, size_t del, scope const(ushort)[] ins)
{
    if (loc > g_textLen)
        loc = g_textLen;
    if (loc + del > g_textLen)
        del = g_textLen - loc;
    immutable newLen = g_textLen - del + ins.length;
    if (newLen > g_text.length)
        return;
    // shift the tail (forward iteration for a left shift, reverse for a right shift)
    if (ins.length < del)
        foreach (i; 0 .. g_textLen - loc - del)
            g_text[loc + ins.length + i] = g_text[loc + del + i];
    else if (ins.length > del)
        foreach_reverse (i; 0 .. g_textLen - loc - del)
            g_text[loc + ins.length + i] = g_text[loc + del + i];
    foreach (i, u; ins)
        g_text[loc + i] = u;
    g_textLen = newLen;
}

void spliceCommitted(size_t loc, size_t del, NSString s)
{
    ushort[128] tmp;
    immutable n = nsLen(s) > tmp.length ? tmp.length : nsLen(s);
    foreach (i; 0 .. n)
        tmp[i] = s.characterAtIndex(i);
    spliceUtf16(loc, del, tmp[0 .. n]);
}

size_t docLen()
{
    return g_textLen + (g_hasMarked ? g_markedLen : 0);
}

ushort docCharAt(size_t i)
{
    if (!g_hasMarked || i < g_markedLoc)
        return g_text[i];
    if (i < g_markedLoc + g_markedLen)
        return g_marked[i - g_markedLoc];
    return g_text[i - g_markedLen];
}

// BMP-only UTF-16 -> UTF-8 (enough for ASCII/é/´); writes a NUL-terminated C string.
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

void logState(const(char)* at)
{
    char[1600] cb;
    char[256] mb;
    utf16ToUtf8(g_text.ptr, g_textLen, cb.ptr);
    utf16ToUtf8(g_marked.ptr, g_markedLen, mb.ptr);
    instr("state", "at=%s text=\"%s\" caret=%zu marked=\"%s\" marked_at=%zu",
        at, cb.ptr, g_caret, mb.ptr, g_markedLoc);
}

// --- Synthetic key injection (f06 route 1) ----------------------------------------

struct KeySpec
{
    ushort code;
    ulong flags;
    string chars;
    string charsNoMod;
    string label;
}

immutable KeySpec optE = KeySpec(14, NSEventModifierFlagOption, "´", "e", "opt_e_deadacute");

void inject(in KeySpec k)
{
    instr("inject", "route=nsevent label=%.*s code=%u",
        cast(int) k.label.length, k.label.ptr, k.code);
    NSString ch = NSString.alloc().initWithUTF8String(k.chars.ptr);
    NSString cm = NSString.alloc().initWithUTF8String(k.charsNoMod.ptr);
    g_win.sendEvent(NSEvent.keyEventWithType(NSEventTypeKeyDown, NSPoint(0, 0), k.flags,
        0, g_winNum, null, ch, cm, false, k.code));
    g_win.sendEvent(NSEvent.keyEventWithType(NSEventTypeKeyUp, NSPoint(0, 0), k.flags,
        0, g_winNum, null, ch, cm, false, k.code));
}

// Route 2: CGEvent-backed NSEvent, dispatched in-process to the view's keyDown:
// (never posted to the WindowServer). The shared private source keeps dead-key state
// across calls, and the wrapped NSEvent carries a real event ref for TSM.
void injectCG(ushort code, ulong flags, const(char)* label)
{
    void* down = CGEventCreateKeyboardEvent(g_cgSrc, code, true);
    if (down is null)
    {
        instr("inject", "route=cgevent_wrap label=%s result=create_failed", label);
        return;
    }
    if (flags != 0)
        CGEventSetFlags(down, flags);
    NSEvent e = NSEvent.eventWithCGEvent(down);
    NSString txt = e !is null ? e.characters() : null;
    instr("inject", "route=cgevent_wrap label=%s code=%u wrapped_type=%ld wrapped_text=%s",
        label, code, e !is null ? e.type() : -1, txt !is null ? txt.UTF8String() : "<nil>");
    if (e !is null)
        g_view.keyDown(e);
    CFRelease(down);
}

void stopApp()
{
    instr("step", "name=NSApp_stop");
    g_app.stop(null);
    NSEvent ev = NSEvent.otherEventWithType(NSEventTypeApplicationDefined,
        NSPoint(0, 0), 0, 0, 0, null, 0, 0, 0);
    g_app.postEvent(ev, true); // stop: is only checked after an event dispatch
}

void onStep()
{
    switch (g_step)
    {
    case 0: // a. plain text — which insertText variant fires WITH conformance?
        inject(KeySpec(4, 0, "h", "h", "letter_h"));
        break;
    case 1:
        inject(KeySpec(34, 0, "i", "i", "letter_i"));
        break;
    case 2: // b1. dead key as a plain synthetic NSEvent (the f06 verbatim path)
        inject(optE);
        break;
    case 3:
        inject(KeySpec(14, 0, "e", "e", "letter_e_after_dead"));
        break;
    case 4: // b2. dead key as a CGEvent-backed NSEvent: does TSM compose now?
        injectCG(14, kCGEventFlagMaskAlternate, "opt_e_deadacute");
        break;
    case 5:
        injectCG(14, 0, "letter_e_compose");
        break;
    case 6: // c. cancel mid-composition with Esc
        injectCG(14, kCGEventFlagMaskAlternate, "opt_e_deadacute");
        break;
    case 7:
        injectCG(53, 0, "escape_mid_composition");
        break;
    case 8: // d. focus loss mid-composition
        injectCG(14, kCGEventFlagMaskAlternate, "opt_e_deadacute");
        break;
    case 9:
        instr("step", "name=focus_steal target=PlainView has_marked=%d", g_hasMarked ? 1 : 0);
        g_win.makeFirstResponder(g_plain);
        break;
    case 10:
        instr("step", "name=focus_restore target=TextView");
        g_win.makeFirstResponder(g_view);
        break;
    case 11: // e. replacementRange semantics: replace committed chars {0,2} directly
        instr("step", "name=direct_insert_replacement text=X repl={0,2}");
        g_view.insertTextRR(NSString.alloc().initWithUTF8String("X"), NSRange(0, 2));
        break;
    case 12: // f. the candidate-anchor math at both ends of the line
    {
        instr("step", "name=direct_first_rect at=start_and_caret");
        NSRange actual;
        g_view.firstRect(NSRange(0, 1), &actual);
        immutable r = g_view.firstRect(NSRange(g_caret, 1), &actual);
        g_view.characterIndexForPoint(r.origin); // round-trip the anchor point
        break;
    }
    default:
        stopApp();
        break;
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

// Attach the AppKit-registered NSTextInputClient protocol to the D-defined class at
// runtime. AppKit gates the whole IME path on conformsToProtocol: — implementing the
// methods alone is not enough for -[NSView inputContext] to create an input context.
void attachProtocol(TextView probe)
{
    Class cls = Class.lookup("TextView");
    if (cls.ptr is null)
        cls = probe.objcClass(); // D may emit a mangled runtime name; ask the instance
    Protocol proto = Protocol.get("NSTextInputClient");
    instr("protocol_attach", "class=%s protocol_found=%d conforms_before=%d",
        cls.name, proto.ptr !is null ? 1 : 0, cls.conformsTo(proto) ? 1 : 0);
    if (proto.ptr is null)
        return;
    immutable added = cls.addProtocol(proto);
    instr("protocol_attach", "added=%d conforms_after=%d", added ? 1 : 0,
        cls.conformsTo(proto) ? 1 : 0);
}

int main()
{
    immutable autoExit = getenv("WSI_AUTO_EXIT") !is null;
    g_useIke = getenv("WSI_USE_IKE") !is null;
    immutable noActivate = getenv("WSI_NO_ACTIVATE") !is null;
    instrInit("APPKIT_F07");
    instr("init_start", "auto_exit=%d use_ike=%d no_activate=%d",
        autoExit ? 1 : 0, g_useIke ? 1 : 0, noActivate ? 1 : 0);

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

    immutable contentRect = NSRect(NSPoint(120, 120), NSSize(480, 120));
    g_win = NSWindow.alloc().initWithContentRect(contentRect,
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable,
        NSBackingStoreBuffered, false);
    g_win.setTitle(NSString.alloc().initWithUTF8String("wsi-f07-text-input"));

    g_view = TextView.alloc().initWithFrame(contentRect);
    g_plain = PlainView.alloc().initWithFrame(NSRect(NSPoint(0, 0), NSSize(10, 10)));

    // Conformance dance BEFORE first-responder setup, so the input context is created
    // against a conforming class.
    attachProtocol(g_view);

    g_win.setContentView(g_view);
    g_win.setDelegate(g_view);
    g_win.makeKeyAndOrderFront(null);
    g_app.activateIgnoringOtherApps(true);
    g_win.makeFirstResponder(g_view);
    g_winNum = g_win.windowNumber();

    // The inputContext split: conforming view gets one, plain view does not.
    NSTextInputContext ctx = g_view.inputContext();
    instr("input_context", "view=TextView ctx=%s",
        ctx !is null ? "non-nil".ptr : "nil".ptr);
    instr("input_context", "view=PlainView ctx=%s",
        g_plain.inputContext() !is null ? "non-nil".ptr : "nil".ptr);
    if (ctx !is null)
    {
        NSString src = ctx.selectedKeyboardInputSource();
        instr("input_context", "selected_source=%s",
            src !is null ? src.UTF8String() : "<nil>");
        if (!noActivate)
        {
            ctx.activate(); // force TSM activation (normally done on app activation)
            src = ctx.selectedKeyboardInputSource();
            instr("input_context", "after_activate selected_source=%s",
                src !is null ? src.UTF8String() : "<nil>");
        }
    }
    instr("window_created", "win_num=%ld first_responder=TextView", g_winNum);

    g_cgSrc = CGEventSourceCreate(kCGEventSourceStatePrivate);
    instr("cg_source", "state=private created=%d", g_cgSrc !is null ? 1 : 0);

    if (autoExit)
    {
        StepTarget target = StepTarget.alloc().init();
        instr("step", "name=script_timer_start interval_ms=250");
        NSTimer.scheduledTimerWithTimeInterval(0.25, target, SEL.register("step:"),
            null, true);
    }

    instr("step", "name=NSApp_run");
    g_app.run();

    instr("loop_exit", "steps=%d", g_step);
    return 0;
}
