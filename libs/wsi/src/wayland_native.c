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
#include <string.h>
#include <wayland-client.h>
#include "wayland_xdg_shell_client_protocol.h"

/*
 * POSIX declarations for the test mapping helper. Enabling the glibc
 * feature macros instead would turn stdlib.h's extern-inline atof/bsearch
 * into strong ImportC symbols that collide with xcb_native.o at link.
 */
extern int mkstemp(char *name);
extern int ftruncate(int fd, long length);
extern int unlink(const char *path);
extern int close(int fd);

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

int wsi_wayland_seat_add_listener(struct wl_seat *seat,
    const struct wl_seat_listener *listener, void *data)
{
    return wl_seat_add_listener(seat, listener, data);
}

struct wl_keyboard *wsi_wayland_seat_get_keyboard(struct wl_seat *seat)
{
    return wl_seat_get_keyboard(seat);
}

void wsi_wayland_seat_destroy(struct wl_seat *seat, uint32_t bound_version)
{
    if (bound_version >= WL_SEAT_RELEASE_SINCE_VERSION)
        wl_seat_release(seat);
    else
        wl_seat_destroy(seat);
}

int wsi_wayland_keyboard_add_listener(struct wl_keyboard *keyboard,
    const struct wl_keyboard_listener *listener, void *data)
{
    return wl_keyboard_add_listener(keyboard, listener, data);
}

void wsi_wayland_keyboard_destroy(struct wl_keyboard *keyboard,
    uint32_t seat_version)
{
    if (seat_version >= WL_KEYBOARD_RELEASE_SINCE_VERSION)
        wl_keyboard_release(keyboard);
    else
        wl_keyboard_destroy(keyboard);
}

/*
 * Test-only mapping helper: attach a throwaway wl_shm buffer so a smoke's
 * surface actually maps — compositors only grant keyboard focus to mapped
 * surfaces. Runs its own registry round trips on the shared display, so the
 * caller must hold the WSI native-I/O borrow, exactly as a renderer would.
 */
struct wsi_wayland_test_shm
{
    struct wl_shm *shm;
};

static void wsi_wayland_test_shm_global(void *data,
    struct wl_registry *registry, uint32_t name, const char *interface,
    uint32_t version)
{
    struct wsi_wayland_test_shm *state = data;
    (void) version;
    if (strcmp(interface, wl_shm_interface.name) == 0 && !state->shm)
        state->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
}

static void wsi_wayland_test_shm_global_remove(void *data,
    struct wl_registry *registry, uint32_t name)
{
    (void) data;
    (void) registry;
    (void) name;
}

int wsi_wayland_test_attach_shm_buffer(struct wl_display *display,
    struct wl_surface *surface, int32_t width, int32_t height)
{
    static const struct wl_registry_listener listener = {
        wsi_wayland_test_shm_global, wsi_wayland_test_shm_global_remove
    };
    struct wsi_wayland_test_shm state = { 0 };
    struct wl_registry *registry = wl_display_get_registry(display);
    if (!registry)
        return -1;
    if (wl_registry_add_listener(registry, &listener, &state) != 0
        || wl_display_roundtrip(display) < 0 || !state.shm)
    {
        wl_proxy_destroy((struct wl_proxy *) registry);
        return -1;
    }

    char path[] = "/tmp/wsi-test-shm-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        return -1;
    unlink(path);
    const int32_t stride = width * 4;
    const int32_t size = stride * height;
    if (ftruncate(fd, size) != 0)
    {
        close(fd);
        return -1;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(state.shm, fd, size);
    struct wl_buffer *buffer = pool
        ? wl_shm_pool_create_buffer(pool, 0, width, height, stride,
            WL_SHM_FORMAT_XRGB8888)
        : NULL;
    if (!buffer)
    {
        if (pool)
            wl_shm_pool_destroy(pool);
        close(fd);
        return -1;
    }
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    const int flushed = wl_display_roundtrip(display);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_proxy_destroy((struct wl_proxy *) state.shm);
    wl_proxy_destroy((struct wl_proxy *) registry);
    return flushed < 0 ? -1 : 0;
}

#pragma attribute(pop)

/* Generated request/event signature tables (no second translation unit). */
#include "wayland_xdg_shell_protocol.c"
