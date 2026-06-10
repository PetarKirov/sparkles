// ImportC shim for the X11 F04 (frame pacing) demo. The Present extension has
// no Xlib binding at all — it is xcb-only — so this demo uses the documented
// Xlib/XCB interop layer (<X11/Xlib-xcb.h>): the window/setup side stays Xlib
// (same as every other demo in this tree), XGetXCBConnection exposes the
// underlying xcb_connection_t, and XSetEventQueueOwner hands the event queue
// to xcb so Present's GenericEvents can be read with xcb_poll_for_event.
// See docs/guidelines/importc-c-libraries.md for the binding style.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xlib-xcb.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <xcb/xcb.h>
#include <xcb/present.h>
#include <sys/timerfd.h>
#include <poll.h>
#pragma attribute(pop)
