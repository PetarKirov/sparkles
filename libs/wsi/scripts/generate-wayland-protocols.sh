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
