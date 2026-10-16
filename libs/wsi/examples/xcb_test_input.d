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

/// Warp to root coordinates on the first screen (no-WM lanes place the
/// probe window at the origin, so root and window coordinates coincide).
int warpPointerOnScreen(xcb_connection_t* connection, short x, short y)
{
    auto screens = xcb_setup_roots_iterator(xcb_get_setup(connection));
    if (screens.rem == 0)
        return -1;
    return warpPointer(connection, screens.data.root, x, y);
}

/// Relative motion through the XTEST slave pointer: unlike a core
/// WarpPointer, this is real device input, so XInput 2 RawMotion sees it.
int sendRelativeMotion(xcb_connection_t* connection, short dx, short dy)
{
    const error = checkedRequest(connection,
        xcb_test_fake_input_checked(connection, XCB_MOTION_NOTIFY, 1,
            XCB_CURRENT_TIME, XCB_NONE, dx, dy, 0));
    return error != 0 ? error : flushOrError(connection);
}

int sendButton(xcb_connection_t* connection, ubyte button, bool press)
{
    const error = checkedRequest(connection,
        xcb_test_fake_input_checked(connection,
            press ? XCB_BUTTON_PRESS : XCB_BUTTON_RELEASE, button,
            XCB_CURRENT_TIME, XCB_NONE, 0, 0, 0));
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

/**
Another X client owning `CLIPBOARD`, on a connection of its own: it lists
`TARGETS` and `UTF8_STRING`, and answers `UTF8_STRING` with `text`. A test
calls `pump` from its step, since nothing else reads this connection.
*/
struct ForeignClipboardOwner
{
    xcb_connection_t* connection;
    uint window;
    uint clipboard, targets, utf8;
    const(char)[] text;

    /// Connects and takes the selection; `false` when either failed.
    bool open(const(char)[] value)
    {
        int screen;
        connection = xcb_connect(null, &screen);
        if (connection is null || xcb_connection_has_error(connection) != 0)
            return false;
        text = value;
        clipboard = internAtom(connection, "CLIPBOARD");
        targets = internAtom(connection, "TARGETS");
        utf8 = internAtom(connection, "UTF8_STRING");
        auto root = xcb_setup_roots_iterator(xcb_get_setup(connection)).data.root;
        window = xcb_generate_id(connection);
        xcb_create_window(connection, 0, window, root, 0, 0, 1, 1, 0,
            XCB_WINDOW_CLASS_INPUT_ONLY, XCB_COPY_FROM_PARENT, 0, null);
        xcb_set_selection_owner(connection, window, clipboard, XCB_CURRENT_TIME);
        return flushOrError(connection) == 0;
    }

    /// Answers every selection request queued on the connection.
    void pump()
    {
        for (auto event = xcb_poll_for_event(connection); event !is null;
            event = xcb_poll_for_event(connection))
        {
            scope (exit) free(event);
            if ((event.response_type & 0x7F) != XCB_SELECTION_REQUEST)
                continue;
            auto request = cast(xcb_selection_request_event_t*) event;
            xcb_selection_notify_event_t reply;
            memset(&reply, 0, reply.sizeof);
            reply.response_type = XCB_SELECTION_NOTIFY;
            reply.time = request.time;
            reply.requestor = request.requestor;
            reply.selection = request.selection;
            reply.target = request.target;
            if (request.target == targets)
            {
                const uint[2] atoms = [targets, utf8];
                xcb_change_property(connection, XCB_PROP_MODE_REPLACE,
                    request.requestor, request.property, XCB_ATOM_ATOM, 32, 2,
                    atoms.ptr);
                reply.property = request.property;
            }
            else if (request.target == utf8)
            {
                xcb_change_property(connection, XCB_PROP_MODE_REPLACE,
                    request.requestor, request.property, utf8, 8,
                    cast(uint) text.length, text.ptr);
                reply.property = request.property;
            }
            xcb_send_event(connection, 0, request.requestor, 0,
                cast(const(char)*) &reply);
            xcb_flush(connection);
        }
    }

    void close()
    {
        if (connection is null)
            return;
        xcb_disconnect(connection);
        connection = null;
    }
}
