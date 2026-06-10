// ImportC shim for the X11 F10 (pointer capture) demo: the D compiler parses
// the real system headers, so every type (Display, XEvent, XIEventMask,
// XIRawEvent, XIDeviceEvent, XIBarrierEvent, PointerBarrier, ...) and function
// signature is taken verbatim from libX11 / libXi / libXfixes / glibc — no
// hand-written bindings to drift. See docs/guidelines/importc-c-libraries.md.
// <X11/extensions/XI2.h> event ids, mask macros (XISetMask), and the XFixes
// barrier directions are all #defines, which ImportC cannot export — the demo
// re-declares them, per the scaffold gotcha. The file name `c.c` becomes the
// D module `c`.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/Xfixes.h>
#include <poll.h>
#pragma attribute(pop)
