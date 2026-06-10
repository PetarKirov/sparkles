// ImportC shim for the X11 F08 (DPI) demo: the D compiler parses the real
// system headers, so every type (Display, XEvent, XrmValue, XRRScreenResources,
// XRROutputInfo, ...) and function signature is taken verbatim from libX11 /
// libXrandr / glibc — no hand-written bindings to drift. See
// docs/guidelines/importc-c-libraries.md. The file name `c.c` becomes the D
// module `c`; `import c;` exposes everything below as callable D symbols.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/Xresource.h>
#include <X11/extensions/Xrandr.h>
#include <poll.h>
#pragma attribute(pop)
