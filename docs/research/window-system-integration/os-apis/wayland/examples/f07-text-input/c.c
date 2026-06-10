// ImportC shim for the F07 text-input demo (see ./app.d and ../../scaffold.md).
// Same three jobs as the scaffold's shim — one translation unit for the
// libwayland ABI + the scanner-generated glue (xdg-shell AND
// text-input-unstable-v3, see ./generate.sh), POSIX shm pieces, and `wsi_*`
// re-exports of every `static inline` request helper ImportC cannot call.
// Additionally pulls in libxkbcommon (real functions, no wrappers needed) so
// the demo can translate wl_keyboard keycodes for the interleaving log.
// Nix's cc wrapper injects -D_FORTIFY_SOURCE, and glibc's fortify wrappers
// (bits/unistd.h) use __builtin_dynamic_object_size, which ImportC does not
// implement — undefine it before the first glibc include.
#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1 /* memfd_create(2) in <sys/mman.h> */

#pragma attribute(push, nogc, nothrow)
#include <unistd.h>
#include <poll.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell-client-protocol.h"
#include "text-input-unstable-v3-client-protocol.h"

/* ---- bootstrap (core protocol) ------------------------------------- */

struct wl_registry *wsi_display_get_registry(struct wl_display *d)
{
    return wl_display_get_registry(d);
}

int wsi_registry_add_listener(struct wl_registry *r,
    const struct wl_registry_listener *l, void *data)
{
    return wl_registry_add_listener(r, l, data);
}

void *wsi_registry_bind(struct wl_registry *r, uint32_t name,
    const struct wl_interface *iface, uint32_t version)
{
    return wl_registry_bind(r, name, iface, version);
}

/* ---- wl_compositor / wl_surface ------------------------------------ */

struct wl_surface *wsi_compositor_create_surface(struct wl_compositor *c)
{
    return wl_compositor_create_surface(c);
}

void wsi_surface_attach(struct wl_surface *s, struct wl_buffer *b, int32_t x, int32_t y)
{
    wl_surface_attach(s, b, x, y);
}

void wsi_surface_damage_buffer(struct wl_surface *s, int32_t x, int32_t y,
    int32_t w, int32_t h)
{
    wl_surface_damage_buffer(s, x, y, w, h);
}

void wsi_surface_commit(struct wl_surface *s)
{
    wl_surface_commit(s);
}

struct wl_callback *wsi_surface_frame(struct wl_surface *s)
{
    return wl_surface_frame(s);
}

void wsi_surface_destroy(struct wl_surface *s)
{
    wl_surface_destroy(s);
}

int wsi_callback_add_listener(struct wl_callback *cb,
    const struct wl_callback_listener *l, void *data)
{
    return wl_callback_add_listener(cb, l, data);
}

void wsi_callback_destroy(struct wl_callback *cb)
{
    wl_callback_destroy(cb);
}

/* ---- wl_shm (software buffers) ------------------------------------- */

struct wl_shm_pool *wsi_shm_create_pool(struct wl_shm *shm, int32_t fd, int32_t size)
{
    return wl_shm_create_pool(shm, fd, size);
}

struct wl_buffer *wsi_shm_pool_create_buffer(struct wl_shm_pool *p, int32_t offset,
    int32_t w, int32_t h, int32_t stride, uint32_t format)
{
    return wl_shm_pool_create_buffer(p, offset, w, h, stride, format);
}

void wsi_shm_pool_destroy(struct wl_shm_pool *p)
{
    wl_shm_pool_destroy(p);
}

int wsi_buffer_add_listener(struct wl_buffer *b,
    const struct wl_buffer_listener *l, void *data)
{
    return wl_buffer_add_listener(b, l, data);
}

void wsi_buffer_destroy(struct wl_buffer *b)
{
    wl_buffer_destroy(b);
}

/* ---- wl_seat / wl_keyboard ------------------------------------------ */

int wsi_seat_add_listener(struct wl_seat *s, const struct wl_seat_listener *l, void *data)
{
    return wl_seat_add_listener(s, l, data);
}

struct wl_keyboard *wsi_seat_get_keyboard(struct wl_seat *s)
{
    return wl_seat_get_keyboard(s);
}

int wsi_keyboard_add_listener(struct wl_keyboard *k,
    const struct wl_keyboard_listener *l, void *data)
{
    return wl_keyboard_add_listener(k, l, data);
}

void wsi_keyboard_destroy(struct wl_keyboard *k)
{
    wl_keyboard_destroy(k);
}

/* ---- xdg-shell (generated glue) ------------------------------------- */

int wsi_wm_base_add_listener(struct xdg_wm_base *b,
    const struct xdg_wm_base_listener *l, void *data)
{
    return xdg_wm_base_add_listener(b, l, data);
}

void wsi_wm_base_pong(struct xdg_wm_base *b, uint32_t serial)
{
    xdg_wm_base_pong(b, serial);
}

struct xdg_surface *wsi_wm_base_get_xdg_surface(struct xdg_wm_base *b,
    struct wl_surface *s)
{
    return xdg_wm_base_get_xdg_surface(b, s);
}

void wsi_wm_base_destroy(struct xdg_wm_base *b)
{
    xdg_wm_base_destroy(b);
}

int wsi_xdg_surface_add_listener(struct xdg_surface *s,
    const struct xdg_surface_listener *l, void *data)
{
    return xdg_surface_add_listener(s, l, data);
}

struct xdg_toplevel *wsi_xdg_surface_get_toplevel(struct xdg_surface *s)
{
    return xdg_surface_get_toplevel(s);
}

void wsi_xdg_surface_ack_configure(struct xdg_surface *s, uint32_t serial)
{
    xdg_surface_ack_configure(s, serial);
}

void wsi_xdg_surface_destroy(struct xdg_surface *s)
{
    xdg_surface_destroy(s);
}

int wsi_toplevel_add_listener(struct xdg_toplevel *t,
    const struct xdg_toplevel_listener *l, void *data)
{
    return xdg_toplevel_add_listener(t, l, data);
}

void wsi_toplevel_set_title(struct xdg_toplevel *t, const char *title)
{
    xdg_toplevel_set_title(t, title);
}

void wsi_toplevel_set_app_id(struct xdg_toplevel *t, const char *app_id)
{
    xdg_toplevel_set_app_id(t, app_id);
}

void wsi_toplevel_destroy(struct xdg_toplevel *t)
{
    xdg_toplevel_destroy(t);
}

/* ---- zwp_text_input_v3 (generated glue) ------------------------------ */

struct zwp_text_input_v3 *wsi_text_input_manager_get_text_input(
    struct zwp_text_input_manager_v3 *m, struct wl_seat *seat)
{
    return zwp_text_input_manager_v3_get_text_input(m, seat);
}

void wsi_text_input_manager_destroy(struct zwp_text_input_manager_v3 *m)
{
    zwp_text_input_manager_v3_destroy(m);
}

int wsi_text_input_add_listener(struct zwp_text_input_v3 *ti,
    const struct zwp_text_input_v3_listener *l, void *data)
{
    return zwp_text_input_v3_add_listener(ti, l, data);
}

void wsi_text_input_enable(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_enable(ti);
}

void wsi_text_input_disable(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_disable(ti);
}

void wsi_text_input_set_surrounding_text(struct zwp_text_input_v3 *ti,
    const char *text, int32_t cursor, int32_t anchor)
{
    zwp_text_input_v3_set_surrounding_text(ti, text, cursor, anchor);
}

void wsi_text_input_set_text_change_cause(struct zwp_text_input_v3 *ti, uint32_t cause)
{
    zwp_text_input_v3_set_text_change_cause(ti, cause);
}

void wsi_text_input_set_content_type(struct zwp_text_input_v3 *ti,
    uint32_t hint, uint32_t purpose)
{
    zwp_text_input_v3_set_content_type(ti, hint, purpose);
}

void wsi_text_input_set_cursor_rectangle(struct zwp_text_input_v3 *ti,
    int32_t x, int32_t y, int32_t w, int32_t h)
{
    zwp_text_input_v3_set_cursor_rectangle(ti, x, y, w, h);
}

void wsi_text_input_commit(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_commit(ti);
}

void wsi_text_input_destroy(struct zwp_text_input_v3 *ti)
{
    zwp_text_input_v3_destroy(ti);
}

#pragma attribute(pop)

// The generated request-marshalling tables, textually included so the package
// stays a single C translation unit (hyphenated filenames are not valid D
// module names; see `excludedSourceFiles` in ./dub.sdl).
#include "xdg-shell-protocol.c"
#include "text-input-unstable-v3-protocol.c"
