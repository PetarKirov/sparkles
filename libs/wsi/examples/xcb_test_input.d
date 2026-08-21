/**
XCB test triggers shared by the X11 conformance driver and the standalone
key injector: out-of-band resize/close requests, input focus, XTEST key and
pointer injection. Test tooling only — the WSI backend itself never sends
input or focus requests.
*/
module xcb_test_input;

version (linux):

import core.stdc.stdlib : free;
import core.stdc.string : memset, strlen;

import xcb_native;

/// xcb_request_check + free: 0 on success, else the protocol error code.
private int checkedRequest(xcb_connection_t* connection,
    xcb_void_cookie_t cookie)
{
    auto error = xcb_request_check(connection, cookie);
    if (error is null)
        return 0;
    const code = error.error_code;
    free(error);
    return code;
}

private int flushOrError(xcb_connection_t* connection)
    => xcb_flush(connection) > 0 ? 0 : xcb_connection_has_error(connection);

private uint internAtom(xcb_connection_t* connection, const(char)* name)
{
    auto reply = xcb_intern_atom_reply(connection,
        xcb_intern_atom(connection, 0, cast(ushort) strlen(name), name),
        null);
    if (reply is null)
        return 0;
    const atom = reply.atom;
    free(reply);
    return atom;
}

int resizeWindow(xcb_connection_t* connection, uint window, uint width,
    uint height)
{
    const uint[2] values = [width, height];
    const error = checkedRequest(connection,
        xcb_configure_window_checked(connection, window,
            XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values.ptr));
    return error != 0 ? error : flushOrError(connection);
}

int sendClose(xcb_connection_t* connection, uint window)
{
    const protocols = internAtom(connection, "WM_PROTOCOLS");
    const deleteWindow = internAtom(connection, "WM_DELETE_WINDOW");
    if (protocols == 0 || deleteWindow == 0)
        return -3;
    xcb_client_message_event_t event;
    memset(&event, 0, event.sizeof);
    event.response_type = XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = window;
    event.type = protocols;
    event.data.data32[0] = deleteWindow;
    event.data.data32[1] = XCB_CURRENT_TIME;
    const error = checkedRequest(connection,
        xcb_send_event_checked(connection, 0, window,
            XCB_EVENT_MASK_NO_EVENT, cast(const(char)*) &event));
    return error != 0 ? error : flushOrError(connection);
}

int focusWindow(xcb_connection_t* connection, uint window)
{
    const error = checkedRequest(connection,
        xcb_set_input_focus_checked(connection,
            XCB_INPUT_FOCUS_POINTER_ROOT, window, XCB_CURRENT_TIME));
    return error != 0 ? error : flushOrError(connection);
}

int warpPointer(xcb_connection_t* connection, uint root, short x, short y)
{
    const error = checkedRequest(connection,
        xcb_warp_pointer_checked(connection, XCB_NONE, root, 0, 0, 0, 0,
            x, y));
    return error != 0 ? error : flushOrError(connection);
}

int sendKey(xcb_connection_t* connection, ubyte keycode, bool press)
{
    auto queried = xcb_test_get_version_reply(connection,
        xcb_test_get_version(connection, XCB_TEST_MAJOR_VERSION,
            XCB_TEST_MINOR_VERSION), null);
    if (queried is null)
        return -1;
    free(queried);
    const error = checkedRequest(connection,
        xcb_test_fake_input_checked(connection,
            press ? XCB_KEY_PRESS : XCB_KEY_RELEASE, keycode,
            XCB_CURRENT_TIME, XCB_NONE, 0, 0, 0));
    return error != 0 ? error : flushOrError(connection);
}
