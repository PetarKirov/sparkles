// ImportC shim for the F06 keyboard demo: Xlib for the window + event loop,
// Xlib-xcb to hand the same connection's xcb_connection_t to xkbcommon-x11,
// XKBlib for XkbSelectEvents/XkbSetDetectableAutoRepeat and the XkbEvent
// union, and the xkbcommon keymap/state/compose machinery. The D compiler
// parses the real system headers — no hand-written bindings to drift. See
// docs/guidelines/importc-c-libraries.md.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/Xlib-xcb.h>
#include <X11/XKBlib.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-x11.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <poll.h>
#pragma attribute(pop)
