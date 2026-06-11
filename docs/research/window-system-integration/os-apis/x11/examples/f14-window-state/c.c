// ImportC shim for the X11 scaffold demo: the D compiler parses the real
// system headers, so every type (Display, XEvent, XImage, XShmSegmentInfo,
// struct pollfd, ...) and function signature is taken verbatim from libX11 /
// libXext / glibc — no hand-written bindings to drift. See
// docs/guidelines/importc-c-libraries.md. The file name `c.c` becomes the D
// module `c`; `import c;` exposes everything below as callable D symbols.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/extensions/XShm.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <poll.h>
#pragma attribute(pop)
