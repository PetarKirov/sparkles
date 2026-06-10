# AppKit F07 — IME / text input (`NSTextInputClient`)

[F06][f06-doc] ended at a boundary: without [`NSTextInputClient`][nstextinputclient],
`interpretKeyEvents:` falls back to the legacy single-argument `insertText:` and a
synthetic dead key passes through verbatim (`´` then `e`, never `é`). This demo crosses
that boundary, per the [F07 feature spec][f07]: a custom view implements the **full**
protocol (all eleven methods), keeps a single-line editor model (committed text +
inline **marked** text with underline styling + caret), and logs every protocol
callback with its arguments — the call choreography is the deliverable. The program is
[`./examples/f07-text-input/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe
(Cocoa only; no Carbon needed this time).

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked**. The lock
distorts one load-bearing thing here: **input-context activation**. AppKit activates a
view's [`NSTextInputContext`][nstextinputcontext] when the app becomes active — which a
locked session never grants — so the demo calls `activate` explicitly (the
[activation-gate finding](#the-activation-gate-a-ssh)). What a real IME does with that
context (candidate windows, CJK conversion) is **Tier C**: see the
[manual script](#tier-c-script-real-pinyin-input) below.

| Measurement                            | Value                                                                                          |
| -------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Protocol conformance from D            | runtime [`class_addProtocol`][class-addprotocol]: `conforms_before=0` → `conforms_after=1`     |
| `-[NSView inputContext]`               | **non-nil** for the conforming view, **nil** for a plain `NSView` subclass                     |
| Text routing WITH conformance          | **`insertText:replacementRange:`** (modern); the legacy `insertText:` never fired              |
| Dead key, plain synthetic `NSEvent`    | still **verbatim** (`´` then `e`) — no event ref, TSM never engages                            |
| Dead key, CGEvent-backed `NSEvent`     | **composes**: `setMarkedText:"´"` (marked!) → `insertText:"é"` replacing it                    |
| The gate                               | composition requires an **activated** input context (`[ctx activate]` over SSH); route is moot |
| Esc mid-composition                    | `insertText:"´"` (TSM **commits** the accent) then `doCommandBySelector: cancelOperation:`     |
| Focus loss mid-composition             | **nothing** — no `unmarkText`, no commit; the marked text is orphaned in the client            |
| `firstRectForCharacterRange:` (system) | **never queried** headless (no candidate window); contract demonstrated by direct calls        |
| Exit                                   | clean `0` (`loop_exit steps=14`)                                                               |

---

## Getting a real input context from D `A[ssh]`

AppKit gates the entire IME path on **protocol conformance**, not on implemented
selectors: [`-[NSView inputContext]`][inputcontext] creates a context only "if the view
subclass conforms to the `NSTextInputClient` protocol". A D-defined
`extern (Objective-C)` class implements the methods but carries no conformance
metadata, so the demo attaches the AppKit-registered protocol at runtime —
`objc_getProtocol("NSTextInputClient")` + [`class_addProtocol`][class-addprotocol]
(via objective-d's typed `Class`/`Protocol` wrappers), **before** the view becomes
first responder:

```text
78408 APPKIT_F07 protocol_attach class=TextView protocol_found=1 conforms_before=0
78429 APPKIT_F07 protocol_attach added=1 conforms_after=1
...
92926 APPKIT_F07 input_context view=TextView ctx=non-nil
92942 APPKIT_F07 input_context view=PlainView ctx=nil
100020 APPKIT_F07 input_context selected_source=com.apple.keylayout.US
```

- Implementing all eleven methods left `conformsToProtocol:` at **0** — selectors
  alone do not confer conformance; one `class_addProtocol` call does.
- The conforming `TextView` gets a non-nil input context bound to the real keyboard
  input source (`com.apple.keylayout.US`); the sibling `PlainView` (a focusable
  `NSView` subclass with no conformance) gets **nil** — the "bespoke rendering view
  silently bypasses the IME" trap the [survey][survey] records for sokol/Uno,
  reproduced in four log lines.
- As soon as the view becomes first responder the context interrogates the client:
  five `validAttributesForMarkedText` calls arrive **before any key is sent**.

---

## The boundary flip vs F06 `A[ssh]`

Same injection route as [F06][f06-doc] (synthetic `NSEvent` → `[window sendEvent:]` →
`keyDown:`), same plain keys — different sink. With conformance attached, plain text
lands on the **modern** [`insertText:replacementRange:`][inserttextrange] with
`replacementRange={NSNotFound,0}` ("insert at the insertion point"):

```text
362490 APPKIT_F07 key code=4 text=h
364777 APPKIT_F07 tic_has_marked_text -> 0
365140 APPKIT_F07 tic_insert_text text=h class=__NSCFString repl={NSNotFound,0}
365181 APPKIT_F07 state at=insert text="h" caret=1 marked="" marked_at=0
```

The legacy single-argument `insertText:` — where **all** text landed in F06 —
never fired once in any F07 run. The conformance line is exactly the routing switch.
Before each insertion the context probes `hasMarkedText` (the client's composition
state is consulted on every key), and the string argument arrives as a plain
`__NSCFString` — IMEs may pass `NSAttributedString` instead, so the demo's
`stringOf` helper checks `respondsToSelector("string")` and logs the concrete class
on every call.

---

## Dead-key composition: three event provenances, three outcomes `A[ssh]`

The headline. The same option-e + e pair was driven through the same view in two ways
(the third — a real keystroke — is Tier C), and the outcome depends entirely on what
backs the `NSEvent`:

| Provenance                                               | What the input context did                                           |
| -------------------------------------------------------- | -------------------------------------------------------------------- |
| Synthetic `keyEventWithType:…` (no event ref)            | forwarded `characters` **verbatim** to `insertText:` — `´`, then `e` |
| CGEvent-backed ([`eventWithCGEvent:`][eventwithcgevent]) | **full marked-text choreography** → `é` (below)                      |
| Real keystroke under a CJK IME                           | Tier C — see the [manual script](#tier-c-script-real-pinyin-input)   |

A plain synthetic `NSEvent` has no underlying Quartz event, so the text system has
nothing to hand TSM and falls back to forwarding the `characters` we typed in — the
F06 verbatim behavior **survives conformance**:

```text
859282 APPKIT_F07 key code=14 text=´
859427 APPKIT_F07 tic_insert_text text=´ class=__NSCFString repl={NSNotFound,0}
1118959 APPKIT_F07 key code=14 text=e
1119104 APPKIT_F07 tic_insert_text text=e class=__NSCFString repl={NSNotFound,0}
```

The fix is to give the event a real backing: create a keyboard `CGEvent` against a
**private [`CGEventSource`][cgeventsource]** (`kCGEventSourceStatePrivate` — the
source owns the dead-key state machine), wrap it with
[`+[NSEvent eventWithCGEvent:]`][eventwithcgevent], and dispatch it **in-process**
straight to `keyDown:` — it is never posted through the WindowServer tap (which F06
showed is not routed to a locked, non-frontmost app). Two findings before the text
system even sees it: the Quartz layer already runs the layout's dead-key machine
(option-e wraps with **empty** `characters`; the following `e` wraps as **`é`**), and
the first such event makes TSM wake up app-side (a `TSM AdjustCapsLockLED…` line
appears on stderr). The full choreography, verbatim:

```text
1369137 APPKIT_F07 inject route=cgevent_wrap label=opt_e_deadacute code=14 wrapped_type=10 wrapped_text=
1369188 APPKIT_F07 key code=14 text=
1370984 APPKIT_F07 tic_has_marked_text -> 0
1371075 APPKIT_F07 tic_valid_attributes -> empty            (x5)
1371271 APPKIT_F07 tic_set_marked_text text=´ class=__NSCFString sel={1,0} repl={NSNotFound,0}
1371301 APPKIT_F07 state at=set_marked text="hi´e" caret=4 marked="´" marked_at=4
1371493 APPKIT_F07 handle_event ctx=non-nil handled=1

1609335 APPKIT_F07 key code=14 text=é
1609581 APPKIT_F07 tic_has_marked_text -> 1
1609633 APPKIT_F07 tic_valid_attributes -> empty            (x4)
1609759 APPKIT_F07 tic_insert_text text=é class=__NSCFString repl={NSNotFound,0}
1609788 APPKIT_F07 state at=insert text="hi´eé" caret=5 marked="" marked_at=4
```

This is exactly the contract the [F07 spec][f07] asks the client to honor:
[`setMarkedText:selectedRange:replacementRange:`][setmarkedtext] installs the pending
`´` as **marked text** at the caret (`sel={1,0}` = caret after it, relative to the
marked string; `repl={NSNotFound,0}` = at the insertion point; the demo renders marked
cells with a 2 pt underline, distinct from committed cells), and the commit arrives as
a plain `insertText:"é"` with `repl={NSNotFound,0}` — **when marked text exists, an
insert replaces it**; the IME does not spell that range out. The gap F06 measured is
closed: composition for injected events works, provided the event is CGEvent-backed
and the context is active.

---

## The activation gate `A[ssh]`

First attempts at the CGEvent route produced _nothing_ — TSM engaged (the CapsLock-LED
line) and swallowed the events without a single client callback. Isolating the two
variables (dispatch route × explicit activation) over four runs:

| Run                 | Route                       | `[ctx activate]` | Composition        |
| ------------------- | --------------------------- | ---------------- | ------------------ |
| run 2               | `interpretKeyEvents:`       | no               | **no** — swallowed |
| run 3 (default)     | `handleEvent:` (+ fallback) | yes              | **yes**            |
| `WSI_USE_IKE=1`     | `interpretKeyEvents:`       | yes              | **yes**            |
| `WSI_NO_ACTIVATE=1` | `handleEvent:` (+ fallback) | no               | **no** — swallowed |

The route is irrelevant (`interpretKeyEvents:` internally offers the event to the
context's [`handleEvent:`][handleevent], which returned `handled=1` in every run —
even the swallowed ones). **Activation is the gate.** AppKit activates the context
when the app becomes active; a locked SSH session never delivers that, so the demo
calls [`activate`][nstextinputcontext] explicitly after `makeFirstResponder:`. A
binding running under a normal GUI session gets this for free — but the failure mode
(everything wired, `handled=1`, zero callbacks) is worth knowing: it is what
IME-while-inactive looks like.

---

## Cancel and focus loss mid-composition `A[ssh]`

**Esc** (CGEvent-backed `keyCode 53`, sent while `´` was marked) does **not** discard
the composition — TSM first **commits the pending accent as text**, then issues the
cancel command. `unmarkText` was never called:

```text
2110561 APPKIT_F07 key code=53 text=´
2110897 APPKIT_F07 tic_insert_text text=´ class=__NSCFString repl={NSNotFound,0}
2110921 APPKIT_F07 state at=insert text="hi´eé´" caret=6 marked="" marked_at=5
2111222 APPKIT_F07 do_command selector=cancelOperation: has_marked=0
```

(Note the wrapped Esc event itself carries `characters="´"` — the _event source_
flushes its dead-key state into the next event, whatever the key. The commit-then-
`cancelOperation:` order means a client that maps Esc to "clear the field" must be
prepared for the accent to land first.)

**Focus loss** (`makeFirstResponder:` to the plain view, while `´` was marked) is the
sharpest finding: **nothing happens to the marked text.** No `unmarkText`, no commit,
no `doCommandBySelector:` — the view resigns and the pre-edit simply stays in the
client's model:

```text
2618015 APPKIT_F07 step name=focus_steal target=PlainView has_marked=1
2618095 APPKIT_F07 focus state=resign has_marked=1
2618129 APPKIT_F07 state at=after_resign text="hi´eé´" caret=6 marked="´" marked_at=6
```

The policy (commit? discard? keep?) is **the client's responsibility** — AppKit's own
text views commit; a windowing-layer binding must pick one deliberately (e.g. call
`unmarkText`/`discardMarkedText` in `resignFirstResponder`). The demo leaves it
untouched to expose the raw behavior.

---

## `replacementRange` semantics and the candidate-window anchor `A[ssh]`

No headless path makes a real IME send a non-`NSNotFound` replacement range
(reconversion does), so the demo drives its own
`insertText:"X" replacementRange={0,2}` to pin the editor-side contract — the range
addresses **committed text in UTF-16 units** and the insertion replaces it:

```text
3114814 APPKIT_F07 tic_insert_text text=X class=NSTaggedPointerString repl={0,2}
3114848 APPKIT_F07 state at=insert text="hi´eé´X" ...   (run 3: replaces marked text)
3090766 APPKIT_F07 state at=insert text="X´e" caret=1   (WSI_NO_ACTIVATE run: replaces "hi")
```

(The two runs differ because in run 3 marked text existed, and marked text takes
precedence over the explicit range — matching how the composition commit behaved.)

[`firstRectForCharacterRange:actualRange:`][firstrect] is the **candidate-window
anchor**: the IME asks for the on-screen rect of a character range and the client must
answer in **screen coordinates** (view → window via `convertRect:toView:nil`, window →
screen via `convertRectToScreen:`). The system never queried it in this headless run —
a dead-key composition shows no candidate window, and that re-query-as-the-caret-moves
proof needs the Tier-C Pinyin session. The demo demonstrates the math by calling it
directly at both ends of the line (9 pt cells starting at x=10; window at (120,120)):

```text
3360474 APPKIT_F07 tic_first_rect range={0,1} view=(10,20 9x16) screen=(130,140 9x16)
3360493 APPKIT_F07 tic_first_rect range={7,1} view=(73,20 9x16) screen=(193,140 9x16)
3360516 APPKIT_F07 tic_character_index screen=(193,140) view_x=73.0 -> 7
```

— two different anchors for two different caret positions, and
[`characterIndexForPoint:`][characterindex] (also screen-coordinate) round-trips the
second anchor back to index 7.

---

## Tier C script: real Pinyin input

Run on `mac-bsn` in an **unlocked** GUI session (results → this doc):

1. System Settings → Keyboard → Input Sources → add **Pinyin – Simplified**; switch to
   it in the menu bar.
2. Build per the [scaffold][scaffold] (`nix develop … ldc2 …`, binary staged at
   `/tmp/wsi-m4/f07-text-input/demo`), run `./demo` with **no** env vars, click the
   window, and type `nihao` then **Space**, then type `x` then **Esc**, then start
   `ni` and click another window.
3. Expect on stderr: per-keystroke `tic_set_marked_text` updates (string class likely
   `NSConcreteAttributedString` — log the attributed ranges), **system-driven**
   `tic_first_rect` calls re-querying the anchor as the pre-edit grows (the candidate
   window should hug the blue marked cells), `tic_insert_text text=你好` on Space,
   the Esc behavior under a real IME (does Pinyin discard via `unmarkText`, unlike the
   dead-key commit?), and the focus-loss fate of an uncommitted pre-edit.
4. Also worth one minute: dead-key option-e + e on the US layout from the real
   keyboard — expect the same `setMarkedText:`/`insertText:` choreography as the
   CGEvent route above.

---

## Findings summary (for `event-sequences.md`)

- **Conformance is the switch, attached at runtime:** implementing the selectors does
  nothing until `class_addProtocol`; then `inputContext` becomes non-nil and text
  routing flips from legacy `insertText:` to `insertText:replacementRange:`. A
  non-conforming view has **no input context at all** (the silent-IME-bypass trap).
- **Composition choreography** (dead key): `hasMarkedText` →
  `validAttributesForMarkedText` (×5) → `setMarkedText:"´" sel={1,0}
repl={NSNotFound,0}` → (next key) `hasMarkedText`=1 → `insertText:"é"
repl={NSNotFound,0}` — the insert **implicitly replaces** the marked text.
- **Synthetic events need a Quartz backing to compose:** plain `keyEventWithType:`
  events are forwarded verbatim even with full conformance; CGEvent-backed events
  (private source = dead-key state) compose. TSM additionally requires an **activated**
  input context — implicit on app activation, explicit (`activate`) over SSH.
- **Esc commits, then cancels** (`insertText:"´"` → `cancelOperation:`); **focus loss
  does nothing** — the pre-edit's fate on deactivation is client policy.
- **Anchors are screen-coordinate** (`firstRectForCharacterRange:` /
  `characterIndexForPoint:`), one rect per caret position; system re-query only
  observable under a real IME (Tier C).

---

## Sources

- **This demo** — [`./examples/f07-text-input/app.d`][demo-app],
  [`./examples/f07-text-input/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, build command), the
  [F06 keyboard findings][f06-doc] (the boundary this demo crosses), and the
  [AppKit survey][survey].
- **Feature specs** — [F07 text input][f07]; [F06 keyboard][f06]; the Tier-C entries
  in the [manual-run queue][queue].
- **Apple Developer documentation** (Wayback-pinned where a verified snapshot exists;
  this host is bot-hostile): [`NSTextInputClient`][nstextinputclient],
  [`insertText:replacementRange:`][inserttextrange],
  [`setMarkedText:selectedRange:replacementRange:`][setmarkedtext],
  [`firstRectForCharacterRange:actualRange:`][firstrect],
  [`characterIndexForPoint:`][characterindex],
  [`NSTextInputContext`][nstextinputcontext] (`activate`,
  [`handleEvent:`][handleevent]), [`inputContext`][inputcontext],
  [`interpretKeyEvents:`][interpretkeyevents],
  [`eventWithCGEvent:`][eventwithcgevent], [`CGEventSource`][cgeventsource],
  [`class_addProtocol`][class-addprotocol].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[f06-doc]: ./f06-keyboard.md
[demo-app]: ./examples/f07-text-input/app.d
[instrument]: ./examples/f07-text-input/instrument.d
[f06]: ../features/f06-keyboard.md
[f07]: ../features/f07-text-input.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs -->

[nstextinputclient]: https://web.archive.org/web/20260115025403/https://developer.apple.com/documentation/appkit/nstextinputclient
[inserttextrange]: https://web.archive.org/web/20250609073312/https://developer.apple.com/documentation/appkit/nstextinputclient/inserttext(_:replacementrange:)
[setmarkedtext]: https://web.archive.org/web/20250609073312/https://developer.apple.com/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:)
[firstrect]: https://web.archive.org/web/20251002235340/https://developer.apple.com/documentation/appkit/nstextinputclient/firstrect(forcharacterrange:actualrange:)
[characterindex]: https://web.archive.org/web/20251003000127/https://developer.apple.com/documentation/appkit/nstextinputclient/characterindex(for:)
[nstextinputcontext]: https://web.archive.org/web/20240715104505/https://developer.apple.com/documentation/appkit/nstextinputcontext
[handleevent]: https://developer.apple.com/documentation/appkit/nstextinputcontext/handleevent(_:)
[inputcontext]: https://web.archive.org/web/20250609073511/https://developer.apple.com/documentation/appkit/nsview/inputcontext
[interpretkeyevents]: https://web.archive.org/web/20240303093433/https://developer.apple.com/documentation/appkit/nsresponder/1531599-interpretkeyevents
[eventwithcgevent]: https://developer.apple.com/documentation/appkit/nsevent
[cgeventsource]: https://developer.apple.com/documentation/coregraphics/cgeventsource
[class-addprotocol]: https://developer.apple.com/documentation/objectivec/class_addprotocol(_:_:)
