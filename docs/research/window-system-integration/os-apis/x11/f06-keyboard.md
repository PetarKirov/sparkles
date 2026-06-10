# X11 F06 — keyboard & keymap

Scancode → keysym → text on X11, with the modern client-side state machine.
The demo, [`./examples/f06-keyboard/app.d`](./examples/f06-keyboard/app.d),
extends the [scaffold](./scaffold.md) to the [F06 spec][f06]'s X11
requirements: it builds an `xkb_keymap`/`xkb_state` from the server via
**xkbcommon-x11** (`XGetXCBConnection` → `xkb_x11_setup_xkb_extension` →
`xkb_x11_keymap_new_from_device` → `xkb_x11_state_new_from_device`), syncs
modifier/group state from `XkbStateNotify`, opts into **detectable
auto-repeat**, rebuilds the keymap live when `setxkbmap` swaps the layout
mid-run, and runs dead-key sequences through `xkb_compose`. Every
press/release logs `key code=… sym=… text=… state=… repeat=…`. Input is
injected by the co-located `run.sh` driver (`xdotool` + `setxkbmap` under
`xvfb-run`); without the driver the demo times out cleanly. Tier A: **11
presses, 2 repeats, 1 composed `é`, 4 live keymap rebuilds, exit 0**.

**Last reviewed:** June 11, 2026

## The verdict line

```text
12059739 f06_x11 summary presses=11 releases=9 repeats=2 composed=1 keymap_rebuilds=4 focused=1
```

## The three levels and who provides them

The [F06 spec][f06]'s three-column split, as observed (cf. the
[concepts entry][skv]):

| Level              | Carrier on X11                                          | Who provides it                                                                                         |
| ------------------ | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Scancode (`code=`) | `XKeyEvent.keycode`, 8–255                              | **Server** — on Linux/evdev servers, kernel scancode + 8; opaque, layout-independent                    |
| Keysym (`sym=`)    | `xkb_state_key_get_one_sym` on the client's `xkb_state` | **Client** — from a keymap _compiled client-side_ out of server data (`xkb_x11_keymap_new_from_device`) |
| Text (`text=`)     | `xkb_state_key_get_utf8` + `xkb_compose`                | **Client** — keysym→UTF-8 plus the compose state machine; the server never produces text                |

The server's only contributions are the keycode stream, the authoritative
modifier/group state, and the keymap _description_; everything from keysym
down is app-side. That makes X11 keyboard handling structurally identical to
Wayland's — same xkbcommon machinery — with one difference: on X11 the keymap
arrives via XKB protocol requests instead of a `wl_keyboard.keymap` fd, and
**repeat is server-side** (below).

## The xkbcommon-x11 wiring

The [xkbcommon-x11 overview][xkbx11] positions the module precisely:

> The xkbcommon-x11 module provides a means for creating an xkb_keymap
> corresponding to the currently active keymap on the X server. To do so, it
> queries the XKB X11 extension using the xcb-xkb library. It can be used as
> a replacement for Xlib's keyboard handling.

The demo follows the header's 8-step workflow on a hybrid connection: the
window and event loop stay Xlib, while [`XGetXCBConnection`][xlibxcb] (from
`X11/Xlib-xcb.h`) exposes the _same socket_ as the `xcb_connection_t*` that
the `xkb_x11_*` functions require:

```text
249 f06_x11 step name=XOpenDisplay fd=3
263 f06_x11 step name=XGetXCBConnection ok=1
313 f06_x11 step name=xkb_x11_setup_xkb_extension version=1.0 base_event=85
325 f06_x11 step name=XkbQueryExtension event_base=85
353 f06_x11 step name=XkbSetDetectableAutoRepeat supported=1
473 f06_x11 step name=xkb_x11_get_core_keyboard_device_id id=3
7243 f06_x11 keymap_event reason=startup layouts=1 layout0=English (US)
```

Note `base_event=85` from the xcb-side setup equals `event_base=85` from
Xlib's `XkbQueryExtension` — one extension on one socket, negotiated twice so
that _both_ libraries cook its events (Xlib needs its own init for
`XkbSelectEvents`/`XkbSetDetectableAutoRepeat` and for converting XKB wire
events into the `XkbEvent` union the loop reads).

### State sync: `XkbStateNotify`, not `xkb_state_update_key`

There are two ways to keep the client's `xkb_state` current, and the
[xkbcommon-x11 header][xkbx11] is explicit about which to use:

> 8. When `StateNotify` is received, update the `xkb_state` accordingly using
>    the `xkb_state_update_mask()` function. … There is no need to call
>    `xkb_state_update_key()`; the state is already synchronized.

The demo does exactly that — a pure observer of the server's state machine:

```text
2024612 f06_x11 key code=50 sym=Shift_L text= state=down repeat=0
2024631 f06_x11 xkb_state base_mods=0x1 locked_mods=0x0 group=0
2030747 f06_x11 key code=11 sym=at text=@ state=down repeat=0
```

`Shift_L` lands, `XkbStateNotify` updates `base_mods` to `0x1`, and the next
keypress on keycode 11 resolves through the shifted level to `at`/`@`. The
alternative — feeding core `KeyPress`/`KeyRelease` into
`xkb_state_update_key` — makes the client _simulate_ the server's state
machine, and drifts the moment any event escapes it: a key grabbed by another
client, a modifier pressed while unfocused, `xmodmap`-style latches, or focus
gained mid-chord all leave the simulation stale (the header's verdict:
"`XkbStateNotify` is more accurate"). The drift risk is the reason the spec
calls the choice out; the observer pattern has none, at the cost of selecting
XKB events.

## Auto-repeat: server-owned, detectable by opt-in

Repeat on X11 is generated **by the server** (delay/rate are server settings —
`xset r rate`, observed at Xvfb's defaults: first repeat after ~660 ms, then
40 ms ≈ 25 Hz). By default the server fakes a full release/press pair per
repeat, indistinguishable from typing. The XKB per-client
[`DetectableAutorepeat`][detectable] control changes the wire pattern so
repeats become press-only:

```text
2051065 f06_x11 key code=39 sym=s text=s state=down repeat=0
2711880 f06_x11 key code=39 sym=s text=s state=down repeat=1
2751984 f06_x11 key code=39 sym=s text=s state=down repeat=1
2768402 f06_x11 key code=39 sym=s text=s state=up repeat=0
```

`XkbSetDetectableAutoRepeat` reported `supported=1`, and a `KeyPress` for a
keycode that is already down (a 256-bit bitset in the demo) is flagged
`repeat=1` — no heuristics, no timers. Contrast with Wayland, where the F06
spec's headline is that **the client owns repeat entirely** (`repeat_info` +
client-side timer + cancellation rules); on X11 the client owns only the
_detection_, and only after opting in. The hold was injected with `xdotool
keydown s` — Xvfb's server-side repeat machinery fires for XTEST-held keys
just like for physical ones.

## Live layout switching: `setxkbmap de` mid-run

The X11 headline. `setxkbmap` replaces the server's keymap, and the server
broadcasts `XkbNewKeyboardNotify`/`XkbMapNotify` to every XKB-aware client;
per the [xkbcommon-x11 workflow][xkbx11], "When `NewKeyboardNotify` or
`MapNotify` are received, recreate the `xkb_keymap` and `xkb_state` as
described above." The demo rebuilds both and logs `keymap_event`:

```text
2784438 f06_x11 xkb_new_keyboard device=3 old_device=3 changed=0x3
2784656 f06_x11 keymap_event reason=XkbNewKeyboardNotify layouts=1 layout0=German
2784672 f06_x11 xkb_new_keyboard device=5 old_device=5 changed=0x3
2784768 f06_x11 keymap_event reason=XkbNewKeyboardNotify layouts=1 layout0=German
2784783 f06_x11 xkb_new_keyboard device=7 old_device=7 changed=0x3
2784883 f06_x11 keymap_event reason=XkbNewKeyboardNotify layouts=1 layout0=German
```

Three notifies for one `setxkbmap` — one per keyboard-ish device (the core
virtual keyboard plus Xvfb's slave devices), `changed=0x3`
(`XkbNKN_KeycodesMask|XkbNKN_GeometryMask`). Rebuild-per-notify is redundant
but harmless (~100 µs each); a production client may coalesce. After the
rebuild the same _physical_ key produces the de mapping with no further app
work:

```text
3798861 f06_x11 key code=29 sym=z text=z state=down repeat=0    # keycode 29 = us "y" position
3819766 f06_x11 key code=16 sym=slash text=/ state=down repeat=0 # de Shift+7 = "/"
```

Keycode 29 — the position that is `y` under `us` — now yields `z` (the de
y/z swap), and `Shift+7` yields `slash` where `us` would give `ampersand`:
both levels above the scancode changed while the scancode stream did not.

Two surprises worth recording:

- **The first injected key also arrived with an `XkbNewKeyboardNotify`**
  (`device=3 old_device=3`, before any `setxkbmap`): the first XTEST client
  touching the virtual core keyboard triggers a new-keyboard notification.
  A client that ignores rebuilds-where-nothing-visibly-changed mis-translates
  every subsequent key, so rebuild unconditionally.
- **`MappingNotify` (the core-protocol legacy path) never fired** — once Xlib
  has XKB initialized, keymap changes arrive only as XKB events; the demo's
  `legacy_mapping_notify` log line stayed silent for the whole run.

## Dead keys: `xkb_compose`, client-side

The de layout's `´` key (keycode 21, `dead_acute`) starts a compose sequence;
[xkbcommon-compose][compose] owns the state machine:

> When the user presses a key which produces the `<dead_acute>` keysym,
> nothing initially happens (thus the key is dubbed a _dead-key_). But when
> the user enters `<a>`, "á" is _composed_, in place of "a".

```text
3840831 f06_x11 compose state=composing
3840857 f06_x11 key code=21 sym=dead_acute text= state=down repeat=0
3854957 f06_x11 compose state=composed text=é
3854978 f06_x11 key code=26 sym=e text=é state=down repeat=0
```

The demo feeds every pressed keysym to `xkb_compose_state_feed`, suppresses
text while `COMPOSING`, and substitutes the composed UTF-8 on `COMPOSED` —
`´` + `e` → `é`, requirement 6's sequence verbatim. **Compose ownership is
fully client-side**: the server delivered two ordinary key events and knows
nothing of the sequence. The table is locale-derived
(`xkb_compose_table_new_from_locale`; the demo falls back from the CI's `C`
locale to `en_US.UTF-8`, where the standard X11 `Compose(5)` set lives).
This is the _raw-key_ compose path only — `XIM`-style input methods (which
layer their own compose/pre-edit on top, cf. [concepts: pre-edit][pec]) are
[F07][f07]'s territory and deliberately untouched here.

## Findings

- **Three-level split:** server provides keycodes + state + keymap
  description; keysym and text are app-side via xkbcommon — the same state
  machine Wayland mandates, fed by XKB protocol instead of a keymap fd. A
  framework can share its entire keyboard translation layer between X11 and
  Wayland below the transport.
- **Repeat contract:** server-generated, server-configured (delay/rate);
  detectability is a per-client XKB opt-in (`XkbSetDetectableAutoRepeat`),
  after which `repeat=1` detection is a trivial down-set membership test.
  Without the opt-in, repeats are wire-identical to retyping.
- **Keymap changes are push, not poll:** `setxkbmap` mid-run produced
  immediate `XkbNewKeyboardNotify` broadcasts (one per device, coalescing
  advised) and the rebuilt keymap re-translated the unchanged scancode stream
  — `keymap_rebuilds=4`, zero missed keys.
- **Compose/dead keys belong to the client** (`xkb_compose`), with the locale
  selecting the sequence table; the server's only role is delivering the
  `dead_acute` keysym's keycode.
- **Same physical key, different identifiers:** keycode 29 is `y` (us) and
  `z` (de) at the sym level while X keycodes themselves are evdev scancode+8
  — the cross-platform scancode divergence [F06][f06] asks about is already
  visible inside one platform's layout switch.

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f06-keyboard
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    docs/research/window-system-integration/os-apis/x11/examples/f06-keyboard/build/f06_keyboard_x11
```

That CI-shaped run injects nothing and must (and does) time out cleanly with
`presses=0`, exit 0. The full scripted run — `xdotool` key injection, the
held-key repeat, the mid-run `setxkbmap us`→`de` switch, and the dead-key
sequence — is the co-located driver `examples/f06-keyboard/run.sh` (run it
from the dev shell; it pulls `xdotool`/`setxkbmap` via `nix shell` and
re-execs itself under `xvfb-run`). Focus handling: the demo
`XSetInputFocus`es itself after `MapNotify`, because bare Xvfb has no WM and
leaves focus at `PointerRoot` — that is enough for XTEST keyboard injection,
so no `icewm` is needed (unlike the [F02](./f02-resize.md) WM-mediated runs).
No reachable display prints `SKIP: no X11 display` and exits 0.

The extra link dependencies are all pkg-config names in the dev shell:
`x11-xcb`, `xcb`, `xkbcommon`, `xkbcommon-x11` (the latter ships inside
`libxkbcommon`, no extra Nix package needed).

## Sources

- **[F06 spec][f06]** — requirements 1, 3, 6 (the per-key log line, the X11
  xkbcommon path + detectable repeat, the two-layout + dead-key run).
- **[xkbcommon-x11 API docs][xkbx11]** — the module overview and the 8-step
  workflow (all verbatim quotes above), including the
  `xkb_state_update_mask`-not-`update_key` rule; `xkbcommon/xkbcommon-x11.h`
  in the source tree carries the same text.
- **[xkbcommon-compose API docs][compose]** — dead-key/compose semantics
  (verbatim quote above), locale table selection, `Compose(5)` format.
- **[XKB protocol — Detectable Autorepeat][detectable]** — the per-client
  control behind `XkbSetDetectableAutoRepeat`.
- **[Xlib-xcb][xlibxcb]** — `XGetXCBConnection`, the hybrid
  one-socket-two-libraries connection.
- **[Concepts][skv]** — scancode vs keysym vs virtual-key; [pre-edit][pec]
  for where F07 picks up.
- **[X11 scaffold findings](./scaffold.md)** — the loop structure and ImportC
  macro-gap discipline (`XkbUseCoreKbd`, the event masks, and friends are
  re-declared constants).
- Demo sources: [`app.d`](./examples/f06-keyboard/app.d),
  [`instrument.d`](./examples/f06-keyboard/instrument.d), the `c.c` ImportC
  shim, and the `run.sh` driver alongside them.

<!-- References -->

[f06]: ../features/f06-keyboard.md
[f07]: ../features/f07-text-input.md
[skv]: ../../concepts.md#scancode-keysym-virtualkey
[pec]: ../../concepts.md#pre-edit-composition
[xkbx11]: https://xkbcommon.org/doc/current/group__x11.html
[compose]: https://xkbcommon.org/doc/current/group__compose.html
[detectable]: https://www.x.org/releases/current/doc/kbproto/xkbproto.html#Detectable_Autorepeat
[xlibxcb]: https://xcb.freedesktop.org/MixingCalls/
