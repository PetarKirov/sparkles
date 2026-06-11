# Design Constraints — What a Windowing Framework Cannot Abstract Away

The synthesis leaf of the [OS-API empirical matrix][matrix]: the hard, measured
constraints that survive every abstraction attempt. Each section states one
constraint, lays out the per-platform evidence (verification tiers as in the
[matrix legend][matrix] — **A[wine]** = under Wine, not Windows; **A[ssh]** = on
`mac-bsn` over SSH, WindowServer-verified but not on-glass), prescribes what a
framework must therefore do, and says where the empirical findings **confirm or
contradict** the framework-level study ([comparison][comparison],
[recommendations][recommendations], and the deep-dive verdicts).

**Last reviewed:** June 11, 2026

---

## 1. Threading: four different contracts, one narrowest portable rule

**The thread-affinity contract is not one rule but a ladder — macOS crashes, Win32
queues, X11 shards per-`Display`, Wayland routes per-queue — and only the strictest
rung is portable.**

| Platform | Contract (measured)                                                                                                                                                                                                                                                                                                                                 | Findings          |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| macOS    | A[ssh] — strictest: window off-main = deterministic `NSInternalInconsistencyException` crash (assert captured verbatim, twice per probe); cross-thread `setNeedsDisplay:` is a **silent no-op**                                                                                                                                                     | [appkit][mac-f17] |
| Win32    | A[wine] — creator-thread **queue affinity**, not main-thread: main saw 0 of 10 messages for a worker-created HWND; two concurrent pumps legal; `SendMessage` blocks on the receiver's _pump_ (400.6 ms vs a 400 ms gap) — mutual send defused by nonqueued processing, send-to-parked-thread **deadlocks**; 100/100 cross-thread `BitBlt` succeeded | [win32][w32-f17]  |
| X11      | A — no main-thread rule; affinity is per-`Display`. The classic no-`XInitThreads` corruption is **extinct on libX11 ≥ 1.8** (ELF-constructor self-arms); two readers on one `Display` serialize and one starves completely                                                                                                                          | [x11][x11-f17]    |
| Wayland  | A — no thread rule at all; per-thread `wl_event_queue` + proxy wrapper is the designed routing model. But a mispaired `read_events` (stolen read intent, reader-count −1) **silently wedges the connection forever**                                                                                                                                | [wayland][wl-f17] |

**What a framework must therefore do.** The narrowest portable contract is: _every
window is owned by one designated thread, and on macOS that thread must be the main
thread_. A framework may relax per platform (multi-pump multi-window on Win32,
fully free-threaded on Wayland) but the relaxation must be capability-queried, not
assumed. Two non-negotiables fall out of the measurements: cross-thread calls must
marshal through a dispatcher (the macOS silent no-op means a missing marshal is
_undetectable_, not just crashy), and the Wayland event-read path must be owned by
exactly one component — exposing raw `prepare_read` to users is handing them the
forever-wedge.

**Versus the framework study.** Confirms [comparison §Dimension 7][comparison]
("GUI = main thread, forced by one platform: AppKit") and [winit][winit]'s
`MainThreadMarker`-plus-`with_any_thread` shape as exactly right. Sharpens it: the
field's uniform main-thread-only rule is _stricter than three of the four OSes
demand_ — only Smithay's no-rule stance and winit's per-platform relaxation match
the measured contracts.

## 2. The modal loop: the pumped loop stops being yours

**On Win32 and macOS, OS-owned modal loops capture the pump, so any redraw driven
solely by "my loop iterated" freezes — Linux has no such loop at all.**

| Platform | Evidence (measured)                                                                                                                                                                                             | Findings          |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Win32    | A[wine] — modal loop entered programmatically: no-fix freeze max tick gap **1.01 s**; with the `SetTimer`-on-`WM_ENTERSIZEMOVE` fix, in-modal ticks at **17 ms**. winewayland swallows `SC_*` entirely          | [win32][w32-f03]  |
| macOS    | A[ssh] — a default-mode timer **starves completely** during tracking/modal modes (0 fires across a 2.0 s gap); the same timer scheduled in `NSRunLoopCommonModes` ticks through nested modes (max gap 109.5 ms) | [appkit][mac-f03] |
| X11      | A — no modal loop exists: ticks held ≤ 17.8 ms through 50-resize storms, bare and WM-mediated                                                                                                                   | [x11][x11-f03]    |
| Wayland  | A — `modal_enter` is unrepresentable; max tick gap 17.06 ms through 12 interactive transitions vs 16.80 ms calm                                                                                                 | [wayland][wl-f03] |

**What a framework must therefore do.** The redraw path must have a delivery
channel that survives loop capture: a `WM_TIMER` re-entry on Win32 and
common-modes (not default-mode) run-loop sources on macOS. Equivalently: the
public frame tick must be specified as "fires even while the OS owns the loop",
which rules out implementing it as "after my `PollEvents` returns".

**Versus the framework study.** Confirms [comparison §Dimension 2][comparison]'s
survey-wide `SetTimer` consensus, now with the freeze quantified (1.01 s → 17 ms).
Adds what the study only implied: the macOS fix is a _different mechanism_
(run-loop mode placement, the [Flutter][comparison] custom-mode trick) — one
"modal loop workaround" abstraction won't compile to both platforms.

## 3. Decorations: a Wayland-only product decision with a measured price

**Only Wayland makes the client responsible for the frame, the responsibility can
arrive uninvited (weston offers no negotiation at all), and getting the geometry
contract wrong is a connection-fatal protocol error.**

| Platform | Evidence (measured)                                                                                                                                                                                                                                                                                                                                                     | Findings          |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — SSD negotiated where offered (sway, tiled and floating); weston has **no decoration protocol** — the client draws or there is no frame. Hand-rolled minimal CSD cost **1061 LOC** vs **295** for the libdecor variant; omitting `set_window_geometry` (`WSI_NO_GEOMETRY=1`) = fatal protocol error, connection killed; move/resize grabs require real input serials | [wayland][wl-f13] |
| X11      | — N/A by design: the WM reparents and draws the frame (hook notes in the Wayland F13 doc)                                                                                                                                                                                                                                                                               | [matrix][matrix]  |
| Win32    | — N/A: DWM owns the frame (custom chrome = `WM_NCCALCSIZE` hooks, out of scope here)                                                                                                                                                                                                                                                                                    | [matrix][matrix]  |
| macOS    | — N/A: `NSWindowStyleMask` owns the frame                                                                                                                                                                                                                                                                                                                               | [matrix][matrix]  |

**What a framework must therefore do.** Carry a CSD path unconditionally on
Wayland and surface the decoration question as an explicit product decision
(SSD-preferred / libdecor / bespoke), never as an internal detail — because the
answer differs per compositor at runtime and can flip mid-session (sway honors a
runtime `set_mode(client_side)` when floating, **silently ignores it** when
tiled). The 3.6× LOC ratio is the empirical argument for libdecor as the default
tier.

**Versus the framework study.** Confirms [comparison §Fork C][comparison]
("prefer libdecor over hand-rolled CSD") and [SDL3][sdl3]'s
SSD-first-with-libdecor-fallback verdict, now with the cost measured. Confirms
consensus #6 ("SSD is only a hint") in its strongest form: on weston the hint
protocol does not even exist. Contradicts nothing — but note [GTK 4][gtk4]'s
KDE-protocol-only binding is exactly the gap our registry probe would expose.

## 4. Keyboard: ownership of sym/text/repeat/compose moves per platform

**No platform delivers the same division of labor between OS and client for
key-identity, text, repeat, and compose — the framework must own a unified state
machine and per-platform fill in what the OS withholds.**

| Platform | Who owns what (measured)                                                                                                                                                                                                                                                                         | Findings          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- |
| Wayland  | A — protocol ships **only evdev codes**; the client owns sym, text, **repeat** (both cancellation paths proven) and compose, via `xkbcommon` (+8 offset) — verified under sway + `wtype`                                                                                                         | [wayland][wl-f06] |
| X11      | A — same `xkbcommon` state machine via xkbcommon-x11; **server owns repeat** (detectable-autorepeat is opt-in); live `setxkbmap` keymap rebuild + client-side compose proven                                                                                                                     | [x11][x11-f06]    |
| Win32    | A[wine] — OS owns text and dead-key compose **only through `TranslateMessage`** (`WM_KEYDOWN`→`WM_CHAR`/`WM_DEADCHAR` chain; skipping it kills text); OS owns repeat. Layout switch under the headless null driver changes the `HKL` but not the tables — de-DE captures queued for real Windows | [win32][w32-f06]  |
| macOS    | A[ssh] — three layers in three places: hardware `keyCode`, layout engine (`UCKeyTranslate` over `uchr`), text layer (`interpretKeyEvents:` → `insertText:`); OS owns repeat (`isARepeat`)                                                                                                        | [appkit][mac-f06] |

**What a framework must therefore do.** The unified key event needs three
independent fields — physical key (scancode/evdev), logical key (layout-resolved
sym), and committed text — plus a repeat flag the framework _synthesizes_ on
Wayland and _translates_ elsewhere. Compose/dead-key state must live in the
framework on Linux and be delegated on Win32/macOS; conflating any two of the
three identities is the bug class the framework study catalogs.

**Versus the framework study.** Confirms [comparison Part 3 consensus #1][comparison]
wholesale (xkbcommon, the `+8` offset, client-side Wayland repeat) — our demos are
the working proof of each clause. Adds a precision the study lacks: on X11 repeat
is the _server's_, so a framework that re-synthesizes repeat everywhere (for
uniformity) must suppress the server's, not stack on top of it.

## 5. Resize: negotiation on Wayland, notification everywhere else — with fatal enforcement

**Wayland resize is a serial-stamped contract the compositor enforces by killing
the connection; the other three platforms merely inform you, each on a different
clock.**

| Platform | Evidence (measured)                                                                                                                                                                                                                                        | Findings          |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — serial-exact `ack_configure` before every matching commit proven; `--violate` ⇒ **fatal `invalid_surface_state`, connection killed**. States arrive as a fresh whole array each configure ([F14][wl-f14]: v1 sees `maximized` where v5 sees `tiled_*`) | [wayland][wl-f02] |
| X11      | A — notify-not-negotiate; **≥ 1 stale frame per resize is structural**; a WM makes `XResizeWindow` deniable                                                                                                                                                | [x11][x11-f02]    |
| Win32    | A[wine] — pure notification: all 14 `SetWindowPos` sizes granted verbatim; pure shrinks invalidate nothing; `WM_SIZING` unreachable programmatically. Fullscreen-as-geometry-idiom **corrupts the placement normal-rect** ([F14][w32-f14])                 | [win32][w32-f02]  |
| macOS    | A[ssh] — app-decided and fully synchronous: `setFrameSize:` → `windowDidResize:` → `drawRect:` in one call stack; pixels = points × 2.0 on all 14 events; live-resize never entered programmatically                                                       | [appkit][mac-f02] |

**What a framework must therefore do.** The frame-lifecycle API must be shaped by
the strictest member: a configure-like event the app **acknowledges by presenting
a buffer of the agreed size**. On Wayland that ack is load-bearing protocol (with
buffer-size coupling the compositor checks); on X11/Win32/macOS it degrades to
"redraw at the new size". An API where `resize` is a property setter and redraw
is independent cannot express the Wayland contract and will ship the
connection-killer as a user-reachable state.

**Versus the framework study.** Confirms [comparison §Dimension 1][comparison]'s
"model the lifecycle as explicit async state" lesson — and escalates it: the
study's evidence was fragility (SDL3's KDE bug tail); ours is a **fatal,
enforced** protocol error, the strongest possible form of the same argument.

## 6. Frame clocks & visibility: four clocks, four throttle behaviors

**There is no portable vsync primitive — the four frame clocks differ in source,
in failure mode, and in what happens when the window is not visible — so the
framework's frame clock must be its own component with per-platform feeders and
a watchdog.**

| Platform | Clock + throttle behavior (measured)                                                                                                                                                  | Findings          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — `wl_surface.frame`: 16.52–16.87 ms over 600 frames (synthetic 60 Hz); **minimized ⇒ callbacks stop dead**, and there is no client-side un-minimize ([F14][wl-f14])                | [wayland][wl-f04] |
| X11      | A — Present is the only real frame clock (ust/msc); **hidden windows never throttle**; Xvfb advertises Present 1.2 with a synthetic 60 Hz                                             | [x11][x11-f04]    |
| Win32    | A[wine] — `DwmFlush` is a **non-blocking `S_OK` stub under Wine** (forced pacing free-runs at p50 522 µs) → the demo's timer fallback carried all 600 frames; no minimized throttling | [win32][w32-f04]  |
| macOS    | A[ssh] — `CADisplayLink` goes **silent under a locked console** despite reporting unpaused/visible; the watchdog fell back to a 16 ms `NSTimer`; real cadence Tier C                  | [appkit][mac-f04] |

**What a framework must therefore do.** `requestRedraw` must be a contract the
framework keeps with its **own** clock, fed by the native vsync source when that
source is alive and by a timer watchdog when it is not — because two of the four
sources were observed dead-while-claiming-alive (Wine's stub, the locked-console
`CADisplayLink`), one stops by design (Wayland minimized — correct power behavior
the framework must surface, not paper over), and one never stops (X11 hidden —
the framework must throttle _itself_ or burn CPU).

**Versus the framework study.** Confirms the [comparison delta-table][comparison]
frame-clock row ("one frame-clock abstraction", `GdkFrameClock`/Slint
`FrameThrottle` as references) and [GTK 4][gtk4]'s freeze-until-frame-callback
verdict. Adds the requirement the study missed: the abstraction needs **liveness
detection**, not just source-folding — no surveyed toolkit documents a watchdog
for a lying vsync source.

## 7. Pointer lock/confine: asymmetric capabilities, asymmetric lifecycles

**Pointer lock is async-and-deniable on Wayland, hand-assembled on X11/Win32, and
confine simply does not exist publicly on macOS — so capture must be a
capability-reported request, not a method that returns `void`.**

| Platform | Evidence (measured)                                                                                                                                                                                                      | Findings          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- |
| Wayland  | A — lock **granted only on surface entry** (async, deniable); oneshot/persistent lifecycles + hint-warp proven; only relative motion flows while locked; deactivation only on focus change (sway)                        | [wayland][wl-f10] |
| X11      | A — lock is assembled from grab+hide+warp (restore exact); `confine_to` modal but **unenforced post-activation** on Xvfb; XFixes barriers are ambient and grab-proof; raw events **double** during the app's own grabs   | [x11][x11-f10]    |
| Win32    | A[wine] — raw `WM_INPUT` + `ClipCursor(1×1)` + `ShowCursor` lock and confine all proven; Wine applies pointer ballistics **before** the raw stream; **focus loss does not clear the clip**                               | [win32][w32-f10]  |
| macOS    | A[ssh] — lock = 3 sync calls, no deny path, **no read-back getter**; warp is silent and fraction-truncating with a 0.25 s event suppression; **no public confine** — warp-back leaks 1 out-of-bounds event per excursion | [appkit][mac-f10] |

**What a framework must therefore do.** Expose `lockPointer()` as an async request
with grant/deny/revoke events (the Wayland shape, the only one that subsumes the
others), and expose `confinePointer()` behind a capability probe that reports
absent on macOS rather than emulating it leakily. Raw-motion delivery must be a
separate stream from accelerated motion, with per-platform dedup (the X11
doubling, the Wine pre-ballistics) handled inside.

**Versus the framework study.** Confirms [GTK 4][gtk4]'s verdict clause "omitting
pointer constraints if any client might be a game" and the
[comparison][comparison] capability-probing pattern (`TryGetFeature`-style) as the
right escape shape. Sharpens it: macOS confine is not "unimplemented", it is
**unimplementable** with public API — a framework that promises uniform confine is
lying on one platform.

## 8. IME: a separate stateful channel, gated differently everywhere

**Text input is not a key-event refinement but a second, stateful channel whose
enable gate, event ordering, and lifetime rules differ per platform — and whose
omission or interleaving bugs are unfixable above the windowing layer.**

| Platform | Evidence (measured)                                                                                                                                                                                                  | Findings          |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — full CJK round-trip headless (sway + fcitx5-pinyin): `zwp_text_input_v3` preedit → `commit_string "你好"`; **serial discipline** (one `commit` per `done`) proven; weston is v1-only                             | [wayland][wl-f07] |
| X11      | A — XIM end-to-end incl. headless fcitx5 pinyin commit, destroy/restart callbacks, on-the-spot preedit deltas; the **`XFilterEvent` gate is total** — skip it and composition never happens                          | [x11][x11-f07]    |
| Win32    | A[wine] — IMM32 choreography fully verified headless (`SCS_SETSTR` echoes real `WM_IME_*`); **TSF COM bring-up all-`S_OK` but blocked at `ITextStoreACP`** — the wall every toolkit hit                              | [win32][w32-f07]  |
| macOS    | A[ssh] — full `NSTextInputClient` (added via runtime `class_addProtocol`) flips composition on: option-e + e ⇒ `setMarkedText:"´"` → `insertText:"é"`; Esc commits-then-cancels; **focus loss orphans the pre-edit** | [appkit][mac-f07] |

**What a framework must therefore do.** Model text input as an explicitly
enabled, per-window stateful channel (enable/disable, preedit-with-styling,
commit, delete-surrounding) that the framework — not the app — wires to the four
native contracts, because each has a non-optional structural obligation: the X11
filter gate sits _inside_ the event pump, the Wayland serial discipline sits
_inside_ protocol dispatch, the macOS protocol must be on the view receiving
keys, and key events must be suppressed/reordered around composition. The
focus-loss-orphans-preedit and Esc-ordering findings mean preedit lifetime needs
explicit cancel events in the API.

**Versus the framework study.** Confirms [comparison §Dimension 3][comparison]'s
two findings — IME is frequently punted, and **nobody ships TSF** — and our TSF
probe explains _why_ empirically: everything up to `ITextStoreACP` is cheap, the
document-model interface is the cliff. Confirms the study's "own the consumer"
prescription ([winit][winit]/[SDL3][sdl3] verdicts) with working evidence that
all four consumers are implementable in a few hundred lines each.

## 9. Popups: compositor-placed vs app-math — the positioner argument

**Wayland places popups and dismisses them for you (uncapturably); the other three
make the app do all placement math and hold fragile grabs — only a
positioner-style declarative API maps onto both.**

| Platform | Evidence (measured)                                                                                                                                                                                                       | Findings          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — positioner solved **compositor-side** (sway flips, not slides, at edges); outside click is **uncapturable** — the client only gets `popup_done`, topmost-first; a stale grab serial is **silently granted grab-less** | [wayland][wl-f15] |
| X11      | A — popup = override-redirect + **session-global grab that starves all other clients**; placement and dismissal 100 % app-side; one grab serves the whole submenu chain                                                   | [x11][x11-f15]    |
| Win32    | A[wine] — `WS_POPUP` + `SetCapture`; one capture slot + screen-coord hit-testing serves the chain; **`WM_CAPTURECHANGED` is the silent grab-breaker**; popups may exceed output bounds                                    | [win32][w32-f15]  |
| macOS    | A[ssh] — borderless window at level 101; placement/clamping 100 % app math (off-screen frames accepted verbatim); local monitor sees only queued events; Esc arrives via `cancelOperation:`                               | [appkit][mac-f15] |

**What a framework must therefore do.** The popup API must be declarative —
anchor rect + gravity + constraint-adjustment, i.e. `xdg_positioner`'s vocabulary
— with the framework computing geometry on X11/Win32/macOS and delegating on
Wayland; and dismissal must be a framework-delivered event (`popup_done`-shaped),
because on Wayland the app _cannot_ observe the outside click and on the others
the grab can be broken silently (`WM_CAPTURECHANGED`, grab steals). "Place this
window at (x, y) and watch clicks yourself" is implementable on exactly three of
four platforms.

**Versus the framework study.** Confirms [comparison §Dimension 6][comparison]
("a popup abstraction cannot be a simple place-at-(x,y) call") and the
[winit][winit] verdict's self-identified gap — winit's punt pushes an obligation
onto consumers that our Wayland findings show consumers cannot even discharge
(the dismiss event only exists protocol-side). The positioner-style resolution
the study inferred from SDL3/Smithay is the one the measurements force.

## 10. Clipboard & DnD: three transfer models, one shared trap

**Clipboard is a negotiated async transfer everywhere, but the ownership model —
unified selection machinery (Linux), transactional with delayed rendering
(Win32), versioned polling (macOS) — and its coupling to input state cannot be
unified into a synchronous `getText()/setText()`.**

| Platform | Evidence (measured)                                                                                                                                                                                         | Findings          |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — clipboard and DnD share one `data_source`/offer pipe-fd machinery; **`set_selection` is dead without a real input serial — silently ignored**; DnD action resolved compositor-side                      | [wayland][wl-f16] |
| X11      | A — clipboard and XDND are **one selection mechanism**; `INCR` chunking proven both directions; full XDND v5 source + target by hand; **delayed rendering is the only mode**                                | [x11][x11-f16]    |
| Win32    | A[wine] — delayed rendering timed (`WM_RENDERFORMAT` only on demand); OLE DnD fully headless (hand-rolled COM to `DRAGDROP_S_DROP`); host bridging two-way on winex11, **absent on winewayland**            | [win32][w32-f16]  |
| macOS    | A[ssh] — eager + lazy `NSPasteboard`; **`changeCount` polling is the only change signal**; promises die with the source; reading `changeCount` inside the ownership callback **recurses to stack overflow** | [appkit][mac-f16] |

**What a framework must therefore do.** The data-transfer API must be: (a)
provider-based — the app registers a typed render-on-demand source, never pushes
bytes eagerly (delayed rendering is mandatory on X11, the default idiom on
Win32/Wayland); (b) async on the read side (pipe-fd / `INCR` / promises all
stream); (c) **coupled to input events on Wayland** — `setClipboard` must accept
or capture the triggering event's serial, or it silently does nothing; and (d)
change-notification must be abstracted as "may be poll-based" (macOS has no push
signal). DnD source and target ride the same machinery on Linux and should share
the provider type.

**Versus the framework study.** Confirms [comparison §Dimension 8][comparison]
(async MIME-typed transfer; [GTK 4][gtk4]'s clipboard as the model; drag-source
as the field's weakest corner — our hand-rolled XDND/OLE sources show it is
laborious but bounded). Adds the input-serial coupling, which no deep-dive
surfaced as an API-shape constraint: it makes "clipboard write" an
_event-context_ operation on Wayland, a genuinely new requirement for the API.

## 11. Loop wakeup: the loop must be composable with external fds

**Cross-thread wakeup is cheap everywhere, but the mechanisms are disjoint — a
client fd on Wayland (no protocol-level user event exists), `ClientMessage` or fd
on X11, the message queue (with a 63-handle ceiling on the wait) on Win32,
run-loop sources on macOS — so loop integration, not wakeup, is the real API.**

| Platform | Evidence (measured)                                                                                                                                                       | Findings          |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — no protocol-level user event; wakeup must be a client fd; eventfd median **11 µs** via the `prepare_read`/`poll` loop                                                 | [wayland][wl-f05] |
| X11      | A — native user event exists (`ClientMessage`, p50 **71 µs**, full server round-trip) but fd-readiness is trivial and 4× faster (eventfd p50 **17 µs**)                   | [x11][x11-f05]    |
| Win32    | A[wine] — `PostMessageW`/`PostThreadMessageW` both verified; the "add an arbitrary handle" story is `MsgWaitForMultipleObjectsEx` with its **63-handle ceiling** (probed) | [win32][w32-f05]  |
| macOS    | A[ssh] — three lanes verified: `postEvent:atStart:`, a signalled version-0 `CFRunLoopSource`, and a `pipe(2)` via `CFFileDescriptor`                                      | [appkit][mac-f05] |

**What a framework must therefore do.** Offer a `wake()` (any-thread, coalesced)
and an external-source registration that is fd-shaped on Linux and source-shaped
on Apple/Win32 — and on Win32 multiplex registered handles itself (the 63-handle
ceiling means user handles cannot map 1:1 onto the OS wait).

**Versus the framework study.** Confirms [comparison §Fork A][comparison]'s
resolution — the external-fd integration point ([winit][winit]'s `calloop`/`AsFd`
story) is the load-bearing requirement, and its absence in GLFW/SDL3 the recorded
gap. The 11–71 µs measurements show the cost argument is a non-issue; the design
argument is everything.

## 12. Scale is late-bound: the first frame is at the wrong scale by design

**On Wayland the first commit is always at scale 1 and the real scale arrives
post-map; on Win32 awareness is write-once-per-process; X11 has no live channel
at all — so scale must be a revisable event in the API, not a creation-time
constant.**

| Platform | Evidence (measured)                                                                                                                                                                                                                            | Findings          |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — both integer and fractional paths in one binary; live fractional rescale + cross-scale output move on sway; **first commit is always at scale 1 — post-map rescale guaranteed**                                                            | [wayland][wl-f08] |
| X11      | A — absence proven live: `Xft.dpi` 96→144→192 and `xrandr --dpi` deliver **nothing** to the window; the only live channel is an opt-in root `PropertyNotify` on `RESOURCE_MANAGER` (convention, not protocol)                                  | [x11][x11-f08]    |
| Win32    | A[wine] — PMv2 surface complete; awareness is **write-once** (second set ⇒ `err=5`), thread granularity, virtualization captured; under winewayland `WM_DPICHANGED` is structurally unreachable — scale arrives as a plain `WM_SIZE` at DPI 96 | [win32][w32-f08]  |
| macOS    | A[ssh] — all scale sources agree (2.0); `convertRectToBacking:` exact incl. fractional; **wrong-scale buffers fail silently** (no error, just blur); headless `drawRect:` CTM is identity — rasterization Tier C                               | [appkit][mac-f08] |

**What a framework must therefore do.** Treat scale as an event stream with a
guaranteed initial delivery _after_ the surface maps, and require render-target
sizing off the physical/buffer size, never the logical size. Process-level
prerequisites (Win32 PMv2 manifest/early `SetProcessDpiAwarenessContext`) must be
handled at init because they are unfixable later (write-once). On X11 the
framework must volunteer the `RESOURCE_MANAGER` listener — no app will.

**Versus the framework study.** Partially **contradicts** the study's cleanest
prescription: [comparison §Dimension 5][comparison] holds up Slint's "learn the
scale before first paint" as the cure, but on Wayland that is _impossible_ — the
first configure cannot carry the real scale and a post-map rescale is guaranteed.
[Winit][winit]'s `surface_size_writer` (make the post-hoc rescale first-class and
cheap) matches the measured reality better than learn-it-early does.

## 13. Output topology: enumeration is portable, change notification is not

**Every platform enumerates monitors, but who answers "which output am I on" and
whether change arrives by event or by polling differs — and on one verified stack
the notification simply never fires.**

| Platform | Evidence (measured)                                                                                                                                                                                              | Findings          |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| Wayland  | A — `wl_output` v4 + xdg-output logical/physical split; live hot-add/remove + vanishing-occupied-output captured; **occupancy (`surface.enter/leave`) trails configures by ~200 ms**                             | [wayland][wl-f09] |
| X11      | A — RandR 1.5 monitors vs 1.2 wiring objects **disagree on physical mm**; occupancy is app-derived; off-screen windows learn nothing                                                                             | [x11][x11-f09]    |
| Win32    | A[wine] — live hotplug captured (~1 s to `\\.\DISPLAY2`) but Wine fires **none of the three notify messages — only polling caught it**; `rcMonitor` all at +0+0 under winewayland                                | [win32][w32-f09]  |
| macOS    | A[ssh] — dual enumeration (NSScreen + CG) bridged via `NSScreenNumber`; `window.screen` answers occupancy directly; a locked session empties only the CG _active_ list; `CGDisplayPixelsWide` returns **points** | [appkit][mac-f09] |

**What a framework must therefore do.** Maintain its own output model updated by
events where they exist and by a low-frequency poll where they provably don't
(A[wine] caveat: the missing notifications are a Wine gap — real-Windows behavior
queued); report window-to-output occupancy as eventually-consistent (the 200 ms
Wayland lag, the X11 derive-it-yourself); and never expose two contradictory
physical-size answers (pick the RandR 1.5 / logical view and say so).

**Versus the framework study.** The study barely touches output topology beyond
DPI migration — this constraint is empirical surplus. It reinforces the
[comparison][comparison] capability-probe ethos: "monitor change events" is
itself a capability that one verified stack lacks.

---

## Constraint summary

| #   | Constraint                                           | Binding platform (why)                                                     | Framework consequence                                                                                    |
| --- | ---------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| 1   | Thread-affinity ladder                               | macOS (off-main = crash; cross-thread call = silent no-op)                 | One owner thread per window, main on macOS; dispatcher marshalling; relax per-platform via capability    |
| 2   | OS-owned modal loops capture the pump                | Win32 (1.01 s freeze) + macOS (default-mode starvation)                    | Frame tick must survive loop capture (`SetTimer` / common-modes sources), never "after my poll returns"  |
| 3   | Client may own the frame; geometry contract is fatal | Wayland (weston: no SSD protocol; geometry violation = disconnect)         | Unconditional CSD path, libdecor default (295 vs 1061 LOC), decoration mode surfaced as product decision |
| 4   | Key sym/text/repeat/compose ownership moves          | Wayland (client owns all) vs Win32/macOS (OS owns text+repeat)             | Three-identity key event; framework-synthesized repeat on Wayland, suppressed-server-repeat on X11       |
| 5   | Resize is a negotiation with fatal enforcement       | Wayland (`ack_configure` serial-exact or connection killed)                | Configure→ack-by-presenting frame lifecycle; size and buffer coupled in the API                          |
| 6   | Four frame clocks, four throttle behaviors           | All four differently (stops dead / never stops / stub / silent)            | Own frame-clock component: native feeder + liveness watchdog + self-throttle                             |
| 7   | Pointer lock/confine asymmetry                       | macOS (no public confine) + Wayland (async-deniable lock)                  | `lockPointer` as async request with grant/deny/revoke; confine behind a capability probe                 |
| 8   | IME is a separate stateful channel                   | All four (filter gate / serials / `ITextStoreACP` wall / view protocol)    | Framework owns all four IME consumers; explicit preedit lifetime incl. cancel                            |
| 9   | Popup placement/dismissal ownership splits           | Wayland (compositor places; outside click uncapturable)                    | Declarative positioner API + framework-delivered dismiss event; never "place at (x,y)"                   |
| 10  | Three clipboard models, input-serial coupling        | Wayland (`set_selection` silently dead without serial) + macOS (poll-only) | Provider-based render-on-demand transfer; event-context writes; poll-tolerant change signal              |
| 11  | Wakeup ≠ loop integration                            | Wayland (no protocol user event) + Win32 (63-handle ceiling)               | Any-thread coalesced `wake()` + external-source registration; framework multiplexes Win32 handles        |
| 12  | Scale is late-bound                                  | Wayland (first commit always scale 1) + Win32 (write-once PMv2)            | Scale as revisable event with guaranteed post-map delivery; size targets off physical size               |
| 13  | Output change notification is not portable           | Win32/Wine (zero notify messages fired — polling only)                     | Framework-owned output model; events where real, poll fallback; occupancy eventually-consistent          |

The contradiction worth flagging upward: the framework study's "learn the scale
before first paint" ([comparison §Dimension 5][comparison], via Slint) is
unimplementable on Wayland as measured (constraint 12) — the prescription should
be [winit][winit]'s shape instead: make the guaranteed post-map rescale
first-class and cheap. Everything else in [comparison][comparison] Part 3/4 and
the [recommendations][recommendations] plan is confirmed, mostly with sharper
teeth (fatal enforcement, measured freezes, LOC prices) than the study could
claim from source-reading alone.

<!-- References -->

[matrix]: ./feature-matrix.md
[comparison]: ../comparison.md
[recommendations]: ../recommendations.md
[winit]: ../winit.md
[sdl3]: ../sdl3.md
[gtk4]: ../gtk4.md
[wl-f02]: ./wayland/f02-resize.md
[wl-f03]: ./wayland/f03-modal-loop.md
[wl-f04]: ./wayland/f04-frame-pacing.md
[wl-f05]: ./wayland/f05-loop-wakeup.md
[wl-f06]: ./wayland/f06-keyboard.md
[wl-f07]: ./wayland/f07-text-input.md
[wl-f08]: ./wayland/f08-dpi-scaling.md
[wl-f09]: ./wayland/f09-outputs.md
[wl-f10]: ./wayland/f10-pointer-capture.md
[wl-f13]: ./wayland/f13-decorations.md
[wl-f14]: ./wayland/f14-window-state.md
[wl-f15]: ./wayland/f15-popup.md
[wl-f16]: ./wayland/f16-clipboard-dnd.md
[wl-f17]: ./wayland/f17-threading.md
[x11-f02]: ./x11/f02-resize.md
[x11-f03]: ./x11/f03-modal-loop.md
[x11-f04]: ./x11/f04-frame-pacing.md
[x11-f05]: ./x11/f05-loop-wakeup.md
[x11-f06]: ./x11/f06-keyboard.md
[x11-f07]: ./x11/f07-text-input.md
[x11-f08]: ./x11/f08-dpi-scaling.md
[x11-f09]: ./x11/f09-outputs.md
[x11-f10]: ./x11/f10-pointer-capture.md
[x11-f15]: ./x11/f15-popup.md
[x11-f16]: ./x11/f16-clipboard-dnd.md
[x11-f17]: ./x11/f17-threading.md
[w32-f02]: ./win32/f02-resize.md
[w32-f03]: ./win32/f03-modal-loop.md
[w32-f04]: ./win32/f04-frame-pacing.md
[w32-f05]: ./win32/f05-loop-wakeup.md
[w32-f06]: ./win32/f06-keyboard.md
[w32-f07]: ./win32/f07-text-input.md
[w32-f08]: ./win32/f08-dpi-scaling.md
[w32-f09]: ./win32/f09-outputs.md
[w32-f10]: ./win32/f10-pointer-capture.md
[w32-f14]: ./win32/f14-window-state.md
[w32-f15]: ./win32/f15-popup.md
[w32-f16]: ./win32/f16-clipboard-dnd.md
[w32-f17]: ./win32/f17-threading.md
[mac-f02]: ./appkit/f02-resize.md
[mac-f03]: ./appkit/f03-modal-loop.md
[mac-f04]: ./appkit/f04-frame-pacing.md
[mac-f05]: ./appkit/f05-loop-wakeup.md
[mac-f06]: ./appkit/f06-keyboard.md
[mac-f07]: ./appkit/f07-text-input.md
[mac-f08]: ./appkit/f08-dpi-scaling.md
[mac-f09]: ./appkit/f09-outputs.md
[mac-f10]: ./appkit/f10-pointer-capture.md
[mac-f15]: ./appkit/f15-popup.md
[mac-f16]: ./appkit/f16-clipboard-dnd.md
[mac-f17]: ./appkit/f17-threading.md
