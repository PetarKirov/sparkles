/*
 * ImportC bridge for the native X11/XCB WSI adapter — includes only.
 *
 * XCB is the native X11 client API; ImportC exposes its declarations
 * directly, so bootstrap, lifecycle batching, and event translation live in
 * the D adapter with no wrapper bodies here.
 */
#undef _FORTIFY_SOURCE
/*
 * xkbcommon.h pulls in stdio.h; without this, glibc's extern-inline
 * getchar/putchar/vprintf are emitted in every ImportC bridge that
 * includes it, and the duplicate definitions across bridges turn into
 * errors under -w in single-invocation unittest builds.
 */
#define __NO_INLINE__ 1

#pragma attribute(push, nogc, nothrow)
#include <xcb/xcb.h>
#include <xcb/xkb.h>
#include <xcb/xtest.h>
#include <xcb-imdkit/imclient.h>
#include <xcb-imdkit/imdkit.h>
#include <xkbcommon/xkbcommon-x11.h>
#pragma attribute(pop)
