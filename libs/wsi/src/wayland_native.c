/*
 * ImportC bridge for the native Wayland WSI adapter — includes only.
 *
 * Core protocol declarations come from libwayland-client; the stable
 * xdg-shell declarations/table are scanner-generated and vendored beside
 * this file so consumers do not need wayland-scanner at build time. ImportC
 * exposes the static-inline request helpers directly, so the D adapter calls
 * the real protocol API with no wrapper bodies here.
 */
#undef _FORTIFY_SOURCE

#pragma attribute(push, nogc, nothrow)
#include <wayland-client.h>
#include "wayland_xdg_shell_client_protocol.h"
#pragma attribute(pop)

/* Generated request/event signature tables (no second translation unit). */
#include "wayland_xdg_shell_protocol.c"
