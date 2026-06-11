#!/bin/sh
# Generate the xdg-shell + xdg-decoration-unstable-v1 client glue next to this
# script (scaffold pattern, see ../scaffold/generate.sh). Invoked by dub's
# preGenerateCommands; idempotent. The XML is located via pkg-config.
set -eu
cd "$(dirname "$0")"
pd="$(pkg-config --variable=pkgdatadir wayland-protocols)"
gen() # gen <xml-path> <stem>
{
    [ -f "$2-client-protocol.h" ] || wayland-scanner client-header "$1" "$2-client-protocol.h"
    [ -f "$2-protocol.c" ] || wayland-scanner private-code "$1" "$2-protocol.c"
}
gen "$pd/stable/xdg-shell/xdg-shell.xml" xdg-shell
gen "$pd/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" xdg-decoration-unstable-v1
