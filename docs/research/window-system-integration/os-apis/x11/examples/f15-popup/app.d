// X11 F15 demo — popup with grab (../../f15-popup.md, spec
// ../../../features/f15-popup.md). Evolves the scaffold (../scaffold/app.d)
// event loop; rendering is server-side XFillRectangle (the subject is the
// secondary-surface + grab model, not pixels).
//
// What it exercises:
//   * a menu-like popup: override-redirect window (CWOverrideRedirect — the
//     WM never sees it) + XGrabPointer (owner_events=False,
//     ButtonPress|ButtonRelease|PointerMotion) + XGrabKeyboard, raised with
//     XRaiseWindow; 3 fake items with hover highlight (motion inside the
//     grab); item click activates; outside click dismisses (the grab is WHY
//     the popup sees clicks it does not own); Esc dismisses
//   * grab routing choice: ONE pointer grab on the first popup,
//     owner_events=False, so every pointer event arrives relative to the
//     grab window and hit-testing is done in root coordinates against the
//     app-known popup-chain rects (the alternative — owner_events=True or
//     re-grabbing on the submenu — is discussed in the findings doc)
//   * edge correctness: opening near the bottom-right screen corner — the
//     APP must clamp; the math is logged (no compositor/positioner exists)
//   * nested submenu one level deep (second override-redirect window),
//     opened on hovering item 2; stacking verified via XQueryTree
//   * probes: XGrabPointer return codes when a second client already holds
//     a grab (AlreadyGrabbed); event starvation of a second client's window
//     while the grab is held (driven mode, see run.sh)
//
// Modes: WSI_AUTO_EXIT=1 self-drives placement/stacking/grab-code probes
// (no synthetic input needed) and exits 0. WSI_DRIVEN=1 waits ~14 s for
// xdotool-injected clicks/keys (run.sh): right-click opens the menu at the
// pointer, hover/submenu/item-click/outside-click/Esc are all real pointer
// events through the grab. Headless-safe: no display -> `SKIP:`, exit 0.
module app;

import c; // ImportC: Xlib + Xutil + Xatom (+ unused XShm) + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : getenv;

// Macros ImportC cannot export, re-declared (see ../scaffold/app.d):
enum : c_long
{
    KeyPressMask = 1L << 0,
    ButtonPressMask = 1L << 2,
    ButtonReleaseMask = 1L << 3,
    PointerMotionMask = 1L << 6,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
    FocusChangeMask = 1L << 21,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    ButtonPress = 4,
    ButtonRelease = 5,
    MotionNotify = 6,
    FocusIn = 9,
    FocusOut = 10,
    Expose = 12,
    MapNotify = 19,
    ConfigureNotify = 22,
    ClientMessage = 33,
}

enum : c_ulong // XCreateWindow attribute mask bits
{
    CWBackPixel = 1L << 1,
    CWBorderPixel = 1L << 3,
    CWOverrideRedirect = 1L << 9,
    CWSaveUnder = 1L << 10,
    CWEventMask = 1L << 11,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum None = 0;
enum CurrentTime = 0;
enum GrabModeAsync = 1;
enum InputOutput = 1;
enum CopyFromParent = 0;
enum XK_Escape = 0xff1b;

// XGrabPointer/XGrabKeyboard return codes (<X11/X.h>):
static immutable string[5] grabCodes =
    ["GrabSuccess", "AlreadyGrabbed", "GrabInvalidTime", "GrabNotViewable", "GrabFrozen"];

// FocusIn/FocusOut mode decode (<X11/X.h>) — grab-generated focus events
// (NotifyGrab/NotifyUngrab) are NOT window-manager focus:
static immutable string[4] focusModes =
    ["NotifyNormal", "NotifyGrab", "NotifyUngrab", "NotifyWhileGrabbed"];

enum itemH = 24, menuW = 160, menuItems = 3;
enum menuH = itemH * menuItems;

struct Menu
{
    Window win;
    int x, y; // root coordinates
    bool open;
    int hover = -1;
}

struct Demo
{
    Display* dpy, dpy2; // dpy2: the independent "second client" connection
    Window root, main, second;
    int screen, screenW, screenH;
    GC gc;
    Atom wmProtocols, wmDelete;
    Menu[2] menus; // [0] the popup menu, [1] its submenu
    bool running = true, grabbed, swallowRelease;
    int opens, dismissals, activations, hoverChanges;
    int secondClientEvents, popupFocusEvents;
}

__gshared int g_xerrors;
extern (C) int onXError(Display* dpy, XErrorEvent* e) @nogc nothrow
{
    ++g_xerrors;
    emitf("x_error", "code=%d request=%d", e.error_code, e.request_code);
    return 0;
}

Window makeOverrideRedirect(ref Demo d, int x, int y, uint w, uint h) @nogc nothrow
{
    XSetWindowAttributes attrs;
    attrs.override_redirect = True; // the WM neither decorates nor manages it
    attrs.background_pixel = 0x202020;
    attrs.border_pixel = 0x808080;
    attrs.save_under = True;
    attrs.event_mask = ExposureMask | FocusChangeMask;
    return XCreateWindow(d.dpy, d.root, x, y, w, h, 1, CopyFromParent,
        InputOutput, null /* CopyFromParent visual */ ,
        CWBackPixel | CWBorderPixel | CWOverrideRedirect | CWSaveUnder | CWEventMask,
        &attrs);
}

void drawMenu(ref Demo d, ref Menu m) @nogc nothrow
{
    if (!m.open)
        return;
    foreach (i; 0 .. menuItems)
    {
        XSetForeground(d.dpy, d.gc, i == m.hover ? 0x6090d0 : 0x383838);
        XFillRectangle(d.dpy, m.win, d.gc, 2, i * itemH + 2,
            menuW - 4, itemH - 4);
    }
    XFlush(d.dpy);
}

/// Is the popup (or submenu) on top of the stack? XQueryTree returns root's
/// children bottom-to-top; override-redirect windows fight no WM for slots,
/// but a WM may still restack other windows around them.
void logStacking(ref Demo d, Window expectTop, const(char)* label) @nogc nothrow
{
    Window rootRet, parentRet;
    Window* children;
    uint n;
    XQueryTree(d.dpy, d.root, &rootRet, &parentRet, &children, &n);
    const top = n ? children[n - 1] : 0;
    emitf("stacking", "probe=%s topmost=0x%lx expected=0x%lx on_top=%d",
        label, top, expectTop, cast(int)(top == expectTop));
    if (children !is null)
        XFree(children);
}

/// Open the popup at the pointer/anchor with app-side edge clamping — on X11
/// nobody else will move it (contrast: a Wayland xdg_positioner lets the
/// compositor slide/flip it). The clamp math is the finding; log it.
void openMenu(ref Demo d, size_t idx, int anchorX, int anchorY,
    const(char)* cause) @nogc nothrow
{
    Menu* m = &d.menus[idx];
    int x = anchorX, y = anchorY;
    if (x + menuW + 2 > d.screenW)
        x = d.screenW - menuW - 2;
    if (y + menuH + 2 > d.screenH)
        y = d.screenH - menuH - 2;
    emitf("popup_open", "menu=%zu anchor=%d,%d gravity=bottom-right cause=%s",
        idx, anchorX, anchorY, cause);
    if (m.win == None)
        m.win = makeOverrideRedirect(d, x, y, menuW, menuH);
    else
        XMoveWindow(d.dpy, m.win, x, y);
    m.x = x;
    m.y = y;
    m.open = true;
    m.hover = -1;
    XMapRaised(d.dpy, m.win); // map + XRaiseWindow in one request
    emitf("popup_placed", "menu=%zu rect=%dx%d+%d+%d repositioned=%d "
            ~ "clamp=anchor+size>screen(%dx%d)", idx, menuW, menuH, x, y,
        cast(int)(x != anchorX || y != anchorY), d.screenW, d.screenH);
    ++d.opens;

    if (idx == 0 && !d.grabbed)
    {
        // owner_events=False: during the grab EVERY pointer event in the
        // whole session is reported to THIS client, relative to the grab
        // window — including clicks over windows we do not own. That is
        // the entire outside-click-dismissal mechanism.
        const pg = XGrabPointer(d.dpy, m.win, False,
            cast(uint)(ButtonPressMask | ButtonReleaseMask | PointerMotionMask),
            GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
        const kg = XGrabKeyboard(d.dpy, m.win, False, GrabModeAsync,
            GrabModeAsync, CurrentTime);
        emitf("grab", "state=acquired pointer=%s keyboard=%s owner_events=0",
            grabCodes[pg].ptr, grabCodes[kg].ptr);
        d.grabbed = pg == 0;
    }
    logStacking(d, m.win, "after_map_raised");
}

void dismissAll(ref Demo d, const(char)* cause) @nogc nothrow
{
    if (d.grabbed)
    {
        XUngrabPointer(d.dpy, CurrentTime);
        XUngrabKeyboard(d.dpy, CurrentTime);
        emit("grab state=released");
        d.grabbed = false;
    }
    foreach_reverse (ref m; d.menus)
        if (m.open)
        {
            XUnmapWindow(d.dpy, m.win);
            m.open = false;
        }
    XFlush(d.dpy);
    ++d.dismissals;
    emitf("popup_dismiss", "cause=%s", cause);
}

/// Root-coordinate hit test across the popup chain (submenu first: it is on
/// top). Returns menu index, item via `item`; -1 if outside everything.
int hitTest(ref Demo d, int xr, int yr, out int item) @nogc nothrow
{
    foreach_reverse (i; 0 .. d.menus.length)
    {
        const m = &d.menus[i];
        if (m.open && xr >= m.x && xr < m.x + menuW && yr >= m.y && yr < m.y + menuH)
        {
            item = (yr - m.y) / itemH;
            return cast(int) i;
        }
    }
    item = -1;
    return -1;
}

/// The "another grab already exists" probe: the second client grabs first,
/// then we try — XGrabPointer returns AlreadyGrabbed (1) instead of any
/// event; the failure is a synchronous return code, not an error.
void probeGrabConflict(ref Demo d) @nogc nothrow
{
    const g2 = XGrabPointer(d.dpy2, d.second, False,
        cast(uint) ButtonPressMask, GrabModeAsync, GrabModeAsync,
        None, None, CurrentTime);
    XSync(d.dpy2, False);
    emitf("probe", "name=second_client_grab result=%s", grabCodes[g2].ptr);
    const g1 = XGrabPointer(d.dpy, d.main, False,
        cast(uint) ButtonPressMask, GrabModeAsync, GrabModeAsync,
        None, None, CurrentTime);
    emitf("probe", "name=our_grab_while_other_holds result=%s", grabCodes[g1].ptr);
    XUngrabPointer(d.dpy2, CurrentTime);
    XSync(d.dpy2, False);
    const g3 = XGrabPointer(d.dpy, d.main, False,
        cast(uint) ButtonPressMask, GrabModeAsync, GrabModeAsync,
        None, None, CurrentTime);
    emitf("probe", "name=our_grab_after_release result=%s", grabCodes[g3].ptr);
    if (g3 == 0)
        XUngrabPointer(d.dpy, CurrentTime);
    XFlush(d.dpy);
}

void handleMotion(ref Demo d, int xr, int yr) @nogc nothrow
{
    int item;
    const mi = hitTest(d, xr, yr, item);
    if (mi < 0)
        return;
    Menu* m = &d.menus[mi];
    if (item != m.hover)
    {
        m.hover = item;
        ++d.hoverChanges;
        emitf("hover", "menu=%d item=%d", mi, item);
        drawMenu(d, *m);
        // Item 2 of the root menu carries the submenu: open it flush with
        // the item's right edge; hovering items 0/1 closes it again.
        if (mi == 0 && item == menuItems - 1 && !d.menus[1].open)
            openMenu(d, 1, m.x + menuW - 4, m.y + item * itemH, "submenu_hover");
        else if (mi == 0 && item < menuItems - 1 && d.menus[1].open)
        {
            XUnmapWindow(d.dpy, d.menus[1].win);
            d.menus[1].open = false;
            emit("popup_dismiss cause=submenu_parent_hover menu=1");
        }
    }
}

int main()
{
    initInstrument("f15_x11");
    const autoExit = getenv("WSI_AUTO_EXIT") !is null;
    const driven = getenv("WSI_DRIVEN") !is null;

    Demo d;
    d.dpy = XOpenDisplay(null);
    if (d.dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    XSetErrorHandler(&onXError);
    d.screen = XDefaultScreen(d.dpy);
    d.root = XRootWindow(d.dpy, d.screen);
    d.screenW = XDisplayWidth(d.dpy, d.screen);
    d.screenH = XDisplayHeight(d.dpy, d.screen);
    d.gc = XDefaultGC(d.dpy, d.screen);
    emitf("step", "name=XOpenDisplay fd=%d screen=%dx%d",
        XConnectionNumber(d.dpy), d.screenW, d.screenH);

    d.main = XCreateSimpleWindow(d.dpy, d.root, 20, 20, 480, 320, 1,
        XBlackPixel(d.dpy, d.screen), 0x4070b0);
    XStoreName(d.dpy, d.main, "Sparkles \xc2\xb7 X11 F15 popup");
    d.wmProtocols = XInternAtom(d.dpy, "WM_PROTOCOLS", False);
    d.wmDelete = XInternAtom(d.dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(d.dpy, d.main, &d.wmDelete, 1);
    // ButtonReleaseMask matters: the release of the popup-opening click can
    // reach the server BEFORE the XGrabPointer issued in response to the
    // press — it is then delivered by the normal masks, not the grab.
    XSelectInput(d.dpy, d.main, ExposureMask | KeyPressMask | ButtonPressMask
            | ButtonReleaseMask | StructureNotifyMask);
    XMapWindow(d.dpy, d.main);
    emitf("window_created", "xid=0x%lx size=480x320+20+20", d.main);

    // The independent second client: its own connection, its own window. It
    // exists to measure what a grab does to everyone else (run.sh clicks it
    // while the popup grab is held: it must receive nothing).
    d.dpy2 = XOpenDisplay(null);
    d.second = XCreateSimpleWindow(d.dpy2, XRootWindow(d.dpy2, 0), 520, 20,
        100, 100, 1, 0, 0xb0b040);
    XStoreName(d.dpy2, d.second, "Sparkles \xc2\xb7 F15 second client");
    XSelectInput(d.dpy2, d.second, ButtonPressMask | ExposureMask);
    XMapWindow(d.dpy2, d.second);
    XFlush(d.dpy2);
    emitf("second_client", "fd=%d xid=0x%lx size=100x100+520+20",
        XConnectionNumber(d.dpy2), d.second);

    // Self-driven probe schedule (µs since init), driven mode skips it:
    enum Act { open, openSub, dismiss, edgeOpen, grabConflict, quit }
    static immutable struct Step { long t; Act a; }
    static immutable Step[8] schedule = [
        {400_000, Act.open}, {700_000, Act.openSub}, {1_000_000, Act.dismiss},
        {1_300_000, Act.edgeOpen}, {1_700_000, Act.dismiss},
        {2_000_000, Act.grabConflict}, {2_400_000, Act.quit}, {0, Act.quit},
    ];
    size_t nextStep;
    const deadline = driven ? 14_000_000 : 4_000_000;

    const fd = XConnectionNumber(d.dpy);
    const fd2 = XConnectionNumber(d.dpy2);
    while (d.running)
    {
        while (XPending(d.dpy) > 0)
        {
            XEvent ev;
            XNextEvent(d.dpy, &ev);
            switch (ev.type)
            {
            case ButtonPress:
                d.swallowRelease = false; // the swallow applies only to the
                // release that immediately follows the opening press
                emitf("button", "state=press n=%d window=0x%lx pos=%d,%d root=%d,%d "
                        ~ "grabbed=%d", ev.xbutton.button, ev.xbutton.window,
                    ev.xbutton.x, ev.xbutton.y, ev.xbutton.x_root,
                    ev.xbutton.y_root, cast(int) d.grabbed);
                if (d.grabbed)
                {
                    int item;
                    if (hitTest(d, ev.xbutton.x_root, ev.xbutton.y_root, item) < 0)
                        dismissAll(d, "outside_click");
                }
                else if (ev.xbutton.window == d.main && ev.xbutton.button == 3)
                {
                    openMenu(d, 0, ev.xbutton.x_root, ev.xbutton.y_root, "right_click");
                    // The release of the click that OPENED the menu would
                    // otherwise instantly activate the item now under the
                    // pointer — every menu toolkit swallows it.
                    d.swallowRelease = true;
                }
                break;
            case ButtonRelease:
                if (d.swallowRelease)
                {
                    d.swallowRelease = false;
                    emit("button state=release swallowed=open_click");
                }
                else if (d.grabbed)
                {
                    int item;
                    const mi = hitTest(d, ev.xbutton.x_root, ev.xbutton.y_root, item);
                    if (mi >= 0)
                    {
                        ++d.activations;
                        emitf("popup_item_activated", "menu=%d item=%d", mi, item);
                        dismissAll(d, "item_activated");
                    }
                }
                break;
            case MotionNotify:
                if (d.grabbed)
                    handleMotion(d, ev.xmotion.x_root, ev.xmotion.y_root);
                break;
            case KeyPress:
                const sym = XLookupKeysym(&ev.xkey, 0);
                emitf("key", "sym=0x%lx via_grab=%d", sym, cast(int) d.grabbed);
                if (sym == XK_Escape && d.grabbed)
                    dismissAll(d, "esc");
                else if (sym == 'q' && !d.grabbed)
                    d.running = false;
                break;
            case FocusIn:
            case FocusOut:
                // Popups never receive WM focus — keyboard arrives only via
                // the grab. Any focus event reaching a popup is the server's
                // grab bookkeeping; the mode says so.
                foreach (ref m; d.menus)
                    if (ev.xany.window == m.win)
                    {
                        ++d.popupFocusEvents;
                        emitf("focus", "window=0x%lx state=%s mode=%s",
                            ev.xany.window, ev.type == FocusIn ? "in".ptr : "out".ptr,
                            focusModes[ev.xfocus.mode].ptr);
                    }
                break;
            case Expose:
                if (ev.xexpose.count != 0)
                    break;
                foreach (ref m; d.menus)
                    if (ev.xexpose.window == m.win)
                        drawMenu(d, m);
                break;
            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == d.wmDelete)
                    d.running = false;
                break;
            default:
                break;
            }
        }

        // Drain the second client's queue — its silence during the grab is
        // the starvation measurement.
        while (XPending(d.dpy2) > 0)
        {
            XEvent ev2;
            XNextEvent(d.dpy2, &ev2);
            if (ev2.type == ButtonPress)
            {
                ++d.secondClientEvents;
                emitf("second_client", "event=button_press pos=%d,%d during_grab=%d",
                    ev2.xbutton.x, ev2.xbutton.y, cast(int) d.grabbed);
            }
        }

        if (autoExit && !driven && nextStep < schedule.length
            && nowUs() >= schedule[nextStep].t)
        {
            final switch (schedule[nextStep].a)
            {
            case Act.open:
                openMenu(d, 0, 200, 200, "auto");
                break;
            case Act.openSub:
                d.menus[0].hover = menuItems - 1;
                drawMenu(d, d.menus[0]);
                openMenu(d, 1, d.menus[0].x + menuW - 4,
                    d.menus[0].y + (menuItems - 1) * itemH, "auto");
                break;
            case Act.dismiss:
                dismissAll(d, "auto");
                break;
            case Act.edgeOpen:
                openMenu(d, 0, d.screenW - 10, d.screenH - 10, "auto_edge");
                break;
            case Act.grabConflict:
                probeGrabConflict(d);
                break;
            case Act.quit:
                d.running = false;
                break;
            }
            ++nextStep;
            if (nextStep == schedule.length - 1)
                break; // sentinel reached
        }
        if ((autoExit || driven) && nowUs() > deadline)
        {
            emit("auto_exit reason=deadline");
            break;
        }

        pollfd[2] pfd;
        pfd[0].fd = fd;
        pfd[0].events = POLLIN;
        pfd[1].fd = fd2;
        pfd[1].events = POLLIN;
        poll(pfd.ptr, 2, (autoExit || driven) ? 20 : -1);
    }

    emitf("summary", "opens=%d dismissals=%d activations=%d hover_changes=%d "
            ~ "second_client_events=%d popup_focus_events=%d x_errors=%d",
        d.opens, d.dismissals, d.activations, d.hoverChanges,
        d.secondClientEvents, d.popupFocusEvents, g_xerrors);
    XCloseDisplay(d.dpy2);
    XCloseDisplay(d.dpy);
    return 0;
}
