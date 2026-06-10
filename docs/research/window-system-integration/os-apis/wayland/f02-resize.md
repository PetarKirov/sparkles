# Wayland F02 — resize correctness

Findings from [`./examples/f02-resize/app.d`](./examples/f02-resize/app.d), the
[F02 spec][f02]'s Wayland demo. Wayland does not _notify_ a client of a new size — it
_negotiates_ one: every [`xdg_surface.configure`][p-configure] carries a serial, the
client must [`ack_configure`][p-ack] that serial before its next commit, and for
maximized/fullscreen states the committed buffer **must** match the configured size. The
demo proves the contract under a six-transition resize storm (maximize → unmaximize →
fullscreen → unfullscreen → maximize → unmaximize), logs every configure with its serial,
size, and full states array, logs the complete buffer (re)allocation story, and — behind
a `--violate` flag, in a separate invocation — breaks the contract once on purpose and
captures the compositor's reaction. Verified Tier A: `weston --backend=headless`
(weston 15.0, libwayland 1.24); normal run exit `0`, violation run exit `0` with the
outcome captured.

**Last reviewed:** June 10, 2026

| Measurement                      | Value                                                                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Storm result                     | 140 frames, 146 commits, **7 configures acked, 6 size changes**, no protocol error, exit `0`                                         |
| Sizes negotiated                 | 640×480 (floating) ⇄ 1024×608 (maximized) ⇄ 1024×640 (fullscreen)                                                                    |
| Buffer strategy                  | per-resize realloc, lazily: 13 allocations, 11 stale-size destroys across 6 size changes (both double-buffer slots churn per resize) |
| Ack → matching commit gap        | 1.4–2.4 ms, dominated by repainting at the new size; the protocol work itself is < 100 µs                                            |
| **Violation outcome (headline)** | **fatal protocol error** — `xdg_wm_base` error 4 (`invalid_surface_state`), connection killed, `wl_display_dispatch` → −1, `EPROTO`  |

## Who picks the size

Three distinct answers were observed, all within one run:

1. **Client picks** — map, unmaximize, unfullscreen: [`xdg_toplevel.configure`][p-tconf]
   suggests `0x0` ("you pick"), states `[]`. The demo restores its remembered floating
   size (640×480). A robust client must carry that memory itself; the compositor does
   not restore it for you.
2. **Compositor dictates** — maximize: `1024x608` with states `[maximized]`. Per the
   [`xdg_toplevel.state` spec][p-states]: "The surface is maximized. The window geometry
   specified in the configure event must be obeyed by the client, or the
   `xdg_wm_base.invalid_surface_state` error is raised." This is the hard constraint the
   violation run targets — and weston enforces it literally (see
   [the violation](#the-violation-commit-the-old-size-after-acking-the-new)).
3. **Compositor bounds** — fullscreen: `1024x640` with states `[fullscreen]`. The spec
   makes fullscreen a _maximum_ ("the client cannot resize beyond it"), with full
   coverage required to avoid letterboxing.

A size _request_ can only be denied implicitly: the client's floating choice is itself
just the size of the buffer it commits, and the compositor's only veto is to configure
again (or, in the constrained states, to kill the connection).

## The observed sequences, one per transition kind

All excerpts are from one Tier-A run: interleaved `WAYLAND_DEBUG=1` wire lines
(`[timestamp.ms]`, `->` = client→compositor request, no arrow = event) and the demo's
instrument lines (µs since `init_start`). These feed the Phase-3 event-sequences
synthesis.

### Map (initial configure)

The [no-buffer-no-window][nbnw] handshake: commit nothing, wait for the compositor to
speak, ack, then attach the first buffer:

```text
 ->  wl_surface#3.commit()                                   # the mandatory no-buffer commit
     xdg_toplevel#8.configure(0, 0, array[0])                # 0x0 = "you pick", states []
528  f02-wayland xdg_toplevel_configure size=0x0 states=[]
     xdg_surface#7.configure(13)                             # the serial to echo
549  f02-wayland configure serial=13 size=640x480 states=[]
 ->  xdg_surface#7.ack_configure(13)                         # ack BEFORE the commit
570  f02-wayland step name=xdg_surface_ack_configure
587  f02-wayland first_configure
 ->  wl_shm_pool#9.create_buffer(new id wl_buffer#10, 0, 640, 480, 2560, 0)
625  f02-wayland buffer_alloc size=640x480 bytes=1228800
 ->  wl_surface#3.attach(wl_buffer#10, 0, 0)
 ->  wl_surface#3.commit()                                   # buffer matches the acked size
1746 f02-wayland first_commit size=640x480
```

### Maximize (`xdg_toplevel.set_maximized`)

Compositor-dictated size; new serial, immediate ack, fresh 1024×608 buffer committed
~2 ms later (allocation + paint), all within one frame interval:

```text
 ->     xdg_toplevel#8.set_maximized()
        xdg_toplevel#8.configure(1024, 608, array[4])        # array[4] = 1×uint32: maximized
329134  f02-wayland xdg_toplevel_configure size=1024x608 states=[maximized]
        xdg_surface#7.configure(14)
329156  f02-wayland configure serial=14 size=1024x608 states=[maximized]
 ->     xdg_surface#7.ack_configure(14)
329176  f02-wayland step name=xdg_surface_ack_configure
329192  f02-wayland resize size=1024x608 scale=1
 ->     wl_shm#5.create_pool(new id wl_shm_pool#9, fd 5, 2490368)
 ->     wl_shm_pool#9.create_buffer(new id wl_buffer#12, 0, 1024, 608, 4096, 0)
329240  f02-wayland buffer_alloc size=1024x608 bytes=2490368
 ->     wl_surface#3.attach(wl_buffer#12, 0, 0)
 ->     wl_surface#3.damage_buffer(0, 0, 1024, 608)
 ->     wl_surface#3.commit()                                # 1024×608, matching the ack
        wl_buffer#10.release()                               # old 640×480 buffer comes back
331630  f02-wayland buffer_release size=640x480
```

### Unmaximize (`xdg_toplevel.unset_maximized`)

The compositor _suggests nothing_: `0x0`, states `[]`. The client restores its
remembered floating size and the stale maximized buffer is destroyed on reuse:

```text
 ->     xdg_toplevel#8.unset_maximized()
        xdg_toplevel#8.configure(0, 0, array[0])             # back to "you pick"
663363  f02-wayland xdg_toplevel_configure size=0x0 states=[]
        xdg_surface#7.configure(15)
663386  f02-wayland configure serial=15 size=640x480 states=[]   # 640x480 = remembered floating size
 ->     xdg_surface#7.ack_configure(15)
663409  f02-wayland step name=xdg_surface_ack_configure
663425  f02-wayland resize size=640x480 scale=1
663441  f02-wayland buffer_destroy size=1024x608 reason=stale_size
 ->     wl_buffer#12.destroy()
 ->     wl_shm_pool#11.create_buffer(new id wl_buffer#10, 0, 640, 480, 2560, 0)
663618  f02-wayland buffer_alloc size=640x480 bytes=1228800
 ->     wl_surface#3.attach(wl_buffer#10, 0, 0)
 ->     wl_surface#3.commit()
```

### Fullscreen (`xdg_toplevel.set_fullscreen`)

Passing a null output lets the compositor pick. Headless weston grants the **full**
1024×640 output — 32 px taller than maximized, because fullscreen covers the panel that
maximize respects:

```text
 ->     xdg_toplevel#8.set_fullscreen(nil)                   # nil output: compositor picks
        xdg_toplevel#8.configure(1024, 640, array[4])        # array[4] = 1×uint32: fullscreen
995740  f02-wayland xdg_toplevel_configure size=1024x640 states=[fullscreen]
        xdg_surface#7.configure(16)
995761  f02-wayland configure serial=16 size=1024x640 states=[fullscreen]
 ->     xdg_surface#7.ack_configure(16)
995783  f02-wayland step name=xdg_surface_ack_configure
995800  f02-wayland resize size=1024x640 scale=1
995816  f02-wayland buffer_destroy size=640x480 reason=stale_size
 ->     wl_shm_pool#13.create_buffer(new id wl_buffer#9, 0, 1024, 640, 4096, 0)
995937  f02-wayland buffer_alloc size=1024x640 bytes=2621440
 ->     wl_surface#3.attach(wl_buffer#9, 0, 0)
 ->     wl_surface#3.commit()
```

Unfullscreen mirrors unmaximize exactly: `configure(0, 0, array[0])`, the client falls
back to 640×480 (serial 17 in this run). The second maximize/unmaximize cycle
(serials 18–19 — not shown) replays the first one identically: the machine is
re-entrant.

### The violation: commit the OLD size after acking the NEW

Separate invocation (`dub run … -- --violate`). The demo acks the maximized configure
_correctly_, then commits a 640×480 buffer against the acked 1024×608 — the one place
the spec makes size a hard constraint:

```text
 ->     xdg_toplevel#8.set_maximized()
        xdg_toplevel#8.configure(1024, 608, array[4])
328852  f02-wayland xdg_toplevel_configure size=1024x608 states=[maximized]
        xdg_surface#7.configure(12)
328877  f02-wayland configure serial=12 size=1024x608 states=[maximized]
 ->     xdg_surface#7.ack_configure(12)                      # the ack is CORRECT
328897  f02-wayland step name=xdg_surface_ack_configure
328912  f02-wayland violation acked_serial=12 acked_size=1024x608 committing=640x480
 ->     wl_shm_pool#9.create_buffer(new id wl_buffer#12, 0, 640, 480, 2560, 0)
 ->     wl_surface#3.attach(wl_buffer#12, 0, 0)
 ->     wl_surface#3.damage_buffer(0, 0, 640, 480)
 ->     wl_surface#3.commit()                                # the lie
330109  f02-wayland violation_commit size=640x480 acked=1024x608
        wl_display#1.error(xdg_wm_base#6, 4, "xdg_surface geometry (640 x 480)
            does not match the configured maximized state (1024 x 608)")
330282  f02-wayland protocol_error interface=xdg_wm_base code=4 object_id=6
```

**Weston's reaction is an immediate fatal protocol error** — no tolerance, no clamping,
no re-configure. The [`wl_display.error`][p-error] event names the culprit object
(`xdg_wm_base#6`), the error code 4 = [`invalid_surface_state`][p-wmerr], and a
human-readable message quoting both geometries verbatim. ~170 µs after the violating
commit, `wl_display_dispatch` returns −1 with `errno == EPROTO`;
`wl_display_get_protocol_error` recovers the (interface, code, object id) triple — but
**not** the message string, which only exists in libwayland's stderr log and the
`WAYLAND_DEBUG` trace. The connection is dead; every subsequent request is discarded.
The demo's stdout verdict:

```text
violation outcome: protocol error — interface=xdg_wm_base code=4 object_id=6 (connection killed by the compositor)
```

Two details worth keeping for the synthesis: the error is posted on the `xdg_wm_base`
_global_ (not the offending `xdg_toplevel`, which also has an `invalid_size` error code
weston chose not to use), and the check fires at **commit time** — acking was fine; the
buffer told the lie.

## Buffer lifetime and allocation strategy

What the `buffer_alloc` / `buffer_destroy` / `buffer_release` stream shows
([F02 §4][f02] asks for the strategy as a finding):

- **A `wl_buffer` is owned by the compositor from `commit` until its
  [`release`][p-release] event.** Weston (which copies `wl_shm` pixels into its
  renderer at repaint) releases ~one frame later — every steady-state frame in the
  trace is commit → ~16 ms → `buffer_release` of that same buffer.
- **Steady state therefore needs only one buffer**; the second slot of the demo's
  double buffer is touched only across resize transitions, when the on-screen buffer is
  still held while the newly-sized one is committed. Double buffering is insurance, not
  throughput — but it is what makes resize race-free against compositors that hold
  buffers longer than weston.
- **Reallocation is per-resize and lazy.** A stale-sized buffer is destroyed only when
  _picked for reuse_ (`buffer_destroy … reason=stale_size`), never while the compositor
  holds it. Hence the 13 allocs / 11 stale destroys for 6 size changes: each transition
  re-allocates the slot it commits immediately, and the _other_ slot one frame later —
  both slots churn on every size change. A pool keyed by size (or one oversized
  allocation) would cut this in half; for a 2.5 MB buffer the `memfd`+`mmap`+pool dance
  measured ~100–200 µs per reallocation.
- The `wl_shm_pool` is destroyed immediately after `create_buffer` (the buffer keeps
  the backing memory alive; the compositor dups the fd) — visible in the trace as
  `create_pool` → `create_buffer` → `destroy()` triplets.

## What surprised us

- **No `activated` state, ever.** Every configure in every Tier-A run carried
  `states=[]`, `[maximized]`, or `[fullscreen]` — never `activated`. Headless weston
  has no seat, so no focus, so no activation. Code that gates rendering or input
  affordances on `activated` would never fire on this backend.
- **Maximized ≠ fullscreen by exactly the panel height**: 1024×608 vs 1024×640 on the
  1024×640 headless output — `weston-desktop-shell`'s 32 px panel is respected by
  maximize and covered by fullscreen. The [scaffold](./scaffold.md#what-surprised-us)
  predicted the first number; the fullscreen delta is new.
- **Configure serials are a per-compositor counter, not per-surface**: this run's first
  configure arrived with serial 13 (earlier demo runs against the same weston instance
  had consumed 1–12). Serials are opaque tokens to echo, nothing more.
- **The violation kills the _connection_, not the window.** A library cannot "catch and
  recover" from a wrong-sized maximized commit: by the time the error event arrives the
  display is unusable (`EPROTO`), and only the (interface, code, id) triple is
  programmatically recoverable — log the stderr line if you want the message.
- **Weston checks geometry only for the constrained states.** The same wrong-sized
  commit in the floating state is, by spec, not a violation at all (the suggested size
  is a suggestion) — which is why the demo arms the violation on `maximized`
  specifically.

## Open questions

- **Other compositors' violation behavior.** Weston is the reference, and it kills.
  Mutter, KWin, and sway each have their own enforcement reputation (sway is reputedly
  permissive about floating sizes; mutter has historically tolerated transient
  mismatches during interactive resize). The demo is compositor-agnostic — re-running
  `--violate` under each is queued in the [manual-run queue](../manual-run-queue.md)
  territory rather than assumed.
- **Interactive (grab-driven) resize storms** produce `states=[resizing]` configures at
  pointer-motion rate; headless weston has no seat to drive them. The
  `resizing`-state path (size is a _maximum_, intermediate mismatches expected) is
  untested here and differs semantically from the maximize path this demo proves.
- **Scale.** The demo logs `scale=1` unconditionally; fractional-scale and
  `preferred_buffer_scale` interactions belong to F08, but the F02 contract ("buffer
  size = configured size × scale") will need re-proving there.

## Sources

- **Protocol** — [`xdg-shell`][p-xdgshell]: [`xdg_surface.configure`][p-configure] /
  [`ack_configure`][p-ack] ("if a client commits the surface in response to the
  configure event, then the client must make an ack_configure request sometime before
  the commit request, passing along the serial of the configure event"),
  [`xdg_toplevel.configure`][p-tconf], [`xdg_toplevel.state`][p-states],
  [`set_fullscreen`][p-setfs], [`xdg_wm_base.error`][p-wmerr]; the [core
  protocol][p-wayland]: [`wl_buffer.release`][p-release], [`wl_display.error`][p-error].
  Glue generated from `wayland-protocols` 1.47 (`stable/xdg-shell/xdg-shell.xml`).
- **Spec implemented** — [F02 resize][f02]; conventions in
  [the features index](../features/index.md); grid cell in
  [the feature matrix](../feature-matrix.md).
- **Baseline** — [the scaffold findings](./scaffold.md) (the single
  maximize/unmaximize storm this demo extends, plus all build gotchas);
  [F01](./f01-first-pixel.md) for the init/first-pixel side of the same machine.
- **Code** — [`./examples/f02-resize/app.d`](./examples/f02-resize/app.d),
  [`./examples/f02-resize/c.c`](./examples/f02-resize/c.c) (adds the
  `xdg_toplevel` fullscreen request wrappers to the scaffold shim),
  [`./examples/f02-resize/instrument.d`](./examples/f02-resize/instrument.d).

<!-- References -->

[f02]: ../features/f02-resize.md
[nbnw]: ../../concepts.md#no-buffer-no-window
[p-wayland]: https://wayland.app/protocols/wayland
[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[p-configure]: https://wayland.app/protocols/xdg-shell#xdg_surface:event:configure
[p-ack]: https://wayland.app/protocols/xdg-shell#xdg_surface:request:ack_configure
[p-tconf]: https://wayland.app/protocols/xdg-shell#xdg_toplevel:event:configure
[p-states]: https://wayland.app/protocols/xdg-shell#xdg_toplevel:enum:state
[p-setfs]: https://wayland.app/protocols/xdg-shell#xdg_toplevel:request:set_fullscreen
[p-wmerr]: https://wayland.app/protocols/xdg-shell#xdg_wm_base:enum:error
[p-error]: https://wayland.app/protocols/wayland#wl_display:event:error
[p-release]: https://wayland.app/protocols/wayland#wl_buffer:event:release
