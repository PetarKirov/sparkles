#!/usr/bin/env bash
# usage: dc.sh <compiler> files...   (type-check only, against sparkles:base sources)
S=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/libs
c=$1; shift
$c -preview=in -preview=dip1000 -o- -I. -I$S/base/src -I$S/test-attributes/src -I$S/metadata/src -I$S/reflection/src "$@"
