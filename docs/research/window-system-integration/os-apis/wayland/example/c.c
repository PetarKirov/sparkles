// ImportC shim: the D compiler parses the real libwayland-client headers, so the
// core ABI (wl_display, wl_proxy, wl_proxy_marshal_flags) AND the generated core
// protocol — including the real exported `wl_registry_interface` type table and
// the `wl_registry_listener` struct — come straight from the system library. That
// table is the fragile part to hand-write; ImportC gives it to us for free.
// See docs/guidelines/importc-c-libraries.md. `c.c` -> D module `c`.
#pragma attribute(push, nogc, nothrow)
#include <wayland-client.h>
#pragma attribute(pop)
