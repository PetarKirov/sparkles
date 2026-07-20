# Wayland F11 — Scroll fidelity

A wheel detent, a trackpad swipe and a high-resolution wheel are one event
vocabulary on Wayland: the `wl_pointer` axis family. The demo,
[`./examples/f11-scroll/app.d`](./examples/f11-scroll/app.d), extends the
[scaffold](./scaffold.md) to the [F11 spec][f11], binds `wl_seat` at
**v9** (sway 1.11 advertises 9; the demo logs `advertised=9 bound=9`) and
logs every member of the family with its full payload — [`axis`][p-wayland]
(continuous length, `wl_fixed`), `axis_value120` (high-resolution 120ths,
v8+, replacing the deprecated `axis_discrete`), `axis_source`
(wheel/finger/continuous/wheel_tilt), `axis_stop`, and
`axis_relative_direction` (v9+, the natural-scrolling signal) — grouped by
`wl_pointer.frame`, accumulated into wheel detents on a rendered ruler, and
summarized per gesture. Verified Tier A under headless sway 1.11
(`./run.sh sway`, exit `0`); headless weston 15 is the SKIP path (**no
seat** → registry probe only). Scrolls are injected two ways, and the
difference between them is the central finding: `wlrctl pointer scroll`
(finger-like, no 120ths) and the demo's own `axis_discrete` injector
(wheel-like, real `axis_value120`).

**Last reviewed:** June 11, 2026

## The frame is the atomicity contract

Per the [core protocol][p-wayland], `wl_pointer.frame` "indicates the end of
a set of events that logically belong together. A client is expected to
accumulate the data in all events within the frame before proceeding" — e.g.
"in a diagonal scroll motion the compositor will send an optional
wl_pointer.axis_source event, two wl_pointer.axis events (horizontal and
vertical) and finally a wl_pointer.frame event." The demo logs each raw
event as it arrives and closes every group with a `frame seq=…` line.
`wlrctl pointer scroll 2 1` delivered exactly the spec's diagonal shape —
both axes in ONE frame:

```text
6524061 f11_wayland frame seq=9 source=finger v=[value=2.000 v120=0(absent) stop=0 dir=identical] h=[value=1.000 v120=0(absent) stop=0 dir=identical]
```

A framework scroll event must therefore be assembled at the frame boundary,
not per `axis` event — interpreting the vertical `axis` alone would turn one
diagonal gesture into two sequential ones.

## Anatomy of a `wlrctl pointer scroll` (the injection-fidelity finding)

What does a [`zwlr_virtual_pointer_v1`][p-vptr] client actually produce?
The `WAYLAND_DEBUG=1` wire trace of `wlrctl pointer scroll 1 0`, interleaved
with the instrument log:

```text
[1290777.763] {Default Queue} wl_pointer#14.axis_source(1)
3005711 f11_wayland axis_source source=finger raw=1
[1290777.788] {Default Queue} wl_pointer#14.axis_relative_direction(0, 0)
3005735 f11_wayland axis_relative_direction axis=vertical direction=identical
[1290777.811] {Default Queue} wl_pointer#14.axis(489594694, 0, 1.00000000)
3005759 f11_wayland axis axis=vertical value=1.000 time=489594694
[1290777.844] {Default Queue} wl_pointer#14.frame()
[1290777.888] {Default Queue} wl_pointer#14.axis_source(1)
[1290777.911] {Default Queue} wl_pointer#14.axis_stop(489594694, 0)
[1290777.938] {Default Queue} wl_pointer#14.frame()
3005903 f11_wayland gesture_summary num=1 frames=2 value_v=1.000 value_h=0.000 v120_v=0 v120_h=0 detents_total=0 source=finger reason=axis_stop
```

Measured anatomy, across the whole choreography (`1`, `5`, `-3`, horizontal
`2`, fractional `0.5`, diagonal `2 1`):

- **`axis_source=finger`** — wlrctl's scroll presents as a touchpad, not a
  wheel (quirk: a horizontal-only scroll arrived with `source=wheel` in its
  value frame, but its stop frame still said `finger`; the demo's
  per-gesture source is taken from the value frame).
- **No `axis_value120`, ever** — `value_v=5.000` arrived as one continuous
  `axis` event, not five 120ths; `detents_total=0` for every wlrctl gesture.
  A client that only counts detents sees _nothing_ from wlrctl injection.
- **`axis_stop` in a separate, immediate frame** with the same timestamp —
  every wlrctl burst is a complete begin+end gesture.
- **Sign convention**: positive = scroll down/right (`-3` produced
  `value=-3.000`); `axis_relative_direction=identical` throughout (no
  natural-scrolling inversion configured).
- **Fractional amounts are silently truncated**: `wlrctl pointer scroll 0.5 0`
  exits `0` and produces **no events at all** (integer parsing → a scroll
  of 0, which sway suppresses).

## The wheel path: `axis_discrete` injection → real `axis_value120`

wlrctl never sends discrete steps, so the v120/detent machinery needs the
demo's own injector ([`inject.d`](./examples/f11-scroll/inject.d), mode
`wheel`): per click it sends `axis_source(wheel)` +
`zwlr_virtual_pointer_v1.axis_discrete(axis=vertical, value=detents×15,
discrete=detents)` — 15 axis units per detent, the libinput wheel
convention. wlroots converts the discrete count for a v8+ bind:

```text
[1295001.623] {Default Queue} wl_pointer#14.axis_source(0)
[1295001.707] {Default Queue} wl_pointer#14.axis_value120(0, 120)
[1295001.736] {Default Queue} wl_pointer#14.axis(0, 0, 15.00000000)
[1295001.763] {Default Queue} wl_pointer#14.frame()
7229711 f11_wayland frame seq=11 source=wheel v=[value=15.000 v120=120 stop=0 dir=identical] h=[…]
7229760 f11_wayland detent step=1 detents=1 carry=0
```

The v120↔value relationship observed: **120 ↔ 15 axis units per logical
detent** (and a `-2`-detent click arrived as `v120=-240`, `value=-30.000` in
one frame — the spec's own example: "a value120 of -240 are two logical
scroll steps in the negative direction within the same hardware event").
The demo accumulates v120 with a carry rather than truncating per event —
the spec mandates it: "clients that rely on discrete scrolling should
accumulate the value120 to multiples of 120 before processing the event."
The carry path is visible when -240 lands at once:

```text
8684960 f11_wayland detent step=-1 detents=2 carry=-120
8684982 f11_wayland detent step=-1 detents=1 carry=0
```

Note also what the wheel path does **not** send: no `axis_stop`. Wheel
sequences have no defined end; only finger (and on some compositors
continuous) sources terminate with a stop. The demo's wheel gestures
therefore close on an idle gap (`reason=idle_gap`), its finger gestures on
the stop frame (`reason=axis_stop`).

## Momentum is the app's job

There is no momentum/fling phase in the protocol — nothing like macOS's
`momentumPhase`. The whole kinetic contract is one event:
[`axis_stop`][p-wayland] — "for some wl_pointer.axis_source types, a
wl_pointer.axis_stop event is sent to notify a client that the axis sequence
has terminated. **This enables the client to implement kinetic scrolling.**"
The compositor reports that the fingers lifted; any post-fling animation,
deceleration curve and over-scroll bounce is app-synthesized from the
velocity the client itself measured before the stop. The demo's
per-gesture summary (`frames`, `value_v`, `v120_v`, `source`, end reason) is
exactly the input such a synthesizer needs.

## The delivery race: why a capability hold is needed

Scroll events are transient, and that makes them harsher than F12's cursors
or F10's motion about the [headless seat dance](./f12-cursors.md):

- A bare `wlrctl pointer scroll` plugs its device, scrolls, and unplugs
  within ~1 ms. The demo — conformant: it waits for `capabilities`, then
  issues `get_pointer` — is still one round-trip away when the axis events
  are routed: they land on **zero** pointer resources and are gone.
  Measured: a run without the hold logged `axis_events=0` for all six
  scrolls while still receiving every `enter`/`leave` (motion persists as
  cursor state; axis does not).
- Keeping the `wl_pointer` alive across the capability drop instead
  (`WSI_KEEP_POINTER=1`) is worse: the kept proxy went **permanently
  silent** — not even `enter` on the next plug — empirically re-confirming
  the F12 rule that capability loss orphans the old objects.
- The working arrangement (`run.sh`): the demo's injector holds one virtual
  pointer open for the whole choreography (`inject 13000 0 0 0 0` — plug
  and sleep), keeping the seat's pointer capability up so the demo's
  `wl_pointer` survives; the transient wlrctl bursts then land on a live
  resource.

The general lesson for input injection on wlroots-headless: **events sent
in the same breath as a device plug are lost to any conformant client**;
either the device must outlive the client's `get_pointer` round-trip or the
events must come from a second, already-established device.

## Findings

- **Smallest representable step**: `axis` is `wl_fixed` (1/256 surface
  unit) for continuous sources; `axis_value120` resolves 1/120 of a wheel
  detent for discrete ones. The two arrive together in one frame and a
  lossless framework event carries both (plus source, per-axis stop flag,
  and the v9 relative direction), assembled at the frame boundary.
- **Device-class discrimination** is `axis_source` (+ presence of
  `axis_value120`): wheel = v120+value, finger = value+stop, continuous =
  value only. The demo's gesture summaries key off exactly that.
- **`axis_discrete` is dead** at v8+: binding seat v9, the demo never
  received one (the handler logs `DEPRECATED-pre-v8` if it ever fires);
  wlroots converts producer-side discrete to `axis_value120 = discrete×120`.
- **v120 must be accumulated with a carry** (spec quote above) — truncating
  per event drops sub-detent precision from high-resolution wheels and
  loses whole detents on multi-step frames (the `-240` case).
- **Momentum**: not in the protocol; `axis_stop` is the kinetic-scrolling
  trigger and everything after it is app-synthesized.
- **Injection fidelity**: wlrctl = finger-source continuous scroll, no
  120ths, integer-only amounts, auto begin+end per invocation; real
  discrete anatomy needs an `axis_discrete`-speaking injector. Neither
  produces fractional/high-res v120 (`v120 % 120 != 0`), trackpad
  pixel-precise deltas, or accelerated-vs-raw divergence — real wheel and
  trackpad hardware (and a fling on each) stays on the Tier-C manual queue.
- **The ruler check**: the rendered ruler scrolls by the continuous `value`
  sum while the detent gauge counts v120/120 — after the full choreography
  they agree (`scroll_px=20.00` = 1+5−3+2 from wlrctl + 45−30 from the
  wheel clicks; `detents=1` = 3−2), i.e. no over/under-scroll drift between
  the two representations.

## Build and run

```bash
d=docs/research/window-system-integration/os-apis/wayland/examples/f11-scroll
nix develop -c dub build --compiler=ldc2 --root=$d
nix develop -c $d/run.sh weston                                                # registry probe (no seat)
nix develop -c sh -c "nix shell nixpkgs#sway nixpkgs#wlrctl -c $d/run.sh sway" # full choreography
```

The sway mode starts `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR` (the weston socket is `wsi-w6b`), holds the capability via
the demo's injector, fires the six `wlrctl pointer scroll` gestures and the
two `axis_discrete` wheel injections while the demo runs (`WSI_AUTO_EXIT=1
WSI_RUN_MS=17000`). Without a compositor the demo prints `SKIP:` and exits
`0`; `WSI_DEMO_DEBUG=1 ./run.sh sway` re-runs with `WAYLAND_DEBUG=1` on the
demo for the wire traces quoted above.

## Sources

- **[F11 spec][f11]** — requirements 1–2 (full native payload per event,
  ruler + per-gesture totals) and the findings list this doc answers
  (smallest step, device-class discrimination, momentum delivery, the
  lossless framework event).
- **[Core protocol][p-wayland]** — `wl_pointer.axis`, `axis_value120`
  (including the accumulate-to-120 mandate and the −240 example),
  `axis_source`, `axis_stop` (the kinetic-scrolling quote),
  `axis_relative_direction` and `frame` (the diagonal-scroll quote); all
  quoted verbatim from the protocol XML (`wayland/share/wayland/wayland.xml`,
  wayland 1.23/1.24; seat v8 added value120, v9 added relative direction).
- **[`wlr-virtual-pointer-unstable-v1`][p-vptr]** — the injector's `axis`,
  `axis_discrete` and `axis_source` requests (hand-written interface tables
  in [`c.c`](./examples/f11-scroll/c.c); wlroots converts `discrete` to
  `axis_value120` for v8+ binds).
- Demo sources: [`app.d`](./examples/f11-scroll/app.d),
  [`inject.d`](./examples/f11-scroll/inject.d),
  [`instrument.d`](./examples/f11-scroll/instrument.d), the `c.c` shim,
  `generate.sh` (xdg-shell only — the axis family is core protocol) and the
  `run.sh` driver alongside it; the seat-capability lessons inherited from
  [F12](./f12-cursors.md) and [F10](./f10-pointer-capture.md).

<!-- References -->

[f11]: ../features/f11-scroll.md
[p-vptr]: https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1
[p-wayland]: https://wayland.app/protocols/wayland
