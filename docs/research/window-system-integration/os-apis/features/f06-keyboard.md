# F06 — Keyboard & keymap

Scancode → keysym → text is three different questions, and the platforms split the work
between app and system differently — most sharply on Wayland, where even **key repeat is the
client's job**. This demo logs all three levels for every press under at least two layouts.

## Requirements

1. For every key press/release log `key code=<scancode> sym=<keysym/vk> text=<utf8>
state=down|up repeat=0|1`.
2. **Wayland:** consume the `wl_keyboard.keymap` fd into an `xkb_keymap`/`xkb_state` (the app
   owns the state machine); honor `modifiers` events; implement **client-side key repeat**
   from `repeat_info` (rate/delay), with correct cancellation on key release _and_ on
   keyboard focus loss (`wl_keyboard.leave`) — prove both cancellations in the log.
3. **X11:** same `xkbcommon` state machine fed from the core/XKB events
   (`xkb_x11_keymap_new_from_device`); server-side repeat — log the `repeat=1` detection
   (detectable auto-repeat).
4. **Win32:** log the `WM_KEYDOWN` → `TranslateMessage` → `WM_CHAR` interplay; show at least
   one case where vk and produced text differ (shifted digit, AltGr).
5. **macOS:** `keyDown:` with `keyCode`/`charactersIgnoringModifiers`/`characters`; route
   through `interpretKeyEvents:` and log what `insertText:` receives.
6. Test under two layouts minimum (`us`, plus `bg` or `de`): a letter, a shifted symbol, and a
   **dead-key compose** sequence (e.g. `´` + `e` → `é` on `de`). Layout switching at runtime
   (where scriptable: `setxkbmap`, weston config) is part of the run.

## Instrumentation

The `key …` events above, plus `keymap_event format=… size=…` (Wayland), `repeat_info
rate=… delay=…`, `compose state=…` transitions.

## Findings to record

- A three-column table per platform: scancode-level, sym-level, text-level — who provides
  each.
- The repeat contract per platform (who repeats, what's configurable, cancellation rules).
- Dead-key/compose ownership (xkbcommon compose vs server vs `interpretKeyEvents:`).
- Where the same physical key produces different scancodes/keycodes across platforms.

## Verification

Wayland/X11: Tier A — inject input via `weston --backend=headless` + a virtual keyboard
client, or `xdotool key` under Xvfb; layout via `setxkbmap`/weston config. Win32/macOS:
synthetic input (`SendInput`, CGEvent) makes most of this `A[wine]`/`A[ssh]`; IME-adjacent
and AltGr-hardware nuances go to the manual queue.
