// Minimal X11 window — the irreducible Xlib sequence that GLFW/SDL/winit wrap on
// Linux: XOpenDisplay -> XCreateSimpleWindow -> XMapWindow -> XNextEvent. All
// types and functions come from the real <X11/Xlib.h> via the ImportC shim
// (`c.c`); nothing is hand-declared. See ../index.md (the X11 OS-API survey).
//
// Headless-safe: if no X server is reachable, XOpenDisplay returns null, we print
// `SKIP:` and exit 0. With a live $DISPLAY it opens a real window, draws on the
// first Expose, and exits (a real app loops until WM_DELETE_WINDOW).
module app;

import c; // ImportC: <X11/Xlib.h>
import core.stdc.config : c_long;
import core.stdc.stdio : printf;

// Xlib exposes these as expression/object-like macros (e.g. `(1L<<15)`), which
// ImportC does not reliably import — re-declare the few we use, per the ImportC
// guide. (Function macros DefaultScreen/RootWindow/BlackPixel are likewise
// avoided in favour of their real function forms XDefaultScreen/XRootWindow/….)
enum : c_long
{
    ExposureMask = 1L << 15,
    KeyPressMask = 1L << 0,
    StructureNotifyMask = 1L << 17,
}

enum
{
    Expose = 12,
    KeyPress = 2,
    ClientMessage = 33,
}

int main()
{
    // 1. Connect to the X server named by $DISPLAY (null = default).
    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0; // green on a headless runner
    }
    scope (exit)
        XCloseDisplay(dpy);

    const screen = XDefaultScreen(dpy);
    const root = XRootWindow(dpy, screen);

    // 2. Create a top-level window as a child of the root window.
    Window win = XCreateSimpleWindow(dpy, root,
        0, 0, 480, 320, // x, y, width, height
        1, // border width
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 (Xlib)");

    // 3. Route the window-manager close button to us as a ClientMessage.
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);

    // 4. Subscribe to events, then map (show) the window.
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask);
    XMapWindow(dpy, win);

    // 5. Event loop. A real app loops until WM_DELETE_WINDOW / a key; here we draw
    //    once on the first Expose and exit so CI never blocks.
    GC gc = XDefaultGC(dpy, screen);
    XEvent ev;
    while (true)
    {
        XNextEvent(dpy, &ev);
        if (ev.type == Expose)
        {
            XSetForeground(dpy, gc, XBlackPixel(dpy, screen));
            XFillRectangle(dpy, win, gc, 190, 130, 100, 60);
            XFlush(dpy);
            printf("ok: mapped a 480x320 window and drew on Expose\n");
            return 0;
        }
        if (ev.type == KeyPress || ev.type == ClientMessage)
            return 0;
    }
}
