# AppKit F06 — keyboard & keymap

Scancode → keysym → text is three different questions, and AppKit answers them in three
different places: the hardware `keyCode`, the keyboard-layout engine
([`UCKeyTranslate`][uckeytranslate] over the `uchr` data), and the text-input layer
([`interpretKeyEvents:`][interpretkeyevents] → `insertText:` / `doCommandBySelector:`).
Per the [F06 feature spec][f06], the demo logs all three levels for every press,
exercises the layout engine directly (including a dead-key compose and a US-vs-German
layout split), and probes the two ways to inject a key — a synthetic
[`NSEvent`][nsevent] and a real-HID [`CGEventPost`][cgeventpost]. The program is
[`./examples/f06-keyboard/app.d`][demo-app] (with the shared [`instrument.d`][instrument]
logger), built on the [scaffold][scaffold] recipe plus `-framework Carbon` for the
HIToolbox layout APIs.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked**. This distorts
exactly one path and it is load-bearing here: **input routing.** A locked, non-frontmost
app has no system key window, so events that travel through the WindowServer's session
event tap ([`CGEventPost`][cgeventpost], route 2) are **not** routed to it — that is the
finding below, but it is partly an artifact of the locked screen and is re-queued for an
unlocked Tier-C run. The in-process path ([`-[NSWindow sendEvent:]`][nswindow], route 1)
and the synchronous layout-engine demonstration are **unaffected** by the lock — they
never touch the WindowServer's routing.

| Measurement                                    | Value                                                                                       |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Levels logged per event                        | scancode (`keyCode`), keysym (`charactersIgnoringModifiers`), text (`characters`)           |
| Text routing without `NSTextInputClient`       | `interpretKeyEvents:` → **legacy** `insertText:` (text) + `doCommandBySelector:` (cmds)     |
| Dead key via **synthetic** `NSEvent`           | **no compose** — `characters` forwarded verbatim (`´` then `e`), never `é`                  |
| Dead key via the **layout engine**             | `UCKeyTranslate` composes **`é`** (option-e dead acute, then `e`)                           |
| Layout dependence (same scancode)              | `keyCode 6` → **`z`** (US) vs **`y`** (German QWERTZ)                                       |
| Runtime layout switch (`TISSelectInputSource`) | **rejected**, `OSStatus −50` (`paramErr`) over SSH                                          |
| Key-repeat contract                            | `keyRepeatDelay` **0.250 s**, `keyRepeatInterval` **0.033 s** (~30 Hz); `isARepeat` carried |
| `CGEventPost` under a locked screen            | **not delivered** (`reached=0`) — session tap not routed to a non-frontmost app             |
| Exit                                           | clean `0` (`loop_exit steps=11`)                                                            |

---

## The three levels — who provides each `A[ssh]`

A custom `KeyView` (`acceptsFirstResponder = YES`, made first responder) logs every
[`keyDown:`][keydown]/`keyUp:`/`flagsChanged:` as
`key code=<scancode> sym=<charsIgnoringMods> text=<characters> state=… repeat=… flags=…`.
The three columns come from three different owners:

| Level                 | Source field                  | Who computes it                                                                   |
| --------------------- | ----------------------------- | --------------------------------------------------------------------------------- |
| **scancode** (`code`) | `-[NSEvent keyCode]`          | Hardware/IOKit — a stable per-physical-key number (e.g. `keyCode 6` is one key)   |
| **keysym** (`sym`)    | `charactersIgnoringModifiers` | The active keyboard **layout** (`uchr`), applied by AppKit, ignoring shift/option |
| **text** (`text`)     | `characters` / `insertText:`  | Layout **+ modifier + dead-key/IME state**, via the text-input system             |

The route-1 sequence makes the split concrete (synthetic events, `[window sendEvent:]`):

```text
298714 APPKIT_F06 key code=0 sym=a text=a state=down repeat=0 flags=0x0
501675 APPKIT_F06 key code=18 sym=1 text=! state=down repeat=0 flags=0x20000
701252 APPKIT_F06 key code=123 sym= text= state=down repeat=0 flags=0xa00000
```

A plain `a` agrees on all three levels; **shift-`1`** keeps `sym=1` (the keysym is layout
text _ignoring_ modifiers) but produces `text=!` (modifier applied), the classic
"vk and produced text differ" case; the **left arrow** (`keyCode 123`, `flags=0xa00000`
= Function | NumericPad) has an _empty_ text level — it is a command key, not a text key,
which is the hinge for the next section.

---

## The `interpretKeyEvents:` / `doCommandBySelector:` boundary `A[ssh]`

Each `keyDown:` is routed through [`interpretKeyEvents:`][interpretkeyevents], and the
view implements three sinks: the modern
[`insertText:replacementRange:`][inserttextrange] (the `NSTextInputClient` method), the
**legacy** single-argument `insertText:`, and `doCommandBySelector:`. The finding is
**which one actually fires**:

```text
299440 APPKIT_F06 insert_text variant=legacy text=a
501786 APPKIT_F06 insert_text variant=legacy text=!
701366 APPKIT_F06 do_command selector=moveLeft:
```

- Text keys land on the **legacy `insertText:`**, _not_ `insertText:replacementRange:`.
  Because `KeyView` does **not** conform to [`NSTextInputClient`][nstextinputclient] (that
  is [F07][f07]'s job), the text system falls back to the pre-`NSTextInputClient`
  `NSResponder` path. So the modern marked-text method is never called here — the
  boundary is exactly the `NSTextInputClient` conformance line.
- Command keys are dispatched by selector: the left arrow becomes
  `doCommandBySelector: moveLeft:`. AppKit's [`NSResponder`][nsresponder] key-binding
  machinery turns the function key into a standard editing command **without any text**,
  which is why its `characters` level was empty above. This `insertText:`-vs-
  `doCommandBySelector:` fork is how AppKit separates "insert this string" from "perform
  this action", and it works for synthetic events with no extra setup.

---

## Dead keys: the layout engine composes; the synthetic event chain does not `A[ssh]`

This is the boundary that feeds [F07][f07]. Two ways to ask "option-e then e":

**Through the layout engine ([`UCKeyTranslate`][uckeytranslate], synchronous, no
injection).** The demo pulls the current `uchr` and translates directly. Option-e sets a
non-zero dead-key state and emits _no_ text; the following `e` consumes that state and
composes `é`:

```text
97610 APPKIT_F06 compose layout=current state=dead_set code=14 mods=option dead_state=1 text_len=0 text=
97617 APPKIT_F06 compose layout=current state=composed code=14 mods=none dead_state=65536 text=é
```

**Through the synthetic-event chain (`interpretKeyEvents:`).** The same two keystrokes,
built as `NSEvent`s carrying the spacing acute `´` and routed through the responder:

```text
903404 APPKIT_F06 key code=14 sym=e text=´ state=down repeat=0 flags=0x80000
903507 APPKIT_F06 insert_text variant=legacy text=´
1103459 APPKIT_F06 insert_text variant=legacy text=e
```

`interpretKeyEvents:` **forwards the `characters` we supplied verbatim** — `´` then `e`,
never `é`. It does **not** re-run the layout's dead-key state machine off the `keyCode`,
and with no `NSTextInputClient` there is no marked-text channel for a pending dead key to
live in. So **dead-key composition is owned by the layout (`uchr`) engine**, reachable
two ways: a real keystroke whose HID event the WindowServer translates before the app
sees it, or an app that implements `NSTextInputClient` marked text and lets the input
context drive `UCKeyTranslate`. A synthetic `NSEvent` fed to `interpretKeyEvents:` gets
neither — the exact gap [F07][f07] closes.

---

## Layout dependence and runtime switching `A[ssh]`

The same scancode means different text under a different layout. The demo enumerates
installed input sources, finds `com.apple.keylayout.German`, and pulls its `uchr`
**without switching the system source**, then translates `keyCode 6` under both:

```text
97603 APPKIT_F06 uckey layout=current code=6 mods=none text=z
98056 APPKIT_F06 uckey layout=german  code=6 mods=none text=y
```

`keyCode 6` is `z` on the US layout and `y` on German QWERTZ — same physical key, layout
decides the text. The dead-key mapping is layout-specific too: on German, option-e is
**not** a dead acute but the euro sign, and emits text immediately (no dead state):

```text
106931 APPKIT_F06 compose layout=german state=dead_set code=14 mods=option dead_state=0 text_len=1 text=€
```

Runtime switching, however, was **refused over SSH**:

```text
98172 APPKIT_F06 layout_switch target=german status=-50 note=rejected
```

[`TISSelectInputSource`][coreservices] returned `−50` (`paramErr`) — the German source
came from the _all-installed_ list but is not an _enabled/selectable_ source, and a
locked SSH session cannot enable it. The robust technique is therefore the one the demo
uses for the comparison: read a layout's `uchr` directly and translate against it, which
needs no privilege and no system-state change. Demonstrating layout dependence does
**not** require selecting the layout.

---

## Key repeat and `isARepeat` `A[ssh]`

The system repeat contract comes from `NSEvent` class properties, logged at startup:

```text
87325 APPKIT_F06 repeat_info delay_s=0.250 interval_s=0.033
```

[`keyRepeatDelay`][keyrepeatdelay] is **0.250 s** before the first repeat;
`keyRepeatInterval` is **0.033 s** (~30 Hz) between repeats. **macOS repeats
server-side** — the app does not run a repeat timer (the opposite of Wayland, where
repeat is the client's job); it only reads these for display/UI purposes. A synthetic
keyDown built with `isARepeat:YES` carries the flag through unchanged:

```text
1303437 APPKIT_F06 key code=0 sym=a text=a state=down repeat=1 flags=0x0
```

so `repeat=1` round-trips, and the demo confirms the property values a real key-hold
would honor.

---

## `CGEventPost` under a locked screen `A[ssh]`

Route 2 posts a real HID-style key with [`CGEventCreateKeyboardEvent`][cgeventcreate] +
[`CGEventPost`][cgeventpost] to `kCGSessionEventTap`, then waits to see whether it reaches
`KeyView.keyDown:` (the view watches a distinct `keyCode 2`):

```text
1503278 APPKIT_F06 step name=cgevent_post tap=session code=2
2103266 APPKIT_F06 cgevent_result tap=session code=2 reached=0 note=blocked_or_not_routed
```

It **did not arrive**. With the console locked and the app non-frontmost, the session
event tap delivers to the active session's key window — which is the lock screen, not our
process. (Under an unlocked session this can additionally require Accessibility/TCC
permission for the posting process.) Either way, `CGEventPost` is **not** a reliable
agent-over-SSH injection path; route 1 (`[window sendEvent:]`) is the workhorse because
it bypasses WindowServer routing entirely and drives the app-side chain in-process. The
unlocked-session `CGEventPost` behavior (and any TCC prompt) is queued for a Tier-C
[manual run][queue].

---

## Findings summary (for `event-sequences.md`)

- **Three-level ownership:** scancode = `keyCode` (hardware), keysym =
  `charactersIgnoringModifiers` (layout, modifier-independent), text = `characters` /
  `insertText:` (layout + modifiers + dead-key/IME). Same scancode → different text per
  layout (`keyCode 6`: `z` US / `y` German).
- **Text routing:** without `NSTextInputClient`, `interpretKeyEvents:` calls the **legacy
  `insertText:`** for text keys and `doCommandBySelector:` (e.g. `moveLeft:`) for command
  keys — the modern `insertText:replacementRange:` is never reached. That conformance line
  is the [F07][f07] boundary.
- **Dead-key/compose ownership:** the `uchr` layout engine (`UCKeyTranslate`) — _not_
  `interpretKeyEvents:`. A synthetic `NSEvent` forwards its `characters` verbatim and
  never composes; composition needs real HID translation or `NSTextInputClient` marked
  text.
- **Repeat contract:** server-side; `keyRepeatDelay` 0.250 s, `keyRepeatInterval`
  0.033 s; the app only reads them. `isARepeat` round-trips through synthetic events.
- **Injection:** synthetic `NSEvent` + `[window sendEvent:]` is in-process and reliable
  over SSH; `CGEventPost` to the session tap is **not delivered** to a locked,
  non-frontmost app. Runtime `TISSelectInputSource` switching is refused (`paramErr`) over
  SSH; reading a layout's `uchr` directly sidesteps that.

---

## Sources

- **This demo** — [`./examples/f06-keyboard/app.d`][demo-app],
  [`./examples/f06-keyboard/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (D-subclass recipe, `stop:` + synthetic-post idiom)
  and the [AppKit survey][survey].
- **Feature specs** — [F06 keyboard][f06]; the follow-on [F07 text input][f07]
  (`NSTextInputClient`, marked text); the Tier-C entry in the [manual-run queue][queue].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSEvent`][nsevent], [`keyDown:`][keydown], [`NSResponder`][nsresponder],
  [`interpretKeyEvents:`][interpretkeyevents],
  [`insertText:replacementRange:`][inserttextrange],
  [`NSTextInputClient`][nstextinputclient], [`keyRepeatDelay`][keyrepeatdelay],
  [`UCKeyTranslate`][uckeytranslate], [Text Input Source Services][coreservices],
  [`CGEventPost`][cgeventpost], [`CGEventCreateKeyboardEvent`][cgeventcreate],
  [`NSWindow`][nswindow].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[demo-app]: ./examples/f06-keyboard/app.d
[instrument]: ./examples/f06-keyboard/instrument.d
[f06]: ../features/f06-keyboard.md
[f07]: ../features/f07-text-input.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nsevent]: https://web.archive.org/web/20250609072450/https://developer.apple.com/documentation/appkit/nsevent?language=objc
[keydown]: https://web.archive.org/web/20240521012045/https://developer.apple.com/documentation/appkit/nsresponder/1525805-keydown
[nsresponder]: https://web.archive.org/web/20260603234149/https://developer.apple.com/documentation/appkit/nsresponder
[interpretkeyevents]: https://web.archive.org/web/20240303093433/https://developer.apple.com/documentation/appkit/nsresponder/1531599-interpretkeyevents
[inserttextrange]: https://web.archive.org/web/20250609073312/https://developer.apple.com/documentation/appkit/nstextinputclient/inserttext(_:replacementrange:)
[nstextinputclient]: https://web.archive.org/web/20260115025403/https://developer.apple.com/documentation/appkit/nstextinputclient
[keyrepeatdelay]: https://web.archive.org/web/20250609072435/https://developer.apple.com/documentation/appkit/nsevent/keyrepeatdelay
[uckeytranslate]: https://web.archive.org/web/20250718170127/https://developer.apple.com/documentation/coreservices/1390584-uckeytranslate
[coreservices]: https://web.archive.org/web/20260601220714/https://developer.apple.com/documentation/coreservices
[cgeventpost]: https://web.archive.org/web/20220817031707/https://developer.apple.com/documentation/coregraphics/1456527-cgeventpost
[cgeventcreate]: https://web.archive.org/web/20250219143838/https://developer.apple.com/documentation/coregraphics/1456564-cgeventcreatekeyboardevent
[nswindow]: https://web.archive.org/web/20260503224546/https://developer.apple.com/documentation/appkit/nswindow
