// ImportC shim for the F16 clipboard + drag-and-drop demo: the D compiler
// parses the real system headers, so every type (Display, XEvent,
// XSelectionRequestEvent, struct pollfd, ...) and function signature is taken
// verbatim from libX11 / glibc — no hand-written bindings to drift. See
// docs/guidelines/importc-c-libraries.md. The file name `c.c` becomes the D
// module `c`; `import c;` exposes everything below as callable D symbols.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <poll.h>
#pragma attribute(pop)
