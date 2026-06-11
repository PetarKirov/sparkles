#!/bin/sh
# Generate the xdg-shell client glue next to this script — the scroll-axis
# machinery itself is all core-protocol wl_pointer (axis / axis_value120 /
# axis_source / axis_stop / axis_relative_direction / frame), so no extra
# protocol XML is needed. Invoked by dub's preGenerateCommands (see ./dub.sdl);
# idempotent so incremental builds stay fast. The dev shell provides
# wayland-scanner + wayland-protocols; the protocol XML is located via
# pkg-config, never hardcoded.
set -eu
cd "$(dirname "$0")"
xml="$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml"
[ -f xdg-shell-client-protocol.h ] || wayland-scanner client-header "$xml" xdg-shell-client-protocol.h
[ -f xdg-shell-protocol.c ] || wayland-scanner private-code "$xml" xdg-shell-protocol.c
