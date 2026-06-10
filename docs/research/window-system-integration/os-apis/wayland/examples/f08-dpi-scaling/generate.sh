#!/bin/sh
# Generate the client glue for the protocols this demo binds beyond the core:
# xdg-shell (stable), viewporter (stable) and fractional-scale-v1 (staging).
# Invoked by dub's preGenerateCommands (see ./dub.sdl); idempotent so
# incremental builds stay fast. The dev shell provides wayland-scanner +
# wayland-protocols; the protocol XML is located via pkg-config, never hardcoded.
set -eu
cd "$(dirname "$0")"
pdir="$(pkg-config --variable=pkgdatadir wayland-protocols)"

gen() { # gen <xml-path> <basename>
    [ -f "$2-client-protocol.h" ] || wayland-scanner client-header "$1" "$2-client-protocol.h"
    [ -f "$2-protocol.c" ] || wayland-scanner private-code "$1" "$2-protocol.c"
}

gen "$pdir/stable/xdg-shell/xdg-shell.xml" xdg-shell
gen "$pdir/stable/viewporter/viewporter.xml" viewporter
gen "$pdir/staging/fractional-scale/fractional-scale-v1.xml" fractional-scale-v1
