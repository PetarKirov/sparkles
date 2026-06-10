# Win32 scaffold — findings

Findings from [`./examples/scaffold/app.d`][scaffold-app], the instrumented Win32 windowing
scaffold every `fXX-*` Win32 feature demo copies: [`RegisterClassExW`][registerclassex] →
[`CreateWindowExW`][createwindowex] (title `wsi-scaffold`) → a [`GetMessage`][getmessage]
pump, presenting a per-frame software gradient from a top-down 32-bit
[DIB section][createdibsection] via [`BitBlt`][bitblt] inside [`WM_PAINT`][wm-paint], with
DIB reallocation on [`WM_SIZE`][wm-size] and a programmatic [`SetWindowPos`][setwindowpos]
resize storm in the bounded (`WSI_AUTO_EXIT=1`) mode. It feeds the scaffold row of the
[feature matrix][matrix] and is the baseline for the [F01][f01] / [F02][f02] specs.

**Last reviewed:** June 10, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`, null
> display driver, headless) with the exe cross-compiled by LDC 1.41.0
> (`-mtriple=x86_64-pc-windows-msvc`). Wine is a **reimplementation, not Windows**: message
> orderings, frame metrics, and timings below are Wine's, and statements about them are
> phrased as such. The Windows CI runner re-executes the same package with `dub` to confirm
> the sequences on real Windows.

---

## What the scaffold adds over `example/`

The minimal example, [`./example/app.d`][example-app], proves the irreducible open-a-window
sequence (class → window → pump) and exits after one `FillRect`. The scaffold,
[`./examples/scaffold/app.d`][scaffold-app], evolves it into the measurement base the feature
demos need:

| Aspect          | [`example/app.d`][example-app]          | [`examples/scaffold/app.d`][scaffold-app]                                                               |
| --------------- | --------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Pixels          | one `FillRect(COLOR_WINDOW+1)`          | per-frame gradient into a [`CreateDIBSection`][createdibsection] backbuffer, [`BitBlt`][bitblt] present |
| Resize          | none (window never resized)             | DIB reallocated on every [`WM_SIZE`][wm-size]; programmatic [`SetWindowPos`][setwindowpos] storm        |
| Lifetime        | `PostQuitMessage` after the first paint | runs until [`WM_CLOSE`][wm-close]; `WSI_AUTO_EXIT=1` gives a bounded ~1 s run ending in exit `0`        |
| Animation       | —                                       | [`SetTimer`][settimer] ~16 ms tick → [`InvalidateRect`][invalidaterect] → next `WM_PAINT`               |
| Instrumentation | a final `printf`                        | [`instrument.d`][instrument]: `<monotonic_us> <DEMO> <EVENT_KIND> key=value ...` on stderr              |
| Teardown        | exits from inside `WM_PAINT`            | [`DestroyWindow`][destroywindow] → [`WM_DESTROY`][wm-destroy] → [`PostQuitMessage`][postquitmessage]    |

Both stay on druntime's built-in `core.sys.windows` bindings — zero third-party packages
(see the binding note in the [Win32 survey][index]).

[`instrument.d`][instrument] is the reference implementation of the [F01][f01] log contract
(microsecond [`MonoTime`][monotime] timestamps, one line per event); the other platforms'
scaffolds copy it verbatim.

---

## Concepts-to-pixel count

Distinct platform object/handle types touched between `init_start` and
`first_pixel_presented` ([F01][f01] requirement 4):

| #   | Type                              | Role                                                      | Acquired via                                      |
| --- | --------------------------------- | --------------------------------------------------------- | ------------------------------------------------- |
| 1   | `HINSTANCE`                       | module handle the class and window are registered against | `GetModuleHandleW`                                |
| 2   | `HCURSOR`                         | class cursor (first user32 call of the process)           | `LoadCursorW`                                     |
| 3   | `WNDCLASSEXW`                     | class descriptor naming the `WndProc`                     | filled by hand                                    |
| 4   | `ATOM`                            | the registered-class handle                               | [`RegisterClassExW`][registerclassex]             |
| 5   | `HWND`                            | the window object                                         | [`CreateWindowExW`][createwindowex]               |
| 6   | `HDC`                             | two instances: the memory DC and the `BeginPaint` DC      | `CreateCompatibleDC` / [`BeginPaint`][beginpaint] |
| 7   | `BITMAPINFO` (`BITMAPINFOHEADER`) | backbuffer descriptor (negative `biHeight` = top-down)    | filled by hand                                    |
| 8   | `HBITMAP`                         | the DIB section (plus the displaced 1×1 stock bitmap)     | [`CreateDIBSection`][createdibsection]            |
| 9   | `PAINTSTRUCT`                     | the paint session (`BeginPaint`/`EndPaint` bracket)       | [`BeginPaint`][beginpaint]                        |
| 10  | `MSG`                             | the pump's message record                                 | [`GetMessageW`][getmessage]                       |

**10 platform types** (6 handles — `HINSTANCE`, `HCURSOR`, `ATOM`, `HWND`, `HDC`, `HBITMAP` —
plus 4 descriptor/record structs) and **zero round-trips the app can observe**: every call
returns synchronously; nothing analogous to Wayland's configure/ack handshake exists.
`CreateDIBSection` hands back a raw pixel pointer the app scribbles into directly:

> The `CreateDIBSection` function creates a DIB that applications can write to directly. The
> function gives you a pointer to the location of the bitmap bit values.
>
> — [`CreateDIBSection`][createdibsection], Microsoft Learn

## LOC

`app.d` is **323 lines** (232 non-blank, non-comment). Per the [F01][f01] spec,
[`instrument.d`][instrument] (50 lines) is excluded from the count.

---

## Init step sequence & timing — `A[wine]`

The creation segment of the bounded run (`WSI_AUTO_EXIT=1`, Wine 10.0,
timestamps in µs since `init_start`):

```text
0      scaffold_win32 init_start
157    scaffold_win32 mode auto_exit=1
304    scaffold_win32 step name=GetModuleHandleW
497    scaffold_win32 step name=LoadCursorW
13630  scaffold_win32 step name=RegisterClassExW
13855  scaffold_win32 step name=CreateWindowExW
14194  scaffold_win32 msg name=WM_NCCREATE
14643  scaffold_win32 msg name=WM_NCCALCSIZE
14878  scaffold_win32 msg name=WM_CREATE
15074  scaffold_win32 window_created
15223  scaffold_win32 step name=ShowWindow
15403  scaffold_win32 msg name=WM_SHOWWINDOW shown=1
18899  scaffold_win32 msg name=WM_ERASEBKGND
19098  scaffold_win32 msg name=WM_WINDOWPOSCHANGED
19304  scaffold_win32 first_configure size=472x286
19514  scaffold_win32 resize size=472x286 scale=1.00
19742  scaffold_win32 buffer_alloc size=472x286 bytes=539968
19990  scaffold_win32 msg name=WM_MOVE
20146  scaffold_win32 step name=UpdateWindow
20337  scaffold_win32 msg name=WM_PAINT
20952  scaffold_win32 first_pixel_presented size=472x286
21184  scaffold_win32 frame_callback t=21183 frame=1
```

`init_start` → `first_pixel_presented` = **20,952 µs** (`A[wine]`), distributed as:

| Step                                                | Δ (µs)     | Note                                                                                                      |
| --------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------------- |
| `LoadCursorW` (first user32 call)                   | **13,133** | under Wine this is where user32 connects to the wine server and loads the display driver — Wine-only cost |
| `RegisterClassExW`                                  | 225        | purely local once user32 is up                                                                            |
| `CreateWindowExW` (incl. `WM_NCCREATE`…`WM_CREATE`) | 1,219      | synchronous; the `WndProc` runs re-entrantly inside the call                                              |
| `ShowWindow` cascade (`WM_SHOWWINDOW` … `WM_MOVE`)  | 4,767      | includes the first `WM_SIZE` and the first 539,968-byte DIB allocation                                    |
| `UpdateWindow` → first `BitBlt` returned            | 806        | gradient fill of 472×286 px + `BitBlt` ≈ 615 µs of that                                                   |

Every step is local (no observable round-trip); the dominant cost is the one-time session
connection, which on real Windows would be paid inside user32's DLL init rather than at
`LoadCursorW` — re-measuring on the CI runner is what the matrix row's Windows cell is for.

---

## Observed creation message order — `A[wine]`

Wine delivered, in order: **`WM_NCCREATE` → `WM_NCCALCSIZE` → `WM_CREATE`** (all inside
`CreateWindowExW`, before `window_created` could be logged), then nothing until `ShowWindow`
produced **`WM_SHOWWINDOW` → `WM_ERASEBKGND` → `WM_WINDOWPOSCHANGED` → `WM_SIZE` →
`WM_MOVE`**, and `UpdateWindow` forced the first **`WM_PAINT`**. This matches the documented
creation set exactly:

> The `CreateWindowEx` function sends `WM_NCCREATE`, `WM_NCCALCSIZE`, and `WM_CREATE`
> messages to the window being created.
>
> — [`CreateWindowExW` § Remarks][createwindowex], Microsoft Learn

Two ordering notes:

- **The first `WM_SIZE` did _not_ arrive during `CreateWindowExW`.** The often-repeated
  "Win32 delivers `WM_SIZE` inside `CreateWindowEx`" (the [F01][f01]-era assumption this
  scaffold was written to check) holds only for windows created with `WS_VISIBLE`; the
  scaffold creates without it and shows explicitly, so under Wine (`A[wine]`) the
  `first_configure` event landed inside [`ShowWindow`][showwindow]'s `SetWindowPos` cascade
  instead. The reentrancy hazard is the same either way — the size arrives before the
  creation call stack unwinds, just one call later — but a binding must not hard-code
  _which_ call delivers it.
- **`WM_ERASEBKGND` preceded `WM_WINDOWPOSCHANGED`/`WM_SIZE`** in the show cascade — under
  Wine the erase request reaches the `WndProc` _before_ the app has been told its client
  size. The scaffold answers `WM_ERASEBKGND` with `1` (no erase) precisely so this ordering
  cannot flash a stale background. Whether real Windows orders it the same way is a
  matrix-cell question for the CI run.

(`WM_GETMINMAXINFO`, also documented as part of creation, is not instrumented by the
scaffold — no claim about it either way.)

---

## Resize-storm sequence — `A[wine]`

At tick 60 the bounded run issues 8 `SetWindowPos` **outer-size** changes from inside one
`WM_TIMER` dispatch, forcing one synchronous paint per step ([F02][f02] requirement 2). Each
step replays the same synchronous pattern — `WM_NCCALCSIZE` → (`WM_ERASEBKGND`) →
`WM_WINDOWPOSCHANGED` → `WM_SIZE` → DIB realloc → paint — re-entrantly, before
`SetWindowPos` returns. Two consecutive steps, one grow and the only pure shrink:

```text
994789   scaffold_win32 step name=SetWindowPos i=4 size=800x600
995055   scaffold_win32 msg name=WM_NCCALCSIZE
996081   scaffold_win32 msg name=WM_ERASEBKGND
996273   scaffold_win32 msg name=WM_WINDOWPOSCHANGED
996482   scaffold_win32 resize size=792x566 scale=1.00
996737   scaffold_win32 buffer_alloc size=792x566 bytes=1793088
998277   scaffold_win32 frame_callback t=998277 frame=65
998528   scaffold_win32 step name=SetWindowPos i=5 size=300x300
998799   scaffold_win32 msg name=WM_NCCALCSIZE
999465   scaffold_win32 msg name=WM_WINDOWPOSCHANGED
999675   scaffold_win32 resize size=292x266 scale=1.00
999979   scaffold_win32 buffer_alloc size=292x266 bytes=310688
1000497  scaffold_win32 frame_callback t=1000497 frame=66
```

and the teardown tail:

```text
1006071  scaffold_win32 resize_storm_end
1006317  scaffold_win32 msg name=WM_WINDOWPOSCHANGED
1006812  scaffold_win32 msg name=WM_DESTROY
1007390  scaffold_win32 msg name=WM_NCDESTROY
1007654  scaffold_win32 exit code=0
```

Findings (all `A[wine]`):

- **Notification, not negotiation.** Every requested size was granted verbatim and announced
  after the fact — "[s]ent to a window after its size has changed" ([`WM_SIZE`][wm-size]).
  The app's only veto point would be `WM_NCCALCSIZE`/`WM_WINDOWPOSCHANGING` (not exercised
  here); there is no ack step.
- **Outer vs client size.** The app asks for the _window_ rectangle; the client size the
  `WndProc` learns is smaller by the non-client frame computed in `WM_NCCALCSIZE` —
  creation `480×320` outer → `472×286` client; storm step 0 `520×360` → `512×326`. Wine's
  default theme costs 8 px horizontally and 34 px vertically (borders + caption).
- **Allocation strategy: realloc per resize.** The scaffold frees and re-creates the DIB
  section on every `WM_SIZE` (8 `buffer_alloc` events, 310 KB–1.8 MB); each step completed
  in ~2–3 ms including the forced repaint. No pooling — a finding for the F02 demo to
  revisit, not a problem at this rate.
- **A pure shrink invalidates nothing.** Step `i=5` (792×566 → 292×266, both dimensions
  shrinking) generated **no `WM_ERASEBKGND`** — and in a run without the storm's explicit
  `InvalidateRect`, no `WM_PAINT` at all: the retained surface still covers the smaller
  client area, so the window keeps showing a stale, now wrongly-anchored gradient. The
  explicit per-step [`InvalidateRect`][invalidaterect] in
  [`runResizeStorm`][scaffold-app] is load-bearing. Grow steps invalidate only the newly
  exposed region (hence their `WM_ERASEBKGND`).
- **No modal-loop messages.** A programmatic storm never enters the interactive sizing modal
  loop: no `WM_ENTERSIZEMOVE`/`WM_SIZING` appeared. That pathology is [F03][f03]'s subject.
- **Teardown ordering.** `DestroyWindow` (called from inside the `WM_TIMER` handler) emitted
  a final `WM_WINDOWPOSCHANGED` (the hide), then `WM_DESTROY` → `WM_NCDESTROY`;
  `PostQuitMessage(0)` ended the pump and the process exited `0`.

---

## Surprises

- **`LoadCursorW` is 63% of time-to-first-pixel** under Wine (13.1 of 21.0 ms) — the first
  user32 call pays the session-connection cost. Naively attributing init time to
  `RegisterClassExW` (the first _logged_ step in an uninstrumented port) would mislead;
  this is why the scaffold logs a `step` per call. `A[wine]` — on Windows the cost moves
  into process/DLL init.
- **First `WM_SIZE` arrives in `ShowWindow`, not `CreateWindowExW`**, for a window created
  without `WS_VISIBLE` (see above) — the spec-level assumption was wrong in detail, right
  in spirit (it still arrives re-entrantly, mid-API-call).
- **`WM_ERASEBKGND` before the size is known** in the show/grow cascades (`A[wine]`).
- **Shrinks self-invalidate nothing** — continuous-redraw apps must invalidate explicitly or
  a shrink shows a stale frame ([F02][f02]'s artifact class, demonstrated trivially here).
- **Wine delivers the full message stream without a visible session** — `WM_PAINT`, timers,
  the storm, teardown — which is what makes this Tier `A[wine]` instead of Tier B.
  Correction from the F03/F04 work: this is NOT Wine's null driver — on this host Wine
  10.0 loads **winewayland** against the live `wayland-0` socket (or the x11 driver under
  Xvfb); with no display server at all, `CreateWindowExW` fails with error 1400. See
  [F03][f03-doc] for the driver-dependent `WM_SYSCOMMAND` behavior this implies. Caveat: Wine itself prints X11 noise (`Authorization required, but no
authorization protocol specified`) to stderr before the demo's first line when `DISPLAY`
  is set but unusable; log consumers must tolerate foreign stderr lines.
- **Timer cadence ran slightly slow:** the 16 ms `SetTimer` delivered ticks every
  ~16.3–16.8 ms (60 frames in ~0.98 s) — consistent with `WM_TIMER`'s low-priority,
  coalescing delivery; fine for animation, unusable as a frame clock ([F04][f04]).

---

## Build & run — the verified `A[wine]` pipeline

From the repo root, inside the opt-in cross shell (`nix develop .#win32`; first entry builds
the unfree SDK derivation). The exact commands the feature demos reuse, run in
`docs/research/window-system-integration/os-apis/win32/examples/scaffold/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/scaffold.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/scaffold.exe
```

`win32-ldc2` wraps `ldc2 -mtriple=x86_64-pc-windows-msvc -link-internally -mscrtlib=msvcrt`
plus the `/LIBPATH`s for the LDC Windows release libs and the `windows.sdk` import libs — the
project `ldc` is the official release binary with integrated LLD, so one command compiles and
links (see `nix/shells/win32-cross.nix`).

Exit code `0`, 68 `frame_callback` events (60 timer frames + 8 storm frames), full event
sequence on stderr. Without `WSI_AUTO_EXIT=1` the program runs (and animates) until the user
closes the window — `WM_CLOSE` logs `close_requested`, `DefWindowProcW` destroys, exit `0`.

The package's `dub.sdl` (`platforms "windows"`) exists for the Windows CI runner, which
builds and runs the same sources with `dub`; locally `dub` is **not** part of the pipeline —
it cannot drive this cross-compile + `lld-link` + Wine flow. Do not run the demo under
`wine explorer /desktop=…` (it swallows stdout and the exit code); the plain `wine64`
invocation above is fully headless.

<!-- References -->

[scaffold-app]: ./examples/scaffold/app.d
[instrument]: ./examples/scaffold/instrument.d
[example-app]: ./example/app.d
[index]: ./index.md
[matrix]: ../feature-matrix.md
[f01]: ../features/f01-first-pixel.md
[f02]: ../features/f02-resize.md
[f03]: ../features/f03-modal-loop.md
[f04]: ../features/f04-frame-pacing.md
[monotime]: https://dlang.org/phobos/core_time.html#.MonoTime
[registerclassex]: https://web.archive.org/web/20260601024121/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerclassexw
[createwindowex]: https://web.archive.org/web/20260504062536/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createwindowexw
[showwindow]: https://web.archive.org/web/20260528084618/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow
[getmessage]: https://web.archive.org/web/20260420210137/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessage
[createdibsection]: https://web.archive.org/web/20260504180948/https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-createdibsection
[bitblt]: https://web.archive.org/web/20260504180449/https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-bitblt
[beginpaint]: https://web.archive.org/web/20260521184316/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-beginpaint
[setwindowpos]: https://web.archive.org/web/20260331132945/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
[settimer]: https://web.archive.org/web/20260512015942/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
[invalidaterect]: https://web.archive.org/web/20260214013648/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-invalidaterect
[destroywindow]: https://web.archive.org/web/20260604001811/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-destroywindow
[postquitmessage]: https://web.archive.org/web/20260609095336/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postquitmessage
[wm-paint]: https://web.archive.org/web/20260420213221/https://learn.microsoft.com/en-us/windows/win32/gdi/wm-paint
[wm-size]: https://web.archive.org/web/20260610105248/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-size
[wm-close]: https://web.archive.org/web/20260610105639/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-close
[wm-destroy]: https://web.archive.org/web/20260521184316/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-destroy
[f03-doc]: ./f03-modal-loop.md
