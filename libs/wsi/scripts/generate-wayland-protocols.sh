#!/usr/bin/env sh
# Reproduce the vendored stable xdg-shell client declarations and tables.
set -eu

repo="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"

wayland-scanner client-header "$xml" \
    "$repo/libs/wsi/src/wayland_xdg_shell_client_protocol.h"
wayland-scanner private-code "$xml" \
    "$repo/libs/wsi/src/wayland_xdg_shell_protocol.c"
# ImportC compiles both native Linux bridges into one program. The generated
# table needs only NULL from stdlib; using stddef avoids importing glibc's
# inline stdlib bodies twice (xcb_native.c legitimately needs free()).
sed -i -e 's/#include <stdlib.h>/#include <stddef.h>/' -e '${/^$/d;}' \
    "$repo/libs/wsi/src/wayland_xdg_shell_protocol.c"

# Server-side cursor shapes (staging cursor-shape-v1). The protocol's only
# tablet request is never issued, so its zwp_tablet_tool_v2 interface
# reference is stubbed to NULL rather than vendoring the whole tablet-v2
# signature table for one unused request.
cursor_xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/staging/cursor-shape/cursor-shape-v1.xml"

wayland-scanner client-header "$cursor_xml" \
    "$repo/libs/wsi/src/wayland_cursor_shape_client_protocol.h"
wayland-scanner private-code "$cursor_xml" \
    "$repo/libs/wsi/src/wayland_cursor_shape_protocol.c"
sed -i \
    -e 's/#include <stdlib.h>/#include <stddef.h>/' \
    -e 's/&zwp_tablet_tool_v2_interface/NULL/' \
    -e '/^extern const struct wl_interface zwp_tablet_tool_v2_interface;$/d' \
    -e '${/^$/d;}' \
    "$repo/libs/wsi/src/wayland_cursor_shape_protocol.c"
# The client header forward-declares the tablet interface for the same
# unused request; the declaration is harmless and stays.

# IME text input (unstable text-input-v3): commit strings, pre-edit with
# byte-range cursor/selection, and surrounding-text/change-cause requests.
text_xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/unstable/text-input/text-input-unstable-v3.xml"

wayland-scanner client-header "$text_xml" \
    "$repo/libs/wsi/src/wayland_text_input_client_protocol.h"
wayland-scanner private-code "$text_xml" \
    "$repo/libs/wsi/src/wayland_text_input_protocol.c"
sed -i -e 's/#include <stdlib.h>/#include <stddef.h>/' -e '${/^$/d;}' \
    "$repo/libs/wsi/src/wayland_text_input_protocol.c"
