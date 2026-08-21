/*
 * Narrow ImportC/XCB bridge for sparkles:wsi.
 *
 * XCB is the native X11 client API. This file keeps its generated header
 * structs out of the public D module and exports only fixed-layout bootstrap
 * and event values plus batched lifecycle requests.
 */
#undef _FORTIFY_SOURCE

#pragma attribute(push, nogc, nothrow)
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>
#include <xcb/xkb.h>
#include <xcb/xtest.h>

struct wsi_xcb_bootstrap
{
    int screen_index;
    int fd;
    uint32_t root;
    uint32_t root_visual;
    uint32_t black_pixel;
    uint32_t wm_protocols;
    uint32_t wm_delete_window;
};

enum wsi_xcb_event_kind
{
    WSI_XCB_EVENT_NONE,
    WSI_XCB_EVENT_EXPOSE,
    WSI_XCB_EVENT_CONFIGURE,
    WSI_XCB_EVENT_CLOSE,
    WSI_XCB_EVENT_FOCUS_IN,
    WSI_XCB_EVENT_FOCUS_OUT,
    WSI_XCB_EVENT_DESTROYED,
    WSI_XCB_EVENT_KEY_PRESS,
    WSI_XCB_EVENT_KEY_RELEASE,
    WSI_XCB_EVENT_ERROR
};

struct wsi_xcb_event
{
    uint8_t kind;
    uint32_t window;
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
    int32_t native_code;
    uint32_t state;
};

static xcb_atom_t wsi_xcb_atom(xcb_connection_t *connection,
    const char *name)
{
    xcb_generic_error_t *error = NULL;
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom(connection, 0,
        (uint16_t) strlen(name), name);
    xcb_intern_atom_reply_t *reply =
        xcb_intern_atom_reply(connection, cookie, &error);
    xcb_atom_t atom = reply ? reply->atom : XCB_ATOM_NONE;
    free(error);
    free(reply);
    return atom;
}

void *wsi_xcb_connect(struct wsi_xcb_bootstrap *out, int *error_code)
{
    int screen_index = 0;
    xcb_connection_t *connection = xcb_connect(NULL, &screen_index);
    int error = connection ? xcb_connection_has_error(connection) : -1;
    if (error != 0)
    {
        if (connection)
            xcb_disconnect(connection);
        if (error_code)
            *error_code = error;
        return NULL;
    }

    const xcb_setup_t *setup = xcb_get_setup(connection);
    xcb_screen_iterator_t screens = xcb_setup_roots_iterator(setup);
    for (int i = 0; i < screen_index && screens.rem; ++i)
        xcb_screen_next(&screens);
    if (!screens.rem)
    {
        xcb_disconnect(connection);
        if (error_code)
            *error_code = -2;
        return NULL;
    }

    xcb_screen_t *screen = screens.data;
    out->screen_index = screen_index;
    out->fd = xcb_get_file_descriptor(connection);
    out->root = screen->root;
    out->root_visual = screen->root_visual;
    out->black_pixel = screen->black_pixel;
    out->wm_protocols = wsi_xcb_atom(connection, "WM_PROTOCOLS");
    out->wm_delete_window = wsi_xcb_atom(connection, "WM_DELETE_WINDOW");
    if (out->wm_protocols == XCB_ATOM_NONE
        || out->wm_delete_window == XCB_ATOM_NONE)
    {
        xcb_disconnect(connection);
        if (error_code)
            *error_code = -3;
        return NULL;
    }
    if (error_code)
        *error_code = 0;
    return connection;
}

void wsi_xcb_disconnect(void *opaque)
{
    xcb_disconnect((xcb_connection_t *) opaque);
}

uint32_t wsi_xcb_generate_id(void *opaque)
{
    return xcb_generate_id((xcb_connection_t *) opaque);
}

static int wsi_xcb_check(xcb_connection_t *connection,
    xcb_void_cookie_t cookie)
{
    xcb_generic_error_t *error = xcb_request_check(connection, cookie);
    if (!error)
        return 0;
    int code = error->error_code;
    free(error);
    return code;
}

int wsi_xcb_create_window(void *opaque,
    const struct wsi_xcb_bootstrap *bootstrap, uint32_t window,
    uint16_t width, uint16_t height, const char *title, uint16_t title_length,
    int visible)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    uint32_t values[2] = {
        bootstrap->black_pixel,
        XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY
            | XCB_EVENT_MASK_FOCUS_CHANGE
            | XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE
    };
    xcb_create_window(connection,
        XCB_COPY_FROM_PARENT, window, bootstrap->root, 0, 0, width, height, 0,
        XCB_WINDOW_CLASS_INPUT_OUTPUT, bootstrap->root_visual,
        XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values);

    xcb_change_property(connection,
        XCB_PROP_MODE_REPLACE, window, bootstrap->wm_protocols,
        XCB_ATOM_ATOM, 32, 1, &bootstrap->wm_delete_window);
    xcb_change_property(connection,
        XCB_PROP_MODE_REPLACE, window, XCB_ATOM_WM_NAME, XCB_ATOM_STRING,
        8, title_length, title);
    if (visible)
        xcb_map_window(connection, window);
    return xcb_flush(connection) > 0 ? 0 : xcb_connection_has_error(connection);
}

int wsi_xcb_destroy_window(void *opaque, uint32_t window)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    xcb_destroy_window(connection, window);
    return xcb_flush(connection) > 0 ? 0 : xcb_connection_has_error(connection);
}

int wsi_xcb_resize_window(void *opaque, uint32_t window,
    uint32_t width, uint32_t height)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    uint32_t values[2] = {width, height};
    int error = wsi_xcb_check(connection,
        xcb_configure_window_checked(connection, window,
            XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values));
    if (error)
        return error;
    return xcb_flush(connection) > 0 ? 0 : xcb_connection_has_error(connection);
}

int wsi_xcb_send_close(void *opaque, uint32_t window)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    xcb_atom_t protocols = wsi_xcb_atom(connection, "WM_PROTOCOLS");
    xcb_atom_t delete_window = wsi_xcb_atom(connection, "WM_DELETE_WINDOW");
    if (protocols == XCB_ATOM_NONE || delete_window == XCB_ATOM_NONE)
        return -3;
    xcb_client_message_event_t event;
    memset(&event, 0, sizeof(event));
    event.response_type = XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = window;
    event.type = protocols;
    event.data.data32[0] = delete_window;
    event.data.data32[1] = XCB_CURRENT_TIME;
    int error = wsi_xcb_check(connection,
        xcb_send_event_checked(connection, 0, window,
            XCB_EVENT_MASK_NO_EVENT, (const char *) &event));
    if (error)
        return error;
    return xcb_flush(connection) > 0 ? 0 : xcb_connection_has_error(connection);
}

int wsi_xcb_poll_event(void *opaque,
    const struct wsi_xcb_bootstrap *bootstrap, struct wsi_xcb_event *out)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    xcb_generic_event_t *generic = xcb_poll_for_event(connection);
    if (!generic)
        return 0;

    memset(out, 0, sizeof(*out));
    if ((generic->response_type & 0x7f) == 0)
    {
        xcb_generic_error_t *error = (xcb_generic_error_t *) generic;
        out->kind = WSI_XCB_EVENT_ERROR;
        out->window = error->resource_id;
        out->native_code = error->error_code;
        free(generic);
        return 1;
    }
    switch (generic->response_type & 0x7f)
    {
    case XCB_EXPOSE:
    {
        xcb_expose_event_t *event = (xcb_expose_event_t *) generic;
        out->kind = WSI_XCB_EVENT_EXPOSE;
        out->window = event->window;
        break;
    }
    case XCB_CONFIGURE_NOTIFY:
    {
        xcb_configure_notify_event_t *event =
            (xcb_configure_notify_event_t *) generic;
        out->kind = WSI_XCB_EVENT_CONFIGURE;
        out->window = event->window;
        out->x = event->x;
        out->y = event->y;
        out->width = event->width;
        out->height = event->height;
        break;
    }
    case XCB_CLIENT_MESSAGE:
    {
        xcb_client_message_event_t *event =
            (xcb_client_message_event_t *) generic;
        if (event->type == bootstrap->wm_protocols
            && event->data.data32[0] == bootstrap->wm_delete_window)
        {
            out->kind = WSI_XCB_EVENT_CLOSE;
            out->window = event->window;
        }
        break;
    }
    case XCB_KEY_PRESS:
    {
        xcb_key_press_event_t *event = (xcb_key_press_event_t *) generic;
        out->kind = WSI_XCB_EVENT_KEY_PRESS;
        out->window = event->event;
        out->native_code = event->detail;
        out->state = event->state;
        break;
    }
    case XCB_KEY_RELEASE:
    {
        xcb_key_release_event_t *event = (xcb_key_release_event_t *) generic;
        out->kind = WSI_XCB_EVENT_KEY_RELEASE;
        out->window = event->event;
        out->native_code = event->detail;
        out->state = event->state;
        break;
    }
    case XCB_FOCUS_IN:
        out->kind = WSI_XCB_EVENT_FOCUS_IN;
        out->window = ((xcb_focus_in_event_t *) generic)->event;
        break;
    case XCB_FOCUS_OUT:
        out->kind = WSI_XCB_EVENT_FOCUS_OUT;
        out->window = ((xcb_focus_out_event_t *) generic)->event;
        break;
    case XCB_DESTROY_NOTIFY:
        out->kind = WSI_XCB_EVENT_DESTROYED;
        out->window = ((xcb_destroy_notify_event_t *) generic)->window;
        break;
    default:
        break;
    }
    free(generic);
    return 1;
}

int wsi_xcb_connection_error(void *opaque)
{
    return xcb_connection_has_error((xcb_connection_t *) opaque);
}

/*
 * Without detectable auto-repeat the server synthesizes a release before
 * every repeated press, so a held key is indistinguishable from typing.
 * With the per-client flag a repeat is a second press with no release in
 * between, which the D side turns into KeyAction.repeat. Best-effort: a
 * server without XKB simply keeps the synthesized releases.
 */
int wsi_xcb_enable_detectable_autorepeat(void *opaque)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    xcb_xkb_use_extension_reply_t *use = xcb_xkb_use_extension_reply(
        connection,
        xcb_xkb_use_extension(connection, XCB_XKB_MAJOR_VERSION,
            XCB_XKB_MINOR_VERSION),
        NULL);
    if (!use)
        return -1;
    int supported = use->supported;
    free(use);
    if (!supported)
        return -1;
    xcb_xkb_per_client_flags_reply_t *flags =
        xcb_xkb_per_client_flags_reply(connection,
            xcb_xkb_per_client_flags(connection, XCB_XKB_ID_USE_CORE_KBD,
                XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT,
                XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT, 0, 0, 0),
            NULL);
    if (!flags)
        return -1;
    int enabled =
        (flags->value & XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT) != 0;
    free(flags);
    return enabled ? 0 : -1;
}

/* Test helpers: give a window input focus, then inject XTEST key events. */
int wsi_xcb_focus_window(void *opaque, uint32_t window)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    int error = wsi_xcb_check(connection,
        xcb_set_input_focus_checked(connection,
            XCB_INPUT_FOCUS_POINTER_ROOT, window, XCB_CURRENT_TIME));
    if (error)
        return error;
    return xcb_flush(connection) > 0
        ? 0 : xcb_connection_has_error(connection);
}

int wsi_xcb_send_key(void *opaque, uint8_t keycode, int press)
{
    xcb_connection_t *connection = (xcb_connection_t *) opaque;
    xcb_test_get_version_reply_t *version = xcb_test_get_version_reply(
        connection,
        xcb_test_get_version(connection, XCB_TEST_MAJOR_VERSION,
            XCB_TEST_MINOR_VERSION),
        NULL);
    if (!version)
        return -1;
    free(version);
    int error = wsi_xcb_check(connection,
        xcb_test_fake_input_checked(connection,
            press ? XCB_KEY_PRESS : XCB_KEY_RELEASE, keycode,
            XCB_CURRENT_TIME, XCB_NONE, 0, 0, 0));
    if (error)
        return error;
    return xcb_flush(connection) > 0
        ? 0 : xcb_connection_has_error(connection);
}

#pragma attribute(pop)
