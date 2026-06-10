# X11 scaffold — findings

What it takes to go from `XOpenDisplay` to a software-rendered, resizable,
cleanly-closing window on X11, measured. The scaffold,
[`./examples/scaffold/app.d`](./examples/scaffold/app.d), is the evolved form of
the survey's minimal example ([`./example/app.d`](./example/app.d)): same
ImportC binding style (the `c.c` shim
`#include`s the real `<X11/Xlib.h>`, `<X11/extensions/XShm.h>`, `<sys/shm.h>`,
and `<poll.h>`), but implementing the full demo contract the feature demos
([F01][f01], [F02][f02]) build on: a `poll(2)`-driven readiness loop, a
[MIT-SHM][shm-spec] backbuffer with an `XPutImage` fallback, redraw-on-`Expose`,
realloc-on-`ConfigureNotify`, the `WM_DELETE_WINDOW` close handshake, and the
shared [`instrument.d`](./examples/scaffold/instrument.d) event log. All numbers
below are from a Tier-A run under `xvfb-run` (Xvfb, no window manager,
`WSI_AUTO_EXIT=1`), exit code 0.

**Last reviewed:** June 10, 2026

## Concepts before the first pixel

Distinct platform object/handle types touched between `init_start` and
`first_pixel_presented` (the [F01][f01] concept count):

| #   | Type                                 | What it is                                                                          |
| --- | ------------------------------------ | ----------------------------------------------------------------------------------- |
| 1   | `Display*`                           | the connection: socket + output buffer + event queue                                |
| 2   | `Window`                             | server-side resource, a 32-bit `XID`                                                |
| 3   | `Atom`                               | interned string id (`WM_DELETE_WINDOW`, `WM_PROTOCOLS`)                             |
| 4   | `Visual*`                            | pixel-format description of the screen                                              |
| 5   | `GC`                                 | graphics context (another `XID`; the default one suffices)                          |
| 6   | `XImage*`                            | client-side image descriptor (layout + data pointer)                                |
| 7   | `ShmSeg` (in `XShmSegmentInfo`)      | the MIT-SHM segment's **X resource id** — the server names the segment by `XID` too |
| 8   | `XEvent`                             | the discriminated event union (incl. `XShmCompletionEvent`)                         |
| 9   | SysV shm segment (`shmid`/`shmaddr`) | the **kernel** handle pair behind the pixels — not an X concept at all              |

**9 concepts** on the MIT-SHM path (8 X11-side + 1 kernel-side); the plain
`XPutImage` fallback needs only **7** (drop rows 7 and 9). For comparison, the
minimal [`./example/app.d`](./example/app.d) touches 6 (no `XImage`, no SHM —
it draws server-side rectangles through the `GC`).

## Lines of code

| File                                                                   | Lines | Role                                        |
| ---------------------------------------------------------------------- | ----- | ------------------------------------------- |
| [`./examples/scaffold/app.d`](./examples/scaffold/app.d)               | 412   | the demo (the [F01][f01] LOC figure)        |
| [`./examples/scaffold/instrument.d`](./examples/scaffold/instrument.d) | 50    | shared logger (excluded from the LOC count) |
| `c.c` (in `./examples/scaffold/`)                                      | 16    | ImportC shim (excluded)                     |

## Init sequence and timing

The instrument log of one `xvfb-run` auto-exit run, `init_start` through
`first_pixel_presented` (microseconds since `init_start`; format
`<monotonic_us> <DEMO> <EVENT_KIND> key=value ...` per the [F01][f01] spec):

```text
0 x11_scaffold init_start
268 x11_scaffold step name=XOpenDisplay fd=3
330 x11_scaffold step name=XShmQueryExtension available=1
343 x11_scaffold step name=XShmGetEventBase completion_event=65
356 x11_scaffold step name=XCreateSimpleWindow xid=0x200001
370 x11_scaffold step name=XStoreName
398 x11_scaffold step name=XInternAtom atom=233
425 x11_scaffold step name=XSetWMProtocols
430 x11_scaffold step name=XSelectInput
435 x11_scaffold step name=XMapWindow
439 x11_scaffold window_created xid=0x200001 size=480x320
456 x11_scaffold step name=XShmCreateImage size=480x320 bpl=1920 bpp=32
475 x11_scaffold step name=shmget shmid=65538 bytes=614400
495 x11_scaffold step name=shmat ok=1
768 x11_scaffold step name=XShmAttach
772 x11_scaffold step name=XSync
777 x11_scaffold step name=shmctl_IPC_RMID
782 x11_scaffold first_configure kind=MapNotify size=480x320
794 x11_scaffold expose count=0 area=480x320+0+0
1373 x11_scaffold frame_callback t=1373 frame=1 size=480x320
1518 x11_scaffold first_pixel_presented method=XShmCompletionEvent drawable=0x200001
```

**Total `init_start` → `first_pixel_presented`: ~1.5 ms** under Xvfb. Which
steps are round-trips matches the Xlib output-buffer model documented in the
[X11 survey](./index.md#what-it-is): `XOpenDisplay` (connection setup, 268 µs)
and `XInternAtom` (reply-carrying) block; `XCreateSimpleWindow`, `XSelectInput`,
and `XMapWindow` are pure client-side marshalling (4–15 µs each). The one
deliberate round-trip in the SHM setup — the `XSync` between `XShmAttach` and
`shmctl(IPC_RMID)` (495 → 768 µs, the gap shows the flush+reply) — exists so the
server has attached the segment before the client marks it for deletion, which
makes the segment crash-proof: the kernel reclaims it as soon as both processes
detach, even if the demo dies.

`first_pixel_presented` is confirmed by the **`XShmCompletionEvent`** the demo
requests (`send_event=True` on `XShmPutImage`) — 145 µs after the put was
issued. On the fallback path (forced with `WSI_NO_SHM=1`) there is no completion
contract at all; the demo logs `first_pixel_presented method=XPutImage_XSync`
after an `XSync` round-trip, which proves the server _processed_ the put, not
that anything reached a screen. Core X11 has no true present confirmation
without the Present extension — the [F01][f01]-mandated caveat.

## Observed event order

### Map + first draw (Xvfb, no window manager)

```text
782 x11_scaffold first_configure kind=MapNotify size=480x320
794 x11_scaffold expose count=0 area=480x320+0+0
1373 x11_scaffold frame_callback t=1373 frame=1 size=480x320
1518 x11_scaffold first_pixel_presented method=XShmCompletionEvent drawable=0x200001
```

`XMapWindow` produces **`MapNotify` then `Expose`, and no `ConfigureNotify` at
all** — with no window manager running, nobody reparents or configures the
window, so its creation geometry is never "corrected" and the first
structure-mask event is `MapNotify`. The demo's `first_configure` therefore
reports `kind=MapNotify`. Under a real WM, expect a `ConfigureNotify` (from the
WM's reparent/placement) before or after `MapNotify` — code must treat the two
as one "now you are on screen at size WxH" signal. The [`xtrace`][xtrace] dump
confirms the wire order — both events arrive back-to-back in the same read,
queued behind the `XSync` reply:

```text
000:<:0010:  8: Request(8): MapWindow window=0x00200001
000:<:0011: 16: MIT-SHM-Request(130,1): Attach shmseg=0x00200002 shmid=0x00008037 readonly=false(0x00)
000:<:0012:  4: Request(43): GetInputFocus
000:>:0012: Event MapNotify(19) event=0x00200001 window=0x00200001 override-redirect=false(0x00)
000:>:0012: Event Expose(12) window=0x00200001 x=0 y=0 width=480 height=320 count=0x0000
000:>:0012:32: Reply to GetInputFocus: revert-to=None(0x00) focus=PointerRoot(0x00000001)
```

### One programmatic resize (from the 10-step `XResizeWindow` storm)

```text
4761 x11_scaffold frame_callback t=4761 frame=10 size=480x320
4787 x11_scaffold step name=XResizeWindow n=1 size=640x400
5153 x11_scaffold frame_callback t=5153 frame=11 size=480x320
5170 x11_scaffold resize size=640x400 scale=1
5367 x11_scaffold buffer_realloc size=640x400 shm=1 bytes=1024000
5383 x11_scaffold expose count=0 area=639x400+0+0
6428 x11_scaffold frame_callback t=6428 frame=12 size=640x400
```

The order is **request → (stale frame) → `ConfigureNotify` → `Expose` →
correctly-sized frame**. Note frame 11: the demo presented one more frame at the
_old_ 480×320 between issuing `XResizeWindow` and receiving the
`ConfigureNotify` — the request is asynchronous, and the authoritative size is
only ever what `ConfigureNotify` reports ([F02][f02]'s "who picks the final
size": on X11 the server/WM does, and the app finds out by event). Every resize
also delivered a fresh `Expose` (Xvfb keeps no backing store, so the content is
discarded on resize), so redraw-on-`Expose` alone already repaints after
resizes; the demo additionally redraws on the size change itself. On the wire
(`xtrace`), `XResizeWindow` is just a `ConfigureWindow` request:

```text
000:<:001d: 20: Request(12): ConfigureWindow window=0x00200001 values={width=640 height=400}
000:>:001e: Event ConfigureNotify(22) event=0x00200001 window=0x00200001 ... width=640 height=400 ...
000:>:001f: Event Expose(12) window=0x00200001 x=0 y=0 width=639 height=400 count=0x0000
```

The full storm — 10 `XResizeWindow` calls, 10 `resize`+`buffer_realloc` pairs,
120 frames — ran with no `BadShmSeg`/`BadDrawable` errors and exited 0 in ~74 ms.

## MIT-SHM: what it buys and the completion contract

What the extension actually provides, per [the MIT-SHM spec][shm-spec]:

> The basic capability provided is that of shared memory XImages. This is
> essentially a version of the ximage interface where the actual image data is
> stored in a shared memory segment, and thus need not be moved through the Xlib
> interprocess communication channel.

So `XShmPutImage` sends a **40-byte request naming the segment** instead of
streaming 614 400 bytes of pixels (480×320×4) through the socket per frame, as
plain `XPutImage` must. The price is a real synchronization contract:

> If this parameter \[`send_event`\] is passed as True, the server will generate
> a "completion" event when the image write is complete; thus your program can
> know when it is safe to begin manipulating the shared memory segment again. …
> If you modify the shared memory segment before the arrival of the completion
> event, the results you see on the screen may be inconsistent.

The completion event has no fixed type code — it is
`XShmGetEventBase(dpy) + ShmCompletion` (65 on this server), discovered at
runtime; the `XShmCompletionEvent` carries the `drawable`, the `shmseg`, and the
offset of the finished put. The scaffold treats it as a one-frame-in-flight
throttle: after each `XShmPutImage` it refuses to draw until the completion
arrives, which under Xvfb paces frames at roughly one server round-trip
(~0.4–0.6 ms/frame in the log). The fallback path (extension absent, attach
failure, or `WSI_NO_SHM=1`) logs `step name=shm_fallback reason=...` and
degrades exactly as the spec instructs — "otherwise your program should operate
using conventional Xlib calls" — with `XPutImage` + `XSync`.

Teardown follows the spec's prescribed order: `XSync` (drain in-flight puts) →
`XShmDetach` → `XDestroyImage` → `shmdt`, the segment having been
`IPC_RMID`-marked at creation.

## Surprises

- **`XSetWMProtocols` is two requests and a hidden round-trip.** The `xtrace`
  dump shows libX11 interning `WM_PROTOCOLS` itself (a second `InternAtom`
  round-trip after the demo's own `WM_DELETE_WINDOW` one) before the
  `ChangeProperty`. Convenience functions hide protocol traffic.
- **`XSync` is `GetInputFocus` on the wire.** Xlib implements the
  flush-and-wait by sending any reply-bearing no-op request and waiting for the
  reply — visible in the trace above.
- **No `ConfigureNotify` on map without a WM.** `first_configure` comes from
  `MapNotify`; a demo that waits for `ConfigureNotify` before drawing
  deadlocks on a WM-less server (Xvfb, CI).
- **`ConfigureNotify` reports sizes the screen can't show.** Resizing to
  900×560 on the 640×480 default Xvfb screen succeeds and reports the full
  900×560 — but the subsequent `Expose` is clipped to `639x479`. The window's
  logical size and its visible region are independent; sizing the backbuffer
  from `Expose` dimensions would be a bug.
- **One stale-size frame per resize is structural.** `XResizeWindow` is
  asynchronous; anything presented between the request and the
  `ConfigureNotify` is at the old size (frame 11 above). Harmless here, but
  it is exactly the artifact window Wayland's configure/ack protocol closes.
- **The shm segment is also an X resource.** Each realloc consumed a fresh
  `ShmSeg` `XID` (`0x200002` … `0x20000b` across the storm) — the server
  names client memory with the same id machinery as windows.
- **`shmget` with `0600` works locally despite the spec's warning** that many
  servers require other-readable (`0777`) segments; over the Unix socket the
  server authenticated the client uid, as the spec's local-transport note
  describes. Remote/TCP clients can't use MIT-SHM at all — which is what the
  `WSI_NO_SHM=1` switch simulates.
- **ImportC gaps are all macros.** `ConnectionNumber`, `XDestroyImage`,
  `ShmCompletion`, `POLLIN`, `IPC_CREAT` are object/function-like macros the
  shim cannot export; the demo uses the function forms (`XConnectionNumber`),
  calls `img.f.destroy_image(img)` directly, and re-declares the constants —
  same discipline as [`./example/app.d`](./example/app.d).

## What the scaffold adds over the minimal example

[`./example/app.d`](./example/app.d) (81 lines) proves the irreducible open → map →
`Expose` → draw-once sequence and exits. The scaffold
([`./examples/scaffold/app.d`](./examples/scaffold/app.d), 412 lines) turns that
into the base every feature demo evolves from:

| Capability      | `example/`                       | `examples/scaffold/`                                                                     |
| --------------- | -------------------------------- | ---------------------------------------------------------------------------------------- |
| Event loop      | blocking `XNextEvent`            | `poll(2)` on `XConnectionNumber(dpy)`, drain via `XPending` — never blocks in Xlib       |
| Drawing         | one server-side `XFillRectangle` | software gradient in a client-owned buffer, presented per frame                          |
| Presentation    | core protocol only               | MIT-SHM (`XShmCreateImage`/`XShmPutImage` + completion events), `XPutImage` fallback     |
| Resize          | ignored                          | `ConfigureNotify` → log + backbuffer/segment realloc + redraw                            |
| Lifecycle       | exits on first `Expose`          | runs until `WM_DELETE_WINDOW`; `WSI_AUTO_EXIT=1` bounded run with a 10-step resize storm |
| Instrumentation | one `ok:` line                   | full [F01][f01] event log via [`instrument.d`](./examples/scaffold/instrument.d)         |
| Teardown        | `XCloseDisplay` only             | spec-ordered SHM detach + image destroy + window destroy + close                         |

Build and run (Tier A, from the repo root):

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/scaffold
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/scaffold
```

No reachable display prints `SKIP: no X11 display` and exits 0 (the research-doc
headless guard); `WSI_NO_SHM=1` forces the fallback presentation path.

## Sources

- **[The MIT Shared Memory Extension][shm-spec]** — the shared-memory `XImage`
  model, the `send_event`/completion contract, attach/detach sequencing, and the
  segment-permission note (all quotes above).
- **[Xlib — C Language X Interface][xlib]** — the output-buffer/flush model the
  timings exhibit; `XSync`; event-queue functions (`XPending`, `XNextEvent`).
- **Xlib reference (Tronche mirror)** — [`XPutImage`/image functions][putimage],
  [`Expose`][expose], [`ConfigureNotify`][confnotify],
  [`XResizeWindow`][resizewindow], [`XSetWMProtocols`][setwmprotocols].
- **[`xtrace`][xtrace]** — the protocol dumps quoted above
  (`nix shell nixpkgs#xtrace`, faking a display in front of Xvfb).
- **This survey** — the [X11 deep-dive](./index.md) (binding style, output-buffer
  model, WM-as-a-client); the [F01][f01]/[F02][f02] feature specs the scaffold
  implements; the runnable sources
  [`./examples/scaffold/app.d`](./examples/scaffold/app.d) and
  [`./examples/scaffold/instrument.d`](./examples/scaffold/instrument.d)
  (plus the `c.c` ImportC shim alongside them).

<!-- References -->

[f01]: ../features/f01-first-pixel.md
[f02]: ../features/f02-resize.md
[shm-spec]: https://www.x.org/releases/current/doc/xextproto/shm.html
[xlib]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
[putimage]: https://tronche.com/gui/x/xlib/graphics/XPutImage.html
[expose]: https://tronche.com/gui/x/xlib/events/exposure/expose.html
[confnotify]: https://tronche.com/gui/x/xlib/events/window-state-change/configure.html
[resizewindow]: https://tronche.com/gui/x/xlib/window/XResizeWindow.html
[setwmprotocols]: https://tronche.com/gui/x/xlib/ICC/client-to-window-manager/XSetWMProtocols.html
[xtrace]: https://salsa.debian.org/debian/xtrace
