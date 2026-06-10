// ImportC shim for the F05 loop-wakeup demo: Xlib for the window + the two
// connections, poll(2) for the readiness loop, eventfd(2)/timerfd(2) as the
// "arbitrary external fd" probes the F05 spec requires. The D compiler parses
// the real system headers — no hand-written bindings to drift. See
// docs/guidelines/importc-c-libraries.md.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <unistd.h>
#include <time.h>
#pragma attribute(pop)
