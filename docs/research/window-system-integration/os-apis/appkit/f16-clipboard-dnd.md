# AppKit F16 — clipboard + drag-and-drop

How macOS does inter-process data exchange, measured: `NSPasteboard` eager and
lazy (promised) copy, cross-process verification through `pbpaste`/`pbcopy`,
`changeCount` polling as the **only** change signal, the ownership-loss
callback and its re-entrancy trap (found the hard way — a stack-overflow
crash), the unrendered-promise death probes, and the
`NSDraggingSource`/`NSDraggingDestination` negotiation. The demo is
[`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d)
(with the standard
[`instrument.d`](./examples/f16-clipboard-dnd/instrument.d)), built on the
[scaffold](./scaffold.md) per the [F16 spec][f16].

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn`
(aarch64-darwin, macOS 26.3.1, LDC 1.41.0) over SSH with the console session
**locked** (`session screen_locked=1` in every log). Clipboard traffic is fully
testable in this state — the pasteboard server (`com.apple.pboard`) doesn't
care about the screen; only the DnD _destination_ events need a live drag,
which the locked WindowServer never synthesizes (Tier C, see
[below](#dnd-the-source-side-works-headless-the-destination-needs-a-real-drag)).

| Measurement                                       | Value                                                                                   |
| ------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Eager copy → `pbpaste` round-trip                 | `é漢🎈` (9 UTF-8 bytes) byte-exact, `match=1`                                           |
| Lazy promise: declare → demand latency            | **328–331 ms** — exactly when `pbpaste` ran, not before                                 |
| External-change signal                            | `changeCount` poll only — **no notification API exists**                                |
| `pasteboardChangedOwner:`                         | fires **only** while a promise is unfulfilled; re-entrancy hazard                       |
| Source exits with unrendered promise              | reader gets **0 bytes**; even the type advertisement vanishes                           |
| `beginDraggingSessionWithItems:` (locked session) | session object created, drag pasteboard populated, **0** destination callbacks (Tier C) |

---

## Copy, eager: `clearContents` is the ownership transaction

One tick of the scripted run, verbatim:

```text
686455 APPKIT_F16 clip_copy mode=eager fmt=public.utf8-plain-text bytes=9 ok=1 change_count=1308->1309(clear)->1309
984872 APPKIT_F16 clip_verify via=pbpaste mode=eager bytes=9 data=é漢🎈 match=1
```

- **The `changeCount` bump happens at [`clearContents`][nspasteboard], not at
  the write.** `clearContents` returns the new count (1308→1309 — it is the
  "take ownership" call); the subsequent `setString:forType:` does **not** bump
  it again. A multi-type write is therefore one transaction: clear once, write
  N types, one bump total.
- The cross-process read-back (a spawned `pbpaste`) returned the 9 UTF-8 bytes
  of `é漢🎈` byte-exact. One trap worth recording: **`pbpaste`/`pbcopy`
  transcode to the POSIX locale**, and an SSH session without `LANG` mangled
  the payload into 4 bytes of `é???` (MacRoman + substitution). `LANG=en_US.UTF-8`
  fixes it — the pasteboard content itself was never wrong, only the CLI's
  re-encoding.

## Copy, lazy: the promise is demanded by the reader, not the clock

`declareTypes:owner:` posts a type list with **no data**; the owner's
[`pasteboard:provideDataForType:`][nspasteboard] renders on demand:

```text
1293141 APPKIT_F16 clip_offer mode=lazy formats=[public.utf8-plain-text] change_count=1309->1310 provider_called=0
1588145 APPKIT_F16 clip_lazy provider_called=0 note=no_reader_yet
1624010 APPKIT_F16 clip_request fmt=public.utf8-plain-text lazy=1 main_thread=1 declare_to_demand_us=330869
1624130 APPKIT_F16 clip_send bytes=9 fmt=public.utf8-plain-text lazy=1
1892510 APPKIT_F16 clip_verify via=pbpaste mode=lazy bytes=9 data=é漢🎈 provider_called=1 match=1
```

- The declare bumps `changeCount` immediately (readers see the _offer_ at
  once), but the provider sat uncalled through a full 300 ms tick
  (`no_reader_yet`) and fired only ~331 ms after the declare — the moment the
  spawned `pbpaste` actually read. The laziness is real and reader-paced.
- The demand was delivered **on the main thread, via the run loop**
  (`main_thread=1`): an app that blocks its run loop while a reader pastes
  deadlocks the reader (the demo spawns `pbpaste` in the background for
  exactly this reason). This is macOS's analogue of Win32's
  `WM_RENDERFORMAT` and X11's `SelectionRequest` — same design, different
  delivery vehicle.

## The event model: poll `changeCount` — there is nothing else

NSPasteboard has **no change notification** — nothing in the
[`NSPasteboard`][nspasteboard] API surface posts an `NSNotification` when
another process writes. The only documented signal is the change count;
Apple's [Pasteboard Programming Guide][pbguide] (Concepts, verbatim):

> The change count is a computer-wide variable that increments every time the
> contents of the pasteboard changes (a new owner is declared). … By examining
> the change count, an application can determine whether the current data in
> the pasteboard is the same as the data it last received. The `changeCount`
> and `clearContents` methods return the change count.

"Examining" means polling. The demo's tick-timer poll is therefore the
_canonical_ implementation, and it works:

```text
2188015 APPKIT_F16 step name=external_pbcopy_takeover promise_state=fulfilled
2491224 APPKIT_F16 clip_external_change detected_by=changeCount_poll old=1315 new=1316
2790767 APPKIT_F16 clip_offer_read change_count=1316 formats=[public.utf8-plain-text,NSStringPboardType] n=2
2796307 APPKIT_F16 clip_paste fmt=public.utf8-plain-text bytes=11 data=external-Ω ownership_lost_callbacks=0
```

The paste path logs the offered formats first (`types` — the external `pbcopy`
write is advertised as modern `public.utf8-plain-text` _plus_ the legacy
`NSStringPboardType` alias), then the chosen type and byte count. Every
clipboard-watching app on macOS (clipboard managers included) is a poller;
a framework's "clipboard changed" event on this platform can only be
poll-synthesized.

## `pasteboardChangedOwner:` — only for unfulfilled promises, and a re-entrancy trap

The takeover above (promise already rendered) produced
`ownership_lost_callbacks=0` — **no callback**. Declaring a _fresh_ promise and
letting `pbcopy` take the board while it is still pending:

```text
3093028 APPKIT_F16 clip_offer mode=lazy_unfulfilled change_count=1317 ownership_lost_callbacks=0
3392543 APPKIT_F16 step name=external_pbcopy_takeover promise_state=unfulfilled
3692726 APPKIT_F16 ownership_lost callback=pasteboardChangedOwner main_thread=1 n=1
3692755 APPKIT_F16 clip_external_change detected_by=changeCount_poll old=1317 new=1318
```

Two measured facts a framework must respect:

1. **The callback is not a general loss signal.** It fired only when ownership
   changed while our promise was unrendered — its job is "release the promised
   data, nobody will ask for it", not "the clipboard changed" (that's the
   poll). Wayland's `wl_data_source.cancelled` and Win32's
   `WM_DESTROYCLIPBOARD` fire on every loss; macOS's fires on abandoned
   promises only.
2. **It is delivered re-entrantly from inside `changeCount`.** The timestamps
   show the callback arriving _during_ the poll's `changeCount` call. The
   demo's first version called `pb.changeCount()` inside the callback to log
   the new count — and died of stack overflow: AppKit's
   `-[NSPasteboard changeCount]` → `-[_NSPasteboardOwnersCollection
handleOwnershipChange]` → `pasteboardChangedOwner:` → `changeCount` →
   `handleOwnershipChange` → … recursed until `EXC_BAD_ACCESS` ("Thread stack
   size exceeded due to excessive recursion", crash-report verbatim). **Do not
   touch the pasteboard from inside `pasteboardChangedOwner:`.**

## Source exits first: the promise dies with the process

Two run modes declare a promise and quit without rendering it
(`WSI_MODE=promise-exit-return` returns from `main`;
`promise-exit-hard` calls `_exit(2)`):

```text
35525 APPKIT_F16 clip_offer mode=promise_exit formats=[public.utf8-plain-text] change_count=1320 provider_called=0
35531 APPKIT_F16 exit kind=return_from_main provider_called=0
```

After **both** exit paths: `pbpaste` returns **0 bytes**, and
`osascript -e 'clipboard info'` reports an empty pasteboard — even the
_declared type list_ is gone. Neither exit path triggered a final
`provideDataForType:` (`provider_called=0` at exit). On macOS, **nobody pays
for an unrendered promise when the source dies: the pasteboard server simply
drops the whole entry**. (Contrast X11, where the selection vanishes with the
owner too but a clipboard _manager_ may have already taken `SAVE_TARGETS`, and
Win32, where `OleFlushClipboard`-style rendering on exit is the app's
responsibility.) Notably, even the _graceful_ exit (plain `return` from
`main`, full C runtime teardown) rendered nothing — only an exit that goes
through AppKit's own application-termination machinery could, and neither a
crash nor a CLI-style exit reaches it. A framework must treat promised data
as lost-on-source-death and flush anything precious eagerly before quitting.

## DnD: the source side works headless; the destination needs a real drag

Clipboard and DnD share the same machinery on macOS — a drag _is_ a
pasteboard (`NSPasteboardNameDrag`), negotiated through the same type system.
The demo registers its view for `public.file-url` + `public.utf8-plain-text`
([`registerForDraggedTypes:`][nsdragdest]), implements the full
[`NSDraggingDestination`][nsdragdest] protocol, and starts a session over its
own view with a synthetic mouse-down:

```text
4003892 APPKIT_F16 dnd_begin api=beginDraggingSessionWithItems types=[public.file-url,public.utf8-plain-text]
4005680 APPKIT_F16 dnd_session started=1 seq=28
4892574 APPKIT_F16 dnd_drag_pasteboard change_count=45 formats=[public.file-url,CorePasteboardFlavorType 0x6675726C,dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn,NSFilenamesPboardType,dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu,Apple URL pasteboard type,public.utf8-plain-text,NSStringPboardType] n=8
4892874 APPKIT_F16 dnd_drag_pasteboard file_url=file:///tmp/wsi-m8/f16-drop.txt
4892886 APPKIT_F16 dnd_summary entered=0 updated=0 dropped=0 note=no_destination_events_headless_locked_session_tierC
```

- **What worked `A[ssh]`:** [`beginDraggingSessionWithItems:event:source:`][nsdragsession]
  accepted the synthetic event and returned a live session (sequence number
  28), and the **drag pasteboard got fully populated** — our 2 declared types
  fanned out to **8** offered flavors (legacy `NSFilenamesPboardType`,
  `Apple URL pasteboard type`, `CorePasteboardFlavorType 0x6675726C` =
  `'furl'`, and two `dyn.*` UTIs), AppKit's automatic
  format-compatibility translation at work. The negotiation _offer_ side is
  fully observable headless.
- **What did not:** zero `NSDraggingDestination` callbacks
  (`entered=0 updated=0 dropped=0`) and none of the `NSDraggingSource`
  feedback methods (`draggingSession:willBeginAtPoint:` etc.) — with the
  console locked, the WindowServer never runs the drag loop that tracks the
  cursor and dispatches enter/update/drop. The destination half
  (`draggingEntered:` → mask negotiation → `prepareForDragOperation:` →
  `performDragOperation:` → `concludeDragOperation:`) is implemented and
  logged but requires a logged-in console drag — **Tier C**, exactly as the
  [F16 spec][f16] anticipates for Finder drags.

> [!NOTE]
> The destination protocol's shape still yields one Tier-A finding: the
> file-URL type on macOS is a **URL string** (`public.file-url` →
> `file:///tmp/wsi-m8/f16-drop.txt` read straight off the drag pasteboard),
> not a path list — closer to XDND's `text/uri-list` than to Win32's
> `CF_HDROP` block.

## One data API for both — what this means for a framework

- **Clipboard and DnD are the same machinery** (pasteboard + UTI types +
  owner/promise model); a framework's data-exchange API can be one
  type-negotiation abstraction with two transports. This matches Wayland/X11
  (one selection mechanism) and diverges from Win32 (clipboard API vs
  COM `IDataObject`).
- **Change detection must be a poll.** Budget for a timer (the demo's 300 ms
  tick is what real clipboard managers use); there is nothing to subscribe to.
- **Promises are main-thread, run-loop-delivered, and die with the source.**
  A framework offering delayed rendering must keep the run loop responsive
  and must not promise data it cannot regenerate after a crash.
- `pasteboardChangedOwner:` is a _promise-cancellation_ hook, not a loss
  event — and it must not re-enter the pasteboard.

## Build and run

`A[ssh]` on the Mac (dub is avoided on this host — it fork-ENOMEMs; invoke
`ldc2` directly, with [`objective-d`][objd]'s runtime modules on the command
line):

```bash
OBJD=$HOME/.dub/packages/objective-d/1.1.2/objective-d/source
ldc2 -I$OBJD app.d instrument.d $OBJD/objc/autorelease.d $OBJD/objc/rt.d \
    $OBJD/objc/block.d -L-framework -LCocoa -of=./demo
WSI_AUTO_EXIT=1 ./demo                    # the scripted run quoted above
WSI_MODE=promise-exit-return ./demo       # then: pbpaste → 0 bytes
WSI_MODE=promise-exit-hard   ./demo       # then: pbpaste → 0 bytes
```

Headless (no WindowServer): prints `SKIP:` and exits 0. The scripted run is
deterministic — two consecutive full runs produced identical verdict-relevant
lines.

## Sources

- **This demo** — [`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d),
  [`instrument.d`](./examples/f16-clipboard-dnd/instrument.d); the
  [AppKit scaffold](./scaffold.md) (toolchain recipe, `A[ssh]` methodology);
  the [F16 feature spec][f16].
- **Sibling F16 measurements** — [X11](../x11/f16-clipboard-dnd.md),
  [Wayland](../wayland/f16-clipboard-dnd.md),
  [Win32](../win32/f16-clipboard-dnd.md) (the negotiation-sequence and
  delayed-rendering comparisons above).
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSPasteboard`][nspasteboard] (`changeCount`, `clearContents`,
  `declareTypes:owner:`, `pasteboard:provideDataForType:`),
  [Pasteboard Programming Guide][pbguide] (the no-notification quote),
  [`NSDraggingDestination`][nsdragdest], [`NSDraggingSource`][nsdragsource],
  [`NSDraggingSession`][nsdragsession].
- **D ↔ Objective-C** — the [`objective-d`][objd] package; the subclassing
  recipe in the [scaffold](./scaffold.md#the-d-side-nsview-subclass-extern-objective-c-worked-no-fallback-needed).

<!-- References -->

[f16]: ../features/f16-clipboard-dnd.md
[objd]: https://github.com/KitsunebiGames/objective-d

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nspasteboard]: https://web.archive.org/web/20260207134741/https://developer.apple.com/documentation/appkit/nspasteboard
[pbguide]: https://web.archive.org/web/20250503101359/https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/PasteboardGuide106/Articles/pbConcepts.html
[nsdragdest]: https://web.archive.org/web/20260411145106/https://developer.apple.com/documentation/appkit/nsdraggingdestination
[nsdragsource]: https://web.archive.org/web/20260608164038/https://developer.apple.com/documentation/appkit/nsdraggingsource
[nsdragsession]: https://web.archive.org/web/20260105004404/https://developer.apple.com/documentation/appkit/nsdraggingsession
