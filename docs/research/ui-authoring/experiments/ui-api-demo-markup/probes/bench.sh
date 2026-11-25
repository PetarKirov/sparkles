#!/usr/bin/env bash
# Times the app's own compile step (deps prebuilt) for the original demo and
# this one, on DMD and LDC: wall seconds and peak RSS, best of N.
X=$(cd "$(dirname "$0")/../.." && pwd) # the experiments directory
S=$(git -C "$X" rev-parse --show-toplevel)/libs
INC="-I. -I$S/base/src -I$S/metadata/src -I$S/reflection/src -I$S/test-attributes/src"
N=${N:-5}
OUT=$(mktemp -d)
run() { # dir compiler mode files...
    local dir=$1 c=$2 mode=$3; shift 3
    local dbg=-debug; [ "$c" = ldc2 ] && dbg=-d-debug
    local obj="-c -of=$OUT/x.o"; [ "$mode" = frontend ] && obj=-o-
    local best=999 mem=0
    for i in $(seq $N); do
        r=$(cd $dir && command time -f "%e %M" $c $dbg -g -w $INC -preview=in -preview=dip1000 $obj "$@" 2>&1 >/dev/null | tail -1)
        t=${r% *}; m=${r#* }
        if awk "BEGIN{exit !($t < $best)}"; then best=$t; mem=$m; fi
    done
    printf "%-10s %-5s %-9s %6.2fs %7d KiB\n" "$(basename $dir)" $c $mode $best $mem
}
for c in dmd ldc2; do
  for mode in frontend full; do
    run "$X/ui-api-demo" $c $mode app.d ui_sketch.d
    run "$X/ui-api-demo-markup" $c $mode app.d ui_sketch.d markup.d
  done
done
