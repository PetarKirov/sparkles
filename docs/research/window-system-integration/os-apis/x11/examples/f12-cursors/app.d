// X11 F12 demo — cursors (../../../features/f12-cursors.md). Built on the
// scaffold (../scaffold/app.d): same ImportC binding style, same poll(2)
// readiness loop, same instrument.d event log. Rendering is grid lines via
// the default GC — the pixels that matter here are the CURSOR's, and those
// are composited by the SERVER (contrast Wayland, where the client renders
// its cursor into a wl_surface and runs its own animation frame timer).
//
// A 3x3 hover-zone grid: the eight edge/corner zones carry the eight resize
// cursors; the centre zone cycles default -> text -> pointer -> a custom ARGB
// bullseye -> an animated 'watch' on each re-entry. Every switch is one
// `XDefineCursor` + `XFlush`, logged as `cursor_set`. Four mechanisms are
// exercised and distinguished in the log:
//
//   * font   — `XCreateFontCursor(dpy, glyph)`: the core `cursor` font baked
//     into every X server since X11R1; glyph ids from <X11/cursorfont.h>
//     (macros — re-declared below per the scaffold ImportC gotcha).
//   * theme  — `XcursorLibraryLoadCursor(dpy, "nw-resize")`: libXcursor file
//     lookup through XCURSOR_THEME/XCURSOR_PATH/XCURSOR_SIZE (+ the display's
//     Xcursor.theme/.size resources). Startup logs the whole resolution:
//     `XcursorGetTheme`, `XcursorGetDefaultSize`, the env vars, and for every
//     shape BOTH load results — the run.sh driver varies the env and measures
//     which knobs libXcursor honors.
//   * custom — `XcursorImageCreate(24,24)` filled with raw premultiplied-ARGB
//     (a bullseye, hotspot 12,12) -> `XcursorImageLoadCursor`. The legacy
//     core alternative, `XCreatePixmapCursor`, takes a 1-bit source + mask
//     and exactly two colors — libXcursor is the only road to full ARGB.
//   * animated — `XcursorLibraryLoadImages("watch", ...)` -> N frames with
//     per-frame delays -> `XcursorImagesLoadCursor`. One call, then the
//     SERVER animates; the client never wakes up again.
//
// Zones are driven either by the built-in XWarpPointer storm (WSI_AUTO_EXIT=1,
// disable with WSI_NO_WARP=1) or externally via `xdotool mousemove` (run.sh).
// WSI_DURATION_MS bounds the run (default 8 s). Headless-safe: no X server ->
// prints `SKIP:` and exits 0. Findings: ../../f12-cursors.md.
module app;

import c; // ImportC: Xlib + Xcursor + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;

// ---------------------------------------------------------------------------
// Constants Xlib exposes as macros that ImportC cannot import; re-declared
// per the scaffold gotcha (../../scaffold.md).

enum : c_long
{
    KeyPressMask = 1L << 0,
    EnterWindowMask = 1L << 4,
    LeaveWindowMask = 1L << 5,
    PointerMotionMask = 1L << 6,
    ExposureMask = 1L << 15,
    StructureNotifyMask = 1L << 17,
}

enum // XEvent.type discriminators
{
    KeyPress = 2,
    MotionNotify = 6,
    EnterNotify = 7,
    LeaveNotify = 8,
    Expose = 12,
    ConfigureNotify = 22,
    ClientMessage = 33,
}

enum False = 0;
enum True = 1;
enum None = 0;
enum POLLIN = 0x001;

// <X11/cursorfont.h> glyph ids (the header is #defines only). Each shape in
// the core `cursor` font; the full table is in the header / XCreateFontCursor(3).
enum : uint
{
    XC_bottom_left_corner = 12,
    XC_bottom_right_corner = 14,
    XC_bottom_side = 16,
    XC_hand2 = 60,
    XC_left_ptr = 68,
    XC_left_side = 70,
    XC_right_side = 96,
    XC_top_left_corner = 134,
    XC_top_right_corner = 136,
    XC_top_side = 138,
    XC_watch = 150,
    XC_xterm = 152,
}

// ---------------------------------------------------------------------------
// The shape vocabulary: one row per shape, carrying its cursor-spec themed
// name (the names cursor-shape-v1 / CSS standardized) AND its core-font glyph.

struct Shape
{
    const(char)* name; // themed (cursor-spec/CSS) name for XcursorLibraryLoadCursor
    uint glyph; // core cursor-font id for XCreateFontCursor
    Cursor font; // loaded font cursor
    Cursor theme; // loaded themed cursor (0 = lookup failed)
}

// Index 0..8 = grid zones (centre zone 4 is handled dynamically); 9..11 = the
// centre-cycle shapes (default arrow, text I-beam, hand/link).
__gshared Shape[12] g_shapes = [
    Shape("nw-resize", XC_top_left_corner),
    Shape("n-resize", XC_top_side),
    Shape("ne-resize", XC_top_right_corner),
    Shape("w-resize", XC_left_side),
    Shape("default", XC_left_ptr), // placeholder for the centre zone
    Shape("e-resize", XC_right_side),
    Shape("sw-resize", XC_bottom_left_corner),
    Shape("s-resize", XC_bottom_side),
    Shape("se-resize", XC_bottom_right_corner),
    Shape("default", XC_left_ptr),
    Shape("text", XC_xterm),
    Shape("pointer", XC_hand2),
];

/// Load one shape through BOTH mechanisms and log both results: theme=0x0
/// means the libXcursor lookup failed end-to-end (no theme file found AND no
/// core fallback in libXcursor's name->glyph table for this name).
void loadShape(Display* dpy, ref Shape s) @nogc nothrow
{
    s.font = XCreateFontCursor(dpy, s.glyph);
    s.theme = XcursorLibraryLoadCursor(dpy, s.name);
    emitf("cursor_load", "name=%s font_glyph=%d font=0x%lx theme=0x%lx",
        s.name, s.glyph, s.font, s.theme);
}

/// Pick a shape's cursor, preferring the themed one; returns the path label.
const(char)* pick(const ref Shape s, out Cursor cur) @nogc nothrow
{
    if (s.theme != 0)
    {
        cur = s.theme;
        return "theme";
    }
    cur = s.font;
    return "font";
}

/// Log what the theme actually resolves a name to at the file level: frame
/// count, nominal size vs actual pixel size, per-frame delay. This is also
/// the F12 "log chosen size" requirement — the size XcursorGetDefaultSize
/// picked is what the library loads.
void logShapeImages(const(char)* name, const(char)* theme, int size) @nogc nothrow
{
    XcursorImages* imgs = XcursorLibraryLoadImages(name, theme, size);
    if (imgs is null || imgs.nimage == 0)
    {
        emitf("cursor_images", "name=%s theme=%s size=%d frames=0 (lookup failed)",
            name, theme is null ? "(null)".ptr : theme, size);
        if (imgs !is null)
            XcursorImagesDestroy(imgs);
        return;
    }
    emitf("cursor_images", "name=%s theme=%s size_requested=%d frames=%d "
            ~ "frame0=%ux%u nominal=%u hot=%u,%u delay_ms=%u",
        name, theme is null ? "(null)".ptr : theme, size, imgs.nimage,
        imgs.images[0].width, imgs.images[0].height, imgs.images[0].size,
        imgs.images[0].xhot, imgs.images[0].yhot, imgs.images[0].delay);
    XcursorImagesDestroy(imgs);
}

/// The custom cursor: a 24x24 premultiplied-ARGB bullseye, hotspot dead
/// centre (12,12) — a hotspot the arrow's (0,0) habit would get wrong.
Cursor makeBullseye(Display* dpy) @nogc nothrow
{
    XcursorImage* img = XcursorImageCreate(24, 24);
    if (img is null)
        return 0;
    img.xhot = 12;
    img.yhot = 12;
    foreach (y; 0 .. 24)
        foreach (x; 0 .. 24)
        {
            const dx = x - 11.5, dy = y - 11.5;
            const r2 = dx * dx + dy * dy;
            uint px = 0x00000000; // transparent outside
            if (r2 <= 2.5 * 2.5)
                px = 0xff000000; // black centre dot
            else if (r2 <= 5.5 * 5.5)
                px = 0xffffffff; // white ring
            else if (r2 <= 8.5 * 8.5)
                px = 0xffcc2222; // red ring
            else if (r2 <= 11.5 * 11.5)
                px = 0xffffffff; // white rim
            img.pixels[y * 24 + x] = px; // premultiplied ARGB (alpha 0xff/0)
        }
    Cursor cur = XcursorImageLoadCursor(dpy, img);
    XcursorImageDestroy(img);
    emitf("cursor_custom", "api=XcursorImageLoadCursor size=24x24 hotspot=12,12 cursor=0x%lx "
            ~ "(legacy XCreatePixmapCursor: 1-bit source+mask, exactly 2 colors)", cur);
    return cur;
}

// ---------------------------------------------------------------------------

int main()
{
    initInstrument("f12_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const envNoWarp = getenv("WSI_NO_WARP");
    const warp = autoExit && (envNoWarp is null || envNoWarp[0] != '1');
    const envDur = getenv("WSI_DURATION_MS");
    const durationMs = envDur !is null ? atoi(envDur) : 8_000;

    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(dpy));

    const screen = XDefaultScreen(dpy);
    Window root = XRootWindow(dpy, screen);

    // -- Theme resolution: log every input libXcursor consults --------------
    const(char)* envTheme = getenv("XCURSOR_THEME"), envPath = getenv("XCURSOR_PATH"),
        envSize = getenv("XCURSOR_SIZE");
    char* theme = XcursorGetTheme(dpy);
    const size = XcursorGetDefaultSize(dpy);
    emitf("xcursor_env", "XCURSOR_THEME=%s XCURSOR_PATH=%s XCURSOR_SIZE=%s",
        envTheme ? envTheme : "(unset)", envPath ? envPath : "(unset)",
        envSize ? envSize : "(unset)");
    emitf("xcursor_resolved", "XcursorGetTheme=%s XcursorGetDefaultSize=%d "
            ~ "XcursorSupportsARGB=%d",
        theme ? theme : "(null)", size, cast(int) XcursorSupportsARGB(dpy));

    // -- Load every shape via BOTH mechanisms --------------------------------
    foreach (ref s; g_shapes)
        loadShape(dpy, s);
    // File-level resolution for one static and one animated shape: what size
    // was actually chosen, and how many frames does 'watch' carry?
    logShapeImages("default", theme, size);
    logShapeImages("watch", theme, size);

    Cursor custom = makeBullseye(dpy);

    // The animated cursor: count the frames ourselves, then hand ALL of them
    // to the server in one cursor object — the server runs the animation.
    Cursor animated = 0;
    const(char)* animName = "watch", animPath = "animated";
    XcursorImages* anim = XcursorLibraryLoadImages("watch", theme, size);
    if (anim is null || anim.nimage == 0)
    {
        if (anim !is null)
            XcursorImagesDestroy(anim);
        animName = "progress";
        anim = XcursorLibraryLoadImages("progress", theme, size);
    }
    if (anim !is null && anim.nimage > 0)
    {
        animated = XcursorImagesLoadCursor(dpy, anim);
        emitf("cursor_animated", "name=%s frames=%d delay_ms=%u cursor=0x%lx "
                ~ "animator=server (client sets it once, never ticks)",
            animName, anim.nimage, anim.images[0].delay, animated);
        XcursorImagesDestroy(anim);
    }
    else
        emit("cursor_animated frames=0 (no animated shape in reach; falls back to font XC_watch)");
    if (animated == 0)
    {
        animated = XCreateFontCursor(dpy, XC_watch); // static fallback
        animName = "watch";
        animPath = "font-fallback-static";
    }

    // -- Window ---------------------------------------------------------------
    int width = 480, height = 480;
    Window win = XCreateSimpleWindow(dpy, root, 20, 20, width, height, 1,
        XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F12 cursors");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, ExposureMask | KeyPressMask | StructureNotifyMask
            | PointerMotionMask | EnterWindowMask | LeaveWindowMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=%dx%d zones=3x3", win, width, height);

    GC gc = XDefaultGC(dpy, screen);
    const fd = XConnectionNumber(dpy);
    bool running = true;
    int zone = -1, centerCycle = -1, warpStep = 0;
    int cursorSets = 0;

    // Centre-zone cycle: arrow -> text -> hand -> custom -> animated.
    // The XWarpPointer storm re-enters the centre after each edge zone, so a
    // full sweep exercises all five.
    static immutable int[17] warpZones = [0, 4, 1, 4, 2, 4, 3, 4, 5, 4, 6, 4, 7, 4, 8, 4, 0];

    void setZoneCursor(int z) @nogc nothrow
    {
        Cursor cur;
        const(char)* path, name;
        if (z == 4) // centre: advance the cycle on each entry
        {
            centerCycle = (centerCycle + 1) % 5;
            switch (centerCycle)
            {
            case 0: case 1: case 2:
                name = g_shapes[9 + centerCycle].name;
                path = pick(g_shapes[9 + centerCycle], cur);
                break;
            case 3:
                name = "custom-bullseye";
                path = "custom";
                cur = custom;
                break;
            default:
                name = animName;
                path = animPath;
                cur = animated;
                break;
            }
        }
        else
        {
            name = g_shapes[z].name;
            path = pick(g_shapes[z], cur);
        }
        XDefineCursor(dpy, win, cur);
        XFlush(dpy); // the request must reach the server before we sleep
        ++cursorSets;
        emitf("cursor_set", "zone=%d name=%s path=%s size=%d cursor=0x%lx",
            z, name, path, size, cur);
    }

    while (running)
    {
        while (XPending(dpy) > 0)
        {
            XEvent ev;
            XNextEvent(dpy, &ev);
            switch (ev.type)
            {
            case MotionNotify:
            case EnterNotify:
                const x = ev.type == MotionNotify ? ev.xmotion.x : ev.xcrossing.x;
                const y = ev.type == MotionNotify ? ev.xmotion.y : ev.xcrossing.y;
                int zx = x * 3 / (width > 0 ? width : 1), zy = y * 3 / (height > 0 ? height : 1);
                zx = zx < 0 ? 0 : (zx > 2 ? 2 : zx);
                zy = zy < 0 ? 0 : (zy > 2 ? 2 : zy);
                const z = zy * 3 + zx;
                if (z != zone)
                {
                    zone = z;
                    setZoneCursor(z);
                }
                break;
            case LeaveNotify:
                zone = -1; // re-entering the same zone counts as an entry
                break;
            case Expose:
                if (ev.xexpose.count == 0)
                {
                    foreach (i; 1 .. 3) // the 3x3 grid, server-side lines
                    {
                        XDrawLine(dpy, win, gc, width * i / 3, 0, width * i / 3, height);
                        XDrawLine(dpy, win, gc, 0, height * i / 3, width, height * i / 3);
                    }
                    XFlush(dpy);
                }
                break;
            case ConfigureNotify:
                width = ev.xconfigure.width;
                height = ev.xconfigure.height;
                break;
            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
                {
                    emit("close_requested via=WM_DELETE_WINDOW");
                    running = false;
                }
                break;
            case KeyPress:
                running = false;
                break;
            default:
                break;
            }
        }

        if (autoExit)
        {
            const elapsedMs = nowUs() / 1000;
            // The built-in driver: one warp every 300 ms through all zones,
            // re-entering the centre between edge zones (cycles all 5 centre
            // cursors). The warp generates real MotionNotify events.
            if (warp && warpStep < warpZones.length && elapsedMs > 500 + 300 * warpStep)
            {
                const z = warpZones[warpStep];
                XWarpPointer(dpy, None, win, 0, 0, 0, 0,
                    (z % 3) * width / 3 + width / 6, (z / 3) * height / 3 + height / 6);
                XFlush(dpy);
                ++warpStep;
            }
            if (elapsedMs > durationMs)
            {
                emit("auto_exit");
                break;
            }
        }

        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        poll(&pfd, 1, autoExit ? 50 : -1);
    }

    emitf("summary", "cursor_sets=%d theme=%s default_size=%d",
        cursorSets, theme ? theme : "(null)", size);

    XFreeCursor(dpy, custom);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
