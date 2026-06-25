# Win32 — F11: Scroll fidelity

Findings from [`./examples/f11-scroll/app.d`][f11-app], the Win32 implementation of the
[F11 spec][f11-spec]: [`WM_MOUSEWHEEL`][wm-mousewheel] / [`WM_MOUSEHWHEEL`][wm-mousehwheel]
raw `wheelDelta` logging, the **accumulation contract proven against the truncation bug**
(a side-by-side carry-the-remainder vs truncate-per-event model, with `WSI_TRUNCATE=1`
letting the buggy model drive a visible ruler), and a wheel-routing probe. Headline
numbers: three injected `+40` sub-detent events produced **1 detent with the accumulator
and 0 with truncation** (`lost_by_truncation=1`); a `+40/−40/+40` jitter burst correctly
produced **zero** lines while keeping `acc_left=40`; and Wine routes the wheel to the
**window under the cursor**, not the focus window — while reporting
`SPI_GETMOUSEWHEELROUTING` as unsupported.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 with the exe
> cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Two runs:
> **winex11** under `xvfb-run` (`WAYLAND_DISPLAY` unset, private `XDG_RUNTIME_DIR`) and
> **winewayland on a headless sway** (the [F08][f08-doc] `WLR_BACKENDS=headless` setup;
> no live `wayland-0` session was available this session) — identical gesture results,
> identical routing. All gestures are injected via [`SendInput`][sendinput]
> `MOUSEEVENTF_WHEEL`/`MOUSEEVENTF_HWHEEL`, so this is the message plumbing only; a real
> precision touchpad (genuine sub-detents, inertia) rides the
> [manual-run queue][manual-queue].

---

## The demo

The scaffold window renders a scrollable ruler (a tick row per line, bright major row
every 5 lines) driven by the vertical detent stream; a second window sits beside it for
the routing probe. Every wheel message logs the raw signed delta plus both models' state;
`gesture_summary` lines diff them per gesture. `WSI_AUTO_EXIT=1` injects eight gestures
(~1.1 s) and exits `0`.

System parameters (both drivers): `wheel_params scroll_lines=3 ok=1 scroll_chars=3 ok=1
wheel_delta=120` — [`SystemParametersInfoW`][systemparametersinfo]
`SPI_GETWHEELSCROLLLINES`/`SPI_GETWHEELSCROLLCHARS` both 3, so one 120-delta detent is a
3-line scroll. The conversion every app owns: `lines = detents × scroll_lines`, where
`WHEEL_DELTA = 120` is "the threshold for action to be taken" ([`WM_MOUSEWHEEL`][wm-mousewheel]).

---

## wheelDelta arrives verbatim — `A[wine]`

The injected `mouseData` reached the handler unmodified in every case — `±120`, `±40`,
`+360` — on both axes and both drivers; no ballistics, no coalescing at this rate
(unlike the F10 pointer deltas, which Wine accelerates):

```text
80861 inject axis=v data=120
81221 scroll axis=v value=120 target=main screen=260,300 keys=0x0 acc=0 detents=1 trunc_detents=1
81685 ruler scroll lines=3 pos_line=3
528426 inject axis=v data=360
528789 scroll axis=v value=360 target=main screen=260,300 keys=0x0 acc=0 detents=3 trunc_detents=3
529353 ruler scroll lines=9 pos_line=9
```

Notes a binding must encode: the delta is **signed, positive = away from the user**, and
extracted with `GET_WHEEL_DELTA_WPARAM` (the low word of `wParam` is the key-state mask,
logged as `keys=`); the `lParam` coordinates are **screen**, not client, coordinates
("relative to the upper-left corner of the screen" — [`WM_MOUSEWHEEL`][wm-mousewheel]);
a single event may carry **multiple detents** (`+360` → `detents=3`, one message); and
an app that handles `WM_MOUSEHWHEEL` "should return zero" ([`WM_MOUSEHWHEEL`][wm-mousehwheel]).

---

## The accumulation contract, proven — `A[wine]`

The contract, verbatim: finer-resolution wheels "send more messages per rotation, but
with a smaller value in each message", and the app should "add the incoming delta values
until WHEEL_DELTA is reached" ([`WM_MOUSEWHEEL`][wm-mousewheel]). The demo runs both
models on every event — `acc` carries the sub-120 remainder; `trunc_detents` is
`delta / 120` per event in isolation:

```text
272687 scroll axis=v value=40 … acc=40 detents=0 trunc_detents=0
273164 scroll axis=v value=40 … acc=80 detents=0 trunc_detents=0
273649 scroll axis=v value=40 … acc=0 detents=1 trunc_detents=0
274090 ruler scroll lines=3 pos_line=3
368263 gesture_summary name=sub_detent_x3 … delta_total=120 detents=1 trunc_detents=0 acc_left=0 lost_by_truncation=1
```

- **Truncation silently eats sub-detent scrolling.** Three `+40` events are exactly one
  detent of physical motion; the accumulator delivers it, truncation delivers nothing —
  on a real precision touchpad (a stream of small deltas) a truncating app simply does
  not scroll. With `WSI_TRUNCATE=1` driving the ruler, both `sub_detent_x3` gestures
  produced **zero** `ruler` lines (the ruler jumped `3 → 0 → 9` instead of
  `3 → 0 → 3 → 0 → 9`).
- **Jitter must cancel, not round.** `+40/−40/+40` → `detents=0`, `acc_left=40` — no
  line emitted, no motion lost. Per-event rounding (instead of truncation) would emit
  spurious ±1 detents here; the carry handles it for free because the remainder keeps
  its sign (`-40` after `+40` returns `acc` to 0).
- **Truncation can also _over_-scroll:** the horizontal gesture `+120, −40, −40, −40`
  is physically net-zero; the accumulator ends at `detents=0`, but truncation keeps the
  `+120` and drops the three `−40`s — `trunc_detents=1`, a phantom scroll
  (`lost_by_truncation=-1`).
- Run totals (both drivers, both runs): `summary v_detents=4 v_trunc_detents=4 v_acc=40
h_detents=0 h_trunc_detents=1 h_acc=0 ruler_pos_line=9` — the models agree only
  because the schedule's full detents dominate; every sub-detent gesture diverged.

---

## Routing: focus vs window-under-cursor — `A[wine]`

With focus on the main window and the cursor parked over the second window, one detent
was injected:

```text
723 wheel_routing spi=0x201C ok=0 value=57005 err=1439
880368 routing_probe focus=main cursor_over=other requested=570,60 actual=570,60
911969 inject axis=v data=120
912365 scroll axis=v value=120 target=other screen=570,60 keys=0x0 acc=40 detents=1 trunc_detents=1
```

- **The wheel went to the window under the cursor**, not the focus window — on both
  drivers. That matches the Windows 10+ default ("scroll inactive windows",
  `MOUSEWHEEL_ROUTING_MOUSE_POS`) even though Wine 10.0 doesn't implement the query:
  `SPI_GETMOUSEWHEELROUTING` fails with error 1439 (`ERROR_INVALID_SPI_VALUE`) and the
  out-value is untouched (`0xdead`). `A[wine]` — apps cannot introspect the routing mode
  under Wine; real-Windows verification of the three SPI values is queued.
- Consequence for frameworks: wheel events can target an **unfocused** window, so scroll
  handling must not assume keyboard focus, and hover state — not focus — selects the
  scroll target.

---

## Momentum does not exist at this level — Tier C

Nothing in the `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` stream marks gesture phases: no
begin/end, no fling, no `axis_stop` analogue (contrast Wayland's `axis_source`/`axis_stop`
and AppKit's `momentumPhase`). A Windows precision touchpad delivers inertial scrolling
as a decaying stream of ordinary small-delta wheel messages — indistinguishable from a
slow finger; the only phase-aware path is [Direct Manipulation][directmanip], the
COM-based touch/touchpad pipeline (Windows 8+) that modern apps adopt for inertia and
pixel-precise pan — deliberately out of scope for this message-level demo. Real-touchpad
capture (delta sizes, message rate, inertia tail) is queued as Tier C in the
[manual-run queue][manual-queue].

---

## Surprises

- **Truncation has two failure modes, not one** — it loses sub-detent motion _and_
  fabricates net motion on direction-mixed gestures (the horizontal `+1` phantom detent).
  Only the signed carry gets both right.
- **`SPI_GETMOUSEWHEELROUTING` fails while the behavior it describes works:** Wine
  routes by cursor position but errors on the query — feature-detection by SPI probe
  would wrongly conclude "focus routing".
- **Wheel coordinates are screen coordinates** while every other client-area mouse
  message uses client coordinates — a classic conversion bug ambush
  (`ScreenToClient` required before hit-testing).
- **One message can be three detents** (`+360` → `detents=3`): per-message
  "scroll one increment" logic under-scrolls on fast wheels.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f11-scroll/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f11-scroll.exe

# winex11 under Xvfb (WAYLAND_DISPLAY unset, private XDG_RUNTIME_DIR)
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) WINEPREFIX=$(mktemp -d) \
    WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    xvfb-run -a nix develop .#win32 -c wine64 ./build/f11-scroll.exe

# winewayland on a headless sway (see the F08 findings for the sway setup)
env -u DISPLAY WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=<sway runtime dir> \
    WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f11-scroll.exe
```

Add `WSI_TRUNCATE=1` to make the buggy truncation model drive the ruler (the sub-detent
gestures visibly stop scrolling). All modes exit `0`; one winex11 run printed a
`double free or corruption` from Wine's teardown _after_ the demo's `exit code=0` line —
log consumers should treat post-exit stderr as noise. Without `WSI_AUTO_EXIT=1` the demo
runs until closed and a real wheel/touchpad can drive the ruler. The package's `dub.sdl`
(`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not part of
the pipeline.

---

## Sources

- [`./examples/f11-scroll/app.d`][f11-app] — the demo (all log excerpts above)
- [F11 spec][f11-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold], [F08 DPI findings][f08-doc]
- [`WM_MOUSEWHEEL`][wm-mousewheel], [`WM_MOUSEHWHEEL`][wm-mousehwheel],
  [`SendInput`][sendinput], [`SystemParametersInfoW`][systemparametersinfo],
  [About mouse input][about-mouse-input], [Direct Manipulation][directmanip] —
  Microsoft Learn (Wayback-pinned)

<!-- References -->

[f11-app]: ./examples/f11-scroll/app.d
[f11-spec]: ../features/f11-scroll.md
[scaffold]: ./scaffold.md
[f08-doc]: ./f08-dpi-scaling.md
[manual-queue]: ../manual-run-queue.md
[wm-mousewheel]: https://web.archive.org/web/20260609095045/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel
[wm-mousehwheel]: https://web.archive.org/web/20250113154445/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel
[sendinput]: https://web.archive.org/web/20260518160717/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
[systemparametersinfo]: https://web.archive.org/web/20260327035133/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow
[about-mouse-input]: https://web.archive.org/web/20250108234745/https://learn.microsoft.com/en-us/windows/win32/inputdev/about-mouse-input
[directmanip]: https://web.archive.org/web/20230225162149/https://learn.microsoft.com/en-us/windows/win32/directmanipulation/direct-manipulation-portal
