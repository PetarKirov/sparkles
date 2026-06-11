# X11 F14 — window state & vetoable close

Who actually changes an X11 window's state, what comes back when it changes,
and what a "close request" really is. The demo,
[`./examples/f14-window-state/app.d`](./examples/f14-window-state/app.d),
extends the [scaffold](./scaffold.md) per the [F14 spec][f14]: maximize toggle
/ minimize / fullscreen toggle / restore, each issued exactly the way EWMH
prescribes (`_NET_WM_STATE` ClientMessages to the root, `WM_CHANGE_STATE` via
`XIconifyWindow`, `_NET_ACTIVE_WINDOW`), with **every** resulting event logged
until the state settles: `PropertyNotify` on `_NET_WM_STATE`/`WM_STATE` (the
atom list is re-fetched and decoded on each change), `ConfigureNotify` sizes,
`Map`/`UnmapNotify`, `VisibilityNotify`, and `FocusIn`/`FocusOut` with the
full mode/detail decode. A "dirty" flag makes the first `WM_DELETE_WINDOW`
request vetoed; a probe pass omits the protocol entirely. Runs are Tier A
under `xvfb-run` — bare Xvfb (no WM) and with `icewm` inside the same Xvfb
(see [`run.sh`](#build-and-run)). All passes: **0 X errors, exit 0**.

**Last reviewed:** June 11, 2026

## The verdict lines

```text
# bare Xvfb (no WM) — 8 requests, nothing whatsoever comes back
3932556 f14_x11 summary requests=8 state_changes=0 configures=0 map_unmap=1 focus=0 x_errors=0

# same binary, icewm running
3921387 f14_x11 summary requests=8 state_changes=13 configures=10 map_unmap=3 focus=3 x_errors=0
```

Same eight requests. Without a WM they go **nowhere**: an [EWMH][ewmh-state]
state change is a ClientMessage sent to the root window with
`SubstructureRedirect|SubstructureNotify` in the event mask —

> To change the state of a mapped window, a Client MUST send a
> `_NET_WM_STATE` client message to the root window

— and the only client that receives it is the one holding
`SubstructureRedirect` on the root, i.e. the window manager. On bare Xvfb no
such client exists, so the messages are discarded by the server. The bare run
is therefore _pure silence_; even `XIconifyWindow` "succeeds" (`sent=1` — it
returns once the [ICCCM §4.1.4][icccm] `WM_CHANGE_STATE` message is sent) and
the window stays mapped. **Every state operation on X11 is a request to a
peer client that may not exist.**

## Event sequences (icewm)

The bare-Xvfb sequence for every transition below is: the `state_request`
line, then nothing. Sequences under icewm, from one self-driven run:

### Maximize toggle (on)

```text
406605 f14_x11 state_request kind=maximize_toggle action=2 target=root
406941 f14_x11 configure size=640x434 pos=0+0 send_event=0
407157 f14_x11 configure size=640x434 pos=0+20 send_event=1
407170 f14_x11 property_notify atom=_NET_WM_STATE state=NewValue
407209 f14_x11 state_changed states=[_NET_WM_STATE_FOCUSED,_NET_WM_STATE_MAXIMIZED_VERT,_NET_WM_STATE_MAXIMIZED_HORZ]
```

Order: **resize first, state property last.** The real+synthetic
`ConfigureNotify` pair is the same WM-mediated mechanism [F02][f02-doc]
documented; the authoritative "am I maximized?" answer arrives only via
`PropertyNotify`, and the property carries no payload — the demo re-reads the
atom list with `XGetWindowProperty`. Per [EWMH][ewmh-state], "The Window
Manager MUST keep this property updated to reflect the current state of the
window." Toggling off is symmetric (configure back to 480×320, then
`states=[_NET_WM_STATE_FOCUSED]`).

### Minimize (iconify)

```text
1411071 f14_x11 state_request kind=minimize via=XIconifyWindow sent=1
1411186 f14_x11 property_notify atom=_NET_WM_STATE state=NewValue
1411397 f14_x11 state_changed states=[_NET_WM_STATE_HIDDEN]
1411417 f14_x11 property_notify atom=WM_STATE state=NewValue
1411442 f14_x11 state_changed wm_state=iconic
1411454 f14_x11 focus state=out mode=NotifyNormal detail=NotifyNonlinear
1411466 f14_x11 unmap_notify send_event=0
```

Iconify is the ICCCM path — per [§4.1.4][icccm], "the client should send a
ClientMessage event to the root with: … the atom `WM_CHANGE_STATE` …
`Data[0] == IconicState`" — and the echo is **double-bookkept**: EWMH
`_NET_WM_STATE` gains `_NET_WM_STATE_HIDDEN` _and_ the ICCCM `WM_STATE`
property flips to `IconicState`, then focus leaves, then the window is
unmapped. **There is no `ConfigureNotify`** — an iconified X11 window keeps
its geometry; "minimized" is an unmap plus two property edits. Note the order
inversion versus maximize: here state properties come _first_, the structural
event (`UnmapNotify`) last.

### Restore from iconic

```text
1913074 f14_x11 state_request kind=restore via=XMapWindow
1913081 f14_x11 state_request kind=activate target=root
1913184 f14_x11 property_notify atom=_NET_WM_STATE state=NewValue
1913417 f14_x11 state_changed states=[_NET_WM_STATE_FOCUSED]
1913429 f14_x11 property_notify atom=WM_STATE state=NewValue
1913455 f14_x11 state_changed wm_state=normal
1913468 f14_x11 map_notify
1913561 f14_x11 focus state=in mode=NotifyNormal detail=NotifyNonlinear
```

De-iconify is just `XMapWindow` (ICCCM: mapping requests the Normal state);
`_NET_ACTIVE_WINDOW` brings focus back — per [EWMH][ewmh-root], "If a Client
wants to activate another window, it MUST send a `_NET_ACTIVE_WINDOW` client
message to the root window."

### Fullscreen toggle (on)

```text
2415199 f14_x11 state_request kind=fullscreen_toggle action=2 target=root
2415423 f14_x11 configure size=640x480 pos=0+0 send_event=0
2415467 f14_x11 configure size=640x480 pos=0+0 send_event=1
2415486 f14_x11 property_notify atom=_NET_FRAME_EXTENTS state=NewValue
2415576 f14_x11 state_changed states=[_NET_WM_STATE_FOCUSED,_NET_WM_STATE_FULLSCREEN]
2415604 f14_x11 property_notify atom=_WIN_LAYER state=NewValue
```

Fullscreen **is a real, WM-owned state** on X11 (contrast Win32's
borderless-resize idiom): icewm resizes the client to the full 640×480
screen, _removes the frame_ (`_NET_FRAME_EXTENTS` changes; the synthetic
configure shows `pos=0+0`, no titlebar offset), sets
`_NET_WM_STATE_FULLSCREEN`, and raises the layer (`_WIN_LAYER`, a pre-EWMH
GNOME hint icewm still maintains). Toggling off restores frame and geometry.

### Which transitions echo, and where

| Transition  | `ConfigureNotify` | `_NET_WM_STATE`        | `WM_STATE` | Map/Unmap     |
| ----------- | ----------------- | ---------------------- | ---------- | ------------- |
| maximize    | yes (real+synth)  | `MAXIMIZED_VERT,_HORZ` | —          | —             |
| iconify     | **no**            | `HIDDEN`               | `iconic`   | `UnmapNotify` |
| de-iconify  | **no**            | drops `HIDDEN`         | `normal`   | `MapNotify`   |
| fullscreen  | yes (real+synth)  | `FULLSCREEN`           | —          | —             |
| no WM (any) | never             | never                  | never      | never         |

Nothing on X11 is fire-and-forget _by design_ (every transition has an
observable echo — when a WM exists); what is absent is any _synchronization_:
the echoes arrive in transition-specific order, interleaved with repaints.

## Focus events: the `Notify*` zoo

The demo decodes `XFocusChangeEvent.mode`
(`NotifyNormal/Grab/Ungrab/WhileGrabbed`) and `detail`
(`NotifyAncestor/Virtual/Inferior/Nonlinear/NonlinearVirtual/Pointer/PointerRoot/DetailNone`)
per the [Xlib input-focus events][xlib-focus] tables. Plain icewm
focus moves are `mode=NotifyNormal detail=NotifyNonlinear`. The zoo earns its
keep the moment a grab is involved — icewm's Alt+F4 handling briefly grabs
the keyboard, and the demo sees it:

```text
6510970 f14_x11 key sym=0xffe9                                  # Alt down (XTEST)
6517124 f14_x11 focus state=out mode=NotifyGrab detail=NotifyAncestor
6517276 f14_x11 close_requested veto=1 action=ignored_dirty_cleared
6529414 f14_x11 focus state=out mode=NotifyUngrab detail=NotifyPointer
6529418 f14_x11 focus state=in mode=NotifyUngrab detail=NotifyAncestor
```

A toolkit that treats every `FocusOut` as "deactivated" will flicker its UI
on each WM keyboard grab; grab-generated focus events (`mode=NotifyGrab`/
`NotifyUngrab`) must be filtered from app-level activation state.

## The veto contract: there is nothing to return

The close request is a `WM_PROTOCOLS`/`WM_DELETE_WINDOW` ClientMessage —
deliverable by the WM (icewm's Alt+F4, pass C) or by anyone else, including
the demo itself (the self-driven pass sends it with `XSendEvent` to its own
window; the WM's version is byte-identical). [ICCCM §4.2.8.1][icccm]:

> Clients receiving a `WM_DELETE_WINDOW` message should behave as if the user
> selected "delete window" from a hypothetical menu. They should perform any
> confirmation dialog with the user and, if they decide to complete the
> deletion, should do the following: …

"If they decide" is the whole veto API. The event has no reply, no return
value, no acknowledgement channel — the veto is implemented by **doing
nothing**:

```text
3511193 f14_x11 step name=XSendEvent msg=WM_DELETE_WINDOW to=self
3511238 f14_x11 close_requested veto=1 action=ignored_dirty_cleared
3912438 f14_x11 step name=XSendEvent msg=WM_DELETE_WINDOW to=self
3912519 f14_x11 close_requested veto=0 action=quit
```

The WM cannot distinguish a deliberate veto from a hung client — which is
exactly why WMs grow kill escalation paths (next section). Contrast Win32
(`WM_CLOSE` returns control via `DefWindowProc`) and macOS
(`windowShouldClose:` returns `BOOL`): there the veto is a first-class
return-value contract; on X11 (as on Wayland) it is an app-side convention.

## No `WM_DELETE_WINDOW` in `WM_PROTOCOLS`: the kill path

Pass D (`WSI_NO_WM_DELETE=1`) skips `XSetWMProtocols`. [ICCCM
§4.1.2.7][icccm] spells out the consequence:

> Clients that choose not to include `WM_DELETE_WINDOW` in the `WM_PROTOCOLS`
> property may be disconnected from the server if the user asks for one of
> the client's top-level windows to be deleted.

Measured nuance: icewm does **not** kill silently. Alt+F4 on the
handshake-less window pops icewm's confirm box (`wmConfirmKill()` in
[icewm `src/wmframe.cc`][icewm-src] — "WARNING! All unsaved changes will be
lost when this client is killed. Do you wish to proceed?"), visible to the
demo only as collateral state noise: `_NET_WM_STATE_FOCUSED` drops and focus
leaves under a grab, no close-shaped event of any kind. The actual
`XKillClient` (driven deterministically via `xdotool windowkill`) then severs
the connection mid-poll:

```text
1514791 f14_x11 state_changed states=[]
1514805 f14_x11 focus state=out mode=NotifyWhileGrabbed detail=NotifyNonlinear
2535915 f14_x11 connection_lost via=XIOError likely=XKillClient
```

The XIO error handler is the _only_ notification — it may not return, so
"graceful shutdown without the handshake" does not exist. The handshake is
three lines of setup; omitting it converts every user close into `SIGKILL`
semantics.

## Findings

- **All state transitions are messages to a peer client, not server calls.**
  No WM ⇒ requests are discarded with zero feedback; `XIconifyWindow`'s
  return value only means "message sent". A framework cannot distinguish
  "request pending" from "no one is listening" except by timeout.
- **The state echo is property-based and payload-less.** `PropertyNotify` on
  `_NET_WM_STATE` says only _changed_; the app must re-fetch and diff the atom
  list. Iconic state is double-bookkept (EWMH `HIDDEN` + ICCCM `WM_STATE`).
- **Echo order is transition-specific**: maximize/fullscreen resize first and
  set the property last; iconify sets properties first and unmaps last. Code
  that infers "minimized" from `UnmapNotify` alone confuses it with
  withdrawal; `WM_STATE`/`_NET_WM_STATE_HIDDEN` is the truth.
- **Fullscreen is a real WM state** (`_NET_WM_STATE_FULLSCREEN` + frame
  removal + layer raise), not a geometry idiom.
- **The close veto is the absence of a reply** — purely advisory, app-side
  convention, indistinguishable from a hang; skipping the handshake means
  `XKillClient` (icewm at least confirms first — measured, not assumed).
- **Grab-generated focus events pollute activation state** —
  `mode=NotifyGrab`/`NotifyUngrab` must be filtered (the WM's own hotkey
  handling triggers them).

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f14-window-state
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f14-window-state
```

That self-driven run (also what CI does) needs no WM and no input tool. The
four-pass comparison — bare/icewm self-driven, icewm with xdotool keys and a
real Alt+F4 close, and the `WSI_NO_WM_DELETE=1` kill probe — is scripted in
`examples/f14-window-state/run.sh` (run from the dev shell; it pulls `xdotool`
and `icewm` via `nix shell`). Interactive keys: `m`/`i`/`f`/`r` transitions,
`d` dirty toggle, `c` self-close-request, `q` quit. No reachable display
prints `SKIP: no X11 display` and exits 0.

## Sources

- **[F14 spec][f14]** — requirements 1–4 (transition logging, focus, vetoable
  close, clean teardown).
- **[EWMH — `_NET_WM_STATE`][ewmh-state]** and **[root window messages
  (`_NET_ACTIVE_WINDOW`)][ewmh-root]** — the client-message contract and the
  property-update obligation (verbatim quotes above).
- **[ICCCM §4 (Tronche mirror)][icccm]** — `WM_CHANGE_STATE`/`IconicState`,
  `WM_DELETE_WINDOW` semantics, and the disconnect warning (verbatim quotes
  above).
- **Xlib reference (Tronche mirror)** — [input-focus events][xlib-focus]
  (the mode/detail tables), [`XIconifyWindow`][xiconify].
- **[icewm source — `src/wmframe.cc`][icewm-src]** — `wmCloseClient`/
  `wmConfirmKill`: the confirm-before-`XKillClient` path pass D measured.
- **[X11 F02 findings][f02-doc]** — the real+synthetic `ConfigureNotify` pair
  and WM-mediated configure mechanics the maximize/fullscreen sequences reuse.
- Demo sources: [`app.d`](./examples/f14-window-state/app.d),
  [`instrument.d`](./examples/f14-window-state/instrument.d), the `c.c`
  ImportC shim, and `run.sh` alongside them.

<!-- References -->

[f14]: ../features/f14-window-state.md
[f02-doc]: ./f02-resize.md
[ewmh-state]: https://specifications.freedesktop.org/wm-spec/1.5/ar01s05.html
[ewmh-root]: https://specifications.freedesktop.org/wm-spec/1.5/ar01s03.html
[icccm]: https://tronche.com/gui/x/icccm/sec-4.html
[xlib-focus]: https://tronche.com/gui/x/xlib/events/input-focus/
[xiconify]: https://tronche.com/gui/x/xlib/ICC/client-to-window-manager/XIconifyWindow.html
[icewm-src]: https://github.com/ice-wm/icewm/blob/master/src/wmframe.cc
