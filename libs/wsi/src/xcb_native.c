/*
 * ImportC bridge for the native X11/XCB WSI adapter — includes only.
 *
 * XCB is the native X11 client API; ImportC exposes its declarations
 * directly, so bootstrap, lifecycle batching, and event translation live in
 * the D adapter with no wrapper bodies here.
 */
#undef _FORTIFY_SOURCE

#pragma attribute(push, nogc, nothrow)
#include <xcb/xcb.h>
#include <xcb/xkb.h>
#include <xcb/xtest.h>
#pragma attribute(pop)
