#!/usr/bin/env bash
# F16 test driver — NOT part of the CI contract (CI only builds and runs the
# demo binary, whose default `dnd` mode self-drives the full XDND protocol —
# both sides, two in-process connections — and exits 0). This driver adds the
# passes that need a real second client: xclip as clipboard requestor (COPY,
# including INCR sending), as clipboard thief (SelectionClear), and as
# clipboard owner (PASTE, including INCR receiving). Run it from the repo dev
# shell (`nix develop`, for dub/xvfb-run); xclip comes via `nix shell`.
#
#     ./run.sh        # build, then run all five passes, each in its own Xvfb
#
# Passes (see ../../f16-clipboard-dnd.md for the findings they produce):
#   dnd         self-contained XDND source+target negotiation (the CI default)
#   copy        demo owns CLIPBOARD+PRIMARY with 'é漢🎈'; xclip -o reads both;
#               `xclip -i` then steals ownership -> demo logs SelectionClear
#   copy-incr   demo owns a 400 KiB payload; xclip -o pulls it -> the demo
#               *sends* INCR (property-delete-driven chunk loop)
#   paste       xclip -i owns 'é漢🎈'; demo requests TARGETS then UTF8_STRING
#   paste-incr  xclip -i owns 2 MiB; the demo *receives* INCR (xclip chunks
#               anything above XExtendedMaxRequestSize/4 bytes)
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
demo="$dir/build/f16_clipboard_dnd_x11"

if [[ -z "${WSI_F16_PASS:-}" ]]; then
    dub build --root="$dir"
    exec nix shell nixpkgs#xclip --command bash -c "
        set -euo pipefail
        for pass in dnd copy copy-incr paste paste-incr; do
            echo \"=== pass \$pass ===\"
            WSI_F16_PASS=\$pass xvfb-run -a '$0'
        done
    "
fi

case "$WSI_F16_PASS" in
dnd)
    WSI_AUTO_EXIT=1 "$demo" --mode=dnd
    ;;
copy)
    "$demo" --mode=copy &
    pid=$!
    sleep 1
    got=$(xclip -selection clipboard -o)
    [[ "$got" == 'é漢🎈' ]] && echo "xclip CLIPBOARD ok: $got"
    gotp=$(xclip -selection primary -o)
    [[ "$gotp" == 'é漢🎈' ]] && echo "xclip PRIMARY ok: $gotp"
    xclip -selection clipboard -o -t TARGETS | tr '\n' ' ' && echo "<- TARGETS"
    printf 'thief' | xclip -selection clipboard -i # steal -> SelectionClear
    wait "$pid"
    ;;
copy-incr)
    "$demo" --mode=copy-incr &
    pid=$!
    sleep 1
    xclip -selection clipboard -o > /tmp/wsi-f16-incr-out.txt
    echo "xclip received $(wc -c < /tmp/wsi-f16-incr-out.txt) bytes:" \
        "$(head -c 16 /tmp/wsi-f16-incr-out.txt)..."
    wait "$pid"
    ;;
paste)
    printf 'é漢🎈' | xclip -selection clipboard -i
    sleep 0.5
    "$demo" --mode=paste
    ;;
paste-incr)
    awk 'BEGIN { for (i = 0; i < 32768; i++) printf "%063d\n", i }' \
        > /tmp/wsi-f16-big.txt # 2 MiB
    xclip -selection clipboard -i /tmp/wsi-f16-big.txt
    sleep 0.5
    "$demo" --mode=paste
    ;;
esac
