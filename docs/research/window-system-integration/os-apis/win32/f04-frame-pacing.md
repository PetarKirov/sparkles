# Win32 F04 — vsync / frame pacing

Where the "draw now, in sync with the display" primitive lives on Win32 — and what is left
of it under Wine. The demo,
[`./examples/f04-frame-pacing/app.d`](./examples/f04-frame-pacing/app.d), extends the
[scaffold](./scaffold.md) to the Win32 half of the [F04 spec][f04]: a trivially cheap solid
color flip paced by [`DwmFlush`][dwmflush] (the DWM composition clock) with the documented
fallback chain to a 16 ms [`SetTimer`][settimer], 600 logged `frame_callback`s,
min/p50/p99/max + jitter histogram on stdout, and a minimize/restore occlusion probe
mid-run. `dwmapi.dll` is reached with two hand-declared `extern (Windows)` prototypes +
`pragma(lib, "dwmapi")` — druntime ships no `dwmapi` module, and the SDK import library in
the [cross shell](./scaffold.md#build--run--the-verified-awine-pipeline) resolves it.

**Last reviewed:** June 10, 2026

> [!IMPORTANT]
> **All numbers are `A[wine]`** (Wine 10.0, x11 driver on bare Xvfb unless labeled
> `winewayland`) — and for this feature the Wine caveat is not a formality: Wine's
> `DwmFlush` is a **stub that succeeds without blocking** (verbatim source below), so the
> "DWM numbers" below measure the _absence_ of a composition clock. The cadence that is
> real under Wine is the fallback timer's. True DWM pacing exists only on real Windows —
> the Tier C manual entry collects it.

---

## The verdict lines

```text
# default run (x11/Xvfb): probe rejects DwmFlush, fallback path runs
17375 f04_frame_pacing_win32 step name=DwmIsCompositionEnabled hr=0x00000000 enabled=1
17759 f04_frame_pacing_win32 pacing_probe call=0 hr=0x00000000 dt_us=0
20844 f04_frame_pacing_win32 pacing_path path=timer reason=dwmflush_returns_immediately
stats path=timer frames=600 deltas=599 min_us=1694 p50_us=15864 p99_us=16931 max_us=30014

# WSI_FORCE_DWM=1: DwmFlush "paces" 600 frames in ~0.3 s — a busy spin
stats path=dwm   frames=600 deltas=599 min_us=431  p50_us=522   p99_us=748   max_us=2178
```

DWM claims to be enabled, `DwmFlush` returns `S_OK` — and pacing on it free-runs at ~1,900
"frames"/s. A pacing fallback gated on **HRESULTs alone would have busy-spun**; the demo's
behavioral probe (does the call ever _block_?) is what catches it.

## The fallback chain, as implemented

1. [`DwmIsCompositionEnabled`][dwmenabled] — reported and logged, but **not trusted as the
   gate**. On real Windows it stopped being meaningful a decade ago:

   > As of Windows 8, DWM composition is always enabled. If an app declares Windows 8
   > compatibility in their manifest, this function will receive a value of `TRUE` through
   > `pfEnabled`.
   >
   > — [`DwmIsCompositionEnabled`][dwmenabled], Microsoft Learn

   Wine mirrors exactly that: its implementation returns `TRUE` iff the prefix's reported
   Windows version is ≥ 6.3 ([`dlls/dwmapi/dwmapi_main.c`][wine-dwmapi]) — `enabled=1`
   observed, with no compositor behind it.

2. **A 10-call `DwmFlush` behavioral probe.** The documented contract is a blocking one:

   > Issues a flush call that blocks the caller until the next call to a `Present` method,
   > when all of the Microsoft DirectX surface updates that are currently outstanding have
   > been made.
   >
   > — [`DwmFlush`][dwmflush], Microsoft Learn

   A real composition clock therefore blocks ~one vblank (2–50 ms) at least once across ten
   calls. Under Wine every call returned `hr=0x00000000` in **0 µs**: Wine's `DwmFlush` is
   literally `FIXME("() stub"); return S_OK;` ([`dwmapi_main.c` lines 89–96][wine-dwmapi]).
   `pacing_path path=timer reason=dwmflush_returns_immediately` is the demo's verdict; an
   error HRESULT (`dwmflush_failed`) and mid-run failure (5 consecutive errors inside the
   pacing loop) take the same fallback. **Whatever the probe finds is logged before a
   single frame is paced.**

3. **The fallback: [`SetTimer`][settimer] at 16 ms**, frames driven from `WM_TIMER` — the
   same cadence (and the same coalescing caveats) as the [scaffold's animation
   timer](./scaffold.md#surprises), now measured properly over 600 frames.

`WSI_FORCE_TIMER=1` / `WSI_FORCE_DWM=1` override the decision so both paths stay reachable
everywhere (the forced-DWM run above is how the busy-spin number was collected — bounded,
because 600 frames complete in ~310 ms).

## Timer-path cadence — the real Wine numbers

600 frames, x11/Xvfb (`A[wine]`); the `winewayland` run of the same binary is statistically
identical (p50 15,819 µs, max 16,961 µs):

| Metric | Value (µs) | Note                                                     |
| ------ | ---------- | -------------------------------------------------------- |
| min    | 1,694      | one short delta as the queue settles after the probe     |
| p50    | 15,864     | ≈ the requested 16 ms — `SetTimer` rounds to timer ticks |
| p99    | 16,931     |                                                          |
| max    | 30,014     | a single coalesced/late tick (one 20–34 ms outlier)      |

```text
histogram bucket=<2ms     count=1
histogram bucket=12-17ms  count=597
histogram bucket=20-34ms  count=1     # all other buckets: 0
```

Two qualifications, both spec-mandated: the timestamps are the demo's own
[`MonoTime`][monotime] at callback dispatch — `WM_TIMER` conveys "draw now", **not** a
presentation time (nothing in this path says when pixels hit glass); and the cadence is a
headless-software number — there is no display refresh behind Xvfb, so 16 ms is the timer
quantum, not a vblank.

## Occlusion probe — does the clock stop when hidden?

At frame 300 the demo minimizes itself from inside the pacing callback and restores ~3 s
later (`ShowWindow(SW_MINIMIZE/SW_RESTORE)`):

```text
4823084 vis_change state=minimized t=4822480 frame=300
4824167 resize size=0x0 wparam=1            # WM_SIZE wParam=SIZE_MINIMIZED
7830174 vis_change state=restored t=7829675 frame=488
```

**The timer path does not throttle at all** (`A[wine]`, both drivers): frames 301–488 tick
through the minimized window at the same ~16 ms — 188 frames over the 3 s hold, then the
restore lands and pacing continues to 600. For a framework this is the contract a
`requestRedraw` built on `WM_TIMER` inherits: **hidden windows keep burning CPU at full
cadence** unless the framework itself gates on visibility. (Contrast Wayland, where frame
callbacks simply stop for occluded surfaces — the [F04 spec][f04]'s requirement 3
asymmetry.) On real Windows, `DwmFlush` is also expected to keep returning while minimized
— it waits on the _global_ composition pass, not on this window's visibility — which is
exactly the per-window-vs-global question the Tier C run answers with real DWM numbers.

## The gold path this demo doesn't take: DXGI waitable swapchains

On real Windows the precise way to pace is not `DwmFlush` but a **flip-model swapchain
created with `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`**, waiting each frame on
the handle from [`IDXGISwapChain2::GetFrameLatencyWaitableObject`][dxgi-waitable]:

> Call `IDXGISwapChain2::GetFrameLatencyWaitableObject` to retrieve the wait handle. …
> By default, the frame latency for waitable swap chains is set to 1, which results in the
> least possible latency but also reduces CPU-GPU parallelism.
>
> — [_Reduce latency with DXGI 1.3 swap chains_][dxgi-reduce], Microsoft Learn

It is the only Win32 primitive that both paces _and_ bounds latency (the wait releases when
the present queue has room, keyed to actual flips), and it is what serious engines use
where [Flutter's Windows embedder][flutter] settles for a `DwmGetCompositionTimingInfo`
phase-locked timer and [JUCE][juce] runs a `WaitForVBlank` thread. It is deliberately out
of scope for this demo: it requires COM object creation and the `D3D11CreateDevice` /
`IDXGIFactory2::CreateSwapChainForHwnd` / `IDXGISwapChain2` interface chain, none of which
exists in druntime's `core.sys.windows` — that is [`windows-d`][index] territory per the
binding note, against this tree's zero-third-party rule. The Tier C entry records it as the
follow-up measurement; this demo's `DwmFlush` → timer chain is the honest
plain-`core.sys.windows` ceiling.

## Wine vs Windows — what must be re-confirmed

- **`DwmFlush` blocking and its jitter.** Under Wine it never blocks (stub). Real Windows
  should show ~6.9/8.3/16.7 ms quanta tracking the monitor; p50/p99 from the Tier C run
  replace the timer table above as the platform's true frame clock.
- **`DwmIsCompositionEnabled` = `TRUE`** is expected on both, for opposite reasons
  (Windows: composition always on; Wine: a version check).
- **Minimized behavior of `DwmFlush`** — global composition clock vs per-window throttle.
- The timer path's ~16 ms cadence and its non-throttling while minimized matched Wine on
  both drivers and is low-risk, but the Windows timer quantum (15.6 ms default) should
  show up as p50 ≈ 15,600.

**Tier C manual entry (Windows box):** build `examples/f04-frame-pacing/`; run
`WSI_AUTO_EXIT=1` (default path — expect `pacing_path path=dwm reason=probe_blocked` on
real DWM, 600 vblank-paced frames, stats to stdout), then `WSI_AUTO_EXIT=1
WSI_FORCE_TIMER=1` for the timer baseline on the same machine. Note the monitor refresh
rate, whether the minimize at frame 300 changes the `DwmFlush` cadence, and paste both
stats/histogram blocks here.

## Build and run

From `docs/research/window-system-integration/os-apis/win32/examples/f04-frame-pacing/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f04-frame-pacing.exe

# Default (probe + fallback) — x11 driver on bare Xvfb
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c xvfb-run -a \
    env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) \
    wine64 ./build/f04-frame-pacing.exe
# WSI_FORCE_DWM=1  — pace on the stub anyway (the busy-spin measurement)
# plain `wine64` without xvfb-run — the winewayland variant (same fallback)
```

Stats land on **stdout**, the event log on stderr; exit `0` on all three variants. A stall
watchdog aborts with exit `2` if a pacing source ever stops delivering frames for 10 s, so
the bounded mode cannot hang CI. Without `WSI_AUTO_EXIT=1` the demo paces until closed
(no occlusion probe, stats on exit).

## Sources

- **[F04 spec][f04]** — requirements 1–3 (platform clock + documented fallback, 600-frame
  stats/histogram, occlusion behavior).
- **Microsoft Learn** (Wayback-pinned): [`DwmFlush`][dwmflush] and
  [`DwmIsCompositionEnabled`][dwmenabled] (both quoted verbatim above),
  [_Desktop Window Manager_][dwm-overview], [`SetTimer`][settimer],
  [_Reduce latency with DXGI 1.3 swap chains_][dxgi-reduce] (quoted) and
  [`IDXGISwapChain2::GetFrameLatencyWaitableObject`][dxgi-waitable].
- **Wine 10.0 source** — [`dlls/dwmapi/dwmapi_main.c`][wine-dwmapi]: `DwmFlush` stub
  (lines 89–96), `DwmIsCompositionEnabled` version check (lines 39–52).
- **Cross-references** — [frame callbacks & per-platform vsync][concepts-vsync];
  the [Win32 survey's pacing note][index]; [Flutter engine][flutter] (the
  `DwmGetCompositionTimingInfo` phase-locked timer), [JUCE][juce] (`WaitForVBlank`
  thread), [GLFW][glfw] (swap-interval only, no waitable swapchain); the
  [F03 findings][f03-doc] (the modal loop freezes whatever pacing the pump drives);
  the [Win32 scaffold](./scaffold.md) (the 16 ms `SetTimer` cadence first observed there).
- Demo sources: [`app.d`](./examples/f04-frame-pacing/app.d),
  [`instrument.d`](./examples/f04-frame-pacing/instrument.d).

<!-- References -->

[f04]: ../features/f04-frame-pacing.md
[f03-doc]: ./f03-modal-loop.md
[index]: ./index.md
[concepts-vsync]: ../../concepts.md#frame-callback-vsync
[flutter]: ../../flutter-engine.md
[juce]: ../../juce.md
[glfw]: ../../glfw.md
[monotime]: https://dlang.org/phobos/core_time.html#.MonoTime
[dwmflush]: https://web.archive.org/web/20250819222812/https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmflush
[dwmenabled]: https://web.archive.org/web/20260527140029/https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmiscompositionenabled
[dwm-overview]: https://web.archive.org/web/20260508074201/https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview
[settimer]: https://web.archive.org/web/20260512015942/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
[dxgi-reduce]: https://web.archive.org/web/20260413023624/https://learn.microsoft.com/en-us/windows/uwp/gaming/reduce-latency-with-dxgi-1-3-swap-chains
[dxgi-waitable]: https://web.archive.org/web/20260413014211/https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_3/nf-dxgi1_3-idxgiswapchain2-getframelatencywaitableobject
[wine-dwmapi]: https://gitlab.winehq.org/wine/wine/-/blob/wine-10.0/dlls/dwmapi/dwmapi_main.c
