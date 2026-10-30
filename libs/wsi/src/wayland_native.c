/*
 * ImportC bridge for the native Wayland adapter and software painter.
 *
 * Core protocol declarations come from libwayland-client; the stable
 * xdg-shell declarations/table are scanner-generated and vendored beside
 * this file so consumers do not need wayland-scanner at build time. ImportC
 * exposes declarations directly. Requests used by the software painter need
 * external entry points: DMD cannot call header-local static inline functions
 * from a separate D module. Keep their upstream bodies behind renamed helpers.
 */
#undef _FORTIFY_SOURCE
/*
 * xkbcommon.h pulls in stdio.h; without this, glibc's extern-inline
 * getchar/putchar/vprintf are emitted in every ImportC bridge that
 * includes it, and the duplicate definitions across bridges turn into
 * errors under -w in single-invocation unittest builds.
 */
#define __NO_INLINE__ 1

#define wl_display_get_registry sparkles_wl_display_get_registry_impl
#define wl_registry_add_listener sparkles_wl_registry_add_listener_impl
#define wl_registry_bind sparkles_wl_registry_bind_impl
#define wl_shm_create_pool sparkles_wl_shm_create_pool_impl
#define wl_shm_pool_destroy sparkles_wl_shm_pool_destroy_impl
#define wl_shm_pool_create_buffer sparkles_wl_shm_pool_create_buffer_impl
#define wl_surface_attach sparkles_wl_surface_attach_impl
#define wl_surface_damage sparkles_wl_surface_damage_impl
#define wl_surface_commit sparkles_wl_surface_commit_impl
#define wl_buffer_destroy sparkles_wl_buffer_destroy_impl

#pragma attribute(push, nogc, nothrow)
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "wayland_xdg_shell_client_protocol.h"
#include "wayland_cursor_shape_client_protocol.h"
#include "wayland_text_input_client_protocol.h"
#include "wayland_pointer_constraints_client_protocol.h"
#include "wayland_relative_pointer_client_protocol.h"
#include "wayland_xdg_decoration_client_protocol.h"
#include "wayland_viewporter_client_protocol.h"
#pragma attribute(pop)

#undef wl_display_get_registry
#undef wl_registry_add_listener
#undef wl_registry_bind
#undef wl_shm_create_pool
#undef wl_shm_pool_destroy
#undef wl_shm_pool_create_buffer
#undef wl_surface_attach
#undef wl_surface_damage
#undef wl_surface_commit
#undef wl_buffer_destroy

#pragma attribute(push, nogc, nothrow)
struct wl_registry *wl_display_get_registry(struct wl_display *display)
{
    return sparkles_wl_display_get_registry_impl(display);
}
int wl_registry_add_listener(struct wl_registry *registry,
    const struct wl_registry_listener *listener, void *data)
{
    return sparkles_wl_registry_add_listener_impl(registry, listener, data);
}
void *wl_registry_bind(struct wl_registry *registry, uint32_t name,
    const struct wl_interface *interface, uint32_t version)
{
    return sparkles_wl_registry_bind_impl(registry, name, interface, version);
}
struct wl_shm_pool *wl_shm_create_pool(struct wl_shm *shm, int32_t fd, int32_t size)
{
    return sparkles_wl_shm_create_pool_impl(shm, fd, size);
}
void wl_shm_pool_destroy(struct wl_shm_pool *pool)
{
    sparkles_wl_shm_pool_destroy_impl(pool);
}
struct wl_buffer *wl_shm_pool_create_buffer(struct wl_shm_pool *pool,
    int32_t offset, int32_t width, int32_t height, int32_t stride, uint32_t format)
{
    return sparkles_wl_shm_pool_create_buffer_impl(pool, offset, width, height, stride, format);
}
void wl_surface_attach(struct wl_surface *surface, struct wl_buffer *buffer,
    int32_t x, int32_t y)
{
    sparkles_wl_surface_attach_impl(surface, buffer, x, y);
}
void wl_surface_damage(struct wl_surface *surface,
    int32_t x, int32_t y, int32_t width, int32_t height)
{
    sparkles_wl_surface_damage_impl(surface, x, y, width, height);
}
void wl_surface_commit(struct wl_surface *surface)
{
    sparkles_wl_surface_commit_impl(surface);
}
void wl_buffer_destroy(struct wl_buffer *buffer)
{
    sparkles_wl_buffer_destroy_impl(buffer);
}
#pragma attribute(pop)

/* Generated request/event signature tables (no second translation unit). */
#include "wayland_xdg_shell_protocol.c"
#include "wayland_cursor_shape_protocol.c"
#include "wayland_text_input_protocol.c"
#include "wayland_pointer_constraints_protocol.c"
#include "wayland_relative_pointer_protocol.c"
#include "wayland_xdg_decoration_protocol.c"
#include "wayland_viewporter_protocol.c"
