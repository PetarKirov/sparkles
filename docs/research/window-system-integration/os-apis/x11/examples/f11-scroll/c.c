// ImportC shim for the X11 F11 (scroll fidelity) demo: the D compiler parses
// the real system headers, so every type (Display, XEvent, XIDeviceEvent,
// XIScrollClassInfo, XIValuatorClassInfo, ...) and function signature is
// taken verbatim from libX11 / libXi / glibc — no hand-written bindings to
// drift. See docs/guidelines/importc-c-libraries.md. The whole of
// <X11/extensions/XI2.h> (event ids, class types, the XIPointerEmulated
// flag) is #defines, which ImportC cannot export — the demo re-declares
// them, per the scaffold gotcha. The file name `c.c` becomes the D module `c`.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XInput2.h>
#include <poll.h>
#pragma attribute(pop)
