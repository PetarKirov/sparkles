# Wayland F14 — Window state & vetoable close

What does each lifecycle transition actually _say_ on the wire? The demo,
[`./examples/f14-window-state/app.d`](./examples/f14-window-state/app.d),
extends the [scaffold](./scaffold.md) to the [F14 spec][f14] with a timed
choreography — `set_maximized → unset_maximized → set_fullscreen →
unset_fullscreen → set_minimized` — that decodes the **complete states array**
of every `xdg_toplevel.configure`, plus the vetoable-close story: the document
is permanently "dirty", the first `xdg_toplevel.close` is _ignored_ (that is
the entire veto mechanism) and the second one exits cleanly. The event loop is
poll-driven rather than frame-callback-driven, because the choreography must
keep ticking after `set_minimized` stops the frame clock —
[F04](./f04-frame-pacing.md)'s occlusion finding, re-measured here on the
minimize path. Verified Tier A under headless weston 15 (socket `wsi-w7a`) and
headless sway 1.11; all runs exit `0`. The driver `run.sh` reproduces all
three choreographies (`weston`, `sway`, `sway-epipe`).

**Last reviewed:** June 11, 2026

## The states choreography, per transition, per compositor

Requests never change state; only the echoed configure does. The full decoded
sequences:

**weston 15** (floating desktop shell — the textbook run):

```text
188     configure serial=1 size=640x480   states=[]
711679  state_request kind=set_maximized
711721  configure serial=2 size=1024x608  states=[maximized]
1412330 state_request kind=unset_maximized
1412375 configure serial=3 size=640x480   states=[]
2112081 state_request kind=set_fullscreen
2112134 configure serial=4 size=1024x640  states=[fullscreen]
2812479 state_request kind=unset_fullscreen
2812530 configure serial=5 size=640x480   states=[]
3511851 state_request kind=set_minimized note=no unset twin, no state feedback
        (nothing — ever)
```

Note `activated` never appears (headless weston has no seat to focus with),
maximized leaves room for the panel (1024×608 of 1024×640) and fullscreen
takes the whole output.

**sway 1.11** (tiled, `xdg_wm_base` bound at v5):

```text
197     configure serial=3 size=640x480   states=[]
2757    configure serial=4 size=1276x693  states=[activated,tiled_left,tiled_right,tiled_top,tiled_bottom]
703539  state_request kind=set_maximized
703617  configure serial=5 size=1276x693  states=[activated,tiled_left,tiled_right,tiled_top,tiled_bottom]
2105253 state_request kind=set_fullscreen
2105600 configure serial=7 size=1280x720  states=[fullscreen,activated,tiled_left,tiled_right,tiled_top,tiled_bottom]
2812439 state_request kind=unset_fullscreen
2814266 configure serial=8 size=1276x693  states=[activated,tiled_left,tiled_right,tiled_top,tiled_bottom]
3513777 state_request kind=set_minimized note=no unset twin, no state feedback
        (nothing — ever)
```

Three sway findings ride in that log. `set_maximized`/`unset_maximized` on a
tiled window are **acknowledged but ineffective** — a configure echoes back
with the states unchanged (the protocol requires a configure in response; it
does not require obedience). Fullscreen _does_ work, takes the full 1280×720,
and the `tiled_*` bits **stay set** underneath it. And the contrast with
[F13](./f13-decorations.md) is a version-negotiation lesson: F13 binds
`xdg_wm_base` at **v1**, and there the same tiled window reported
`maximized=1` — sway downgrades its tiled state to `maximized` for clients too
old for the v2 `tiled_*` values. The state vocabulary you see depends on the
version you bind.

A fourth state appears only under interaction: F13's resize-grab run shows the
states array growing to `[activated,resizing]` for the duration of an
interactive resize.

## The minimize asymmetry, from the XML

Maximize and fullscreen are symmetric set/unset pairs with a state echo.
Minimize is neither — [the protocol][p-xdg] is explicit that it is
fire-and-forget, and even names the F04 wakeup trap:

```text
<request name="set_minimized">
  <description summary="set the window as minimized">
    Request that the compositor minimize your surface. There is no
    way to know if the surface is currently minimized, nor is there
    any way to unset minimization on this surface.

    If you are looking to throttle redrawing when minimized, please
    instead use the wl_surface.frame event for this, as this will
    also work with live previews on windows in Alt-Tab, Expose or
    similar compositor features.
  </description>
</request>
```

There is no `minimized` entry in the `state` enum, no `unset_minimized`
request, and — measured — **no configure of any kind** follows the request on
either compositor. The demo's census confirms the prescribed signal is the
frame callback ([F04](./f04-frame-pacing.md)'s frame-callbacks-stop finding,
now on the minimize path):

```text
weston: state_request kind=set_minimized frames=211   → minimize_census frames_in_1200ms_after_set_minimized=0
sway:   state_request kind=set_minimized frames=48    → minimize_census frames_in_1200ms_after_set_minimized=0
```

(weston ran a clean 60 Hz — 43/85/127/169/211 at the five requests — then a
hard stop. Headless sway delivers frame callbacks damage-driven and only hit
60 Hz while fullscreen, so its zero is consistent but weaker evidence; the
window itself survives, since `swaymsg` can still address it afterwards —
sway has no minimize concept for tiled windows.)

## `suspended` (v6) — measured: not deliverable here

The demo binds `xdg_wm_base` at `min(advertised, 6)` precisely to catch the
v6 `suspended` state ("The surface is currently not ordinarily being
repainted…", `since="6"`). The measured answer on both compositors:

```text
weston: wm_base advertised=5 bound=5 suspended_possible=0
sway:   wm_base advertised=5 bound=5 suspended_possible=0
```

Both headless weston 15 and sway 1.11 still advertise **v5**, so neither may
ever send `suspended` — at v5 the frame-callback silence is the _only_
machine-readable minimized/occluded signal. The related v5
`wm_capabilities` event is also instructive — it is UI advice, not
permission:

```text
weston: wm_capabilities caps=[maximize,fullscreen,minimize]
sway:   wm_capabilities caps=[window_menu,maximize]
```

sway advertises neither `fullscreen` nor `minimize`, yet honors
`set_fullscreen` fully — the event tells a client which _buttons to draw_,
not which requests are legal.

## Vetoable close: the veto is doing nothing

[`xdg_toplevel.close`][p-xdg] is a one-way event, not a question — there is
no return value, no reply, nothing to veto _with_:

```text
<event name="close">
  <description summary="surface wants to be closed">
    …
    This is only a request that the user intends to close the
    window. The client may choose to ignore this request, or show
    a dialog to ask the user to save their data, etc.
  </description>
</event>
```

`./run.sh sway` delivers two `swaymsg '[app_id=…] kill'` — and despite the
name, `kill` on a Wayland view sends exactly this close event, nothing more:

```text
--- swaymsg kill #1 (must be vetoed) ---
6001957 close_requested n=1 verdict=vetoed dirty=1 note=event ignored, no reply sent
--- swaymsg kill #2 (accepted) ---
7005119 close_requested n=2 verdict=accepted
ok: 48 frames, 6 configures, closes_seen=2 vetoes_left=0
```

The window survives the first kill untouched — no protocol error, no
compositor retaliation, no timeout (sway never escalates to disconnecting a
client that ignores close). The `sway-epipe` mode measures the only real
deadline: the demo vetoes _every_ close (`WSI_VETO_CLOSE=99`) and the
compositor is then killed out from under it —

```text
6002046 close_requested n=1 verdict=vetoed dirty=1 note=event ignored, no reply sent
--- compositor dies under the lingering veto-er ---
7004961 dispatch_error errno=32 note=EPIPE - compositor gone, veto moot
```

`wl_display_dispatch` fails, `wl_display_get_error` returns `EPIPE` (32), and
the demo still exits `0`. A client can veto the user forever; it cannot veto
the compositor's death.

## Findings

- **Echo map**: maximize/unmaximize and fullscreen/unfullscreen each echo one
  configure with the states array and new size; minimize echoes **nothing**
  on either compositor (and the XML says it never will). Interactive resize
  adds a `resizing` state for the grab's duration (F13's run).
- **Obedience is optional**: sway acks `set_maximized` on a tiled window with
  an unchanged-states configure. Treat the echoed array, never the request,
  as the truth.
- **Bound version changes the vocabulary**: the same tiled sway window is
  `[maximized]` to a v1 client and
  `[activated,tiled_left,tiled_right,tiled_top,tiled_bottom]` to a v5 one.
- **`suspended` needs `xdg_wm_base` ≥ 6** — neither weston 15 nor sway 1.11
  headless advertises it (both v5), so the frame-callback stop remains the
  only minimized signal; `wm_capabilities` advertises UI affordances, not
  request legality (sway honors fullscreen it doesn't advertise).
- **Fullscreen owner**: a real first-class state on Wayland
  (`states=[fullscreen]`, compositor-sized to the output) — unlike Win32's
  borderless-resize idiom; weston reserves panel space for `maximized` but
  not `fullscreen`.
- **The veto contract**: `close` is advisory by design; veto = ignore the
  event (nothing to return), accept = tear down yourself. `swaymsg kill` is
  just this event; no escalation ever comes. The only non-vetoable end is the
  socket dying (`EPIPE`), which a robust client must absorb (exit 0, not
  crash).
- **Loop architecture consequence**: a frame-callback-driven loop deadlocks
  at `set_minimized` (the callback never comes); state machines that must
  outlive minimize need a poll/timerfd leg — same conclusion as
  [F05](./f05-loop-wakeup.md), reached from the lifecycle side.

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f14-window-state

d=docs/research/window-system-integration/os-apis/wayland/examples/f14-window-state
nix develop -c $d/run.sh weston                                       # full storm, states decoded
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway"       # storm + two-kill vetoable close
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway-epipe" # veto everything, compositor dies, EPIPE
```

The sway modes start `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR` and address the window by `app_id` over `swaymsg`. Without
a compositor every mode prints `SKIP:` and exits `0`.

## Sources

- **[F14 spec][f14]** — requirement 1's per-transition sequences, the
  minimized-is-fire-and-forget asymmetry called out as a finding, the dirty
  flag/veto choreography of requirement 3, and requirement 4's clean-teardown
  bar.
- **[xdg-shell][p-xdg]** — `set_maximized`/`unset_maximized`,
  `set_fullscreen`/`unset_fullscreen`, the `set_minimized` and `close`
  passages quoted verbatim above, the `state` enum (`suspended` value 9,
  `since="6"`) and `wm_capabilities` (XML at
  `wayland-protocols/stable/xdg-shell/xdg-shell.xml`, v1.47 — interface
  version 7).
- **[F04 — frame pacing](./f04-frame-pacing.md)** — the
  frame-callbacks-stop-when-hidden finding this demo cross-checks on the
  minimize path, and the reason the loop is poll-driven.
- Demo sources: [`app.d`](./examples/f14-window-state/app.d),
  [`instrument.d`](./examples/f14-window-state/instrument.d), the `c.c` shim
  (state-request quartet + `poll`), `generate.sh` and the `run.sh` driver
  alongside it. The decoration-mode interplay with maximize lives in
  [F13](./f13-decorations.md).

<!-- References -->

[f14]: ../features/f14-window-state.md
[p-xdg]: https://wayland.app/protocols/xdg-shell
