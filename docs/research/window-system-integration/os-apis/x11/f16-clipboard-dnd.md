# X11 F16 — clipboard + file drag-and-drop

On X11 the clipboard and drag-and-drop are **the same mechanism**: [ICCCM
selections][icccm]. The clipboard is a selection named `CLIPBOARD`; a drag is
a selection named `XdndSelection` plus a [ClientMessage choreography][xdnd]
(XDND) for the hover negotiation — the actual data still travels through
`XConvertSelection`. The demo,
[`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d),
extends the [scaffold](./scaffold.md) per the [F16 spec][f16] and implements
all of it by hand: selection ownership with the ICCCM-required targets, INCR
transfers **in both directions**, ownership-loss handling, and the full XDND
v5 protocol — **both sides**, the target on the demo's main connection and
the source on a second in-process `Display` connection, so the complete
negotiation is Tier A with no external tool. The clipboard passes are
verified against `xclip` (requestor, thief, and owner) under `xvfb-run` via
`examples/f16-clipboard-dnd/run.sh`. All five passes: exit 0.

**Last reviewed:** June 11, 2026

## One mechanism, three obligations

Owning a selection is `XSetSelectionOwner` plus a contract. The [ICCCM][icccm]
(§ 2.6.2) fixes the minimum target list:

> Selection owners are required to support the following targets. All other
> targets are optional. TARGETS — The owner should return a list of atoms
> that represent the targets for which an attempt to convert the current
> selection will succeed …

and for `TIMESTAMP`:

> TIMESTAMP — To avoid some race conditions, it is important that requestors
> be able to discover the timestamp the owner used to acquire ownership.

Even _acquiring_ ownership has a rule (§ 2.1) — `CurrentTime` is forbidden:

> Clients attempting to acquire a selection must set the time value of the
> `SetSelectionOwner` request to the timestamp of the event triggering the
> acquisition attempt, not to `CurrentTime`. A zero-length append to a
> property is a way to obtain a timestamp for this purpose; the timestamp is
> in the corresponding `PropertyNotify` event.

The demo does exactly that zero-length-append dance, then serves `TARGETS`,
`TIMESTAMP`, and `UTF8_STRING` (the payload is `é漢🎈` — 2+3+4 UTF-8 bytes),
logging every `SelectionRequest` with requestor, target, and reply property:

```text
469 f16_x11 clip_offer selection=CLIPBOARD targets=[TARGETS,TIMESTAMP,UTF8_STRING] bytes=9 ts=491523782 owned=1
1003495 f16_x11 clip_request requestor=0x400001 selection=CLIPBOARD target=UTF8_STRING property=XCLIP_OUT
1003500 f16_x11 clip_send bytes=9 incr=0 target=UTF8_STRING
1008164 f16_x11 clip_request requestor=0x400001 selection=CLIPBOARD target=TARGETS property=XCLIP_OUT
1010584 f16_x11 ownership_lost selection=CLIPBOARD ts=491524792
```

`xclip -o` printed `é漢🎈` byte-exact, and `xclip -o -t TARGETS` listed
`TARGETS TIMESTAMP UTF8_STRING`. The last line is the F16 "another app
copies" requirement: `printf thief | xclip -i` takes the selection over, the
server delivers **`SelectionClear`**, and the old owner logs `ownership_lost`
and stops serving. Ownership loss is an event, never an error.

A conversion the owner cannot do is refused by replying with
`SelectionNotify` whose property is `None` — and the reply _always_ comes;
a missing `SelectionNotify` would hang the requestor (which is why real
requestors need timeouts).

### The PRIMARY contrast

The "other" clipboard X11 is famous for is one line of code away — the same
owner, handlers, and transfer code with a different selection atom:

```d
XSetSelectionOwner(dpy, XA_PRIMARY, win, owner.ts);
```

`xclip -selection primary -o` then returns the same `é漢🎈`. Per the
[ICCCM][icccm], `PRIMARY` "is the principal means of communication between
clients that use the selection mechanism" (select-then-middle-click paste),
while `CLIPBOARD` "is used to hold data that is being transferred between
clients, that is, data that usually is being cut … or copied" — a pure
convention split; the protocol machinery is identical.

## INCR sending (the demo owns 400 KiB)

Selections can exceed what a property transfer should carry in one shot, so
the ICCCM (§ 2.7.2) defines the **INCR** incremental protocol:

> Requestors may receive a property of type INCR in response to any target
> that results in selection data. … The contents of the INCR property will be
> an integer, which represents a lower bound on the number of bytes of data
> in the selection.

The owner-side choreography is property-**delete**-driven:

> The selection owner then: Appends the data in suitable-size chunks to the
> same property on the same window as the selection reply … Waits between
> each append for a `PropertyNotify` (state==Deleted) event that shows that
> the requestor has read the data. … \[and finally\] writes zero-length data
> to the property.

The demo crosses its 256 KiB threshold with a 400 KiB payload and `xclip -o`
as the requestor — note the start (type-`INCR` property carrying the lower
bound), the seven delete-driven 64 KiB appends, and the zero-length
terminator:

```text
1003209 f16_x11 clip_request requestor=0x400001 selection=CLIPBOARD target=UTF8_STRING property=XCLIP_OUT
1003215 f16_x11 clip_send bytes=409600 incr=1 phase=start lower_bound=409600
1003276 f16_x11 incr_chunk n=1 bytes=65536 offset=65536
1003443 f16_x11 incr_chunk n=2 bytes=65536 offset=131072
...
1003928 f16_x11 incr_chunk n=7 bytes=16384 offset=409600
1003984 f16_x11 clip_send bytes=409600 incr=1 phase=done chunks=7
```

`xclip` received all 409 600 bytes intact. Two structural notes the log makes
visible: each chunk costs a full client→server→client round trip (~100 µs
here, on a local socket with both ends idle — INCR is _slow_ by design), and
the owner watches for `PropertyNotify` on the **requestor's** window, which
works because event selection (`XSelectInput`) is per-client, not per-window
— a third client selecting on your window sees its property traffic.

## INCR receiving (xclip owns 2 MiB)

The requestor side, per the same ICCCM section — the deletes are how the
requestor paces the owner:

> The selection requestor: Waits for the `SelectionNotify` event. Loops:
> Retrieving data using `GetProperty` with the delete argument `True`.
> Waiting for a `PropertyNotify` with the state argument `NewValue`. Waits
> until the property named by the `PropertyNotify` event is zero-length.

With `xclip -i` serving a 2 MiB file, the demo's paste mode logs the offered
targets first (the F16 requirement), then the chunk loop:

```text
597 f16_x11 clip_offer targets=[TARGETS,UTF8_STRING] count=2
639 f16_x11 paste_incr phase=start lower_bound=0
3176 f16_x11 incr_chunk n=1 bytes=1048575 total=1048575
4594 f16_x11 incr_chunk n=2 bytes=1048575 total=2097150
4615 f16_x11 incr_chunk n=3 bytes=2 total=2097152
4642 f16_x11 paste_data fmt=UTF8_STRING bytes=2097152 incr=1 chunks=3
```

All 2 097 152 bytes arrived. Two real-world deviations from the spec are
visible: `xclip` advertises `lower_bound=0` (a legal but useless lower
bound — receivers cannot preallocate from it), and its `TARGETS` reply omits
the ICCCM-_required_ `TIMESTAMP` target. Its chunk size, 1 048 575 bytes, is
`XExtendedMaxRequestSize(dpy)/4` (the [xclip][xclip] `xcin` heuristic), which
also means `xclip` only switches to INCR above ~1 MiB on a BIG-REQUESTS
server — a small copy from it is a single property.

## XDND by hand — both sides in one process

File drop is **not** a separate data path. The [XDND spec][xdnd] is explicit
that the drag's data transfer _is_ a selection conversion:

> By using `XConvertSelection()`, one can use the same data conversion code
> for both the Clipboard and Drag-and-Drop.

The demo proves it literally: its `handleSelectionRequest` function serves
both the `CLIPBOARD` passes and the XDND drop. What XDND adds is (a) a
window property and (b) a six-message `ClientMessage` choreography:

- **`XdndAware`** — the target marks itself droppable by setting this
  property to its highest supported version (5 here); the source reads it
  before sending anything ("the `XdndAware` property provides the highest
  version number supported by the target").
- **`XdndEnter`** — source → target: protocol version plus up to **3** data
  types inline; "targets … only need to fetch `XdndTypeList` from the source
  window if they \[don't\] find what they are looking for in the three types
  listed in the `XdndEnter` message". The demo's source advertises 4 types
  with the more-types bit set, so the target exercises the property fetch.
- **`XdndPosition`** ⇄ **`XdndStatus`** — hover negotiation: pointer position
  - requested action one way; accept flag, no-resend rectangle, and chosen
    action back.
- **`XdndLeave`** — the abort path (exercised once before the real drop).
- **`XdndDrop`** → selection transfer → **`XdndFinished`**.

The complete Tier-A negotiation, source and target interleaved on two
in-process connections (`0x200001` = target window/connection 1, `0x400001`
= source window/connection 2; times in µs):

```text
723 f16_x11 dnd_source target_XdndAware=5
825 f16_x11 dnd_source owns=XdndSelection ts=491520752 types=4 type_list_set=1
834 f16_x11 dnd_source send=XdndEnter,XdndPosition version=5 more_types=1 pos=100,100
866 f16_x11 dnd_enter source=0x400001 version=5 formats=[text/uri-list,UTF8_STRING,text/plain] more_types=1
893 f16_x11 dnd_enter XdndTypeList=[text/uri-list,UTF8_STRING,text/plain,TEXT] count=4
895 f16_x11 dnd_position source=0x400001 pos=100,100 action=XdndActionCopy
900 f16_x11 dnd_status send accept=1 action=XdndActionCopy
919 f16_x11 dnd_source recv=XdndStatus accept=1 action=XdndActionCopy n=1
925 f16_x11 dnd_source send=XdndLeave (abort path)
932 f16_x11 dnd_source send=XdndEnter,XdndPosition version=5 more_types=1 pos=120,80
941 f16_x11 dnd_leave source_aborted=1 cached_formats_dropped=1
943 f16_x11 dnd_enter source=0x400001 version=5 formats=[text/uri-list,UTF8_STRING,text/plain] more_types=1
960 f16_x11 dnd_position source=0x400001 pos=120,80 action=XdndActionCopy
965 f16_x11 dnd_status send accept=1 action=XdndActionCopy
971 f16_x11 dnd_source recv=XdndStatus accept=1 action=XdndActionCopy n=2
978 f16_x11 dnd_source send=XdndDrop
986 f16_x11 dnd_drop source=0x400001 time=491520752
1024 f16_x11 clip_request requestor=0x200001 selection=XdndSelection target=text/uri-list property=XdndSelection
1026 f16_x11 clip_send bytes=33 incr=0 target=text/uri-list
1056 f16_x11 dnd_data fmt=text/uri-list bytes=33 uri="file:///tmp/wsi-f16-dropped.txt"
1061 f16_x11 dnd_finished send success=1 action=XdndActionCopy
1069 f16_x11 dnd_source recv=XdndFinished success=1 action=XdndActionCopy
1100 f16_x11 teardown dnd_complete=1
```

The file lands as `text/uri-list` — a `file://` URI with a CRLF terminator,
not a path; receivers must URI-decode. The entire enter→drop→finish cycle
took ~270 µs of protocol time. The timestamp in `XdndDrop` (`data.l[2]`) is
what the target must pass to `XConvertSelection` — the drop is pinned to a
moment of selection ownership, the same race-avoidance device as the
clipboard's `TIMESTAMP`.

> [!NOTE]
> `XdndStatus`'s accept flag is **advisory hover feedback**, not a contract:
> the spec still requires the target to send `XdndFinished` even when it
> rejects the drop ("If the target receives `XdndDrop` and will not accept
> it, it sends `XdndFinished` and then treats it as `XdndLeave`"). The
> source must also handle never hearing back at all — "If the source doesn't
> receive the expected `XdndStatus` within a reasonable amount of time, it
> should send `XdndLeave`." Timeouts are part of the protocol, not hygiene.

## Surprises

- **Atoms and window ids are server-global, connections are not.** The
  in-process source reuses the target's atom values across its own
  `Display*` and addresses the target's window directly — but the target's
  `XdndAware` property was invisible to the source until the target's
  connection flushed (`XSync`). Cross-client coordination bugs on X11 are
  flush bugs first.
- **`xclip` violates the ICCCM it implements:** no `TIMESTAMP` in `TARGETS`,
  and an INCR lower bound of 0. Interop code must treat the required-targets
  table as aspirational.
- **INCR pacing is property round-trips** — ~100 µs per 64 KiB chunk even
  loopback-local. Large pastes are visibly slower than large copies served
  in one property (xclip needed no INCR below ~1 MiB on a BIG-REQUESTS
  server).
- **Event selection on a foreign window is the INCR enabler**: the owner
  `XSelectInput`s `PropertyChangeMask` on the _requestor's_ window. There is
  no capability check — any client may watch any window's property traffic.
- **Refusal is a positive act** (`SelectionNotify` with `property=None`);
  silence deadlocks the requestor. Every requestor path in the demo
  (clipboard paste, XDND data fetch) would hang forever on a vanished owner
  without a deadline.
- **Delayed rendering is the default, not an option.** Nothing is
  transferred at copy time — the owner serves each request from live state.
  If the owner exits first the selection simply vanishes (no OS-side cache;
  that is what clipboard-manager daemons are for). The Win32 equivalent
  (`SetClipboardData(fmt, NULL)` + `WM_RENDERFORMAT`) is an opt-in to what
  X11 always does.
- **Clipboard and DnD literally share machinery**: one `SelOwner` struct and
  one `handleSelectionRequest` serve `CLIPBOARD`, `PRIMARY`, and
  `XdndSelection` in the demo — evidence for a framework data-transfer API
  where "clipboard" and "drag source" are one interface with two triggers.

## Negotiation sequences (for `event-sequences.md`)

```text
COPY   owner:      zero-len append -> PropertyNotify(ts) -> XSetSelectionOwner(CLIPBOARD, ts)
       requestor:  XConvertSelection -> owner gets SelectionRequest
       owner:      ChangeProperty(reply data) -> SelectionNotify(property)
       loss:       new owner appears -> old owner gets SelectionClear

INCR   owner:      ChangeProperty(type=INCR, lower bound) -> SelectionNotify
       requestor:  GetProperty(delete=True)                      # starts the loop
       owner:      on PropertyNotify(Deleted): append next chunk # repeat
       owner:      append zero-length chunk                      # terminates

XDND   source:     read XdndAware -> own XdndSelection -> XdndEnter -> XdndPosition
       target:     XdndStatus(accept, action)        # repeat Position/Status while hovering
       source:     XdndDrop(timestamp)   (or XdndLeave to abort)
       target:     XConvertSelection(XdndSelection, type, timestamp)  # = COPY sequence
       target:     XdndFinished(success, action)
```

## Build and run

Tier A, from the repo root — the no-argument run is the self-contained
both-sides XDND negotiation (what CI executes):

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f16-clipboard-dnd
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f16-clipboard-dnd
```

The five-pass `xclip` choreography (copy, INCR send, paste, INCR receive,
ownership theft) is `examples/f16-clipboard-dnd/run.sh`, which fetches
`xclip` via `nix shell` and gives each pass its own Xvfb. No reachable
display prints `SKIP: no X11 display` and exits 0.

## Sources

- **[ICCCM — Inter-Client Communication Conventions Manual][icccm]** — § 2
  selections: acquisition timestamps, required targets (`TARGETS`,
  `TIMESTAMP`), `SelectionRequest`/`SelectionNotify`/`SelectionClear`
  semantics, refusal, and the § 2.7.2 INCR protocol (all quotes above);
  § 2.6.1 for the `PRIMARY`/`CLIPBOARD` split.
- **[XDND — Drag-and-Drop Protocol for the X Window System][xdnd]** —
  `XdndAware`, the message sequence, `XdndTypeList`, action atoms, and the
  shared-conversion-code quote.
- **[Xlib — C Language X Interface][xlib]** — `XSetSelectionOwner`,
  `XConvertSelection`, `XGetWindowProperty`, `XChangeProperty`, and the
  output-buffer/flush model behind the `XdndAware` visibility surprise.
- **[`xclip`][xclip]** — the companion requestor/owner; its `xclib.c`
  chunk-size heuristic (`XExtendedMaxRequestSize/4`) explains the observed
  1 048 575-byte INCR chunks.
- **This survey** — the [F16 feature spec][f16]; the [X11 scaffold](./scaffold.md)
  this demo extends; the runnable source
  [`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d)
  (plus the `c.c` ImportC shim, `instrument.d`, and `run.sh` alongside it).

<!-- References -->

[f16]: ../features/f16-clipboard-dnd.md
[icccm]: https://www.x.org/releases/current/doc/xorg-docs/icccm/icccm.html
[xdnd]: https://www.freedesktop.org/wiki/Specifications/XDND/
[xlib]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
[xclip]: https://github.com/astrand/xclip
