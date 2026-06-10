# Win32 F03 — modal-loop survival

What actually happens when a Win32 window enters the interactive size/move **modal loop** —
the headline pathology of the [F03 spec][f03] — measured, not assumed. The demo,
[`./examples/f03-modal-loop/app.d`](./examples/f03-modal-loop/app.d), extends the
[scaffold](./scaffold.md) with a ~2 Hz color-cycle animation driven from the **main loop
body** (the shape the modal loop starves), enters the loop **programmatically** via
[`SendMessage(WM_SYSCOMMAND, SC_SIZE | WMSZ_*, …)`][wm-syscommand] with a watchdog thread
feeding it synthetic input ([`SendInput`][sendinput] button-down/moves/button-up and posted
arrow keys), and measures the animation freeze with and without the survey-wide
countermeasure — [`SetTimer`][settimer] on [`WM_ENTERSIZEMOVE`][wm-entersizemove],
render from `WM_TIMER`, [`KillTimer`][settimer] on [`WM_EXITSIZEMOVE`][wm-exitsizemove]
(`WSI_MODAL_FIX=1`). Both modes run to exit `0` under Wine.

**Last reviewed:** June 10, 2026

> [!IMPORTANT]
> **Everything below is `A[wine]`** (Wine 10.0, LDC 1.41.0 cross-compile), and — a finding
> of this demo — **which Wine display driver loads changes the result entirely**:
>
> - **`winewayland`** (what the plain [scaffold pipeline](./scaffold.md#build--run--the-verified-awine-pipeline)
>   actually selects on this host: a live `$XDG_RUNTIME_DIR/wayland-0` socket exists, so the
>   X11 noise on stderr means the _x11_ driver failed, not that the run is driverless) —
>   the modal loop **never runs at all** (see [below](#driver-fork)).
> - **x11 driver on bare Xvfb** (`xvfb-run`, no WM) — Wine's **generic in-process modal
>   loop** runs, faithfully reproducing the Windows behavior. The freeze numbers come from
>   this configuration.
> - **No display at all** — `CreateWindowExW` fails with error `1400`: Wine's null driver
>   cannot create ordinary windows, so "headless Wine" always means _some_ real driver.
>
> Wine's generic loop is a reimplementation with at least one observable divergence
> (the [dispatch-break heuristic](#wine-vs-windows)); the Tier C manual run re-confirms
> the numbers on real Windows.

---

## The verdict lines

```text
# x11/Xvfb, no fix: the animation freezes for the whole drag
4710921 f03_modal_loop_win32 summary mode=nofix ticks=120 max_gap_us=1009597 attempts=3

# x11/Xvfb, WSI_MODAL_FIX=1: WM_TIMER ticks continue inside the modal loop
4652286 f03_modal_loop_win32 summary mode=fix   ticks=239 max_gap_us=620760  attempts=3

# winewayland: the modal loop never exists; the animation never freezes
1961142 f03_modal_loop_win32 summary mode=nofix ticks=120 max_gap_us=17292   attempts=3
```

The same binary, the same three programmatic drags: a **1.01 s** worst tick gap without the
countermeasure, ~16 ms in-modal ticks with it, and no modal loop at all when Wine delegates
to a Wayland compositor. The rest of this doc is the mechanics.

## Who pumps, and why `GetMessage` never returns to you

The demo's animation is deliberately driven from the loop body — drain
[`PeekMessageW`][getmessage], render one `tick`, wait on the queue with a 16 ms cap
(`MsgWaitForMultipleObjects`) — the shape of every game loop and of most toolkits'
"iterate" function. When the user grabs a title bar or border (or the demo sends the
equivalent `WM_SYSCOMMAND`), `DefWindowProcW` does not return:

> Sent one time to a window after it enters the moving or sizing modal loop. The window
> enters the moving or sizing modal loop when the user clicks the window's title bar or
> sizing border, or when the window passes the `WM_SYSCOMMAND` message to the
> `DefWindowProc` function and the `wParam` parameter of the message specifies the
> `SC_MOVE` or `SC_SIZE` value. The operation is complete when `DefWindowProc` returns.
>
> — [`WM_ENTERSIZEMOVE`][wm-entersizemove], Microsoft Learn

Inside that call the OS runs **its own** message pump. Wine's implementation
([`dlls/win32u/defwnd.c`, `sys_command_size_move`][wine-defwnd]) makes the mechanics
inspectable: a `for (;;)` loop calls `NtUserGetMessage` itself, consumes `WM_MOUSEMOVE` and
`WM_KEYDOWN` to drive the drag (sending [`WM_SIZING`][wm-sizing]/[`WM_MOVING`][wm-moving]
and `SetWindowPos` per step), **dispatches every other message** to the window procedures,
and exits on button-up / `VK_RETURN` / `VK_ESCAPE`. So:

- The application's own loop body is starved — it is parked inside `SendMessage`
  (interactively: inside `DispatchMessage` of a `WM_NCLBUTTONDOWN`) for the whole drag.
  The demo's `src=loop` ticks stop dead between `modal_enter` and `modal_exit`.
- The thread captured is **the window's thread**: anything that thread drives — timers
  consumed in the loop body, swap chains presented from it, the [F04][f04-doc] pacing
  loop — freezes with it. A framework whose API contract is "the app owns the loop"
  ([GLFW][glfw]'s documented position) cannot hide this.
- The OS pump **does dispatch queued messages** — `WM_TIMER` and `WM_PAINT` included —
  which is the load-bearing fact every countermeasure builds on.

## Programmatic entry — what worked

`SendMessage(hwnd, WM_SYSCOMMAND, SC_SIZE | WMSZ_BOTTOMRIGHT, MAKELPARAM(x, y))` is the
documented programmatic door into the loop (it is exactly what custom-chrome apps send from
`WM_NCLBUTTONDOWN`); `SC_MOVE | 2` (the `HTCAPTION` nibble) is the title-bar-drag variant,
and plain `SC_SIZE` is keyboard-mode sizing ("Size" in the system menu). Three lessons from
making them run unattended (`WSI_AUTO_EXIT=1`):

1. **The grab variants poll the real button state.** Wine's loop treats "any dispatched
   message while `VK_LBUTTON` is up" as a consumed button-up and exits
   ([`defwnd.c` line ~776][wine-defwnd]). Posted `WM_MOUSEMOVE`/`WM_LBUTTONUP` are second
   class; the watchdog therefore injects a **real** button press with
   [`SendInput`][sendinput]`(MOUSEEVENTF_LEFTDOWN)` before the `WM_SYSCOMMAND`, drives the
   drag with relative `MOUSEEVENTF_MOVE`s (each produces a logged `WM_SIZING`/`WM_MOVING`
   plus a resize), and ends it with `MOUSEEVENTF_LEFTUP` — the loop's documented exit.
2. **Keyboard mode has a pre-loop that swallows the first input.** Plain `SC_SIZE` first
   runs `start_size_move`, an inner pump that waits for an arrow key to _pick the edge_ —
   **before** `WM_ENTERSIZEMOVE` is sent. The freeze therefore starts ~600 ms before
   `modal_enter` in the `sc_size_kbd` rows below, and no enter-armed countermeasure can
   cover that window (the same pre-`WM_ENTERSIZEMOVE` pause [winit][winit] cancels with its
   dummy-`WM_MOUSEMOVE`-on-`WM_NCLBUTTONDOWN` trick).
3. **Whether any of this runs is the display driver's choice.** <a id="driver-fork"></a>
   `handle_sys_command` offers the command to the driver first; `winewayland`'s
   [`WAYLAND_SysCommand`][wine-wayland] **returns 0 ("handled") for every
   `SC_MOVE`/`SC_SIZE` on a Wayland-surfaced window** — it forwards to
   `xdg_toplevel.move`/`.resize` only if a recent pointer-button serial exists, and
   silently drops the request otherwise. Either way the in-process modal loop is skipped:
   no `WM_ENTERSIZEMOVE`, `SendMessage` returns in ~260 µs, `entered=0`. Win32-on-Wayland
   thus inherits Wayland's [no-modal-loop model][f03] — the compositor drives the resize
   and the client just receives configures. The x11 driver does the same delegation via
   `_NET_WM_MOVERESIZE` when a WM supports it ([`X11DRV_SysCommand`][wine-x11]); on bare
   Xvfb that atom probe fails, which is precisely what routes the demo into the
   **generic loop** and makes the freeze measurable.

```text
# winewayland: all three attempts — request returns immediately, never entered
495724  modal_request name=sc_size_grab wparam=0xf008 cursor=240,160
496485  modal_request_returned name=sc_size_grab dur_us=261 entered=0
```

## The freeze, measured

`tick t=… src=loop|timer` per animation frame; per-attempt `modal_summary` lines measure
from the last pre-enter tick through the first post-exit tick. x11/Xvfb, generic loop, all
`A[wine]`:

| Attempt (~956 ms drag)       | Mode    | Ticks inside loop | Max tick gap (µs) | `WM_SIZING`/`WM_MOVING` |
| ---------------------------- | ------- | ----------------- | ----------------- | ----------------------- |
| `sc_size_grab` (border)      | no fix  | **0**             | **1,009,597**     | 5 / 0                   |
| `sc_move_caption` (titlebar) | no fix  | **0**             | **1,008,991**     | 0 / 5                   |
| `sc_size_kbd`                | no fix  | 0                 | 720,445           | 1 / 0                   |
| `sc_size_grab` (border)      | **fix** | **59**            | 61,822¹           | 5 / 0                   |
| `sc_move_caption` (titlebar) | **fix** | **59**            | 61,250¹           | 0 / 5                   |
| `sc_size_kbd`                | **fix** | 1²                | 620,760²          | 0 / 0                   |

¹ The in-modal cadence itself is steady: 58 inter-tick deltas, mean **16.0 ms**, worst
**17.0 ms** — indistinguishable from the animation outside the loop. The ~61 ms figure is
the post-exit bridge (the demo joins its watchdog thread before the next loop tick), not a
modal-loop stall.
² The keyboard variant's gap is the unmitigable `start_size_move` pre-loop (lesson 2), plus
a Wine-specific early exit (below). On the two realistic drags the countermeasure turns a
**~1.01 s** freeze into a **17 ms** worst frame — while `WM_SIZING`/`WM_MOVING` and real
window resizes keep landing between the ticks.

A no-fix excerpt — one full second of dead air between two ticks, with the drag's resizes
happening inside it:

```text
506391  tick t=506391 src=loop frame=30
508895  modal_enter t=508895 fix=0
509201  msg name=WM_SIZING edge=8 rect=0,0-400,240
511138  resize size=392x206
…(4 more WM_SIZING + resizes, zero ticks)…
1465298 modal_exit t=1465298 dur_us=956403 ticks_during=0
1515989 modal_summary name=sc_size_grab dur_us=956403 ticks_during=0 max_gap_us=1009597 sizing=5 moving=0
1516516 tick t=1515988 src=loop frame=31
```

And the fix-mode counterpart — the timer ticks marching straight through the drag:

```text
504939  modal_enter t=504939 fix=1
505177  step name=SetTimer id=modal interval_ms=16
521707  tick t=521707 src=timer frame=31
537435  tick t=537434 src=timer frame=32
…(57 more src=timer ticks, ~16 ms apart, while WM_SIZING resizes the window)…
1460783 modal_exit t=1460769 dur_us=955830 ticks_during=59
```

## The countermeasures

The implemented fix is the survey-consensus one; the [F03 spec][f03] asks for the
alternatives to be recorded:

| Technique                                                                   | How it works                                                                                                    | Who uses it                                                                                                                                              | Trade-off                                                                                                                                  |
| --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **`SetTimer` on `WM_ENTERSIZEMOVE` + render from `WM_TIMER`** (implemented) | The modal pump dispatches queued [`WM_TIMER`][settimer]s; each one renders a frame re-entrantly inside the loop | [SDL3][sdl3] (`SetTimer(SDL_IterateMainCallbacks, USER_TIMER_MINIMUM)`), [GTK 4][gtk4] (timer pumps `g_main_context_iteration`), [sokol][concepts-modal] | `WM_TIMER` is low-priority/coalescing — ~15.6–17 ms best case, degrades under load; rendering becomes re-entrant (the `WndProc` must cope) |
| Render on `WM_PAINT`/refresh reentry only                                   | The loop dispatches the `WM_PAINT`s the drag itself invalidates                                                 | [GLFW][glfw] (window-refresh callback; docs state the blocking "is not a bug")                                                                           | Paints only when the OS invalidates — a _move_ (no size change) invalidates nothing, so the animation still freezes                        |
| **Render thread** — paint from a second thread, pump stays hostage          | The captured thread keeps pumping; presentation happens elsewhere                                               | [JUCE][juce]'s vblank thread; the standard D3D/GL game-engine answer                                                                                     | The only _complete_ fix (animation never depends on the pump) — at the price of cross-thread surface/size synchronization                  |
| `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` bracketing + flag                      | Mark "in size-move", adapt geometry handling, accept the freeze                                                 | [Qt 6][qt6] (`ResizeMoveActive`), [winit][winit] (`MARKER_IN_SIZE_MOVE`), [wxWidgets][concepts-modal]                                                    | Mitigation bookkeeping, not survival — used _in addition to_ one of the above                                                              |
| Dummy `WM_MOUSEMOVE` on `WM_NCLBUTTONDOWN`                                  | Cancels the ~500 ms pre-drag pause before the loop proper starts                                                | [winit][winit] (the empirically-discovered `lparam = 0` trick), sokol                                                                                    | Addresses only the entry pause (the same window `sc_size_kbd` exposes above), not the in-loop freeze                                       |

A `PeekMessage` sub-loop run from `WM_ENTERSIZEMOVE` itself (sometimes suggested) is **not**
viable as a survival strategy: `WM_ENTERSIZEMOVE` is sent once at entry, before the drag
events exist, and returning from it is required for the real loop to run — which is why no
surveyed framework does it and the demo implements the timer instead.

## Wine vs Windows — what must be re-confirmed {#wine-vs-windows}

- **The dispatch-break heuristic.** Wine's generic loop exits when _any_ dispatched message
  is followed by an up `VK_LBUTTON` ("It's possible that the window proc that handled the
  dispatch consumed a `WM_LBUTTONUP`" — [`defwnd.c`][wine-defwnd]). With the button
  genuinely held (the realistic drag) this is invisible — the 59-tick fix rows above prove
  timers and the loop coexist — but it ends Wine's _keyboard-mode_ sizing at the first
  `WM_TIMER` (the `sc_size_kbd` fix row: 1 tick, 17.8 ms). On Windows, keyboard sizing and
  `WM_TIMER` are expected to coexist; Tier C confirms.
- **Timing.** The ~956 ms drag duration is watchdog-scripted, not OS-determined; only the
  _shape_ (zero ticks vs ~16 ms ticks) transfers to Windows, not the absolute gap.
- **Driver forks don't exist on Windows.** The `winewayland`/`_NET_WM_MOVERESIZE`
  delegation paths are Wine architecture; on Windows the in-process loop is the only path.

**Tier C manual entry (Windows box):** build `examples/f03-modal-loop/` with
`dub build` (or `win32-ldc2` artifacts copied over); run **without** `WSI_AUTO_EXIT`, once
with and once with `WSI_MODAL_FIX=1`. Drag the title bar and a corner for ~2 s each.
Expected: no-fix — the color-cycle freezes for the whole drag and `tick` gaps ≈ drag
duration; fix — `src=timer` ticks every ~15.6 ms between `modal_enter`/`modal_exit`, color
keeps cycling during the drag. Also press `Alt+Space`, `S`, then arrows (keyboard sizing):
confirm `WM_TIMER` ticks continue (the Wine early-exit should _not_ reproduce). Paste the
`modal_summary` lines here.

## Build and run

From `docs/research/window-system-integration/os-apis/win32/examples/f03-modal-loop/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f03-modal-loop.exe

# Generic modal loop (the freeze measurement): Wine x11 driver on bare Xvfb
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c xvfb-run -a \
    env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) \
    wine64 ./build/f03-modal-loop.exe          # no fix
# …same with WSI_MODAL_FIX=1 for the countermeasure run

# winewayland (the plain scaffold pipeline): modal loop never enters
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f03-modal-loop.exe
```

All three exit `0`. Without `WSI_AUTO_EXIT=1` the demo runs until closed — the interactive
(Tier C) script above.

## Sources

- **[F03 spec][f03]** — requirements 1–3 (animation, interaction proof, the Win32
  technique + alternatives).
- **Microsoft Learn** (Wayback-pinned): [`WM_ENTERSIZEMOVE`][wm-entersizemove] (verbatim
  quote above), [`WM_EXITSIZEMOVE`][wm-exitsizemove], [`WM_SYSCOMMAND`][wm-syscommand]
  (`SC_SIZE`/`SC_MOVE`, the four low bits "used internally"), [`WM_SIZING`][wm-sizing],
  [`WM_MOVING`][wm-moving], [`WM_CANCELMODE`][wm-cancelmode], [`SetTimer`][settimer],
  [`SendInput`][sendinput], [`GetMessage`][getmessage].
- **Wine 10.0 source** (the loop actually measured): generic loop
  [`dlls/win32u/defwnd.c` — `sys_command_size_move` / `start_size_move`][wine-defwnd];
  driver delegation [`dlls/winewayland.drv/window.c` — `WAYLAND_SysCommand`][wine-wayland]
  and [`dlls/winex11.drv/window.c` — `X11DRV_SysCommand`][wine-x11].
- **Cross-references** — the modal-loop concept and per-framework workarounds:
  [concepts § Win32 modal resize/move loop][concepts-modal], [comparison][comparison]
  (consensus point 8), [winit][winit], [SDL3][sdl3], [Qt 6][qt6], [GTK 4][gtk4],
  [GLFW][glfw], [JUCE][juce]; the [Win32 scaffold](./scaffold.md) and the
  [F04 pacing findings][f04-doc] (what else freezes with the pump).
- Demo sources: [`app.d`](./examples/f03-modal-loop/app.d),
  [`instrument.d`](./examples/f03-modal-loop/instrument.d).

<!-- References -->

[f03]: ../features/f03-modal-loop.md
[f04-doc]: ./f04-frame-pacing.md
[comparison]: ../../comparison.md
[concepts-modal]: ../../concepts.md#win32-modal-resize-loop
[winit]: ../../winit.md
[sdl3]: ../../sdl3.md
[qt6]: ../../qt6.md
[gtk4]: ../../gtk4.md
[glfw]: ../../glfw.md
[juce]: ../../juce.md
[wm-entersizemove]: https://web.archive.org/web/20250611230612/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove
[wm-exitsizemove]: https://web.archive.org/web/20250824080033/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-exitsizemove
[wm-syscommand]: https://web.archive.org/web/20260520182433/https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syscommand
[wm-sizing]: https://web.archive.org/web/20251011051049/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-sizing
[wm-moving]: https://web.archive.org/web/20260430182713/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-moving
[wm-cancelmode]: https://web.archive.org/web/20260430182713/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-cancelmode
[settimer]: https://web.archive.org/web/20260512015942/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
[sendinput]: https://web.archive.org/web/20260518160717/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
[getmessage]: https://web.archive.org/web/20260420210137/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessage
[wine-defwnd]: https://gitlab.winehq.org/wine/wine/-/blob/wine-10.0/dlls/win32u/defwnd.c#L663
[wine-wayland]: https://gitlab.winehq.org/wine/wine/-/blob/wine-10.0/dlls/winewayland.drv/window.c#L674
[wine-x11]: https://gitlab.winehq.org/wine/wine/-/blob/wine-10.0/dlls/winex11.drv/window.c#L3324
