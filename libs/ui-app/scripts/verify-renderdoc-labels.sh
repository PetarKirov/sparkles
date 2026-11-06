#!/usr/bin/env bash
# The native arm's GPU scopes as debug labels in a RenderDoc capture
# (docs/specs/profiling/SPEC.md, PRF12), with no desktop session: text-lab on
# headless Weston (lavapipe) under `renderdoccmd capture`, frame 20 captured
# through `--debug renderdoc-capture=20`, the capture converted to XML and its
# labels counted. RenderDoc comes from the flake's nixpkgs.
# Run from the repository root inside the dev shell.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d /tmp/rd.XXXX)"
chmod 700 "$work"
trap 'if [ -n "${weston:-}" ]; then kill "$weston" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json}"
unset WAYLAND_DISPLAY DISPLAY

echo ">> RenderDoc and text-lab ..."
rd="$(nix build --no-link --print-out-paths --inputs-from "$repo" nixpkgs#renderdoc)"
dub build -q --root="$repo" :text-lab
lab="$repo/apps/text-lab/build/text-lab"

XDG_RUNTIME_DIR="$work" weston --backend=headless --socket=rd --idle-time=0 \
  --log="$work/weston.log" &
weston=$!
for _ in $(seq 1 100); do [ -S "$work/rd" ] && break; sleep 0.05; done

echo ">> capturing frame 20 ..."
# The loader finds RenderDoc's layer only on its implicit-layer path.
XDG_RUNTIME_DIR="$work" WAYLAND_DISPLAY=rd \
  VK_ADD_IMPLICIT_LAYER_PATH="$rd/share/vulkan/implicit_layer.d" \
  timeout 180 "$rd/bin/renderdoccmd" capture -w -c "$work/cap" "$lab" \
  --window-system wayland --debug frames=40,renderdoc-capture=20 >"$work/run.log" 2>&1
grep 'native window renderdoc: 1 captures' "$work/run.log"
"$rd/bin/renderdoccmd" convert -f "$work/cap_frame20.rdc" -o "$work/cap.xml" -c xml >/dev/null
grep -q '>frame<' "$work/cap.xml"
grep -q '>canvas<' "$work/cap.xml"
echo ">> the capture carries the frame's GPU scopes as debug labels."
