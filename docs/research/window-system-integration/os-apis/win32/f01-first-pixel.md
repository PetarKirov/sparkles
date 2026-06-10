# Win32 — F01: first pixel & init cost

Findings from [`./examples/f01-first-pixel/app.d`][f01-app], the Win32 implementation of the
[F01 spec][f01-spec]: one instrumented software frame — [`RegisterClassExW`][registerclassex]
→ [`CreateWindowExW`][createwindowex] → a [DIB-section][createdibsection] gradient presented
by one [`BitBlt`][bitblt] inside [`WM_PAINT`][wm-paint] — then a ~200 ms hold and a clean
exit `0`. It extends the [scaffold][scaffold] with the two probes the spec called for: a
**second [`LoadCursorW`][loadcursorw]** call that separates the one-time session-connection
cost from the steady per-call cost, and a **`WSI_WS_VISIBLE=1`** variant that settles for
which window styles the spec's "`WM_SIZE` arrives during `CreateWindowEx`" parenthetical
actually holds.

**Last reviewed:** June 10, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`, null
> display driver, headless) with the exe cross-compiled by LDC 1.41.0
> (`-mtriple=x86_64-pc-windows-msvc`). Wine is a **reimplementation, not Windows**: message
> orderings and timings below are Wine's, and statements about them are phrased as such.
> The Windows CI runner re-executes the same package with `dub` to confirm the sequences on
> real Windows.

---

## What the demo adds over the scaffold

| Aspect        | [scaffold][scaffold-app]                                          | [`f01-first-pixel/app.d`][f01-app]                                                                                               |
| ------------- | ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Frames        | continuous (16 ms timer)                                          | exactly **one** software frame, then a 200 ms hold ([`SetTimer`][settimer]) → [`DestroyWindow`][destroywindow] → exit `0`        |
| `LoadCursorW` | one call (the 13 ms first-user32-call surprise)                   | called **twice** (`call=1` / `call=2`) to split first-connection cost from per-call cost                                         |
| Window style  | always `WS_OVERLAPPEDWINDOW`, explicit [`ShowWindow`][showwindow] | `WSI_WS_VISIBLE=1` adds [`WS_VISIBLE`][window-styles] and skips `ShowWindow` (message-order probe)                               |
| Creation msgs | `WM_NCCREATE`/`WM_NCCALCSIZE`/`WM_CREATE` logged                  | additionally [`WM_GETMINMAXINFO`][wm-getminmaxinfo] and [`WM_WINDOWPOSCHANGING`][wm-windowposchanging], each tagged `in_create=` |
| Init steps    | one `step` per API call                                           | same, plus `CreateCompatibleDC`/`CreateDIBSection`/`BeginPaint`/`BitBlt` steps inside the paint path                             |

Both runs below are the bounded mode (`WSI_AUTO_EXIT=1`); both exited `0` with the full
sequence on stderr.

---

## Init step sequence & timing — `A[wine]`

Default mode (`ws_visible=0`), timestamps in µs since `init_start`:

```text
0      f01_first_pixel_win32 init_start
184    f01_first_pixel_win32 mode auto_exit=1 ws_visible=0
414    f01_first_pixel_win32 step name=GetModuleHandleW
628    f01_first_pixel_win32 step name=LoadCursorW call=1
13746  f01_first_pixel_win32 step name=LoadCursorW call=2
13993  f01_first_pixel_win32 step name=RegisterClassExW
14229  f01_first_pixel_win32 step name=CreateWindowExW ws_visible=0
14612  f01_first_pixel_win32 msg name=WM_GETMINMAXINFO in_create=1
14961  f01_first_pixel_win32 msg name=WM_NCCREATE in_create=1
15482  f01_first_pixel_win32 msg name=WM_NCCALCSIZE in_create=1
15790  f01_first_pixel_win32 msg name=WM_CREATE in_create=1
16034  f01_first_pixel_win32 step name=CreateCompatibleDC
16295  f01_first_pixel_win32 window_created
16474  f01_first_pixel_win32 step name=ShowWindow
16671  f01_first_pixel_win32 msg name=WM_SHOWWINDOW shown=1 in_create=0
16956  f01_first_pixel_win32 msg name=WM_WINDOWPOSCHANGING in_create=0
20618  f01_first_pixel_win32 msg name=WM_ERASEBKGND in_create=0
20892  f01_first_pixel_win32 msg name=WM_WINDOWPOSCHANGED in_create=0
21170  f01_first_pixel_win32 first_configure size=472x286 in_create=0
21472  f01_first_pixel_win32 resize size=472x286 scale=1.00 in_create=0
21758  f01_first_pixel_win32 step name=CreateDIBSection
21994  f01_first_pixel_win32 buffer_alloc size=472x286 bytes=539968
22263  f01_first_pixel_win32 msg name=WM_MOVE in_create=0
22496  f01_first_pixel_win32 step name=UpdateWindow
22718  f01_first_pixel_win32 msg name=WM_PAINT in_create=0
22951  f01_first_pixel_win32 step name=BeginPaint
23570  f01_first_pixel_win32 step name=BitBlt size=472x286
23840  f01_first_pixel_win32 first_pixel_presented size=472x286
24096  f01_first_pixel_win32 summary concepts=10 loc_file=app.d round_trips_observed=0
```

`init_start` → `first_pixel_presented` = **23,840 µs** (`A[wine]`), distributed as:

| Step                                                     | Δ (µs)     | Round-trip?                                                                              |
| -------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------- |
| `LoadCursorW` `call=1` (first user32 call)               | **13,118** | the one-time session connection (under Wine: wineserver + display-driver load)           |
| `LoadCursorW` `call=2` (identical call, warm)            | 247        | purely local — the 13 ms above is connection cost, **not** `LoadCursorW`'s own cost      |
| [`RegisterClassExW`][registerclassex]                    | 236        | local                                                                                    |
| [`CreateWindowExW`][createwindowex] → `window_created`   | 2,066      | synchronous; `WM_GETMINMAXINFO`…`WM_CREATE` run re-entrantly inside the call             |
| `ShowWindow` cascade (`WM_SHOWWINDOW` … `WM_MOVE`)       | 6,022      | includes the first `WM_SIZE` and the 539,968-byte [`CreateDIBSection`][createdibsection] |
| [`UpdateWindow`][updatewindow] → first `BitBlt` returned | 1,344      | gradient fill of 472×286 px + `BitBlt`                                                   |

### First-connection vs per-call cost

The two consecutive `LoadCursorW` calls bracket the question the [scaffold][scaffold] left
open: `call=1` cost **13,118 µs**, `call=2` cost **247 µs** — a ~53× ratio (`A[wine]`).
The first user32 call of the process pays a one-time connection charge; every subsequent
user32 call is local and sub-millisecond. Under Wine that charge is wineserver connection
plus display-driver load; on real Windows the equivalent work happens in `user32.dll`
process init, so the CI runner's numbers are expected to show a flat `call=1` ≈ `call=2`
profile there — re-measuring is what the matrix's Windows cell is for.

---

## The `WS_VISIBLE` answer — which call delivers the first `WM_SIZE`?

The [F01 spec][f01-spec]'s era assumption was "Win32 delivers `WM_SIZE` inside
`CreateWindowEx`". The `WSI_WS_VISIBLE=1` run settles it (`A[wine]`). [`WS_VISIBLE`][window-styles]
is documented as:

> The window is initially visible. This style can be turned on and off by using the
> `ShowWindow` or `SetWindowPos` function.
>
> — [Window Styles][window-styles], Microsoft Learn

With `WS_VISIBLE` set at creation, the **entire show cascade moves inside
`CreateWindowExW`** — every message up to and including the first `WM_SIZE` and `WM_MOVE`
is logged `in_create=1`, and `window_created` (the line after `CreateWindowExW` returns)
appears only after the DIB has already been allocated:

```text
12717  f01_first_pixel_win32 step name=CreateWindowExW ws_visible=1
13080  f01_first_pixel_win32 msg name=WM_GETMINMAXINFO in_create=1
13423  f01_first_pixel_win32 msg name=WM_NCCREATE in_create=1
13933  f01_first_pixel_win32 msg name=WM_NCCALCSIZE in_create=1
14246  f01_first_pixel_win32 msg name=WM_CREATE in_create=1
14755  f01_first_pixel_win32 msg name=WM_SHOWWINDOW shown=1 in_create=1
15050  f01_first_pixel_win32 msg name=WM_WINDOWPOSCHANGING in_create=1
18433  f01_first_pixel_win32 msg name=WM_ERASEBKGND in_create=1
18719  f01_first_pixel_win32 msg name=WM_WINDOWPOSCHANGED in_create=1
19003  f01_first_pixel_win32 first_configure size=472x286 in_create=1
19291  f01_first_pixel_win32 resize size=472x286 scale=1.00 in_create=1
19816  f01_first_pixel_win32 buffer_alloc size=472x286 bytes=539968
20115  f01_first_pixel_win32 msg name=WM_MOVE in_create=1
20349  f01_first_pixel_win32 window_created
20523  f01_first_pixel_win32 step name=ShowWindow skipped=1 reason=ws_visible
```

Side-by-side (`A[wine]`):

| Event                                                                              | `WS_OVERLAPPEDWINDOW` (default) | `… \| WS_VISIBLE`        |
| ---------------------------------------------------------------------------------- | ------------------------------- | ------------------------ |
| `WM_GETMINMAXINFO` → `WM_NCCREATE` → `WM_NCCALCSIZE` → `WM_CREATE`                 | inside `CreateWindowExW`        | inside `CreateWindowExW` |
| `WM_SHOWWINDOW` → `WM_WINDOWPOSCHANGING` → `WM_ERASEBKGND` → `WM_WINDOWPOSCHANGED` | inside `ShowWindow`             | inside `CreateWindowExW` |
| **first `WM_SIZE`** (+ DIB alloc) → `WM_MOVE`                                      | inside `ShowWindow`             | inside `CreateWindowExW` |
| first `WM_PAINT`                                                                   | inside `UpdateWindow`           | inside `UpdateWindow`    |

Three conclusions:

1. **The spec's parenthetical holds exactly for `WS_VISIBLE` windows** and not otherwise
   (`A[wine]`): the first `WM_SIZE` arrives during `CreateWindowExW` _iff_ the window is
   created visible; for a hidden-then-shown window it arrives during [`ShowWindow`][showwindow].
   The message **order** is byte-identical in both modes — only the API call whose stack
   frame delivers it changes. A binding must therefore be resize-ready _before_ calling
   `CreateWindowExW`, whichever style it uses: the reentrancy hazard is the same.
2. **`WM_GETMINMAXINFO` precedes `WM_NCCREATE`** (`A[wine]`) — the very first message a
   window receives arrives before the window has processed its creation message, matching
   "[s]ent to a window when the size or position of the window is about to change"
   ([`WM_GETMINMAXINFO`][wm-getminmaxinfo]). The scaffold left this message uninstrumented;
   it is now confirmed as part of the creation set.
3. **No `WM_PAINT` arrives inside `CreateWindowExW` even with `WS_VISIBLE`** (`A[wine]`):
   painting waits for [`UpdateWindow`][updatewindow] or the message pump in both modes.
   "First pixel" is never a side effect of window creation alone.

`init_start` → `first_pixel_presented` was **22,264 µs** in the `WS_VISIBLE` run vs
23,840 µs default — the same work, redistributed (creation-to-`window_created` grows from
2,066 µs to 7,632 µs because the show cascade now runs inside it).

---

## What "presented" means on Win32

Per the [F01 spec][f01-spec] (requirement 3), `first_pixel_presented` is logged when the
first [`BitBlt`][bitblt] inside [`WM_PAINT`][wm-paint] **returns** — at 23,840 µs above.
Two honesty notes:

- GDI offers no end-to-end present confirmation: `BitBlt`'s return means the blit into the
  window surface completed, not that the pixels reached glass. On real Windows the DWM
  composites window surfaces asynchronously after the blit; nothing in the GDI API reports
  that composition. This is Win32's analogue of X11's "no confirmation without the Present
  extension" caveat in the spec.
- Under Wine's null display driver there is **no glass at all** — the full message stream
  (including `WM_PAINT` and the `BitBlt`) runs headless. The `A[wine]` label on this number
  is therefore doing double duty: a reimplementation _and_ no physical output. The CI
  Windows runner confirms the same sequence on a real desktop.

---

## Concepts & LOC

Identical concept set to the [scaffold][scaffold] (the demo deliberately adds no new
platform objects): **10 distinct platform types** — 6 handles (`HINSTANCE`, `HCURSOR`,
`ATOM`, `HWND`, `HDC`, `HBITMAP`) plus 4 descriptor/record structs (`WNDCLASSEXW`,
`BITMAPINFO`, `PAINTSTRUCT`, `MSG`) — and **zero observable round-trips**: every call
returns synchronously, and nothing analogous to Wayland's configure/ack handshake exists.
See the [scaffold's concepts-to-pixel table][scaffold] for the per-type breakdown; the demo
logs the count as a `summary concepts=10` event.

[`app.d`][f01-app] is **322 lines** (240 non-blank, non-comment). Per the spec,
[`instrument.d`][instrument] (50 lines, copied verbatim from the scaffold) is excluded.

---

## Teardown

After `first_pixel_presented`, the bounded run arms a 200 ms [`SetTimer`][settimer] hold
(so a human running it interactively sees the frame), then tears down cleanly:

```text
225527 f01_first_pixel_win32 hold_elapsed ms=200
225854 f01_first_pixel_win32 msg name=WM_WINDOWPOSCHANGING in_create=0
226360 f01_first_pixel_win32 msg name=WM_WINDOWPOSCHANGED in_create=0
226953 f01_first_pixel_win32 msg name=WM_DESTROY
227557 f01_first_pixel_win32 msg name=WM_NCDESTROY
227793 f01_first_pixel_win32 exit code=0
```

Without `WSI_AUTO_EXIT=1` the demo holds the frame until the user closes the window.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f01-first-pixel/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f01-first-pixel.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f01-first-pixel.exe          # default
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 WSI_WS_VISIBLE=1 \
    nix develop .#win32 -c wine64 ./build/f01-first-pixel.exe          # WS_VISIBLE probe
```

Both runs exit `0`. The package's `dub.sdl` (`platforms "windows"`) exists for the Windows
CI runner; locally `dub` is not part of the pipeline, and the demo must not be run under
`wine explorer /desktop=…` (it swallows stdout and the exit code).

---

## Sources

- [`./examples/f01-first-pixel/app.d`][f01-app] — the demo (all log excerpts above)
- [F01 spec][f01-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold] — baseline sequences and the `LoadCursorW` surprise
- [`CreateWindowExW`][createwindowex], [`ShowWindow`][showwindow],
  [`UpdateWindow`][updatewindow], [Window Styles][window-styles],
  [`WM_GETMINMAXINFO`][wm-getminmaxinfo] — Microsoft Learn (Wayback-pinned)

<!-- References -->

[f01-app]: ./examples/f01-first-pixel/app.d
[instrument]: ./examples/f01-first-pixel/instrument.d
[scaffold]: ./scaffold.md
[scaffold-app]: ./examples/scaffold/app.d
[f01-spec]: ../features/f01-first-pixel.md
[registerclassex]: https://web.archive.org/web/20260601024121/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclassexw
[createwindowex]: https://web.archive.org/web/20260504062536/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createwindowexw
[showwindow]: https://web.archive.org/web/20260528084618/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow
[loadcursorw]: https://web.archive.org/web/20260320234508/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadcursorw
[updatewindow]: https://web.archive.org/web/20251129164958/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-updatewindow
[createdibsection]: https://web.archive.org/web/20260504180948/https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdibsection
[bitblt]: https://web.archive.org/web/20260504180449/https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt
[settimer]: https://web.archive.org/web/20260512015942/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
[destroywindow]: https://web.archive.org/web/20260604001811/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-destroywindow
[wm-paint]: https://web.archive.org/web/20260420213221/https://learn.microsoft.com/en-us/windows/win32/gdi/wm-paint
[wm-getminmaxinfo]: https://web.archive.org/web/20260528084618/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-getminmaxinfo
[wm-windowposchanging]: https://web.archive.org/web/20260331132957/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanging
[window-styles]: https://web.archive.org/web/20260422213536/https://learn.microsoft.com/en-us/windows/win32/winmsg/window-styles
