// ImportC shim: the D compiler parses the real Xlib header, so every type
// (Display, Window, XEvent's exact union layout, …) and function signature is
// taken verbatim from the system library — no hand-written bindings to drift.
// See docs/guidelines/importc-c-libraries.md. The file name `c.c` becomes the D
// module `c`; `import c;` exposes all of <X11/Xlib.h> as callable D symbols.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#pragma attribute(pop)
