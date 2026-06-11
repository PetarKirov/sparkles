// X11 F14 demo — window state & vetoable close (../../f14-window-state.md,
// spec ../../../features/f14-window-state.md). Evolves the scaffold
// (../scaffold/app.d) event loop; presentation is reduced to a server-side
// XFillRectangle (state events, not pixels, are the subject here).
//
// What it exercises:
//   * maximize toggle / fullscreen toggle via _NET_WM_STATE ClientMessages to
//     the root window (EWMH: _NET_WM_STATE_MAXIMIZED_HORZ+VERT,
//     _NET_WM_STATE_FULLSCREEN, action _NET_WM_STATE_TOGGLE)
//   * minimize via XIconifyWindow (ICCCM WM_CHANGE_STATE -> IconicState),
//     restore via XMapWindow + _NET_ACTIVE_WINDOW
//   * every resulting event is logged until the dust settles: PropertyNotify
//     on _NET_WM_STATE / WM_STATE (the atom list is re-read and decoded each
//     change), ConfigureNotify sizes, Map/Unmap/ReparentNotify,
//     VisibilityNotify, and FocusIn/FocusOut with the full mode/detail decode
//   * vetoable close: a "dirty" flag vetoes the first WM_DELETE_WINDOW
//     ClientMessage (the request is purely advisory — there is nothing to
//     "return" to the WM); the second request closes
//   * WSI_NO_WM_DELETE=1 omits WM_DELETE_WINDOW from WM_PROTOCOLS: a WM-side
//     close then falls back to XKillClient and the connection dies (XIO error
//     handler logs `connection_lost` and exits 0 — that *is* the finding)
//
// Modes: WSI_AUTO_EXIT=1 self-drives the whole transition schedule (the same
// handlers the keys call) and exits 0 — works on bare Xvfb (no WM: requests
// vanish; the silence is logged) and under a WM. WSI_DRIVEN=1 instead waits
// ~12 s for externally injected keys (xdotool; see run.sh):
//   m maximize-toggle   i iconify   r restore   f fullscreen-toggle
//   d dirty-toggle      c self-send a WM_DELETE_WINDOW request   q quit
// Headless-safe: no display -> prints `SKIP:` and exits 0.
module app;

import c; // ImportC: Xlib + Xutil + Xatom (+ unused XShm) + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : exit, getenv;

// Macros ImportC cannot export, re-declared (see ../scaffold/app.d):
enum : c_long
{
    KeyPressMask = 1L << 0,
    ExposureMask = 1L << 15,
    VisibilityChangeMask = 1L << 16,
    StructureNotifyMask = 1L << 17,
    SubstructureNotifyMask = 1L << 19,
    SubstructureRedirectMask = 1L << 20,
    FocusChangeMask = 1L << 21,
    PropertyChangeMask = 1L << 22,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    FocusIn = 9,
    FocusOut = 10,
    Expose = 12,
    VisibilityNotify = 15,
    UnmapNotify = 18,
    MapNotify = 19,
    ReparentNotify = 21,
    ConfigureNotify = 22,
    PropertyNotify = 28,
    ClientMessage = 33,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum XA_ATOM = 4; // Xatom.h: #define XA_ATOM ((Atom) 4) — a cast macro
enum AnyPropertyType = 0;
enum NoEventMask = 0;

// EWMH _NET_WM_STATE ClientMessage actions (EWMH spec, _NET_WM_STATE):
enum : c_long
{
    _NET_WM_STATE_REMOVE = 0,
    _NET_WM_STATE_ADD = 1,
    _NET_WM_STATE_TOGGLE = 2,
}

// ICCCM WM_STATE / WM_CHANGE_STATE state values:
enum { WithdrawnState = 0, NormalState = 1, IconicState = 3 }

// The FocusIn/FocusOut "Notify* zoo" (Xlib ch. 10.8, <X11/X.h>):
static immutable string[4] focusModes =
    ["NotifyNormal", "NotifyGrab", "NotifyUngrab", "NotifyWhileGrabbed"];
static immutable string[8] focusDetails = [
    "NotifyAncestor", "NotifyVirtual", "NotifyInferior", "NotifyNonlinear",
    "NotifyNonlinearVirtual", "NotifyPointer", "NotifyPointerRoot", "NotifyDetailNone",
];

struct Demo
{
    Display* dpy;
    Window root, win;
    int screen;
    Atom netWmState, netMaxH, netMaxV, netFullscreen, netActive;
    Atom wmProtocols, wmDelete, wmState;
    bool dirty, running = true;
    int requests, stateChanges, configures, unmapsMaps, focusEvents;
}

__gshared int g_xerrors;
extern (C) int onXError(Display* dpy, XErrorEvent* e) @nogc nothrow
{
    ++g_xerrors;
    emitf("x_error", "code=%d request=%d", e.error_code, e.request_code);
    return 0;
}

// Fires when the server severs the connection (the XKillClient probe). The
// handler must not return; exiting 0 keeps the probe pass green — losing the
// connection is the documented outcome, not a demo failure.
extern (C) int onXIOError(Display* dpy) @nogc nothrow
{
    emit("connection_lost via=XIOError likely=XKillClient");
    exit(0);
}

/// EWMH state change: a ClientMessage *to the root window* with
/// SubstructureRedirect|SubstructureNotify in the event mask — only a WM
/// (the client that selected SubstructureRedirect on the root) receives it.
void sendNetWmState(ref Demo d, c_long action, Atom a1, Atom a2,
    const(char)* kind) @nogc nothrow
{
    XEvent e;
    e.xclient.type = ClientMessage;
    e.xclient.window = d.win;
    e.xclient.message_type = d.netWmState;
    e.xclient.format = 32;
    e.xclient.data.l[0] = action;
    e.xclient.data.l[1] = cast(c_long) a1;
    e.xclient.data.l[2] = cast(c_long) a2;
    e.xclient.data.l[3] = 1; // source indication: normal application
    XSendEvent(d.dpy, d.root, False,
        SubstructureRedirectMask | SubstructureNotifyMask, &e);
    XFlush(d.dpy);
    ++d.requests;
    emitf("state_request", "kind=%s action=%ld target=root", kind, action);
}

void requestActivate(ref Demo d) @nogc nothrow
{
    XEvent e;
    e.xclient.type = ClientMessage;
    e.xclient.window = d.win;
    e.xclient.message_type = d.netActive;
    e.xclient.format = 32;
    e.xclient.data.l[0] = 1; // source: application
    XSendEvent(d.dpy, d.root, False,
        SubstructureRedirectMask | SubstructureNotifyMask, &e);
    XFlush(d.dpy);
    ++d.requests;
    emit("state_request kind=activate target=root");
}

/// Self-deliver the WM_PROTOCOLS/WM_DELETE_WINDOW ClientMessage — the close
/// request is just an event any client may send; the WM sends exactly this.
void sendCloseRequest(ref Demo d) @nogc nothrow
{
    XEvent e;
    e.xclient.type = ClientMessage;
    e.xclient.window = d.win;
    e.xclient.message_type = d.wmProtocols;
    e.xclient.format = 32;
    e.xclient.data.l[0] = cast(c_long) d.wmDelete;
    XSendEvent(d.dpy, d.win, False, NoEventMask, &e);
    XFlush(d.dpy);
    emit("step name=XSendEvent msg=WM_DELETE_WINDOW to=self");
}

/// Re-read and decode the _NET_WM_STATE atom list (PropertyNotify carries no
/// payload — the new value must be fetched with XGetWindowProperty).
void logNetWmState(ref Demo d) nothrow
{
    Atom type;
    int format;
    c_ulong nitems, after;
    ubyte* prop;
    XGetWindowProperty(d.dpy, d.win, d.netWmState, 0, 32, False, XA_ATOM,
        &type, &format, &nitems, &after, &prop);
    char[256] buf = '\0';
    size_t off;
    foreach (i; 0 .. cast(size_t) nitems)
    {
        const a = (cast(Atom*) prop)[i];
        char* name = XGetAtomName(d.dpy, a);
        off += snprintf(buf.ptr + off, buf.length - off, "%s%s",
            i ? ",".ptr : "".ptr, name);
        XFree(name);
    }
    if (prop !is null)
        XFree(prop);
    ++d.stateChanges;
    emitf("state_changed", "states=[%s]", buf.ptr);
}

/// Decode the ICCCM WM_STATE property (set by the WM): the first CARD32 is
/// Withdrawn/Normal/Iconic — the only reliable iconified-or-not signal.
void logWmState(ref Demo d) nothrow
{
    Atom type;
    int format;
    c_ulong nitems, after;
    ubyte* prop;
    XGetWindowProperty(d.dpy, d.win, d.wmState, 0, 2, False, AnyPropertyType,
        &type, &format, &nitems, &after, &prop);
    if (prop !is null && nitems >= 1)
    {
        const v = *cast(c_ulong*) prop;
        emitf("state_changed", "wm_state=%s", v == IconicState
                ? "iconic".ptr : v == NormalState ? "normal".ptr : "withdrawn".ptr);
        ++d.stateChanges;
    }
    if (prop !is null)
        XFree(prop);
}

void redraw(ref Demo d, int w, int h) @nogc nothrow
{
    GC gc = XDefaultGC(d.dpy, d.screen);
    XSetForeground(d.dpy, gc, d.dirty ? 0xc04040 : 0x4070b0);
    XFillRectangle(d.dpy, d.win, gc, 0, 0, cast(uint) w, cast(uint) h);
}

// One named action per key; the auto schedule calls the same handler.
void act(ref Demo d, char key) nothrow
{
    switch (key)
    {
    case 'm':
        sendNetWmState(d, _NET_WM_STATE_TOGGLE, d.netMaxH, d.netMaxV, "maximize_toggle");
        break;
    case 'f':
        sendNetWmState(d, _NET_WM_STATE_TOGGLE, d.netFullscreen, 0, "fullscreen_toggle");
        break;
    case 'i':
        // Xutil convenience: sends the ICCCM WM_CHANGE_STATE ClientMessage
        // (IconicState) to the root — again, only a WM listens.
        const st = XIconifyWindow(d.dpy, d.win, d.screen);
        XFlush(d.dpy);
        ++d.requests;
        emitf("state_request", "kind=minimize via=XIconifyWindow sent=%d", st);
        break;
    case 'r':
        sendNetWmState(d, _NET_WM_STATE_REMOVE, d.netMaxH, d.netMaxV, "restore_maximize");
        sendNetWmState(d, _NET_WM_STATE_REMOVE, d.netFullscreen, 0, "restore_fullscreen");
        XMapWindow(d.dpy, d.win); // de-iconify (ICCCM: map the window)
        emit("state_request kind=restore via=XMapWindow");
        requestActivate(d);
        break;
    case 'd':
        d.dirty = !d.dirty;
        emitf("dirty", "flag=%d", cast(int) d.dirty);
        break;
    case 'c':
        sendCloseRequest(d);
        break;
    case 'q':
        d.running = false;
        break;
    default:
        break;
    }
}

int main()
{
    initInstrument("f14_x11");
    const autoExit = getenv("WSI_AUTO_EXIT") !is null;
    const driven = getenv("WSI_DRIVEN") !is null;
    const noWmDelete = getenv("WSI_NO_WM_DELETE") !is null;

    Demo d;
    d.dpy = XOpenDisplay(null);
    if (d.dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    XSetErrorHandler(&onXError);
    XSetIOErrorHandler(&onXIOError);
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(d.dpy));

    d.screen = XDefaultScreen(d.dpy);
    d.root = XRootWindow(d.dpy, d.screen);

    int width = 480, height = 320;
    d.win = XCreateSimpleWindow(d.dpy, d.root, 20, 20, width, height, 1,
        XBlackPixel(d.dpy, d.screen), XWhitePixel(d.dpy, d.screen));
    XStoreName(d.dpy, d.win, "Sparkles \xc2\xb7 X11 F14 window state");

    d.netWmState = XInternAtom(d.dpy, "_NET_WM_STATE", False);
    d.netMaxH = XInternAtom(d.dpy, "_NET_WM_STATE_MAXIMIZED_HORZ", False);
    d.netMaxV = XInternAtom(d.dpy, "_NET_WM_STATE_MAXIMIZED_VERT", False);
    d.netFullscreen = XInternAtom(d.dpy, "_NET_WM_STATE_FULLSCREEN", False);
    d.netActive = XInternAtom(d.dpy, "_NET_ACTIVE_WINDOW", False);
    d.wmProtocols = XInternAtom(d.dpy, "WM_PROTOCOLS", False);
    d.wmDelete = XInternAtom(d.dpy, "WM_DELETE_WINDOW", False);
    d.wmState = XInternAtom(d.dpy, "WM_STATE", False);

    if (noWmDelete)
        emit("step name=XSetWMProtocols skipped=WSI_NO_WM_DELETE");
    else
        XSetWMProtocols(d.dpy, d.win, &d.wmDelete, 1);

    XSelectInput(d.dpy, d.win, ExposureMask | KeyPressMask | StructureNotifyMask
            | PropertyChangeMask | FocusChangeMask | VisibilityChangeMask);
    XMapWindow(d.dpy, d.win);
    emitf("window_created", "xid=0x%lx size=%dx%d", d.win, width, height);

    // The self-driven schedule (µs since init) — same handlers as the keys.
    static immutable struct Step { long t; char key; }
    static immutable Step[9] schedule = [
        {400_000, 'm'}, {900_000, 'm'}, {1_400_000, 'i'}, {1_900_000, 'r'},
        {2_400_000, 'f'}, {2_900_000, 'f'}, {3_400_000, 'd'},
        {3_500_000, 'c'}, /* dirty -> vetoed */ {3_900_000, 'c'}, /* closes */
    ];
    size_t nextStep;
    const deadline = driven ? 12_000_000 : 5_000_000;

    const fd = XConnectionNumber(d.dpy);
    while (d.running)
    {
        while (XPending(d.dpy) > 0)
        {
            XEvent ev;
            XNextEvent(d.dpy, &ev);
            switch (ev.type)
            {
            case ConfigureNotify:
                ++d.configures;
                emitf("configure", "size=%dx%d pos=%d+%d send_event=%d",
                    ev.xconfigure.width, ev.xconfigure.height,
                    ev.xconfigure.x, ev.xconfigure.y, cast(int) ev.xany.send_event);
                width = ev.xconfigure.width;
                height = ev.xconfigure.height;
                break;
            case MapNotify:
                ++d.unmapsMaps;
                emit("map_notify");
                break;
            case UnmapNotify:
                ++d.unmapsMaps;
                emitf("unmap_notify", "send_event=%d", cast(int) ev.xany.send_event);
                break;
            case ReparentNotify:
                emitf("reparent_notify", "parent=0x%lx", ev.xreparent.parent);
                break;
            case VisibilityNotify:
                emitf("visibility", "state=%d", ev.xvisibility.state);
                break;
            case PropertyNotify:
                char* name = XGetAtomName(d.dpy, ev.xproperty.atom);
                emitf("property_notify", "atom=%s state=%s", name,
                    ev.xproperty.state == 0 ? "NewValue".ptr : "Deleted".ptr);
                XFree(name);
                if (ev.xproperty.atom == d.netWmState && ev.xproperty.state == 0)
                    logNetWmState(d);
                else if (ev.xproperty.atom == d.wmState && ev.xproperty.state == 0)
                    logWmState(d);
                break;
            case FocusIn:
            case FocusOut:
                ++d.focusEvents;
                emitf("focus", "state=%s mode=%s detail=%s",
                    ev.type == FocusIn ? "in".ptr : "out".ptr,
                    focusModes[ev.xfocus.mode].ptr, focusDetails[ev.xfocus.detail].ptr);
                break;
            case Expose:
                if (ev.xexpose.count == 0)
                    redraw(d, width, height);
                break;
            case ClientMessage:
                if (ev.xclient.message_type == d.wmProtocols
                    && cast(Atom) ev.xclient.data.l[0] == d.wmDelete)
                {
                    if (d.dirty)
                    {
                        // The veto: simply do nothing. WM_DELETE_WINDOW is
                        // advisory (ICCCM §4.2.8.1) — there is no reply, no
                        // return value, nothing to send back. Ignoring it IS
                        // the veto; the WM cannot tell refusal from sloth.
                        d.dirty = false;
                        emit("close_requested veto=1 action=ignored_dirty_cleared");
                        redraw(d, width, height);
                    }
                    else
                    {
                        emit("close_requested veto=0 action=quit");
                        d.running = false;
                    }
                }
                break;
            case KeyPress:
                const sym = XLookupKeysym(&ev.xkey, 0);
                emitf("key", "sym=0x%lx", sym);
                if (sym >= 'a' && sym <= 'z')
                    act(d, cast(char) sym);
                break;
            default:
                break;
            }
        }

        if (autoExit && !driven && nextStep < schedule.length
            && nowUs() >= schedule[nextStep].t)
        {
            act(d, schedule[nextStep].key);
            ++nextStep;
        }
        if ((autoExit || driven) && nowUs() > deadline)
        {
            emit("auto_exit reason=deadline");
            break;
        }
        if (!autoExit && !driven && nextStep == 0)
            nextStep = 1; // interactive: no schedule, keys only

        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, (autoExit || driven) ? 20 : -1);
    }

    emitf("summary", "requests=%d state_changes=%d configures=%d map_unmap=%d "
            ~ "focus=%d x_errors=%d", d.requests, d.stateChanges, d.configures,
        d.unmapsMaps, d.focusEvents, g_xerrors);
    XDestroyWindow(d.dpy, d.win);
    XCloseDisplay(d.dpy);
    return 0;
}
