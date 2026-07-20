// ImportC shim for the X11 F03 (modal-loop survival) demo: the scaffold's
// headers (Xlib + MIT-SHM + SysV shm + poll) plus <sys/timerfd.h> — the demo's
// animation heartbeat is a timerfd polled alongside the X connection fd, the
// exact "own your loop" shape a framework needs. See
// docs/guidelines/importc-c-libraries.md. The file name `c.c` becomes the D
// module `c`; `import c;` exposes everything below as callable D symbols.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/XShm.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/timerfd.h>
#include <poll.h>
#pragma attribute(pop)
