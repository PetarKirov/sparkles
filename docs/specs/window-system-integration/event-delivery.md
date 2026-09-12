# `sparkles:wsi` — Event delivery under load

_A decision record: the unresolved questions about how `WindowEvent`s are queued,
merged, dropped or held back when a consumer cannot keep up, with the facts that
force each one and a recommended answer. Accepted answers move into
[SPEC.md](./SPEC.md) as requirements; this page keeps the reasoning. Index entry:
`WSI-O9` in [open-issues.md](./open-issues.md)._

**Status:** partly decided. `EQ1`–`EQ6`, `EQ8`, `EQ9` and `EQ13` were accepted on
September 13, 2026 and are ready to move into [SPEC.md](./SPEC.md) as requirements;
`EQ7` was reopened by those answers, and `EQ10`–`EQ12` and `EQ14` remain open with a
standing recommendation. **Owner:** `sparkles:wsi` (`sparkles.wsi.loop`, `sparkles.wsi.events`,
the four backends' pumps). **Consumers in scope:** ordinary GUI applications,
drawing applications that need every sample, and games that need per-frame sums and
raw deltas at device rate. A decision that serves only one of the three is not
accepted here.

## 1. What the code does today

Verified against the tree at the time of writing, not against the milestone summaries:

- Each backend owns an `EventQueue!128`: a fixed ring of `WindowEvent`, 600 bytes
  per slot (`WindowEvent.sizeof`, set by the largest payload in the sum type),
  75 KiB per backend, allocated inline in the backend value.
- `WindowEvent` carries a sequence number, a window id and the payload. There is
  no timestamp.
- `pushCoalesced` keeps only the newest observation of three kinds per window
  (`SurfaceMetricsChanged`, `Moved`, `Exposed`) by scanning the queue's trailing run;
  any other kind anchors the order and stops the scan. Every other kind, pointer
  motion and raw relative motion included, is appended once per native event.
- When the ring is full, `emit` records a sticky `capacity` error. The next
  dispatch reports it as a loop failure and the application's event loop ends.
  This is the failure reported from UAT: `wsi-input-echo --backend x11` with
  confinement and relative motion on, under GNOME/Xwayland, after roughly 74,000
  events, "XCB dispatch/re-arm failed (errno=0 stage=4)".
- The X11 pump drains every event XCB has queued in one call; the Win32 and AppKit
  pumps drain their native queues the same way; the Wayland pump calls
  `wl_display_dispatch_pending`, which by design dispatches everything pending.
- The echo, the only interactive consumer so far, pretty-prints every event, so its
  drain rate is on the order of a thousand events per second.

## 2. Numbers that force the decisions

| Fact                                                                                                   | Consequence                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Gaming mice report at 1,000 to 8,000 Hz; compositors forward relative motion at device rate            | At 8 kHz, 128 slots fill in 16 ms, one frame at 60 Hz. Per-sample raw motion in the queue and once-per-frame draining are incompatible at the current capacity, with no slow consumer involved.                      |
| Linux socket buffers default to about 200 KiB; a Wayland motion event is a few dozen bytes on the wire | One `wl_display_dispatch_pending` can legitimately produce thousands of events, and the pump cannot stop halfway. Backpressure alone cannot bound the Wayland case; something must absorb or merge a whole dispatch. |
| A slot is 600 bytes because the sum type's largest member (owned text) sets it                         | Motion, the high-rate kind, carries roughly 64 bytes of information in a 600-byte slot. Capacity and layout are one decision, not two.                                                                               |
| The consumer is an application callback of unknown cost                                                | Any policy that depends on the consumer's speed (backpressure, drop-on-full) makes behaviour load-dependent; policies keyed to the frame clock are deterministic.                                                    |

## 3. Precedent

What other systems do when a consumer falls behind. Gathered from documentation and
source reading, not measured here; entries marked "as far as known" are unverified.

| System               | Queue bound                                                                | Motion policy                                                                                               | Overflow policy                       |
| -------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Win32                | 10,000 posted messages per thread (`USERPostMessageLimit`)                 | `WM_MOUSEMOVE` synthesized on demand from the current position; `WM_INPUT` queued per sample                | `PostMessage` fails                   |
| macOS window server  | none documented                                                            | mouse-moved and dragged coalesced per app by default, deltas summed (`NSEvent.isMouseCoalescingEnabled`)    | app marked not responding             |
| X11 (Xlib/XCB)       | unbounded client list; server buffers unread output                        | none; XI2 raw events never compressed                                                                       | memory                                |
| Wayland (libwayland) | client unbounded; server output buffer 4 KiB, growable to a cap since 1.23 | none; `relative_motion` at device rate                                                                      | client disconnected                   |
| Android              | per-window batching in `InputDispatcher`                                   | one `MotionEvent` per frame with history (`getHistorySize`)                                                 | ANR after 5 s                         |
| iOS (UIKit)          | none documented                                                            | delivery at display rate; extra digitizer samples via `coalescedTouches(for:)`, plus `predictedTouches`     | watchdog                              |
| Chromium             | unbounded IPC queue                                                        | `pointermove`/`touchmove` aligned to the frame; samples via `getCoalescedEvents()`                          | memory                                |
| GDK                  | unbounded list                                                             | per-frame motion compression on by default (3.12+), history retrievable                                     | memory                                |
| Qt                   | unbounded window-system queue                                              | XI2 motion, touch update and configure compressed (`AA_CompressHighFrequencyEvents`, default on)            | memory                                |
| Java AWT/Swing       | unbounded `EventQueue`                                                     | `Component.coalesceEvents` merges pending `MOUSE_MOVED`/`MOUSE_DRAGGED`, `PAINT`, `UPDATE`                  | memory                                |
| Flutter              | unbounded packet queue                                                     | none by default; optional resampling to frame time                                                          | memory                                |
| Dear ImGui           | unbounded `ImVector`                                                       | duplicates filtered; queue trickled one state change per frame so edges are never lost                      | memory                                |
| SDL 2/3              | 65,535 events                                                              | none                                                                                                        | `SDL_PushEvent` fails                 |
| raylib               | no pointer queue; key and char queues of 16                                | delta is the difference of the last two polled positions                                                    | extra presses dropped silently        |
| Unity Input System   | 1,000 events and 5 MB per update (settings)                                | legacy `Input` polls per-frame accumulated axes                                                             | further events dropped with a warning |
| Godot                | unbounded list                                                             | `use_accumulated_input` on by default: one motion per frame, `relative` summed; off for drawing apps        | memory                                |
| Quake III / ioquake3 | 256-event ring (`MAX_QUED_EVENTS`)                                         | per-sample `SE_MOUSE` deltas, summed per frame by the client                                                | drop oldest, print "overflow"         |
| Unreal Engine        | unbounded deferred message array                                           | `WM_MOUSEMOVE` thinned by the OS; raw input per sample in high-precision mode, summed per frame by gameplay | memory                                |
| Bevy                 | per-frame `Vec`, cleared after two frames                                  | per-sample `MouseMotion`; `AccumulatedMouseMotion` sums per frame (0.15+)                                   | a reader that skips frames loses them |
| GLFW, winit          | none of their own                                                          | callbacks from the native pump                                                                              | the OS queue's policy                 |

The pattern: nobody keeps every motion sample in a small fixed queue. Motion is
summed (Godot, macOS deltas), replaced by the latest (AWT, Win32, raylib) or batched
per frame with the samples attached (Chromium, GDK, Android, iOS). Discrete input is
kept losslessly in a large or unbounded queue. The only small fixed caps shipped
(Quake's 256, raylib's 16) have a lossy, non-fatal overflow policy. None turns
overflow into a dead loop.

## 4. Questions

Each question states the fact that forces it, the options, a recommendation, and its
answer once decided. IDs are stable; answered questions keep their entry with the
decision and the date.

### The contract under overload

**EQ1 — Which currency does each event kind pay in when the consumer cannot keep up?**
There are three: latency (hold events upstream), loss (drop or merge) and memory
(grow). The current fourth answer, a dead loop, is out. The answer may differ by
kind: "never lose a key edge" and "never let motion lag by more than a frame" are
both reasonable and different.
_Options:_ one policy for all kinds; a policy per family (lifecycle, discrete input,
motion, text).
_Recommendation:_ per family. Lifecycle, focus, discrete input and text pay in
latency and, past the cap, memory or a counted drop, never merge. Motion pays in
loss by merging, with history kept aside (EQ5).
**Accepted 2026-09-13:** per family. Lifecycle, focus, discrete input (keys,
buttons, scroll steps) and text never merge — they pay in latency, and past
capacity in the `EQ4` policy. Motion pays in loss by merging, with its samples kept
in the `EQ5` ring.

**EQ2 — What absorbs one whole Wayland dispatch?** `wl_display_dispatch_pending`
cannot be stopped halfway, so backpressure in the pump bounds X11, Win32 and AppKit
but not Wayland, where one dispatch can carry thousands of events.
_Options:_ capacity large enough for a socket buffer's worth; merging so that a
dispatch's motion collapses to a handful of events; both.
_Recommendation:_ both, with merging doing the work and capacity as margin: without
merging no reasonable capacity is safe against an 8 kHz device and a stalled frame.
**Resolved 2026-09-13 by `EQ5` and `EQ9`:** merging collapses a dispatch's motion
to one event per window and pointer, and the `EQ9` layout makes a capacity of
roughly a thousand slots cost what 128 slots cost today. A flood of non-mergeable
events still relies on capacity and the `EQ4` policy, which is now survivable.

**EQ3 — Which of these goes: the cap, per-sample motion in the queue, or
once-per-frame draining?** At 8 kHz the three cannot coexist at 128 slots.
_Recommendation:_ per-sample motion leaves the queue (EQ5 puts samples in a side
ring); the cap and per-frame draining stay.
**Resolved 2026-09-13 by `EQ5`:** per-sample motion leaves the queue for the ring.
The cap and per-drain merging stay.

**EQ4 — What is the overflow policy when everything else fails?**
_Options:_ fatal sticky error (today); drop-oldest with a counter (Quake); drop-newest
(SDL); grow into a heap block allocated at `open`, still allocation-free at dispatch.
Whatever is chosen, how does the consumer observe it: a gap in sequence numbers, an
explicit dropped-count event, a counter read through the backend?
_Recommendation:_ drop-oldest for coalescible kinds and drop-newest for discrete
kinds is too clever; simpler is grow-once at `open` to a configured cap (EQ10) and,
past it, drop-newest with a per-backend counter and one `EventsDropped` notice event
per drain, so a consumer that cares can log or degrade. Never fatal.
**Accepted 2026-09-13:** past capacity the newest event is dropped and a
per-backend counter increments; the drain synthesizes one `EventsDropped` notice
carrying that count before the events it drains, then resets it. The notice is
synthesized rather than queued because a full queue has no slot to give. Overflow
is never fatal and never a sticky error. A pure motion flood cannot reach this path
while its merge partner is still in the queue's trailing run; motion interleaved
with anchoring events can, as can discrete input alone.

### What a motion event is

**EQ5 — Do motion samples live in a side ring per pointer, with the queued event
holding a summary?** This is the Android, iOS, Chromium and GDK shape: one event per
window and pointer in the queue (latest position, summed relative delta, sample
count), and the samples behind it in a separate structure a drawing app can read.
Sub-questions: who owns the ring's lifetime (the backend, per window and pointer);
its depth; and whether drop-oldest is acceptable there.
_Recommendation:_ yes. Ring per (window, pointer) owned by the backend, depth a
compile-time parameter defaulting to a few hundred samples, drop-oldest with a count,
since history is advisory. This is also the SoA move that keeps the 600-byte queue
slot out of the high-rate path: a sample is position, delta, pressure, tilt and a
timestamp, on the order of 48 bytes.
**Accepted 2026-09-13:** yes. One queued event per (window, pointer) carries the
latest position, the summed relative delta and a sample count; the samples
(position, delta, pressure, tilt, timestamp) live in a ring owned by the backend,
keyed by (window, pointer), with a compile-time depth and drop-oldest on overflow,
since history is advisory. This keeps the high-rate path out of the queue slot and
is the SoA half of `EQ9`.

**EQ6 — Do events carry a timestamp, and in which clock?** Resampling, velocity,
gesture recognition and frame alignment need the device timestamp; every platform
supplies one (X server time, Wayland milliseconds and the relative-pointer's
microseconds, `GetMessageTime`, `NSEvent.timestamp`). Today only a sequence exists.
_Recommendation:_ yes, as a prerequisite for EQ5: platform time converted once by
the backend into the loop's monotonic clock, with the raw platform value kept only
where a protocol needs it back (Wayland serials are already handled separately).
**Accepted 2026-09-13** as a prerequisite of `EQ5`: both the queued event and the
ring sample carry a timestamp, converted once by the backend from the platform's
clock (X server time, Wayland's milliseconds and the relative pointer's
microseconds, `GetMessageTime`, `NSEvent.timestamp`) into the loop's monotonic
clock. Without it a consumer cannot align a merged event with the ring. Raw
platform values are kept only where a protocol needs them back; Wayland serials
remain separate.

**EQ7 — When motion merges, which sequence survives, and does the event say how
many samples it stands for?** Strictly increasing sequences are promised today;
contiguity is not.
_Recommendation:_ the merged event keeps the newest sequence and gains a `samples`
count; contiguity is explicitly not promised.
_Reopened 2026-09-13._ Accepting `EQ5` exposed a sub-question the original
recommendation got wrong. Merging by remove-and-append (what `pushCoalesced` does
today) is O(trailing run) per event and keeps drain order strictly increasing;
merging in place — updating the queued event's payload and leaving it where it sits,
as AWT's `coalesceEvents` and Win32's synthesized `WM_MOUSEMOVE` do — is O(1) with a
per-(window, pointer) slot index, but then the merged event either keeps its
original sequence (drain order stays monotonic, the sequence no longer names the
newest observation) or takes the newest one (and drain order stops being
monotonic, breaking a promise consumers can already rely on). Both the cost and the
ordering contract ride on this.

**EQ8 — Does absolute `moved` coalesce by default?** Today it anchors the queue, so
relative events can only merge within the run after the last absolute move, which
ties the relative stream's bound to the absolute rate. GDK and Qt merge moves by
default and expose history.
_Recommendation:_ yes, per (window, pointer), with the samples in the EQ5 ring. The
default is lossy-with-history; a consumer that wants every sample reads the ring.
Presses, releases, enter and leave still anchor, so the last position before a
press is always delivered.
**Accepted 2026-09-13:** yes, per (window, pointer), with the samples in the `EQ5`
ring, so the default is lossy-with-history and a drawing consumer reads the ring.
Presses, releases, enter and leave still anchor the order, so the last position
before a press is always delivered.

### Layout and knobs

**EQ9 — What is the target slot size, and what moves out of line?** Owned text and
composition payloads set the 600 bytes. `DrawOp` went from 656 to 64 bytes by moving
text into an arena paired with the command buffer.
_Recommendation:_ one or two cache lines per slot, with text and composition payloads
in a per-backend arena the drain borrows from (this also answers `WSI-O3`), and touch
and tablet detail in the EQ5 ring. Decide the layout before the cap: 1,024 slots of
64 bytes is the same memory as 128 of 600.
**Accepted 2026-09-13:** one or two cache lines per slot. Owned text and
composition payloads move out of line (which is also the answer to `WSI-O3`), touch
and tablet detail move into the `EQ5` ring, and the cap is decided afterwards:
1,024 slots of 64 bytes is the memory 128 slots of 600 bytes cost today. What
"out of line" does to `WindowEvent`'s Regularity is `EQ14`.

**EQ10 — Which knobs are compile-time and which are runtime?** Candidates: capacity,
history depth, motion coalescing, relative summing, overflow policy. The backends are
large templates, so a policy parameter multiplies instantiations and lane coverage;
per-window runtime switches (GDK's per-window compression, Godot's accumulated input)
cost a branch on a path already doing a sum-type match.
_Recommendation:_ capacity and history depth compile-time (they size inline storage);
coalescing and summing runtime per window, default on; overflow policy fixed by the
spec, not a knob.
**Open; recommendation stands.** Capacity and history depth compile-time, since
they size inline storage; coalescing and relative summing runtime per window,
default on; the `EQ4` overflow policy fixed by this specification rather than
exposed as a knob.

**EQ11 — Where does per-frame accumulation live?** Games should not read the queue.
Something must offer "state since the last frame": pressed set, summed deltas, latest
position.
_Options:_ `sparkles:wsi`; `sparkles:input`; the host in `sparkles:ui-app`.
_Recommendation:_ a small accumulator type in `sparkles:input`, fed by draining the
queue, so `sparkles:wsi` stays the lossless-as-possible boundary and the SDL and
raylib producers can feed the same type.
**Recommendation stands; open pending `EQ10` and `EQ14`.** A small accumulator in
`sparkles:input`, fed by draining the queue, keeps `sparkles:wsi` the
lossless-as-possible boundary and lets the SDL and raylib producers feed the same
type.

**EQ12 — Does coalescing key on the drain or on the frame clock?** Chromium, GDK,
Android and iOS merge per frame, which makes behaviour deterministic instead of
load-dependent. `FrameReady` exists and F04 is pending.
_Recommendation:_ on the drain, for now: the queue cannot assume a frame clock (a
headless or non-rendering consumer has none), and per-drain merging is what the
platforms without a frame clock (AWT, macOS) do. Revisit when F04 lands, as a
consumer-side choice.
**Open; recommendation stands.** Per-drain merging for now, because the queue
cannot assume a frame clock and the platforms without one (AWT, macOS) merge per
delivery. Revisit when `F04` lands, as a consumer-side choice rather than a queue
policy.

**EQ13 — How are touch contacts and tablet detail treated?** Touch floods are per
contact; tablets add pressure and tilt.
_Recommendation:_ the same as the mouse: one queued event per (window, contact)
with the samples in the ring, keyed by pointer id, so a contact is a pointer.
**Resolved 2026-09-13 by `EQ5`'s shape:** a touch contact is a pointer id, so a
contact gets the same treatment as the mouse — one queued event per (window,
contact) with the samples in that pointer's ring. Tablet pressure and tilt are
sample fields, not queue fields.

**EQ14 — Does a queued event still own its text, once text moves out of line?**
`EQ9` moves owned text and composition payloads out of the slot, but
[SPEC.md](./SPEC.md) §7 calls `WindowEvent` a lossless boundary "whose payloads own
their small text and metadata", and the type is Regular: copyable, comparable,
replayable into the recording backend. An arena the drain borrows from breaks that
unless the borrow's validity is stated, and a recorded event that borrows is not
replayable later.
_Options:_ keep short text inline (a commit is usually a few bytes) and spill only
long pre-edit and clipboard metadata to a per-backend arena valid until the next
drain, with the event carrying a span; arena plus reference count, so a kept event
stays valid; keep full ownership and shrink the slot by making the largest payload a
heap-owned buffer, paying an allocation on the rare large commit.
_Recommendation:_ inline-short-with-spill, and state the borrow's lifetime as
"valid until the drain that delivered it returns"; a consumer keeping an event past
that copies it through an explicit deep-copy the recording backend also uses.
_Answer:_ open.

## 5. Dependencies between answers

- `EQ5` required `EQ6` and settled `EQ3` and `EQ13`; `EQ8` rides on `EQ5`; together
  with `EQ9` they settled `EQ2`.
- `EQ7` must be answered before the merge is implemented: it fixes both the cost of
  a merge and whether drained sequences stay strictly increasing.
- `EQ9` precedes any change to the cap, and raises `EQ14`, which fixes what a
  consumer may do with a delivered event.
- `EQ11` is independent of the queue's policy and can land first.
- `EQ12` can be revisited after `F04` without reopening anything above.

## 6. What changes when this is decided

SPEC §4 gains the delivery contract (requirement IDs for capacity, merge rules,
overflow observation and timestamps), §7 gains the sample ring and the timestamp,
and the conformance suite gains a flood property per backend: N native motions
injected faster than the drain must end with the sum of deltas intact, the ring
holding the last `depth` samples, no sticky error, and the drop counter at zero;
a second property overflows discrete input and requires the counter and the notice.
`comparison.md` records the lanes.
