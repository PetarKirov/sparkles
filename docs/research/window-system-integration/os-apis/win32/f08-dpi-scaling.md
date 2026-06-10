# Win32 — F08: DPI / runtime rescale

Findings from [`./examples/f08-dpi-scaling/app.d`][f08-app], the Win32 implementation of the
[F08 spec][f08-spec]: a Per-Monitor-v2 observatory that calls
[`SetProcessDpiAwarenessContext`][setprocessdpiawarenesscontext] before any `HWND` exists,
logs every DPI source ([`GetDpiForWindow`][getdpiforwindow] /
[`GetDpiForSystem`][getdpiforsystem] / [`GetSystemDpiForProcess`][getsystemdpiforprocess] /
`GetDeviceCaps(LOGPIXELSX)` / the thread+window
[awareness contexts][dpi-awareness-context]), proves the write-once and ordering rules,
renders 1-physical-px hairlines over the scaffold gradient, and implements the full
[`WM_DPICHANGED`][wm-dpichanged] suggested-rect contract. The headline Wine finding:
**`WM_DPICHANGED` does not exist under Wine 10.0** — a live Wayland compositor scale change
(headless sway, `output … scale 2`) reached the winewayland window as a plain `WM_SIZE`
**doubling the physical pixels at constant DPI 96**, and the registry path
(`LogPixels=144`) changes only the _startup_ DPI. The runtime-rescale plumbing is therefore
implemented-and-dormant here, queued for real mixed-DPI Windows.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`,
> headless) with the exe cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`).
> Three winewayland runs (default against the live `wayland-0` socket; a fresh prefix with
> `LogPixels=144`; a headless-sway run with a live scale change) plus a
> `WSI_LATE_AWARENESS=1` ordering probe. The [F08 spec][f08-spec] itself warns that Wine
> emulates per-monitor DPI imperfectly — this page measures exactly how imperfectly. All
> Windows-contract statements are cited; the real mixed-DPI drag is Tier C in the
> [manual-run queue][manual-queue].

---

## The demo

Four bounded runs, all exit `0`:

| Run             | Mode                                    | Captures                                                       |
| --------------- | --------------------------------------- | -------------------------------------------------------------- |
| default         | `WSI_AUTO_EXIT=1`                       | PMv2 ordering, write-once proof, DPI sources at 96             |
| late awareness  | `WSI_AUTO_EXIT=1 WSI_LATE_AWARENESS=1`  | window-first ordering probe + thread-granularity probe         |
| LogPixels 144   | fresh prefix, `reg add … LogPixels=144` | startup DPI 144 / scale 1.50, DPI virtualization while unaware |
| sway scale hunt | `WSI_RUN_MS=12000` under headless sway  | live compositor `scale 1→2` against a winewayland window       |

The Win10-1607+ DPI surface is absent from druntime's `core.sys.windows`, so the demo
declares the eight entry points and resolves them with `GetProcAddress` — which doubles as
a capability log. Wine 10.0 exports all eight (`api name=… present=1` for
`SetProcessDpiAwarenessContext`, `Get/SetThreadDpiAwarenessContext`,
`GetWindowDpiAwarenessContext`, [`AreDpiAwarenessContextsEqual`][aredpiequal],
`GetDpiForWindow`, `GetDpiForSystem`, `GetSystemDpiForProcess`).
`DPI_AWARENESS_CONTEXT` values are opaque pseudo-handles; the demo names them only through
`AreDpiAwarenessContextsEqual`, as [the docs require][dpi-awareness-context].

---

## Awareness: write-once, ordering, granularity — `A[wine]`

### The production ordering and the write-once proof

```text
15160 awareness_set when=before_window ctx=per_monitor_aware_v2 ok=1 err=0
15559 awareness_set when=second_call ctx=system_aware ok=0 err=5
```

The first call (before any `HWND`) succeeds; the immediate second call fails with
`err=5` = `ERROR_ACCESS_DENIED`, matching the documented rule — the call fails "if the
default API awareness mode for the process has already been set (via a previous API call
or within the application manifest)"
([`SetProcessDpiAwarenessContext`][setprocessdpiawarenesscontext]). Process awareness is
**write-once**, even under Wine.

### The late-call probe: Wine implements the rule literally

The spec-era expectation was that calling the API _after_ a window exists fails with
`ERROR_ACCESS_DENIED`. Observed (`WSI_LATE_AWARENESS=1`, window created first):

```text
14631 window_ctx hwnd=main ctx=unaware
15341 awareness_set when=after_window ctx=per_monitor_aware_v2 ok=1 err=0
15720 dpi_sources when=after_late_set window=96 system=96 process=96 devcaps=96
      thread_ctx=per_monitor_aware_v2
16650 window_ctx hwnd=main ctx=unaware note=unchanged_after_thread_set
```

Under Wine the late call **succeeds** — the documented failure condition is "already been
set", not "a window exists", and Wine implements that reading. But success retrofits
nothing: the pre-existing window keeps its creation-time `unaware` context
([`GetWindowDpiAwarenessContext`][getwindowdpictx] is per-window state, frozen at
`CreateWindowExW`). So the _practical_ ordering rule survives intact — **awareness must be
set before window creation to matter**, whether or not the late call errors. Whether real
Windows also accepts the late call (some user32 paths set the process default implicitly,
which would trip the already-been-set rule) is queued for the
[manual-run queue][manual-queue].

### Thread-scoped granularity

[`SetThreadDpiAwarenessContext`][setthreaddpictx] overrides the process default per thread,
which makes awareness effectively **per-window, decided at creation time**:

```text
16252 thread_awareness_set ctx=per_monitor_aware_v2 prev=per_monitor_aware_v2 ok=1
16650 window_ctx hwnd=main ctx=unaware note=unchanged_after_thread_set
17205 window_ctx hwnd=second ctx=per_monitor_aware dpi=96
```

The existing window stays `unaware`; a second window created while the thread context is
PMv2 picks the new awareness up. This is the documented incremental-migration mechanism
(per-window mixed awareness), and it works under Wine. Quirk: see
[Surprises](#surprises) for why the second window reports `per_monitor_aware`, not `…_v2`.

---

## DPI sources, virtualization, and startup DPI — `A[wine]`

### A scaled prefix: `LogPixels=144`

Wine reads `HKCU\Control Panel\Desktop\LogPixels` at prefix/server start, so the registry
path is a **startup-DPI** knob, not a runtime one (set it, `wineserver -k`, rerun). With
144 (scale 1.5):

```text
15614 dpi_sources when=before_awareness window=0 system=96  process=144 devcaps=96  thread_ctx=unaware
16907 dpi_sources when=after_awareness  window=0 system=144 process=144 devcaps=144 thread_ctx=per_monitor_aware_v2
18969 dpi_sources when=after_window window=144 system=144 process=144 devcaps=144 thread_ctx=per_monitor_aware_v2
22778 resize size=470x271 scale=1.50 logical=313x180
23782 first_pixel_presented size=470x271 dpi=144
```

Two findings in one log:

- **DPI virtualization, caught live.** While the thread was still unaware,
  [`GetDpiForSystem`][getdpiforsystem] and `GetDeviceCaps(LOGPIXELSX)` answered a
  virtualized **96** — `GetDpiForSystem`'s return value is defined by the _caller's_
  awareness — while [`GetSystemDpiForProcess`][getsystemdpiforprocess] reported the real
  **144**. Two "system DPI" APIs disagreeing by design (`A[wine]`, doc-consistent): the
  same call sequence on Windows is the classic "queried the DPI before opting in, cached
  96 forever" bug.
- **No created-at-wrong-scale-then-rescaled dance** on a single static-DPI display: the
  first `WM_SIZE` already speaks physical pixels at DPI 144 (`470x271` physical =
  `313x180` logical), and `first_pixel_presented` carries `dpi=144`. Under PMv2 the client
  rect is physical; the demo derives logical as `physical * 96 / dpi`. The wrong-scale
  startup problem is a multi-monitor phenomenon (window opens on a monitor other than the
  one the system DPI describes) — unreachable here, Tier C.

The default-prefix run is the same picture at 96/scale 1.00 throughout.

---

## The `WM_DPICHANGED` hunt: a live compositor scale change — `A[wine]`

The most Windows-like runtime-rescale stimulus available headless: run the demo on a
dedicated headless Wayland compositor and change the output scale under it while it runs.

Setup: sway 1.11 with `WLR_BACKENDS=headless WLR_RENDERER=pixman` on a private
`XDG_RUNTIME_DIR`; the demo under `WAYLAND_DISPLAY=<sway socket>` (winewayland confirmed —
`DISPLAY` cleared) with `WSI_RUN_MS=12000`; at ~6 s wall
`swaymsg output HEADLESS-1 scale 2`, at ~11 s `scale 1`. Result:

```text
15195   resize size=472x286 scale=1.00 logical=472x286
16179   first_pixel_presented size=472x286 dpi=96
18692   resize size=628x299 scale=1.00 logical=628x299      (sway tiles the window)
3988772 resize size=1268x659 scale=1.00 logical=1268x659    (the scale-2 moment)
12019248 summary dpichanged=0 final_dpi=96
```

When the output went to scale 2, the window's client area **doubled in physical pixels**
(`628x299` → `1268x659` ≈ ×2 each axis, arriving ~"now the same logical area is twice the
pixels") — and that is _all_ that happened: `GetDpiForWindow` stayed 96, **zero
`WM_DPICHANGED`**, zero [`WM_GETDPISCALEDSIZE`][wm-getdpiscaledsize] (none in any run). The
revert to scale 1 produced nothing further before the deadline. Wine 10.0's winewayland
maps compositor scale into the _virtual monitor's pixel dimensions_ and resizes surfaces,
never into the DPI subsystem — so the per-monitor-DPI message machinery is **structurally
unexercisable under Wine 10.0**, headless or not. The demo absorbed the change through the
ordinary [F02][f02-doc] path (`WM_SIZE` → DIB realloc, `buffer_alloc size=1268x659
bytes=3342448`), which is exactly what a robust binding should do anyway: treat
size-changes and scale-changes as independently arriving facts.

### The dormant contract (implemented, cited, queued)

The handler is live code awaiting a host that sends the message. Per
[`WM_DPICHANGED`][wm-dpichanged] — "In order to handle this message correctly, you will
need to resize and reposition your window based on the suggestions provided by `lParam`
and using `SetWindowPos`" — the demo logs `dpi_changed old=… new=… suggested=WxH+X+Y`,
adopts the new DPI, applies the suggested rect verbatim via
[`SetWindowPos`][setwindowpos], and lets the resulting `WM_SIZE` reallocate the DIB at the
new physical size; `WM_GETDPISCALEDSIZE` is logged and left to `DefWindowProcW` (linear
scaling). The 1-physical-px hairlines (border + center crosshair drawn into the
backbuffer) are the verification instrument: at a correct buffer size they are razor-sharp,
while DPI-virtualized bitmap stretching — the failure mode PMv2 opts out of — blurs them
visibly. Real-Windows mixed-DPI drag: [manual-run queue][manual-queue].

---

## Manifest vs API

The demo opts in via API because it is a single self-contained exe in a cross-compile
pipeline with no manifest-embedding step — and because the _failure_ modes of the API path
(ordering, write-once) are findings this page needed to capture. Production guidance is
the opposite: "We recommended that you specify the default process DPI awareness via a
manifest setting" ([Setting the default DPI awareness for a process][setting-default-dpi])
— the manifest (`<dpiAwareness>PerMonitorV2</dpiAwareness>`) is applied before any code
runs, cannot lose the ordering race against early window/DPI queries (including ones made
by injected DLLs or static initializers), and leaves `SetProcessDpiAwarenessContext` free
to fail loudly if something else already claimed the default. The API path remains the
right tool for exactly one job: a _library_ that must cope with the host process not
having declared anything — which is the thread-context probe above, not the process call.

---

## Surprises

- **`WM_DPICHANGED` is unreachable under Wine 10.0** — even a live Wayland output-scale
  change arrives as a plain physical `WM_SIZE` at constant DPI. Every WinUI/GDI
  scaling-bug reproduction that hinges on the DPI-changed path needs real Windows; Wine
  tests only the static-DPI and resize paths (`A[wine]`).
- **The late `SetProcessDpiAwarenessContext` call succeeds under Wine** — the
  `ERROR_ACCESS_DENIED` lock is "already set", not "window exists" — but it changes
  nothing for existing windows, so code that "fixes" awareness late observes success and
  no effect. The write-once failure (`err=5`) fires only on the _second_ call.
- **`GetWindowDpiAwarenessContext` degrades v2 to v1 under Wine:** windows created under a
  `per_monitor_aware_v2` thread/process context report a context equal to
  `PER_MONITOR_AWARE`, not `…_V2` (`AreDpiAwarenessContextsEqual` against v2 is false).
  Awareness round-tripping through a window handle is lossy here — compare against both
  v1 and v2 or trust your own bookkeeping (`A[wine]`).
- **Two system-DPI APIs disagree while unaware** (`GetDpiForSystem`=96 virtualized,
  `GetSystemDpiForProcess`=144 real, `LogPixels=144` prefix) — caller-relative
  virtualization captured in a single log line.
- **`scale=1.50` startup is otherwise boring** — under PMv2 with one static display the
  window is born at the right DPI and the first buffer is the right size; all the danger
  lives in _changes_, which Wine cannot deliver.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f08-dpi-scaling/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f08-dpi-scaling.exe

# default + ordering probe (winewayland, live wayland-0)
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f08-dpi-scaling.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 WSI_LATE_AWARENESS=1 \
    nix develop .#win32 -c wine64 ./build/f08-dpi-scaling.exe

# startup DPI 144: write LogPixels, restart the prefix's server, rerun
export WINEPREFIX=$(mktemp -d) WINEDEBUG=-all
nix develop .#win32 -c wine64 reg add 'HKCU\Control Panel\Desktop' \
    /v LogPixels /t REG_DWORD /d 144 /f
nix develop .#win32 -c wineserver -k
WSI_AUTO_EXIT=1 nix develop .#win32 -c wine64 ./build/f08-dpi-scaling.exe
```

The scale-change hunt additionally needs a compositor the run owns: start
`sway -c /dev/null` with `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
WLR_RENDERER=pixman` on a fresh `XDG_RUNTIME_DIR`, run the demo with
`WAYLAND_DISPLAY=<sway's socket>` / `DISPLAY=` / `WSI_AUTO_EXIT=1 WSI_RUN_MS=12000`, and
issue `swaymsg output HEADLESS-1 scale 2` mid-run. All four modes exit `0`. The package's
`dub.sdl` (`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not
part of the pipeline.

---

## Sources

- [`./examples/f08-dpi-scaling/app.d`][f08-app] — the demo (all log excerpts above)
- [F08 spec][f08-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold], [F02 resize findings][f02-doc] — baseline pump,
  DIB-realloc path
- [`SetProcessDpiAwarenessContext`][setprocessdpiawarenesscontext],
  [`SetThreadDpiAwarenessContext`][setthreaddpictx],
  [`GetWindowDpiAwarenessContext`][getwindowdpictx],
  [`AreDpiAwarenessContextsEqual`][aredpiequal], [`GetDpiForWindow`][getdpiforwindow],
  [`GetDpiForSystem`][getdpiforsystem], [`GetSystemDpiForProcess`][getsystemdpiforprocess],
  [`DPI_AWARENESS_CONTEXT`][dpi-awareness-context], [`WM_DPICHANGED`][wm-dpichanged],
  [`WM_GETDPISCALEDSIZE`][wm-getdpiscaledsize], [`SetWindowPos`][setwindowpos],
  [Setting the default DPI awareness for a process][setting-default-dpi],
  [High DPI desktop application development on Windows][high-dpi-overview] —
  Microsoft Learn (Wayback-pinned)

<!-- References -->

[f08-app]: ./examples/f08-dpi-scaling/app.d
[f08-spec]: ../features/f08-dpi-scaling.md
[scaffold]: ./scaffold.md
[f02-doc]: ./f02-resize.md
[manual-queue]: ../manual-run-queue.md
[setprocessdpiawarenesscontext]: https://web.archive.org/web/20260426012553/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocessdpiawarenesscontext
[setthreaddpictx]: https://web.archive.org/web/20260405053528/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext
[getwindowdpictx]: https://web.archive.org/web/20250819230625/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowdpiawarenesscontext
[aredpiequal]: https://web.archive.org/web/20250819224636/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-aredpiawarenesscontextsequal
[getdpiforwindow]: https://web.archive.org/web/20260307012320/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow
[getdpiforsystem]: https://web.archive.org/web/20251213073130/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforsystem
[getsystemdpiforprocess]: https://web.archive.org/web/20250819221629/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemdpiforprocess
[dpi-awareness-context]: https://web.archive.org/web/20260405053528/https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context
[wm-dpichanged]: https://web.archive.org/web/20260428034332/https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[wm-getdpiscaledsize]: https://web.archive.org/web/20251203200824/https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-getdpiscaledsize
[setwindowpos]: https://web.archive.org/web/20260331132945/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
[setting-default-dpi]: https://web.archive.org/web/20260408104354/https://learn.microsoft.com/en-us/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process
[high-dpi-overview]: https://web.archive.org/web/20260602171007/https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
