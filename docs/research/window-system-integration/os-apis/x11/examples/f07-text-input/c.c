// ImportC shim for the X11 F07 (XIM text input) demo: the D compiler parses
// the real system headers, so every type (Display, XIM, XIC, XIMStyles,
// XIMCallback, XIMPreeditDrawCallbackStruct, ...) and function signature —
// including the varargs XCreateIC / XGetIMValues / XSetICValues /
// XVaCreateNestedList family — is taken verbatim from libX11. See
// docs/guidelines/importc-c-libraries.md. The file name `c.c` becomes the D
// module `c`; `import c;` exposes everything below as callable D symbols.
//
// Unlike the sibling demos' shims, this one is COMPILED (dub `sourceFiles`),
// not just imported, because it defines the two helper functions below. As a
// root module ImportC semantically checks every glibc fortify wrapper, and
// the Nix toolchain's default -D_FORTIFY_SOURCE pulls in
// __builtin_dynamic_object_size, which ImportC lacks — so switch it off.
#undef _FORTIFY_SOURCE

#pragma attribute(push, nogc, nothrow)
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <poll.h>

// XIMText's payload union is a member literally named `string`, which is a D
// keyword, so the field is unreachable from D code. Two one-line accessors
// keep the demo honest without hand-copying the struct layout (non-static so
// they have external linkage for the D modules to call).
const char *xim_text_mb(const XIMText *t)
{
    return (t && !t->encoding_is_wchar) ? t->string.multi_byte : 0;
}

int xim_text_len(const XIMText *t)
{
    return t ? (int) t->length : -1;
}
#pragma attribute(pop)
