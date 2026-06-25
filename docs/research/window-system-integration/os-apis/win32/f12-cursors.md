# Win32 — F12: Cursors

Findings from [`./examples/f12-cursors/app.d`][f12-app], the Win32 implementation of the
[F12 spec][f12-spec]: a 3×3 hover-zone grid answered from [`WM_SETCURSOR`][wm-setcursor]
with [`SetCursor`][setcursor] ([`LoadCursorW`][loadcursorw] system shapes + one custom ARGB
bullseye from [`CreateIconIndirect`][createiconindirect]), a 12-stop
[`SetCursorPos`][setcursorpos] tour that drives the `WM_MOUSEMOVE` → `WM_SETCURSOR`
cascade from inside the demo, and a class-cursor precedence probe. Two headline answers:
Win32's resize vocabulary is **four bidirectional shapes for eight edges**
(`IDC_SIZENWSE`/`NESW`/`WE`/`NS` — no per-edge cursors), and in the precedence probe the
**class cursor wins** whenever `WM_SETCURSOR` falls through to `DefWindowProcW` — a
`SetCursor` immediately before the fall-through is silently overwritten.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 with the exe
> cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Two runs:
> **winewayland** against the live `wayland-0` session and **winex11** under `xvfb-run`
> (`WAYLAND_DISPLAY` unset, private `XDG_RUNTIME_DIR`); both produced identical zone,
> storm, and precedence results. Cursor _requests_ are what the log proves; the rendered
> pixels (who composites the cursor) need eyes — the visual pass rides the
> [manual-run queue][manual-queue].

---

## The demo

The client area is a 3×3 grid: the 8 border cells map the 8 resize edges onto the 4
resize shapes, and the center cell is subdivided 2×2 into `IDC_ARROW` / `IDC_IBEAM` /
`IDC_HAND` / the custom bullseye. The window class registers `hCursor = IDC_CROSS` as the
precedence-probe foil. A `WSI_AUTO_EXIT=1` run (~2 s) executes the 12-stop tour, then the
precedence phases, then exits `0`.

All 9 cursors loaded successfully in both runs (`cursor_loaded … handle=…` for the 7
`IDC_*` shapes, `IDC_CROSS`, and the `CreateIconIndirect` bullseye);
`GetSystemMetrics(SM_CXCURSOR/SM_CYCURSOR)` answered **32×32** — the "nominal width of a
cursor, in pixels" ([`GetSystemMetrics`][getsystemmetrics]).

---

## Driving the pointer without a hand — `A[wine]`

winewayland offers no external warp tool, but [`SetCursorPos`][setcursorpos] — "[m]oves
the cursor to the specified screen coordinates" — goes through wineserver's virtual
cursor and works from inside the demo; each warp produced exactly one `WM_MOUSEMOVE`
whose `DefWindowProcW` pass generated exactly one `WM_SETCURSOR`:

```text
115924 tour_warp zone=nw client=78,47 screen=82,77
116040 wm_setcursor n=1 hittest=1 trigger=0x200 phase=normal
116108 cursor_set name=IDC_SIZENWSE zone=nw
...
499817 tour_warp zone=se client=393,238 screen=397,268
499968 cursor_set name=IDC_SIZENWSE zone=se        ← same shape as nw: 4 shapes, 8 edges
...
980028 tour_warp zone=c_ibeam client=267,123 screen=271,153
980170 cursor_set name=IDC_IBEAM zone=c_ibeam
1171599 cursor_set name=custom_bullseye zone=c_custom
1460289 summary wm_setcursor=15 wm_mousemove=15
```

- **The storm is 1:1 with mouse movement.** `summary wm_setcursor=15 wm_mousemove=15`
  (16/16 in the X11 run, which gets one extra pair because Xvfb's pointer starts over the
  window — first `cursor_set … zone=se` before any warp). Every `WM_SETCURSOR` carried
  `hittest=1` (`HTCLIENT`) and `trigger=0x200` (`WM_MOUSEMOVE`) — the message is per-move,
  not per-zone-change, so a real interactive drag re-answers it continuously and the
  handler must be cheap and idempotent. The demo resolves the zone and calls `SetCursor`
  on **every** message, logging `cursor_set` only on zone change.
- **The shape vocabulary:** the 8 edge stops resolved to only 4 distinct shapes —
  `nw`/`se` → `IDC_SIZENWSE`, `ne`/`sw` → `IDC_SIZENESW`, `w`/`e` → `IDC_SIZEWE`,
  `n`/`s` → `IDC_SIZENS`. Win32 has no per-edge resize cursors (contrast Wayland's
  `cursor-shape-v1` with its eight directional `*_resize` names); a cross-platform shape
  enum must fold pairs when targeting Win32.

---

## Precedence: who sets the cursor — `A[wine]`

The contract under test, verbatim: "The `DefWindowProc` function also uses this message to
set the cursor to an arrow if it is not in the client area, or to the registered class
cursor if it is in the client area" ([`WM_SETCURSOR`][wm-setcursor]). Three phases, each
ending with a fresh warp to force a `WM_SETCURSOR` and a [`GetCursor`][getcursor] sample
a few timer ticks later:

```text
1267843 cursor_set name=IDC_HAND zone=probe then=DefWindowProcW
1331655 precedence_result phase=set_then_def cursor_after=IDC_CROSS
1395545 precedence_result phase=class_only  cursor_after=IDC_CROSS
1459597 precedence_result phase=normal      cursor_after=IDC_HAND
```

- **`SetCursor` then `DefWindowProcW`: the class cursor wins.** The hand was set and then
  silently replaced by `IDC_CROSS` inside the same message — `DefWindowProcW` re-applies
  the class cursor unconditionally for `HTCLIENT`. Code that "sets the cursor and returns
  whatever" flickers or loses; the _only_ correct shape is `SetCursor` + **return `TRUE`
  without calling `DefWindowProc`** (the `phase=normal` row, where `IDC_HAND` survived).
- Equivalently: a non-null class `hCursor` and a `WM_SETCURSOR` handler are mutually
  exclusive strategies. Bindings that switch cursors at runtime should register
  `hCursor = null`-or-arrow and own `WM_SETCURSOR`; the class cursor is the static-app
  convenience.
- [`SetSystemCursor`][setsystemcursor] (replacing a _system_ cursor image machine-wide) is
  deliberately not exercised — it mutates host-global state.

---

## Custom, animated, and DPI — `A[wine]`

- **Custom ARGB cursor:** a 32×32 bullseye with hotspot `(16,16)` built from a 32bpp
  top-down DIB ([`CreateDIBSection`][scaffold]) plus an all-zero monochrome mask, through
  [`CreateIconIndirect`][createiconindirect] with [`ICONINFO`][iconinfo]`.fIcon=FALSE` —
  "[a] value of TRUE specifies an icon; FALSE specifies a cursor", and only cursors honor
  the hotspot fields. Creation succeeded and the `c_custom` zone set it like any system
  shape. One-liner on the legacy API: [`CreateCursor`][createcursor] takes only monochrome
  AND/XOR bit planes — alpha-blended cursors require the `CreateIconIndirect` (or
  `LoadIconWithScaleDown`-era) path.
- **Animated cursors: absent under Wine.** [`LoadCursorFromFileW`][loadcursorfromfilew]
  ("[t]he data in the file must be in either .CUR or .ANI format") on
  `C:\windows\cursors\aero_busy.ani` failed with `err=3` (`ERROR_PATH_NOT_FOUND`), and a
  host-side `find` over the fresh prefix's `drive_c/windows` found **no `.ani`, no
  `.cur`, not even a `cursors\` directory** — Wine prefixes ship no cursor files at all;
  Wine's system cursors come from the host theme via the display driver. The `.ani` code
  path is therefore Windows-only territory (Tier C).
- **DPI:** `SM_CXCURSOR/SM_CYCURSOR` report 32×32 — a _nominal_ size. On Windows 10+ the
  effective cursor size follows the system cursor-size accessibility setting and per-monitor
  DPI scaling of the cursor image is done by the system when the cursor was loaded with
  the right metrics (`LoadCursorW` resources carry multiple sizes; see
  [About cursors][about-cursors]); there is **no per-window cursor-size API**, and under
  Wine at 96 DPI nothing scale-dependent was observable. Live mixed-DPI behavior
  (does the arrow grow on the 150 % monitor?) is unreachable here — Tier C, with the
  [F08][f08-doc] caveat that Wine never varies DPI per monitor anyway.

---

## Surprises

- **`DefWindowProcW` overwrites a just-set cursor** (`set_then_def` → `IDC_CROSS`): the
  class cursor is not a fallback, it is an _unconditional re-application_ — the
  return-`TRUE` discipline is load-bearing, and a binding cannot mix "class cursor for
  most windows" with "occasionally `SetCursor` in the handler" on the same class.
- **`WM_SETCURSOR` does not exist without mouse messages.** Changing `g.phase` did
  nothing until the next warp generated a `WM_MOUSEMOVE`; an app that changes its desired
  cursor while the mouse is still must re-trigger (the idiomatic poke is
  `SetCursorPos(GetCursorPos())` or posting a synthetic `WM_MOUSEMOVE`, which
  `DefWindowProcW` converts into a fresh `WM_SETCURSOR`).
- **A Wine prefix has zero cursor _files_** — `LoadCursorW(null, IDC_*)` succeeds for the
  whole standard vocabulary while `C:\windows\cursors` doesn't exist; system-shape loading
  and file loading are entirely separate plumbing under Wine (`A[wine]`).
- **Identical results under winewayland and winex11** — zone mapping, 1:1 storm ratio,
  precedence winners, custom-cursor creation, missing `.ani` — the cursor pipeline above
  the display driver is driver-independent in Wine 10.0.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f12-cursors/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f12-cursors.exe

# default (winewayland, live wayland-0)
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f12-cursors.exe

# winex11 under Xvfb (WAYLAND_DISPLAY unset, private XDG_RUNTIME_DIR)
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) WINEPREFIX=$(mktemp -d) \
    WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    xvfb-run -a nix develop .#win32 -c wine64 ./build/f12-cursors.exe
```

Both modes exit `0`. Without `WSI_AUTO_EXIT=1` the demo runs until closed and the grid can
be explored with a real mouse (the visual check queued as Tier C). The package's `dub.sdl`
(`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not part of the
pipeline.

---

## Sources

- [`./examples/f12-cursors/app.d`][f12-app] — the demo (all log excerpts above)
- [F12 spec][f12-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold], [F08 DPI findings][f08-doc]
- [`WM_SETCURSOR`][wm-setcursor], [`SetCursor`][setcursor], [`LoadCursorW`][loadcursorw],
  [`SetCursorPos`][setcursorpos], [`GetCursor`][getcursor],
  [`CreateIconIndirect`][createiconindirect], [`ICONINFO`][iconinfo],
  [`CreateCursor`][createcursor], [`LoadCursorFromFileW`][loadcursorfromfilew],
  [`SetSystemCursor`][setsystemcursor], [`GetSystemMetrics`][getsystemmetrics],
  [About cursors][about-cursors] — Microsoft Learn (Wayback-pinned)

<!-- References -->

[f12-app]: ./examples/f12-cursors/app.d
[f12-spec]: ../features/f12-cursors.md
[scaffold]: ./scaffold.md
[f08-doc]: ./f08-dpi-scaling.md
[manual-queue]: ../manual-run-queue.md
[wm-setcursor]: https://web.archive.org/web/20260516001653/https://learn.microsoft.com/en-us/windows/win32/menurc/wm-setcursor
[setcursor]: https://web.archive.org/web/20260427173423/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcursor
[loadcursorw]: https://web.archive.org/web/20260320234508/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadcursorw
[setcursorpos]: https://web.archive.org/web/20260427173424/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcursorpos
[getcursor]: https://web.archive.org/web/20250819222429/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getcursor
[createiconindirect]: https://web.archive.org/web/20260430182623/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createiconindirect
[iconinfo]: https://web.archive.org/web/20260430182623/https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-iconinfo
[createcursor]: https://web.archive.org/web/20260427173927/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createcursor
[loadcursorfromfilew]: https://web.archive.org/web/20250819224602/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadcursorfromfilew
[setsystemcursor]: https://web.archive.org/web/20260310010155/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setsystemcursor
[getsystemmetrics]: https://web.archive.org/web/20260609034441/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics
[about-cursors]: https://web.archive.org/web/20260427173423/https://learn.microsoft.com/en-us/windows/win32/menurc/about-cursors
