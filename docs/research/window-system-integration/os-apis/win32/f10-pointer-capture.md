# Win32 — F10: Pointer — relative motion, lock & confine

Findings from [`./examples/f10-pointer-capture/app.d`][f10-app], the Win32 implementation
of the [F10 spec][f10-spec]: raw deltas via [`RegisterRawInputDevices`][regrawinput] +
[`WM_INPUT`][wm-input] diffed against the cooked `WM_MOUSEMOVE` stream for the _same_
injected motion, the classic lock assembly ([`ClipCursor`][clipcursor] to a 1×1 rect +
[`ShowCursor`][showcursor]`(FALSE)`), and confine-to-rect with clamping proofs. Two
headline answers: **Wine's "raw" stream is not raw** — a `SendInput` move of `dx=16`
arrived in `WM_INPUT` as `dx=32`, i.e. pointer ballistics are applied _before_ the raw
tee, the opposite of documented Windows behavior — and the **lock idiom holds**: with the
1×1 clip the cursor never left the pin while relative deltas kept flowing, and unlock
restored the saved position exactly.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 with the exe
> cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Two runs:
> **winex11** under `xvfb-run` (`WAYLAND_DISPLAY` unset, private `XDG_RUNTIME_DIR`;
> 640×480) and **winewayland on a headless sway** (the [F08][f08-doc]
> `WLR_BACKENDS=headless` setup; 1280×720 — no live `wayland-0` session was available
> this session). Lock/confine/restore results were identical; the drivers diverge only
> in which `WM_INPUT` events a warp produces (below). All motion is injected in-process
> (`SetCursorPos` / `SendInput` / `mouse_event`); real-hardware feel rides the
> [manual-run queue][manual-queue].

---

## The demo

The scaffold window plus: a `WM_INPUT` handler logging every `RAWMOUSE` (`lLastX/lLastY`,
`usFlags`, buttons), a `WM_MOUSEMOVE` handler logging the cooked position, and a
`WSI_AUTO_EXIT=1` schedule (~2 s, exit `0`) that walks five phases: an absolute
`SetCursorPos` tour, a relative-injection comparison, a lock/unlock cycle driving a
crosshair from the accumulated raw deltas, confine clamping probes, and clip auto-clear
probes. Interactively, `L` toggles mouselook and `C` toggles confine.

Registration succeeded on both drivers and read back intact via
`GetRegisteredRawInputDevices`:

```text
12075 raw_register usage=1:2 flags=RIDEV_INPUTSINK ok=1 err=0
12393 raw_register_readback count=1 flags=0x100 target=000000000002006C
```

---

## Raw vs cooked: which flag arrives, and who produces events — `A[wine]`

Every single `WM_INPUT` mouse event in both runs carried `usFlags=0x0` —
**`MOUSE_MOVE_RELATIVE`, always** ([`RAWMOUSE`][rawmouse]: "mouse movement data is
relative to the last mouse position"). No injection method — `SetCursorPos`,
`SendInput MOUSEEVENTF_MOVE`, `mouse_event` — ever produced `MOUSE_MOVE_ABSOLUTE` under
Wine 10.0. (On real Windows, absolute injection and tablets/RDP do produce
`MOUSE_MOVE_ABSOLUTE`; queued for real hardware.)

The drivers disagree about _warps_:

- **winex11:** every `SetCursorPos` warp produced a `WM_MOUSEMOVE` **plus** a null
  `WM_INPUT` (`dx=0 dy=0 flags=0x0`) — a raw event that carries no motion. Run summary:
  `wm_mousemove=19 wm_input=20`.
- **winewayland:** warps produced **no `WM_INPUT` at all**; only `SendInput`/`mouse_event`
  relative injection reached the raw stream. Run summary: `wm_mousemove=19 wm_input=8`.

Consumers must therefore not assume a 1:1 raw/cooked pairing, and must treat zero-delta
raw events as no-ops.

---

## The same injection on both streams: ballistics — `A[wine]`

Accel state at startup (both drivers): `accel_state spi_getmouse=6,10,1 ok=1 speed=10 ok=1`
— the classic two-threshold ballistics ([`SystemParametersInfoW`][systemparametersinfo]
`SPI_GETMOUSE`: thresholds 6 and 10, acceleration level 1) at default pointer speed 10.
Phase B injects identical relative moves and watches both streams:

```text
400843 inject method=SendInput kind=rel dx=16 dy=8
401291 pointer rel dx=32 dy=16 raw=1 flags=0x0 mode=relative buttons=0x0
401799 pointer abs x=346 y=345 raw=0          ← previous x=314: also moved +32
592410 inject method=mouse_event kind=rel dx=-16 dy=-8
592879 pointer rel dx=-32 dy=-16 raw=1 flags=0x0 mode=relative buttons=0x0
```

- **Wine applies ballistics _before_ the raw tee.** Injected `16` arrived as `32` in
  `WM_INPUT` — and `WM_MOUSEMOVE` moved by the same 32 px. The doubling follows the
  level-1 accel rule per axis (`|d| > threshold₁ = 6` → ×2): `7,-3` → `14,-3`;
  `40,0` → `80,0`; `-13,22` → `-26,44`. This is **the opposite of the documented Windows
  contract** — "WM*INPUT has no ballistics applied to its data" while `WM_MOUSEMOVE` is
  where "Windows applies pointer acceleration (also known as ballistics)"
  ([Taking advantage of high-definition mouse movement][highdef-mouse]). `A[wine]`:
  under Wine, raw and cooked report the \_same* accelerated motion, so the
  raw-vs-cooked divergence that the comparison was built to capture **cannot manifest
  here** — the real-Windows run is queued.
- `mouse_event` behaves exactly like `SendInput` (it is the legacy wrapper —
  [`mouse_event`][mouse-event] says use `SendInput` instead).

---

## Lock: `ClipCursor(1×1)` + `ShowCursor(FALSE)` — `A[wine]`

Win32 has no atomic pointer lock; the demo assembles it and proves each part:

```text
720990 lock state=on pin=418,459 saved=418,459 showcursor=-1
721387 lock clip_readback=418,459-419,460
784763 inject method=SendInput kind=rel dx=7 dy=-3
785227 pointer rel dx=14 dy=-3 raw=1 flags=0x0 mode=relative buttons=0x0
785632 mouselook yaw=14 pitch=-3
785876 pointer abs x=314 y=329 raw=0           ← client coords of the pin: unmoved
976431 locked_cursor x=418 y=459 pin=418,459 yaw=68 pitch=41
1040358 lock state=off showcursor=0 restored_to=418,459 actual=418,459
1040872 unlock clip_readback=0,0-1280,720
```

- **The pin holds and deltas keep flowing.** Three relative injections while locked all
  arrived as `WM_INPUT` deltas (accelerated, per the previous section) and drove the
  crosshair (`yaw=68 pitch=41`), while `GetCursorPos` stayed at the pin and the cooked
  `WM_MOUSEMOVE` never moved. [`GetClipCursor`][getclipcursor] read back the exact 1×1
  rect (`right`/`bottom` exclusive: `418,459-419,460`).
- **`ShowCursor` is a counter, not a flag** — "[t]his function sets an internal display
  counter … [t]he cursor is displayed only if the display count is greater than or equal
  to 0" ([`ShowCursor`][showcursor]). Probed explicitly at startup:
  `showcursor_probe hide1=-1 hide2=-2 show1=-1 show2=0` — two `FALSE` need two `TRUE`,
  and a framework that hides on lock must restore _symmetrically_ or the cursor stays
  invisible app-wide.
- **Restore is exact.** Unlock = `ClipCursor(null)` → `ShowCursor(TRUE)` →
  [`SetCursorPos`][setcursorpos] to the position saved at lock time;
  [`GetCursorPos`][getcursorpos] confirmed `actual == restored_to` on both drivers.
- **winewayland maps the clip to Wayland pointer constraints — and trips on it.** The
  moment the 1×1 clip was set, Wine printed
  `Error marshalling request for zwp_pointer_constraints_v1.lock_pointer: Invalid
argument` (`null value passed for arg 2`) on stderr — yet the wineserver-side clip
  still worked (pin held, clamps applied). `A[wine]`, Wine 10.0 bug: the logical clip
  state and the compositor-side constraint are separate layers, and the second can fail
  without the first noticing.

One-liner: [`SetCapture`][setcapture] is **routing, not confinement** — it redirects
mouse _messages_ to a window during a drag; the cursor itself keeps moving anywhere on
screen. Only `ClipCursor` constrains the cursor.

---

## Confine: clamping proven — `A[wine]`

Phase D clips to the center half of the window and probes from inside, outside, and via a
huge relative move (winex11 run; winewayland identical modulo geometry):

```text
1137436 confine rect=222,201-458,344
1137690 confine clip_readback=222,201-458,344
1201015 confine_probe target=inside requested=340,272 actual=340,272 clamped=0
1265265 confine_probe target=window_corner requested=104,130 actual=222,201 clamped=1
1329372 confine_probe target=screen_origin requested=0,0 actual=222,201 clamped=1
1393012 inject method=SendInput kind=rel dx=2000 dy=2000
1425461 confine_probe target=rel_2000 actual=457,343
```

- Requests inside the rect are granted verbatim; outside requests clamp to the nearest
  edge (`screen_origin` → `left,top`); a +2000,+2000 relative move lands on
  `right-1,bottom-1` — the rect's exclusive edges, consistent with the `GetClipCursor`
  read-back. The cooked `WM_MOUSEMOVE` stream reports only clamped positions.

### What clears a clip

The headless-reachable probes both came back **negative under Wine**: after
`SetForegroundWindow(other)` (focus to a second window, `WM_KILLFOCUS` confirmed) and
after `ShowWindow(SW_MINIMIZE)`, `GetClipCursor` still read the confine rect:

```text
1553149 after_focus_loss clip_readback=222,201-458,344
1681162 after_minimize clip_readback=222,201-458,344
```

That matches the letter of the docs — `ClipCursor` documents **no** same-process
auto-clear; what it documents is the obligation: "The cursor is a shared resource. If an
application confines the cursor, it must release the cursor by using ClipCursor before
relinquishing control to another application" ([`ClipCursor`][clipcursor]). On real
Windows the system _does_ drop the clip in cases unreachable headless — switching to
another application/desktop (Alt-Tab, Ctrl-Alt-Del, UAC secure desktop), which is why
games re-apply the clip on every `WM_ACTIVATE`. Queued for real hardware. Practical
consequence either way: **treat `ClipCursor` as volatile global state** — re-assert on
activation, always `ClipCursor(null)` on deactivate/teardown (the demo does it in
`WM_DESTROY`).

---

## Surprises

- **Raw isn't raw under Wine** — `WM_INPUT` deltas arrive post-ballistics (×2 above
  threshold), identical to the cooked stream. A mouselook implementation calibrated under
  Wine will feel twice as fast as on Windows for the same physical motion.
- **A Wayland protocol error that doesn't break anything:** winewayland's
  `lock_pointer` marshalling failure left the logical clip fully functional.
- **Warps tee into the raw stream on winex11 but not winewayland**, and on winex11 they
  arrive as _zero-delta_ relative events — three driver-specific shapes for one API call.
- **Focus loss does not clear `ClipCursor`** (same process): a second window taking
  foreground and even minimizing the clipping window left the clip active — under Wine
  the cursor of an unfocused, minimized app still imprisons the user's pointer. Hygiene
  is entirely the app's job.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f10-pointer-capture/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f10-pointer.exe

# winex11 under Xvfb (WAYLAND_DISPLAY unset, private XDG_RUNTIME_DIR)
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) WINEPREFIX=$(mktemp -d) \
    WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    xvfb-run -a nix develop .#win32 -c wine64 ./build/f10-pointer.exe

# winewayland on a headless sway (see the F08 findings for the sway setup)
env -u DISPLAY WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=<sway runtime dir> \
    WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f10-pointer.exe
```

Both modes exit `0`. With no display server at all, `CreateWindowExW` fails with error
1400 (see [scaffold][scaffold]). Without `WSI_AUTO_EXIT=1` the demo runs until closed:
`L` toggles mouselook (yellow crosshair driven by raw deltas), `C` toggles confine (cyan
rect). The package's `dub.sdl` (`platforms "windows"`) exists for the Windows CI runner;
locally `dub` is not part of the pipeline.

---

## Sources

- [`./examples/f10-pointer-capture/app.d`][f10-app] — the demo (all log excerpts above)
- [F10 spec][f10-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold], [F08 DPI findings][f08-doc]
- [`RegisterRawInputDevices`][regrawinput], [`WM_INPUT`][wm-input],
  [`GetRawInputData`][getrawinputdata], [`RAWMOUSE`][rawmouse],
  [Raw input overview][rawinput],
  [Taking advantage of high-definition mouse movement][highdef-mouse],
  [`ClipCursor`][clipcursor], [`GetClipCursor`][getclipcursor],
  [`ShowCursor`][showcursor], [`SetCursorPos`][setcursorpos],
  [`GetCursorPos`][getcursorpos], [`SetCapture`][setcapture],
  [`SendInput`][sendinput], [`mouse_event`][mouse-event],
  [`SystemParametersInfoW`][systemparametersinfo] — Microsoft Learn (Wayback-pinned)

<!-- References -->

[f10-app]: ./examples/f10-pointer-capture/app.d
[f10-spec]: ../features/f10-pointer-capture.md
[scaffold]: ./scaffold.md
[f08-doc]: ./f08-dpi-scaling.md
[manual-queue]: ../manual-run-queue.md
[regrawinput]: https://web.archive.org/web/20260306223227/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerrawinputdevices
[wm-input]: https://web.archive.org/web/20250108204157/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-input
[getrawinputdata]: https://web.archive.org/web/20260227023243/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getrawinputdata
[rawmouse]: https://web.archive.org/web/20250212174308/https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-rawmouse
[rawinput]: https://web.archive.org/web/20260421141757/https://learn.microsoft.com/en-us/windows/win32/inputdev/raw-input
[highdef-mouse]: https://web.archive.org/web/20250724231155/https://learn.microsoft.com/en-us/windows/win32/dxtecharts/taking-advantage-of-high-dpi-mouse-movement
[clipcursor]: https://web.archive.org/web/20250201095242/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-clipcursor
[getclipcursor]: https://web.archive.org/web/20250126180850/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclipcursor
[showcursor]: https://web.archive.org/web/20250201095242/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showcursor
[setcursorpos]: https://web.archive.org/web/20260427173424/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcursorpos
[getcursorpos]: https://web.archive.org/web/20250108125624/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getcursorpos
[setcapture]: https://web.archive.org/web/20250130150837/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcapture
[sendinput]: https://web.archive.org/web/20260518160717/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
[mouse-event]: https://web.archive.org/web/20250108132113/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mouse_event
[systemparametersinfo]: https://web.archive.org/web/20260327035133/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow
