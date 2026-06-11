// F16 X11 demo — clipboard + file drag-and-drop, both implemented by hand on
// the one mechanism X11 has for either: ICCCM selections
// (../../../features/f16-clipboard-dnd.md; findings in ../../f16-clipboard-dnd.md).
//
// Modes (--mode=..., default `dnd`):
//   copy       own CLIPBOARD (and PRIMARY — the one-line contrast), serve
//              TARGETS/TIMESTAMP/UTF8_STRING ('é漢🎈') to any requestor
//              (xclip -o); log every SelectionRequest; exit on SelectionClear
//   copy-incr  same with a 400 KiB payload -> INCR *sending* (the
//              property-delete-driven chunk choreography, logged per chunk)
//   paste      log the owner's TARGETS, then convert UTF8_STRING; a payload
//              above the owner's chunk limit arrives as INCR *receive*
//   dnd        XDND v5, BOTH SIDES in one process: this window is the target
//              (XdndAware); a second Display connection plays the source —
//              owns XdndSelection, Enter/Position, aborts once with Leave,
//              re-enters, Drops, serves text/uri-list through a normal
//              selection transfer, gets XdndFinished. (The CI default.)
//
// Headless-safe: no X server -> prints `SKIP:` and exits 0. WSI_AUTO_EXIT=1
// tightens the deadline so CI runs stay bounded. run.sh drives xclip passes.
module app;

import c; // ImportC: Xlib + Xutil + Xatom + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv, malloc;
import core.stdc.string : memcpy, strcmp, strlen;

// -- macro constants ImportC cannot export (cast-expression #defines) --------
enum : c_long
{
    PropertyChangeMask = 1L << 22,
    StructureNotifyMask = 1L << 17,
}

enum // XEvent.type discriminators
{
    PropertyNotify = 28, SelectionClear = 29, SelectionRequest = 30,
    SelectionNotify = 31, ClientMessage = 33,
}

enum { PropertyNewValue = 0, PropertyDelete = 1 }
enum { PropModeReplace = 0, PropModeAppend = 2 }
enum { None = 0, False = 0, True = 1, POLLIN = 0x001 }
enum Atom XA_PRIMARY = 1, XA_ATOM = 4, XA_INTEGER = 19, XA_STRING = 31;

enum size_t INCR_THRESHOLD = 256 * 1024; // own a bigger payload -> send INCR
enum size_t INCR_CHUNK = 64 * 1024; // bytes per INCR append
enum int XDND_VERSION = 5;

// -- small helpers ------------------------------------------------------------

/// Atom -> name for log lines (rotating static buffers so one emitf can hold 4).
const(char)* an(Display* dpy, Atom a) @nogc nothrow
{
    static char[64][4] bufs;
    static int next;
    if (a == None)
        return "None";
    auto buf = bufs[next & 3].ptr;
    next++;
    char* s = XGetAtomName(dpy, a);
    snprintf(buf, 64, "%s", s);
    XFree(s);
    return buf;
}

/// ICCCM-correct ownership timestamp: "A zero-length append to a property is
/// a way to obtain a timestamp for this purpose; the timestamp is in the
/// corresponding PropertyNotify event." (ICCCM § 2.1) — never CurrentTime.
Time serverTimestamp(Display* dpy, Window win) @nogc nothrow
{
    const prop = XInternAtom(dpy, "WSI_TIMESTAMP", False);
    XChangeProperty(dpy, win, prop, XA_STRING, 8, PropModeAppend, null, 0);
    for (;;)
    {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type == PropertyNotify && ev.xproperty.atom == prop)
            return ev.xproperty.time;
    }
}

/// Read a whole property (deleting it when `del`); returns malloc'd bytes.
ubyte* readProperty(Display* dpy, Window win, Atom prop, int del,
    out Atom type, out int format, out c_ulong nitems) @nogc nothrow
{
    Atom actualType;
    int actualFormat;
    c_ulong n, after;
    ubyte* data;
    XGetWindowProperty(dpy, win, prop, 0, 0x1FFFFFFF, del, AnyPropertyType,
        &actualType, &actualFormat, &n, &after, &data);
    type = actualType;
    format = actualFormat;
    nitems = n;
    return data; // caller XFree()s
}

enum Atom AnyPropertyType = 0;

// -- selection OWNER side -----------------------------------------------------
// One struct serves both the clipboard owner and the XDND source: on X11 the
// clipboard and DnD literally share the transfer machinery (the F16 finding).

struct SelOwner
{
    Display* dpy;
    Window win;
    Atom dataTarget; // UTF8_STRING (clipboard) or text/uri-list (XDND)
    const(ubyte)* data;
    size_t len;
    Time ts;
    Atom targetsAtom, timestampAtom, incrAtom;
    // active INCR send (at most one in this demo)
    Window incrRequestor;
    Atom incrProperty;
    size_t incrOffset;
    int incrChunks;
    bool incrActive;
}

/// Answer one SelectionRequest per ICCCM § 2.2: convert into the named
/// property on the requestor's window, then confirm with SelectionNotify
/// (property = None refuses). Payloads above INCR_THRESHOLD start an INCR
/// transfer (ICCCM § 2.7.2) instead of one giant ChangeProperty.
void handleSelectionRequest(ref SelOwner o, ref XSelectionRequestEvent req) @nogc nothrow
{
    emitf("clip_request", "requestor=0x%lx selection=%s target=%s property=%s",
        req.requestor, an(o.dpy, req.selection), an(o.dpy, req.target),
        an(o.dpy, req.property));

    // "If the specified property is None, the requestor is an obsolete
    // client. Owners are encouraged to support these clients by using the
    // specified target atom as the property name" (ICCCM § 2.2).
    Atom property = req.property == None ? req.target : req.property;

    if (req.target == o.targetsAtom)
    {
        Atom[3] targets = [o.targetsAtom, o.timestampAtom, o.dataTarget];
        XChangeProperty(o.dpy, req.requestor, property, XA_ATOM, 32,
            PropModeReplace, cast(ubyte*) targets.ptr, 3);
    }
    else if (req.target == o.timestampAtom)
    {
        c_long t = cast(c_long) o.ts;
        XChangeProperty(o.dpy, req.requestor, property, XA_INTEGER, 32,
            PropModeReplace, cast(ubyte*)&t, 1);
    }
    else if (req.target == o.dataTarget && o.len > INCR_THRESHOLD)
    {
        // INCR start: property of type INCR holding "a lower bound on the
        // number of bytes of data in the selection" (ICCCM § 2.7.2); we then
        // watch the requestor's window for the property *deletions* that
        // drive the chunk loop. Input masks are per-client, so selecting
        // PropertyChangeMask on a foreign window is legal.
        c_long bound = cast(c_long) o.len;
        XSelectInput(o.dpy, req.requestor, PropertyChangeMask);
        XChangeProperty(o.dpy, req.requestor, property, o.incrAtom, 32,
            PropModeReplace, cast(ubyte*)&bound, 1);
        o.incrRequestor = req.requestor;
        o.incrProperty = property;
        o.incrOffset = 0;
        o.incrChunks = 0;
        o.incrActive = true;
        emitf("clip_send", "bytes=%zu incr=1 phase=start lower_bound=%ld", o.len, bound);
    }
    else if (req.target == o.dataTarget)
    {
        XChangeProperty(o.dpy, req.requestor, property, o.dataTarget, 8,
            PropModeReplace, o.data, cast(int) o.len);
        emitf("clip_send", "bytes=%zu incr=0 target=%s", o.len, an(o.dpy, o.dataTarget));
    }
    else
    {
        property = None; // refuse: SelectionNotify with property None
        emitf("clip_send", "refused target=%s", an(o.dpy, req.target));
    }

    XEvent reply;
    reply.xselection.type = SelectionNotify;
    reply.xselection.display = req.display;
    reply.xselection.requestor = req.requestor;
    reply.xselection.selection = req.selection;
    reply.xselection.target = req.target;
    reply.xselection.property = property;
    reply.xselection.time = req.time;
    XSendEvent(o.dpy, req.requestor, False, 0, &reply);
    XFlush(o.dpy);
}

/// INCR chunk pump: each PropertyDelete from the requestor means "read,
/// send the next chunk"; a zero-length append terminates. Returns true when
/// the transfer just completed.
bool handleIncrDelete(ref SelOwner o, ref XPropertyEvent pev) @nogc nothrow
{
    if (!o.incrActive || pev.window != o.incrRequestor
        || pev.atom != o.incrProperty || pev.state != PropertyDelete)
        return false;
    const remaining = o.len - o.incrOffset;
    const n = remaining < INCR_CHUNK ? remaining : INCR_CHUNK;
    XChangeProperty(o.dpy, o.incrRequestor, o.incrProperty, o.dataTarget, 8,
        PropModeReplace, o.data + o.incrOffset, cast(int) n);
    XFlush(o.dpy);
    if (n == 0) // final zero-length chunk -> done
    {
        o.incrActive = false;
        emitf("clip_send", "bytes=%zu incr=1 phase=done chunks=%d", o.len, o.incrChunks);
        return true;
    }
    o.incrOffset += n;
    o.incrChunks++;
    emitf("incr_chunk", "n=%d bytes=%zu offset=%zu", o.incrChunks, n, o.incrOffset);
    return false;
}

// -- selection REQUESTOR side ---------------------------------------------------

/// Fetch one conversion result (the property a SelectionNotify named),
/// following the INCR receive loop when the type is INCR: delete the INCR
/// property to start, then GetProperty(delete=True) on each PropertyNewValue
/// until a zero-length chunk (ICCCM § 2.7.2). Returns total bytes.
size_t fetchConverted(Display* dpy, Window win, Atom prop, Atom incrAtom,
    ubyte* outBuf, size_t outCap, out bool wasIncr, out int chunks) @nogc nothrow
{
    Atom type;
    int format;
    c_ulong nitems;
    ubyte* data = readProperty(dpy, win, prop, True, type, format, nitems);
    if (type != incrAtom)
    {
        wasIncr = false;
        chunks = 0;
        const n = cast(size_t) nitems;
        if (data !is null && outBuf !is null && n <= outCap)
            memcpy(outBuf, data, n);
        if (data !is null)
            XFree(data);
        return n;
    }
    // INCR: the GetProperty(delete=True) above performed the ICCCM "starts
    // the transfer process by deleting the (type==INCR) property".
    const bound = data !is null && nitems >= 1 ? *cast(c_long*) data : 0;
    if (data !is null)
        XFree(data);
    emitf("paste_incr", "phase=start lower_bound=%ld", bound);
    wasIncr = true;
    chunks = 0;
    size_t total = 0;
    for (;;)
    {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type != PropertyNotify || ev.xproperty.atom != prop
            || ev.xproperty.state != PropertyNewValue)
            continue;
        ubyte* chunk = readProperty(dpy, win, prop, True, type, format, nitems);
        const n = cast(size_t) nitems;
        if (chunk !is null)
        {
            if (outBuf !is null && total + n <= outCap)
                memcpy(outBuf + total, chunk, n);
            XFree(chunk);
        }
        if (n == 0)
            break; // zero-length chunk terminates
        chunks++;
        total += n;
        emitf("incr_chunk", "n=%d bytes=%zu total=%zu", chunks, n, total);
    }
    return total;
}

// -- modes ----------------------------------------------------------------------

int runCopy(Display* dpy, Window win, bool big, long deadlineUs) @nogc nothrow
{
    SelOwner owner;
    owner.dpy = dpy;
    owner.win = win;
    owner.targetsAtom = XInternAtom(dpy, "TARGETS", False);
    owner.timestampAtom = XInternAtom(dpy, "TIMESTAMP", False);
    owner.incrAtom = XInternAtom(dpy, "INCR", False);
    owner.dataTarget = XInternAtom(dpy, "UTF8_STRING", False);
    const clipboard = XInternAtom(dpy, "CLIPBOARD", False);

    static immutable string small = "é漢🎈"; // 2+3+4 UTF-8 bytes
    if (big)
    {
        enum size_t bigLen = 400 * 1024; // > INCR_THRESHOLD -> INCR send
        auto p = cast(ubyte*) malloc(bigLen);
        foreach (i; 0 .. bigLen)
            p[i] = cast(ubyte)('A' + i % 26);
        owner.data = p;
        owner.len = bigLen;
    }
    else
    {
        owner.data = cast(const ubyte*) small.ptr;
        owner.len = small.length;
    }

    owner.ts = serverTimestamp(dpy, win);
    XSetSelectionOwner(dpy, clipboard, win, owner.ts);
    const got = XGetSelectionOwner(dpy, clipboard) == win;
    emitf("clip_offer", "selection=CLIPBOARD targets=[TARGETS,TIMESTAMP,UTF8_STRING] bytes=%zu ts=%lu owned=%d",
        owner.len, owner.ts, cast(int) got);
    if (!big)
    {
        // The PRIMARY contrast: identical machinery, one more line.
        XSetSelectionOwner(dpy, XA_PRIMARY, win, owner.ts);
        emit("clip_offer selection=PRIMARY targets=[TARGETS,TIMESTAMP,UTF8_STRING] note=same_machinery_one_line");
    }

    const fd = XConnectionNumber(dpy);
    bool incrDone = false;
    while (nowUs() < deadlineUs)
    {
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case SelectionRequest:
                handleSelectionRequest(owner, ev.xselectionrequest);
                break;
            case PropertyNotify:
                if (handleIncrDelete(owner, ev.xproperty))
                    incrDone = true;
                break;
            case SelectionClear:
                emitf("ownership_lost", "selection=%s ts=%lu",
                    an(dpy, ev.xselectionclear.selection), ev.xselectionclear.time);
                if (ev.xselectionclear.selection == clipboard)
                    return 0; // the F16 "another app copies" requirement
                break;
            default:
                break;
            }
        }
        if (incrDone && big)
            return 0; // copy-incr: one full INCR transfer served is the demo
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        poll(&pfd, 1, 100);
    }
    emit("auto_exit reason=deadline");
    return 0;
}

int runPaste(Display* dpy, Window win) @nogc nothrow
{
    const clipboard = XInternAtom(dpy, "CLIPBOARD", False);
    const targetsAtom = XInternAtom(dpy, "TARGETS", False);
    const utf8 = XInternAtom(dpy, "UTF8_STRING", False);
    const incrAtom = XInternAtom(dpy, "INCR", False);
    const dest = XInternAtom(dpy, "WSI_PASTE", False);
    const ts = serverTimestamp(dpy, win);

    const owner = XGetSelectionOwner(dpy, clipboard);
    emitf("step", "name=XGetSelectionOwner selection=CLIPBOARD owner=0x%lx", owner);
    if (owner == None)
    {
        printf("SKIP: nobody owns CLIPBOARD (run via run.sh with xclip)\n");
        return 0;
    }

    // 1) what does the owner offer? (TARGETS first, per ICCCM)
    XConvertSelection(dpy, clipboard, targetsAtom, dest, win, ts);
    for (;;)
    {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type != SelectionNotify)
            continue;
        if (ev.xselection.property == None)
        {
            emit("clip_offer targets=[] note=owner_refused_TARGETS");
            break;
        }
        Atom type;
        int format;
        c_ulong n;
        auto data = readProperty(dpy, win, dest, True, type, format, n);
        char[512] list;
        size_t pos = 0;
        foreach (i; 0 .. cast(size_t) n)
        {
            const a = (cast(Atom*) data)[i];
            pos += snprintf(list.ptr + pos, list.length - pos, "%s%s",
                i ? ",".ptr : "".ptr, an(dpy, a));
            if (pos >= list.length - 64)
                break;
        }
        XFree(data);
        emitf("clip_offer", "targets=[%s] count=%lu", list.ptr, n);
        break;
    }

    // 2) convert the text itself (INCR receive when the owner chunks it)
    XConvertSelection(dpy, clipboard, utf8, dest, win, ts);
    for (;;)
    {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (ev.type != SelectionNotify)
            continue;
        if (ev.xselection.property == None)
        {
            emit("paste_data refused=1");
            return 0;
        }
        static __gshared ubyte[4 * 1024 * 1024] buf;
        bool wasIncr;
        int chunks;
        const total = fetchConverted(dpy, win, dest, incrAtom, buf.ptr,
            buf.length, wasIncr, chunks);
        emitf("paste_data", "fmt=UTF8_STRING bytes=%zu incr=%d chunks=%d",
            total, cast(int) wasIncr, chunks);
        if (total <= 64)
            emitf("paste_text", "text=\"%.*s\"", cast(int) total, cast(char*) buf.ptr);
        return 0;
    }
}

// -- XDND: both sides in one process ---------------------------------------------
// Target = `win` on `dpy`; source = a second connection (`sdpy`) with its own
// 1x1 unmapped window that owns XdndSelection. Atoms are server-global, so the
// same ids work on both connections; window ids likewise.

struct DndAtoms
{
    Atom aware, selection, enter, position, status, leave, drop, finished,
        actionCopy, typeList, uriList;
}

DndAtoms internDnd(Display* dpy) @nogc nothrow
{
    DndAtoms a;
    a.aware = XInternAtom(dpy, "XdndAware", False);
    a.selection = XInternAtom(dpy, "XdndSelection", False);
    a.enter = XInternAtom(dpy, "XdndEnter", False);
    a.position = XInternAtom(dpy, "XdndPosition", False);
    a.status = XInternAtom(dpy, "XdndStatus", False);
    a.leave = XInternAtom(dpy, "XdndLeave", False);
    a.drop = XInternAtom(dpy, "XdndDrop", False);
    a.finished = XInternAtom(dpy, "XdndFinished", False);
    a.actionCopy = XInternAtom(dpy, "XdndActionCopy", False);
    a.typeList = XInternAtom(dpy, "XdndTypeList", False);
    a.uriList = XInternAtom(dpy, "text/uri-list", False);
    return a;
}

void sendDndMessage(Display* dpy, Window dest, Atom type, Window from,
    c_long l1, c_long l2, c_long l3, c_long l4) @nogc nothrow
{
    XEvent ev;
    ev.xclient.type = ClientMessage;
    ev.xclient.window = dest;
    ev.xclient.message_type = type;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = cast(c_long) from;
    ev.xclient.data.l[1] = l1;
    ev.xclient.data.l[2] = l2;
    ev.xclient.data.l[3] = l3;
    ev.xclient.data.l[4] = l4;
    XSendEvent(dpy, dest, False, 0, &ev);
    XFlush(dpy);
}

int runDnd(Display* dpy, Window win, long deadlineUs) @nogc nothrow
{
    const da = internDnd(dpy);

    // -- target side: announce XdndAware (a window property, not an event mask)
    c_long ver = XDND_VERSION;
    XChangeProperty(dpy, win, da.aware, XA_ATOM, 32, PropModeReplace,
        cast(ubyte*)&ver, 1);
    XSync(dpy, False); // flush: the source connection reads this property next
    emitf("step", "name=XdndAware_set version=%ld window=0x%lx", ver, win);

    // -- source side: a second connection, as a separate client would be
    Display* sdpy = XOpenDisplay(null);
    const sroot = XRootWindow(sdpy, XDefaultScreen(sdpy));
    Window swin = XCreateSimpleWindow(sdpy, sroot, 0, 0, 1, 1, 0, 0, 0);
    emitf("step", "name=source_connection fd=%d window=0x%lx",
        XConnectionNumber(sdpy), swin);
    XSelectInput(sdpy, swin, PropertyChangeMask); // for serverTimestamp

    // Source checks the target's XdndAware before any message (spec step 1).
    {
        Atom type;
        int format;
        c_ulong n;
        auto p = readProperty(sdpy, win, da.aware, False, type, format, n);
        emitf("dnd_source", "target_XdndAware=%ld", n >= 1 ? *cast(c_long*) p : -1);
        if (p !is null)
            XFree(p);
    }

    // Source owns XdndSelection and advertises 4 types -> the >3-types path:
    // XdndEnter carries only 3 atoms; bit 0 of l[1] says "look at XdndTypeList".
    SelOwner src;
    src.dpy = sdpy;
    src.win = swin;
    src.targetsAtom = XInternAtom(sdpy, "TARGETS", False);
    src.timestampAtom = XInternAtom(sdpy, "TIMESTAMP", False);
    src.incrAtom = XInternAtom(sdpy, "INCR", False);
    src.dataTarget = da.uriList;
    static immutable string uri = "file:///tmp/wsi-f16-dropped.txt\r\n";
    src.data = cast(const ubyte*) uri.ptr;
    src.len = uri.length;
    src.ts = serverTimestamp(sdpy, swin);
    XSetSelectionOwner(sdpy, da.selection, swin, src.ts);
    Atom[4] types = [da.uriList, XInternAtom(sdpy, "UTF8_STRING", False),
        XInternAtom(sdpy, "text/plain", False), XInternAtom(sdpy, "TEXT", False)];
    XChangeProperty(sdpy, swin, da.typeList, XA_ATOM, 32, PropModeReplace,
        cast(ubyte*) types.ptr, 4);
    emitf("dnd_source", "owns=XdndSelection ts=%lu types=4 type_list_set=1", src.ts);

    void sendEnterAndPosition(int x, int y) @nogc nothrow
    {
        sendDndMessage(sdpy, win, da.enter, swin,
            (cast(c_long) XDND_VERSION << 24) | 1 /* more-than-3-types bit */ ,
            cast(c_long) types[0], cast(c_long) types[1], cast(c_long) types[2]);
        sendDndMessage(sdpy, win, da.position, swin, 0,
            (x << 16) | y, cast(c_long) src.ts, cast(c_long) da.actionCopy);
        emitf("dnd_source", "send=XdndEnter,XdndPosition version=5 more_types=1 pos=%d,%d", x, y);
    }

    sendEnterAndPosition(100, 100);

    // -- the negotiation, multiplexing both connections' fds -------------------
    pollfd[2] pfds;
    pfds[0].fd = XConnectionNumber(dpy);
    pfds[1].fd = XConnectionNumber(sdpy);
    pfds[0].events = pfds[1].events = POLLIN;
    int statusCount = 0;
    bool leftOnce = false, finished = false;
    Time dropTime = 0;

    while (!finished && nowUs() < deadlineUs)
    {
        // ---- target events (dpy) ----
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == ClientMessage && ev.xclient.message_type == da.enter)
            {
                const srcWin = cast(Window) ev.xclient.data.l[0];
                const moreTypes = (ev.xclient.data.l[1] & 1) != 0;
                emitf("dnd_enter", "source=0x%lx version=%ld formats=[%s,%s,%s] more_types=%d",
                    srcWin, ev.xclient.data.l[1] >> 24,
                    an(dpy, cast(Atom) ev.xclient.data.l[2]),
                    an(dpy, cast(Atom) ev.xclient.data.l[3]),
                    an(dpy, cast(Atom) ev.xclient.data.l[4]), cast(int) moreTypes);
                if (moreTypes) // the full list lives on the source window
                {
                    Atom type;
                    int format;
                    c_ulong n;
                    auto p = readProperty(dpy, srcWin, da.typeList, False, type, format, n);
                    char[256] list;
                    size_t pos = 0;
                    foreach (i; 0 .. cast(size_t) n)
                        pos += snprintf(list.ptr + pos, list.length - pos, "%s%s",
                            i ? ",".ptr : "".ptr, an(dpy, (cast(Atom*) p)[i]));
                    XFree(p);
                    emitf("dnd_enter", "XdndTypeList=[%s] count=%lu", list.ptr, n);
                }
            }
            else if (ev.type == ClientMessage && ev.xclient.message_type == da.position)
            {
                const pos = ev.xclient.data.l[2];
                emitf("dnd_position", "source=0x%lx pos=%ld,%ld action=%s",
                    ev.xclient.data.l[0], pos >> 16, pos & 0xffff,
                    an(dpy, cast(Atom) ev.xclient.data.l[4]));
                // XdndStatus: bit0 accept; empty rect (l[2]=l[3]=0) = keep sending
                sendDndMessage(dpy, cast(Window) ev.xclient.data.l[0], da.status,
                    win, 1, 0, 0, cast(c_long) da.actionCopy);
                emit("dnd_status send accept=1 action=XdndActionCopy");
            }
            else if (ev.type == ClientMessage && ev.xclient.message_type == da.leave)
                emit("dnd_leave source_aborted=1 cached_formats_dropped=1");
            else if (ev.type == ClientMessage && ev.xclient.message_type == da.drop)
            {
                dropTime = cast(Time) ev.xclient.data.l[2];
                emitf("dnd_drop", "source=0x%lx time=%lu", ev.xclient.data.l[0], dropTime);
                // data transfer = a perfectly ordinary selection conversion
                XConvertSelection(dpy, da.selection, da.uriList, da.selection,
                    win, dropTime);
                emit("step name=XConvertSelection selection=XdndSelection target=text/uri-list");
            }
            else if (ev.type == SelectionNotify)
            {
                static __gshared ubyte[4096] dbuf;
                bool wasIncr;
                int chunks;
                const total = fetchConverted(dpy, win, ev.xselection.property,
                    src.incrAtom, dbuf.ptr, dbuf.length, wasIncr, chunks);
                emitf("dnd_data", "fmt=text/uri-list bytes=%zu uri=\"%.*s\"",
                    total, cast(int)(total >= 2 ? total - 2 : total), cast(char*) dbuf.ptr);
                sendDndMessage(dpy, swin, da.finished, win, 1 /* accepted */ ,
                    cast(c_long) da.actionCopy, 0, 0);
                emit("dnd_finished send success=1 action=XdndActionCopy");
            }
        }

        // ---- source events (sdpy) ----
        while (XPending(sdpy) > 0)
        {
            XEvent ev;
            XNextEvent(sdpy, &ev);
            if (ev.type == ClientMessage && ev.xclient.message_type == da.status)
            {
                statusCount++;
                emitf("dnd_source", "recv=XdndStatus accept=%ld action=%s n=%d",
                    ev.xclient.data.l[1] & 1,
                    an(sdpy, cast(Atom) ev.xclient.data.l[4]), statusCount);
                if (!leftOnce)
                {
                    // exercise the abort path once: Leave, then re-enter
                    leftOnce = true;
                    sendDndMessage(sdpy, win, da.leave, swin, 0, 0, 0, 0);
                    emit("dnd_source send=XdndLeave (abort path)");
                    sendEnterAndPosition(120, 80);
                }
                else
                {
                    sendDndMessage(sdpy, win, da.drop, swin, 0,
                        cast(c_long) src.ts, 0, 0);
                    emit("dnd_source send=XdndDrop");
                }
            }
            else if (ev.type == SelectionRequest)
                handleSelectionRequest(src, ev.xselectionrequest); // same code as clipboard
            else if (ev.type == ClientMessage && ev.xclient.message_type == da.finished)
            {
                emitf("dnd_source", "recv=XdndFinished success=%ld action=%s",
                    ev.xclient.data.l[1] & 1, an(sdpy, cast(Atom) ev.xclient.data.l[2]));
                finished = true;
            }
        }

        if (!finished)
            poll(pfds.ptr, 2, 100);
    }

    XDestroyWindow(sdpy, swin);
    XCloseDisplay(sdpy);
    emitf("teardown", "dnd_complete=%d", cast(int) finished);
    return finished ? 0 : 1;
}

// ---------------------------------------------------------------------------

int main(string[] args)
{
    initInstrument("f16_x11");
    const(char)* mode = "dnd";
    foreach (a; args[1 .. $])
        if (a.length > 7 && a[0 .. 7] == "--mode=")
            mode = (a[7 .. $] ~ '\0').ptr;

    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const deadlineUs = autoExit ? 8_000_000 : 30_000_000;

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d mode=%s", XConnectionNumber(dpy), mode);

    const screen = XDefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, XRootWindow(dpy, screen), 0, 0,
        320, 200, 1, XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · F16 clipboard+dnd");
    XSelectInput(dpy, win, StructureNotifyMask | PropertyChangeMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=320x200", win);

    int rc;
    if (strcmp(mode, "copy") == 0)
        rc = runCopy(dpy, win, false, deadlineUs);
    else if (strcmp(mode, "copy-incr") == 0)
        rc = runCopy(dpy, win, true, deadlineUs);
    else if (strcmp(mode, "paste") == 0)
        rc = runPaste(dpy, win);
    else
        rc = runDnd(dpy, win, deadlineUs);

    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return rc;
}
