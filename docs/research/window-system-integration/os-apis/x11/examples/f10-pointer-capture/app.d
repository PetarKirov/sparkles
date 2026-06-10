// X11 F10 demo — pointer: relative/raw motion, lock & confine (the feature
// contract: ../../../features/f10-pointer-capture.md; findings:
// ../../f10-pointer-capture.md). Built on the scaffold (../scaffold/app.d),
// drawing reduced to server-side lines so the pointer machinery is the subject.
//
// Scripted phases (WSI_AUTO_EXIT=1):
//   1 unlocked          XI_Motion abs + XI_RawMotion raw-vs-accelerated pairs
//   2 locked            mouselook: XIGrabDevice + XFixesHideCursor + warp-to-
//                       center; deltas from raw motion; unlock warps back to
//                       the saved position (X11 *can* warp — Wayland can only
//                       hint via set_cursor_position_hint)
//   3 confine_grab      modal: XGrabPointer confine_to = InputOnly child over
//                       the center half (+ second-client AlreadyGrabbed probe)
//   4 confine_barrier   ambient: XFixesCreatePointerBarrier on the rect edges
//   5 barrier_plus_grab grab without confine_to on top of live barriers
// Each confine phase warps to the window corners and reports XQueryPointer
// (`confine_probe target=… actual=… inside_rect=…`). Interactive keys:
// l=lock c=confine-grab b=barriers q=quit.
//
// WSI_DRIVEN=1 stretches each phase to 2 s and suppresses the self-warp
// probes so an external driver (xdotool, see ./run.sh) owns the pointer.
// Headless-safe: no display, or no XInputExtension -> prints `SKIP:`, exit 0.
module app;

import c; // ImportC: Xlib + Xutil + XInput2 + Xfixes + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

// ---------------------------------------------------------------------------
// Constants ImportC cannot export (all #defines): core masks/types, the
// whole of <X11/extensions/XI2.h>, and the XFixes barrier directions from
// <X11/extensions/xfixeswire.h>. Re-declared per the scaffold gotcha.

enum : c_long
{
    KeyPressMask = 1L << 0, ExposureMask = 1L << 15, StructureNotifyMask = 1L << 17,
}

enum // core XEvent.type discriminators; GenericEvent carries all XI2 events
{
    KeyPress = 2, Expose = 12, MapNotify = 19, ClientMessage = 33, GenericEvent = 35,
}

enum False = 0;
enum True = 1;
enum None = 0;
enum CurrentTime = 0;
enum GrabModeAsync = 1;
enum InputOnly = 2;
enum POLLIN = 0x001;

immutable string[5] grabStatusName =
    ["GrabSuccess", "AlreadyGrabbed", "GrabInvalidTime", "GrabNotViewable", "GrabFrozen"];

enum // XI2.h; XI_BarrierHit/Leave require announcing XI >= 2.3
{
    XIAllDevices = 0, XIAllMasterDevices = 1,
    XIMasterPointer = 1, XIMasterKeyboard = 2, XISlavePointer = 3,
    XISlaveKeyboard = 4, XIFloatingSlave = 5,
    XI_ButtonPress = 4, XI_Motion = 6, XI_RawMotion = 17,
    XI_BarrierHit = 25, XI_BarrierLeave = 26,
}

enum // xfixeswire.h: directions a barrier is *transparent* in
{
    BarrierPositiveX = 1, BarrierPositiveY = 2, BarrierNegativeX = 4, BarrierNegativeY = 8,
}

immutable string[5] useName =
    ["MasterPointer", "MasterKeyboard", "SlavePointer", "SlaveKeyboard", "FloatingSlave"];

/// XISetMask is a macro; same bit math, D-side.
void xiSetMask(scope ubyte[] mask, int event) @nogc nothrow
{
    mask[event >> 3] |= cast(ubyte)(1 << (event & 7));
}

/// Select XI2 `events` for `deviceid` on `w` (one XIEventMask, one request).
void xiSelect(Display* dpy, Window w, int deviceid, scope const int[] events) @nogc nothrow
{
    ubyte[4] bits = 0;
    foreach (e; events)
        xiSetMask(bits[], e);
    XIEventMask m;
    m.deviceid = deviceid;
    m.mask_len = bits.length;
    m.mask = bits.ptr;
    XISelectEvents(dpy, w, &m, 1);
}

int main()
{
    initInstrument("x11_f10");
    const autoExit = getenv("WSI_AUTO_EXIT") !is null;
    const driven = getenv("WSI_DRIVEN") !is null; // xdotool owns the pointer
    const unitUs = driven ? 2_000_000 : 420_000; // per-phase duration

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    const screen = XDefaultScreen(dpy);
    const root = XRootWindow(dpy, screen);

    // -- Extension handshakes -------------------------------------------------
    int xiOpcode, xiEventBase, xiErrorBase;
    if (!XQueryExtension(dpy, "XInputExtension", &xiOpcode, &xiEventBase, &xiErrorBase))
    {
        printf("SKIP: no XInputExtension on this display\n");
        XCloseDisplay(dpy);
        return 0;
    }
    int xiMajor = 2, xiMinor = 3; // 2.3: raw events during grabs + barrier events
    const xiStatus = XIQueryVersion(dpy, &xiMajor, &xiMinor);
    emitf("step", "name=XIQueryVersion status=%d server=%d.%d opcode=%d",
        xiStatus, xiMajor, xiMinor, xiOpcode);
    if (xiStatus != 0 /* Success */ || xiMajor < 2)
    {
        printf("SKIP: server does not speak XI2 (got %d.%d)\n", xiMajor, xiMinor);
        XCloseDisplay(dpy);
        return 0;
    }
    int fixMajor, fixMinor, fixEventBase, fixErrorBase;
    const haveFixes = XFixesQueryExtension(dpy, &fixEventBase, &fixErrorBase) != 0
        && XFixesQueryVersion(dpy, &fixMajor, &fixMinor) != 0;
    emitf("step", "name=XFixesQueryVersion server=%d.%d barriers=%d",
        fixMajor, fixMinor, cast(int)(haveFixes && fixMajor >= 5));

    // -- Device dump + master pointer id --------------------------------------
    int masterPtr = 2; // conventional VCP id; replaced by the query below
    int nDevs;
    XIDeviceInfo* devs = XIQueryDevice(dpy, XIAllDevices, &nDevs);
    foreach (i; 0 .. nDevs)
    {
        const d = devs + i;
        emitf("device", "id=%d use=%s attachment=%d name=%s", d.deviceid,
            useName[d.use - 1].ptr, d.attachment, d.name);
        if (d.use == XIMasterPointer)
            masterPtr = d.deviceid;
    }
    XIFreeDeviceInfo(devs);

    // -- Window ----------------------------------------------------------------
    const int width = 480, height = 320;
    Window win = XCreateSimpleWindow(dpy, root, 20, 20, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F10 pointer capture");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d", win, width, height);

    // XI2 selections: raw motion is root-window-only by spec; abs motion +
    // barrier events ride the same root/window split.
    static immutable int[] rootEvents = [XI_RawMotion, XI_BarrierHit, XI_BarrierLeave];
    static immutable int[] winEvents = [XI_Motion, XI_ButtonPress];
    xiSelect(dpy, root, XIAllMasterDevices, rootEvents);
    xiSelect(dpy, win, XIAllMasterDevices, winEvents);
    emit("step name=XISelectEvents root=RawMotion,BarrierHit/Leave win=Motion,ButtonPress");

    GC gc = XDefaultGC(dpy, screen);

    // Window origin in root coordinates (no WM under Xvfb, but don't assume).
    int orgX, orgY;
    {
        Window dummy;
        XTranslateCoordinates(dpy, win, root, 0, 0, &orgX, &orgY, &dummy);
    }
    // The confine region: center half of the window (window + root coords).
    const rx = width / 4, ry = height / 4, rw = width / 2, rh = height / 2;
    const cx = width / 2, cy = height / 2; // lock center (window coords)

    // -- Demo state ------------------------------------------------------------
    Display* dpy2 = null; // second client, for the AlreadyGrabbed probe
    Window confineChild = None;
    PointerBarrier[4] barriers;
    bool locked, confineGrabbed, barriersUp, plainGrabbed;
    int savedX = -1, savedY = -1; // root coords to restore on unlock
    double yaw = 0, pitch = 0; // accumulated raw deltas while locked
    int rawWhileLocked, jitterWarps, recenterWarps;

    void queryPtr(out int rootX, out int rootY, out int winX, out int winY)
    {
        Window r, ch;
        uint mods;
        XQueryPointer(dpy, win, &r, &ch, &rootX, &rootY, &winX, &winY, &mods);
    }

    void redraw()
    {
        XClearWindow(dpy, win);
        if (confineGrabbed || barriersUp)
            XDrawRectangle(dpy, win, gc, rx, ry, rw, rh);
        if (locked)
        {
            const px = cx + cast(int) yaw / 4, py = cy + cast(int) pitch / 4;
            XDrawLine(dpy, win, gc, px - 8, py, px + 8, py);
            XDrawLine(dpy, win, gc, px, py - 8, px, py + 8);
        }
        XFlush(dpy);
    }

    void setLock(bool on)
    {
        if (on == locked)
            return;
        if (on)
        {
            int wx, wy;
            queryPtr(savedX, savedY, wx, wy);
            XFixesHideCursor(dpy, win);
            ubyte[4] bits = 0;
            xiSetMask(bits[], XI_Motion);
            xiSetMask(bits[], XI_ButtonPress);
            XIEventMask m;
            m.deviceid = masterPtr;
            m.mask_len = bits.length;
            m.mask = bits.ptr;
            const st = XIGrabDevice(dpy, masterPtr, win, CurrentTime, None,
                GrabModeAsync, GrabModeAsync, True, &m);
            XWarpPointer(dpy, None, win, 0, 0, 0, 0, cx, cy);
            emitf("lock", "state=on grab=XIGrabDevice status=%s saved=%d,%d",
                grabStatusName[st].ptr, savedX, savedY);
            yaw = pitch = 0;
            rawWhileLocked = jitterWarps = recenterWarps = 0;
        }
        else
        {
            XIUngrabDevice(dpy, masterPtr, CurrentTime);
            XFixesShowCursor(dpy, win);
            XWarpPointer(dpy, None, root, 0, 0, 0, 0, savedX, savedY); // X11 can warp
            XSync(dpy, False);
            int rxp, ryp, wx, wy;
            queryPtr(rxp, ryp, wx, wy);
            emitf("lock", "state=off restored=%d,%d wanted=%d,%d match=%d",
                rxp, ryp, savedX, savedY, cast(int)(rxp == savedX && ryp == savedY));
            emitf("lock_stats", "raw_events=%d jitter_warps=%d recenter_warps=%d "
                    ~ "yaw=%.1f pitch=%.1f", rawWhileLocked, jitterWarps,
                recenterWarps, yaw, pitch);
        }
        locked = on;
        redraw();
    }

    void setConfineGrab(bool on)
    {
        if (on == confineGrabbed)
            return;
        if (on)
        {
            if (confineChild == None)
            {
                // InputOnly child over the center half: invisible, events-only —
                // it exists purely to be a confine_to target. WSI_CONFINE_IO=1
                // swaps in an InputOutput child to probe whether the window
                // class changes the confinement behavior.
                const inputOutput = getenv("WSI_CONFINE_IO") !is null;
                XSetWindowAttributes attrs;
                confineChild = XCreateWindow(dpy, win, rx, ry, rw, rh, 0, 0,
                    inputOutput ? 1 : InputOnly, null, 0, &attrs);
                XMapWindow(dpy, confineChild);
                emitf("step", "name=XCreateWindow class=%s xid=0x%lx",
                    inputOutput ? "InputOutput".ptr : "InputOnly".ptr, confineChild);
            }
            const st = XGrabPointer(dpy, win, True, 0, GrabModeAsync,
                GrabModeAsync, confineChild, None, CurrentTime);
            emitf("confine", "mode=grab rect=%dx%d+%d+%d confine_to=0x%lx status=%s",
                rw, rh, rx, ry, confineChild, grabStatusName[st].ptr);
            // Failure probe: a *second client* grabbing while we hold the grab.
            if (dpy2 is null)
                dpy2 = XOpenDisplay(null);
            if (dpy2 !is null)
            {
                const st2 = XGrabPointer(dpy2, win, True, 0, GrabModeAsync,
                    GrabModeAsync, None, None, CurrentTime);
                if (st2 == 0)
                    XUngrabPointer(dpy2, CurrentTime);
                ubyte[4] bits = 0;
                XIEventMask m;
                m.deviceid = masterPtr;
                m.mask_len = bits.length;
                m.mask = bits.ptr;
                const st3 = XIGrabDevice(dpy2, masterPtr, win, CurrentTime, None,
                    GrabModeAsync, GrabModeAsync, True, &m);
                if (st3 == 0)
                    XIUngrabDevice(dpy2, masterPtr, CurrentTime);
                XFlush(dpy2);
                emitf("grab_probe", "client=second XGrabPointer=%s XIGrabDevice=%s",
                    grabStatusName[st2].ptr, grabStatusName[st3].ptr);
            }
        }
        else
        {
            XUngrabPointer(dpy, CurrentTime);
            emit("confine mode=grab state=off");
        }
        confineGrabbed = on;
        redraw();
    }

    void setBarriers(bool on)
    {
        if (on == barriersUp || !haveFixes || fixMajor < 5)
            return;
        if (on)
        {
            // Four barriers boxing the region (root coords). Each is transparent
            // *inward* only, so the pointer can enter but relative motion cannot
            // leave. Non-modal: no grab, event delivery is untouched.
            const x1 = orgX + rx, y1 = orgY + ry, x2 = x1 + rw, y2 = y1 + rh;
            barriers[0] = XFixesCreatePointerBarrier(dpy, root, x1, y1, x1, y2,
                BarrierPositiveX, 0, null); // left edge: only +x passes
            barriers[1] = XFixesCreatePointerBarrier(dpy, root, x2, y1, x2, y2,
                BarrierNegativeX, 0, null); // right edge: only -x passes
            barriers[2] = XFixesCreatePointerBarrier(dpy, root, x1, y1, x2, y1,
                BarrierPositiveY, 0, null); // top edge: only +y passes
            barriers[3] = XFixesCreatePointerBarrier(dpy, root, x1, y2, x2, y2,
                BarrierNegativeY, 0, null); // bottom edge: only -y passes
            XWarpPointer(dpy, None, win, 0, 0, 0, 0, cx, cy); // start inside
            emitf("confine", "mode=barrier rect=%dx%d+%d+%d root_rect=%d,%d..%d,%d "
                    ~ "ids=%lu,%lu,%lu,%lu", rw, rh, rx, ry, x1, y1, x2, y2,
                barriers[0], barriers[1], barriers[2], barriers[3]);
        }
        else
        {
            foreach (b; barriers)
                XFixesDestroyPointerBarrier(dpy, b);
            emit("confine mode=barrier state=off");
        }
        barriersUp = on;
        redraw();
    }

    void setPlainGrab(bool on) // grab-on-top-of-barriers interaction probe
    {
        if (on == plainGrabbed)
            return;
        if (on)
        {
            const st = XGrabPointer(dpy, win, True, 0, GrabModeAsync,
                GrabModeAsync, None, None, CurrentTime);
            emitf("grab_probe", "client=first XGrabPointer=%s confine_to=None "
                    ~ "barriers_active=%d", grabStatusName[st].ptr, cast(int) barriersUp);
        }
        else
            XUngrabPointer(dpy, CurrentTime);
        plainGrabbed = on;
    }

    /// Warp to a window-local target, round-trip, report where the pointer
    /// actually ended up relative to the confine region.
    void confineProbe(const(char)* mode, int tx, int ty)
    {
        XWarpPointer(dpy, None, win, 0, 0, 0, 0, tx, ty);
        XSync(dpy, False);
        int rxp, ryp, wx, wy;
        queryPtr(rxp, ryp, wx, wy);
        const inside = wx >= rx && wx < rx + rw && wy >= ry && wy < ry + rh;
        emitf("confine_probe", "mode=%s target=%d,%d actual=%d,%d inside_rect=%d",
            mode, tx, ty, wx, wy, cast(int) inside);
    }

    // -- Scripted phases (auto mode) -------------------------------------------
    static immutable string[6] phaseNames = [
        "unlocked", "locked", "confine_grab", "confine_barrier",
        "barrier_plus_grab", "done"
    ];
    int phase = -1;
    long phaseStartUs;
    long nextProbeUs;
    int probeIdx;
    bool sawExpose, running = true;
    static immutable int[2][4] corners = [[8, 8], [471, 8], [8, 311], [471, 311]];

    void enterPhase(int p)
    {
        phase = p;
        phaseStartUs = nowUs();
        nextProbeUs = phaseStartUs + 60_000;
        probeIdx = 0;
        emitf("phase", "name=%s", phaseNames[p].ptr);
        final switch (p)
        {
        case 0:
            break;
        case 1:
            setLock(true);
            break;
        case 2:
            setLock(false);
            setConfineGrab(true);
            break;
        case 3:
            setConfineGrab(false);
            setBarriers(true);
            break;
        case 4:
            setPlainGrab(true);
            break;
        case 5:
            setPlainGrab(false);
            setBarriers(false);
            running = false;
            emit("auto_exit");
            break;
        }
    }

    void runProbe() // self-warp choreography; suppressed when xdotool drives
    {
        static immutable string[3] probeMode = ["grab", "barrier", "barrier_grab"];
        if (phase == 0) // diagonal sweep: feeds abs motion + raw-vs-accel pairs
            XWarpPointer(dpy, None, win, 0, 0, 0, 0,
                40 + probeIdx * 80, 40 + probeIdx * 48);
        else if (phase == 1) // mouselook jitter: warp off-center, handler re-centers
        {
            XWarpPointer(dpy, None, win, 0, 0, 0, 0,
                cx + (probeIdx % 2 == 0 ? 24 : -16), cy + 10 - probeIdx * 4);
            ++jitterWarps;
        }
        else if (phase >= 2 && phase <= 4)
            confineProbe(probeMode[phase - 2].ptr,
                corners[probeIdx & 3][0], corners[probeIdx & 3][1]);
        ++probeIdx;
    }

    // -- Event loop --------------------------------------------------------------
    const fd = XConnectionNumber(dpy);
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

            case KeyPress: // interactive toggles
                const ks = XLookupKeysym(&ev.xkey, 0);
                if (ks == 'l')
                    setLock(!locked);
                else if (ks == 'c')
                    setConfineGrab(!confineGrabbed);
                else if (ks == 'b')
                    setBarriers(!barriersUp);
                else if (ks == 'q' || ks == 0xff1b /* XK_Escape */ )
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
                    switch (cookie.evtype)
                    {
                    case XI_RawMotion:
                        // One event, both flavors: values = post-acceleration/
                        // transform, raw_values = device deltas untouched.
                        const re = cast(const(XIRawEvent)*) cookie.data;
                        double dx = 0, dy = 0, rdx = 0, rdy = 0;
                        int idx;
                        foreach (i; 0 .. re.valuators.mask_len * 8)
                        {
                            if (!(re.valuators.mask[i >> 3] & (1 << (i & 7))))
                                continue;
                            if (i == 0)
                            {
                                dx = re.valuators.values[idx];
                                rdx = re.raw_values[idx];
                            }
                            else if (i == 1)
                            {
                                dy = re.valuators.values[idx];
                                rdy = re.raw_values[idx];
                            }
                            ++idx;
                        }
                        const accelEq = dx == rdx && dy == rdy;
                        if (locked)
                        {
                            yaw += rdx;
                            pitch += rdy;
                            ++rawWhileLocked;
                            emitf("pointer", "rel dx=%.2f dy=%.2f raw=1 "
                                    ~ "accel_dx=%.2f accel_dy=%.2f accel_equal=%d "
                                    ~ "yaw=%.1f pitch=%.1f",
                                rdx, rdy, dx, dy, cast(int) accelEq, yaw, pitch);
                        }
                        else
                            emitf("raw_motion", "raw_dx=%.2f raw_dy=%.2f "
                                    ~ "accel_dx=%.2f accel_dy=%.2f accel_equal=%d device=%d",
                                rdx, rdy, dx, dy, cast(int) accelEq, re.deviceid);
                        break;

                    case XI_Motion:
                        const de = cast(const(XIDeviceEvent)*) cookie.data;
                        const mx = cast(int) de.event_x, my = cast(int) de.event_y;
                        if (locked)
                        {
                            if (mx != cx || my != cy) // recenter (skip our own echo)
                            {
                                XWarpPointer(dpy, None, win, 0, 0, 0, 0, cx, cy);
                                ++recenterWarps;
                            }
                        }
                        else
                            emitf("pointer", "abs x=%d y=%d root=%.0f,%.0f", mx, my,
                                de.root_x, de.root_y);
                        break;

                    case XI_BarrierHit:
                    case XI_BarrierLeave:
                        const be = cast(const(XIBarrierEvent)*) cookie.data;
                        emitf(cookie.evtype == XI_BarrierHit
                                ? "barrier_hit".ptr : "barrier_leave".ptr,
                            "barrier=%lu root=%.0f,%.0f blocked_dx=%.1f blocked_dy=%.1f",
                            be.barrier, be.root_x, be.root_y, be.dx, be.dy);
                        break;

                    default:
                        break;
                    }
                }
                XFreeEventData(dpy, cookie);
                break;

            default:
                break;
            }
        }

        if (autoExit && sawExpose && running)
        {
            const now = nowUs();
            if (now - phaseStartUs >= unitUs)
                enterPhase(phase + 1);
            else if (!driven && now >= nextProbeUs)
            {
                runProbe();
                nextProbeUs = now + 60_000;
            }
            if (locked)
                redraw(); // keep the crosshair live while deltas accumulate
        }

        XFlush(dpy);
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 5 : -1);
    }

    // -- Teardown ----------------------------------------------------------------
    setPlainGrab(false);
    setBarriers(false);
    setConfineGrab(false);
    if (locked)
        setLock(false);
    if (dpy2 !is null)
        XCloseDisplay(dpy2);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
