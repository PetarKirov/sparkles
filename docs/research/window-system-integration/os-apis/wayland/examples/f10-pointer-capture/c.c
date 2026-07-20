// ImportC shim for the F10 pointer-capture demo (see ./app.d and
// ../../scaffold.md). Same three jobs as the scaffold's shim — one
// translation unit for the libwayland ABI + the scanner-generated glue
// (xdg-shell, pointer-constraints-unstable-v1, relative-pointer-unstable-v1,
// see ./generate.sh), POSIX shm pieces, and `wsi_*` re-exports of every
// `static inline` request helper ImportC cannot call.
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
#include "xdg-shell-client-protocol.h"
#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"

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

/* ---- wl_compositor / wl_surface / wl_region ------------------------- */

struct wl_surface *wsi_compositor_create_surface(struct wl_compositor *c)
{
    return wl_compositor_create_surface(c);
}

struct wl_region *wsi_compositor_create_region(struct wl_compositor *c)
{
    return wl_compositor_create_region(c);
}

void wsi_region_add(struct wl_region *r, int32_t x, int32_t y, int32_t w, int32_t h)
{
    wl_region_add(r, x, y, w, h);
}

void wsi_region_destroy(struct wl_region *r)
{
    wl_region_destroy(r);
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

/* ---- wl_seat / wl_pointer -------------------------------------------- */

int wsi_seat_add_listener(struct wl_seat *s,
    const struct wl_seat_listener *l, void *data)
{
    return wl_seat_add_listener(s, l, data);
}

struct wl_pointer *wsi_seat_get_pointer(struct wl_seat *s)
{
    return wl_seat_get_pointer(s);
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

/* ---- pointer-constraints-unstable-v1 --------------------------------- */

struct zwp_locked_pointer_v1 *wsi_lock_pointer(
    struct zwp_pointer_constraints_v1 *pc, struct wl_surface *surface,
    struct wl_pointer *pointer, struct wl_region *region, uint32_t lifetime)
{
    return zwp_pointer_constraints_v1_lock_pointer(pc, surface, pointer, region, lifetime);
}

struct zwp_confined_pointer_v1 *wsi_confine_pointer(
    struct zwp_pointer_constraints_v1 *pc, struct wl_surface *surface,
    struct wl_pointer *pointer, struct wl_region *region, uint32_t lifetime)
{
    return zwp_pointer_constraints_v1_confine_pointer(pc, surface, pointer, region, lifetime);
}

void wsi_constraints_destroy(struct zwp_pointer_constraints_v1 *pc)
{
    zwp_pointer_constraints_v1_destroy(pc);
}

int wsi_locked_add_listener(struct zwp_locked_pointer_v1 *lp,
    const struct zwp_locked_pointer_v1_listener *l, void *data)
{
    return zwp_locked_pointer_v1_add_listener(lp, l, data);
}

void wsi_locked_set_cursor_position_hint(struct zwp_locked_pointer_v1 *lp,
    wl_fixed_t x, wl_fixed_t y)
{
    zwp_locked_pointer_v1_set_cursor_position_hint(lp, x, y);
}

void wsi_locked_destroy(struct zwp_locked_pointer_v1 *lp)
{
    zwp_locked_pointer_v1_destroy(lp);
}

int wsi_confined_add_listener(struct zwp_confined_pointer_v1 *cp,
    const struct zwp_confined_pointer_v1_listener *l, void *data)
{
    return zwp_confined_pointer_v1_add_listener(cp, l, data);
}

void wsi_confined_destroy(struct zwp_confined_pointer_v1 *cp)
{
    zwp_confined_pointer_v1_destroy(cp);
}

/* ---- relative-pointer-unstable-v1 ------------------------------------ */

struct zwp_relative_pointer_v1 *wsi_get_relative_pointer(
    struct zwp_relative_pointer_manager_v1 *m, struct wl_pointer *p)
{
    return zwp_relative_pointer_manager_v1_get_relative_pointer(m, p);
}

void wsi_relative_manager_destroy(struct zwp_relative_pointer_manager_v1 *m)
{
    zwp_relative_pointer_manager_v1_destroy(m);
}

int wsi_relative_add_listener(struct zwp_relative_pointer_v1 *rp,
    const struct zwp_relative_pointer_v1_listener *l, void *data)
{
    return zwp_relative_pointer_v1_add_listener(rp, l, data);
}

void wsi_relative_destroy(struct zwp_relative_pointer_v1 *rp)
{
    zwp_relative_pointer_v1_destroy(rp);
}

/* ---- zwlr_virtual_pointer_v1 (hand-written interface tables) --------- */
/* The demo's `inject` mode (see ./inject.d) plugs a virtual pointer device
 * in — that is what makes a headless wlroots seat gain the pointer
 * capability at all. wlr-protocols is not part of wayland-protocols, so the
 * dev shell has no XML to scan; the tables below are hand-derived from
 * wlr-virtual-pointer-unstable-v1.xml (interface version 2). Request order
 * (== opcodes): motion, motion_absolute, button, axis, frame, axis_source,
 * axis_stop, axis_discrete, destroy. Only the requests the injector uses get
 * wrappers. */

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
    /* ImportC rejects address-of-extern in a static initializer ("not a
     * constant expression"), so the types array is patched lazily. */
    vpm_create_types[0] = &wl_seat_interface;
    vpm_create_types[1] = &wsi_virtual_pointer_interface;
    return wl_proxy_marshal_flags(mgr, 0, &wsi_virtual_pointer_interface,
        wl_proxy_get_version(mgr), 0, seat, NULL);
}

void wsi_vpm_destroy(struct wl_proxy *mgr)
{
    wl_proxy_marshal_flags(mgr, 1, NULL, wl_proxy_get_version(mgr), WL_MARSHAL_FLAG_DESTROY);
}

void wsi_vptr_motion(struct wl_proxy *p, uint32_t time, wl_fixed_t dx, wl_fixed_t dy)
{
    wl_proxy_marshal_flags(p, 0, NULL, wl_proxy_get_version(p), 0, time, dx, dy);
}

void wsi_vptr_frame(struct wl_proxy *p)
{
    wl_proxy_marshal_flags(p, 4, NULL, wl_proxy_get_version(p), 0);
}

void wsi_vptr_destroy(struct wl_proxy *p)
{
    wl_proxy_marshal_flags(p, 8, NULL, wl_proxy_get_version(p), WL_MARSHAL_FLAG_DESTROY);
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

#pragma attribute(pop)

// The generated request-marshalling tables, textually included so the package
// stays a single C translation unit (see `excludedSourceFiles` in ./dub.sdl).
#include "xdg-shell-protocol.c"
#include "pointer-constraints-unstable-v1-protocol.c"
#include "relative-pointer-unstable-v1-protocol.c"
