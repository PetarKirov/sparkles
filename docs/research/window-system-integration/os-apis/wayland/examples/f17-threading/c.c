// ImportC shim for the F17 threading-probe demo — the scaffold shim
// (../scaffold/c.c) plus wsi_display_sync (probe 3's per-queue callback).
// NOTE: <pthread.h> itself is NOT importable — glibc's pthread.h drags in
// <linux/types.h> (__int128), so threads come from druntime's
// core.sys.posix.pthread declarations instead (see ../../f05-loop-wakeup.md).
//
// Original scaffold notes (see ./app.d and ../../index.md).
// Three jobs:
//
//   1. Import the real libwayland-client ABI *and* the wayland-scanner-generated
//      xdg-shell client glue (see ./generate.sh) into one translation unit,
//      which becomes the D module `c`.
//   2. Provide the POSIX shared-memory pieces (`memfd_create`, `mmap`,
//      `ftruncate`, `close`) the wl_shm software-rendering path needs.
//   3. Re-export the `static inline` request helpers as real `wsi_*` functions.
//      ImportC compiles static inlines but does not make them callable from D —
//      the same limitation ../../example/app.d works around by hand-expanding
//      `wl_proxy_marshal_flags`. One-line C wrappers scale far better than
//      hand-marshalling once a real window needs ~25 of them, and they keep the
//      listener types exact (no function-pointer casts on the D side).
// Nix's cc wrapper injects -D_FORTIFY_SOURCE, and glibc's fortify wrappers
// (bits/unistd.h) use __builtin_dynamic_object_size, which ImportC does not
// implement — undefine it before the first glibc include.
#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1 /* memfd_create(2) in <sys/mman.h> */

#pragma attribute(push, nogc, nothrow)
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
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

/* ---- wl_display.sync (static inline in the generated core header) ---- */

/* Also accepts a wl_proxy_create_wrapper() of the display: the wrapper is
 * what wl_proxy_set_queue() is applied to, so the sync callback's done
 * event lands on a worker-owned queue (probe 3). */
struct wl_callback *wsi_display_sync(struct wl_display *d)
{
    return wl_display_sync(d);
}

/* ---- wl_seat -------------------------------------------------------- */

int wsi_seat_add_listener(struct wl_seat *s, const struct wl_seat_listener *l, void *data)
{
    return wl_seat_add_listener(s, l, data);
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

void wsi_toplevel_set_maximized(struct xdg_toplevel *t)
{
    xdg_toplevel_set_maximized(t);
}

void wsi_toplevel_unset_maximized(struct xdg_toplevel *t)
{
    xdg_toplevel_unset_maximized(t);
}

void wsi_toplevel_destroy(struct xdg_toplevel *t)
{
    xdg_toplevel_destroy(t);
}

#pragma attribute(pop)

// The generated request-marshalling tables (`xdg_wm_base_interface`, …).
// Textually included so the package stays a single C translation unit: dub
// would otherwise compile the generated file as its own D module, and its
// hyphenated filename is not a valid module name ("module `xdg-shell-protocol`
// has non-identifier characters in filename"). See `excludedSourceFiles` in
// ./dub.sdl.
#include "xdg-shell-protocol.c"
