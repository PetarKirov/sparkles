// ImportC shim for the F15 popup demo (see ./app.d and ../../f15-popup.md).
// The scaffold shim (../scaffold/c.c) plus:
//
//   - xdg_positioner / xdg_popup request helpers (generated xdg-shell glue;
//     xdg_wm_base is bound up to v5 so xdg_popup.reposition / repositioned
//     and xdg_positioner.set_reactive are reachable),
//   - wl_seat / wl_pointer / wl_keyboard helpers (the popup grab redirects
//     both pointer and keyboard focus — Esc dismissal arrives on the
//     grab's wl_keyboard),
//   - libxkbcommon (keymap fd -> xkb_state -> keysym; the virtual keyboard
//     wtype plugs in ships its OWN generated keymap, so raw keycodes are
//     meaningless — only the keysym lookup identifies Escape),
//   - <poll.h> for the timeout-driven event loop (the reposition probe and
//     the stale-grab watchdog are time-based, not event-based),
//   - hand-written zwlr_virtual_pointer_v1 tables (f13 pattern, plus
//     motion_absolute) for the scripted ./inject.d gesture sessions.
//
// Nix's cc wrapper injects -D_FORTIFY_SOURCE, and glibc's fortify wrappers
// use __builtin_dynamic_object_size, which ImportC does not implement.
#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1 /* memfd_create(2) in <sys/mman.h> */

#pragma attribute(push, nogc, nothrow)
#include <unistd.h>
#include <poll.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "xdg-shell-client-protocol.h"

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

/* ---- wl_seat / wl_pointer / wl_keyboard ------------------------------ */

int wsi_seat_add_listener(struct wl_seat *s, const struct wl_seat_listener *l, void *data)
{
    return wl_seat_add_listener(s, l, data);
}

struct wl_pointer *wsi_seat_get_pointer(struct wl_seat *s)
{
    return wl_seat_get_pointer(s);
}

struct wl_keyboard *wsi_seat_get_keyboard(struct wl_seat *s)
{
    return wl_seat_get_keyboard(s);
}

void wsi_seat_destroy(struct wl_seat *s)
{
    wl_seat_destroy(s);
}

int wsi_pointer_add_listener(struct wl_pointer *p,
    const struct wl_pointer_listener *l, void *data)
{
    return wl_pointer_add_listener(p, l, data);
}

void wsi_pointer_destroy(struct wl_pointer *p)
{
    wl_pointer_destroy(p);
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

/* ---- xdg_positioner / xdg_popup -------------------------------------- */

struct xdg_positioner *wsi_wm_base_create_positioner(struct xdg_wm_base *b)
{
    return xdg_wm_base_create_positioner(b);
}

void wsi_positioner_set_size(struct xdg_positioner *p, int32_t w, int32_t h)
{
    xdg_positioner_set_size(p, w, h);
}

void wsi_positioner_set_anchor_rect(struct xdg_positioner *p,
    int32_t x, int32_t y, int32_t w, int32_t h)
{
    xdg_positioner_set_anchor_rect(p, x, y, w, h);
}

void wsi_positioner_set_anchor(struct xdg_positioner *p, uint32_t anchor)
{
    xdg_positioner_set_anchor(p, anchor);
}

void wsi_positioner_set_gravity(struct xdg_positioner *p, uint32_t gravity)
{
    xdg_positioner_set_gravity(p, gravity);
}

void wsi_positioner_set_constraint_adjustment(struct xdg_positioner *p, uint32_t adj)
{
    xdg_positioner_set_constraint_adjustment(p, adj);
}

void wsi_positioner_set_offset(struct xdg_positioner *p, int32_t x, int32_t y)
{
    xdg_positioner_set_offset(p, x, y);
}

void wsi_positioner_set_reactive(struct xdg_positioner *p)
{
    xdg_positioner_set_reactive(p); /* since v3 */
}

void wsi_positioner_destroy(struct xdg_positioner *p)
{
    xdg_positioner_destroy(p);
}

struct xdg_popup *wsi_xdg_surface_get_popup(struct xdg_surface *s,
    struct xdg_surface *parent, struct xdg_positioner *pos)
{
    return xdg_surface_get_popup(s, parent, pos);
}

int wsi_popup_add_listener(struct xdg_popup *p,
    const struct xdg_popup_listener *l, void *data)
{
    return xdg_popup_add_listener(p, l, data);
}

void wsi_popup_grab(struct xdg_popup *p, struct wl_seat *seat, uint32_t serial)
{
    xdg_popup_grab(p, seat, serial);
}

void wsi_popup_reposition(struct xdg_popup *p, struct xdg_positioner *pos, uint32_t token)
{
    xdg_popup_reposition(p, pos, token); /* since v3 */
}

void wsi_popup_destroy(struct xdg_popup *p)
{
    xdg_popup_destroy(p);
}

#pragma attribute(pop)

/* ---- zwlr_virtual_pointer_v1 (hand-written interface tables) --------- */
/* The demo's `inject` mode (see ./inject.d) plugs ONE virtual pointer in and
 * scripts a whole popup scenario inside that single device session — a
 * per-gesture plug/unplug (the wlrctl model) would flap the seat's pointer
 * capability mid-grab, and whether THAT dismisses the popup must stay a
 * controlled measurement, not an accident. Tables hand-derived from
 * wlr-virtual-pointer-unstable-v1.xml exactly as in the F13 shim, plus
 * motion_absolute (opcode 1) for global-coordinate scripting. */

#pragma attribute(push, nogc, nothrow)

static const struct wl_interface *vp_null_types[5] = { NULL, NULL, NULL, NULL, NULL };

static const struct wl_message wsi_vptr_requests[] = {
    { "motion", "uff", vp_null_types },
    { "motion_absolute", "uuuuu", vp_null_types },
    { "button", "uuu", vp_null_types },
    { "axis", "uuf", vp_null_types },
    { "frame", "", vp_null_types },
    { "axis_source", "u", vp_null_types },
    { "axis_stop", "uu", vp_null_types },
    { "axis_discrete", "uufi", vp_null_types },
    { "destroy", "", vp_null_types },
};

const struct wl_interface wsi_virtual_pointer_interface = {
    "zwlr_virtual_pointer_v1", 2, 9, wsi_vptr_requests, 0, NULL,
};

static const struct wl_interface *vpm_create_types[2];

static const struct wl_message wsi_vpm_requests[] = {
    { "create_virtual_pointer", "?on", vpm_create_types },
    { "destroy", "", vp_null_types },
};

const struct wl_interface wsi_virtual_pointer_manager_interface = {
    "zwlr_virtual_pointer_manager_v1", 2, 2, wsi_vpm_requests, 0, NULL,
};

struct wl_proxy *wsi_vpm_create_virtual_pointer(struct wl_proxy *mgr, struct wl_seat *seat)
{
    vpm_create_types[0] = &wl_seat_interface;
    vpm_create_types[1] = &wsi_virtual_pointer_interface;
    return wl_proxy_marshal_flags(mgr, 0, &wsi_virtual_pointer_interface,
        wl_proxy_get_version(mgr), 0, seat, NULL);
}

void wsi_vpm_destroy(struct wl_proxy *mgr)
{
    wl_proxy_marshal_flags(mgr, 1, NULL, wl_proxy_get_version(mgr), WL_MARSHAL_FLAG_DESTROY);
}

void wsi_vptr_motion_absolute(struct wl_proxy *p, uint32_t time,
    uint32_t x, uint32_t y, uint32_t x_extent, uint32_t y_extent)
{
    wl_proxy_marshal_flags(p, 1, NULL, wl_proxy_get_version(p), 0,
        time, x, y, x_extent, y_extent);
}

void wsi_vptr_button(struct wl_proxy *p, uint32_t time, uint32_t button, uint32_t state)
{
    wl_proxy_marshal_flags(p, 2, NULL, wl_proxy_get_version(p), 0, time, button, state);
}

void wsi_vptr_frame(struct wl_proxy *p)
{
    wl_proxy_marshal_flags(p, 4, NULL, wl_proxy_get_version(p), 0);
}

void wsi_vptr_destroy(struct wl_proxy *p)
{
    wl_proxy_marshal_flags(p, 8, NULL, wl_proxy_get_version(p), WL_MARSHAL_FLAG_DESTROY);
}

#pragma attribute(pop)

// The generated request-marshalling tables (`xdg_wm_base_interface`, …).
// Textually included so the package stays a single C translation unit (see
// `excludedSourceFiles` in ./dub.sdl and the scaffold notes).
#include "xdg-shell-protocol.c"
