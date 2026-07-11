# Wayland F07 — IME / text input

The hardest row in the matrix, and Wayland is the only platform where the
whole stack — compositor, input method, client — can be assembled headless.
The demo, [`./examples/f07-text-input/app.d`](./examples/f07-text-input/app.d),
extends the [scaffold](./scaffold.md) to the [F07 spec][f07]: an editable line
with a visible caret (block-glyph cells, no font lib; pre-edit rendered inline
over an underline band, real strings logged), driven by
[`zwp_text_input_v3`][p-ti3] with the full double-buffered state/serial
discipline, plus an exhaustively logged [`wl_keyboard`][p-wayland] +
`xkbcommon` path so raw-key/IME interleaving is observable. Verified Tier A
under headless sway 1.11 with fcitx5 5.1.16 + pinyin as the
[`zwp_input_method_v2`][p-im2] client and `wtype` as the key injector — **a
complete CJK round-trip (`nihao␣` → `你好`) with no display attached**.

**Last reviewed:** June 11, 2026

## The v3 contract: double-buffered state, counted commits

[`text-input-unstable-v3`][p-ti3] is symmetric double buffering. Client →
compositor state (`enable`, `set_surrounding_text`, `set_content_type`,
`set_cursor_rectangle`, `set_text_change_cause`) is pending until a `commit`
request: "A commit request atomically applies all pending state, replacing
the current state." Compositor → client state (`preedit_string`,
`commit_string`, `delete_surrounding_text`) is pending until a `done` event,
and must then be applied in the exact order the XML mandates:

> "1. Replace existing preedit string with the cursor. 2. Delete requested
> surrounding text. 3. Insert commit string with the cursor at its end. 4. Calculate surrounding text to send. 5. Insert new preedit text in cursor
> position. 6. Place cursor inside preedit text."

The serial is not a number the compositor invents — it is the client's own
commit count echoed back: "The compositor must count the number of commit
requests coming from each `zwp_text_input_v3` object and use the count as the
serial in done events." A `done` whose serial doesn't match means the IM acted
on stale state; the client must still apply the edits but "should not change
the current state of the `zwp_text_input_v3` object" — i.e. send nothing until
a matching `done`. The demo implements exactly this (`g_tiCommits` is
incremented at the _only_ call site of `commit`), and the discipline fired in
anger during the round-trip below.

The lifecycle hooks: on `enter`, "all state information is invalidated and
needs to be resent" — the demo answers with
`enable + set_surrounding_text + set_content_type + set_cursor_rectangle + commit`.
On `leave`, "the client should reset any preedit string previously set" — the
composition evaporates uncommitted, and the demo sends a committed `disable`.
Every local (keyboard) edit re-sends surrounding text with
`set_text_change_cause(other)`; IM-applied edits use cause `input_method`.

## How far the headless IME stack goes, per compositor

| Layer reached                           | weston 15.0 headless | sway 1.11 headless |
| --------------------------------------- | -------------------- | ------------------ |
| `zwp_text_input_manager_v3` in registry | **no** (v1 only)     | yes (v1 of v3)     |
| `wl_seat` present                       | no                   | yes (v9, caps 0x0) |
| `zwp_text_input_v3.enter` received      | —                    | yes (with IM only) |
| `enable` + state committed              | —                    | yes                |
| `preedit_string` received               | —                    | **yes** (pinyin)   |
| `commit_string` received                | —                    | **yes** (`你好`)   |

**Weston is a dead end for this demo, twice over.** Its registry dump (the
demo logs one `global` line per advertised interface) contains
`zwp_text_input_manager_v1 version=1` and `zwp_input_panel_v1 version=1` but
no v3 manager — weston's text-input stack is still the ancient
`text-input-unstable-v1`/`input-method-unstable-v1` pair that its bundled demo
IM `weston-keyboard` (shipped at `$prefix/libexec/weston-keyboard`; it
connects and exits 0 against the headless instance) speaks. And headless
weston advertises **no `wl_seat` at all** (the
[scaffold finding](./scaffold.md#what-surprised-us)), so even the v1 path has
no seat to hang a text input on. Outcome recorded: _manager absent_.

```text
218 f07_wayland global iface=zwp_input_panel_v1 version=1
220 f07_wayland global iface=zwp_text_input_manager_v1 version=1
226 f07_wayland text_input_manager present=0
228 f07_wayland seat present=0
```

**Sway headless is the real testbed.** `WLR_BACKENDS=headless sway` advertises
`zwp_text_input_manager_v3`, `zwp_input_method_manager_v2`,
`zwp_virtual_keyboard_manager_v1` and a `wl_seat` (initially with zero
capabilities — no devices). Three escalation steps, each a finding:

1. **No IM client connected:** injecting keys with `wtype` (a
   `zwp_virtual_keyboard_v1` client) makes the seat sprout the keyboard
   capability (`caps=0x2`), the demo's surface gets `wl_keyboard` focus and
   raw key events — but **no `zwp_text_input_v3.enter` ever arrives**. Sway's
   text-input relay only routes enter/leave when an input method is attached:
   no IM, no text-input session, even with keyboard focus.
2. **fcitx5 connected (default `keyboard-us` engine):** `ti_enter` arrives
   ~0.7 ms after the first configure, the demo enables + commits (serial 1).
   Typed keys pass through fcitx5's grab and re-emerge as plain `wl_keyboard`
   events; no `done` is ever sent. fcitx5 must be started with
   `WAYLAND_DISPLAY` pointing at sway and falls back cleanly without dbus
   (run it under `dbus-run-session`; a second fcitx5 aborts on the session-bus
   name otherwise).
3. **fcitx5 + pinyin** (`fcitx5-chinese-addons`, profile `DefaultIM=pinyin`,
   `ActiveByDefault=True`): the full choreography below.

## The pinyin round-trip, captured headless

`wtype -d 200 "nihao"`, then `wtype -k space`, against the running demo
(`instrument.d` stream; µs timestamps, `frame_callback`/`global` lines
elided):

```text
1961    f07_wayland ti_enter
1980    f07_wayland ti_commit_state serial=1 enable=1 cause=-1 cursor_rect=16,96 12x48
3508918 f07_wayland ti_preedit_string text="n" cursor_begin=0 cursor_end=1 (pending)
3508953 f07_wayland ti_done serial=1 client_commits=1 in_sync=1
3508971 f07_wayland text committed="" cursor=0 preedit="n" preedit_cursor=0..1
3508991 f07_wayland ti_commit_state serial=2 enable=0 cause=-1 cursor_rect=16,96 12x48
3696534 f07_wayland ti_preedit_string text="ni ha" cursor_begin=0 cursor_end=5 (pending)
3696583 f07_wayland ti_done serial=2 client_commits=2 in_sync=1
3893760 f07_wayland ti_preedit_string text="ni hao" cursor_begin=0 cursor_end=6 (pending)
3893809 f07_wayland ti_done serial=3 client_commits=3 in_sync=1
5102925 f07_wayland ti_commit_string text="你好" (pending)
5102952 f07_wayland ti_done serial=4 client_commits=4 in_sync=1
5102969 f07_wayland text committed="你好" cursor=6 preedit="" preedit_cursor=0..0
5102988 f07_wayland ti_commit_state serial=5 enable=0 cause=0 cursor_rect=88,96 12x48
5103005 f07_wayland ti_done serial=4 client_commits=5 in_sync=0
```

Readings:

- **Pre-edit grows event-by-event** (`n` → `ni ha` → `ni hao` — fcitx5's
  segmented pinyin display), each one a `preedit_string` + `done` pair, each
  applied as pending → current per the six-step recipe. The cursor span
  (`cursor_begin..cursor_end`) covers the whole pre-edit.
- **Space commits**: a `commit_string("你好")` with _no_ accompanying
  `preedit_string` — so the pending pre-edit is the initial empty string, and
  applying the recipe replaces the composition with committed text, cursor at
  its end (byte 6 — indices are UTF-8 bytes, two CJK code points × 3).
- **The serial discipline fired for real**: the demo's post-apply state
  commit (serial 5, with `set_text_change_cause(input_method)` and the caret
  rectangle moved from x=16 to x=88) crossed with a _duplicate_ `done(4)` from
  sway. The demo logs `in_sync=0`, applies the (empty) changes, and correctly
  sends nothing — without the count-your-own-commits rule this is an infinite
  commit/done ping-pong.
- The caret rectangle (`set_cursor_rectangle`) is in **surface-local logical
  coordinates** — under F08's fractional scaling these are _not_ pixels, which
  is exactly how the candidate-window-positioning question feeds
  [F08](./f08-dpi-scaling.md).

Cancel mid-composition (`wtype -d 200 "niha"`, then `wtype -k Escape`) is the
degenerate form, captured with `WAYLAND_DEBUG=1` interleaved:

```text
[ 571282.011] {Default Queue} zwp_text_input_v3#3.preedit_string("ni ha", 0, 5)
[ 571282.042] {Default Queue} zwp_text_input_v3#3.done(4)
3684641 f07_wayland ti_commit_state serial=5 enable=0 cause=-1 cursor_rect=16,96 12x48
[ 572490.355] {Default Queue} zwp_text_input_v3#3.done(5)
4892908 f07_wayland text committed="" cursor=0 preedit="" preedit_cursor=0..0
```

Escape produces a **bare `done`** — no `preedit_string`, no `commit_string` —
so all pending values are at their documented initial (empty) state and
applying them erases the composition. "Cancel" is not an event; it is the
absence of one. Focus loss mid-composition is specified to behave the same
way from the other side (`leave`: "the client should reset any preedit
string previously set") — the demo implements it (drop pre-edit, send
committed `disable`), but a single-window headless run never receives `leave`;
verifying it needs the two-window Tier-C pass.

## Which key events still arrive while the IME composes

The demo logs every `wl_keyboard.key` with the xkb keysym and UTF-8 it
translates to, so the two runs answer this directly:

- **fcitx5 active, plain `keyboard-us` engine:** every key arrives as a raw
  `wl_keyboard` event (`key … sym=0x68 name=h utf8="h"` for the whole of
  "hello"), and no text-input event is ever sent. The IM grabs the keyboard
  ([`zwp_input_method_keyboard_grab_v2`][p-im2]) but _forwards_ what it does
  not consume — through a **virtual keyboard, with its own keymap**: the demo
  sees `kb_keymap` change (and even fcitx5's initial grab keyboard announce
  itself with `kb_keymap format=0 size=0`, the `no_keymap` format).
- **fcitx5 active, pinyin composing:** between `ti_enter` and the final
  `done`, **zero `wl_keyboard.key` events arrive** — `n i h a o` and space
  are consumed wholesale by the grab and re-materialize only as
  `preedit_string`/`commit_string`. There is no per-platform "which keys leak"
  subtlety as on Win32/X11: the grab is all-or-nothing per keystroke.

Corollary for a framework: the `wl_keyboard` stream and the
`zwp_text_input_v3` stream are _alternatives_ gated by the IM's per-key
decision, not parallel feeds to reconcile — but both must be wired up, because
the same seat delivers through either depending on what is focused and
whether/what the IM consumes.

## Tier-C manual script (real session, real IME)

Tier A proved the protocol; Tier C checks the human-visible half (candidate
window anchored at the caret, real keyboard). On any wlroots/KDE session with
fcitx5-pinyin (sway: `input * xkb_layout us` plus `exec fcitx5 -d`; the GTK/Qt
`*_IM_MODULE` env vars must be **unset** so apps use the native protocol):

1. Run the demo (`dub build` once, then `./build/f07_text_input`), click the
   window.
2. `Ctrl+Space` to activate pinyin, type `nihao`, observe: inline cells with
   the yellow underline band growing (the pre-edit), the candidate popup
   anchored at the white caret bar, log lines `ti_preedit_string …`
   `ti_done …` per keystroke.
3. Press `Space`: expect `ti_commit_string text="你好"`, underline band gone,
   committed cells inserted, caret advanced (`cursor=6`), and a
   `ti_commit_state` whose `cursor_rect` x moved two cells right.
4. Type at _both ends_ of a long line (Home/ End, then more text) and watch
   `cursor_rect` track the caret — that is requirement 2 of [the spec][f07].
5. Mid-composition, press `Escape`: pre-edit cells vanish, log shows a bare
   `ti_done` with everything empty.
6. Mid-composition, `Alt+Tab` away: expect `ti_leave` +
   `dropped_preedit_bytes=N`, then a committed `disable` — and nothing
   committed into the line.

## Findings

- **Layer reached, Tier A: complete.** preedit + commit + delete-surrounding
  machinery exercised by a real Pinyin IME, headless: sway 1.11 (compositor) +
  fcitx5 5.1.16/`zwp_input_method_v2` (IM) + `wtype`/`zwp_virtual_keyboard_v1`
  (keys). Weston 15 cannot host this at all (text-input v1 only, no headless
  seat).
- **The serial is your own commit count**; an out-of-sync `done` (observed
  live) must be applied-but-not-answered. Getting this wrong either drops IME
  edits or commit-loops.
- **`enter` is gated on an attached IM, not on keyboard focus** (sway): a
  client cannot distinguish "no IME installed" from "IME not attached yet",
  and must keep both input paths wired forever.
- **Keys are consumed all-or-nothing** by the IM grab; composing keystrokes
  produce no `wl_keyboard` events at all. The two streams never need merging,
  only switching. The IM's forwarding keyboard can swap keymaps mid-session
  (`kb_keymap` re-fires, including the `no_keymap` format) — keymap state must
  be per-event, never cached at startup.
- **All indices are UTF-8 bytes** (`你好` commit → `cursor=6`), and the spec
  forbids splitting code points — an internal UTF-16 or code-point editor
  representation needs a byte-offset conversion layer at the protocol
  boundary.
- The cursor rectangle is **logical-coordinate**, double-buffered state: it
  must be re-committed after every caret move or the candidate window anchors
  to a stale position (it visibly does — step 4 of the Tier-C script).

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f07-text-input

# Tier-A IME stack (each in its own shell, shared XDG_RUNTIME_DIR):
export XDG_RUNTIME_DIR=$(mktemp -d)
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    nix shell nixpkgs#sway -c sway &                      # compositor (wayland-1)
WAYLAND_DISPLAY=wayland-1 nix shell nixpkgs#dbus nixpkgs#fcitx5 -c \
    dbus-run-session fcitx5 &                             # the input method
WAYLAND_DISPLAY=wayland-1 WSI_AUTO_EXIT=1 \
    ./docs/research/.../f07-text-input/build/f07_text_input &  # the demo
WAYLAND_DISPLAY=wayland-1 nix shell nixpkgs#wtype -c wtype "nihao"  # the fingers
```

For the pinyin run, point fcitx5 at `fcitx5-chinese-addons` (set
`FCITX_ADDON_DIRS`/`XDG_DATA_DIRS` to include both packages — nixpkgs:
`qt6Packages.fcitx5-chinese-addons`) and pre-seed
`$XDG_CONFIG_HOME/fcitx5/profile` with `DefaultIM=pinyin` plus
`$XDG_CONFIG_HOME/fcitx5/config` with `ActiveByDefault=True` — and write the
profile while fcitx5 is _not_ running, since it persists its current profile
on exit. Without a compositor the demo prints `SKIP:` and exits `0`; with a
compositor lacking the v3 manager or a seat it logs
`text_input_manager present=0` / `seat present=0` as the finding and still
exits `0` (`WSI_AUTO_EXIT=1` bounds the run to ~3 s).

## Sources

- **[F07 spec][f07]** — requirements 1–4 (inline pre-edit, cursor rectangle,
  lifecycle, payload logging) and the Tier-C verification mandate.
- **[`text-input-unstable-v3`][p-ti3]** — all verbatim quotes above: the
  six-step `done` recipe, the commit-count serial rule, the enter/leave state
  invalidation, byte-index rules (protocol XML at
  `wayland-protocols/unstable/text-input/text-input-unstable-v3.xml`,
  v1.47).
- **[`input-method-unstable-v2`][p-im2]** — the compositor↔IM half
  implemented by sway/fcitx5 (keyboard grab, commit batching); not bound by
  the demo, but the source of every event it received.
- **[Core protocol][p-wayland]** — `wl_seat`/`wl_keyboard` (capability
  dance, keymap event, `no_keymap` format).
- **[Wayland scaffold findings](./scaffold.md)** — base implementation,
  ImportC shim pattern, the no-headless-seat weston surprise.
- Demo sources: [`app.d`](./examples/f07-text-input/app.d),
  [`instrument.d`](./examples/f07-text-input/instrument.d), the `c.c` shim
  and `generate.sh` (which scanner-generates the xdg-shell _and_
  text-input-v3 glue) alongside it; raw-keyboard groundwork in
  [F06](./f06-keyboard.md).

<!-- References -->

[f07]: ../features/f07-text-input.md
[p-ti3]: https://wayland.app/protocols/text-input-unstable-v3
[p-im2]: https://wayland.app/protocols/input-method-unstable-v2
[p-wayland]: https://wayland.app/protocols/wayland
