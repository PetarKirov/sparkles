#!/bin/sh
# Symlink libdecor.h next to this script so ImportC finds it without nonstandard
# include paths (pkg-config locates it; nothing is hardcoded). Invoked by dub's
# preGenerateCommands; idempotent. Needs PKG_CONFIG_PATH to contain
# libdecor-0.pc — see ../run.sh, which derives it via `nix build nixpkgs#libdecor.dev`.
set -eu
cd "$(dirname "$0")"
inc="$(pkg-config --variable=includedir libdecor-0)/libdecor-0/libdecor.h"
[ -e libdecor.h ] || ln -s "$inc" libdecor.h
