// X11 F06 demo — keyboard & keymap (../../../features/f06-keyboard.md).
// Built on the scaffold (../scaffold/app.d): same ImportC binding style, same
// poll(2)-driven readiness loop, same instrument.d event log.
//
// What it demonstrates (F06 requirements 1, 3, 6):
//
//   * The xkbcommon-x11 path: XGetXCBConnection exposes the Xlib connection's
//     xcb_connection_t, xkb_x11_setup_xkb_extension negotiates XKB >= 1.0,
//     xkb_x11_keymap_new_from_device + xkb_x11_state_new_from_device build the
//     keymap/state for the core keyboard — the app then owns the same
//     scancode -> keysym -> text state machine a Wayland client owns.
//   * Modifier/group state is synced from the server's XkbStateNotify events
//     via xkb_state_update_mask (NOT from xkb_state_update_key — the demo is
//     a pure observer, so the server's state is authoritative and a second
//     client's modifier presses are tracked too; see the findings doc for the
//     drift trade-off).
//   * Live keymap replacement: XkbNewKeyboardNotify / XkbMapNotify (broadcast
//     by the server when e.g. `setxkbmap de` runs) trigger a full
//     keymap+state rebuild, logged as `keymap_event`.
//   * Server-side auto-repeat with the detectable opt-in
//     (XkbSetDetectableAutoRepeat): a repeat arrives as KeyPress-without-
//     KeyRelease, detected via a keycode-is-already-down bitset -> repeat=1.
//   * Dead-key compose via xkb_compose (the de-layout `´` + `e` -> `é`);
//     XIM/X compose-of-the-input-method is F07's territory, not touched here.
//
// Every press/release logs `key code=… sym=… text=… state=down|up repeat=…`.
// Input is injected by the run.sh driver (xdotool + setxkbmap under Xvfb);
// without a driver the demo just times out cleanly (WSI_AUTO_EXIT=1, exit 0).
// Headless-safe: no X server -> prints `SKIP:` and exits 0. Findings:
// ../../f06-keyboard.md.
module app;

import c; // ImportC: Xlib + Xlib-xcb + XKBlib + xkbcommon{,-x11,-compose} + poll
import instrument;

import core.stdc.config : c_long, c_ulong;
import core.stdc.locale : LC_ALL, setlocale;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi, getenv;
import core.stdc.string : strcmp;

// ---------------------------------------------------------------------------
// Constants Xlib/XKB.h expose as macros that ImportC cannot import;
// re-declared per the scaffold gotcha.

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
    MappingNotify = 34,
}

enum False = 0;
enum True = 1;
enum POLLIN = 0x001;
enum RevertToParent = 2;
enum CurrentTime = 0;

enum XkbUseCoreKbd = 0x0100; // XKB.h device spec
enum // XkbEvent.any.xkb_type discriminators (XKB.h)
{
    XkbNewKeyboardNotify = 0,
    XkbMapNotify = 1,
    XkbStateNotify = 2,
}

enum : c_ulong // XkbSelectEvents masks (XKB.h)
{
    XkbNewKeyboardNotifyMask = 1L << 0,
    XkbMapNotifyMask = 1L << 1,
    XkbStateNotifyMask = 1L << 2,
}

// ---------------------------------------------------------------------------
// The xkbcommon trio (context/keymap/state) + compose, rebuilt on demand.

struct Kbd
{
    xkb_context* ctx;
    xkb_keymap* keymap;
    xkb_state* state;
    xcb_connection_t* xcb;
    int deviceId;
}

/// (Re)build keymap + state from the server's current map for the core
/// keyboard — called at startup and again on every XkbNewKeyboardNotify /
/// XkbMapNotify (e.g. after `setxkbmap de`). F06 requirement 3 + 6.
bool rebuildKeymap(ref Kbd k, const(char)* reason)
{
    if (k.state !is null)
        xkb_state_unref(k.state);
    if (k.keymap !is null)
        xkb_keymap_unref(k.keymap);
    k.keymap = xkb_x11_keymap_new_from_device(k.ctx, k.xcb, k.deviceId,
        XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (k.keymap is null)
        return false;
    k.state = xkb_x11_state_new_from_device(k.keymap, k.xcb, k.deviceId);
    if (k.state is null)
        return false;
    emitf("keymap_event", "reason=%s layouts=%u layout0=%s", reason,
        xkb_keymap_num_layouts(k.keymap), xkb_keymap_layout_get_name(k.keymap, 0));
    return true;
}

int main()
{
    initInstrument("f06_x11");
    const envAuto = getenv("WSI_AUTO_EXIT");
    const autoExit = envAuto !is null && envAuto[0] == '1';
    const envDur = getenv("WSI_DURATION_MS");
    const durationMs = envDur !is null ? atoi(envDur) : 10_000;

    // -- Connect; expose the xcb side of the same socket ----------------------
    Display* dpy = XOpenDisplay(null);
    if (dpy is null)
    {
        printf("SKIP: no X11 display (XOpenDisplay returned null)\n");
        return 0;
    }
    emitf("step", "name=XOpenDisplay fd=%d", XConnectionNumber(dpy));
    xcb_connection_t* xcb = XGetXCBConnection(dpy);
    emitf("step", "name=XGetXCBConnection ok=%d", cast(int)(xcb !is null));

    // -- XKB extension, both faces of it --------------------------------------
    // xcb side (for xkbcommon-x11's GetMap/GetState requests):
    ushort xkbMajor, xkbMinor;
    ubyte xkbBaseEvent, xkbBaseError;
    if (!xkb_x11_setup_xkb_extension(xcb, 1, 0,
            XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            &xkbMajor, &xkbMinor, &xkbBaseEvent, &xkbBaseError))
    {
        printf("SKIP: server lacks the XKB extension\n");
        XCloseDisplay(dpy);
        return 0;
    }
    emitf("step", "name=xkb_x11_setup_xkb_extension version=%u.%u base_event=%u",
        xkbMajor, xkbMinor, xkbBaseEvent);
    // Xlib side (so XKBlib cooks wire events into XkbEvent and XkbSelectEvents
    // & XkbSetDetectableAutoRepeat work). Same extension on the same socket —
    // the event base it reports matches the xcb one.
    int xkbOpcode, xkbEventBase, xkbErrorBase, libMajor = 1, libMinor = 0;
    XkbQueryExtension(dpy, &xkbOpcode, &xkbEventBase, &xkbErrorBase, &libMajor, &libMinor);
    emitf("step", "name=XkbQueryExtension event_base=%d", xkbEventBase);

    // Detectable auto-repeat opt-in: repeats become KeyPress-only (F06 req 3).
    int darSupported = 0;
    XkbSetDetectableAutoRepeat(dpy, True, &darSupported);
    emitf("step", "name=XkbSetDetectableAutoRepeat supported=%d", darSupported);

    // Subscribe to the keymap/state broadcasts.
    enum c_ulong xkbMask = XkbNewKeyboardNotifyMask | XkbMapNotifyMask | XkbStateNotifyMask;
    XkbSelectEvents(dpy, XkbUseCoreKbd, xkbMask, xkbMask);
    emit("step name=XkbSelectEvents masks=new_keyboard|map|state");

    // -- xkbcommon: keymap + state for the core keyboard ----------------------
    Kbd kbd;
    kbd.xcb = xcb;
    kbd.ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    kbd.deviceId = xkb_x11_get_core_keyboard_device_id(xcb);
    emitf("step", "name=xkb_x11_get_core_keyboard_device_id id=%d", kbd.deviceId);
    if (kbd.deviceId < 0 || !rebuildKeymap(kbd, "startup"))
    {
        printf("SKIP: could not build an xkb keymap from the device\n");
        XCloseDisplay(dpy);
        return 0;
    }

    // -- Compose (dead keys): xkbcommon's compose table, locale-driven --------
    // XIM-style input-method compose is F07's territory; this is the pure
    // client-side xkb_compose state machine. Under a bare CI env the locale is
    // "C", whose compose table is empty — fall back to en_US.UTF-8 (the
    // canonical X11 Compose set, which carries <dead_acute><e> -> é).
    setlocale(LC_ALL, "");
    const(char)* locale = getenv("LC_ALL");
    if (locale is null || locale[0] == '\0')
        locale = getenv("LC_CTYPE");
    if (locale is null || locale[0] == '\0')
        locale = getenv("LANG");
    if (locale is null || locale[0] == '\0'
        || strcmp(locale, "C") == 0 || strcmp(locale, "POSIX") == 0)
        locale = "en_US.UTF-8";
    xkb_compose_table* composeTable = xkb_compose_table_new_from_locale(
        kbd.ctx, locale, XKB_COMPOSE_COMPILE_NO_FLAGS);
    xkb_compose_state* compose = composeTable !is null
        ? xkb_compose_state_new(composeTable, XKB_COMPOSE_STATE_NO_FLAGS) : null;
    emitf("step", "name=xkb_compose_table_new_from_locale locale=%s ok=%d",
        locale, cast(int)(compose !is null));

    // -- Window; self-focus so xdotool/XTEST input lands here under bare Xvfb -
    const screen = XDefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, XRootWindow(dpy, screen), 0, 0,
        480, 320, 1, XBlackPixel(dpy, screen), XWhitePixel(dpy, screen));
    XStoreName(dpy, win, "Sparkles · X11 F06 keyboard");
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XSelectInput(dpy, win, KeyPressMask | KeyReleaseMask | ExposureMask
            | StructureNotifyMask | FocusChangeMask);
    XMapWindow(dpy, win);
    emitf("window_created", "xid=0x%lx size=480x320", win);

    // -- State for the loop ----------------------------------------------------
    ubyte[32] downBits; // keycode bitset: a KeyPress for an already-down key is a repeat
    bool running = true, focused = false;
    int presses = 0, releases = 0, repeats = 0, composed = 0, rebuilds = 0;
    char[64] symName, keyText, composeText;

    const fd = XConnectionNumber(dpy);
    while (running)
    {
        while (XPending(dpy) > 0) // also flushes the output buffer
        {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if (ev.type == xkbEventBase) // all XKB events share one type code
            {
                auto xkbEv = cast(XkbEvent*)&ev;
                switch (xkbEv.any.xkb_type)
                {
                case XkbStateNotify:
                    // Server-authoritative modifier/group sync (F06 req 3).
                    xkb_state_update_mask(kbd.state,
                        xkbEv.state.base_mods, xkbEv.state.latched_mods,
                        xkbEv.state.locked_mods, xkbEv.state.base_group,
                        xkbEv.state.latched_group, xkbEv.state.locked_group);
                    emitf("xkb_state", "base_mods=0x%x locked_mods=0x%x group=%d",
                        xkbEv.state.base_mods, xkbEv.state.locked_mods,
                        xkbEv.state.group);
                    break;
                case XkbNewKeyboardNotify: // e.g. setxkbmap replaced the keymap
                    emitf("xkb_new_keyboard", "device=%d old_device=%d changed=0x%x",
                        xkbEv.new_kbd.device, xkbEv.new_kbd.old_device,
                        xkbEv.new_kbd.changed);
                    if (rebuildKeymap(kbd, "XkbNewKeyboardNotify"))
                        ++rebuilds;
                    break;
                case XkbMapNotify:
                    if (rebuildKeymap(kbd, "XkbMapNotify"))
                        ++rebuilds;
                    break;
                default:
                    break;
                }
                continue;
            }

            switch (ev.type)
            {
            case KeyPress, KeyRelease:
                const keycode = ev.xkey.keycode; // X keycode == xkb keycode
                const down = ev.type == KeyPress;
                const idx = keycode >> 3, bit = cast(ubyte)(1 << (keycode & 7));
                // With detectable auto-repeat a repeat is a KeyPress while
                // the key is still down (no interleaved KeyRelease).
                const repeat = down && (downBits[idx] & bit) != 0;
                if (down)
                    downBits[idx] |= bit;
                else
                    downBits[idx] &= cast(ubyte) ~cast(int) bit;

                const sym = xkb_state_key_get_one_sym(kbd.state, keycode);
                if (xkb_keysym_get_name(sym, symName.ptr, symName.length) < 0)
                    symName[0] = '\0';
                keyText[0] = '\0';
                xkb_state_key_get_utf8(kbd.state, keycode, keyText.ptr, keyText.length);
                const(char)* text = keyText.ptr;

                if (down && compose !is null && sym != 0)
                {
                    // Dead-key state machine (F06 req 6): feed every pressed
                    // keysym; while composing, suppress the raw text.
                    if (xkb_compose_state_feed(compose, sym) == XKB_COMPOSE_FEED_ACCEPTED)
                    {
                        final switch (xkb_compose_state_get_status(compose))
                        {
                        case XKB_COMPOSE_COMPOSING:
                            emit("compose state=composing");
                            text = "";
                            break;
                        case XKB_COMPOSE_COMPOSED:
                            composeText[0] = '\0';
                            xkb_compose_state_get_utf8(compose,
                                composeText.ptr, composeText.length);
                            emitf("compose", "state=composed text=%s", composeText.ptr);
                            text = composeText.ptr;
                            ++composed;
                            xkb_compose_state_reset(compose);
                            break;
                        case XKB_COMPOSE_CANCELLED:
                            emit("compose state=cancelled");
                            text = "";
                            xkb_compose_state_reset(compose);
                            break;
                        case XKB_COMPOSE_NOTHING:
                            break;
                        }
                    }
                }

                emitf("key", "code=%u sym=%s text=%s state=%s repeat=%d",
                    keycode, symName.ptr, text, down ? "down".ptr : "up".ptr,
                    cast(int) repeat);
                if (down)
                {
                    ++presses;
                    repeats += repeat;
                }
                else
                    ++releases;
                break;

            case MapNotify:
                // Bare Xvfb has no WM: focus stays PointerRoot unless someone
                // sets it. Self-focus so injected XTEST events land here.
                XSetInputFocus(dpy, win, RevertToParent, CurrentTime);
                XFlush(dpy);
                emit("step name=XSetInputFocus revert_to=parent");
                break;

            case FocusIn:
                focused = true;
                emit("focus state=in");
                break;

            case FocusOut:
                focused = false;
                emit("focus state=out");
                break;

            case MappingNotify:
                // Legacy core-protocol keymap change; the XKB events above
                // supersede it for XKB-aware clients. Logged if it appears.
                emit("legacy_mapping_notify");
                break;

            case ClientMessage:
                if (cast(Atom) ev.xclient.data.l[0] == wmDelete)
                {
                    emit("close_requested via=WM_DELETE_WINDOW");
                    running = false;
                }
                break;

            default:
                break;
            }
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

    emitf("summary", "presses=%d releases=%d repeats=%d composed=%d "
            ~ "keymap_rebuilds=%d focused=%d", presses, releases, repeats,
        composed, rebuilds, cast(int) focused);

    if (compose !is null)
        xkb_compose_state_unref(compose);
    if (composeTable !is null)
        xkb_compose_table_unref(composeTable);
    xkb_state_unref(kbd.state);
    xkb_keymap_unref(kbd.keymap);
    xkb_context_unref(kbd.ctx);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    emit("teardown");
    return 0;
}
