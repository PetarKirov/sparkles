# Wayland F06 — keyboard & keymap

Findings from [`./examples/f06-keyboard/app.d`](./examples/f06-keyboard/app.d), the
[F06 spec][f06]'s Wayland demo. Wayland's keyboard story is radical delegation: the protocol
delivers a bare evdev scancode ([`wl_keyboard.key`][p-key]) plus raw modifier masks, and
**everything above that — keysym, text, dead-key compose, even key repeat — is the client's
job**, via `libxkbcommon` driven by a compositor-serialized keymap fd. The demo binds
`wl_seat`/`wl_keyboard`, compiles every [`keymap`][p-keymap] event into an
`xkb_keymap`/`xkb_state`, feeds presses through an `xkb_compose_state`, and implements
client-side repeat with a `timerfd` (the [F05](./f05-loop-wakeup.md) external-fd pattern) —
proving **both** mandatory cancellations in one run. Headless weston advertises **no
`wl_seat` at all** ([scaffold finding](./scaffold.md#what-surprised-us)), so the Tier-A run
uses `sway` 1.11 (`WLR_BACKENDS=headless`) + `wtype`'s `zwp_virtual_keyboard_v1` injection;
without a seat the demo prints `SKIP` and exits `0`. Exit `0`, 17 key events, 27 synthesized
repeats, both cancellations on the record.

**Last reviewed:** June 11, 2026

| Measurement                    | Value                                                                                                                |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Keymap deliveries              | **8 `keymap_event`s in one 30 s run** (format=1 `xkb_v1`, 23 833 B; one 23 912 B — one per injector device lifetime) |
| Repeat contract                | `repeat_info rate_hz=25 delay_ms=600` (sway default), re-sent with every keyboard; **zero repeated key events**      |
| Repeat measured                | first synthetic repeat exactly 600 ms after press, then 40 ms cadence (25 Hz), 18 repeats over a 1.3 s hold          |
| Cancellation proofs            | `repeat_cancel reason=release` **and** `repeat_cancel reason=focus_leave` (quoted below)                             |
| Compose                        | `dead_acute` → `compose state=composing` → `e` → `compose state=composed text=é` (locale `en_US.UTF-8`, client-side) |
| Live `swaymsg … xkb_layout de` | **no keymap event** — with only virtual keyboards on the seat, `input *` config has no device to apply to (Tier C)   |

## Scancode → keysym → text: who provides each

The three-level split ([concepts § scancode vs keysym][c-keys]) on Wayland, as observed:

| Level        | Carried by                                              | Provided by                                                                                        |
| ------------ | ------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Scancode** | [`wl_keyboard.key`][p-key] `key` arg — a raw evdev code | Compositor (verbatim from the input stack); client adds **+8** to get the XKB keycode (X11 legacy) |
| **Keysym**   | nothing on the wire                                     | **Client**: [`xkb_state_key_get_one_sym`][xkb-mask] against the keymap fd + `modifiers` events     |
| **Text**     | nothing on the wire                                     | **Client**: [`xkb_state_key_get_utf8`][xkb-mask], overridden by the compose machine on dead keys   |

The compositor's contributions are the inputs to the client's state machine, never the
outputs: the serialized keymap ([`wl_keyboard.keymap`][p-keymap] — "this event provides a
file descriptor to the client which can be memory-mapped in read-only mode to provide a
keyboard mapping description", with `MAP_PRIVATE` required since v7), the raw masks+group
([`modifiers`][p-mods], applied via [`xkb_state_update_mask`][xkb-mask] — a client must never
track modifiers itself, since keys pressed while focus is elsewhere would desync it), and
the repeat parameters. A full press resolves like this in the log
(`key code=<evdev+8> sym=… text=… state=… repeat=…`, the [F06 format][f06]):

```text
9685674 f06-wayland key code=9 sym=adiaeresis text=ä state=down repeat=0
9689130 f06-wayland key code=9 sym=adiaeresis text=ä state=up repeat=0
```

## The keymap fd pipeline — and how often it really fires

Each delivery is mmap'ed (`MAP_PRIVATE`), compiled with
[`xkb_keymap_new_from_string`][xkb-newmap] (`XKB_KEYMAP_FORMAT_TEXT_V1`), and **replaces**
the previous `xkb_keymap` + `xkb_state`:

```text
2082234 f06-wayland seat_capabilities caps=0x2 keyboard=1
2082271 f06-wayland keyboard_bound
2082304 f06-wayland keymap_event format=1 size=23833 n=1
2082722 f06-wayland keymap_parsed layouts=1 layout0=(unnamed)
2082743 f06-wayland repeat_info rate_hz=25 delay_ms=600
2082762 f06-wayland keyboard_enter serial=112 pressed=0
2082782 f06-wayland modifiers depressed=0x0 latched=0x0 locked=0x0 group=0
```

The run received **eight** of these. Under virtual-keyboard injection every `wtype`
invocation creates (and on exit destroys) a `zwp_virtual_keyboard_v1` device, and sway
responds with full hotplug semantics each time: `wl_seat.capabilities` gains then loses the
keyboard bit, and each new keyboard brings _its own_ keymap — `wtype` uploads a synthetic
map containing exactly the keysyms it needs, which is why the dead-key invocation's keymap
is a different size (23 912 B vs 23 833 B) and why `layout0` has no name. Two structural
findings fall out:

- **A keymap is per-device state that can change at any moment mid-run** — a client that
  compiles it once at startup is wrong. The demo rebuilds keymap+state on every event and
  kills any armed repeat (`repeat_cancel reason=keymap_replaced` path), since keycode
  semantics just changed under it.
- **Keyboard capability is dynamic.** `caps` toggled `0x0` ⇄ `0x2` eight times; a client
  must handle `wl_seat.capabilities` removing the keyboard while it holds one
  (`wl_keyboard.release`) — even on a "desktop".

Also visible above: `repeat_info` re-arrives with **every** keyboard object (the spec
guarantees it "before any key press event"), and `enter` carries the already-pressed key
array — keys down at focus-gain arrive _inside_ `enter`, not as `key` events (the demo's
injector had to delay 300 ms after device creation so presses arrive as real events).

## Client-side key repeat, proven

The protocol's entire repeat machinery is one event, [`wl_keyboard.repeat_info`][p-repeat]
(v4+):

> Informs the client about the keyboard's repeat rate and delay. … Negative values for
> either rate or delay are illegal. A rate of zero will disable any repeating (regardless
> of the value of delay).
>
> — [`wl_keyboard.repeat_info`][p-repeat], rate in "characters per second", delay in
> "milliseconds since key down until repeating starts"

No repeated key events ever arrive — the client must synthesize them. The demo arms a
`timerfd` (one-shot `delay`, then `1/rate` interval) on each press of a repeating key
([`xkb_keymap_key_repeats`][xkb-repeats] gates non-repeating keys), and the cadence is
exactly the contract: press at 5 327 639 µs, first `repeat=1` at 5 927 699 µs (+600 ms),
then every ~40 ms:

```text
5327639 f06-wayland key code=9 sym=a text=a state=down repeat=0
5327686 f06-wayland repeat_arm code=9 delay_ms=600 rate_hz=25
5927699 f06-wayland key code=9 sym=a text=a state=down repeat=1
5967704 f06-wayland key code=9 sym=a text=a state=down repeat=1
6008556 f06-wayland key code=9 sym=a text=a state=down repeat=1
        … (18 repeats at ~40 ms intervals in all) …
```

**Cancellation 1 — key release** (`wtype -P a -s 1300 -p a`, one held key):

```text
6627746 f06-wayland key code=9 sym=a text=a state=up repeat=0
6627775 f06-wayland repeat_cancel reason=release code=9
```

**Cancellation 2 — focus loss.** While `b` was held (repeats ticking), a second client (the
scaffold) mapped and took sway's focus; [`wl_keyboard.leave`][p-leave] arrived and killed
the timer — per the spec, leave "resets all values to their defaults" in the logical
keyboard state, so a repeat surviving it would type into a window that no longer has focus:

```text
12730474 f06-wayland key code=9 sym=b text=b state=down repeat=1
12770466 f06-wayland key code=9 sym=b text=b state=down repeat=1
12781897 f06-wayland keyboard_leave serial=185
12781927 f06-wayland repeat_cancel reason=focus_leave code=9
```

Exit summary: `repeats_synthesized=27 cancel_on_release=8 cancel_on_focus_loss=1`.

## Dead-key compose: also the client's

xkbcommon's compose module ([`xkb_compose_state`][xkb-compose], table from the locale —
`en_US.UTF-8` here, loaded from the standard `Compose` files) is fed every pressed keysym;
the keymap itself never produces the composed character. The `´` + `e` sequence
(`wtype -k dead_acute -s 200 -k e`):

```text
10665248 f06-wayland compose state=composing
10665282 f06-wayland key code=9 sym=dead_acute text= state=down repeat=0
10869151 f06-wayland compose state=composed text=é
10869195 f06-wayland key code=10 sym=e text=é state=down repeat=0
```

Ownership summary: the dead key produces a sym (`dead_acute`) but **no text** (dead syms
have no Unicode mapping); while `COMPOSING` the client withholds text; on `COMPOSED` the
**compose state machine, not the keymap,** supplies the final UTF-8 (`é`) — note the same
press whose state-derived text would be `e` logs `text=é`. The compositor is uninvolved
beyond delivering the two scancodes. (X11 contrast queued for the X11 demo: there the same
xkbcommon machinery applies, but legacy `XIM`/server compose paths exist; on Wayland there
is exactly one owner.)

## The layout-switch attempt — an honest negative

The plan was `swaymsg 'input * xkb_layout de'` mid-run, expecting a fresh `keymap` event.
The command succeeded (`"success": true`) but **no keymap event arrived**, and the
subsequent injection still resolved through the injector's map. The reason is structural,
not a bug: sway's `input` configuration applies to input _devices_, and this seat's only
keyboards are `wtype`'s virtual ones, which **bring their own keymap** — that is the entire
point of `zwp_virtual_keyboard_v1` (its `keymap` request mirrors the `wl_keyboard` event).
With `WLR_LIBINPUT_NO_DEVICES=1` there is no physical keyboard for the `de` layout to bind
to, so nothing on the seat changed. The keymap-replacement _mechanism_ the test was after
is nonetheless proven eight times over by the per-invocation keymaps (different sizes
included) — what remains unverified headless is specifically a **real device's** keymap
changing in place. That goes to Tier C (manual queue): run under sway on real hardware,
hold a key on a physical keyboard, `swaymsg input * xkb_layout de`, and watch for the
keymap event + repeat cancellation.

## What surprised us

- **`wtype`'s device lifecycle dominates the trace.** One logical action ("type a") is a
  full hotplug cycle: capability add → keymap → enter (with the key possibly already in the
  `enter` array if injected immediately) → key → leave → capability remove. Injection
  tooling shapes the protocol traffic far more than the compositor does.
- **The keymap is the injector's, not the seat's.** Under virtual-keyboard injection the
  client's sym/text resolution runs against the _injector's_ synthetic keymap — `-M shift`
  produced a `modifiers depressed=0x1` event, but the sym stayed `a` because `wtype`'s
  one-level map has nothing at the shift level. Layout-sensitive assertions (us `y` vs de
  `z`) are untestable through this channel.
- **`enter` swallows presses.** A key already down when focus arrives is reported in
  `enter`'s `keys` array, not as a `key` event — toolkits must treat those as "held, not
  newly pressed" (no text, no repeat). The demo logs `keyboard_enter pressed=N`.
- **Everything worked first try under sway** — no labwc fallback needed; the only
  choreography fixes were injector-side (single-invocation holds via `wtype -P … -s … -p`,
  300 ms post-creation delays).

## Verification

Tier A under `sway` 1.11 headless (the scaffold's weston cannot serve F06 — no seat):

```bash
# compositor (no bars; layout set for completeness):
echo 'input * xkb_layout us' > /tmp/wsi-f06-sway.cfg
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    nix shell nixpkgs#sway -c sway -c /tmp/wsi-f06-sway.cfg &
# demo (sway picked wayland-1), then injection:
WAYLAND_DISPLAY=wayland-1 WSI_AUTO_EXIT=1 ./build/f06_keyboard_wayland &
wtype -s 300 a                          # plain key
wtype -s 300 -M shift -k a -m shift     # modifiers event
wtype -s 300 -P a -s 1300 -p a          # hold: repeat + cancel-on-release
swaymsg 'input * xkb_layout de'         # the (negative) live-switch probe
wtype -s 300 -k dead_acute -s 200 -k e  # compose é
wtype -s 300 -P b -s 3000 -p b &        # hold while a second client maps:
WSI_AUTO_EXIT=1 ../scaffold/build/scaffold_wayland   # → cancel-on-focus-loss
```

**Tier C (manual queue):** real-device live layout switch (above); AltGr/hardware-level
nuances; IME interaction ([concepts § pre-edit][c-ime]) — `zwp_text_input_v3` is a separate
protocol the demo deliberately does not touch.

## Sources

- **Protocol** — the [core Wayland protocol][p-wayland]: [`wl_keyboard.keymap`][p-keymap]
  (fd + `MAP_PRIVATE` rule quoted above), [`key`][p-key], [`modifiers`][p-mods],
  [`leave`][p-leave] ("resets all values to their defaults"),
  [`repeat_info`][p-repeat] (quoted), [`wl_seat.capabilities`][p-caps];
  [`zwp_virtual_keyboard_v1`][p-vkbd] (the injection channel and why it owns the keymap).
- **xkbcommon** — [quick guide][xkb-quick] (the keymap/state lifecycle the demo follows);
  API: [`xkb_keymap_new_from_string`][xkb-newmap], [`xkb_state_update_mask`][xkb-mask],
  [`xkb_state_key_get_one_sym`][xkb-mask], [`xkb_state_key_get_utf8`][xkb-mask],
  [`xkb_keymap_key_repeats`][xkb-repeats], [compose][xkb-compose].
- **Tools** — [`wtype`][wtype] (virtual-keyboard injector), [sway][sway]
  (`WLR_BACKENDS=headless` compositor with a real seat).
- **Spec implemented** — [F06 keyboard & keymap][f06]; the scancode/keysym/text and
  compose concepts in [concepts][c-keys]; conventions in
  [the features index](../features/index.md).
- **Code** — [`./examples/f06-keyboard/app.d`](./examples/f06-keyboard/app.d),
  [`./examples/f06-keyboard/c.c`](./examples/f06-keyboard/c.c) (scaffold shim +
  `wl_keyboard` wrappers + `<xkbcommon/xkbcommon.h>`/`xkbcommon-compose.h` — all xkbcommon
  entry points are real exported functions, so ImportC needs no `wsi_*` re-exports for
  them), [`./examples/f06-keyboard/instrument.d`](./examples/f06-keyboard/instrument.d).

<!-- References -->

[f06]: ../features/f06-keyboard.md
[c-keys]: ../../concepts.md#scancode-keysym-virtualkey
[c-ime]: ../../concepts.md#pre-edit-composition
[p-wayland]: https://wayland.app/protocols/wayland
[p-keymap]: https://wayland.app/protocols/wayland#wl_keyboard:event:keymap
[p-key]: https://wayland.app/protocols/wayland#wl_keyboard:event:key
[p-mods]: https://wayland.app/protocols/wayland#wl_keyboard:event:modifiers
[p-leave]: https://wayland.app/protocols/wayland#wl_keyboard:event:leave
[p-repeat]: https://wayland.app/protocols/wayland#wl_keyboard:event:repeat_info
[p-caps]: https://wayland.app/protocols/wayland#wl_seat:event:capabilities
[p-vkbd]: https://wayland.app/protocols/virtual-keyboard-unstable-v1
[xkb-quick]: https://xkbcommon.org/doc/current/md_doc_2quick-guide.html
[xkb-newmap]: https://xkbcommon.org/doc/current/group__keymap.html
[xkb-mask]: https://xkbcommon.org/doc/current/group__state.html
[xkb-repeats]: https://xkbcommon.org/doc/current/group__components.html
[xkb-compose]: https://xkbcommon.org/doc/current/group__compose.html
[wtype]: https://github.com/atx/wtype
[sway]: https://swaywm.org/
