# Wayland F16 — Clipboard + drag-and-drop

Clipboard and DnD are literally the same machinery on Wayland — one
`wl_data_source`/`wl_data_offer` negotiation over pipe fds, entered through
`set_selection` for copy-paste and `start_drag` for DnD. The demo,
[`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d),
extends the [scaffold](./scaffold.md) to the [F16 spec][f16] with **one
client owning two toplevels** (window A, the source; window B, the drop
target) so both sides of every negotiation land in a single log. The legs:
a `set_selection(serial=0)` probe before any input event exists; a valid
copy of `é漢🎈` verified by `wl-paste` (a real second client); ownership
loss to `wl-copy`; a paste of `wl-copy`'s offer on keyboard-focus delivery;
and a full injected drag from A into B with the v3 action negotiation.
Verified Tier A under headless sway 1.11 (exit `0`); headless weston 15
(socket `wsi-w8b`) is the seat-less baseline. Gestures come from the
binary's own `inject` mode (`zwlr_virtual_pointer_v1` with
`motion_absolute`); the keyboard from `wtype`.

**Last reviewed:** June 11, 2026

## No clipboard without input: the serial coupling, measured

[wl_data_device.set_selection][p-way] takes a `serial` documented as "the
serial number of the event that triggered this request". X11 and Win32 let
any process write the clipboard at any time; Wayland requires provable,
recent user input. The demo proves both directions:

**Stale (serial=0, no input event has ever been delivered to this client):**

```text
[2357609.573]  -> wl_data_device#3.set_selection(wl_data_source#19, 0)
306682 f16_wayland set_selection serial=0 note=stale-no-input-event-exists
```

```text
--- after stale set_selection(serial=0): what does wl-paste see? ---
Nothing is copied
(wl-paste exit=1)
```

The request is **silently ignored** — no protocol error, and notably the
rejected source receives no `cancelled` either (the demo's `stale` source
logs nothing, ever). The failure is only observable from the outside, by a
second client finding no selection.

**Valid (serial 21 from an injected right-click press):**

```text
3153874 f16_wayland button surface=A serial=21 button=0x111 state=1
3153911 f16_wayland clip_offer kind=selection formats=[text/plain;charset=utf-8,text/plain]
[2360456.938]  -> wl_data_device#3.set_selection(wl_data_source#21, 21)
```

```text
--- wl-paste --list-types (the offer, seen by a second client) ---
text/plain;charset=utf-8
text/plain
--- wl-paste (the payload; demo serves the send fd) ---
4158798 f16_wayland clip_send source=selection fmt=text/plain;charset=utf-8 bytes=9
é漢🎈
```

The `send` event hands the demo a pipe fd; it writes the 9 UTF-8 bytes and
closes — there is no buffer handed to the compositor, the source process
serves every paste live (and therefore must outlive its readers; no
lazy-vs-eager distinction exists, _everything_ is lazy on Wayland).

## Ownership loss is one event

When `wl-copy` takes the selection over, the demo's source gets exactly one
notification and is done:

```text
[2361465.490] wl_data_source#21.cancelled()
4162650 f16_wayland ownership_lost source=selection
```

Immediately after — without the demo asking — the replacement offer arrives
(`data_device.data_offer` + five `offer` MIME events + `selection`), and the
demo pastes it back through its own pipe:

```text
4162732 f16_wayland selection_formats mime_count=5
4162753 f16_wayland offer_mime i=0 mime=text/plain
4162780 f16_wayland offer_mime i=1 mime=text/plain;charset=utf-8
4162800 f16_wayland offer_mime i=2 mime=TEXT
4162821 f16_wayland offer_mime i=3 mime=STRING
4162841 f16_wayland offer_mime i=4 mime=UTF8_STRING
4162929 f16_wayland paste_data bytes=17 text=stolen-by-wl-copy
```

(`TEXT`/`STRING`/`UTF8_STRING` are `wl-copy`'s X11-compat aliases — the
"offered formats" log the [F16 spec][f16] asks for.) Delivery contract,
verbatim from [wl_data_device.selection][p-way]:

> The selection event is sent to a client immediately before receiving
> keyboard focus and when a new selection is set while the client has
> keyboard focus.

Two measured nuances: on sway the offer arrived although the seat had **no
keyboard capability at all** at that moment (`caps=1`) — wlroots tracks a
focused client independently of the capability — and `wl-copy` itself needs
no serial because sway offers `zwlr_data_control_v1`, the privileged
clipboard-manager side door that bypasses the serial coupling entirely.

## DnD: the full negotiation, both sides in one log

`start_drag` is valid only against a live implicit grab — verbatim from
[wl_data_device.start_drag][p-way]:

> The origin surface is the surface where the drag originates and the
> client must have an active implicit grab that matches the serial.

so the injector presses `BTN_LEFT` on A and **holds it** through an 8-step
`motion_absolute` sweep into B before releasing. Source setup and kickoff
(icon surface omitted — `nil` on the wire):

```text
6388974 f16_wayland clip_offer kind=dnd formats=[text/plain;charset=utf-8,text/plain] actions=copy|move
[2363679.549]  -> wl_data_source#23.set_actions(3)
[2363679.583]  -> wl_data_device#3.start_drag(wl_data_source#23, wl_surface#9, nil, 44)
```

The drag immediately enters A itself (the cursor is over the origin), then
leaves, then enters B; each enter introduces a **fresh** `wl_data_offer`
and re-runs the target-side handshake — `accept` with the enter serial,
then `set_actions(copy|move, preferred=move)`:

```text
6389150 f16_wayland dnd_enter surface=A serial=46 pos=320.0,240.0
[2363679.897]  -> wl_data_offer#4278190081.accept(46, "text/plain;charset=utf-8")
[2363679.905]  -> wl_data_offer#4278190081.set_actions(3, 2)
[2363680.040] wl_data_source#23.action(2)
[2363680.072] wl_data_offer#4278190081.action(2)
...
7059500 f16_wayland dnd_leave motions_seen=4
7059525 f16_wayland dnd_enter surface=B serial=49 pos=0.0,240.0
7059541 f16_wayland dnd_accept serial=49 fmt=text/plain;charset=utf-8 actions=copy|move preferred=move
7060534 f16_wayland offer_action dnd_action=2 note=compositor-resolved
```

**Who picked copy vs move:** nobody unilaterally — the source offered
`copy|move` (3), the target offered `copy|move` with `preferred=move`, and
the **compositor** resolved `action(2)` = `move`, telling _both_ sides
symmetrically (`wl_data_source.action` and `wl_data_offer.action`). Between
the two surfaces the source briefly sees `action(0)` — no target — which is
how rejection mid-flight looks.

Drop, transfer, and the three-way finish:

```text
[2365100.166] wl_data_device#3.drop()
[2365100.254]  -> wl_data_offer#4278190082.receive("text/plain;charset=utf-8", fd 6)
[2365100.324] wl_data_source#23.dnd_drop_performed()
7798878 f16_wayland clip_send source=dnd fmt=text/plain;charset=utf-8 bytes=21
7798926 f16_wayland dnd_drop_data bytes=21 text=dnd-payload-é漢🎈
[2365101.119]  -> wl_data_offer#4278190082.finish()
7799124 f16_wayland source_dnd_finished note=target-done-source-may-delete-on-move
```

`drop` → target `receive` (pipe) → source `dnd_drop_performed` → source
serves `send` → target drains to EOF → target `finish` → source
`dnd_finished` ("the target accepted the drop; for a `move` the source may
now delete the data"). The whole [F16 spec][f16] requirement-3 sequence —
enter formats, position feedback, accept/action signaling, drop, transfer,
finish — is this one trace.

## Implementation traps the demo hit

- **A re-delivered selection offer races the drop transfer.** Right after
  `drop`, sway re-sends the _selection_ offer (focus churn), and a naive
  single-pipe receiver clobbers the still-draining DnD pipe — the first demo
  build lost the drop payload and never sent `finish`. Selection and DnD
  transfers need independent pipes; they are independent state machines that
  merely share the event vocabulary.
- **Same-client source+target works but deadlocks if the read blocks**: the
  `send` event can only be served by the same event loop that is waiting for
  the drop data, so the receive pipe must be drained from `poll`, never with
  a blocking read after `receive`.
- **`wl_data_offer.accept` wants the enter serial**, and each enter brings
  a fresh offer object — caching one offer pointer across surfaces is wrong
  even within one client.
- The trailing `wl_display_dispatch: Broken pipe` in a full `run.sh` capture
  is the backgrounded `wl-copy` daemon dying when the compositor is killed —
  not a demo error.

## Seat-less weston: the clipboard is seat-scoped by construction

Headless weston advertises `wl_data_device_manager` v3 but no `wl_seat`
([scaffold finding](./scaffold.md#what-surprised-us)) — and
`get_data_device` takes a seat, so there is nothing to bind a clipboard to:

```text
132 f16_wayland globals data_device_manager=1 version=3 seat=0
ok: data_device_manager=1 but seat=0; clipboard is seat-scoped, nothing to exercise
```

That is itself the architectural finding: on Wayland the clipboard is not
global state, it is **per-seat input state** — coherent with the serial
coupling above.

## Reproducing

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f16-clipboard-dnd

d=docs/research/window-system-integration/os-apis/wayland/examples/f16-clipboard-dnd
nix develop -c $d/run.sh weston   # seat-less registry probe
nix develop -c sh -c "nix shell nixpkgs#sway nixpkgs#wl-clipboard nixpkgs#wtype -c $d/run.sh sway"
```

The sway mode starts `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR`, drives `wl-paste`/`wl-copy` as the real second client,
and injects clicks/drags via the demo's `inject` mode
([`./examples/f16-clipboard-dnd/inject.d`](./examples/f16-clipboard-dnd/inject.d)).
`WSI_DEMO_DEBUG=1` adds the `WAYLAND_DEBUG=1` wire trace quoted above.
Without a compositor every mode prints `SKIP:` and exits `0`.

## Sources

- **[F16 spec][f16]** — the copy/paste/ownership-loss/DnD requirements and
  the shared-machinery finding this page answers for Wayland.
- **[Core Wayland protocol][p-way]** — `wl_data_device_manager`,
  `wl_data_source`, `wl_data_device` (`set_selection`, `start_drag`,
  `selection`, `enter`/`leave`/`motion`/`drop`), `wl_data_offer`
  (`accept`, `receive`, `set_actions`, `finish`, `action`); the
  `set_selection`/`start_drag`/`selection` passages quoted verbatim above.
- **[wlr-data-control][p-dc]** — the privileged clipboard-manager protocol
  that lets `wl-clipboard` bypass the serial coupling on wlroots.
- **[F15 — popup](./f15-popup.md)** — the single-device-session injection
  pattern reused here for the press-hold-sweep drag.
- Demo sources: [`app.d`](./examples/f16-clipboard-dnd/app.d),
  [`inject.d`](./examples/f16-clipboard-dnd/inject.d),
  [`instrument.d`](./examples/f16-clipboard-dnd/instrument.d), the `c.c`
  shim (data-device quartet + `pipe2` + virtual-pointer tables),
  `generate.sh` and the `run.sh` driver alongside it.

<!-- References -->

[f16]: ../features/f16-clipboard-dnd.md
[p-way]: https://wayland.app/protocols/wayland
[p-dc]: https://wayland.app/protocols/wlr-data-control-unstable-v1
