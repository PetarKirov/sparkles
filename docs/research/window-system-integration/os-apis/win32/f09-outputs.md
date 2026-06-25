# Win32 — F09: Output enumeration & hotplug

Findings from [`./examples/f09-outputs/app.d`][f09-app], the Win32 implementation of the
[F09 spec][f09-spec]: an [`EnumDisplayMonitors`][enumdisplaymonitors] +
[`GetMonitorInfoW`][getmonitorinfow] (`MONITORINFOEXW`) + [`GetDpiForMonitor`][getdpiformonitor] +
[`EnumDisplaySettingsW`][enumdisplaysettingsw] observatory with
[`MonitorFromWindow`][monitorfromwindow] occupancy tracking, all three hotplug signals
([`WM_DISPLAYCHANGE`][wm-displaychange] / [`WM_SETTINGCHANGE`][wm-settingchange] /
[`WM_DEVICECHANGE`][wm-devicechange] via [`RegisterDeviceNotificationW`][registerdevicenotificationw]),
and a ~0.5 s re-enumerate-and-diff poll. The headline: a **live hotplug was captured** —
`swaymsg create_output` against a headless sway materialized `\\.\DISPLAY2` in Wine's monitor
list within ~1 s, and `unplug` removed it — but Wine 10.0 fired **zero** of the three
messages either way; only the poll caught both transitions. Bonus quirk: under winewayland
every monitor's `rcMonitor` sits at `+0+0` while `rcWork` carries the real layout offset,
which makes geometric occupancy derivation ambiguous.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 with the exe
> cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Three runs:
> **winewayland** against the live `wayland-0` session (two physical 2560×1440 monitors),
> **winex11** under `xvfb-run` (`WAYLAND_DISPLAY` unset, private `XDG_RUNTIME_DIR`), and
> **winewayland on a headless sway** (the [F08][f08-doc] `WLR_BACKENDS=headless` setup)
> for the hotplug experiment. Wine is a reimplementation: the missing-`WM_DISPLAYCHANGE`
> finding is a Wine behavior; on real Windows the message is documented to fire
> (re-confirmation is in the [manual-run queue][manual-queue]).

---

## The demo

Three bounded runs, all exit `0`:

| Run          | Driver / display                                 | Captures                                                           |
| ------------ | ------------------------------------------------ | ------------------------------------------------------------------ |
| default      | winewayland, live `wayland-0` (2 real monitors)  | enumeration model, occupancy, off-screen `MonitorFromWindow` probe |
| x11          | winex11 under `xvfb-run` (640×480, 1 output)     | same demo, single-output + `hz=0` contrast                         |
| hotplug hunt | winewayland on headless sway, `WSI_RUN_MS=18000` | `swaymsg create_output` + `output HEADLESS-2 unplug` mid-run       |

Per output the demo logs: `szDevice`, `rcMonitor` (plus the rect `EnumDisplayMonitors`
itself hands the callback, as a cross-check), `rcWork`, `MONITORINFOF_PRIMARY`, the
effective DPI from [`GetDpiForMonitor`][getdpiformonitor] (shcore, resolved with
`GetProcAddress` — present under Wine 10.0), and the current raw mode from
[`EnumDisplaySettingsW`][enumdisplaysettingsw]`(szDevice, ENUM_CURRENT_SETTINGS)`
(`dmPelsWidth/Height`, `dmBitsPerPel`, `dmDisplayFrequency`, `dmPosition`).

---

## The information model — `A[wine]`

The first enumeration pass runs **before `RegisterClassExW`** — it needs no window, only
user32 (the F09 "is enumeration global?" question: yes; the pass costs the usual one-time
session-connect, ~7–14 ms first-user32-call tax, cf. the [scaffold findings][scaffold]).
The live-session winewayland run:

```text
13558 enum_pass when=pre_window count=2
13828 output id=0 device=\\.\DISPLAY1 rect=2560x1440+0+0 enum_rect=2560x1440+0+0
      work=2560x1440+0+0 primary=1 dpi=96 mode=2560x1440 bpp=32 hz=59 pos=0,0
14627 output id=1 device=\\.\DISPLAY2 rect=2560x1440+0+0 enum_rect=2560x1440+0+0
      work=2560x1440+2560+0 primary=0 dpi=96 mode=2560x1440 bpp=32 hz=59 pos=0,0
```

- **Identity** is the `MONITORINFOEXW.szDevice` string (`\\.\DISPLAY1`, `\\.\DISPLAY2`) —
  the `HMONITOR` handle is not stable across topology changes, so the demo diffs by name.
- **Refresh and bit depth survive the winewayland round trip:** `hz=59`/`bpp=32` from the
  live session, `hz=60` from headless sway — Wine forwards the compositor's mode instead
  of inventing one. Under Xvfb (winex11) the same query returns **`hz=0`**: Xvfb has no
  real rate, and [`DEVMODEW`][devmodew] only promises that `dmDisplayFrequency`
  "specifies the frequency, in hertz, of a display device in its current mode" — a driver
  with no real mode answers 0. Consumers must treat `0` as "unknown", not 0 Hz.
- **`rcMonitor` is broken under winewayland (Wine 10.0):** both monitors report
  `rcMonitor` at `+0+0`, while `rcWork` carries the actual side-by-side layout
  (`+2560+0` for `DISPLAY2`) — the same inversion appears in the sway run (`work=…+1280+0`).
  The rect `EnumDisplayMonitors` passes its callback agrees with the (wrong) `rcMonitor`,
  so the bug is consistent across both query paths. `dmPosition` is `0,0` for every
  output, too. Only `rcWork` reveals the topology. `A[wine]` — on Windows `rcMonitor` is
  the virtual-desktop rect and multi-monitor coordinates hang off the primary per
  [the multiple-display-monitors overview][multimon].
- **`GetDpiForMonitor` exists and answers 96** for every output in every run — consistent
  with [F08][f08-doc]'s finding that Wine maps compositor scale into pixel sizes, never
  into the DPI subsystem.

---

## Occupancy: the derivation Win32 forces on apps — `A[wine]`

Win32 has no surface-enters-output event, so the demo re-derives
[`MonitorFromWindow`][monitorfromwindow]`(hwnd, MONITOR_DEFAULTTONULL)` on every
`WM_MOVE`/`WM_SIZE` (and after topology changes) and logs transitions. For contrast in one
line each: X11 gives the window nothing (you diff geometry against RandR yourself), and
Wayland is the only platform that tells the surface directly (`wl_surface.enter`/`leave` —
[F09 spec][f09-spec] req. 2).

```text
20136  surface_output enter device=\\.\DISPLAY1 why=WM_SIZE window=480x320+0+0
503050 step name=SetWindowPos offscreen=1 pos=20000,20000
503833 surface_output none why=WM_MOVE
504096 offscreen_probe defaulttonull=0000000000000000 defaulttonearest=\\.\DISPLAY1 same_as_primary=1
744254 surface_output enter device=\\.\DISPLAY1 why=WM_MOVE window=480x320+80+80
```

The off-screen probe (window parked at `+20000+20000`) confirms the documented flag
contract — "[i]f the window does not intersect a display monitor, the return value
depends on the value of `dwFlags`" ([`MonitorFromWindow`][monitorfromwindow]):
`MONITOR_DEFAULTTONULL` returned `NULL`, `MONITOR_DEFAULTTONEAREST` "[r]eturns a handle to
the display monitor that is nearest to the window". A binding should track occupancy with
`DEFAULTTONULL` (so "off every monitor" is representable) and fall back to
`DEFAULTTONEAREST` when it needs _some_ DPI/geometry context.

The `rcMonitor`-at-origin quirk has a real casualty here: in the sway two-output phase the
window sat at `+80+80` — unambiguously on `HEADLESS-1` — yet `MonitorFromWindow` answered
`DISPLAY2` (`surface_output enter device=\\.\DISPLAY2 why=poll`), because with every
monitor rect overlapping at the origin, largest-intersection tie-breaking picks the bigger
1920×1080 monitor. **Geometric occupancy is unreliable under winewayland multi-monitor**
(`A[wine]`); the demo reports what the API says rather than second-guessing it.

---

## Hotplug: a live `create_output`, and nobody told the window — `A[wine]`

The experiment: headless sway (the [F08][f08-doc] pattern — `WLR_BACKENDS=headless
WLR_RENDERER=pixman` on a private `XDG_RUNTIME_DIR`), prefix pre-warmed so wineboot
doesn't eat the timeline, demo at `WSI_RUN_MS=18000`; at wall +8 s
`swaymsg create_output` (sway adds a 1920×1080 `HEADLESS-2`), at wall +14 s
`swaymsg output HEADLESS-2 unplug`. Result:

```text
7343     enum_pass when=pre_window count=1     (1280x720 hz=60)
7949572  output_added device=\\.\DISPLAY2 via=poll
7949624  enum_pass when=poll count=2
7949760  output id=1 device=\\.\DISPLAY2 rect=1920x1080+0+0 work=1920x1080+1280+0
         primary=0 dpi=96 mode=1920x1080 bpp=32 hz=60 pos=0,0
7949899  surface_output enter device=\\.\DISPLAY2 why=poll window=1276x693+80+80
13901631 output_removed device=\\.\DISPLAY2 via=poll
13901806 surface_output enter device=\\.\DISPLAY1 why=poll window=1276x693+80+80
18014683 summary displaychange=0 settingchange=0 devicechange=0 outputs=1
```

- **Wine materializes the monitor.** Within one or two 0.5 s poll periods of
  `create_output`, `EnumDisplayMonitors` reports a second monitor with the correct mode
  (`1920x1080 hz=60`) and a correct `rcWork` offset; the unplug removes it just as fast.
  The window whose (derived) output vanished kept running — no crash, no stale handle, the
  next derivation simply landed on `DISPLAY1`.
- **But the announcement machinery is dead.** Zero [`WM_DISPLAYCHANGE`][wm-displaychange]
  — despite "[t]he `WM_DISPLAYCHANGE` message is sent to all windows when the display
  resolution has changed" and a _topology_ change being the canonical trigger on Windows —
  zero [`WM_SETTINGCHANGE`][wm-settingchange], zero [`WM_DEVICECHANGE`][wm-devicechange].
  [`RegisterDeviceNotificationW`][registerdevicenotificationw] for
  `GUID_DEVINTERFACE_MONITOR` succeeded (non-null handle, `err=0`) and never delivered
  anything: Wine 10.0's winewayland updates the monitor list wineserver-side but never
  broadcasts. `A[wine]` — every `via=` field in the log says `poll`, no run produced a
  `via=WM_DISPLAYCHANGE`.
- **Consequence for a binding:** under Wine, output topology is **pull-only**. A binding
  that relies on `WM_DISPLAYCHANGE` (the correct Windows design) sees a frozen monitor
  list under Wine; the demo's re-enumerate-on-poll diff (by `szDevice`) is the portable
  fallback, and re-deriving occupancy after any diff is load-bearing because the old
  `HMONITOR` may be stale.
- The sway run also shows sway _tiling_ the Wine window right after map
  (`buffer_alloc size=1268x659` — the full output minus decorations), which is why the
  occupancy lines carry `window=1276x693`.

On real Windows the expectation (Tier C, [queued][manual-queue]) is `WM_DISPLAYCHANGE`
plus a `WM_SETTINGCHANGE` burst on hotplug, and `WM_DEVICECHANGE` only with the
device-interface registration in place.

---

## Surprises

- **Hotplug works; hotplug _notification_ doesn't** (Wine 10.0, winewayland): the monitor
  list is live, all three message channels are silent. Polling is mandatory under Wine —
  and `summary devicechange=0` despite a successful `RegisterDeviceNotificationW` means
  absence-of-message is indistinguishable from absence-of-event without a poll to compare
  against.
- **`rcMonitor` at `+0+0` for every monitor** while `rcWork` carries the offset — exactly
  backwards from what a layout consumer reads first. Anything deriving monitor-relative
  placement from `rcMonitor` silently believes all monitors are mirrored (`A[wine]`).
- **`MonitorFromWindow` can answer a monitor the window is not on** (the overlap
  tie-break) — occupancy logs under winewayland multi-monitor must be read with that
  grain of salt.
- **Xvfb's `hz=0`** is a legal `dmDisplayFrequency` value, not corruption — code that
  divides by the refresh rate meets it the first time it runs under CI.
- **`GetDpiForMonitor` is present and uniformly 96** even with a scaled compositor —
  consistent with [F08][f08-doc]: Wine's DPI subsystem and its mode reporting are fed by
  different plumbing.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f09-outputs/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f09-outputs.exe

# default (winewayland, live wayland-0)
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f09-outputs.exe

# winex11 under Xvfb (WAYLAND_DISPLAY unset, private XDG_RUNTIME_DIR)
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) WINEPREFIX=$(mktemp -d) \
    WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    xvfb-run -a nix develop .#win32 -c wine64 ./build/f09-outputs.exe
```

The hotplug hunt needs a compositor the run owns (the [F08][f08-doc] recipe): headless
sway on a fresh `XDG_RUNTIME_DIR`, pre-warm the prefix (`wine64 cmd /c exit 0`), run the
demo with `WAYLAND_DISPLAY=<sway socket>` / `WSI_AUTO_EXIT=1 WSI_RUN_MS=18000`, and issue
`swaymsg create_output` then `swaymsg output HEADLESS-2 unplug` mid-run. All three modes
exit `0`. The package's `dub.sdl` (`platforms "windows"`) exists for the Windows CI
runner; locally `dub` is not part of the pipeline.

---

## Sources

- [`./examples/f09-outputs/app.d`][f09-app] — the demo (all log excerpts above)
- [F09 spec][f09-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold], [F08 DPI findings][f08-doc] — baseline pump,
  headless-sway recipe
- [`EnumDisplayMonitors`][enumdisplaymonitors], [`GetMonitorInfoW`][getmonitorinfow],
  [`MONITORINFOEXW`][monitorinfoexw], [`GetDpiForMonitor`][getdpiformonitor],
  [`EnumDisplaySettingsW`][enumdisplaysettingsw], [`DEVMODEW`][devmodew],
  [`MonitorFromWindow`][monitorfromwindow], [`WM_DISPLAYCHANGE`][wm-displaychange],
  [`WM_SETTINGCHANGE`][wm-settingchange], [`WM_DEVICECHANGE`][wm-devicechange],
  [`RegisterDeviceNotificationW`][registerdevicenotificationw],
  [Multiple Display Monitors][multimon] — Microsoft Learn (Wayback-pinned)

<!-- References -->

[f09-app]: ./examples/f09-outputs/app.d
[f09-spec]: ../features/f09-outputs.md
[scaffold]: ./scaffold.md
[f08-doc]: ./f08-dpi-scaling.md
[manual-queue]: ../manual-run-queue.md
[enumdisplaymonitors]: https://web.archive.org/web/20260426131636/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaymonitors
[getmonitorinfow]: https://web.archive.org/web/20260130173833/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmonitorinfow
[monitorinfoexw]: https://web.archive.org/web/20250910042726/https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-monitorinfoexw
[getdpiformonitor]: https://web.archive.org/web/20251204174657/https://learn.microsoft.com/en-us/windows/win32/api/shellscalingapi/nf-shellscalingapi-getdpiformonitor
[enumdisplaysettingsw]: https://web.archive.org/web/20260124223626/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumdisplaysettingsw
[devmodew]: https://web.archive.org/web/20260124211031/https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-devmodew
[monitorfromwindow]: https://web.archive.org/web/20260220172157/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-monitorfromwindow
[wm-displaychange]: https://web.archive.org/web/20260307045616/https://learn.microsoft.com/en-us/windows/win32/gdi/wm-displaychange
[wm-settingchange]: https://web.archive.org/web/20260424145757/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-settingchange
[wm-devicechange]: https://web.archive.org/web/20260213195157/https://learn.microsoft.com/en-us/windows/win32/devio/wm-devicechange
[registerdevicenotificationw]: https://web.archive.org/web/20251209000309/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerdevicenotificationw
[multimon]: https://web.archive.org/web/20260305160903/https://learn.microsoft.com/en-us/windows/win32/gdi/multiple-display-monitors
