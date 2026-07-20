# Wayland F13 — CSD & decoration modes

Who draws the window frame? The demo,
[`./examples/f13-decorations/app.d`](./examples/f13-decorations/app.d), extends
the [scaffold](./scaffold.md) to the [F13 spec][f13] with one binary and three
behaviours: negotiate [`zxdg_decoration_manager_v1`][p-deco] (request
server-side, log the compositor's answer, honor runtime switches), fall back to
a **minimal hand-rolled CSD** — title bar with block-glyph title + close box, a
fake-shadow margin ring whose outer band is the 8 `xdg_toplevel.resize` edge
zones, `xdg_toplevel.move` from the bar — and demonstrate the
`xdg_surface.set_window_geometry` contract, including what breaks without it
(`WSI_NO_GEOMETRY=1` earns a fatal protocol error). A second variant in
[`./examples/f13-decorations/libdecor-variant/`](./examples/f13-decorations/libdecor-variant/app.d)
links [libdecor][libdecor] — the sanctioned helper-library exception — for the
LOC and behaviour comparison. Verified Tier A under headless weston 15 and
headless sway 1.11 (tiled, floating, and with an injected virtual pointer
driving the CSD hit zones with real serials); all runs exit `0`. The driver
`run.sh` reproduces all five choreographies (`weston`, `weston-violate`,
`sway`, `sway-csd`, `libdecor`).

**Last reviewed:** June 11, 2026

## Who offers decoration negotiation? The per-compositor answer

The registry tells the first half of the story before a single buffer exists;
the `zxdg_toplevel_decoration_v1.configure` answer and the runtime probes tell
the rest:

| Capability                              | weston 15.0 headless         | sway 1.11 headless                                                                                                                             |
| --------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `zxdg_decoration_manager_v1`            | **not offered**              | yes (v1)                                                                                                                                       |
| Answer to `set_mode(server_side)`       | — (`mode=csd source=absent`) | `server_side`, tiled **and** floating                                                                                                          |
| Answer to `set_mode(client_side)`       | —                            | first (pre-map) configure still says `server_side`; `client_side` arrives with the post-map configure                                          |
| Runtime `set_mode(client_side)` mid-run | —                            | floating: honored (`mode=csd` + the configured size grows to absorb the frame); tiled: **silently ignored** (no `decoration.configure` at all) |
| Runtime `unset_mode`                    | —                            | back to `server_side` at the next configure                                                                                                    |
| `swaymsg border none/normal` poke       | —                            | geometry-only re-configures (1276×693 ↔ 1280×720); the decoration _mode_ never changes                                                         |
| Resulting demo path                     | hand-rolled CSD              | SSD, unless forced/floating-switched to CSD                                                                                                    |

So the two ways a client ends up owning the frame are both real: weston omits
the protocol entirely (`wl_display_connect` → no global → you draw), and sway
offers it but [the XML][p-deco] reserves the last word for the server — "The
compositor can decide not to use the client's mode and enforce a different
mode instead." The same section also prescribes the re-negotiation dance the
demo's storm exercises, including the anti-loop rule:

```text
After requesting a decoration mode, the compositor will respond by
emitting an xdg_surface.configure event. The client should then update
its content, drawing it without decorations if the received mode is
server-side decorations. The client must also acknowledge the configure
when committing the new content (see xdg_surface.ack_configure).
…
Such clients are responsible for preventing configure loops and must
make sure not to send multiple successive set_mode requests with the
same decoration mode.
```

Ordering matters too: the decoration object is created **before** the first
commit, because "creating an `xdg_toplevel_decoration` from an `xdg_toplevel`
which has a buffer attached or committed is a client error"
(`unconfigured_buffer`, error 0). And sway's tiled indifference is spec-legal:
mode switches only ever arrive bundled with a configure, and a tiling
compositor that draws no deco for tiled windows anyway has nothing to say.

## The minimal CSD: move, resize, close — with real serials

In CSD mode the buffer is `geometry + 2×12 px` of semi-transparent
"fake shadow"; the outer `margin + 4 px` band maps straight onto the
`xdg_toplevel.resize_edge` enum (values 1–10), the bar starts a move, its
rightmost square is the close box. `./run.sh sway-csd` floats the window at a
known position and drives each zone with a _held_ virtual pointer (the demo's
own `inject` mode — a transient `wlrctl` click unplugs before the freshly
created `wl_pointer` can receive the button). The instrument log:

```text
2604673 f13-deco csd_hit zone=title pos=193,27
2704821 f13-deco pointer_button serial=11 button=0x110 state=1
2704852 f13-deco move_start serial=11
…
4211247 f13-deco csd_hit zone=bottom_right pos=648,488
4311350 f13-deco pointer_button serial=21 button=0x110 state=1
4311380 f13-deco resize_start edge=10 name=bottom_right serial=21
…
5919942 f13-deco pointer_button serial=33 button=0x110 state=1   ← content: control, no request
…
7425624 f13-deco csd_hit zone=close pos=631,27
7525281 f13-deco csd_close note=client shutdown, no protocol request
```

and the `WAYLAND_DEBUG=1` wire trace carries the two requests verbatim, each
with the live button-press serial:

```text
[3783686.075] {Default Queue}  -> xdg_toplevel#10.move(wl_seat#8, 11)
[3785293.206] {Default Queue}  -> xdg_toplevel#10.resize(wl_seat#8, 21, 10)
[3785293.321] {Default Queue} wl_pointer#16.leave(23, wl_surface#3)
[3785293.342] {Default Queue} xdg_toplevel#10.configure(640, 480, array[8])
```

That trace _is_ the measured answer to "does a headless drag complete": the
grab **starts** — sway immediately steals the pointer (`wl_pointer.leave`) and
the next configure's states array grows to `array[8]` (`activated` +
`resizing`) — but the compositor owns the gesture from that moment; the client
never sees the button release, and a 1-px hold produces no size change. Move
and resize are requests to _begin_ compositor-driven interactions, not
client-computed geometry. The close box is the asymmetric third: it sends
**nothing** on the wire — CSD close is a pure client-side decision
([F14](./f14-window-state.md) owns the close choreography proper).

## The `set_window_geometry` contract — and what breaks without it

Every CSD commit logs buffer size vs declared geometry; the margin is dropped
when maximized (real CSD does the same — shadows off when tiled/maximized):

```text
1938   commit buffer=664x504  geometry=640x480@12,12  geometry_set=1 csd=1
498401 commit buffer=1024x608 geometry=1024x608@0,0   geometry_set=1 csd=1
```

`WSI_NO_GEOMETRY=1` keeps the 12-px ring but never calls
`set_window_geometry`, so the window geometry defaults to the full buffer.
The auto storm's `set_maximized` then commits a 1048×632 buffer against a
1024×608 configure, and weston answers with a **fatal** error — the connection
is killed (`errno=71 EPROTO`), recovered by the demo via
`wl_display_get_protocol_error`:

```text
xdg_wm_base#6: error 4: xdg_surface geometry (1048 x 632) does not match the configured maximized state (1024 x 608)
500362 f13-deco protocol_error errno=71 interface=xdg_wm_base code=4 object_id=6
outcome: protocol error — interface=xdg_wm_base code=4 (connection killed)
```

So the contract is not cosmetic: with shadows in the buffer, a client that
forgets `set_window_geometry` doesn't get a slightly-too-big window, it gets
**disconnected** the first time it is maximized. (Error 4 is
`xdg_wm_base.invalid_surface_state`.)

## The libdecor variant: what the helper buys

The variant replaces the entire shell layer with `libdecor_new` +
`libdecor_decorate`: `xdg_surface`/`xdg_toplevel` creation, the configure/ack
dance, xdg-decoration negotiation, `set_window_geometry`, frame drawing,
move/resize hit zones, themes, shadows and double-click-to-maximize all live
behind one configure callback that hands the client its _content_ size.
Behaviour diverges per compositor exactly as designed:

- **weston** (no SSD protocol): libdecor's cairo plugin draws the frame as
  subsurfaces. Maximized, the content callback reports **1024×584** for the
  1024×608 maximized geometry — the 24-px title bar is libdecor's, subtracted
  before the app ever sees a number.
- **sway**: libdecor binds xdg-decoration itself, accepts `server_side`, and
  draws nothing — `window_state=0x79` (`active` + `tiled` on all four edges)
  with content = the full 1276×693 tile.

Two operational findings from getting it to run headless: libdecor prefers
its **GTK plugin**, whose `gtk_init` stalls ~50 s on session-D-Bus timeouts in
a headless environment and then never delivers a configure; forcing the cairo
plugin via `LIBDECOR_PLUGIN_DIR` still left a ~25 s stall in the cairo
plugin's own D-Bus cursor-settings query. `run.sh` pins the cairo plugin
**and** points `DBUS_SESSION_BUS_ADDRESS` at a dead socket so the connect
fails instantly; with no plugin at all libdecor falls back to "no
decorations" and the protocol machinery still works (3 configures, maximize
storm intact).

### LOC ledger

| Variant                            | Decoration-relevant source                        | LOC      |
| ---------------------------------- | ------------------------------------------------- | -------- |
| Minimal hand-rolled CSD            | `app.d` 729 + `c.c` 332 (+ `inject.d` 79 harness) | **1061** |
| libdecor                           | `app.d` 214 + `c.c` 81                            | **295**  |
| "Free" SSD (sway accepts, F14 app) | decoration-specific code                          | **0**    |

And the minimal CSD is still a toy: no themes, no a11y names, no snap-layout
hints, no touch/tablet move, no double-click-to-maximize, no input region
extending past the visible frame for easier resize grabs — each of those is
inside libdecor's 295-line price.

## Findings

- **Per-compositor decoration answers** (the F13 question): weston 15 —
  protocol absent, CSD mandatory; sway 1.11 — offered (v1), grants
  `server_side`, honors runtime `set_mode(client_side)` only for floating
  windows and ignores it (no configure echo) for tiled ones. mutter/kwin stay
  on the manual Tier-C queue (mutter famously refuses SSD).
- **A client must implement CSD anyway**: either the global is missing
  (weston) or the answer can be `client_side` — SSD is an optimization, never
  a guarantee. The inverse also holds on sway: a request for `client_side` is
  answered `server_side` until the window maps.
- **`move`/`resize` are grab-starters**, serial-gated on a real input event;
  the compositor takes the pointer (`leave` + `resizing` state) and the client
  never computes drag geometry. CSD close sends nothing on the wire.
- **`set_window_geometry` is enforced**, not advisory: buffer ≠ configured
  size while maximized is a connection-killing `invalid_surface_state` on
  weston.
- **libdecor**: 295 vs 1061 LOC, plus themes/shadows/gestures for free, and
  it auto-degrades to SSD where offered (sway) — but its plugin loader has
  sharp headless edges (GTK-plugin D-Bus stalls; pin
  `LIBDECOR_PLUGIN_DIR`/sever the session bus in CI).
- **Customization hooks elsewhere** (the N/A cells of the matrix): Win32 —
  `WM_NCCALCSIZE` + `DwmExtendFrameIntoClientArea`; macOS —
  `NSWindowStyleMask.fullSizeContentView` + `titlebarAppearsTransparent`;
  X11 — Motif `_MOTIF_WM_HINTS` + `_GTK_FRAME_EXTENTS`. All three are
  _opt-out_ tweaks on top of system decorations; only Wayland makes the frame
  the app's problem by default.

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f13-decorations

d=docs/research/window-system-integration/os-apis/wayland/examples/f13-decorations
nix develop -c $d/run.sh weston            # negotiation + geometry contract (no SSD protocol)
nix develop -c $d/run.sh weston-violate    # the missing-set_window_geometry protocol error
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway"      # SSD answer, tiled + floating + mode storm
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh sway-csd"  # CSD zones via injected pointer
nix develop -c sh -c "nix shell nixpkgs#sway -c $d/run.sh libdecor"  # libdecor on weston, then sway
```

The sway modes start `WLR_BACKENDS=headless sway` in a private
`XDG_RUNTIME_DIR`; the weston modes use socket `wsi-w7a`. `sway-csd` floats
the window at (320,120) and clicks title bar / bottom-right band / content /
close box via the demo's own virtual-pointer `inject` mode
(`WSI_DEMO_DEBUG=1` adds the `WAYLAND_DEBUG` wire trace). The libdecor mode
fetches `nixpkgs#libdecor` ad hoc and builds the variant against its
`pkg-config` — the only demo in the catalog that links a helper library.
Without a compositor every mode prints `SKIP:` and exits `0`.

## Sources

- **[F13 spec][f13]** — requirements 1–4 (negotiation, minimal CSD,
  geometry contract, libdecor comparison) and the Tier-A/Tier-C split for
  protocol evidence vs interactive drags.
- **[xdg-decoration-unstable-v1][p-deco]** — the `mode` enum, the
  `set_mode`/`unset_mode`/`configure` dance, the `unconfigured_buffer` error
  and the "compositor can decide not to use the client's mode" sentence, all
  quoted verbatim above (XML at
  `wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml`,
  v1.47).
- **[xdg-shell][p-xdg]** — `xdg_toplevel.move`/`resize` (grab semantics,
  `resize_edge` enum), `xdg_surface.set_window_geometry`, and the
  `xdg_wm_base.invalid_surface_state` error the violation run triggers.
- **[libdecor][libdecor]** — `libdecor_new`, `libdecor_decorate`,
  `libdecor_configuration_get_content_size`, `libdecor_frame_commit`; plugin
  selection via `LIBDECOR_PLUGIN_DIR` (cairo vs GTK) observed from the 0.2.x
  sources packaged in nixpkgs.
- Demo sources: [`app.d`](./examples/f13-decorations/app.d),
  [`inject.d`](./examples/f13-decorations/inject.d),
  [`instrument.d`](./examples/f13-decorations/instrument.d), the `c.c` shim,
  `generate.sh` (xdg-shell + xdg-decoration glue), the `run.sh` driver, and
  the [libdecor variant](./examples/f13-decorations/libdecor-variant/app.d).
  The virtual-pointer injection pattern is [F10](./f10-pointer-capture.md)'s;
  the state-array decoding this demo only skims is completed in
  [F14](./f14-window-state.md).

<!-- References -->

[f13]: ../features/f13-decorations.md
[p-deco]: https://wayland.app/protocols/xdg-decoration-unstable-v1
[p-xdg]: https://wayland.app/protocols/xdg-shell
[libdecor]: https://gitlab.freedesktop.org/libdecor/libdecor
