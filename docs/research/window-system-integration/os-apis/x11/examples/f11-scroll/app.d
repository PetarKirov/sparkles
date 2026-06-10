// X11 F11 demo — scroll fidelity (the feature contract:
// ../../../features/f11-scroll.md; findings: ../../f11-scroll.md). Built on
// the scaffold (../scaffold/app.d), drawing reduced to a server-side ruler.
//
// X11 represents one physical scroll TWICE: legacy core buttons 4/5/6/7 and
// XI2 smooth-scroll valuators (XIScrollClass; deltas ride XI_Motion). This
// demo captures both streams for the same physical event, and measures the
// dedupe machinery between them:
//
//   * device query: XIQueryDevice dump of every XIScrollClass (number,
//     scroll_type, increment, flags) and XIValuatorClass — on Xvfb the
//     honest answer is `scroll_class … none=1` for every device
//   * two connections, one window: dpy (this client) selects XI2 button +
//     motion events; dpy2 (a *second* client) selects core ButtonPress —
//     core ButtonPressMask is one-client-exclusive per window, so splitting
//     clients is also the only way to capture both streams concurrently
//   * phase A `dual_client`:    core stream on dpy2, XI2 stream on dpy
//   * phase B `dual_selection`: dpy2 deselects; dpy selects BOTH core and
//     XI2 button events — measures which representation(s) one client gets
//   * phase C `core_only`:      dpy clears its XI2 selection — does core
//     delivery resume once no XI2 selection exists on the window?
//   * XIPointerEmulated: logged (`emulated=0|1`) on every XI2 button event —
//     are xdotool's `click 4/5` wheel events tagged as emulated?
//   * a scrollable ruler (1 detent = 20 px) + per-gesture totals
//     (`gesture_summary …`, gestures split on a 400 ms idle gap)
//   * built-in pass (no xdotool): XSendEvent-fabricated button 4/5 presses —
//     delivered with send_event=1 to core selectors only, never as XI2
//
// WSI_DRIVEN=1 stretches the phases to 4 s each so xdotool (see ./run.sh)
// can deliver real XTest wheel clicks. Headless-safe: no display, or no
// XInputExtension -> prints `SKIP:`, exit 0.
module app;

import c; // ImportC: Xlib + Xutil + XInput2 + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf, snprintf;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;

// ---------------------------------------------------------------------------
// Constants ImportC cannot export (all #defines), re-declared per the
// scaffold gotcha: core masks/types and the whole of <X11/extensions/XI2.h>.

enum : c_long
{
    KeyPressMask = 1L << 0,
    ButtonPressMask = 1L << 2,
    ButtonReleaseMask = 1L << 3,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // core XEvent.type discriminators; GenericEvent carries all XI2 events
{
    KeyPress = 2, ButtonPress = 4, ButtonRelease = 5,
    Expose = 12, ClientMessage = 33, GenericEvent = 35,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;

enum // XI2.h
{
    XIAllDevices = 0,
    XIMasterPointer = 1, XIMasterKeyboard = 2, XISlavePointer = 3,
    XISlaveKeyboard = 4, XIFloatingSlave = 5,
    XI_ButtonPress = 4, XI_ButtonRelease = 5, XI_Motion = 6,
    XIButtonClass = 1, XIValuatorClass = 2, XIScrollClass = 3,
    XIScrollTypeVertical = 1, XIScrollTypeHorizontal = 2,
    XIScrollFlagNoEmulation = 1 << 0, XIScrollFlagPreferred = 1 << 1,
    XIPointerEmulated = 1 << 16, // event flag: emulated from another event
}

immutable string[5] useName =
    ["MasterPointer", "MasterKeyboard", "SlavePointer", "SlaveKeyboard", "FloatingSlave"];

/// XISetMask is a macro; same bit math, D-side.
void xiSetMask(scope ubyte[] mask, int event) @nogc nothrow
{
    mask[event >> 3] |= cast(ubyte)(1 << (event & 7));
}

/// One smooth-scroll axis discovered via XIQueryDevice: XI_Motion carries the
/// axis as an *absolute accumulating* valuator; one detent = `increment`.
struct ScrollAxis
{
    int deviceid, number, scrollType;
    double increment;
    double last; // last absolute valuator value seen (NaN until primed)
}

int main()
{
    initInstrument("x11_f11");
    const autoExit = getenv("WSI_AUTO_EXIT") !is null;
    const driven = getenv("WSI_DRIVEN") !is null; // xdotool owns the input
    const phaseUs = driven ? 4_000_000 : 600_000;

    Display* dpy = XOpenDisplay(null); // client 1: the XI2 listener
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    int xiOpcode, xiEventBase, xiErrorBase;
    if (!XQueryExtension(dpy, "XInputExtension", &xiOpcode, &xiEventBase, &xiErrorBase))
    {
        printf("SKIP: no XInputExtension on this display\n");
        XCloseDisplay(dpy);
        return 0;
    }
    int xiMajor = 2, xiMinor = 3;
    const xiStatus = XIQueryVersion(dpy, &xiMajor, &xiMinor);
    emitf("step", "name=XIQueryVersion status=%d server=%d.%d", xiStatus, xiMajor, xiMinor);
    if (xiStatus != 0 || xiMajor < 2)
    {
        printf("SKIP: server does not speak XI2 (got %d.%d)\n", xiMajor, xiMinor);
        XCloseDisplay(dpy);
        return 0;
    }
    const screen = XDefaultScreen(dpy);
    const root = XRootWindow(dpy, screen);

    // -- Scroll capability dump: which devices have XIScrollClass? ------------
    // (Per the XI 2.1 smooth-scrolling spec a wheel device exposes one scroll
    // class per axis; Xvfb's virtual pointers expose none — logged honestly.)
    ScrollAxis[16] axes;
    int nAxes;
    int nDevs;
    int masterPtr = 2; // conventional VCP id; replaced by the query below
    XIDeviceInfo* devs = XIQueryDevice(dpy, XIAllDevices, &nDevs);
    foreach (i; 0 .. nDevs)
    {
        const d = devs + i;
        emitf("device", "id=%d use=%s name=%s", d.deviceid, useName[d.use - 1].ptr, d.name);
        if (d.use == XIMasterPointer)
            masterPtr = d.deviceid;
        int found;
        foreach (k; 0 .. d.num_classes)
        {
            const any = d.classes[k];
            if (any.type == XIScrollClass)
            {
                const sc = cast(const(XIScrollClassInfo)*) any;
                emitf("scroll_class", "device=%d number=%d type=%s increment=%g "
                        ~ "flags=0x%x no_emulation=%d preferred=%d",
                    d.deviceid, sc.number,
                    sc.scroll_type == XIScrollTypeVertical ? "vertical".ptr : "horizontal".ptr,
                    sc.increment, sc.flags,
                    cast(int)((sc.flags & XIScrollFlagNoEmulation) != 0),
                    cast(int)((sc.flags & XIScrollFlagPreferred) != 0));
                if (nAxes < axes.length)
                    axes[nAxes++] = ScrollAxis(d.deviceid, sc.number,
                        sc.scroll_type, sc.increment, double.nan);
                ++found;
            }
            else if (any.type == XIValuatorClass)
            {
                const vc = cast(const(XIValuatorClassInfo)*) any;
                char* label = vc.label ? XGetAtomName(dpy, vc.label) : null;
                emitf("valuator_class", "device=%d number=%d label=%s min=%g max=%g mode=%d",
                    d.deviceid, vc.number, label ? label : "-".ptr, vc.min, vc.max, vc.mode);
                if (label)
                    XFree(label);
            }
        }
        if (!found)
            emitf("scroll_class", "device=%d none=1", d.deviceid);
    }
    XIFreeDeviceInfo(devs);

    // -- Window + the two-client selection split --------------------------------
    const int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 20, 20, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F11 scroll");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    const c_long baseMask = ExposureMask | KeyPressMask | StructureNotifyMask;
    XSelectInput(dpy, win, baseMask); // NO core buttons yet: dpy2 owns those
    ubyte[4] bits = 0;
    xiSetMask(bits[], XI_ButtonPress);
    xiSetMask(bits[], XI_ButtonRelease);
    xiSetMask(bits[], XI_Motion);
    XIEventMask m;
    m.deviceid = XIAllDevices;
    m.mask_len = bits.length;
    m.mask = bits.ptr;
    XISelectEvents(dpy, win, &m, 1);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    // Client 2: core-protocol-only listener on the *same* window. Core
    // ButtonPressMask is one-client-per-window-exclusive, so a second
    // connection is the only way to hold core + XI2 selections concurrently.
    Display* dpy2 = XOpenDisplay(null);
    if (dpy2 is null)
    {
        printf("SKIP: could not open second display connection\n");
        XCloseDisplay(dpy);
        return 0;
    }
    XSelectInput(dpy2, win, ButtonPressMask | ButtonReleaseMask);
    XFlush(dpy2);
    emit("step name=XSelectInput conn=core_client mask=ButtonPress|ButtonRelease");

    GC gc = XDefaultGC(dpy, screen);

    // -- Ruler + gesture state ---------------------------------------------------
    enum detentPx = 20; // 1 wheel detent scrolls the ruler by 20 px
    int vOffset, hOffset; // ruler offsets in px
    long lastScrollUs = -1, gestureStartUs;
    int gEvents, gCore, gXi2, gEmulated, gVDetents, gHDetents;
    double gSmoothV = 0, gSmoothH = 0;

    void redraw()
    {
        XClearWindow(dpy, win);
        foreach (y; 0 .. height / detentPx + 2)
        {
            const v = y * detentPx - (vOffset % (detentPx * 5)) - detentPx;
            const lineNo = (v + vOffset) / detentPx;
            const major = lineNo % 5 == 0;
            XDrawLine(dpy, win, gc, 40 + hOffset, v, (major ? 90 : 70) + hOffset, v);
            if (major)
            {
                char[16] buf;
                const n = snprintf(buf.ptr, buf.length, "%d", lineNo);
                XDrawString(dpy, win, gc, 96 + hOffset, v + 4, buf.ptr, n);
            }
        }
        XFlush(dpy);
    }

    void endGesture()
    {
        if (gEvents == 0)
            return;
        emitf("gesture_summary", "events=%d core=%d xi2=%d emulated=%d "
                ~ "v_detents=%d h_detents=%d smooth_v=%g smooth_h=%g dur_ms=%lld",
            gEvents, gCore, gXi2, gEmulated, gVDetents, gHDetents,
            gSmoothV, gSmoothH, (lastScrollUs - gestureStartUs) / 1000);
        gEvents = gCore = gXi2 = gEmulated = gVDetents = gHDetents = 0;
        gSmoothV = gSmoothH = 0;
    }

    /// Fold one scroll event into the running gesture (and the ruler, when it
    /// is the stream that owns the ruler in the current phase).
    void countScroll(uint button, bool isXi2, bool emulated, bool moveRuler)
    {
        const now = nowUs();
        if (lastScrollUs >= 0 && now - lastScrollUs > 400_000)
            endGesture();
        if (gEvents == 0)
            gestureStartUs = now;
        lastScrollUs = now;
        ++gEvents;
        isXi2 ? ++gXi2 : ++gCore;
        if (emulated)
            ++gEmulated;
        const step = (button == 4 || button == 6) ? -1 : 1;
        if (button == 4 || button == 5)
            gVDetents += step;
        else
            gHDetents += step;
        if (moveRuler)
        {
            if (button == 4 || button == 5)
                vOffset += step * detentPx;
            else
                hOffset += step * detentPx;
            redraw();
        }
    }

    immutable(char)* axisOf(uint b) => (b == 4 || b == 5) ? "v".ptr : "h".ptr;

    // -- Phases --------------------------------------------------------------
    // A dual_client:    core -> dpy2, XI2 -> dpy (both streams, one event?)
    // B dual_selection: dpy2 deselects; dpy holds core AND XI2 selections
    // C core_only:      dpy clears the XI2 selection, keeps the core one
    int phase = -1;
    long phaseStartUs;
    bool sawExpose, running = true;
    int sendProbes;

    void enterPhase(int p)
    {
        phase = p;
        phaseStartUs = nowUs();
        if (p == 0)
            emit("phase name=dual_client");
        else if (p == 1)
        {
            XSelectInput(dpy2, win, 0);
            XFlush(dpy2);
            XSelectInput(dpy, win, baseMask | ButtonPressMask | ButtonReleaseMask);
            emit("phase name=dual_selection core_client=deselected "
                    ~ "xi2_client=core+xi2");
        }
        else if (p == 2)
        {
            ubyte[4] none = 0;
            XIEventMask m0;
            m0.deviceid = XIAllDevices;
            m0.mask_len = none.length;
            m0.mask = none.ptr;
            XISelectEvents(dpy, win, &m0, 1);
            emit("phase name=core_only xi2_selection=cleared");
        }
        else
        {
            endGesture();
            running = false;
            emit("auto_exit");
        }
    }

    /// Built-in probe (no xdotool): fabricate a core wheel press/release pair
    /// with XSendEvent. It reaches core selectors only — fabricated events
    /// never enter the input pipeline, so no XI2 twin and no ruler motion
    /// from the server's point of view (this is why drivers use XTest).
    void sendEventProbe(uint button)
    {
        XEvent se;
        se.xbutton.type = ButtonPress;
        se.xbutton.display = dpy;
        se.xbutton.window = win;
        se.xbutton.button = button;
        se.xbutton.same_screen = True;
        XSendEvent(dpy, win, True, ButtonPressMask, &se);
        se.xbutton.type = ButtonRelease;
        XSendEvent(dpy, win, True, ButtonReleaseMask, &se);
        XFlush(dpy);
        emitf("step", "name=XSendEvent button=%u", button);
    }

    void handleCoreButton(const(XButtonEvent)* be, const(char)* conn, bool moveRuler)
    {
        if (be.type == ButtonRelease)
            return; // wheel scrolls are press+release pairs; count presses
        if (be.button >= 4 && be.button <= 7)
        {
            emitf("scroll", "conn=%s kind=core axis=%s button=%u value=%+d send_event=%d",
                conn, axisOf(be.button), be.button,
                (be.button == 4 || be.button == 6) ? -1 : 1, cast(int) be.send_event);
            countScroll(be.button, false, false, moveRuler);
        }
        else
            emitf("button", "conn=%s kind=core button=%u send_event=%d",
                conn, be.button, cast(int) be.send_event);
    }

    // -- Event loop: poll both connections ----------------------------------
    const fd1 = XConnectionNumber(dpy), fd2 = XConnectionNumber(dpy2);
    while (running)
    {
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case Expose:
                if (ev.xexpose.count == 0)
                {
                    redraw();
                    if (!sawExpose)
                    {
                        sawExpose = true;
                        if (autoExit)
                            enterPhase(0);
                    }
                }
                break;

            case ButtonPress:
            case ButtonRelease: // only selected in phases B and C
                handleCoreButton(&ev.xbutton, "xi2_client", phase >= 1);
                break;

            case KeyPress:
                const ks = XLookupKeysym(&ev.xkey, 0);
                if (ks == 'q' || ks == 0xff1b /* XK_Escape */ )
                    running = false;
                break;

            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
                    running = false;
                break;

            case GenericEvent:
                auto cookie = &ev.xcookie;
                if (XGetEventData(dpy, cookie) && cookie.extension == xiOpcode)
                {
                    const de = cast(const(XIDeviceEvent)*) cookie.data;
                    if (cookie.evtype == XI_ButtonPress)
                    {
                        const emulated = (de.flags & XIPointerEmulated) != 0;
                        // XIAllDevices delivers every event twice: once from
                        // the slave, once as the master copy. Dedupe by
                        // counting only the master copy (the measured trap).
                        const masterCopy = de.deviceid == masterPtr;
                        if (de.detail >= 4 && de.detail <= 7)
                        {
                            emitf("scroll", "conn=xi2_client kind=xi2 axis=%s button=%d "
                                    ~ "value=%+d emulated=%d flags=0x%x device=%d source=%d",
                                axisOf(de.detail), de.detail,
                                (de.detail == 4 || de.detail == 6) ? -1 : 1,
                                cast(int) emulated, de.flags, de.deviceid, de.sourceid);
                            if (masterCopy)
                                countScroll(de.detail, true, emulated, true);
                        }
                        else
                            emitf("button", "conn=xi2_client kind=xi2 button=%d emulated=%d",
                                de.detail, cast(int) emulated);
                    }
                    else if (cookie.evtype == XI_Motion)
                    {
                        // Smooth scrolling: scroll axes ride XI_Motion as
                        // absolute accumulating valuators; delta/increment
                        // = detents. (No XIScrollClass on Xvfb -> never hit.)
                        int idx;
                        foreach (i; 0 .. de.valuators.mask_len * 8)
                        {
                            if (!(de.valuators.mask[i >> 3] & (1 << (i & 7))))
                                continue;
                            const v = de.valuators.values[idx++];
                            foreach (ref ax; axes[0 .. nAxes])
                            {
                                if (ax.number != i
                                    || (ax.deviceid != de.deviceid && ax.deviceid != de.sourceid))
                                    continue;
                                if (ax.last == ax.last) // !NaN: delta is meaningful
                                    emitf("scroll", "conn=xi2_client kind=smooth axis=%s "
                                            ~ "value=%g delta=%g detents=%g emulated=%d",
                                        ax.scrollType == XIScrollTypeVertical ? "v".ptr : "h".ptr,
                                        v, v - ax.last, (v - ax.last) / ax.increment,
                                        cast(int)((de.flags & XIPointerEmulated) != 0));
                                ax.last = v;
                            }
                        }
                    }
                }
                XFreeEventData(dpy, cookie);
                break;

            default:
                break;
            }
        }

        while (XPending(dpy2) > 0) // the core-only second client
        {
            XEvent ev;
            XNextEvent(dpy2, &ev);
            if (ev.type == ButtonPress || ev.type == ButtonRelease)
                handleCoreButton(&ev.xbutton, "core_client", phase == 0);
        }

        if (autoExit && sawExpose && running)
        {
            const now = nowUs();
            if (now - phaseStartUs >= phaseUs)
                enterPhase(phase + 1);
            else if (!driven && sendProbes < 3 * (phase + 1)
                && now - phaseStartUs >= 100_000 * (sendProbes % 3 + 1))
            {
                sendEventProbe(sendProbes % 3 == 2 ? 6 : (sendProbes % 2 == 0 ? 4 : 5));
                ++sendProbes;
            }
            if (lastScrollUs >= 0 && now - lastScrollUs > 400_000)
                endGesture();
        }

        XFlush(dpy);
        pollfd[2] pfds;
        pfds[0].fd = fd1;
        pfds[1].fd = fd2;
        pfds[0].events = pfds[1].events = POLLIN;
        pfds[0].revents = pfds[1].revents = 0;
        poll(pfds.ptr, 2, autoExit ? 5 : -1);
    }

    endGesture();
    XCloseDisplay(dpy2);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
