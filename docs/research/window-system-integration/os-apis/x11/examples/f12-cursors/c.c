// ImportC shim for the X11 F12 (cursors) demo: the D compiler parses the real
// system headers, so every type (Display, XEvent, Cursor, XcursorImage,
// XcursorImages, ...) and function signature is taken verbatim from libX11 /
// libXcursor / glibc — no hand-written bindings to drift. See
// docs/guidelines/importc-c-libraries.md. <X11/cursorfont.h> is NOT included:
// it is macros only (`#define XC_left_ptr 68` ...), which ImportC cannot
// export — the demo re-declares the glyph ids it uses, per the scaffold
// gotcha. The file name `c.c` becomes the D module `c`.
#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xcursor/Xcursor.h>
#include <poll.h>
#pragma attribute(pop)
