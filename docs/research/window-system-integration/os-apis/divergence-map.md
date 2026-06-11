# Divergence Map — What the Four Platforms Agree On, and Where They Fork

The capstone of the os-apis empirical phase: 17 features × 4 platforms
(Wayland, X11, Win32, AppKit), every cell demoed, measured, and written up. The
[feature matrix][matrix] holds the per-cell one-liners; this document re-cuts the same
evidence **per feature** into the three questions a windowing framework's designer
actually asks: _what consensus can the portable layer rely on?_ — _where exactly do the
platforms fork?_ — _what does that fork force on the framework's architecture?_ It ends
with a [severity table](#divergence-severity-table) that prioritizes the design work.
The toolkit-survey companion is [`../comparison.md`][comparison] (how fifteen existing
toolkits resolved these same forks); this map is the OS-level ground truth underneath it.

**Last reviewed:** June 11, 2026

> [!NOTE]
> Every claim below traces to a per-platform findings doc (linked per cell). Verification
> tiers carry over from the [matrix][matrix]: Wayland and X11 rows are Tier A (headless
> weston/sway/Xvfb), Win32 rows are `A[wine]` (Wine 10.0 is a reimplementation, not
> Windows), AppKit rows are `A[ssh]` (real macOS hardware over SSH; on-screen compositing
> unverified). Wine-divergence and locked-console caveats are flagged inline where they
> matter.

---

## How to read this map, and the patterns that recur

Three mega-patterns emerged from the data — they explain most of the per-feature forks
and are worth internalizing before reading any row:

1. **Notification vs negotiation.** Wayland's contracts are first-class and _enforced_:
   resize requires a serial-exact `ack_configure` and a violation kills the connection
   ([wayland F02][wl-f02]); skipping `set_window_geometry` under CSD is a fatal protocol
   error ([wayland F13][wl-f13]); `set_selection` without a real input serial is silently
   dead ([wayland F16][wl-f16]). The other three _notify_ after the fact (X11
   `ConfigureNotify` [x11 F02][x11-f02], Win32 `WM_SIZE` [win32 F02][w32-f02], AppKit
   `windowDidResize:` [appkit F02][mac-f02]) and trust the app. A portable layer must be
   shaped around the strictest member: model these flows as negotiations with acknowledged
   state, and let the notify platforms degenerate into trivial acks.

2. **Who owns the loop.** Win32 and AppKit can _take the loop away_ — the size/move modal
   loop freezes a main-loop animation for up to 1.01 s ([win32 F03][w32-f03]) and a
   default-mode `NSTimer` starves completely during tracking/modal run-loop modes
   ([appkit F03][mac-f03]) — while Wayland and X11 are flat fd-pumps where no such state
   exists ([wayland F03][wl-f03], [x11 F03][x11-f03]). Symmetrically, the fd platforms make
   _you_ own integration (no protocol-level user event on Wayland — [wayland F05][wl-f05])
   while the loop-owning platforms give you posting primitives (`PostMessage`
   [win32 F05][w32-f05], `postEvent:` [appkit F05][mac-f05]). A framework needs both: a
   render path that survives loop theft, and a wakeup abstraction over fd-vs-message.

3. **The outlier rotates.** X11/Win32/AppKit usually cluster and Wayland is the outlier
   (resize negotiation, client-owned key repeat, compositor-side popup placement,
   compositor-resolved DnD actions, mandatory CSD capability) — but not always: on
   threading **AppKit** is the lone hard-liner (off-main window = deterministic crash,
   [appkit F17][mac-f17], vs _no_ main-thread rule at all on Wayland/X11
   [wl F17][wl-f17]/[x11 F17][x11-f17]); on the modal loop **Win32/AppKit** fork from
   **Wayland/X11**; on close-veto **Win32/AppKit** have it first-class while
   **Wayland/X11** spell it "ignore the message" ([F14](#f14--window-state--vetoable-close)).
   No single platform can be "the weird one" in the portability layer — each feature has
   its own strictest member, and that member sets the abstraction's shape.

A fourth, smaller refrain: **first-class vs hand-assembled.** Pointer lock is one protocol
request on Wayland but a 3-call assembly on the other three; a popup grab is one request
on Wayland, a session grab on X11, a capture slot on Win32, and pure event-monitor
emulation on AppKit. Where a capability is assembled, its failure modes are assembled too
— and those (capture theft, focus-loss leaks, warp suppression) are what the findings docs
measured.

---

## F01 — First pixel & init cost

**Where the four agree.** Every platform reaches a confirmed software pixel through the
same conceptual ladder — connect, window/surface object, pixel buffer, present — in
roughly 9–11 distinct concepts and a few hundred LOC, and the dominant cost is never CPU
work but a platform-specific synchronization point ([wl F01][wl-f01], [x11 F01][x11-f01],
[w32 F01][w32-f01], [mac F01][mac-f01]).

**Where they fork** — what you wait on:

| Platform | Bottleneck                                                                            | Measured                                                          |
| -------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Wayland  | the frame clock (2 round-trips, then first `frame` callback)                          | ~2.2 ms client work, 11–19 ms to pixel ([wl F01][wl-f01])         |
| X11      | five blocking round-trips; "presented" unprovable without Present; a WM adds ~3 ms    | ~1.4 ms total client path ([x11 F01][x11-f01])                    |
| Win32    | one-time session connect inside the first cursor/window call; **0** round-trips after | 23.8 ms to first `BitBlt`, 13.1 ms = connect ([w32 F01][w32-f01]) |
| AppKit   | three first-WindowServer-contact calls; cold-vs-warm dominates everything else        | 130 ms cold → 100 ms warm ([mac F01][mac-f01])                    |

Also: first `WM_SIZE` arrives _inside_ `CreateWindowExW` iff `WS_VISIBLE`
([w32 F01][w32-f01]) — callbacks can fire before the creation call returns.

**What the fork forces.** Init cost is not a portability problem, but two facts are:
the framework's window-creation API must tolerate **synchronous callback re-entry during
creation** (Win32), and "first frame is visible" needs a per-platform definition because
X11 cannot even express it without an extension.

## F02 — Resize

**Where the four agree.** A resize ultimately arrives as an event carrying a size, the
app reallocates a buffer, and a storm of programmatic resizes settles without loss on all
four. That is the entire consensus.

**Where they fork:**

- **Wayland — negotiation.** Serial-exact `ack_configure` before every matching commit is
  mandatory; committing a wrong-size buffer while maximized is a fatal
  `invalid_surface_state` that kills the connection ([wl F02][wl-f02]).
- **X11 — notify, deniable.** `ConfigureNotify` after the fact; ≥1 stale frame per resize
  is structural; with a WM, `XResizeWindow` is merely a request the WM may deny
  ([x11 F02][x11-f02]).
- **Win32 — notify, granted.** All 14 `SetWindowPos` sizes granted verbatim; pure shrinks
  invalidate nothing (the stale-shrink artifact); the interactive `WM_SIZING` path is
  unreachable programmatically ([w32 F02][w32-f02]).
- **AppKit — app-decided, synchronous.** `setFrameSize:` → `windowDidResize:` →
  `drawRect:` in one call chain, in **points**; `pixels = points × scale` held on all 14
  events ([mac F02][mac-f02]).

**What the fork forces.** Resize must be modeled as **negotiation, not notification**,
because Wayland: the portable contract is "here is a proposed size + serial; you must
commit a matching buffer and ack" — on X11/Win32/AppKit the ack is a no-op. And the
framework must repaint on shrink itself (Win32 invalidates nothing) and keep logical
units separate from buffer units (AppKit speaks points, Wayland speaks both).

## F03 — Modal-loop survival

**Where the four agree.** A ~2 Hz animation _can_ be kept alive through every
state-transition storm on all four platforms — but only because two of them need a
documented countermeasure.

**Where they fork.** Wayland and X11 simply have no modal loop: max tick gap 17.06 ms
through 12 transitions ([wl F03][wl-f03]), ≤17.8 ms through 50-resize storms
([x11 F03][x11-f03]). Win32's size/move modal loop freezes the main loop for up to
**1.01 s**; the `SetTimer`-on-`WM_ENTERSIZEMOVE` countermeasure restores 17 ms in-modal
ticks ([w32 F03][w32-f03]). AppKit's equivalent is run-loop _modes_: a
common-modes timer ticks through nested tracking/modal modes (max gap 109.5 ms) while a
default-mode timer fires **zero** times in 2.0 s ([mac F03][mac-f03]).

**What the fork forces.** The framework's redraw driver cannot live in the main loop
body. It must be a callback the platform re-enters (timer in common modes / `WM_TIMER`
armed on `WM_ENTERSIZEMOVE`), because on two platforms the main loop is not yours during
interaction. This is the strongest argument for a callback-shaped, not poll-shaped,
portable render hook (cf. [comparison Fork A][comparison]).

## F04 — Frame pacing

**Where the four agree.** Every platform nominally offers a "draw now" clock near the
display refresh — and on every platform that clock **can stop or lie**, so none of the
four demos could trust it unconditioned.

**Where they fork:**

| Platform | Native clock                | Measured failure mode                                                                                                      |
| -------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Wayland  | `wl_surface.frame`          | tight 16.5–16.9 ms over 600 frames; minimize ⇒ callbacks **stop dead** ([wl F04][wl-f04])                                  |
| X11      | Present extension only      | core X11 has no frame clock; hidden windows never throttle; Xvfb advertises Present 1.2 ([x11 F04][x11-f04])               |
| Win32    | `DwmFlush`                  | a non-blocking `S_OK` stub under Wine — pacing free-runs at p50 522 µs; timer fallback required ([w32 F04][w32-f04])       |
| AppKit   | `CADisplayLink` (macOS 14+) | silent under a locked console despite unpaused/visible state; watchdog fell back to a 16 ms `NSTimer` ([mac F04][mac-f04]) |

**What the fork forces.** The redraw loop needs an **independent watchdog clock**: the
native pacer can vanish (minimize on Wayland), never exist (core X11), succeed-without-
pacing (Wine `DwmFlush`), or go silent while claiming to be live (locked-console
`CADisplayLink`). The portable API should be "request a frame callback, with a timeout
fallback," never "block on vsync."

## F05 — Loop wakeup & external fds

**Where the four agree.** A second thread can wake the native loop on all four, cheaply
(median 11 µs–506 µs), and arbitrary external event sources can join the same wait — no
platform forces a second wait primitive or polling.

**Where they fork.** The mechanism and its ceiling differ everywhere: Wayland has **no
protocol-level user event** — the wakeup must be a client fd in the app-owned
`prepare_read`/`poll` loop (eventfd median 11 µs, [wl F05][wl-f05]). X11 has a native
`ClientMessage` (p50 71 µs, a full server round-trip) but a trivial fd path is 4× faster
([x11 F05][x11-f05]). Win32 posts to a queue (`PostMessageW` p50 60 µs;
`PostThreadMessageW` p50 506 µs) and its "add an fd" story is
`MsgWaitForMultipleObjectsEx` with a hard **63-handle ceiling** ([w32 F05][w32-f05]).
AppKit offers three in-process mechanisms (`postEvent:` 319 µs, `CFRunLoopSource` 398 µs,
`CFFileDescriptor` fd 72 µs median) ([mac F05][mac-f05]).

**What the fork forces.** Wrappable: one `Waker` abstraction (fd on Wayland/X11/AppKit,
posted message on Win32) covers it. The 63-handle Win32 ceiling means "register an OS
handle with the loop" cannot be an unbounded public API — multiplex internally.

## F06 — Keyboard & keymap

**Where the four agree.** Scancode → keysym → text is a three-level pipeline on all four,
text is a separate question from keys (dead-key compose exists everywhere), and layouts
can change at runtime under a live window.

**Where they fork** — who owns each level:

- **Wayland:** protocol ships only evdev codes; the **client** owns sym, text, compose,
  and key repeat (both repeat cancellations are client obligations) via `libxkbcommon`
  ([wl F06][wl-f06]).
- **X11:** the same `xkbcommon` state machine client-side, but the **server** owns repeat
  (detectable auto-repeat is an opt-in); live `setxkbmap` requires a client keymap rebuild
  ([x11 F06][x11-f06]).
- **Win32:** the system owns repeat and translation order
  (`WM_KEYDOWN` → `TranslateMessage` → `WM_CHAR`/`WM_DEADCHAR`); astral text arrives as
  **two** `WM_CHAR`s (UTF-16 surrogates); the `LoadKeyboardLayoutW` switch is a lie under
  Wine's headless null driver ([w32 F06][w32-f06]).
- **AppKit:** three distinct APIs for the three levels (`keyCode`, `UCKeyTranslate`,
  `interpretKeyEvents:` → `insertText:`); the layout engine composes dead keys but the
  synthetic-event chain does not ([mac F06][mac-f06]).

**What the fork forces.** Wrappable, with one structural decision: the framework must
implement **client-side key repeat** (timer-driven, with focus-loss and key-up
cancellation) because Wayland provides none — and then must _disable_ it where the system
repeats for you. Keysym/text must be separate event fields everywhere.

## F07 — IME / text input

**Where the four agree.** All four converge on the same composition state machine:
start → pre-edit updates (styled, caret-positioned) → commit-or-cancel, with the app
rendering pre-edit inline and reporting caret rectangles back to the IME. All four were
driven to a real composed commit (你好 / é) in the demos.

**Where they fork** — the protocol carrying that state machine:

| Platform | Protocol                 | Sharpest measured edge                                                                                                           |
| -------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Wayland  | `zwp_text_input_v3`      | double-buffered serial discipline; weston is v1-only — protocol availability varies ([wl F07][wl-f07])                           |
| X11      | XIM                      | the `XFilterEvent` gate is **total** — every event must pass through it ([x11 F07][x11-f07])                                     |
| Win32    | IMM32 (TSF half-blocked) | full `WM_IME_*` choreography; TSF needs an `ITextStoreACP` implementation ([w32 F07][w32-f07])                                   |
| AppKit   | `NSTextInputClient`      | implementing the protocol _flips composition on_; Esc commits-then-cancels; focus loss orphans the pre-edit ([mac F07][mac-f07]) |

**What the fork forces.** Architecture-forcing for the text stack: the IME hook must sit
**inside the event loop** (X11's filter gate, AppKit's `interpretKeyEvents:`) and the
text widget model must natively represent marked/pre-edit text with attributes — it
cannot be bolted onto a plain "key + char" event stream. Focus-loss pre-edit policy
(commit? discard?) differs and must be an explicit framework decision.

## F08 — DPI / runtime rescale

**Where the four agree.** Rendering at the right scale is the app's job everywhere; a
wrong-scale buffer fails _silently_ (blurry or mis-sized, never an error —
[mac F08][mac-f08], [wl F08][wl-f08]).

**Where they fork:**

- **Wayland:** scale is per-surface and live (fractional-scale + viewport, or integer
  fallback); the first commit is **always at scale 1** — a post-map rescale is guaranteed
  ([wl F08][wl-f08]).
- **X11:** the absence proof — `Xft.dpi` 96→144→192 and `xrandr --dpi` deliver **nothing**
  to a live window; the only live channel is an opt-in root `PropertyNotify` on
  `RESOURCE_MANAGER`, a convention, not protocol ([x11 F08][x11-f08]).
- **Win32:** Per-Monitor-v2 with write-once process awareness (second call: `err=5`) and
  a suggested-rect contract on `WM_DPICHANGED` — which is structurally unreachable under
  Wine, where compositor scale arrives as a plain `WM_SIZE` at DPI 96 ([w32 F08][w32-f08]).
- **AppKit:** points everywhere, pixels in the backing store; all scale sources agree
  (2.0) and `convertRectToBacking:` is exact including fractional ([mac F08][mac-f08]).

**What the fork forces.** The framework must keep a **logical/physical unit split in the
core geometry types** (Wayland and AppKit demand it; X11 has only physical) and must
treat scale as a **per-window, post-creation, repeatable event** — never a startup
constant — because Wayland guarantees a rescale after first commit and Win32/macOS
deliver per-monitor changes.

## F09 — Output enumeration & hotplug

**Where the four agree.** All four can enumerate outputs with position, size, and scale;
hotplug is observable under a live window on all four (live add/remove captured on
Wayland, Win32, and via xrandr choreography on X11); and window↔output **occupancy** is
knowable, with platform-specific freshness.

**Where they fork.** Two platforms ship **two disagreeing object models** for the same
display: X11's RandR 1.5 monitors vs 1.2 wiring objects disagree on physical mm
([x11 F09][x11-f09]); macOS pairs `NSScreen` (points, y-up) with CoreGraphics (pixels,
y-down), bridged by `NSScreenNumber` — and `CGDisplayPixelsWide` returns points
([mac F09][mac-f09]). Occupancy is compositor-told on Wayland (`enter`/`leave`, trailing
configures by ~200 ms, [wl F09][wl-f09]) and AppKit (`window.screen`), but derived
client-side on X11 (off-screen windows learn nothing). Change signals are unreliable:
Wine fired **none** of Win32's three notify messages on a real hotplug — only the ~0.5 s
poll caught it ([w32 F09][w32-f09]).

**What the fork forces.** Wrappable with a rule: maintain a **polled, diffed output
cache** as the source of truth and treat platform change events as hints that trigger an
early re-poll. Occupancy must be exposed as eventually-consistent (Wayland's 200 ms
trail), and the geometry type must carry which coordinate convention it is in.

## F10 — Pointer capture (lock / confine / relative motion)

**Where the four agree.** Mouselook is achievable on all four: relative deltas keep
flowing while the visible cursor is pinned and hidden, and unlock restores the saved
position. Confinement to a region exists in some form on three.

**Where they fork:**

| Platform | Lock is…                                                            | Sharpest edge                                                                                                                                                      |
| -------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Wayland  | a first-class protocol request — **grantable, deniable, revocable** | granted only on surface entry; deactivated only on focus change; only relative motion while locked ([wl F10][wl-f10])                                              |
| X11      | assembled: grab + hide + warp-to-center                             | `confine_to` modal but unenforced post-activation on Xvfb; raw events **double** during own grabs ([x11 F10][x11-f10])                                             |
| Win32    | assembled: `ClipCursor(1×1)` + `ShowCursor(FALSE)` + `WM_INPUT`     | Wine applies ballistics _before_ the raw tee; focus loss does **not** clear the clip ([w32 F10][w32-f10])                                                          |
| AppKit   | assembled: 3 sync calls, **cannot be denied**, no read-back getter  | warp is silent + fraction-truncating + 0.25 s motion suppression; **no public confine** — warp-back leaks 1 out-of-bounds event per excursion ([mac F10][mac-f10]) |

**What the fork forces.** The capture API must be **async and failable** —
`requestPointerLock()` that may be granted later, denied, or revoked externally — because
Wayland; on the other three the grant is immediate and the revocation paths (capture
theft, focus loss) must be synthesized into the same revoked event. Confinement must be a
capability flag (absent on macOS), and the framework must clean up OS-global state
(Win32's clip) on focus loss itself.

## F11 — Scroll fidelity

**Where the four agree.** One physical detent ≈ 120 units / 15° convention is recoverable
on all four; sub-detent precision exists everywhere; and **accumulation with
carried remainder** is the correct client model everywhere — truncation measurably loses
_and_ fabricates detents ([w32 F11][w32-f11]).

**Where they fork.** The vocabulary: Wayland delivers one frame-grouped axis family with
`axis_value120`, `axis_source`, and `axis_stop` ([wl F11][wl-f11]); X11 delivers the same
scroll **twice** (core buttons 4/5 and XI2 valuators) with either/or per-window delivery
and an unreliable dedupe flag — and CI servers have no `XIScrollClass` at all
([x11 F11][x11-f11]); Win32 gives a bare `wheelDelta` and routes to the window **under
the cursor** under Wine ([w32 F11][w32-f11]); AppKit packs three representations into one
event where `hasPreciseScrollingDeltas` switches the _unit_ (lines vs pixels), plus a
phase pair ([mac F11][mac-f11]). Momentum is system-driven and statefully routed only on
macOS — `sendEvent:` drops synthetic momentum ([mac F11][mac-f11]); elsewhere it is
app-synthesized ([wl F11][wl-f11]).

**What the fork forces.** Wrappable into one event: `{pixels?, detent120, source, phase}`
with a per-axis accumulator in the framework. Dedupe by **capability, not flags** (X11),
and treat momentum as an optional platform-provided phase the framework can synthesize
where missing.

## F12 — Cursors

**Where the four agree.** The system composites the cursor; the app's job is to _say
which one_ per region, on pointer motion/entry. Themed system shapes, a custom ARGB
cursor, and hide/show work on all four.

**Where they fork.** Ownership and vocabulary: Wayland needs **both** mechanisms in one
binary — `cursor-shape-v1` enum (sway) and client-rendered theme surface (weston), with a
seat-capability lifecycle that is fatal if mishandled ([wl F12][wl-f12]). X11's server
animates and scales cursors itself, but a themeless server resolves nothing
([x11 F12][x11-f12]). Win32's resize vocabulary is **4 bidirectional shapes for 8
edges**, the class cursor silently overwrites `SetCursor` on `DefWindowProc`
fall-through, and `WM_SETCURSOR` storms per move ([w32 F12][w32-f12]). AppKit had **no
public diagonal resize cursor before macOS 15**, and `set` rewrites the push/pop stack
top ([mac F12][mac-f12]).

**What the fork forces.** Wrappable: a semantic cursor enum (à la CSS) mapped per
platform, with a fallback table for vocabulary gaps (diagonals on old macOS) and a
client-render path kept alive for Wayland compositors without the shape protocol.

## F13 — Decorations (Wayland-only by design)

**Where the four agree.** N/A by construction — X11, Win32, and macOS decorate
server/system-side; their customization-hook notes live in the
[Wayland F13 doc][wl-f13]'s comparison section (see the [matrix][matrix] note).

**Where they fork.** Within Wayland alone: sway offers negotiated SSD; **weston has no
decoration protocol at all**; hand-rolled CSD costs ~1061 LOC vs 295 with libdecor, and
omitting `set_window_geometry` is a fatal protocol error ([wl F13][wl-f13]).

**What the fork forces.** A framework targeting Wayland **must own a CSD path** (or take
the libdecor dependency) — "ask for SSD" is not a strategy, because the answer can be "no
such protocol." This is the only feature where one platform forces an entire rendering
subsystem to exist (cf. [comparison Fork C][comparison]).

## F14 — Window state & vetoable close

**Where the four agree.** Maximize/fullscreen/minimize/restore are requestable
everywhere; state changes echo back observably; and a close request is **advisory on all
four** — the app decides whether to die.

**Where they fork** — the temporal shape of a state change:

- **Wayland:** states arrive as a configure **array** (and v1 vs v5 binds disagree —
  `maximized` vs `tiled_*` for the same compositor action); minimize is fire-and-forget
  with no echo at all; veto = ignore the `close` event ([wl F14][wl-f14]).
- **X11:** requests are root-window ClientMessages that do nothing without a WM; the echo
  is a payload-less `PropertyNotify` requiring re-fetch; no handshake means the
  punishment is `XKillClient` ([x11 F14][x11-f14]).
- **Win32:** echoes **synchronously** via `WM_SIZE` wParam; fullscreen is a geometry
  idiom that corrupts the placement normal-rect; close veto is first-class (swallow
  `WM_CLOSE`) ([w32 F14][w32-f14]).
- **AppKit:** three verbs, three temporal shapes — `zoom:` synchronous + animated
  (356 ms), `miniaturize:` async (1.55 s), `toggleFullScreen:` can simply fail;
  `windowShouldClose:` is a first-class once-veto that `close` (vs `performClose:`)
  skips ([mac F14][mac-f14]).

**What the fork forces.** Window state must be modeled as **requested-state vs
observed-state** with async reconciliation — setters that return `void` and lie are the
only honest portable signature, because the echo is synchronous (Win32), seconds-late
(AppKit minimize), absent (Wayland minimize), or WM-dependent (X11). Close must be a
single framework-level veto hook mapped to four different idioms.

## F15 — Popup with grab

**Where the four agree.** A raw-window context menu — placed at the pointer, hover
highlight, item activation, dismiss on outside click and Esc, one-level submenu — is
buildable on all four, and edge-of-screen handling exists on all four.

**Where they fork.** Who places it and who sees the outside click:

| Platform | Placement                                                                           | Outside-click dismissal                                                                                               |
| -------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Wayland  | **compositor** solves the positioner (sway flips, not slides)                       | uncapturable — only `popup_done`, topmost-first; stale grab serial silently granted grab-less ([wl F15][wl-f15])      |
| X11      | 100 % app math (override-redirect)                                                  | session-global pointer grab funnels it — and starves **all** other clients ([x11 F15][x11-f15])                       |
| Win32    | 100 % app math (`WS_POPUP`)                                                         | one `SetCapture` slot + screen-coord hit-testing; `WM_CAPTURECHANGED` is the silent grab-breaker ([w32 F15][w32-f15]) |
| AppKit   | 100 % app math (borderless window @ level 101; off-screen frames accepted verbatim) | no grab at all — local event monitor + `windowDidResignKey` emulation ([mac F15][mac-f15])                            |

**What the fork forces.** The popup API must be **declarative about placement intent**
(anchor + gravity + constraint-adjustment, i.e. the `xdg_positioner` shape) so the
compositor can decide on Wayland while the framework runs the same algorithm itself
elsewhere — and dismissal must be modeled as a platform-delivered "done" signal, never as
"I saw the outside click," because on Wayland you never will.

## F16 — Clipboard + drag-and-drop

**Where the four agree.** Eager and lazy (delayed-rendered/promised) transfer both exist
on all four; MIME/format negotiation precedes data; cross-process round-trips of
non-ASCII text (`é漢🎈`) verified everywhere; and losing ownership is an observable event
with sharp edges.

**Where they fork.** Unification and change signals: clipboard and DnD are **one
mechanism** on Wayland (`data_source`/offer over pipe fds — and `set_selection` is dead
without a real input serial, [wl F16][wl-f16]) and X11 (ICCCM selections + XDND, INCR
both directions, delayed rendering is the _only_ mode, [x11 F16][x11-f16]); they are two
mechanisms on Win32 (clipboard + OLE `DoDragDrop` with COM vtables; host bridging absent
on winewayland, [w32 F16][w32-f16]) and macOS (`NSPasteboard` + dragging protocols).
macOS has **no change notification** — `changeCount` polling is the only signal, and
touching `changeCount` inside the ownership callback recurses to stack overflow
([mac F16][mac-f16]); promises die with the source process. DnD action selection is
compositor-resolved on Wayland, app-negotiated elsewhere.

**What the fork forces.** Wrappable behind an async, provider-based API: data must be
offered as **lazily-rendered providers** (the only mode on X11, required for promises),
all reads async (pipe fds, INCR chunks), and "clipboard changed" exposed as an optional
capability backed by polling on macOS. Copy must be tied to a real input event on Wayland
— a framework "set clipboard programmatically at any time" API cannot be promised
portably.

## F17 — Threading

**Where the four agree.** Only on the weakest fact: every platform allows _some_
off-main-thread work (cross-thread `BitBlt` 100/100 on Win32 [w32 F17][w32-f17];
per-thread queues/`Display*`s on Wayland/X11), and every platform has at least one
silent-failure mode worth knowing.

**Where they fork** — the rule:

- **Wayland:** no main-thread rule at all; per-thread `wl_event_queue` + proxy wrappers
  are the _designed_ routing model — but a mispaired `read_events` silently wedges the
  connection forever ([wl F17][wl-f17]).
- **X11:** no main-thread rule (affinity is per-`Display`); the classic
  no-`XInitThreads` corruption is **extinct** on libX11 ≥ 1.8 (ELF-constructor
  self-arms); shared-`Display` reads starve one reader ([x11 F17][x11-f17]).
- **Win32:** HWND/queue **thread affinity** — the creating thread sees the messages
  (main saw 0 of 10); `SendMessage` to a parked (non-pumping) thread deadlocks
  ([w32 F17][w32-f17]).
- **AppKit:** the strictest — window creation off-main is a deterministic
  `NSInternalInconsistencyException` crash, and a direct cross-thread `setNeedsDisplay:`
  is a **silent no-op** ([mac F17][mac-f17]).

**What the fork forces.** The framework's public threading contract is dictated by
AppKit: **all windowing calls on one designated thread** (and on macOS that thread must
be the process main thread), with the F05 waker as the only cross-thread entry point.
Anything looser is unshippable on one platform and a latent deadlock on another.

---

## Divergence severity table

Severity grades what the fork costs a portable framework: **cosmetic** (numbers differ,
shape identical), **wrappable** (one abstraction + per-platform tables), and
**architecture-forcing** (the strictest platform dictates the portable API's shape).

| Feature             | Severity             | One-line reason                                                                                                             |
| ------------------- | -------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| F01 first pixel     | cosmetic             | same concept ladder everywhere; only the bottleneck (frame clock / round-trips / session connect) moves                     |
| F02 resize          | architecture-forcing | Wayland makes resize an enforced negotiation (serial ack, fatal on violation) — model it that way everywhere                |
| F03 modal loop      | architecture-forcing | Win32/AppKit steal the loop (1.01 s freeze / starved timer); the render driver must be a re-entered callback                |
| F04 frame pacing    | architecture-forcing | the native clock can stop (minimize), lie (Wine `DwmFlush`), or go silent (`CADisplayLink`) — independent watchdog required |
| F05 loop wakeup     | wrappable            | all four wake in ≤~0.5 ms; one `Waker` over fd-vs-posted-message covers it (mind the 63-handle ceiling)                     |
| F06 keyboard        | wrappable            | same three-level pipeline; framework must own client-side repeat (Wayland) and toggle it off elsewhere                      |
| F07 text input      | architecture-forcing | four protocols, one composition state machine — marked text and the IME gate must live in the core text model               |
| F08 dpi scaling     | architecture-forcing | logical/physical unit split + scale-as-repeatable-event (Wayland first-commit-at-1; X11 has no signal at all)               |
| F09 outputs         | wrappable            | polled diffed cache + events-as-hints absorbs dual models, point/pixel traps, and Wine's missing notifications              |
| F10 pointer capture | architecture-forcing | lock is async-deniable-revocable on Wayland and confine is absent on macOS — API must be failable + capability-flagged      |
| F11 scroll          | wrappable            | everything reduces to {pixels, detent120, source, phase} + a carried-remainder accumulator                                  |
| F12 cursors         | wrappable            | semantic enum + per-platform mapping + fallbacks (4-shape Win32 vocabulary, pre-15 macOS diagonal gap)                      |
| F13 decorations     | architecture-forcing | Wayland alone, but it forces a whole CSD rendering path to exist (weston has no SSD protocol to negotiate)                  |
| F14 window state    | architecture-forcing | requested-vs-observed state with async reconciliation: echo is sync, late, absent, or WM-dependent by platform              |
| F15 popup           | architecture-forcing | placement must be declarative intent (compositor decides on Wayland); dismissal is a signal, not an observed click          |
| F16 clipboard + DnD | wrappable            | async provider model covers all four; caveats (serial-gated copy, polling-only change signal) are capability flags          |
| F17 threading       | architecture-forcing | AppKit's main-thread-or-crash rule sets the public contract; Win32 affinity and Wayland queue-pairing hide inside it        |

Ten of seventeen features are architecture-forcing — and in eight of those ten the
strictest member is Wayland or AppKit. That is the headline of the whole empirical phase:
the portable core must be designed _from_ the Wayland contract model and the AppKit
loop/threading model, with X11 and Win32 as the permissive degenerate cases — the
reverse of how most pre-Wayland toolkits grew (see [comparison, Part 5][comparison-delta]).

<!-- References -->

[matrix]: ./feature-matrix.md
[comparison]: ../comparison.md
[comparison-delta]: ../comparison.md#part-5-the-delta-table
[wl-f01]: ./wayland/f01-first-pixel.md
[wl-f02]: ./wayland/f02-resize.md
[wl-f03]: ./wayland/f03-modal-loop.md
[wl-f04]: ./wayland/f04-frame-pacing.md
[wl-f05]: ./wayland/f05-loop-wakeup.md
[wl-f06]: ./wayland/f06-keyboard.md
[wl-f07]: ./wayland/f07-text-input.md
[wl-f08]: ./wayland/f08-dpi-scaling.md
[wl-f09]: ./wayland/f09-outputs.md
[wl-f10]: ./wayland/f10-pointer-capture.md
[wl-f11]: ./wayland/f11-scroll.md
[wl-f12]: ./wayland/f12-cursors.md
[wl-f13]: ./wayland/f13-decorations.md
[wl-f14]: ./wayland/f14-window-state.md
[wl-f15]: ./wayland/f15-popup.md
[wl-f16]: ./wayland/f16-clipboard-dnd.md
[wl-f17]: ./wayland/f17-threading.md
[x11-f01]: ./x11/f01-first-pixel.md
[x11-f02]: ./x11/f02-resize.md
[x11-f03]: ./x11/f03-modal-loop.md
[x11-f04]: ./x11/f04-frame-pacing.md
[x11-f05]: ./x11/f05-loop-wakeup.md
[x11-f06]: ./x11/f06-keyboard.md
[x11-f07]: ./x11/f07-text-input.md
[x11-f08]: ./x11/f08-dpi-scaling.md
[x11-f09]: ./x11/f09-outputs.md
[x11-f10]: ./x11/f10-pointer-capture.md
[x11-f11]: ./x11/f11-scroll.md
[x11-f12]: ./x11/f12-cursors.md
[x11-f14]: ./x11/f14-window-state.md
[x11-f15]: ./x11/f15-popup.md
[x11-f16]: ./x11/f16-clipboard-dnd.md
[x11-f17]: ./x11/f17-threading.md
[w32-f01]: ./win32/f01-first-pixel.md
[w32-f02]: ./win32/f02-resize.md
[w32-f03]: ./win32/f03-modal-loop.md
[w32-f04]: ./win32/f04-frame-pacing.md
[w32-f05]: ./win32/f05-loop-wakeup.md
[w32-f06]: ./win32/f06-keyboard.md
[w32-f07]: ./win32/f07-text-input.md
[w32-f08]: ./win32/f08-dpi-scaling.md
[w32-f09]: ./win32/f09-outputs.md
[w32-f10]: ./win32/f10-pointer-capture.md
[w32-f11]: ./win32/f11-scroll.md
[w32-f12]: ./win32/f12-cursors.md
[w32-f14]: ./win32/f14-window-state.md
[w32-f15]: ./win32/f15-popup.md
[w32-f16]: ./win32/f16-clipboard-dnd.md
[w32-f17]: ./win32/f17-threading.md
[mac-f01]: ./appkit/f01-first-pixel.md
[mac-f02]: ./appkit/f02-resize.md
[mac-f03]: ./appkit/f03-modal-loop.md
[mac-f04]: ./appkit/f04-frame-pacing.md
[mac-f05]: ./appkit/f05-loop-wakeup.md
[mac-f06]: ./appkit/f06-keyboard.md
[mac-f07]: ./appkit/f07-text-input.md
[mac-f08]: ./appkit/f08-dpi-scaling.md
[mac-f09]: ./appkit/f09-outputs.md
[mac-f10]: ./appkit/f10-pointer-capture.md
[mac-f11]: ./appkit/f11-scroll.md
[mac-f12]: ./appkit/f12-cursors.md
[mac-f14]: ./appkit/f14-window-state.md
[mac-f15]: ./appkit/f15-popup.md
[mac-f16]: ./appkit/f16-clipboard-dnd.md
[mac-f17]: ./appkit/f17-threading.md
