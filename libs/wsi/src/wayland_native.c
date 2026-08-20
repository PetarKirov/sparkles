/*
 * Narrow ImportC bridge for the native Wayland WSI adapter.
 *
 * Core protocol declarations come from libwayland-client.  The stable
 * xdg-shell declarations/table are scanner-generated and vendored beside
 * this file so consumers do not need wayland-scanner at build time.  Only
 * static-inline request helpers are re-exported here; socket ownership and
 * prepare-read dispatch remain visible in the D adapter.
 */
#undef _FORTIFY_SOURCE

#pragma attribute(push, nogc, nothrow)
#include <wayland-client.h>
#include "wayland_xdg_shell_client_protocol.h"

struct wl_registry *wsi_wayland_display_get_registry(struct wl_display *display)
{
    return wl_display_get_registry(display);
}

struct wl_callback *wsi_wayland_display_sync(struct wl_display *display)
{
    return wl_display_sync(display);
}

int wsi_wayland_registry_add_listener(struct wl_registry *registry,
    const struct wl_registry_listener *listener, void *data)
{
    return wl_registry_add_listener(registry, listener, data);
}

void *wsi_wayland_registry_bind(struct wl_registry *registry, uint32_t name,
    const struct wl_interface *interface, uint32_t version)
{
    return wl_registry_bind(registry, name, interface, version);
}

struct wl_surface *wsi_wayland_compositor_create_surface(
    struct wl_compositor *compositor)
{
    return wl_compositor_create_surface(compositor);
}

void wsi_wayland_surface_commit(struct wl_surface *surface)
{
    wl_surface_commit(surface);
}

struct wl_callback *wsi_wayland_surface_frame(struct wl_surface *surface)
{
    return wl_surface_frame(surface);
}

void wsi_wayland_surface_destroy(struct wl_surface *surface)
{
    wl_surface_destroy(surface);
}

int wsi_wayland_callback_add_listener(struct wl_callback *callback,
    const struct wl_callback_listener *listener, void *data)
{
    return wl_callback_add_listener(callback, listener, data);
}

void wsi_wayland_callback_destroy(struct wl_callback *callback)
{
    wl_callback_destroy(callback);
}

int wsi_wayland_wm_base_add_listener(struct xdg_wm_base *base,
    const struct xdg_wm_base_listener *listener, void *data)
{
    return xdg_wm_base_add_listener(base, listener, data);
}

void wsi_wayland_wm_base_pong(struct xdg_wm_base *base, uint32_t serial)
{
    xdg_wm_base_pong(base, serial);
}

struct xdg_surface *wsi_wayland_wm_base_get_xdg_surface(
    struct xdg_wm_base *base, struct wl_surface *surface)
{
    return xdg_wm_base_get_xdg_surface(base, surface);
}

void wsi_wayland_wm_base_destroy(struct xdg_wm_base *base)
{
    xdg_wm_base_destroy(base);
}

int wsi_wayland_xdg_surface_add_listener(struct xdg_surface *surface,
    const struct xdg_surface_listener *listener, void *data)
{
    return xdg_surface_add_listener(surface, listener, data);
}

struct xdg_toplevel *wsi_wayland_xdg_surface_get_toplevel(
    struct xdg_surface *surface)
{
    return xdg_surface_get_toplevel(surface);
}

void wsi_wayland_xdg_surface_ack_configure(struct xdg_surface *surface,
    uint32_t serial)
{
    xdg_surface_ack_configure(surface, serial);
}

void wsi_wayland_xdg_surface_destroy(struct xdg_surface *surface)
{
    xdg_surface_destroy(surface);
}

int wsi_wayland_toplevel_add_listener(struct xdg_toplevel *toplevel,
    const struct xdg_toplevel_listener *listener, void *data)
{
    return xdg_toplevel_add_listener(toplevel, listener, data);
}

void wsi_wayland_toplevel_set_title(struct xdg_toplevel *toplevel,
    const char *title)
{
    xdg_toplevel_set_title(toplevel, title);
}

void wsi_wayland_toplevel_set_app_id(struct xdg_toplevel *toplevel,
    const char *app_id)
{
    xdg_toplevel_set_app_id(toplevel, app_id);
}

void wsi_wayland_toplevel_set_maximized(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_set_maximized(toplevel);
}

void wsi_wayland_toplevel_unset_maximized(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_unset_maximized(toplevel);
}

void wsi_wayland_toplevel_set_fullscreen(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_set_fullscreen(toplevel, NULL);
}

void wsi_wayland_toplevel_set_min_size(struct xdg_toplevel *toplevel,
    int32_t width, int32_t height)
{
    xdg_toplevel_set_min_size(toplevel, width, height);
}

void wsi_wayland_toplevel_set_max_size(struct xdg_toplevel *toplevel,
    int32_t width, int32_t height)
{
    xdg_toplevel_set_max_size(toplevel, width, height);
}

void wsi_wayland_toplevel_destroy(struct xdg_toplevel *toplevel)
{
    xdg_toplevel_destroy(toplevel);
}

#pragma attribute(pop)

/* Generated request/event signature tables (no second translation unit). */
#include "wayland_xdg_shell_protocol.c"
