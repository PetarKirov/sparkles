# X11 F01 — first pixel & init cost

What sits between `XOpenDisplay` and a confirmed software frame, call by call.
The demo, [`./examples/f01-first-pixel/app.d`](./examples/f01-first-pixel/app.d),
is the [scaffold](./scaffold.md) cut down to exactly the
[F01 spec][f01]'s init-to-first-pixel path: connect, create + map a window,
allocate a [MIT-SHM][shm-spec] backbuffer, present one gradient frame, and exit
the moment the present is confirmed. Every initialization API call emits a
`step name=<call> rt=<0|1>` line — `rt=1` marking the calls that block on a
server reply — because on X11 _that_ is the interesting measurement: in Xlib's
[output-buffer model][xlib], most of "creating a window" is free local
marshalling, and the wall-clock cost concentrates in a handful of round-trips.
All numbers are Tier-A runs under `xvfb-run` (exit 0); the WM comparison runs
`icewm` inside the same Xvfb.

**Last reviewed:** June 10, 2026

## The instrumented run

One complete `WSI_AUTO_EXIT=1` log, `init_start` → `first_pixel_presented`
(microseconds since `init_start`; format per the [F01 spec][f01]):

```text
0 f01_x11 init_start
283 f01_x11 step name=XOpenDisplay rt=1
285 f01_x11 step name=XConnectionNumber fd=3 rt=0
287 f01_x11 step name=XDefaultScreen/Root/Visual/Depth rt=0
335 f01_x11 step name=XShmQueryExtension available=1 rt=1
337 f01_x11 step name=XShmGetEventBase completion_event=65 rt=0
339 f01_x11 step name=XCreateSimpleWindow xid=0x200001 rt=0
341 f01_x11 step name=XStoreName rt=0
366 f01_x11 step name=XInternAtom atom=233 rt=1
383 f01_x11 step name=XSetWMProtocols rt=1 note=hidden_InternAtom
385 f01_x11 step name=XSelectInput rt=0
387 f01_x11 step name=XMapWindow rt=0
389 f01_x11 window_created xid=0x200001 size=480x320
391 f01_x11 step name=XShmCreateImage size=480x320 bpl=1920 bpp=32 rt=0
400 f01_x11 step name=shmget shmid=65592 bytes=614400 rt=kernel
408 f01_x11 step name=shmat ok=1 rt=kernel
410 f01_x11 step name=XShmAttach rt=0
683 f01_x11 step name=XSync rt=1 us=272
686 f01_x11 step name=shmctl_IPC_RMID rt=kernel
687 f01_x11 first_configure kind=MapNotify size=480x320
689 f01_x11 expose count=0 area=480x320+0+0
1278 f01_x11 step name=XShmPutImage rt=0 send_event=1
1286 f01_x11 frame_callback t=1286 frame=1 size=480x320
1427 f01_x11 first_pixel_presented method=XShmCompletionEvent drawable=0x200001
1430 f01_x11 summary concepts=9 loc=359 init_to_pixel_us=1430
1431 f01_x11 teardown
```

**Total `init_start` → `first_pixel_presented`: ~1.4 ms** under Xvfb, no WM.

## Round-trips vs fire-and-forget

The step list sorted by what actually costs time. "Round-trip" means the call
synthesizes a reply-bearing request and blocks until the reply arrives — the
distinction the [Xlib manual][xlib] codifies by listing which functions can
generate replies; everything else only appends to Xlib's output buffer:

| Call                                                                                        | `rt` | Cost (µs) | Why                                                                                                                                |
| ------------------------------------------------------------------------------------------- | ---- | --------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `XOpenDisplay`                                                                              | 1    | ~283      | socket connect + auth + connection-setup reply (the screen/visual data comes here)                                                 |
| `XShmQueryExtension`                                                                        | 1    | ~48       | `QueryExtension` reply                                                                                                             |
| `XInternAtom`                                                                               | 1    | ~25       | atom id is in the reply                                                                                                            |
| `XSetWMProtocols`                                                                           | 1    | ~17       | **hidden** round-trip: libX11 interns `WM_PROTOCOLS` itself (xtrace-confirmed in the [scaffold findings](./scaffold.md#surprises)) |
| `XSync` (SHM attach fence)                                                                  | 1    | ~272      | deliberate: server must attach the segment before `shmctl(IPC_RMID)`                                                               |
| `XCreateSimpleWindow`                                                                       | 0    | ~2        | the client _mints the `XID` itself_ and queues the request                                                                         |
| `XStoreName`, `XSelectInput`, `XMapWindow`, `XShmCreateImage`, `XShmAttach`, `XShmPutImage` | 0    | 2–9 each  | pure output-buffer marshalling (`XShmCreateImage` is entirely client-side)                                                         |
| `shmget` / `shmat` / `shmctl`                                                               | —    | ~8 each   | kernel calls, not X protocol at all                                                                                                |

So of ~1.4 ms total, ~0.65 ms is the five round-trips, ~0.6 ms is drawing the
first 614 400-byte gradient (the `expose` → `XShmPutImage` gap), and the
request marshalling for the entire window is noise (~20 µs combined).

### What the async calls hide (`WSI_SYNC_STEPS=1`)

A fire-and-forget call's _server-side_ cost is invisible until something
flushes. `WSI_SYNC_STEPS=1` brackets each async call with an `XSync` and logs
the fence's cost:

```text
259 f01_x11 step name=XCreateSimpleWindow xid=0x200001 rt=0
279 f01_x11 step name=XSync after=XCreateSimpleWindow us=18
...
330 f01_x11 step name=XMapWindow rt=0
532 f01_x11 step name=XSync after=XMapWindow us=200
```

Creating a window costs the server ~18 µs; **mapping it costs ~200 µs** — the
map is where Xvfb allocates/clears the backing resources and generates
`MapNotify`/`Expose`. The "cheap" call is cheap only on the client side; the
ledger balances at the next round-trip. (Total init is unchanged — ~1.4 ms —
because the fences only surface latency the unfenced run pays inside the SHM
`XSync` and the event wait.)

## What "presented" means on X11

The demo requests a completion event on its one `XShmPutImage`
(`send_event=True`) and treats `first_pixel_presented` as the arrival of the
**`XShmCompletionEvent`** (type `XShmGetEventBase(dpy) + ShmCompletion` = 65
here, a runtime value). Per the [MIT-SHM spec][shm-spec], that event means the
server "when the image write is complete" — i.e. the server is done **reading
the segment**. It does _not_ mean the pixels reached glass:

> [!IMPORTANT]
> Core X11 has no presentation confirmation. The completion event proves the
> server consumed the put; an `XSync` after a plain `XPutImage` (the
> `WSI_NO_SHM=1` fallback, which logs
> `first_pixel_presented method=XPutImage_XSync`) proves only that the server
> _processed_ it. Knowing when a frame actually hit the screen requires the
> [Present extension][present] (`PresentCompleteNotify`) — the
> [F01 spec][f01]-mandated caveat, and the X11 column's structural gap next to
> Wayland's `frame` callback.

The fallback run confirms both paths cost about the same under Xvfb (1.20 ms
no-SHM vs 1.43 ms SHM — at one 480×320 frame the SHM setup tax outweighs the
pixel-streaming tax; SHM wins on every _subsequent_ frame).

## Concepts and LOC

The demo emits the [F01][f01] summary line itself:

```text
1430 f01_x11 summary concepts=9 loc=359 init_to_pixel_us=1430
```

**9 concepts** on the MIT-SHM path (`Display*`, `Window`, `Atom`, `Visual*`,
`GC`, `XImage*`, the `ShmSeg` XID, `XEvent`, and the kernel SysV segment), **7**
on the fallback path (`summary concepts=7` in the `WSI_NO_SHM=1` run) — the
itemized table is in the [scaffold findings](./scaffold.md#concepts-before-the-first-pixel).
**359 LOC** ([`app.d`](./examples/f01-first-pixel/app.d), excluding the shared
[`instrument.d`](./examples/f01-first-pixel/instrument.d) logger and the 16-line
`c.c` ImportC shim).

## WM vs no WM: same code, 3× the time, different first event

The same binary under Xvfb with `icewm` running:

```text
422 f01_x11 step name=shmctl_IPC_RMID rt=kernel
631 f01_x11 first_configure kind=ConfigureNotify size=480x320 send_event=0
3657 f01_x11 configure_notify size=480x320 send_event=1
3662 f01_x11 map_notify
3746 f01_x11 expose count=0 area=480x320+0+0
4360 f01_x11 step name=XShmPutImage rt=0 send_event=1
4508 f01_x11 first_pixel_presented method=XShmCompletionEvent drawable=0x400001
4511 f01_x11 summary concepts=9 loc=359 init_to_pixel_us=4511
```

Two findings:

- **First pixel takes ~4.5 ms instead of ~1.4 ms.** `XMapWindow` no longer
  maps: per the [X protocol][xproto], with `SubstructureRedirect` selected on
  the root "a `MapRequest` event is generated, but the window remains
  unmapped" — the WM must reparent, decorate, and map on the client's behalf,
  and the ~3 ms gap between the real `ConfigureNotify` (631 µs) and `MapNotify`
  (3662 µs) is icewm doing that.
- **The first structure event flips kind.** Bare Xvfb delivers
  `MapNotify` → `Expose` and **no `ConfigureNotify` at all**; under a WM the
  first event is a `ConfigureNotify` (reparent/placement), followed by an ICCCM
  _synthetic_ one (`send_event=1`), then `MapNotify`. Init code must treat
  `MapNotify` and `ConfigureNotify` as one "on screen at WxH" signal — waiting
  specifically for `ConfigureNotify` deadlocks on WM-less servers (CI), waiting
  for `MapNotify` alone misses the WM's size correction. The full event-order
  analysis is in the [F02 findings](./f02-resize.md).

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f01-first-pixel
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f01-first-pixel
```

`WSI_SYNC_STEPS=1` adds the per-call `XSync` fences; `WSI_NO_SHM=1` forces the
`XPutImage` fallback; no reachable display prints `SKIP: no X11 display` and
exits 0.

## Sources

- **[F01 spec][f01]** — the requirements this demo implements (event set,
  concept count, LOC, the present-confirmation honesty rule).
- **[X11 scaffold findings](./scaffold.md)** — the base the demo was cut from:
  concept table, `xtrace` dumps proving the `XSetWMProtocols` hidden
  `InternAtom` and that `XSync` is `GetInputFocus` on the wire.
- **[Xlib — C Language X Interface][xlib]** — the output-buffer model behind
  the `rt=0`/`rt=1` split; `XSync`; `XOpenDisplay` connection setup.
- **[The MIT Shared Memory Extension][shm-spec]** — the
  `send_event`/completion contract quoted above.
- **[X Window System Protocol][xproto]** — `MapWindow` under
  `SubstructureRedirect` ("a `MapRequest` event is generated, but the window
  remains unmapped").
- **[Present extension][present]** — what actual presentation confirmation
  would require.
- Demo sources: [`app.d`](./examples/f01-first-pixel/app.d),
  [`instrument.d`](./examples/f01-first-pixel/instrument.d), and the `c.c`
  ImportC shim alongside them.

<!-- References -->

[f01]: ../features/f01-first-pixel.md
[shm-spec]: https://www.x.org/releases/current/doc/xextproto/shm.html
[xlib]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
[xproto]: https://xorg.freedesktop.org/archive/current/doc/xproto/x11protocol.html
[present]: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/presentproto.txt
