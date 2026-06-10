# X11 F11 — scroll fidelity — findings

How X11 represents one physical scroll twice — legacy core button events
4/5/6/7 and [XI 2.1 smooth scrolling][xi2proto] (`XIScrollClass` valuators) —
and what it actually takes to receive, deduplicate, and quantify the two
streams, measured per the [F11 feature contract][f11]. The demo,
[`./examples/f11-scroll/app.d`](./examples/f11-scroll/app.d), extends the
[scaffold](./scaffold.md) with a scrollable ruler (1 detent = 20 px),
per-gesture totals, a full `XIQueryDevice` scroll-class dump, and **two
client connections to one window** so core and XI2 selections can coexist.
Numbers are from Tier-A runs under `xvfb-run` (exit 0): a built-in pass
(device query + `XSendEvent` probes) and an `examples/f11-scroll/run.sh`
pass driving real XTest wheel clicks with `xdotool click 4/5/6/7`.

**Last reviewed:** June 11, 2026

## The dual representation, per spec

[XI2proto][xi2proto] defines the equivalence both directions:

> One unit of scrolling in either direction is considered to be equivalent
> to one button event, e.g. for a unit size of 1.0, -2.0 on an valuator type
> Vertical sends two button press/release events for button 4. Likewise, a
> button press event for button 7 generates an event on the Horizontal
> valuator with a value of +1.0. The server may accumulate deltas of less
> than one unit of scrolling.

The exchange rate is the scroll class's `increment` — "The valuator delta
equivalent to one positive unit of scrolling" — so the one-detent math is
`detents = (value − last_value) / increment`, with scroll valuators arriving
on `XI_Motion` as **absolute, accumulating** values (the demo keeps
`last_value` per axis and differences). Fractions below one increment exist
on the smooth side only; the button side is born quantized. That asymmetry
is the whole fidelity story: buttons 4/5/6/7 are the lossy projection,
`v120`-style fractional detents (Wayland `axis_v120`, Win32 `wheelDelta`)
are recoverable only from the valuator stream.

## What Xvfb's devices actually expose: no `XIScrollClass`

The honest device-query answer on this server — every pointer device has
plain `Rel X`/`Rel Y` valuators and **no scroll class at all**:

```text
409 x11_f11 device id=2 use=MasterPointer name=Virtual core pointer
424 x11_f11 valuator_class device=2 number=0 label=Rel X min=-1 max=-1 mode=0
443 x11_f11 valuator_class device=2 number=1 label=Rel Y min=-1 max=-1 mode=0
445 x11_f11 scroll_class device=2 none=1
450 x11_f11 device id=4 use=SlavePointer name=Virtual core XTEST pointer
456 x11_f11 scroll_class device=4 none=1
462 x11_f11 device id=6 use=SlavePointer name=Xvfb mouse
468 x11_f11 scroll_class device=6 none=1
```

Consequently the smooth half of the dual representation **never fires**
under Xvfb: `xdotool click 4/5` is a genuine button press on the XTEST
pointer, not a scroll-valuator change, and no `XI_Motion` scroll deltas
exist to be logged. The demo still implements the full valuator-delta path
(primed from the scroll-class dump), but exercising it needs a real wheel
behind `xf86-input-libinput` — a per-axis `XIScrollClass` with
`increment=1` (wheel) or `increment=15`-style values (touchpads), per the
[XI 2.1 smooth-scrolling design][who-t-smooth]. That capture is queued as
Tier C; everything below is about the button representation and the
delivery machinery, which Tier A _can_ prove.

## Capturing both streams takes two clients

Core `ButtonPressMask` is exclusive: "Only one client at a time can select a
`ButtonPress` event" ([Xlib manual][xselectinput]). So one process cannot
hold a core button selection twice — the demo opens a second `Display`
connection (`conn=core_client`) for the core stream while the first
(`conn=xi2_client`) selects `XI_ButtonPress`/`XI_Motion`.

The result is the demo's central measurement: **delivery is either/or per
window, not both**. With the XI2 selection present, the core client received
_nothing_ for real wheel clicks; with the XI2 selection cleared (phase
`core_only`), core delivery resumed:

```text
12502   x11_f11 phase name=dual_client
1007167 x11_f11 scroll conn=xi2_client kind=xi2 axis=v button=5 value=+1 emulated=0 flags=0x0 device=4 source=4
1007230 x11_f11 scroll conn=xi2_client kind=xi2 axis=v button=5 value=+1 emulated=0 flags=0x0 device=2 source=4
        (no conn=core_client events at all in this phase)
8018116 x11_f11 phase name=core_only xi2_selection=cleared
8112889 x11_f11 scroll conn=xi2_client kind=core axis=v button=5 value=+1 send_event=0
```

This is [XI2proto][xi2proto]'s event-processing rule working as written:

> then, the event is delivered as an XI event from the MD to any interested
> clients. If the event has been delivered, event processing stops.
> Otherwise, the event is delivered as a core event to any interested
> clients.

Core is the _fallback_ representation, attempted only when no client took
the XI2 event on that window. The "double-event trap" the feature contract
asks about therefore cannot happen between XI2 and core on one window — the
server suppresses the core copy. The phase-B variant (one client selecting
core **and** XI2 on the same window) confirms it from the other side: only
`kind=xi2` events arrived, zero `kind=core`.

## The double-delivery trap that _does_ exist: `XIAllDevices`

The same spec section starts one step earlier: the slave's event is first
"delivered as an XI event [from the slave] to any interested clients",
_then_ again "as an XI event from the MD". A client that selects with
`deviceid=XIAllDevices` is interested in both, so every wheel click arrives
twice — once as `device=4` (the XTEST slave) and once as `device=2` (the
master copy), 46 µs apart:

```text
1007167 x11_f11 scroll ... kind=xi2 axis=v button=5 value=+1 ... device=4 source=4
1007230 x11_f11 scroll ... kind=xi2 axis=v button=5 value=+1 ... device=2 source=4
```

Before the demo deduped (it now counts only master copies), a 3-detent
`xdotool click --repeat 3 5` gesture totaled `v_detents=6` — the ruler
scrolled exactly twice as far as the wheel turned. Select
`XIAllMasterDevices` (or filter `deviceid != sourceid`) unless you really
want per-slave streams. After dedupe, the totals are honest:

```text
1652016 x11_f11 gesture_summary events=3 core=0 xi2=3 emulated=0 v_detents=3 h_detents=0 smooth_v=0 smooth_h=0 dur_ms=240
```

## `XIPointerEmulated`: measured answer for synthetic wheels

[XI2proto][xi2proto] reserves the flag for server-side emulation:

> Any server providing this behaviour marks emulated button or valuator
> events with the XIPointerEmulated flag for DeviceEvents, and the
> XIRawEmulated flag for raw events, to hint at applications which event is
> a hardware event.

Measured: `xdotool click 4/5` events carry **`emulated=0 flags=0x0`** on the
XI2 side. XTest fakes a _genuine_ button press; with no scroll valuator
upstream there is nothing to emulate _from_, so the flag never appears on
this server. The practical consequence for a framework's dedupe logic: the
flag only distinguishes wheel-buttons-derived-from-smooth-scroll on devices
that _have_ an `XIScrollClass`. The robust recipe is capability-driven —
per device and axis, if a scroll class exists, consume valuator deltas and
drop `XIPointerEmulated` button events; otherwise consume the button events
as whole detents. Trusting the flag alone over-counts nothing here, but
trusting "buttons are always emulated" would drop every real detent on
Xvfb-class devices.

## `XSendEvent` fabrications never reach the input pipeline

The built-in pass (no xdotool) probes the third way to make a "scroll":
fabricating a core `ButtonPress` with `XSendEvent`. Delivery is direct to
matching core selectors, flagged, and invisible to XI2 — no precedence rule,
no master copy, no emulation flag:

```text
103129 x11_f11 step name=XSendEvent button=4
103158 x11_f11 scroll conn=core_client kind=core axis=v button=4 value=-1 send_event=1
```

Note the inversion: in phase `dual_client` the core client received the
fabricated event even though the XI2 client's selection starves it of all
_real_ wheel events — `XSendEvent` bypasses the device-event processing
whose first XI2 match would have stopped core delivery. (`send_event=1` is
also why security-conscious apps ignore such events, and why `xdotool`
drives XTest instead.)

## Surprises

- **Core and XI2 are alternatives, not duplicates, per window.** The
  feared core+XI2 double event for one wheel click is impossible on a
  single window: any XI2 delivery stops core delivery — measured both
  across clients (core client starved) and within one client (phase B).
- **The real double-event trap is device-level**: `XIAllDevices` delivers
  slave event + master copy (3 clicks → 6 events → `v_detents=6`).
- **`xdotool` wheel clicks are not "emulated"** — `XIPointerEmulated` marks
  buttons synthesized _from_ smooth scroll, not synthetic input in general.
- **Xvfb has no `XIScrollClass` anywhere**, so CI can never see a fractional
  scroll on this stack; the smooth path stays Tier C (real hardware).
- **`ButtonPressMask` is one-client-exclusive per window** — capturing both
  representations concurrently structurally requires two connections.
- **Wheel events are press/release pairs**: each detent is two core events;
  the demo counts presses only, or every total would double.
- **ImportC gaps, again all macros**: the entire `<X11/extensions/XI2.h>` —
  `XI_ButtonPress`, class types, `XIPointerEmulated` (`1 << 16`), scroll
  flags — is re-declared in the demo, per the [scaffold](./scaffold.md)
  gotcha.

## What a lossless framework scroll event must carry

Combining the measured X11 floor with the contract's cross-platform fields:
axis; **fractional detents** (`delta / increment`, the native resolution —
quantize at the consumer, never the producer); the **raw delta + increment**
pair (X11) or `v120` (Win32/Wayland) so no rounding is baked in; the
**source class** (wheel vs finger vs continuous — on X11 inferable only
from the device's scroll-class `increment`/`flags`, there is no
`axis_source`); an **emulated/duplicate marker** unifying
`XIPointerEmulated` with the device-level dedupe above; and **gesture
boundaries** — X11 has none (no `axis_stop`, no frame grouping), so the
demo's 400 ms idle splitter is already framework-level policy, not
platform data.

## Build and run

| File                               | Lines | Role                                            |
| ---------------------------------- | ----- | ----------------------------------------------- |
| `examples/f11-scroll/app.d`        | 495   | the demo                                        |
| `examples/f11-scroll/instrument.d` | 50    | shared logger (copied from the scaffold)        |
| `examples/f11-scroll/c.c`          | 14    | ImportC shim (Xlib + XInput2 + poll)            |
| `examples/f11-scroll/run.sh`       | 57    | two-pass driver (built-in, then xdotool clicks) |

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f11-scroll
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f11-scroll
```

The full choreography (both passes) is `examples/f11-scroll/run.sh` (run
from the dev shell; it pulls `xdotool` via `nix shell`). `WSI_AUTO_EXIT=1`
scripts the three phases (`dual_client` → `dual_selection` → `core_only`);
`WSI_DRIVEN=1` stretches them to 4 s each for the xdotool clicks. No
reachable display or no `XInputExtension` prints `SKIP:` and exits 0.

## Sources

- **[X Input Extension 2.x protocol spec][xi2proto]** — smooth-scrolling
  unit/`increment` semantics, `XIPointerEmulated`, and the
  slave→master→core event-processing rules (all quotes above).
- **[Peter Hutterer — "What's new in XI 2.1 — smooth scrolling"][who-t-smooth]**
  — the design rationale and what real devices' scroll classes look like.
- **Xlib manual (Tronche mirror)** — [`XSelectInput`][xselectinput] (the
  one-client `ButtonPress` rule), [`XSendEvent`][xsendevent]
  (`send_event` flagging).
- **[`XIQueryDevice` man page][xiquerydevice]** — the class-dump API the
  capability detection rides on.
- **[`xdotool`][xdotool]** — the XTest wheel-click driver.
- **This survey** — the [X11 deep-dive](./index.md), the
  [scaffold findings](./scaffold.md), the [F11 feature contract][f11], and
  the runnable sources
  [`./examples/f11-scroll/app.d`](./examples/f11-scroll/app.d)
  (+ `c.c`, `instrument.d`, `run.sh` alongside it).

<!-- References -->

[f11]: ../features/f11-scroll.md
[xi2proto]: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/specs/XI2proto.txt
[who-t-smooth]: https://who-t.blogspot.com/2011/09/whats-new-in-xi-21-smooth-scrolling.html
[xselectinput]: https://tronche.com/gui/x/xlib/event-handling/XSelectInput.html
[xsendevent]: https://tronche.com/gui/x/xlib/event-handling/XSendEvent.html
[xiquerydevice]: https://www.x.org/releases/current/doc/man/man3/XIQueryDevice.3.xhtml
[xdotool]: https://github.com/jordansissel/xdotool
