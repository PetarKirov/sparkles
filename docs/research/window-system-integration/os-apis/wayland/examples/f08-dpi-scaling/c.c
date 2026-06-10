// ImportC shim for the F08 DPI/scale demo (see ./app.d and ../../scaffold.md).
// Same three jobs as the scaffold's shim — one translation unit for the
// libwayland ABI + the scanner-generated glue (xdg-shell, viewporter AND
// fractional-scale-v1, see ./generate.sh), POSIX shm pieces, and `wsi_*`
// re-exports of every `static inline` request helper ImportC cannot call.
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
#include "viewporter-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"

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

int wsi_surface_add_listener(struct wl_surface *s,
    const struct wl_surface_listener *l, void *data)
{
    return wl_surface_add_listener(s, l, data);
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

void wsi_surface_set_buffer_scale(struct wl_surface *s, int32_t scale)
{
    wl_surface_set_buffer_scale(s, scale);
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

/* ---- wl_output ------------------------------------------------------ */

int wsi_output_add_listener(struct wl_output *o,
    const struct wl_output_listener *l, void *data)
{
    return wl_output_add_listener(o, l, data);
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

/* ---- viewporter (generated glue) ------------------------------------ */

struct wp_viewport *wsi_viewporter_get_viewport(struct wp_viewporter *v,
    struct wl_surface *s)
{
    return wp_viewporter_get_viewport(v, s);
}

void wsi_viewporter_destroy(struct wp_viewporter *v)
{
    wp_viewporter_destroy(v);
}

void wsi_viewport_set_destination(struct wp_viewport *vp, int32_t w, int32_t h)
{
    wp_viewport_set_destination(vp, w, h);
}

void wsi_viewport_destroy(struct wp_viewport *vp)
{
    wp_viewport_destroy(vp);
}

/* ---- fractional-scale-v1 (generated glue) ---------------------------- */

struct wp_fractional_scale_v1 *wsi_fractional_scale_manager_get(
    struct wp_fractional_scale_manager_v1 *m, struct wl_surface *s)
{
    return wp_fractional_scale_manager_v1_get_fractional_scale(m, s);
}

void wsi_fractional_scale_manager_destroy(struct wp_fractional_scale_manager_v1 *m)
{
    wp_fractional_scale_manager_v1_destroy(m);
}

int wsi_fractional_scale_add_listener(struct wp_fractional_scale_v1 *f,
    const struct wp_fractional_scale_v1_listener *l, void *data)
{
    return wp_fractional_scale_v1_add_listener(f, l, data);
}

void wsi_fractional_scale_destroy(struct wp_fractional_scale_v1 *f)
{
    wp_fractional_scale_v1_destroy(f);
}

#pragma attribute(pop)

// The generated request-marshalling tables, textually included so the package
// stays a single C translation unit (hyphenated filenames are not valid D
// module names; see `excludedSourceFiles` in ./dub.sdl).
#include "xdg-shell-protocol.c"
#include "viewporter-protocol.c"
#include "fractional-scale-v1-protocol.c"
