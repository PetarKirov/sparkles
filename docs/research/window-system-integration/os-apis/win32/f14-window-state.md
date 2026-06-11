# Win32 F14 — window state & vetoable close

Who changes a Win32 window's state, what echoes back, and what a close request
really is — measured per the [F14 spec][f14]. The demo,
[`./examples/f14-window-state/app.d`](./examples/f14-window-state/app.d),
extends the [scaffold](./scaffold.md) with a scripted state tour
([`ShowWindow`][showwindow]`(SW_MAXIMIZE / SW_MINIMIZE / SW_RESTORE)` plus the
borderless-fullscreen idiom), logging **every** message until each transition
settles — [`WM_SIZE`][wm-size] `wParam` decoded,
[`WM_WINDOWPOSCHANGING`][wm-windowposchanging]/[`WM_WINDOWPOSCHANGED`][wm-windowposchanged]
order and flags, [`WM_GETMINMAXINFO`][wm-getminmaxinfo],
[`WM_ACTIVATE`][wm-activate]/`WM_SETFOCUS`/[`WM_KILLFOCUS`][wm-killfocus],
and a [`GetWindowPlacement`][getwindowplacement] read-back after every step —
then exercises the **first-class close veto**: a dirty flag makes the first
`WM_CLOSE` return `0` without `DefWindowProc`; the second closes. Run under
**both** Wine display drivers (winewayland on headless weston, winex11 on bare
Xvfb — [F03][f03-doc] proved they diverge); both exit `0`.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything below is `A[wine]`** (Wine 10/11 `wine64`, LDC 1.41.0
> cross-compile). winewayland ran against a **headless weston** compositor
> (`weston --backend=headless`, 1024×768) — no live desktop session existed on
> the host, and with no display server at all `CreateWindowExW` fails with
> error 1400 (re-confirming the F03 finding). The x11 runs are bare Xvfb — no
> window manager, which on X11 would change everything ([X11 F14][x11-f14])
> and here changes _almost nothing_: Wine's win32u implements the state
> machine in-process and only mirrors results to the backing window system.
> Message orderings are Wine's; the Tier C manual run re-confirms on Windows.

---

## The verdict lines

```text
# maximize: the request is synchronous and the new state echoes in-band
818143 f14_state_win32 state_changed via=WM_SIZE kind=SIZE_MAXIMIZED size=1024x742

# fullscreen: there is NO fullscreen state — the idiom lands as a plain resize
2416667 f14_state_win32 state_changed via=WM_SIZE kind=SIZE_RESTORED size=1024x768

# the veto: return 0 from WM_CLOSE, and nothing else happens
3215260 f14_state_win32 close_requested veto=1 src=self_syscommand dirty=1
```

Three facts that frame the whole platform: state changes are **synchronous
in-process calls** that echo back through `WM_SIZE`'s `wParam` (no
configure/ack round-trip); fullscreen is **a geometry idiom, not a state**;
and the close veto is **first-class** — unlike X11's `WM_DELETE_WINDOW`
ClientMessage and Wayland's `xdg_toplevel.close`, which are purely advisory
events an app may ignore, Win32 gives the app a return-value contract: the
window closes only if the app forwards `WM_CLOSE` to `DefWindowProc`.

## Per-transition sequences

All timestamps µs; winewayland run shown, x11 deltas called out
([diff below](#driver-diff)).

### Maximize — `ShowWindow(SW_MAXIMIZE)`

```text
814595 state_request kind=maximize api=ShowWindow(SW_MAXIMIZE)
815146 msg name=WM_GETMINMAXINFO maxSize=1032x776 maxPos=-4,-4
815561 msg name=WM_WINDOWPOSCHANGING rect=-4,-4-1032x776 flags=0x8020
815981 msg name=WM_GETMINMAXINFO maxSize=1032x776 maxPos=-4,-4
817799 msg name=WM_WINDOWPOSCHANGED rect=-4,-4-1032x776 flags=0x8020
818143 state_changed via=WM_SIZE kind=SIZE_MAXIMIZED size=1024x742
818722 placement when=after_maximize showCmd=SW_SHOWMAXIMIZED normal_rect=60,40-480x320 iconic=0 zoomed=1
```

[`WM_GETMINMAXINFO`][wm-getminmaxinfo] fires (twice) **before** the move — the
app's only chance to override the maximized size/position ("Sent to a window
when the size or position of the window is about to change"). The maximized
outer rect overhangs the monitor by the 4 px border on every side
(`-4,-4-1032x776` on a 1024×768 monitor) — maximized windows hide their
borders off-screen. Then the documented pair: `WM_WINDOWPOSCHANGING` (the
proposal — an app could still mutate it) → `WM_WINDOWPOSCHANGED` (the fact),
from which `DefWindowProc` synthesizes `WM_SIZE` with
`wParam=SIZE_MAXIMIZED` — the state echo. `GetWindowPlacement` still reports
`normal_rect=60,40-480x320`: **the normal rect is remembered by the system**,
not the app.

Under winewayland one more thing happened ~2 ms later:

```text
820463 msg name=WM_WINDOWPOSCHANGED rect=-4,-4-1024x736 flags=0x1636
820804 state_changed via=WM_SIZE kind=SIZE_MAXIMIZED size=1016x702
```

a **second, compositor-driven configure** shrank the window to weston's idea
of a maximized surface. Win32-on-Wayland keeps Wayland's
the-compositor-decides model: the synchronous in-process answer is
provisional. On x11/bare-Xvfb (nobody to disagree) this echo does not exist.

### Minimize — and where focus goes

```text
1614642 state_request kind=minimize api=ShowWindow(SW_MINIMIZE)
1615081 focus state=out reason=WM_KILLFOCUS next=0000000000000000
1615763 msg name=WM_WINDOWPOSCHANGING rect=-32000,-32000-160x31 flags=0x8174
1616748 msg name=WM_WINDOWPOSCHANGED rect=-32000,-32000-160x31 flags=0x8134
1617114 state_changed via=WM_SIZE kind=SIZE_MINIMIZED size=0x0
1617436 placement when=after_minimize showCmd=SW_SHOWMINIMIZED normal_rect=60,40-480x320 iconic=1 zoomed=0
1617932 focus_probe foreground=…2005E focus=0000000000000000 self=…2005E
```

- Minimize is **not** an unmap: the window is moved to the legacy parking
  position `(-32000,-32000)` at icon size `160×31` — minimized windows still
  have geometry.
- `WM_SIZE` arrives with `wParam=SIZE_MINIMIZED` and **size 0×0** — the
  scaffold's keep-no-buffer rule exists for exactly this.
- Focus goes **nowhere**: `WM_KILLFOCUS` reports `next=null`, and the probe
  confirms `GetFocus()==null` while `GetForegroundWindow()` is still the
  minimized window itself (`A[wine]`, single-window process; on a real desktop
  the shell would activate another window — Tier C re-check).
- Restore reverses it: `WM_SIZE SIZE_RESTORED` then `WM_SETFOCUS` +
  `WM_ACTIVATE WA_ACTIVE` — focus comes back unasked.

Note the asymmetric echo direction vs Wayland: Win32 echoes minimized state
in-band (`SIZE_MINIMIZED`), whereas `xdg_toplevel.set_minimized` is
fire-and-forget with no state echo at all ([F14 spec][f14] point 1).

### Fullscreen — the borderless idiom, and a placement footgun

Win32 has **no fullscreen window state**. The implemented idiom is the
canonical one (Raymond Chen, [“How do I switch a window between normal and
fullscreen?”][chen-fullscreen]): save `GetWindowLongPtrW(GWL_STYLE)` +
`GetWindowRect`, strip `WS_OVERLAPPEDWINDOW` with
[`SetWindowLongPtrW`][setwindowlongptr], then one
[`SetWindowPos`][setwindowpos] to the [`MonitorFromWindow`][getmonitorinfo]
rect with `SWP_FRAMECHANGED`; exit restores both.

```text
2414506 state_request kind=fullscreen_enter monitor=0,0-1024x768 saved_rect=60,40-480x320
2414984 msg name=WM_WINDOWPOSCHANGING rect=0,0-1024x768 flags=0x220
2415333 msg name=WM_GETMINMAXINFO maxSize=1024x768 maxPos=0,0
2416330 msg name=WM_WINDOWPOSCHANGED rect=0,0-1024x768 flags=0x224
2416667 state_changed via=WM_SIZE kind=SIZE_RESTORED size=1024x768
2417236 placement when=fullscreen_enter showCmd=SW_SHOWNORMAL normal_rect=0,0-1024x768 iconic=0 zoomed=0
```

Two findings:

- The state echo says `SIZE_RESTORED` and `GetWindowPlacement` says
  `SW_SHOWNORMAL` — as far as the window manager state machine is concerned,
  **a fullscreen window is a normal window that happens to cover the
  monitor**. Whoever owns "fullscreen" is the app, full stop.
- **The normal-rect memory is destroyed by the idiom**: during fullscreen,
  `rcNormalPosition` reads `0,0-1024x768` — moving a _normal_ window updates
  its normal rect. Restore-from-fullscreen must come from the app's own saved
  rect (as the demo's `saved_rect=60,40-480x320` does), **not** from
  `GetWindowPlacement` — a real footgun for naive bindings, and the reason
  the maximize/minimize transitions (which preserve `normal_rect`) and
  fullscreen (which corrupts it) must be treated differently.

### Vetoable close — the first-class veto

The demo drives the real user chain: the title-bar ✕ posts
`WM_SYSCOMMAND SC_CLOSE`, whose `DefWindowProc` handling sends
[`WM_CLOSE`][wm-close]:

```text
3215027 msg name=WM_SYSCOMMAND cmd=0xf060          ← SC_CLOSE
3215260 close_requested veto=1 src=self_syscommand dirty=1
# …window fully alive; 400 ms later, second attempt, flag now clear:
3615820 msg name=WM_SYSCOMMAND cmd=0xf060
3616050 close_requested veto=0 src=self_syscommand dirty=0
3616345 msg name=WM_WINDOWPOSCHANGING rect=0,0-0x0 flags=0x97   ← the hide
3617323 focus state=WA_INACTIVE reason=WM_ACTIVATE minimized=0
3617744 msg name=WM_ACTIVATEAPP active=0
3618018 focus state=out reason=WM_KILLFOCUS next=0000000000000000
3618348 msg name=WM_DESTROY
3618948 exit code=0
```

The veto is **returning 0 from `WM_CLOSE` without calling `DefWindowProc`**:

> An application can prompt the user for confirmation, prior to destroying a
> window, by processing the `WM_CLOSE` message and calling the
> `DestroyWindow` function only if the user confirms the choice.
>
> — [`WM_CLOSE`][wm-close], Microsoft Learn

`DefWindowProc`'s `WM_CLOSE` handler is what calls `DestroyWindow`; not
forwarding _is_ the refusal — no further protocol, no race. One-line
contrast: on X11 and Wayland the close request is an **advisory event**
(`WM_DELETE_WINDOW` / `xdg_toplevel.close`) the app simply ignores — same
outcome, but nothing in the protocol names it a veto; on Win32 (and macOS
`windowShouldClose:`) the refusal is a first-class return-value contract.
Session end is the separate [`WM_QUERYENDSESSION`][wm-queryendsession]
contract (return `FALSE` to object) — cited, not exercised here.

The accepted close then tears down in a fixed order — hide → deactivate
(`WM_ACTIVATE WA_INACTIVE` → `WM_ACTIVATEAPP 0` → `WM_KILLFOCUS`) →
`WM_DESTROY` — i.e. **focus/activation loss is part of destruction**, a
sequence bindings must not interpret as a user focus change.

## winewayland vs winex11 — the diff {#driver-diff}

The same binary, the same tour, both exit `0`. The transition sequences are
**message-for-message identical** except:

| Where           | winewayland (headless weston)                                                                               | winex11 (bare Xvfb) |
| --------------- | ----------------------------------------------------------------------------------------------------------- | ------------------- |
| after maximize  | a second `WM_WINDOWPOSCHANGED` (`flags=0x1636`) + `WM_SIZE SIZE_MAXIMIZED 1016×702` — the compositor's size | no second configure |
| after restore   | an extra `WM_WINDOWPOSCHANGING/CHANGED` echo pair (`flags=0x237/0x1a37`)                                    | absent              |
| everything else | identical                                                                                                   | identical           |

The asymmetry is exactly [F03][f03-doc]'s lesson restated for states: Wine's
in-process state machine answers synchronously, and the Wayland compositor's
opinion arrives **afterwards** as a correction. A binding that treats the
first `WM_SIZE` after `SW_MAXIMIZE` as final double-allocates its backbuffer
on Win32-on-Wayland. On real Windows there is no second authority — Tier C
expects the x11-like single-echo shape.

One more creation-time observation: `WM_GETMINMAXINFO` reaches the WndProc
**inside `CreateWindowExW`**, before `window_created` can be logged (both
drivers) — confirming the creation-set membership the
[scaffold findings](./scaffold.md) explicitly left unclaimed.

## Tier C manual entry (Windows box)

Build `examples/f14-window-state/` and run **without** `WSI_AUTO_EXIT`. Keys:
`M` maximize toggle, `N` minimize, `R` restore, `F` fullscreen toggle, `D`
dirty toggle (red border = dirty). Confirm: (a) single `WM_SIZE` echo per
transition — no winewayland-style second configure; (b) on minimize, which
window `WM_KILLFOCUS` names and what `GetForegroundWindow()` returns with
other apps open; (c) `normal_rect` corruption during fullscreen reproduces;
(d) ✕-click with `D` armed logs `close_requested veto=1 src=external` and the
window survives; second ✕ closes, exit 0. Paste the transition blocks here.

## Build and run

From `docs/research/window-system-integration/os-apis/win32/examples/f14-window-state/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f14-window-state.exe

# winewayland — needs a Wayland socket; headless weston works:
# (XDG_RUNTIME_DIR must be a private dir containing the weston socket)
weston --backend=headless --socket=wsi-f14 --width=1024 --height=768 &
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    WAYLAND_DISPLAY=wsi-f14 DISPLAY= \
    nix develop .#win32 -c wine64 ./build/f14-window-state.exe

# winex11 — bare Xvfb (no WM):
Xvfb :77 -screen 0 1024x768x24 &
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    XDG_RUNTIME_DIR=$(mktemp -d) DISPLAY=:77 \
    nix develop .#win32 -c wine64 ./build/f14-window-state.exe
```

Both exit `0`. Without `WSI_AUTO_EXIT=1` the demo runs interactively (keys
above).

## Sources

- **[F14 spec][f14]** — requirements 1–4 (transitions, focus, veto, clean
  teardown); sibling findings: [X11 F14][x11-f14] (the no-WM contrast),
  [F03 modal loop][f03-doc] (the driver fork this doc re-confirms).
- **Microsoft Learn** (Wayback-pinned): [`ShowWindow`][showwindow],
  [`WM_SIZE`][wm-size], [`WM_GETMINMAXINFO`][wm-getminmaxinfo] (quoted),
  [`WM_WINDOWPOSCHANGING`][wm-windowposchanging],
  [`WM_WINDOWPOSCHANGED`][wm-windowposchanged], [`WM_ACTIVATE`][wm-activate],
  [`WM_KILLFOCUS`][wm-killfocus], [`WM_CLOSE`][wm-close] (quoted),
  [`WM_QUERYENDSESSION`][wm-queryendsession],
  [`GetWindowPlacement`][getwindowplacement],
  [`SetWindowLongPtrW`][setwindowlongptr], [`SetWindowPos`][setwindowpos],
  [`GetMonitorInfoW`][getmonitorinfo].
- **Raymond Chen** — [the borderless-fullscreen idiom][chen-fullscreen]
  (Wayback-pinned).
- Demo sources: [`app.d`](./examples/f14-window-state/app.d),
  [`instrument.d`](./examples/f14-window-state/instrument.d).

<!-- References -->

[f14]: ../features/f14-window-state.md
[f03-doc]: ./f03-modal-loop.md
[x11-f14]: ../x11/f14-window-state.md
[showwindow]: https://web.archive.org/web/20240110202659/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-showwindow
[wm-size]: https://web.archive.org/web/20260610105248/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-size
[wm-getminmaxinfo]: https://web.archive.org/web/20240118020240/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-getminmaxinfo
[wm-windowposchanging]: https://web.archive.org/web/20240901212625/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanging
[wm-windowposchanged]: https://web.archive.org/web/20240412105731/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanged
[wm-activate]: https://web.archive.org/web/20240105230739/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-activate
[wm-killfocus]: https://web.archive.org/web/20240221073104/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-killfocus
[wm-close]: https://web.archive.org/web/20260610105639/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-close
[wm-queryendsession]: https://web.archive.org/web/20240106162059/https://learn.microsoft.com/en-us/windows/win32/shutdown/wm-queryendsession
[getwindowplacement]: https://web.archive.org/web/20240820084835/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowplacement
[setwindowlongptr]: https://web.archive.org/web/20240507203030/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowlongptrw
[setwindowpos]: https://web.archive.org/web/20260331132945/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
[getmonitorinfo]: https://web.archive.org/web/20240121161421/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmonitorinfow
[chen-fullscreen]: https://web.archive.org/web/20240303172929/https://devblogs.microsoft.com/oldnewthing/20100412-00/?p=14353
