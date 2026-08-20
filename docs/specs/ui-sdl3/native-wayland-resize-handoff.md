# Handoff: drop SDL, native Wayland live-resize

> [!IMPORTANT]
> **Superseded as an implementation plan by the
> [`sparkles:wsi` specification](../window-system-integration/SPEC.md) and
> [delivery plan](../window-system-integration/PLAN.md).** The measurements,
> vetoed workarounds, and immediate-ack requirement below remain primary evidence.
> Native Wayland is now one vertical slice of a four-backend WSI library integrated
> with Event Horizon; SDL remains an explicitly named compatibility backend rather
> than being deleted globally.

**Status:** the `sparkles:wsi` native Wayland lifecycle and Event Horizon
prepare-read seam are implemented and pass under headless Weston. The Vulkan triangle
renderer consumer and Mutter live-resize measurement are still pending; keep the SDL
triangle until those gates pass.
**Date:** 2026-08-20.
**Branch:** `feat/ui-sdl3-input`. The measured X11-good loop (`32c323f71`) and the Darwin `events.d` fix (`1faff458a`) are **committed** — see [§3 Working tree](#3-working-tree).
**This document is for the next agent.** Read [§0](#0-read-this-first) then [§1](#1-mission). Do not re-run the SDL/libdecor experiments in [§5](#5-chronology--every-step-we-took).

---

## 0. Read this first

You are continuing a measured investigation, not starting a green-field windowing library.

1. The original brief was **live window resize** of `libs/ui-sdl3/examples/vulkan-triangle.d`.
2. We made the **Vulkan** side fast. The remaining 100–1000 ms spikes on GNOME/Mutter are **SDL 3.4.12 + libdecor 0.2.5**, not RADV.
3. `vkcube` on the **same** machine is smooth because it owns `xdg_surface` and **acks configure immediately**.
4. The owner’s decision: **drop SDL on this path** (to avoid libdecor) and write a **native Wayland** triangle.
5. Live triangle tracking **beats** prettier create counts. Slack, debounce, and pad-to-display were tried and **vetoed**.
6. **Do not delete** the SDL triangle until the native one is CI-green and HITL-verified on Mutter.
7. The Darwin `events.d` `size_t` fix is already on the branch (`1faff458a`). It is unrelated to resize; do not fold further WSI work into it.

If a sentence in this file and a sentence in the current source disagree, **trust the source** and update this file. File:line anchors below are from 2026-08-20.

---

## 1. Mission

Replace SDL as the window / WSI host for the triangle with a **native Wayland** client that:

- uses **no SDL** and **no libdecor**;
- acks `xdg_surface.configure` **before returning from the listener** (vkcube, not SDL);
- draws the same triangle through the same `FrameSync` / `Swapchain` / shaders;
- live-resizes on this GNOME/Mutter as well as `vkcube` and as well as `--video-driver x11`;
- still `--help`s cleanly for CI, and prints `SKIP:` + exit 0 if `wl_display_connect` is null.

**Done** means every row in [§8.7 Success criteria](#87-success-criteria-must-measure) is measured on this machine, not that a window opens.

Suggested first deliverable:

```
libs/ui-sdl3/examples/vulkan-triangle-wayland.d
```

One example first. Promote a `sparkles:ui-wayland` library only after the loop is measured. `sparkles:ui-skia` / Graphite is out of scope.

---

## 2. First 30 minutes

Completion criterion: you can rebuild the current SDL triangle, `git status` is clean, and you have not started a native window yet.

1. Confirm branch and that the tree is clean:

   ```bash
   git rev-parse --abbrev-ref HEAD   # expect feat/ui-sdl3-input
   git status                        # expect clean
   git log --oneline origin/feat/ui-sdl3-input..HEAD
   ```

2. The X11-good loop is already committed (`32c323f71`). Do not rewind it. Start native work from a clean tree (see [§3](#3-working-tree)).

3. Build and glance at `--help` so the CLI contract is in your head:

   ```bash
   cd libs/ui-sdl3/examples
   dub build --single vulkan-triangle.d -b debug
   ./build/vulkan_triangle --help
   ```

4. Read, in this order (do not skip the research):

   | Doc                                                                                                        | Why                                      |
   | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
   | This file                                                                                                  | Mission, vetoes, plan                    |
   | [`os-apis/wayland`](../../research/window-system-integration/os-apis/wayland/index.md)                     | Handshake, loop, no-buffer-no-window     |
   | [`os-apis/wayland/example/`](../../research/window-system-integration/os-apis/wayland/example/)            | ImportC pattern already in-repo          |
   | [`importc-c-libraries.md`](../../guidelines/importc-c-libraries.md)                                        | pkg-config, `sourceLibrary` gotcha       |
   | [`recommendations.md`](../../research/window-system-integration/recommendations.md) §2.1 + decorations row | Own the window; **no libdecor hard dep** |
   | [`sdl3.md`](../../research/window-system-integration/sdl3.md)                                              | Why SDL’s pump looks the way it does     |
   | [`smithay-libdecor.md`](../../research/window-system-integration/smithay-libdecor.md)                      | Why we will not take libdecor            |
   | `libs/ui-sdl3/examples/vulkan-triangle.d` `draw` / `rebuild` / `presentOnce`                               | GPU policy to port                       |
   | `libs/ui-sdl3/src/sparkles/ui_sdl3/{swapchain,frame,vulkan_context}.d`                                     | Reuse vs rewrite                         |

5. Existence proof on this desktop (optional, 30 s):

   ```bash
   vkcube    # must print “Selected WSI platform: wayland”
   ```

---

## 3. Working tree

**Clean as of 2026-08-20.** Nothing left uncommitted from the SDL resize session.

**On the branch** (`feat/ui-sdl3-input`):

| SHA         | Subject                                                                            |
| ----------- | ---------------------------------------------------------------------------------- |
| `fcdd49745` | `feat(ui-sdl3): retire swapchain and present semaphores instead of idling`         |
| `bf9f3ae3c` | `feat(ui-sdl3/examples): rebuild the triangle swapchain without idling`            |
| `904eece94` | `feat(vulkan.dispatch): load optional dynamic-rendering commands`                  |
| `e6d0d7bbe` | `feat(ui-sdl3): grow-only swapchains, dynamic rendering, idle before teardown`     |
| `13afb9c2c` | `feat(ui-sdl3/examples): dynamic-render the triangle and skip shrink rebuilds`     |
| `68b615b68` | `fix(ui-sdl3/examples): release color-attachment read after the acquire barrier`   |
| `c8f178744` | `feat(ui-sdl3): add --present-mode for the triangle swapchain`                     |
| `b24020abe` | `feat(core-cli.args): parse enums through sparkles:wired wire names`               |
| `326f2016d` | `feat(ui-sdl3/examples): spell present mode as a wired enum`                       |
| `83ed01c7f` | `docs(specs/ui-sdl3): hand off native Wayland live-resize`                         |
| `32c323f71` | `feat(ui-sdl3): grow-only live resize with amortized reap` — **the X11-good loop** |
| `1faff458a` | `fix(ui-sdl3.events): disambiguate size_t on Darwin` — unrelated; already landed   |

`32c323f71` is what used to sit uncommitted: `--trace-ms`, `--decor`, `--video-driver`, pump+peep, mailbox 2 ms pace, live-resize watch, grow-only + `drawableExtent`, ASCII title, `Swapchain.recreate(..., growOnly=false)`, `reap(vk, limit)` on both `Swapchain` and `FrameSync`.

Keep `--trace-ms` / `RunReport` until the native example has the **same columns**. That is how we will compare X11 vs native Wayland in one glance.

---

## 4. Machine, stack, how to run

Recorded 2026-08-19 on the developer’s desktop:

| Item         | Value                                                                                                    |
| ------------ | -------------------------------------------------------------------------------------------------------- |
| Session      | GNOME, `XDG_SESSION_TYPE=wayland`, `WAYLAND_DISPLAY=wayland-0`, `DISPLAY=:0`                             |
| GPU / driver | AMD Radeon RX Vega, **RADV VEGA10**                                                                      |
| SDL          | 3.4.12 (`sdl3` + `sdl3.dev` in the nix shell)                                                            |
| libdecor     | 0.2.5, plugins `libdecor-gtk.so` (wins by priority) and `libdecor-cairo.so`                              |
| Vulkan       | triangle requests `apiVersion13`; dynamic rendering is core                                              |
| Present      | mailbox offered; FIFO 16–17 ms; **IMMEDIATE not offered** on this RADV/Wayland                           |
| Surface      | Wayland `currentExtent = 0xFFFFFFFF` (`surfaceExtent: "app-defined"`); X11 `currentExtent` = window size |

### 4.1 Current SDL triangle

From repo root (toolchain on `PATH` via `nix develop` / direnv):

```bash
cd libs/ui-sdl3/examples
dub build --single vulkan-triangle.d -b debug

# Best SDL result (XWayland) — the acceptance bar
./build/vulkan_triangle --frames 0 --present-mode mailbox --trace-ms 20 --no-color --video-driver x11

# Native Wayland via SDL — expect 100–1000 ms pump stalls. Do not “fix” this.
./build/vulkan_triangle --frames 0 --present-mode mailbox --trace-ms 20 --no-color --video-driver wayland

# Headless CI-style (must unset Wayland or SDL opens the real session)
# Xvfb :80 -screen 0 1024x768x24 &
# env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 DISPLAY=:80 ./build/vulkan_triangle --frames 0
```

| Flag                                                          | Meaning                                                                                    |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `--frames 0`                                                  | Run until close. Default is 120 (too short to drag).                                       |
| `--present-mode mailbox\|fifo\|fifo-relaxed\|immediate\|auto` | Wired enum; values = `VkPresentModeKHR`. `auto` = mailbox if offered.                      |
| `--trace-ms N`                                                | Log any frame whose wall time is ≥ N ms, then a `RunReport` on close.                      |
| `--video-driver x11\|wayland\|auto`                           | Sets `SDL_VIDEODRIVER` **before** `SDL_Init`.                                              |
| `--decor none\|cairo\|auto`                                   | libdecor policy. Default is `none`. Irrelevant once SDL is gone.                           |
| `--resize-stress`                                             | `SDL_SetWindowSize` grow+shrink band. **Does not reproduce** the 100–1000 ms Mutter stall. |
| `--validation`                                                | Khronos layer. **Do not mix with `MANGOHUD=1`.**                                           |
| `--no-color`                                                  | For pasting `RunReport`.                                                                   |

`--trace-ms` columns (keep these names in the native app):

```
trace frame=… …ms win=WxH sc=WxH events=N [kinds] sizeEvents=…
rebuilt=… watch=… poll=… pump=… peep=… waitFrame=…
acq=RESULT/…ms pres=RESULT/…ms waitAll=… create=… reap=…
```

`RunReport` also has `framesOver50ms`, `framesOver100ms`, `swapchainsBuilt`, `reaps`, `watchPresents`, `pixelSizeEvents`, `surfaceExtent`, `videoDriver`, `rendering`.

### 4.2 MangoHud

```bash
MANGOHUD=1 ./build/vulkan_triangle --frames 0 --present-mode mailbox
```

Not `mangoapp`. HUD-only is fine for frametimes.

**Do not** combine `MANGOHUD=1` with `--validation`. MangoHud 0.8.2 injects a `BeginRenderPass(LOAD)` after a barrier that only releases `COLOR_ATTACHMENT_WRITE`. That is [flightlessmango/MangoHud#1214](https://github.com/flightlessmango/MangoHud/issues/1214), not our app. We added `COLOR_ATTACHMENT_READ` to **our** acquire barrier (`68b615b68`); it did **not** stop the overlay warning. Short HUD+validation runs also hit `free(): chunks in smallbin corrupted`.

### 4.3 vkcube (existence proof)

```bash
vkcube   # “Selected WSI platform: wayland”
```

Installed here as `/nix/store/…-vulkan-tools-1.4.328.0/bin/vkcube`.

Source of truth: [KhronosGroup/Vulkan-Tools `cube/cube.c`](https://github.com/KhronosGroup/Vulkan-Tools/blob/697e22d5d256b29e4d6cdd75b3cd42f1aa634113/cube/cube.c)

- `demo_run` Wayland loop ~L3034
- `handle_surface_configure` ~L3064

---

## 5. Chronology — every step we took

Read this so you do not repeat it. Each subsection is a closed experiment.

### 5.0 Original brief and the 10-point policy

User:

> Make `libs/ui-sdl3/examples/vulkan-triangle.d` window resize as performant as possible.

We proposed, and the owner accepted **yes to all of**:

1. Skip a rebuild when the new size is 0 or unchanged.
2. Reuse render pass + pipeline (viewport/scissor are dynamic; format does not change).
3. Pause drawing on 0×0 (minimised); keep the old swapchain.
4. Mailbox default; FIFO is the spec-guaranteed fallback.
5. Coalesce `PIXEL_SIZE_CHANGED` to one flag per pump; only the last SDL size matters.
6. Early-out same size.
7. Defer framebuffer recreation (dynamic rendering later dropped FBs entirely).
8. Dynamic rendering when the API allows (1.3 core / 1.2+KHR).
9. Grow-only / display-padded swapchain + viewport / compositor scale.
10. `vkQueueWaitIdle` only when destroying present-waited objects (`FrameSync` / old swapchain), never `vkDeviceWaitIdle` on the resize hot path.

That policy is still the GPU contract. Item 9 was later **narrowed**: pad-to-display is legal on Wayland (`currentExtent == 0xFFFFFFFF`) but **wrong on this Mutter** (it scales the whole buffer → stamp). On X11 pad is **illegal** (`currentExtent` is the window). v1 native Wayland should **match the configured size**, like vkcube.

### 5.1 Pre-session GPU work (already committed)

Goal: live resize without `vkDeviceWaitIdle`.

| What                                                               | Why                                                      | Trap we hit                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------ | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Retire old swapchain / `renderFinished`; destroy in `reap`         | Present may still scan the old images                    | Immediate destroy → `VUID-vkDestroySwapchainKHR-swapchain-01282` under `--resize-stress`                                                                                                                                                                                                                                                     |
| `FrameSync.waitAll` (in-flight fences) instead of `deviceWaitIdle` | Idle waits for the presentation engine (a vsync on FIFO) | `const previous` / `const action` failed dip1000/`Expected` — use `auto`                                                                                                                                                                                                                                                                     |
| Reuse pass + pipeline                                              | Format and layout do not change with the window          | —                                                                                                                                                                                                                                                                                                                                            |
| Dynamic rendering                                                  | Resize only rebuilds image views                         | Enabling `VK_KHR_dynamic_rendering` on API 1.1 failed `ppEnabledExtensionNames-01387`. Triangle requests `apiVersion13`. First barrier used `TOP_OF_PIPE` → `SYNC-HAZARD-WRITE-AFTER-READ`; srcStage must be `COLOR_ATTACHMENT_OUTPUT` to match the acquire wait. `beginRendering(in VkRenderingInfo)` failed ImportC non-const — use `ref`. |
| Grow-only / `minAlloc` pad                                         | Shrink without create                                    | First create stayed exact so `--frames N` at 960×540 still reported that. Pad later caused the stamp (see 5.4).                                                                                                                                                                                                                              |
| `decideResize` + `Swapchain.recreate`                              | Skip format/mode re-query; `oldSwapchain`                | First-time `out` create wiped `_retired`; `create` became `ref`. `cast(VkFence) 1` is not `@safe`.                                                                                                                                                                                                                                           |
| `--resize-stress`                                                  | Exercise rebuild                                         | After grow-only, the original 480–872 band never exceeded 960×540 → 40 frames / 1 swapchain. Later changed to grow **and** shrink past 960×540.                                                                                                                                                                                              |
| `--present-mode` + wired `PresentMode`                             | Measure mailbox vs FIFO                                  | Manual enum↔string replaced with `sparkles:wired` `@WireCase` like `vulkaninfo.d`. core-cli now parses every enum through `wireNames`. `--present-mode immediate` correctly errors on this RADV/Wayland. First PresentMode commit failed the end-of-file-fixer hook.                                                                         |

MangoHud path: see [§4.2](#42-mangohud). Adding `COLOR_ATTACHMENT_READ` did not fix their overlay.

### 5.2 User report that opened the HITL loop

> Mailbox &lt;1 ms steady, FIFO 16–17 ms, slow resize 5–30 ms, **fast drag 100–1000 ms**.

We instrumented rather than guessing. `--trace-ms` splits `poll` into `pump` / `peep` and records `waitFrame`, `acq`, `pres`, `waitAll`, `create`, `reap`.

**Programmatic `--resize-stress` on Wayland did not reproduce 100–1000 ms.** Max ~20 ms = one display-pad `vkCreateSwapchainKHR`. Zero `SUBOPTIMAL` / `OUT_OF_DATE`. The bug is **interactive Mutter configure**, not `SDL_SetWindowSize`.

### 5.3 HITL on native SDL Wayland

Representative mailbox traces (GNOME, no HUD):

| Setup                                                                     | Feel                                                      | Where the time went                                                                                                                                                                                               | Verdict                                                             |
| ------------------------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Tight `while (SDL_PollEvent)` + uncapped mailbox (~12 kHz)                | Unusable                                                  | 200–2600 ms in `poll`. `maxPixelSizeEvents=1` hid a **motion flood**. Each `PollEvent` calls `PumpEvents`; each pump can wait **4 ms** on `wl_display.flush` EAGAIN (`Wayland_PumpEvents` in SDL 3.4.12). N×4 ms. | Amplifier. Fixed with peep + 2 ms mailbox floor.                    |
| Pump once + `SDL_PeepEvents` + 2 ms mailbox floor                         | Flood gone; still 300–1200 ms                             | **100% `SDL_PumpEvents`**, 4 events `[resized, pixel, other, exposed]`. Vulkan create/present were &lt;1 ms.                                                                                                      | Remaining stall is SDL/compositor, not GPU.                         |
| libdecor **GTK** (default plugin)                                         | up to 1.2 s                                               | `libdecor-gtk` imports `g_main_context_iteration` and `wl_display_roundtrip`.                                                                                                                                     | Amplifier.                                                          |
| libdecor **cairo** (`--decor cairo`)                                      | ~500 ms typical                                           | Still `wl_display_roundtrip` in the cairo plugin.                                                                                                                                                                 | Better than GTK, not good.                                          |
| `--decor none` (`SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0`)                     | still 400–1280 ms                                         | Without a buffer, Mutter waits on configure. GNOME can also force CSD and SDL reloads libdecor anyway.                                                                                                            | `decor: "none"` is **our flag**, not proof SDL stayed off libdecor. |
| Present from `SDL_AddEventWatch` on `PIXEL_SIZE_CHANGED` (create allowed) | Subjectively smooth, “dragging behind”; metrics **worse** | Nested Wayland + **swapchain create in the watch** (one create 1781 ms, `rebuilt=true`). `watchPresents=7671` vs `pixelSizeEvents=798` = configure **feedback loop**.                                             | Never create in a configure/watch callback.                         |
| Cheap watch (timeout 0, no rebuild) + pad-to-display                      | Smooth, still behind; then **stamp**                      | Pad 2560×1440, viewport = window. This Mutter **scales** the whole buffer → triangle in a top-left navy rectangle.                                                                                                | Pad-to-display is wrong here.                                       |
| Viewport = swapchain + pad                                                | “Clip” on shrink                                          | Opposite assumption. A padded 16:9 buffer in a non-16:9 window looks cropped/letterboxed because Mutter scales, it does not crop.                                                                                 | —                                                                   |
| Exact window-sized swapchain                                              | Visuals correct                                           | Shrink and grow both recreate (or grow-only + window viewport — see X11).                                                                                                                                         | Visuals first.                                                      |

**Title bug:** `"sparkles — vulkan triangle"` (em dash U+2014) rendered as `sparkles ã vulkan triangle`. GNOME’s title bar treated UTF-8 as Latin-1. Fixed to ASCII hyphen: `"sparkles - vulkan triangle"`. Keep ASCII in `xdg_toplevel.set_title` until you prove UTF-8.

**Hard fact:** on this Mutter, `SDL_PumpEvents` is allowed to block for a compositor timeout (~1 s) while a configure is unacked **or** acked without a matching buffer. vkcube never enters that state.

### 5.4 Why SDL cannot be fixed from outside

SDL 3.4.12, `src/video/wayland/SDL_waylandwindow.c`, `handle_xdg_surface_configure` (paraphrased from the tree we read):

```c
/* Interactive resizes are throttled by acking … at the next frame callback */
if (!wind->resizing) {
    ConfigureWindowGeometry(window);
    xdg_surface_ack_configure(xdg, serial);
} else if (!wind->pending_config_ack) {
    wind->pending_config_ack = true;
    SDL_SendWindowEvent(..., SDL_EVENT_WINDOW_EXPOSED, ...);
}
/* actual ack is in surface_frame_done */
```

Vulkan WSI’s `wl_surface.frame` **replaces** SDL’s callback (only one pending frame callback per surface). SDL never acks → Mutter waits → 100–1000 ms.

On libdecor 0.2.5, `LIBDECOR_WINDOW_STATE_RESIZING` does not exist (`#if SDL_LIBDECOR_CHECK_VERSION(0, 3, 0)`), so `resizing` stays false and **every** configure does `ConfigureWindowGeometry` + `libdecor_frame_commit` → `wl_display_roundtrip` **after** posting `PIXEL_SIZE_CHANGED` and **before** the app can present. Nested present-from-watch was an attempt to feed Mutter a buffer before that roundtrip; it made a configure storm.

`Wayland_PumpEvents` (SDL 3.4.12) can wait ~4 ms on `EAGAIN` from `wl_display_flush`. Hints we used:

- `SDL_HINT_VIDEO_WAYLAND_ALLOW_LIBDECOR` / env `SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR`
- `SDL_HINT_VIDEO_WAYLAND_PREFER_LIBDECOR`
- cairo-only plugin dir via `LIBDECOR_PLUGIN_DIR` + a `/tmp` symlink (see `forceLibdecorCairo` in the triangle)

**You cannot fix this from outside SDL without owning `xdg_surface`.** That is why we drop SDL.

vkcube does the opposite ([`handle_surface_configure`](https://github.com/KhronosGroup/Vulkan-Tools/blob/697e22d5d256b29e4d6cdd75b3cd42f1aa634113/cube/cube.c) ~L3064):

```c
xdg_surface_ack_configure(xdg_surface, serial);   // immediately
demo->xdg_surface_has_been_configured = 1;
/* apply pending_width / pending_height from xdg_toplevel.configure */
demo_resize(demo);                                // recreate swapchain here
```

Its loop ([`demo_run`](https://github.com/KhronosGroup/Vulkan-Tools/blob/697e22d5d256b29e4d6cdd75b3cd42f1aa634113/cube/cube.c) ~L3034):

```c
wl_display_flush(demo->wayland_display);
while (wl_display_prepare_read(...) != 0)
    wl_display_dispatch_pending(...);
wl_display_read_events(...);
wl_display_dispatch_pending(...);
if (initialized && swapchain_ready)
    demo_draw(demo);
```

`xdg_toplevel.configure` only stores `pending_width` / `pending_height`. Zero size means “client chooses”.

No libdecor. No “wait for `wl_surface.frame` before ack”. Mesa WSI still calls `wl_surface.frame` on present; that is fine because **ack already happened**.

vkcube uses `vkDeviceWaitIdle` on resize. **Do not copy that.** Use `FrameSync.waitAll`.

### 5.5 X11 / XWayland (`--video-driver x11`) — the acceptance bar

This is the **best SDL result** and what native Wayland must match.

X11 `currentExtent` **is** the window. You **cannot** create a swapchain larger than the current window (spec: `imageExtent` must match `currentExtent` unless it is `0xFFFFFFFF`). Grow-only pad is illegal. Present is **1:1 and clips** (does not scale). So:

- **Shrink:** keep the large images, set viewport / scissor / `renderArea` to the **window pixel size** (`drawableExtent`). X11 shows the top-left. Triangle tracks, no create.
- **Grow:** must `vkCreateSwapchainKHR` at the new `currentExtent` or the triangle stays small in a larger window.

| Policy                                                                              | `swapchainsBuilt` | Feel                                    | Notes                                                                         |
| ----------------------------------------------------------------------------------- | ----------------- | --------------------------------------- | ----------------------------------------------------------------------------- |
| Recreate every pixel                                                                | ~800–1000         | Live, hiccups                           | `maxCreateMs` ~25–110 ms at 2K–5K; `queueWaitIdle` after every rebuild ~32 ms |
| Recreate every pixel, reap only after 100 ms quiet                                  | ~1000             | Live, still hiccups on large grow       | `reaps: 8` then **one** `queueWaitIdle` of **308 ms** destroying the pile     |
| Debounce create 50 ms, present `SUBOPTIMAL` meanwhile                               | ~11               | **Smooth but triangle does not follow** | X11 does not scale the old buffer. Owner: live tracking is a **must-have**.   |
| Grow immediately, shrink viewport-only, amortized reap (no idle, 1 swapchain/frame) | ~200–335          | **“Much better”**                       | `framesOver50ms=0` except dual-monitor; `maxCreateMs` ~25 ms                  |
| + 16 ms min gap between grows                                                       | ~322              | Still 20–30 ms on grow                  | Grow events are already &gt;16 ms apart; throttle never fired                 |
| + 64 px grow slack                                                                  | 92                | **“Feels worse”**                       | Stats prettier, triangle late by up to 64 px. **Reverted.**                   |

**Settled X11 algorithm** (`32c323f71`, current `vulkan-triangle.d`):

1. `SDL_PumpEvents` once, then `SDL_PeepEvents` (do **not** `PollEvent` in a loop).
2. Optional watch present on `PIXEL_SIZE` / `EXPOSED` — **non-blocking** (`waitForFences` / acquire timeout 0), **never rebuild** in the watch.
3. `rebuild()` if window **exceeds** swapchain (grow). Shrink → no-op.
4. `presentOnce`: record with `drawableExtent(sc, windowPx)` = window size clamped to swapchain.
5. Mailbox: 2 ms floor when **not** resizing (stops the 12 kHz Wayland-socket flood). No sleep on a resize tick.
6. After **100 ms** with no size event: `sync.reap(vk, 8)` + `sc.reap(vk, 1)` — **no** `queueWaitIdle`.

Best measured X11 session (grow-only + live viewport, after reap amortize):

```
framesPresented:     35967
swapchainsBuilt:       335     # grows only
reaps:                   7     # then 216 once we reaped 1:1 with builds
framesOver50ms:          1     # later 0
maxFrameMs:           72.4     # reap of 5120×1397; later maxReapMs 0.99
maxCreateMs:          24.8
maxPresentMs:          0.4
```

Dual-monitor (~4800–5100 × 1200) grow still costs **one** ~20–25 ms create. That is the RADV allocation floor. Do not “fix” it by skipping the grow.

The 72 ms line the owner asked about was `queueWaitIdle` on a 5K retired swapchain. Replaced by quiet + `reap(limit)` without idle → `maxReapMs` ~1 ms.

### 5.6 Visual bugs (confirmed fixed on the SDL path)

1. **UTF-8 title** — em dash → `ã`. ASCII hyphen.
2. **Shrink clip** — we kept a large swapchain and drew the full extent; X11 clipped to the window so the triangle looked cropped. Fix: `drawableExtent` = window pixels clamped to swapchain, used for `renderArea` / viewport / scissor.
3. **Stamp** — pad-to-display + window viewport on Wayland: Mutter scaled the 2560×1440 image into the smaller window; the triangle sat in a navy rectangle in the top-left. Fix: do not pad on this compositor. Native v1: match configured size.

The triangle shader is **not** a fullscreen NDC triangle:

```
(0.0, -0.6), (0.6, 0.6), (-0.6, 0.6)
```

Lots of clear-color (`0.05, 0.05, 0.08`) around it is **normal**. Do not “fix” that.

---

## 6. Hypothesis graveyard

Do not spend a week re-testing these.

| Hypothesis                                              | Verdict                                                                                                                                                                       |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `waitAll` / `vkDeviceWaitIdle` is the 100–1000 ms spike | **False** on this Mutter. `waitAll` was 0–10 ms. Idle was removed earlier.                                                                                                    |
| `OUT_OF_DATE` / `SUBOPTIMAL` force-rebuild storm        | **False** on Wayland (0/0). **True-ish** on X11 (thousands of `SUBOPTIMAL` on shrink) but present still works; we do not force-rebuild.                                       |
| Uncapped mailbox + `PollEvent` loop                     | **True amplifier** (N×4 ms flush). Fixed with peep + 2 ms pace. Not the remaining Wayland stall.                                                                              |
| libdecor-gtk `g_main_context_iteration`                 | **True amplifier**. Cairo better, still roundtrips.                                                                                                                           |
| Present-from-watch unblocks Mutter                      | **Subjectively yes**, **metrics no** (nested dispatch + create-in-watch). Cheap watch + exact size is OK on X11; do not put create in a configure callback without measuring. |
| Pad to display + viewport = window                      | **Stamp** if compositor scales; **correct** if it clips. This Mutter/X11 pair: Wayland scales, X11 clips.                                                                     |
| Pad + viewport = swapchain                              | Letterbox / “clip” when aspect ≠ window.                                                                                                                                      |
| 50 ms create debounce                                   | Smooth numbers, **triangle does not follow** on X11. Owner vetoed.                                                                                                            |
| 64 px grow slack                                        | Same veto.                                                                                                                                                                    |
| 16 ms min gap between creates                           | Grow events already &gt;16 ms apart; no effect.                                                                                                                               |
| `queueWaitIdle` after FIF+1                             | 32 ms hitch **during** drag; then 308 ms after a pile. Replaced by quiet + amortized destroy.                                                                                 |
| MangoHud RAW is our barrier                             | **False.** Overlay bug #1214.                                                                                                                                                 |
| `--resize-stress` reproduces interactive stalls         | **False.** Interactive Mutter configure only.                                                                                                                                 |

---

## 7. Current triangle algorithm (reference implementation)

Port the **ideas**. Do not port `SDL_PumpEvents`.

### 7.1 Frame loop (X11-good)

```
while running:
    SDL_PumpEvents()                         # once
    while SDL_PeepEvents(...): handle quit / PIXEL_SIZE
    # watch may have presented already (timeout 0, no rebuild)

    if window > swapchain:                   # grow
        waitAll fences
        Swapchain.recreate(..., growOnly=false)
        rebind views; replaceImages (retire old renderFinished)
    # shrink: skip create

    presentOnce(mayBlock=true):
        waitForFrame
        acquire (SUBOPTIMAL still draws)
        record(..., drawableExtent(sc, windowPx))
        submit; present; advance

    if retired && now - lastSizeChange >= 100ms:
        sync.reap(vk, 8)
        sc.reap(vk, 1)                       # no queueWaitIdle

    if mailbox && !resizing:
        DelayNS so the frame is at least 2ms
```

`drawableExtent` = window pixels clamped to swapchain (0 → full swapchain). Unittest: `vulkan_triangle.drawableExtentClampsToTheSwapchain`.

`decideAcquire` (`frame.d`): `VK_SUBOPTIMAL_KHR` → **proceed + recreate flag**. Abandoning a suboptimal acquire leaves a signalled semaphore and hangs the next acquire. On X11 we currently **do not** force-rebuild on `SUBOPTIMAL` if grow-only already covers.

Fence reset is in `beginFrame`, **not** `waitForFrame`. Resetting early deadlocks if acquire bails.

### 7.2 Library APIs added this session (`32c323f71`)

```d
// swapchain.d / frame.d
void reap(ref VulkanContext vk, uint limit = uint.max);

// swapchain.d — growOnly is no longer implied by the 0xFFFFFFFF sentinel
Swapchain.recreate(..., bool growOnly = false);
```

Teardown (`destroy`) still `queueWaitIdle`s then `reap()` unlimited.

`chooseExtent`: if `caps.currentExtent.width != uint.max`, **return it** (X11). Else clamp window (and optional `minAlloc`) to `[minImageExtent, maxImageExtent]`.

### 7.3 Dynamic-rendering barriers (keep)

Acquire → color:

- `oldLayout` `UNDEFINED` → `COLOR_ATTACHMENT_OPTIMAL`
- `srcAccess` 0, `dstAccess` `COLOR_ATTACHMENT_WRITE | COLOR_ATTACHMENT_READ`
- `srcStage` / `dstStage` `COLOR_ATTACHMENT_OUTPUT`

Color → present:

- `COLOR_ATTACHMENT_OPTIMAL` → `PRESENT_SRC_KHR`
- `srcAccess` `COLOR_ATTACHMENT_WRITE`, `dstAccess` `MEMORY_READ`
- `srcStage` `COLOR_ATTACHMENT_OUTPUT`, `dstStage` `BOTTOM_OF_PIPE`

### 7.4 Shaders

`libs/ui-sdl3/examples/shaders/triangle.vert` + `.frag` (+ `.spv` next to them). Loaded via `stringImportPaths "shaders"`. Three vertices, no buffers: `gl_VertexIndex`.

---

## 8. What to build

### 8.1 Goal (again)

A **second** example (recommended) that opens an `xdg_toplevel` with no SDL and no libdecor, draws the same triangle, and live-resizes on this Mutter.

```
libs/ui-sdl3/examples/vulkan-triangle-wayland.d
```

Keep `// ci: run --help` so `apps/ci` treats it like the other examples.

### 8.2 Protocol objects (minimum)

Follow [os-apis/wayland](../../research/window-system-integration/os-apis/wayland/index.md) and the existing ImportC example.

1. `wl_display_connect(null)` — null → `SKIP:` + exit 0.
2. Registry → bind `wl_compositor`, `xdg_wm_base` (and optionally `zxdg_decoration_manager_v1` for **SSD**).
3. `wl_compositor.create_surface`.
4. `xdg_wm_base.get_xdg_surface` → `xdg_surface.get_toplevel`.
5. `xdg_toplevel.set_title` (ASCII) + `set_app_id` (`sparkles.vulkan-triangle`).
6. **Commit with no buffer** → wait for first `xdg_surface.configure` → **ack immediately** → then create Vulkan surface + swapchain. Attaching a buffer before the first configure is a protocol error.
7. `xdg_wm_base.ping` → `pong` (or the compositor disconnects you).
8. `xdg_toplevel.close` → set a quit flag (cooperative; do not veto in v1).

**GNOME/Mutter does not advertise `zxdg_decoration_manager_v1`.** v1 should ship **undecorated** if SSD is absent. A title bar can wait. **Do not pull libdecor** to “fix” CSD.

### 8.3 ImportC + wayland-scanner

This is the first real codegen+ImportC job in-tree. The research example **stops before `xdg_shell`** on purpose.

**Core protocol (`wayland-client.h`):**

- Shim: `#include <wayland-client.h>` under `#pragma attribute(push, nogc, nothrow)` — copy [`os-apis/wayland/example/c.c`](../../research/window-system-integration/os-apis/wayland/example/c.c).
- `wl_display_get_registry` / `wl_registry_add_listener` are `static inline` and **do not import**. Call `wl_proxy_marshal_flags` / `wl_proxy_add_listener` (the research example already does this).
- `dub.sdl`: `libs "wayland-client"` and **`targetType "sourceLibrary"`** if this becomes a package — see [the `sourceLibrary` gotcha](../../guidelines/importc-c-libraries.md#the-sourcelibrary-gotcha-read-this). A `--single` example can just `libs "wayland-client"`.
- **Never** search `/nix/store` for headers. `pkg-config --cflags wayland-client`.

**`xdg-shell` (and later decoration / fractional-scale):**

- **Must** be generated with `wayland-scanner`. Do not hand-expand every request.
- XML lives in `wayland-protocols` (not in `wayland` itself). The nix **dev shell today has `pkgs.wayland` + `pkgs.wayland.dev` only** (`nix/shells/default.nix` ~L162). You will need to add:

  ```nix
  pkgs.wayland-protocols
  # wayland-scanner is typically in pkgs.wayland; confirm with `which wayland-scanner`
  ```

- Generate **C** (`client-header` + `private-code`), then ImportC the generated `.c` from a shim. Do not parse XML at runtime. Do not check generated C into git if you can generate it at build time; if the example is `dub --single`, a tiny committed generated pair next to the example is acceptable for v1 — prefer a D driver that invokes `wayland-scanner` over a shell script ([AGENTS: substantial scripts in D](../../guidelines/AGENTS.md)).
- Locate the XML with pkg-config, not a store walk:

  ```bash
  pkg-config --variable=pkgdatadir wayland-protocols
  # typically …/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
  ```

**Listeners are `extern (C) nothrow @nogc`.** Store pending size + a flag in the listener; apply on the main loop after `dispatch_pending`. vkcube resizes **in** the configure handler; either is fine if you **ack first**. If a listener must call GC / throwing D, use the same cast-to-`nothrow @nogc` trampoline as `liveResizeWatch` in the current triangle.

### 8.4 Vulkan surface without SDL — load-bearing constraints

`sparkles:vulkan` is deliberately platform-free:

```
// libs/vulkan/src/sparkles/vulkan/vulkan_c.c
// No `VK_USE_PLATFORM_*` is defined: window-system surface creation belongs to
// `sparkles:ui-sdl3`, which obtains it from SDL3 rather than from a platform
// header.
```

There is **no** `VK_KHR_wayland_surface` in `dispatch.d` and **no** `vkCreateWaylandSurfaceKHR` typedef in the imported headers.

`VulkanContext.create` today (`vulkan_context.d`):

1. `SDL_Vulkan_LoadLibrary` + `SDL_Vulkan_GetVkGetInstanceProcAddr`
2. `SDL_Vulkan_GetInstanceExtensions` (on Linux: `VK_KHR_surface` + one of wayland/xlib/xcb)
3. `vkCreateInstance`
4. `SDL_Vulkan_CreateSurface`
5. pick a graphics+present queue, `vkCreateDevice` (`VK_KHR_swapchain` + optional dynamic rendering)

For the native example:

1. Load `vkGetInstanceProcAddr` via **`sparkles.vulkan.loader`** (already exists for non-SDL callers). Do not invent another `dlopen`.
2. Enable instance extensions `VK_KHR_surface` + `VK_KHR_wayland_surface` yourself.
3. Create the surface with `vkCreateWaylandSurfaceKHR`. Get the PFN via `vkGetInstanceProcAddr` after instance creation. You will need the `VkWaylandSurfaceCreateInfoKHR` layout — either:
   - a **second ImportC shim** that `#define VK_USE_PLATFORM_WAYLAND_KHR` and `#include <vulkan/vulkan.h>` (or `vulkan_wayland.h`) in the **example only**, so `sparkles:vulkan` stays platform-free; or
   - hand-write the small create-info struct (sType `VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR` = 1000006000) and the PFN typedef.

   Prefer the example-local shim. Do not add `VK_USE_PLATFORM_*` to `libs/vulkan` in v1.

4. Reuse `VulkanContext` **after** splitting surface creation, **or** duplicate the small create-device sequence in the example for v1. Preferred split (when you touch the library):

   ```
   VulkanContext.createFromSurface(ctx, getProc, instanceExtensions, surface)
   ```

   Keep `create(ctx, Window, …)` as the SDL path.

5. `PixelSize` lives in `window.d` (SDL). `Swapchain` imports it. Either pass width/height as two `int`s, copy the 6-line struct into the example, or lift `PixelSize` into `sparkles:ui-sdl3` in a SDL-free module. Do not make the Wayland example import `window.d` if that pulls SDL init.

6. `Swapchain` / `FrameSync` take `ref VulkanContext`. They do not call SDL. Reuse them as-is once you have a context + surface.

### 8.5 Event loop (copy vkcube, not SDL)

```
while running:
    wl_display_flush(display)
    while (wl_display_prepare_read(display) != 0)
        wl_display_dispatch_pending(display)
    // poll the fd with timeout 0 if you also want a mailbox 2 ms pace
    wl_display_read_events(display)   // or skip if poll said empty
    wl_display_dispatch_pending(display)

    if configured && swapchain ready && window > 0:
        if pendingSize > current swapchain:   # grow
            waitAll; recreate; rebind
        # shrink: drawableExtent only  — or recreate (vkcube); see 8.6
        presentOnce
        maybe reap(limit) after quiet
```

Hard rules:

- **Ack in `xdg_surface.configure` before returning from the listener.**
- **Never** `wl_display_roundtrip` on the hot path (init-only is OK).
- **Never** `wl_display_dispatch` (blocking) on the hot path.
- One `wl_display` default queue. Mesa WSI and the app must both use `dispatch_pending` on the **same thread**.
- Do not `roundtrip` from a listener.
- Prefer: listener stores size + acks; **present stays after dispatch** (vkcube’s split). Measure before you present from a listener.

`xdg_toplevel.configure(width, height, states)`: width/height 0 → keep last / default.

### 8.6 Swapchain policy for native Wayland

On Wayland, `currentExtent` is typically `0xFFFFFFFF` (we measured `surfaceExtent: "app-defined"`). You **may** choose any size in `[minImageExtent, maxImageExtent]`.

**Do not pad to the display** for v1. Match the **configured** size (what `xdg_toplevel.configure` asked for). That is what vkcube does (`demo->width` / `height`). Padding caused the stamp/clip confusion.

Recommended v1:

- Create at the last configured pixel size (logical × scale if you bind `wp_fractional_scale_v1`; v1 can assume scale 1).
- Grow: recreate when configured size exceeds swapchain.
- Shrink: either recreate (simple, like vkcube) **or** keep images + `drawableExtent` (X11 lesson). Recreate-on-shrink is simpler and cheap if you are not creating every pixel (Mutter will not send 12 k configures if you ack+present promptly).
- Mailbox if offered, else FIFO. Keep `--present-mode`.
- `oldSwapchain` + retire + `reap(limit)` — keep the library.
- `waitAll` fences, not `deviceWaitIdle`.

If the triangle is blurry on HiDPI, bind `wp_viewporter` + `wp_fractional_scale_v1` later. Scale arrives as numerator/120. v1 ignore.

### 8.7 Success criteria (must measure)

Interactive, **this** machine, `MANGOHUD` optional, **no** validation. Same `--trace-ms 20` schema.

| Metric                      | SDL Wayland (fail)    | SDL X11 (bar)    | Native Wayland (target) |
| --------------------------- | --------------------- | ---------------- | ----------------------- |
| Fast-drag `pump` / dispatch | 100–3500 ms           | ≤ 20 ms          | **≤ 20 ms**             |
| Triangle tracks window      | hitchy / late         | yes              | **yes** (must-have)     |
| `framesOver100ms`           | many                  | 0                | **0**                   |
| Grow create at ~2K          | n/a (blocked in pump) | ~20–25 ms        | **~20–25 ms OK**        |
| Dual-monitor ~5K create     | n/a                   | ~25 ms           | **~25 ms OK**           |
| Reap hitch                  | mixed                 | ≤ 2 ms amortized | **≤ 2 ms**              |
| vs `vkcube` subjective      | worse                 | comparable       | **comparable**          |

CI: `--help` skip-or-run; no compositor → print `SKIP:` and exit 0 (same as the research Wayland example). Headless Xvfb is **not** required for the Wayland example.

### 8.8 Suggested implementation order

Each step has a completion criterion. Do not start the next step until it is met.

| #   | Step                                                                                                                                    | Completion criterion                                                                                                          |
| --- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 0   | ~~Commit the SDL/X11 triangle + `reap(limit)` / `growOnly`.~~ **Done** (`32c323f71`, `1faff458a`). Tree is clean.                       | `git status` clean. `dub build --single vulkan-triangle.d` still works.                                                       |
| 1   | Skeleton window: ImportC + scanner, registry, `xdg_toplevel`, first configure, **ack**, commit empty, print configure sizes. No Vulkan. | Runs on Mutter; prints sizes while you drag; `SKIP:` + 0 with `env -u WAYLAND_DISPLAY`. Compare to `os-apis/wayland/example`. |
| 2   | Vulkan surface on that `wl_surface`. One swapchain, one static triangle, no resize.                                                     | Window shows the navy clear + triangle. `--help` works. `--frames 120` presents 120 frames and exits.                         |
| 3   | Resize: pending size from toplevel, ack + recreate (or grow-only) **after** dispatch, then draw. `--trace-ms 20`.                       | HITL on Mutter **before** decorations or input. Fast-drag dispatch ≤ 20 ms. Triangle tracks.                                  |
| 4   | Input enough to close: `xdg_toplevel.close`. Escape via `wl_keyboard` can wait.                                                         | Close button / compositor close quits cleanly and prints `RunReport`.                                                         |
| 5   | SSD if the decoration manager exists; else undecorated.                                                                                 | No libdecor in `ldd`. Title is ASCII.                                                                                         |
| 6   | Compare numbers to the X11 table.                                                                                                       | [§8.7](#87-success-criteria-must-measure) filled in with a real `RunReport`.                                                  |

Do **not** start with a full windowing library, IME, clipboard, fractional scale, or Skia.

### 8.9 What to copy vs rewrite

**Copy (or import):** shaders + `spirvWords`, `Pipeline`, `RenderTarget`, `record` / barriers, `FrameSync`, `Swapchain`, `decideAcquire`, `drawableExtent` if you keep shrink-without-create, CLI via `sparkles:core-cli` + wired `PresentMode`, `--trace-ms` / `RunReport` (same columns).

**Rewrite:** window, surface, event pump, configure/ack.

**Do not copy:** `SDL_AddEventWatch`, `--decor`, `--video-driver`, libdecor plugin dir hack, `SDL_DelayNS` mailbox pace unless you still see a commit flood (if you present once per compositor frame you will not).

### 8.10 Nix / flake

New files are **invisible** to `nix develop` / flake builds until `git add`ed (stage, no need to commit). Symptom: “No package file found”.

If the example needs `wayland-protocols` / `wayland-scanner`, add them to `nix/shells/default.nix` next to `pkgs.wayland` (Linux-only `optionals` block). `ciPackages` only if a CI job actually runs the scanner.

The research Wayland example’s `dub.sdl` is only `libs "wayland-client"` — it never needed the scanner. Yours will.

---

## 9. Repository map

| Path                                                               | Role                                                                                                                                              |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libs/ui-sdl3/examples/vulkan-triangle.d`                          | Current SDL example. Owns triangle, CLI, frame loop, `RenderTarget`, `Pipeline`. Keep GPU bits.                                                   |
| `libs/ui-sdl3/examples/shaders/`                                   | `triangle.vert` / `.frag` + SPIR-V                                                                                                                |
| `libs/ui-sdl3/src/sparkles/ui_sdl3/swapchain.d`                    | `chooseExtent` / `choosePresentMode` / `decideResize` / `recreate` / `reap(limit)`. Reuse if the new window feeds `VulkanContext` + a pixel size. |
| `libs/ui-sdl3/src/sparkles/ui_sdl3/frame.d`                        | `FrameSync`, `decideAcquire`. Reuse.                                                                                                              |
| `libs/ui-sdl3/src/sparkles/ui_sdl3/vulkan_context.d`               | Instance / device / **SDL** surface. Needs a Wayland-native create path.                                                                          |
| `libs/ui-sdl3/src/sparkles/ui_sdl3/window.d`                       | SDL window + `PixelSize`. Do not use the window for the native app.                                                                               |
| `libs/ui-sdl3/src/sparkles/ui_sdl3/events.d`                       | SDL → `sparkles:input`. Darwin `size_t` fix is `1faff458a`.                                                                                       |
| `libs/vulkan/src/sparkles/vulkan/vulkan_c.c`                       | `VK_NO_PROTOTYPES`, **no** `VK_USE_PLATFORM_*`                                                                                                    |
| `libs/vulkan/src/sparkles/vulkan/loader.d`                         | `vkGetInstanceProcAddr` without SDL                                                                                                               |
| `libs/vulkan/src/sparkles/vulkan/dispatch.d`                       | Has `khrSurface` + swapchain; **no** wayland surface                                                                                              |
| `docs/research/window-system-integration/os-apis/wayland/example/` | Registry-only ImportC bootstrap                                                                                                                   |
| `docs/guidelines/importc-c-libraries.md`                           | How we add C deps                                                                                                                                 |

`sparkles:ui-skia` / Graphite is out of scope. Same rule as today: prove WSI without Skia.

---

## 10. Open questions (do not block v1)

- Promote the window to `sparkles:ui-wayland` vs keep it example-only until Skia needs it.
- Keep SDL as a **fallback** backend for X11/Windows/macOS, or go WSI-per-platform from the start ([recommendations](../../research/window-system-integration/recommendations.md)).
- CSD later, still without libdecor (draw a titlebar ourselves, or live with SSD/none). GNOME will force the none/CSD path.
- Whether native Wayland should mailbox-uncapped or wait on `wl_surface.frame` (vkcube draws every loop iteration after dispatch; Mutter will pace if you ack+commit promptly).
- Lift `PixelSize` out of `window.d` so `Swapchain` does not import SDL types.

---

## 11. Owner quotes (acceptance language)

> Mailbox &lt;1 ms steady, FIFO 16–17 ms, slow resize 5–30 ms, fast drag 100–1000 ms.

> The previous build felt much more smooth. The downside was that on faster resize motions it was dragging behind (though in a smooth way).

> I confirm the bugs I reported are fixed [title + shrink clip]. Without `--video-driver x11` the performance is still bad. But with x11 is the best I tested so far.

> [After debounce] the actual triangle was not resizing in real-time (**which is a must have**).

> [After grow-only + viewport] much better!

> [After 64 px slack] Feels worse now, not sure if the stats represent this.

> I want to drop SDL (to avoid libdecor) and build a native Wayland app.

Live tracking **beats** prettier create counts. Do not reintroduce slack, debounce, or pad-to-display without a new measurement on **native** Wayland (where `currentExtent` is app-defined and pad is legal — still not the v1 recommendation).

---

## 12. Pitfalls specific to this repo

- **`git add` new files** or `nix develop` / flake builds will not see them.
- **Substantial scripts in D**, not Python.
- **`@nogc` listeners** vs D runtime: see [§8.3](#83-importc--wayland-scanner).
- **wayland-scanner output** is C; ImportC it. Do not parse XML on the hot path.
- **One `wl_display` default queue.** Same thread as Mesa WSI.
- **Commit messages:** conventional commits; backtick `` `@nogc` `` / `` `@safe` `` so GitHub does not mention users. Scope e.g. `feat(ui-sdl3/examples): native Wayland triangle`.
- **Pre-commit:** prettier on markdown; `check-docs-sidebar` if you add more `docs/**/*.md` (this page is already in the sidebar). Bypass a single hook with `SKIP=…` if needed.
- **`dip1000` / `in`:** `const` on `Expected` payloads and ImportC structs has already bitten this stack. Prefer `auto` / `ref`.
- **Do not enable `VK_KHR_dynamic_rendering` on a 1.1 instance.**
- **Do not mix MangoHud with `--validation`.**
- **Default `--frames` is 120.** Interactive tests need `--frames 0`.

---

## 13. Pointers already in the tree

- `libs/ui-sdl3/examples/vulkan-triangle.d` module doc points here.
- VitePress sidebar: **UI SDL3 → Native Wayland resize handoff** (`docs/.vitepress/config.mts`).
