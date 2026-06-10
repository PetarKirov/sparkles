# Win32 — F02: resize correctness

Findings from [`./examples/f02-resize/app.d`][f02-app], the Win32 implementation of the
[F02 spec][f02-spec]: a continuously redrawn, corner-anchored gradient (corner values
verified in the backbuffer after every draw) surviving a 14-step programmatic
[`SetWindowPos`][setwindowpos] storm — pure grows, pure shrinks, mixed, move-only and a
same-size no-op — with every [`WM_SIZING`][wm-sizing] / [`WM_SIZE`][wm-size] /
[`WM_WINDOWPOSCHANGING`][wm-windowposchanging] / [`WM_WINDOWPOSCHANGED`][wm-windowposchanged]
/ [`WM_ERASEBKGND`][wm-erasebkgnd] / [`WM_PAINT`][wm-paint] logged with its payload. Two variants are flag
toggles: `WSI_NO_INVALIDATE=1` reproduces the [scaffold's][scaffold] **stale-shrink**
artifact, and `WSI_GROW_ONLY=1` switches the DIB allocation strategy from realloc-per-resize
to grow-only reuse.

**Last reviewed:** June 10, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`, null
> display driver, headless) with the exe cross-compiled by LDC 1.41.0
> (`-mtriple=x86_64-pc-windows-msvc`). Wine is a **reimplementation, not Windows**: message
> orderings and timings are Wine's, and statements about them are phrased as such. Findings
> flagged as possibly Wine-specific are queued for confirmation on the Windows CI runner.

---

## The demo

Three bounded runs (`WSI_AUTO_EXIT=1`: ~0.5 s of 16 ms-timer animation, then the storm,
then [`DestroyWindow`][destroywindow]), all of which exited `0`:

| Run           | Flags                 | Frames | `buffer_alloc` | `buffer_reuse` | `stale_content` | `paint_check` failures |
| ------------- | --------------------- | ------ | -------------- | -------------- | --------------- | ---------------------- |
| default       | —                     | 44     | 12             | 0              | 0               | 0                      |
| stale probe   | `WSI_NO_INVALIDATE=1` | 37     | 12             | 0              | **4**           | 0                      |
| grow-only DIB | `WSI_GROW_ONLY=1`     | 44     | **5**          | **7**          | 0               | 0                      |

The storm's 14 [`SetWindowPos`][setwindowpos] steps (outer sizes; Wine's default frame costs
8 px horizontally, 34 px vertically): grows `520×360 → 640×480 → 800×600 → 1024×768`,
shrinks `700×500 → 500×350 → 320×240`, mixed `240×640 → 640×240`, two move-only steps
(`SWP_NOSIZE`), one same-size/same-position step, then grow `800×600` and shrink back to
`480×320`. After each step the demo invalidates (unless `WSI_NO_INVALIDATE=1`) and forces a
synchronous paint with [`UpdateWindow`][updatewindow], then logs a `step_result painted=`
verdict by comparing the frame counter.

**Artifact freedom is checked, not eyeballed:** after every gradient draw the four corners
of the current client-size region are compared against the expected channel extremes
(`paint_check`); a stale or wrongly-strided buffer fails immediately. All three runs
reported `paint_checks failed=0`, and with the fix active every size-changing step reported
`painted=1` — no step presented a frame anchored to a previous size.

---

## Annotated message sequences — `A[wine]`

### Create + show (timestamps µs since `init_start`)

```text
12869  step name=CreateWindowExW
13215  msg name=WM_NCCREATE
13868  msg name=WM_NCCALCSIZE
14107  msg name=WM_CREATE
14317  window_created
14469  step name=ShowWindow
14646  msg name=WM_SHOWWINDOW shown=1
14864  msg name=WM_WINDOWPOSCHANGING pos=0,0 size=0x0 flags=0x0043
18185  msg name=WM_ERASEBKGND
18391  msg name=WM_WINDOWPOSCHANGED pos=0,0 size=480x320 flags=0x1847
18734  msg name=WM_SIZE wparam=0 size=472x286
18981  first_configure size=472x286
19416  buffer_alloc size=472x286 cap=472x286 bytes=539968
19716  msg name=WM_MOVE pos=4,30
19914  step name=UpdateWindow
20111  msg name=WM_PAINT
20752  first_pixel_presented size=472x286
```

Same shape as the [scaffold][scaffold] (and as F01's default mode), now with the
`WINDOWPOS` payloads visible: `WM_WINDOWPOSCHANGING` carries the **proposed** geometry
(`flags=0x0043` = `SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW` — a show, not a resize), and
`WM_WINDOWPOSCHANGED` the **final** outer geometry (`480x320`), from which the client size
`472x286` is announced via `WM_SIZE` (`wparam=0` = `SIZE_RESTORED`). `WM_ERASEBKGND` still
precedes the size announcement (`A[wine]`, flagged for the Windows runner).

### Pure grow (storm step `i=0`, default run)

```text
504700 step name=SetWindowPos i=0 kind=grow pos=0,0 size=520x360
505032 msg name=WM_WINDOWPOSCHANGING pos=0,0 size=520x360 flags=0x0016
505432 msg name=WM_NCCALCSIZE
506338 msg name=WM_ERASEBKGND
506659 msg name=WM_WINDOWPOSCHANGED pos=0,0 size=520x360 flags=0x1016
507011 msg name=WM_SIZE wparam=0 size=512x326
507546 buffer_alloc size=512x326 cap=512x326 bytes=667648
507877 msg name=WM_PAINT
508597 frame_callback t=508596 frame=31 size=512x326
508925 step_result i=0 kind=grow painted=1 client=512x326
```

The full pattern — proposed (`WM_WINDOWPOSCHANGING`) → non-client recalculation
([`WM_NCCALCSIZE`][wm-nccalcsize]) → erase of the newly exposed region → final
(`WM_WINDOWPOSCHANGED`) → client-size notification (`WM_SIZE`) → DIB realloc → paint — runs
**re-entrantly, before `SetWindowPos` returns**. Every requested size was granted verbatim.

### Pure shrink, fix active (step `i=6`, default run)

```text
535735 step name=SetWindowPos i=6 kind=shrink pos=0,0 size=320x240
536075 msg name=WM_WINDOWPOSCHANGING pos=0,0 size=320x240 flags=0x0016
536458 msg name=WM_NCCALCSIZE
537102 msg name=WM_WINDOWPOSCHANGED pos=0,0 size=320x240 flags=0x1016
537467 msg name=WM_SIZE wparam=0 size=312x206
537992 buffer_alloc size=312x206 cap=312x206 bytes=257088
538358 msg name=WM_PAINT
538781 frame_callback t=538781 frame=37 size=312x206
540156 step_result i=6 kind=shrink painted=1 client=312x206
```

Note the missing `WM_ERASEBKGND`: a shrink exposes nothing, so the system invalidates
nothing. The `WM_PAINT` at 538358 exists **only** because the demo's explicit
[`InvalidateRect`][invalidaterect] requested it.

### Pure shrink, fix disabled (`WSI_NO_INVALIDATE=1`, step `i=4`) — the stale-content artifact

```text
525326 step name=SetWindowPos i=4 kind=shrink pos=0,0 size=700x500
525672 msg name=WM_WINDOWPOSCHANGING pos=0,0 size=700x500 flags=0x0016
526049 msg name=WM_NCCALCSIZE
527246 msg name=WM_WINDOWPOSCHANGED pos=0,0 size=700x500 flags=0x1016
527608 msg name=WM_SIZE wparam=0 size=692x466
528231 buffer_alloc size=692x466 cap=692x466 bytes=1289888
528552 step_result i=4 kind=shrink painted=0 client=692x466
528867 stale_content i=4 kind=shrink was=1016x734 now=692x466
       note=window_still_shows_frame_anchored_to_old_size
```

No `WM_ERASEBKGND`, **no `WM_PAINT`** — `UpdateWindow` was a no-op, exactly as documented:

> The `UpdateWindow` function updates the client area of the specified window by sending a
> `WM_PAINT` message to the window if the window's update region is not empty. … If the
> update region is empty, no message is sent.
>
> — [`UpdateWindow`][updatewindow], Microsoft Learn

The retained window surface still covers the smaller client area, so the window keeps
showing the **previous frame's gradient, anchored to `1016×734`, in a `692×466` window** —
the F02 artifact class. All four pure shrinks in this run (`i=4,5,6,13`) logged
`painted=0` + `stale_content`; both mixed steps (`i=7,8`) still painted, because their one
growing dimension makes the system invalidate the newly exposed strip (their logs show
`WM_ERASEBKGND` + `WM_PAINT` even without the demo's `InvalidateRect`). **For a
continuously-animating app on Win32, self-invalidation on resize exists only for grows;
shrink correctness is entirely the app's responsibility.** (`A[wine]`; the mechanism matches
the `UpdateWindow`/[`InvalidateRect`][invalidaterect] contract, so it is expected to hold on
Windows — CI confirms.)

### Move-only (`SWP_NOSIZE`, step `i=9`, stale-probe run)

```text
547332 step name=SetWindowPos i=9 kind=move pos=120,120 size=0x0
547692 msg name=WM_WINDOWPOSCHANGING pos=120,120 size=0x0 flags=0x0015
548158 msg name=WM_WINDOWPOSCHANGED pos=120,120 size=640x240 flags=0x0815
548548 msg name=WM_MOVE pos=124,150
548776 step_result i=9 kind=move painted=0 client=632x206
```

No `WM_NCCALCSIZE`, no `WM_SIZE`, no paint: [`DefWindowProcW`][wm-windowposchanged]
synthesizes only [`WM_MOVE`][wm-move] from this `WM_WINDOWPOSCHANGED` —

> By default, the `DefWindowProc` function sends the `WM_SIZE` and `WM_MOVE` messages to
> the window. The `WM_SIZE` and `WM_MOVE` messages are not sent if an application handles
> the `WM_WINDOWPOSCHANGED` message without calling `DefWindowProc`.
>
> — [`WM_WINDOWPOSCHANGED`][wm-windowposchanged], Microsoft Learn

`WM_MOVE` reports the **client** area's screen position (`124,150` = outer `120,120` plus
Wine's `4,30` frame offset). The raw `flags=` values are the [`WINDOWPOS`][windowpos]
flags; the bits beyond the documented `SWP_*` set (`0x0800`, `0x1000`) are user32-internal
markers correlating with which of `WM_SIZE`/`WM_MOVE` gets synthesized — logged raw, no
claim beyond that.

### Same size, same position (step `i=11`, stale-probe run)

```text
550799 step name=SetWindowPos i=11 kind=same pos=0,0 size=640x240
551137 msg name=WM_WINDOWPOSCHANGING pos=0,0 size=640x240 flags=0x0016
551609 step_result i=11 kind=same painted=0 client=632x206
```

A genuinely no-op `SetWindowPos` still delivers **`WM_WINDOWPOSCHANGING`** — "a window
whose size, position, or place in the Z order is _about to change_"
([`WM_WINDOWPOSCHANGING`][wm-windowposchanging]) — but `WM_WINDOWPOSCHANGED` and everything
after it are suppressed once the system determines nothing changed (`A[wine]`; worth
confirming on Windows). The proposed-change hook fires on intent, the changed notification
only on effect.

---

## Who picks the final size

**Notification, not negotiation** (`A[wine]`, consistent with the documented model): the
app requests an **outer** rectangle; every requested size in the storm was granted
verbatim and announced after the fact via `WM_SIZE` — "[s]ent to a window after its size
has changed" ([`WM_SIZE`][wm-size]). There is no ack step and no compositor counter-offer
(contrast Wayland's configure/ack/commit in the [F02 spec][f02-spec]). The app's veto/clamp
points are all _hooks on the way in_:

- [`WM_GETMINMAXINFO`][wm-getminmaxinfo] — clamp min/max tracking sizes (not exercised);
- [`WM_WINDOWPOSCHANGING`][wm-windowposchanging] — "[d]uring this message, modifying any of
  the values in `WINDOWPOS` affects the window's new size, position, or place in the Z
  order" (not exercised);
- [`WM_NCCALCSIZE`][wm-nccalcsize] — decides how much of the outer rectangle becomes client
  area (left to `DefWindowProcW`: outer `480×320` → client `472×286` under Wine's theme).

## Buffer strategy: realloc-per-resize vs grow-only reuse

Both strategies are implemented behind `WSI_GROW_ONLY` and produced identical visual
results (`paint_checks failed=0`, all steps `painted=1`):

| Metric                        | realloc (default)             | grow-only (`WSI_GROW_ONLY=1`)                  |
| ----------------------------- | ----------------------------- | ---------------------------------------------- |
| `CreateDIBSection` calls      | 12 (1 create + 11 size steps) | 5 (1 create + the 4 pure grows)                |
| `buffer_reuse` (stride-drawn) | 0                             | 7 (every shrink/mixed/return step)             |
| Peak DIB                      | 2,982,976 B, freed on shrink  | 2,982,976 B (`cap=1016x734`), **held to exit** |
| Storm wall time               | ~70.7 ms                      | ~68.5 ms                                       |

At this storm rate the difference is noise (`A[wine]`): [`CreateDIBSection`][createdibsection]
plus the realloc dance cost roughly what the stride bookkeeping saves. The real trade-off is
**peak memory held vs allocator churn** — grow-only pins the high-water-mark buffer
(2.9 MB here) for the window's remaining lifetime, while realloc returns memory on every
shrink but creates/destroys a kernel GDI object per resize. A grow-only (or pooled)
strategy becomes interesting for _interactive_ resize, where `WM_SIZING` storms arrive at
mouse-move rate — that path is F03's measurement. One correctness note: a reused
larger-than-client DIB **must** be drawn through its allocation stride (`cap` width), not
the client width — the demo's `paint_check` corners would fail instantly otherwise.

## The modal-resize gap (`WM_SIZING`)

Across all three runs: `wm_sizing_count=0`, `wm_entersizemove_count=0`. A programmatic
[`SetWindowPos`][setwindowpos] storm **cannot** reach the interactive sizing path —
[`WM_SIZING`][wm-sizing] is "[s]ent to a window that the user is resizing", i.e. only from
the modal loop a border drag enters ([`WM_ENTERSIZEMOVE`][wm-entersizemove] →
`WM_SIZING`… → `WM_EXITSIZEMOVE`). The demo logs and counts all three so their absence is
itself recorded evidence. Interactive border-drag resize on Win32 is therefore **Tier C**
for this feature (per the [spec][f02-spec]'s verification note), and the modal-loop
pathology — the pump being held hostage during the drag — is exercised by [F03][f03].

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f02-resize/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f02-resize.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f02-resize.exe                    # default
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 WSI_NO_INVALIDATE=1 \
    nix develop .#win32 -c wine64 ./build/f02-resize.exe                    # stale probe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 WSI_GROW_ONLY=1 \
    nix develop .#win32 -c wine64 ./build/f02-resize.exe                    # grow-only DIB
```

All three exit `0`. Without `WSI_AUTO_EXIT=1` the demo animates until the user closes the
window — an interactive border drag would then exercise (and log) the `WM_SIZING` path.
The package's `dub.sdl` (`platforms "windows"`) exists for the Windows CI runner; locally
`dub` is not part of the pipeline, and the demo must not be run under
`wine explorer /desktop=…` (it swallows stdout and the exit code).

---

## Sources

- [`./examples/f02-resize/app.d`][f02-app] — the demo (all log excerpts above)
- [F02 spec][f02-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold] — the original stale-shrink observation, baseline storm
- [`SetWindowPos`][setwindowpos], [`UpdateWindow`][updatewindow],
  [`InvalidateRect`][invalidaterect], [`WM_SIZE`][wm-size], [`WM_SIZING`][wm-sizing],
  [`WM_WINDOWPOSCHANGING`][wm-windowposchanging], [`WM_WINDOWPOSCHANGED`][wm-windowposchanged],
  [`WM_NCCALCSIZE`][wm-nccalcsize], [`WM_GETMINMAXINFO`][wm-getminmaxinfo],
  [`WM_ENTERSIZEMOVE`][wm-entersizemove], [`WM_MOVE`][wm-move], [`WINDOWPOS`][windowpos],
  [`CreateDIBSection`][createdibsection] — Microsoft Learn (Wayback-pinned)

<!-- References -->

[f02-app]: ./examples/f02-resize/app.d
[scaffold]: ./scaffold.md
[f02-spec]: ../features/f02-resize.md
[f03]: ../features/f03-modal-loop.md
[setwindowpos]: https://web.archive.org/web/20260331132945/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
[updatewindow]: https://web.archive.org/web/20251129164958/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-updatewindow
[invalidaterect]: https://web.archive.org/web/20260214013648/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-invalidaterect
[destroywindow]: https://web.archive.org/web/20260604001811/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-destroywindow
[createdibsection]: https://web.archive.org/web/20260504180948/https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdibsection
[wm-paint]: https://web.archive.org/web/20260420213221/https://learn.microsoft.com/en-us/windows/win32/gdi/wm-paint
[wm-size]: https://web.archive.org/web/20260610105248/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-size
[wm-sizing]: https://web.archive.org/web/20251011051049/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-sizing
[wm-windowposchanging]: https://web.archive.org/web/20260331132957/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanging
[wm-windowposchanged]: https://web.archive.org/web/20251213210222/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanged
[wm-erasebkgnd]: https://web.archive.org/web/20260520180843/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-erasebkgnd
[wm-nccalcsize]: https://web.archive.org/web/20260325165520/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-nccalcsize
[wm-getminmaxinfo]: https://web.archive.org/web/20260528084618/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-getminmaxinfo
[wm-entersizemove]: https://web.archive.org/web/20250611230612/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove
[wm-move]: https://web.archive.org/web/20260427173509/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-move
[windowpos]: https://web.archive.org/web/20251125031139/https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-windowpos
