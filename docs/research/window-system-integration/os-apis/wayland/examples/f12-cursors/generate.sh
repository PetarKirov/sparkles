#!/bin/sh
# Generate the client glue for the protocols this demo binds beyond the core:
# xdg-shell (stable) and cursor-shape-v1 (staging). cursor-shape-v1's
# get_tablet_tool_v2 request references zwp_tablet_tool_v2, so the tablet-v2
# glue must be generated too — purely for the extern interface symbol; the
# demo never binds it. Invoked by dub's preGenerateCommands (see ./dub.sdl);
# idempotent so incremental builds stay fast. The dev shell provides
# wayland-scanner + wayland-protocols; the protocol XML is located via
# pkg-config, never hardcoded.
set -eu
cd "$(dirname "$0")"
pdir="$(pkg-config --variable=pkgdatadir wayland-protocols)"

gen() { # gen <xml-path> <basename>
    [ -f "$2-client-protocol.h" ] || wayland-scanner client-header "$1" "$2-client-protocol.h"
    [ -f "$2-protocol.c" ] || wayland-scanner private-code "$1" "$2-protocol.c"
}

gen "$pdir/stable/xdg-shell/xdg-shell.xml" xdg-shell
gen "$pdir/stable/tablet/tablet-v2.xml" tablet-v2
gen "$pdir/staging/cursor-shape/cursor-shape-v1.xml" cursor-shape-v1
