// X11 F07 demo — IME / text input via XIM (../../../features/f07-text-input.md).
// Built on the scaffold (../scaffold/app.d): same ImportC binding style, same
// poll(2)-driven readiness loop, same instrument.d event log.
//
// An editable line with a visible caret, rendered as colored block cells
// (committed = colored blocks, pre-edit = gray blocks + underline, caret =
// black bar; the *real* strings go to the log). On top of that, the full XIM
// bring-up with every pathology instrumented:
//
//   * Locale coupling: setlocale(LC_ALL, "") -> XSupportsLocale ->
//     XSetLocaleModifiers("") are all logged — run with LC_ALL=C vs C.UTF-8
//     (the run.sh driver does) to watch the IM stack degrade.
//   * XOpenIM timed (for the XMODIFIERS=@im=nonexistent measurement), the
//     offered style list dumped, and the negotiated style logged after a
//     preference walk: PreeditPosition -> PreeditCallbacks -> PreeditNothing
//     -> PreeditNone (WSI_XIM_STYLE=callbacks|nothing reorders it).
//   * The XFilterEvent gate: EVERY event passes through it first; swallowed
//     events are logged `filtered type=… keycode=…` so the IM's appetite is
//     visible.
//   * Xutf8LookupString in the key path; XNSpotLocation re-reported on every
//     caret move (over-the-spot candidate anchoring); preedit callbacks
//     (start/draw/caret/done) implemented for the on-the-spot style.
//   * XNDestroyCallback on the IM + XRegisterIMInstantiateCallback on the
//     display: an IM server starting *after* the demo (or dying under it) is
//     observed live — flags set in the callbacks, reopened from the loop.
//
// Without an IM (XOpenIM failed and nothing instantiated) the demo falls
// back to XLookupString and keeps running. WSI_AUTO_EXIT=1 bounds the run
// (WSI_DURATION_MS, default 10 s). Headless-safe: no X server -> prints
// `SKIP:` and exits 0. Findings: ../../f07-text-input.md.
module app;

import c; // ImportC: Xlib + Xutil (XIM lives in libX11 proper) + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.locale : LC_ALL, setlocale;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : memmove, strlen;

// ---------------------------------------------------------------------------
// Constants Xlib exposes as macros that ImportC cannot import; re-declared
// per the scaffold gotcha. The XN* "names" are string macros in Xlib.h.

enum : c_long
{
    KeyPressMask = 1L << 0,
    KeyReleaseMask = 1L << 1,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
    FocusChangeMask = 1L << 21,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    KeyRelease = 3,
    FocusIn = 9,
    FocusOut = 10,
    Expose = 12,
    MapNotify = 19,
    ConfigureNotify = 22,
    ClientMessage = 33,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum ZPixmap = 2;
enum RevertToParent = 2;
enum CurrentTime = 0;

enum : c_ulong // XIMStyle bits (Xlib.h macros)
{
    XIMPreeditArea = 0x0001,
    XIMPreeditCallbacks = 0x0002,
    XIMPreeditPosition = 0x0004,
    XIMPreeditNothing = 0x0008,
    XIMPreeditNone = 0x0010,
    XIMStatusArea = 0x0100,
    XIMStatusCallbacks = 0x0200,
    XIMStatusNothing = 0x0400,
    XIMStatusNone = 0x0800,
}

enum // Xutf8LookupString status (Xlib.h macros)
{
    XBufferOverflow = -1,
    XLookupNone = 1,
    XLookupChars = 2,
    XLookupKeySym = 3,
    XLookupBoth = 4,
}

enum // keysyms the editor reacts to (keysymdef.h macros)
{
    XK_BackSpace = 0xff08,
    XK_Return = 0xff0d,
    XK_Escape = 0xff1b,
    XK_Left = 0xff51,
    XK_Right = 0xff53,
}

// XN* argument names (string macros in Xlib.h).
immutable XNQueryInputStyle = "queryInputStyle";
immutable XNClientWindow = "clientWindow";
immutable XNInputStyle = "inputStyle";
immutable XNFocusWindow = "focusWindow";
immutable XNPreeditAttributes = "preeditAttributes";
immutable XNSpotLocation = "spotLocation";
immutable XNFontSet = "fontSet";
immutable XNFilterEvents = "filterEvents";
immutable XNDestroyCallback = "destroyCallback";
immutable XNPreeditStartCallback = "preeditStartCallback";
immutable XNPreeditDoneCallback = "preeditDoneCallback";
immutable XNPreeditDrawCallback = "preeditDrawCallback";
immutable XNPreeditCaretCallback = "preeditCaretCallback";

// ---------------------------------------------------------------------------
// The editable line: committed text + pre-edit, both as arrays of UTF-8
// codepoint cells (block-cell rendering; the log carries the real bytes).

enum MaxCells = 120;

struct CellLine
{
    char[8][MaxCells] cells;
    ubyte[MaxCells] len;
    int count, caret;

    void insert(const(char)* bytes, int n) @nogc nothrow
    {
        int i = 0;
        while (i < n && count < MaxCells)
        {
            int cl = 1; // codepoint length from the UTF-8 lead byte
            while (i + cl < n && (bytes[i + cl] & 0xc0) == 0x80)
                ++cl;
            if (cl > 8)
                cl = 8;
            memmove(&cells[caret + 1], &cells[caret], (count - caret) * 8);
            memmove(&len[caret + 1], &len[caret], count - caret);
            cells[caret][0 .. cl] = bytes[i .. i + cl];
            len[caret] = cast(ubyte) cl;
            ++count;
            ++caret;
            i += cl;
        }
    }

    void remove(int first, int n) @nogc nothrow
    {
        if (first < 0 || first >= count)
            return;
        if (first + n > count)
            n = count - first;
        memmove(&cells[first], &cells[first + n], (count - first - n) * 8);
        memmove(&len[first], &len[first + n], count - first - n);
        count -= n;
        if (caret > count)
            caret = count;
    }

    /// NUL-terminated concatenation, for the log.
    const(char)* str(return ref char[1024] buf) @nogc nothrow
    {
        size_t o;
        foreach (i; 0 .. count)
        {
            buf[o .. o + len[i]] = cells[i][0 .. len[i]];
            o += len[i];
        }
        buf[o] = '\0';
        return buf.ptr;
    }
}

// ---------------------------------------------------------------------------
// Shared state the XIM callbacks mutate (single-threaded demo; the callbacks
// run inside XFilterEvent/XPending on this thread).

__gshared CellLine g_text; // committed
__gshared CellLine g_pre; // pre-edit (PreeditCallbacks style only)
__gshared bool g_imDestroyed, g_imInstantiated, g_dirty;
__gshared int g_preeditDraws;

extern (C) int preeditStart(XIC ic, XPointer client, XPointer call) @nogc nothrow
{
    emit("preedit_start (returning -1: no length limit)");
    return -1;
}

extern (C) void preeditDone(XIC ic, XPointer client, XPointer call) @nogc nothrow
{
    emit("preedit_done");
    g_pre.count = 0;
    g_pre.caret = 0;
    g_dirty = true;
}

extern (C) void preeditDraw(XIC ic, XPointer client,
    XIMPreeditDrawCallbackStruct* call) @nogc nothrow
{
    ++g_preeditDraws;
    const mb = xim_text_mb(call.text);
    emitf("preedit_draw", "caret=%d chg_first=%d chg_length=%d text=%s",
        call.caret, call.chg_first, call.chg_length,
        mb !is null ? mb : "(null)".ptr);
    // Replace [chg_first, chg_first+chg_length) with the new text (the XIM
    // delta protocol; text==null means pure deletion).
    g_pre.remove(call.chg_first, call.chg_length);
    if (mb !is null)
    {
        g_pre.caret = call.chg_first;
        g_pre.insert(mb, cast(int) strlen(mb));
    }
    g_pre.caret = call.caret;
    char[1024] buf;
    emitf("preedit_state", "text=%s caret=%d", g_pre.str(buf), g_pre.caret);
    g_dirty = true;
}

extern (C) void preeditCaret(XIC ic, XPointer client,
    XIMPreeditCaretCallbackStruct* call) @nogc nothrow
{
    emitf("preedit_caret", "position=%d direction=%d style=%d",
        call.position, call.direction, call.style);
    g_pre.caret = call.position;
    g_dirty = true;
}

extern (C) void imDestroyed(XIM im, XPointer client, XPointer call) @nogc nothrow
{
    // The IM server died. The XIM and all its XICs are already invalid —
    // using (or closing) them is a use-after-free; just forget them.
    emit("im_destroyed (XIM and XICs now invalid; must NOT XCloseIM)");
    g_imDestroyed = true;
}

extern (C) void imInstantiated(Display* dpy, XPointer client, XPointer call) @nogc nothrow
{
    // An IM matching the locale modifiers just became available (e.g. an IM
    // server started after us, or the built-in IM at registration time).
    emit("im_instantiated");
    g_imInstantiated = true;
}

// ---------------------------------------------------------------------------
// XIM bring-up: style negotiation + IC creation, every step logged.

const(char)* styleName(c_ulong s, return ref char[64] buf) @nogc nothrow
{
    import core.stdc.stdio : snprintf;

    const(char)* pre = (s & XIMPreeditPosition) ? "Position"
        : (s & XIMPreeditCallbacks) ? "Callbacks" : (s & XIMPreeditArea) ? "Area"
        : (s & XIMPreeditNothing) ? "Nothing" : (s & XIMPreeditNone) ? "None" : "?";
    const(char)* st = (s & XIMStatusCallbacks) ? "Callbacks"
        : (s & XIMStatusArea) ? "Area"
        : (s & XIMStatusNothing) ? "Nothing" : (s & XIMStatusNone) ? "None" : "?";
    snprintf(buf.ptr, buf.length, "Preedit%s|Status%s", pre, st);
    return buf.ptr;
}

struct Im
{
    XIM im;
    XIC ic;
    c_ulong style;
    c_long filterMask;
}

/// XOpenIM (timed) + destroy callback + style query/negotiation + XCreateIC.
/// Returns im=null when no IM is reachable for the current locale modifiers.
Im openInputMethod(Display* dpy, Window win, XFontSet fs, ref XPoint spot) nothrow
{
    Im r;
    const t0 = nowUs();
    r.im = XOpenIM(dpy, null, null, null);
    emitf("step", "name=XOpenIM ok=%d took_us=%lld", cast(int)(r.im !is null),
        nowUs() - t0);
    if (r.im is null)
        return r;

    static XIMCallback destroyCb; // must outlive the IM
    destroyCb.client_data = null;
    destroyCb.callback = cast(XIMProc)&imDestroyed;
    const dcErr = XSetIMValues(r.im, XNDestroyCallback.ptr, &destroyCb, null);
    emitf("step", "name=XSetIMValues destroy_callback=%s",
        dcErr is null ? "registered".ptr : dcErr);

    // What the IM offers, verbatim.
    XIMStyles* styles;
    char[64] nm;
    if (XGetIMValues(r.im, XNQueryInputStyle.ptr, &styles, null) !is null
        || styles is null)
    {
        emit("step name=XGetIMValues queryInputStyle=FAILED");
        return r;
    }
    foreach (i; 0 .. styles.count_styles)
        emitf("xim_style_offered", "style=0x%04lx name=%s",
            styles.supported_styles[i], styleName(styles.supported_styles[i], nm));

    // Preference walk (F07 spec: Position first, fall back through Nothing).
    const pref = getenv("WSI_XIM_STYLE");
    c_ulong[4] wanted = [
        XIMPreeditPosition | XIMStatusNothing,
        XIMPreeditCallbacks | XIMStatusNothing,
        XIMPreeditNothing | XIMStatusNothing,
        XIMPreeditNone | XIMStatusNone,
    ];
    if (pref !is null && pref[0] == 'c') // callbacks (on-the-spot) first
        wanted[0 .. 2] = [XIMPreeditCallbacks | XIMStatusNothing,
            XIMPreeditPosition | XIMStatusNothing];
    if (pref !is null && pref[0] == 'n') // nothing (root-window style) only
        wanted = [XIMPreeditNothing | XIMStatusNothing,
            XIMPreeditNone | XIMStatusNone, 0, 0];

    foreach (w; wanted)
    {
        bool offered = false;
        foreach (i; 0 .. styles.count_styles)
            offered |= styles.supported_styles[i] == w;
        if (w == 0 || !offered)
            continue;

        if (w & XIMPreeditPosition)
        {
            // Over-the-spot: the IM draws the pre-edit at XNSpotLocation
            // with XNFontSet; both are *required* create-time attributes.
            XVaNestedList plist = XVaCreateNestedList(0,
                XNSpotLocation.ptr, &spot, XNFontSet.ptr, fs, null);
            r.ic = XCreateIC(r.im, XNInputStyle.ptr, w,
                XNClientWindow.ptr, win, XNFocusWindow.ptr, win,
                XNPreeditAttributes.ptr, plist, null);
            XFree(plist);
        }
        else if (w & XIMPreeditCallbacks)
        {
            // On-the-spot: the app draws the pre-edit; the IM drives it
            // through these four callbacks.
            static XIMCallback startCb, doneCb, drawCb, caretCb;
            startCb.callback = cast(XIMProc)&preeditStart;
            doneCb.callback = cast(XIMProc)&preeditDone;
            drawCb.callback = cast(XIMProc)&preeditDraw;
            caretCb.callback = cast(XIMProc)&preeditCaret;
            XVaNestedList plist = XVaCreateNestedList(0,
                XNPreeditStartCallback.ptr, &startCb,
                XNPreeditDoneCallback.ptr, &doneCb,
                XNPreeditDrawCallback.ptr, &drawCb,
                XNPreeditCaretCallback.ptr, &caretCb, null);
            r.ic = XCreateIC(r.im, XNInputStyle.ptr, w,
                XNClientWindow.ptr, win, XNFocusWindow.ptr, win,
                XNPreeditAttributes.ptr, plist, null);
            XFree(plist);
        }
        else
            r.ic = XCreateIC(r.im, XNInputStyle.ptr, w,
                XNClientWindow.ptr, win, XNFocusWindow.ptr, win, null);

        if (r.ic !is null)
        {
            r.style = w;
            emitf("xim_style_negotiated", "style=0x%04lx name=%s", w,
                styleName(w, nm));
            break;
        }
        emitf("step", "name=XCreateIC style=0x%04lx FAILED (falling back)", w);
    }
    XFree(styles);
    if (r.ic is null)
        return r;

    // The IM may need events the app did not select (e.g. the built-in IM
    // wants KeyRelease for compose) — the app MUST add XNFilterEvents to its
    // own mask or XFilterEvent never sees them.
    XGetICValues(r.ic, XNFilterEvents.ptr, &r.filterMask, null);
    emitf("step", "name=XGetICValues filterEvents=0x%lx", r.filterMask);
    return r;
}

// ---------------------------------------------------------------------------
// Block-cell rendering: committed cells colored by codepoint, pre-edit cells
// gray with an underline, caret as a black bar. F07 req 1, sans fonts.

enum CellW = 14, CellH = 22, OriginX = 12, OriginY = 40;

void draw(XImage* img) @nogc nothrow
{
    const w = img.width, h = img.height;
    if (img.bits_per_pixel != 32)
        return;
    foreach (y; 0 .. h)
    {
        auto row = cast(uint*)(img.data + y * img.bytes_per_line);
        row[0 .. w] = 0xf0f0e8;
        if (y == 0 || y == h - 1)
            row[0 .. w] = 0;
        row[0] = 0;
        row[w - 1] = 0;
    }
    void cell(int i, uint color, bool underline)
    {
        const x0 = OriginX + i * CellW;
        if (x0 + CellW >= w)
            return;
        foreach (y; OriginY .. OriginY + CellH)
        {
            auto row = cast(uint*)(img.data + y * img.bytes_per_line);
            const ul = underline && y >= OriginY + CellH - 3;
            row[x0 + 1 .. x0 + CellW - 1] = ul ? 0x303030 : color;
        }
    }
    // committed │ pre-edit (inline at the caret) │ rest of committed
    int col = 0;
    foreach (i; 0 .. g_text.caret)
        cell(col++, 0x4060c0 + (g_text.cells[i][0] & 0x3f) * 0x300, false);
    const preStart = col;
    foreach (i; 0 .. g_pre.count)
        cell(col++, 0xb0b0b0, true);
    foreach (i; g_text.caret .. g_text.count)
        cell(col++, 0x4060c0 + (g_text.cells[i][0] & 0x3f) * 0x300, false);
    // caret bar (inside the pre-edit while composing)
    const cx = OriginX + (preStart + g_pre.caret) * CellW;
    foreach (y; OriginY - 2 .. OriginY + CellH + 2)
    {
        auto row = cast(uint*)(img.data + y * img.bytes_per_line);
        if (cx + 2 < w)
            row[cx .. cx + 2] = 0;
    }
}

int main()
{
    initInstrument("f07_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const envDur = getenv("WSI_DURATION_MS");
    const durationMs = envDur !is null ? atoi(envDur) : 10_000;

    // -- The locale coupling, step by step (F07's first pathology) ------------
    // XIM is the only input path in this tree whose availability depends on
    // the C runtime locale: XOpenIM consults it (and XMODIFIERS) at open time.
    const loc = setlocale(LC_ALL, "");
    emitf("step", "name=setlocale result=%s", loc !is null ? loc : "(failed)".ptr);
    const supported = XSupportsLocale();
    emitf("step", "name=XSupportsLocale supported=%d", supported);
    const mods = XSetLocaleModifiers("");
    emitf("step", "name=XSetLocaleModifiers result=%s XMODIFIERS=%s",
        mods !is null ? mods : "(failed)".ptr,
        getenv("XMODIFIERS") !is null ? getenv("XMODIFIERS") : "(unset)".ptr);

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy);
    Visual* visual = XDefaultVisual(dpy, screen);
    const depth = XDefaultDepth(dpy, screen);

    // -- Window ----------------------------------------------------------------
    int width = 640, height = 120;
    Window win = XCreateSimpleWindow(dpy, XRootWindow(dpy, screen), 0, 0,
        width, height, 1, XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F07 text input");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    enum c_long baseMask = KeyPressMask | KeyReleaseMask | ExposureMask
            | StructureNotifyMask | FocusChangeMask;
    XSelectInput(dpy, win, baseMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    // -- Fontset (required by XIMPreeditPosition) ------------------------------
    char** missing;
    int nMissing;
    char* defStr;
    XFontSet fs = XCreateFontSet(dpy,
        "-*-fixed-medium-r-normal--14-*-*-*-*-*-*-*,-*-*-*-*-*-*-14-*-*-*-*-*-*-*",
        &missing, &nMissing, &defStr);
    emitf("step", "name=XCreateFontSet ok=%d missing_charsets=%d",
        cast(int)(fs !is null), nMissing);
    if (missing !is null)
        XFreeStringList(missing);

    // -- IM lifecycle hooks, then the IM itself --------------------------------
    // Registered BEFORE XOpenIM so an IM server that starts later (fcitx5 in
    // the run.sh choreography) is announced; Xlib also fires it immediately
    // when an IM for the current modifiers is already reachable.
    XRegisterIMInstantiateCallback(dpy, null, null, null,
        cast(XIDProc)&imInstantiated, null);
    emit("step name=XRegisterIMInstantiateCallback");

    XPoint spot = XPoint(OriginX, cast(short)(OriginY + CellH)); // caret baseline
    Im im = openInputMethod(dpy, win, fs, spot);
    if (im.ic !is null && im.filterMask != 0)
        XSelectInput(dpy, win, baseMask | im.filterMask);

    GC gc = XDefaultGC(dpy, screen);
    import core.stdc.stdlib : malloc;

    XImage* img = XCreateImage(dpy, visual, cast(uint) depth, ZPixmap, 0,
        cast(char*) malloc(cast(size_t) width * height * 4),
        cast(uint) width, cast(uint) height, 32, 0);

    // -- Helpers bound to the loop's state -------------------------------------
    char[1024] lineBuf;
    void updateSpot()
    {
        if (im.ic is null || !(im.style & XIMPreeditPosition))
            return;
        spot.x = cast(short)(OriginX + g_text.caret * CellW);
        spot.y = cast(short)(OriginY + CellH);
        XVaNestedList plist = XVaCreateNestedList(0, XNSpotLocation.ptr, &spot, null);
        XSetICValues(im.ic, XNPreeditAttributes.ptr, plist, null);
        XFree(plist);
        emitf("spot", "x=%d y=%d (caret cell %d)", spot.x, spot.y, g_text.caret);
    }

    const fd = XConnectionNumber(dpy);
    bool running = true, focused = false;
    int commits = 0, filtered = 0, keyEvents = 0;
    g_dirty = true;

    while (running)
    {
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);

            // THE GATE. Every event — not just key events — must be offered
            // to the IM first; a True return means the IM swallowed it (it
            // becomes pre-edit fuel / compose state) and the app must NOT
            // process it. Skipping this breaks every XIM on earth.
            if (XFilterEvent(&ev, 0) == True)
            {
                ++filtered;
                if (ev.type == KeyPress || ev.type == KeyRelease)
                    emitf("filtered", "type=%s keycode=%u",
                        ev.type == KeyPress ? "KeyPress".ptr : "KeyRelease".ptr,
                        ev.xkey.keycode);
                else
                    emitf("filtered", "type=%d", ev.type);
                continue;
            }

            switch (ev.type)
            {
            case KeyPress:
                ++keyEvents;
                char[256] buf;
                KeySym sym = 0;
                int status = XLookupNone, n = 0;
                if (im.ic !is null)
                {
                    n = Xutf8LookupString(im.ic, &ev.xkey, buf.ptr,
                        cast(int) buf.length - 1, &sym, &status);
                }
                else // no IM at all: raw Latin-1 fallback path
                {
                    n = XLookupString(&ev.xkey, buf.ptr, cast(int) buf.length - 1,
                        &sym, null);
                    status = n > 0 ? XLookupBoth : XLookupKeySym;
                }
                buf[n] = '\0';
                emitf("lookup", "via=%s status=%d sym=0x%lx len=%d text=%s",
                    im.ic !is null ? "Xutf8LookupString".ptr : "XLookupString".ptr,
                    status, sym, n, buf.ptr);

                if ((status == XLookupChars || status == XLookupBoth) && n > 0)
                {
                    g_text.insert(buf.ptr, n);
                    ++commits;
                    emitf("commit", "text=%s line=%s caret=%d", buf.ptr,
                        g_text.str(lineBuf), g_text.caret);
                    updateSpot();
                    g_dirty = true;
                }
                if (status == XLookupKeySym || status == XLookupBoth)
                {
                    const old = g_text.caret;
                    if (sym == XK_BackSpace && g_text.caret > 0)
                        g_text.remove(--g_text.caret, 1);
                    else if (sym == XK_Left && g_text.caret > 0)
                        --g_text.caret;
                    else if (sym == XK_Right && g_text.caret < g_text.count)
                        ++g_text.caret;
                    else if (sym == XK_Return)
                    {
                        emitf("line_submitted", "text=%s", g_text.str(lineBuf));
                        g_text.count = 0;
                        g_text.caret = 0;
                    }
                    else if (sym == XK_Escape)
                        break; // reaches us only when the IM didn't want it
                    if (g_text.caret != old || sym == XK_BackSpace || sym == XK_Return)
                    {
                        emitf("caret", "cell=%d line=%s", g_text.caret,
                            g_text.str(lineBuf));
                        updateSpot();
                        g_dirty = true;
                    }
                }
                break;

            case KeyRelease:
                ++keyEvents;
                break;

            case MapNotify:
                // Bare Xvfb has no WM: self-focus so injected XTEST events
                // land here (same as the F06 demo).
                XSetInputFocus(dpy, win, RevertToParent, CurrentTime);
                XFlush(dpy);
                break;

            case FocusIn:
                focused = true;
                emit("focus state=in");
                if (im.ic !is null)
                    XSetICFocus(im.ic);
                break;

            case FocusOut:
                focused = false;
                emitf("focus", "state=out preedit_pending=%d", g_pre.count);
                if (im.ic !is null)
                    XUnsetICFocus(im.ic);
                break;

            case Expose:
                if (ev.xexpose.count == 0)
                    g_dirty = true;
                break;

            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
                    running = false;
                break;

            default:
                break;
            }
        }

        // IM lifecycle transitions signalled from the callbacks.
        if (g_imDestroyed)
        {
            g_imDestroyed = false;
            im = Im.init; // XIM/XIC are already freed by Xlib — just forget
            g_pre.count = 0;
            g_pre.caret = 0;
            g_dirty = true;
        }
        if (g_imInstantiated)
        {
            g_imInstantiated = false;
            if (im.im is null)
            {
                emit("step name=reopen_im (instantiate callback fired)");
                im = openInputMethod(dpy, win, fs, spot);
                if (im.ic !is null)
                {
                    if (im.filterMask != 0)
                        XSelectInput(dpy, win, baseMask | im.filterMask);
                    if (focused)
                        XSetICFocus(im.ic);
                    updateSpot();
                }
            }
        }

        if (g_dirty && img !is null)
        {
            draw(img);
            XPutImage(dpy, win, gc, img, 0, 0, 0, 0,
                cast(uint) width, cast(uint) height);
            XFlush(dpy);
            g_dirty = false;
        }

        if (autoExit && nowUs() > cast(long) durationMs * 1000)
        {
            emit("auto_exit");
            break;
        }

        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 100 : -1);
    }

    char[64] nm;
    emitf("summary", "im=%d style=%s commits=%d filtered=%d key_events=%d "
            ~ "preedit_draws=%d line=%s", cast(int)(im.im !is null),
        im.im !is null ? styleName(im.style, nm) : "(none)".ptr,
        commits, filtered, keyEvents, g_preeditDraws, g_text.str(lineBuf));

    if (im.ic !is null)
        XDestroyIC(im.ic);
    if (im.im !is null)
        XCloseIM(im.im);
    img.f.destroy_image(img);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
