# X11 F02 — resize correctness

Who really decides an X11 window's size, and what lands in your event queue
when it changes. The demo,
[`./examples/f02-resize/app.d`](./examples/f02-resize/app.d), extends the
[scaffold](./scaffold.md) to the full [F02 spec][f02]: a continuously animated,
corner-anchored gradient survives an aggressive programmatic resize storm
driven over **both** paths an X11 window experiences — self-resize
(`XResizeWindow` on the demo's own connection, including a burst of three
back-to-back requests) and **external resize from a second `Display*`
connection** opened mid-run, which configures the window by `XID` exactly the
way a window manager or `xdotool` would. Every `ConfigureNotify` is logged with
size, position, `serial`, and `send_event`; every `Expose`, every buffer
realloc, every stale frame, and every protocol error (via `XSetErrorHandler`)
are logged too. Runs are Tier A under `xvfb-run` — once on bare Xvfb (no WM)
and once with `icewm` running inside the same Xvfb, which turns out to change
_everything_ about the event flow. Both runs: **0 protocol errors, exit 0**.

**Last reviewed:** June 10, 2026

## The verdict lines

```text
# bare Xvfb (no WM)
68582 f02_x11 summary configures=13 reallocs=14 stale_frames=11 errors=0 final=480x320

# same binary, icewm running
72710 f02_x11 summary configures=30 reallocs=14 stale_frames=26 errors=0 final=480x320
```

Same 13 resize requests (6 spaced self-resizes + a 3-request burst + 4
external), same 14 buffer allocations — but the WM more than doubles the
`ConfigureNotify` count and the stale-frame count. The rest of this doc is why.

## Event sequences

### Map — bare Xvfb vs icewm

No WM (`MapNotify` → `Expose`, **no `ConfigureNotify` at all** — the
[scaffold's](./scaffold.md#observed-event-order) deadlock warning):

```text
682 f02_x11 map_notify serial=16 send_event=0
685 f02_x11 expose count=0 area=480x320+0+0 serial=16
```

Under icewm the window is adopted first, and the map takes ~3 ms instead of
~0.3 ms:

```text
624 f02_x11 configure_notify size=480x320 pos=0+0 serial=18 send_event=0 override=0
638 f02_x11 reparent_notify parent=0x2000ef serial=18
3565 f02_x11 configure_notify size=480x320 pos=4+24 serial=18 send_event=1 override=0
3596 f02_x11 map_notify serial=18 send_event=0
3655 f02_x11 expose count=0 area=480x320+0+0 serial=18
```

Annotated: a **real** `ConfigureNotify` (the WM configuring the window inside
its new frame, position parent-relative `0+0`), `ReparentNotify` (the frame
window `0x2000ef`), a **synthetic** `ConfigureNotify` (`send_event=1`,
position `4+24` — _root_ coordinates, i.e. the 4 px border + 24 px titlebar of
the icewm frame), then `MapNotify`, then `Expose`. The map itself was withheld:
per the [X protocol][xproto] `MapWindow` spec, with `SubstructureRedirect`
selected on the root by another client, "a `MapRequest` event is generated, but
the window remains unmapped" — icewm maps it after decorating.

### Self-resize, no WM — the structural stale frame

One step of the storm (request → stale frame → `ConfigureNotify` → realloc →
`Expose` → correct frame):

```text
3541 f02_x11 step name=XResizeWindow conn=self n=1 size=640x400
3891 f02_x11 stale_frame frame=7 size=480x320 pending=640x400
3902 f02_x11 configure_notify size=640x400 pos=0+0 serial=25 send_event=0 override=0
3905 f02_x11 resize size=640x400 scale=1
4109 f02_x11 buffer_realloc size=640x400 shm=1 bytes=1024000
4112 f02_x11 expose count=0 area=639x400+0+0 serial=25
```

`XResizeWindow` is asynchronous, so the demo presents exactly **one frame at
the old size** between the request and the notification — flagged
`stale_frame` by comparing the presented size against the last requested size.
All 6 spaced self-resizes show exactly one; it is structural, not a bug to fix:
the authoritative size is only ever what `ConfigureNotify` reports. (This is
precisely the artifact window Wayland's configure/ack/commit negotiation
closes.)

### The burst — three requests, three notifications, no coalescing

```text
25675 f02_x11 step name=XResizeWindow conn=self_burst n=1 size=600x380
25678 f02_x11 step name=XResizeWindow conn=self_burst n=2 size=440x300
25679 f02_x11 step name=XResizeWindow conn=self_burst n=3 size=560x360
25905 f02_x11 stale_frame frame=43 size=360x260 pending=560x360
25916 f02_x11 configure_notify size=600x380 pos=0+0 serial=91 send_event=0 override=0
26059 f02_x11 buffer_realloc size=600x380 shm=1 bytes=912000
26063 f02_x11 configure_notify size=440x300 pos=0+0 serial=92 send_event=0 override=0
26106 f02_x11 buffer_realloc size=440x300 shm=1 bytes=528000
26110 f02_x11 configure_notify size=560x360 pos=0+0 serial=93 send_event=0 override=0
26151 f02_x11 buffer_realloc size=560x360 shm=1 bytes=806400
```

The server does **not** coalesce: every `ConfigureWindow` request produces its
own `ConfigureNotify` (serials 91/92/93), and the demo's naive
realloc-on-every-notify therefore tears down and rebuilds the SHM segment
twice for sizes that were already obsolete when the events were read. A
production loop should drain the queue and realloc only for the **last**
`ConfigureNotify` of a batch — the demo deliberately doesn't, to make the cost
visible (`reallocs=14` for 13 size changes plus the initial allocation).

### External-client resize, no WM — indistinguishable except by bookkeeping

The second connection (`fd=4`) resizes the window it does not own:

```text
29058 f02_x11 step name=XOpenDisplay conn=external fd=4
29091 f02_x11 step name=XResizeWindow conn=external n=1 size=500x340
29483 f02_x11 stale_frame frame=49 size=560x360 pending=500x340
29506 f02_x11 configure_notify size=500x340 pos=0+0 serial=111 send_event=0 override=0
29660 f02_x11 buffer_realloc size=500x340 shm=1 bytes=680000
29662 f02_x11 expose count=0 area=500x340+0+0 serial=111
```

The event is byte-for-byte the same shape as the self-resize one:
`send_event=0`, `override=0`, same ordering, one stale frame. **X11 gives the
app no way to tell who resized it** — a `Window` is a server-side resource any
authenticated client may configure ([`XResizeWindow`][resizewindow] takes any
`Window`, not just your own). The only distinguisher is the app's own
bookkeeping (the demo knows because it issued the request itself on `dpy2`).
Note the `serial` field is no help: it names the last request _the receiving
connection_ sent (here the demo's own `XShmPutImage` traffic), not the request
that caused the event — see [serial semantics](#serial-semantics) below.

### WM-mediated resize — `XResizeWindow` becomes a _request to the WM_

The headline finding. Under icewm, the same `XResizeWindow` call no longer
resizes anything directly: per the [X protocol][xproto] `ConfigureWindow`
spec, "if the override-redirect attribute of the window is `False` and some
other client has selected `SubstructureRedirect` on the parent, then a
`ConfigureRequest` event is generated, and no further processing is
performed." The WM gets the event and decides. Observed grant latency: 0.5–
**5.4 ms** (vs 0.2–0.4 ms on bare Xvfb), with up to **6 stale frames** for one
resize, and icewm sat on the first three requests and granted them in one
batch:

```text
6183 f02_x11 step name=XResizeWindow conn=self n=1 size=640x400
6530 f02_x11 stale_frame frame=7 size=480x320 pending=640x400
        ... 5 more stale frames at 480x320 ...
8397 f02_x11 step name=XResizeWindow conn=self n=2 size=320x240
        ... 6 stale frames ...
10694 f02_x11 step name=XResizeWindow conn=self n=3 size=800x520
        ... 2 stale frames ...
11613 f02_x11 configure_notify size=640x400 pos=0+0 serial=40 send_event=0 override=0
12394 f02_x11 buffer_realloc size=640x400 shm=1 bytes=1024000
12409 f02_x11 expose count=0 area=484x324+0+0 serial=40
12425 f02_x11 expose count=1 area=156x324+484+0 serial=40
12438 f02_x11 expose count=0 area=640x76+0+324 serial=40
12451 f02_x11 configure_notify size=640x400 pos=0+24 serial=40 send_event=1 override=0
12464 f02_x11 configure_notify size=640x400 pos=0+24 serial=40 send_event=1 override=0
12477 f02_x11 configure_notify size=320x240 pos=0+0 serial=40 send_event=0 override=0
        ... grant of n=2, then grant of n=3, same pattern ...
```

Three things to read out of that:

1. **Every grant arrives as a real + synthetic `ConfigureNotify` pair** (icewm
   sometimes sends the synthetic twice). The real one (`send_event=0`) is the
   server resizing the client window inside the frame, position
   parent-relative; the synthetic one (`send_event=1`) is icewm complying with
   [ICCCM §4.1.5][icccm]: "the general rule is that coordinates in real
   `ConfigureNotify` events are in the parent's space; in synthetic events,
   they are in the root space" — hence `pos=0+24`, the client area's root
   position under the titlebar. Code that recomputes layout from
   `ConfigureNotify` positions must check `send_event` or it will mix two
   coordinate systems.
2. **`Expose` arrives as a multi-rectangle batch** (`count=1`, then `count=0`)
   — the redraw gate must be `count == 0` (last of the batch), as
   [`Expose`][expose] documents, or the demo would redraw per rectangle.
3. **The WM may batch or delay grants arbitrarily.** Requests n=1–3 were
   granted back-to-back ~5 ms later; an app that assumed one
   `ConfigureNotify` per request, in order and promptly, would mis-track its
   own size. The 26 stale frames (vs 11 on bare Xvfb) are the same structural
   artifact as before, just with a longer and WM-controlled window.

The external-connection resizes under icewm go through the **same redirect**
(the second client's `ConfigureWindow` also hits the WM) and were granted in
~0.4 ms each with the same real+synthetic pair — under a WM, the self/external
distinction disappears entirely: _every_ resize is WM-mediated.

## Findings

- **Who picks the final size: the server — or, with a WM, the WM.**
  `XResizeWindow` is fire-and-forget; without a WM the server applies it
  verbatim, with a WM it degrades to a `ConfigureRequest` _suggestion_ the WM
  may delay, batch, or (for sizes violating its constraints) modify. The app
  finds out only from `ConfigureNotify`, and only that event is authoritative.
  The [F02][f02] contrast: X11 _notifies_, Wayland _negotiates_.
- **One stale-size frame per resize is the structural minimum** (11 across the
  bare-Xvfb storm); a WM stretches it to many (26 under icewm). X11 has no
  mechanism to atomically pair "new size" with "first frame at the new size".
- **`ConfigureNotify` reports sizes the screen cannot show.** The storm's
  900×560 on Xvfb's 640×480 screen is granted and reported in full —
  `quirk name=beyond_screen configure=900x560 screen=640x480` — while the
  matching `Expose` is clipped to `639x479`. Logical window geometry and
  visible region are independent; sizing a backbuffer from `Expose` rectangles
  would be a bug ([`ConfigureNotify`][confnotify] geometry is the contract).
- <a id="serial-semantics"></a>**`serial` cannot attribute events.** Per the
  Xlib event-structure definition, `serial` is the number "of the last request
  processed by the server" _on this connection_. In the bare run each
  resize's events carry the serial of the demo's own latest `XShmPutImage`; in
  the icewm run the entire three-grant batch — nine `ConfigureNotify`/`Expose`
  events caused by _icewm's_ requests — shares one stale `serial=40`. It
  orders the stream; it does not identify causes.
- **Per-resize realloc is the worst-case strategy and still cheap on X11**
  (~40–200 µs per SHM segment rebuild, `bytes=240000`…`2016000` across the
  storm), but each realloc burns a fresh `ShmSeg` XID and a SysV segment;
  a real renderer should allocate max-size or pool, and must coalesce
  `ConfigureNotify` batches (see the burst above).
- **Correctness held in all four scenarios** — self, burst, external, and
  WM-mediated: every frame presented at the then-authoritative size, every
  `buffer_realloc` matches its `configure_notify`, `errors=0` from the
  `XSetErrorHandler` tally (no `BadShmSeg`/`BadDrawable`/`BadWindow`), final
  size restored to 480×320, exit 0.

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f02-resize
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f02-resize
```

For the WM-mediated variant, run the built binary inside Xvfb with `icewm`
started first (Xvfb itself ships no WM):

```bash
nix develop -c nix shell nixpkgs#icewm -c xvfb-run -a bash -c \
    'icewm & sleep 2; WSI_AUTO_EXIT=1 docs/research/window-system-integration/os-apis/x11/examples/f02-resize/build/f02_resize_x11'
```

`WSI_NO_SHM=1` forces the `XPutImage` presentation path; no reachable display
prints `SKIP: no X11 display` and exits 0. The demo exits non-zero if any X
protocol error was reported.

## Sources

- **[F02 spec][f02]** — requirements 1–4 (gradient geometry, programmatic
  storm, per-event logging, allocation-strategy finding).
- **[X11 scaffold findings](./scaffold.md)** — the base implementation, the
  original stale-frame and beyond-screen observations, and the `xtrace` proof
  that `XResizeWindow` is a `ConfigureWindow` request on the wire.
- **[X Window System Protocol][xproto]** — `ConfigureWindow` and `MapWindow`
  under `SubstructureRedirect` (both verbatim quotes above).
- **[ICCCM §4.1.5 — Configuring the Window][icccm]** — real vs synthetic
  `ConfigureNotify` and the parent-space/root-space coordinate rule (verbatim
  quote above).
- **Xlib reference (Tronche mirror)** — [`XResizeWindow`][resizewindow],
  [`ConfigureNotify`][confnotify], [`Expose`][expose].
- Demo sources: [`app.d`](./examples/f02-resize/app.d),
  [`instrument.d`](./examples/f02-resize/instrument.d), and the `c.c` ImportC
  shim alongside them; the [F01 findings](./f01-first-pixel.md) for the init
  side of the same event-order story.

<!-- References -->

[f02]: ../features/f02-resize.md
[xproto]: https://xorg.freedesktop.org/archive/current/doc/xproto/x11protocol.html
[icccm]: https://tronche.com/gui/x/icccm/sec-4.html
[resizewindow]: https://tronche.com/gui/x/xlib/window/XResizeWindow.html
[confnotify]: https://tronche.com/gui/x/xlib/events/window-state-change/configure.html
[expose]: https://tronche.com/gui/x/xlib/events/exposure/expose.html
