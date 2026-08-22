/**
Minimal XIM server for the X11 text-input lane, over xcb-imdkit's server
API on its own X connection.

Registers as `@im=test` (clients find it through `$XMODIFIERS`), offers the
PreeditNothing/StatusNothing style, and answers forwarded keys with a fixed
policy: pressing the commit key commits the ASCII string `"xim"` — ASCII on
purpose, so the payload is identical bytes in COMPOUND_TEXT and UTF-8 and
the lane never depends on transport-encoding conversion — while every other
key (and every release) bounces straight back to the client, which is the
path ordinary typing takes while an IME is active.

Built and reaped by `scripts/verify-x11-xvfb.sh`; runs until killed.
*/
module xim_test_server;

version (linux):

import core.stdc.stdio : fflush, printf, stdout;
import core.stdc.stdlib : free;

import xcb_native;

/// X keycode of the key whose press commits (evdev KEY_C 46 + 8).
private enum ubyte commitKeycode = 54;

private extern (C) void onProtocol(xcb_im_t* im, xcb_im_client_t*,
    xcb_im_input_context_t* ic, const(xcb_im_packet_header_fr_t)* hdr,
    void*, void* arg, void*) nothrow @nogc
{
    if (hdr is null || ic is null || hdr.major_opcode != XCB_XIM_FORWARD_EVENT)
        return;
    auto event = cast(xcb_key_press_event_t*) arg;
    if (event is null)
        return;
    const pressed = (event.response_type & 0x7F) == XCB_KEY_PRESS;
    if (pressed && event.detail == commitKeycode)
    {
        static immutable char[3] text = "xim";
        xcb_im_commit_string(im, ic, XCB_XIM_LOOKUP_CHARS, text.ptr,
            text.length, 0);
        return;
    }
    xcb_im_forward_event(im, ic, event);
}

int main()
{
    int screenIndex;
    auto connection = xcb_connect(null, &screenIndex);
    if (connection is null || xcb_connection_has_error(connection) != 0)
        return 2;
    scope (exit) xcb_disconnect(connection);

    auto screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
    foreach (_; 0 .. screenIndex)
    {
        if (screens.rem == 0)
            break;
        xcb_screen_next(&screens);
    }
    if (screens.rem == 0)
        return 2;

    // The selection-owner window XIM discovery hangs off; never mapped.
    const window = xcb_generate_id(connection);
    const uint[1] values = [XCB_EVENT_MASK_PROPERTY_CHANGE];
    xcb_create_window(connection, XCB_COPY_FROM_PARENT, window,
        screens.data.root, 0, 0, 1, 1, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screens.data.root_visual, XCB_CW_EVENT_MASK, values.ptr);

    uint[1] styles = [XCB_IM_PreeditNothing | XCB_IM_StatusNothing];
    xcb_im_styles_t inputStyles = {1, styles.ptr};
    char* compoundText = cast(char*) "COMPOUND_TEXT".ptr;
    xcb_im_encodings_t encodings = {1, &compoundText};
    // XCB_IM_ALL_LOCALES is a string macro (invisible to ImportC); the
    // lane runs under the C locale, so a short list is enough.
    auto im = xcb_im_create(connection, screenIndex, window, "test",
        "C,en_US,en", &inputStyles, null, null, &encodings,
        XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE,
        &onProtocol, null);
    if (im is null)
        return 3;
    scope (exit) xcb_im_destroy(im);

    if (!xcb_im_open_im(im))
        return 4;
    scope (exit) xcb_im_close_im(im);
    xcb_flush(connection);

    printf("xim-test-server: ready\n");
    fflush(stdout);

    while (true)
    {
        auto event = xcb_wait_for_event(connection);
        if (event is null)
            return xcb_connection_has_error(connection) != 0 ? 5 : 0;
        xcb_im_filter_event(im, event);
        free(event);
    }
}
