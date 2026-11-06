# Run the native arm on macOS

On macOS the native arm — `sparkles:wsi`'s AppKit backend, drawn by
`sparkles:ui-vulkan` — runs through [MoltenVK], Vulkan's portability layer
over Metal. This page is how to build, run and check it, and what MoltenVK
does differently from a Linux driver.

## Build and run

Enter the dev shell (`nix develop`, or `direnv`): it puts the Vulkan loader
and MoltenVK on the path and points `VK_DRIVER_FILES` at MoltenVK's driver
manifest. A plain build is the native arm, on macOS as everywhere:

```bash
dub build :text-lab && apps/text-lab/build/text-lab
dub build :hue && apps/hue/build/hue --gui README.md
dub build :terminal && apps/terminal/build/sparkles_terminal
dub build :ui-gallery && apps/ui-gallery/build/ui-gallery --gui
```

`-c raylib` names the raylib window instead. The Nix packages (`nix
build .#hue`, `.#terminal`, `.#ui-gallery`, `.#text-lab`) are the native arm
too (`.#hue-raylib` and its siblings the raylib window), and need no dev
shell: the Vulkan loader nixpkgs builds already searches MoltenVK's driver
directory.

::: tip Re-enter the shell after a MoltenVK change
The overlay builds MoltenVK against the SPIRV-Cross revision MoltenVK pins.
A stock MoltenVK prints `[MVK-BUILD-ERROR] Cereal serialization … is not
completely defined` on every instance; if you see it, your shell still
points at an older driver.
:::

## Check it on a window

```bash
nix develop -c libs/vulkan-wsi/scripts/verify-appkit-vulkan-macos.sh
```

runs the AppKit surface conformance probe (window → `CAMetalLayer` →
`VK_EXT_metal_surface` → a device that presents), then a triangle through 300
frames of resize stress, and fails on a MoltenVK built against the wrong
SPIRV-Cross. Every native-arm application takes the same diagnostics:

| Switch                   | What it does                                                 |
| ------------------------ | ------------------------------------------------------------ |
| `--debug frames=N`       | presents N frames, prints the frame statistics, and exits    |
| `--debug shot=PATH`      | writes the last of those frames to a PNG, from the swapchain |
| `--debug resize-stress`  | zooms and restores the window every 30 frames                |
| `--debug log-events`     | logs every window-system event, with counts at the end       |
| `--window-system appkit` | names the backend (`auto` picks it on macOS)                 |

`--debug shot` needs no Screen Recording permission and works while the
session is locked; `screencapture` needs both. Wrap long runs in
`caffeinate -dimsu` so the display does not sleep or lock under them: a
locked session still presents every frame, but shows none of them and gives
no application the focus.

## What MoltenVK does differently

- **Present modes.** The surface offers `FIFO` and `IMMEDIATE`, not
  `MAILBOX`; `auto` takes `FIFO`, and asking for `mailbox` is refused.
- **`IMMEDIATE` in a window is still paced by the display.** MoltenVK turns
  the layer's display sync off for it, but the WindowServer composites a
  windowed `CAMetalLayer` at the display's refresh and `nextDrawable` waits
  for one of its three drawables to come back, so both modes run at the
  refresh rate (about 115 fps on a 120 Hz panel).
- **Frame pacing** comes from the view's `CADisplayLink` (macOS 14 and
  later): `requestFrame` answers at the next refresh, as Wayland's frame
  callback does, and an idle window draws nothing.
- **GPU timestamps calibrate** through `VK_EXT_calibrated_timestamps`, whose
  `CLOCK_MONOTONIC_RAW` sample is `mach_continuous_time` — which counts sleep,
  where `MonoTime` does not. The profiler subtracts the difference.
- **Focus is cooperative.** Since macOS 14 a process launched from a shell
  comes to the front only if the active application yields; a test that
  needs the focus must account for it. A full-screen request from an
  application that is not active is ignored.
- **Colour emoji** come from Apple Color Emoji, a 190 MB collection the arm
  maps read-only rather than reads.

[MoltenVK]: https://github.com/KhronosGroup/MoltenVK/tree/db66022459ffb663aa2b50f6b018bc2e124f5edf
