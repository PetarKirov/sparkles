# Event sequences — lifecycle transitions, side by side

The Phase-3 synthesis of the demo matrix: for each lifecycle transition, the
**ordered event sequence** each platform actually delivered, distilled from the
per-platform findings docs (every sequence below links to the run it came from).
Platforms: Wayland (headless weston 15 / sway 1.11, Tier A), X11 (Xvfb ± icewm,
Tier A), Win32 (`A[wine]` — Wine 10/11, headless; orderings are Wine's, queued
for Windows CI re-confirmation), AppKit (`A[ssh]` — macOS 26.3 over SSH, console
locked; geometry/callback orderings are sound, composited pixels are not).

Each section ends with **Alignment notes**: what a framework's unified event
stream must reorder, synthesize, or suppress per platform.

**Last reviewed:** June 11, 2026

## 1. Creation → first pixel

What "presented" even means differs per platform — only Wayland has a
server-driven confirmation; the other three confirm at best "my draw call
returned".

```text
Wayland [w-f01]                          X11 [x-f01]
  connect → registry roundtrip (rt 1)      XOpenDisplay (rt 1)
  create wl_surface/xdg_surface/toplevel   XCreateSimpleWindow (async, client mints XID)
  commit(no buffer)                        XMapWindow (async)
  ← xdg_toplevel/xdg_surface.configure     ← MapNotify → Expose        (no WM)
    (rt 2: wait for first configure)       ← Configure(real) → Reparent →
  ack_configure(serial)                      Configure(synth) → MapNotify → Expose (WM)
  attach + damage + frame() + commit       XShmPutImage(send_event)
  ← frame callback done                    ← ShmCompletionEvent
  = "presented": commit consumed by        = "presented": server done READING the
    the compositor's repaint cycle           buffer; glass needs the Present ext.

Win32 [n-f01]  A[wine]                   AppKit [a-f01]  A[ssh]
  RegisterClassExW                         CGMainDisplayID (rt: WindowServer connect)
  CreateWindowExW —— re-entrant inside:    NSApplication.sharedApplication (rt)
    WM_GETMINMAXINFO → WM_NCCREATE →       NSWindow initWithContentRect (rt: server-
    WM_NCCALCSIZE → WM_CREATE                side window; scale already known)
  ShowWindow —— re-entrant inside:         setContentView —— synchronous inside:
    WM_SHOWWINDOW → WM_WINDOWPOSCHANGING     view setFrameSize: (first configure)
    → WM_ERASEBKGND → WM_WINDOWPOSCHANGED  makeKeyAndOrderFront (paints nothing)
    → WM_SIZE (first configure) → WM_MOVE  [NSApp run] → first drawRect: on the
  UpdateWindow → WM_PAINT → BitBlt           loop's first drawing pass (~26 ms in)
  = "presented": BitBlt returned; DWM      = "presented": drawRect: returned;
    composites later, unreported             CATransaction composites later, unreported
```

Round-trip/blocking shape: Wayland blocks exactly twice (registry sync, first
configure) — everything else is buffered writes; X11 blocks on five
reply-bearing calls (~0.65 ms of a ~1.4 ms total) and `XCreateSimpleWindow`
itself is free; Win32 has **zero** observable round-trips but the first user32
call pays a one-time ~13 ms session-connection charge (`A[wine]`) and creation
messages run re-entrantly inside `CreateWindowExW`; AppKit's init is a chain of
synchronous WindowServer round-trips (`sharedApplication` ~27 ms,
`initWithContentRect:` ~38 ms cold) totalling ~100–130 ms to first pixel.

With `WS_VISIBLE`, Win32's entire show cascade (through the first `WM_SIZE` and
`WM_MOVE`) moves _inside_ `CreateWindowExW` — same message order, different
stack frame [n-f01].

**Alignment notes.** A unified "window created" event must be deliverable
_before_ the platform's first resize: Win32 delivers the first `WM_SIZE`
re-entrantly inside the creation/show call, and AppKit's first `setFrameSize:`
fires inside `setContentView:` before the view's `window` link exists. A
unified "first frame presented" event is honest only on Wayland; on the other
three it must be synthesized from draw-call return (and documented as weaker).
On X11 the framework must accept either `MapNotify` or `ConfigureNotify` as the
on-screen signal — waiting for one specific kind deadlocks WM-less servers or
misses WM size corrections.

## 2. Programmatic resize (one clean cycle)

```text
Wayland — negotiation [w-f02]            X11 — notification, maybe mediated [x-f02]
  → set_maximized / (request)              → XResizeWindow (fire-and-forget)
  ← xdg_toplevel.configure(size, states)     [1 stale frame at old size — structural;
  ← xdg_surface.configure(serial)             ≤6 under a WM, which may batch grants]
  → ack_configure(serial)   # MUST echo    ← ConfigureNotify(real)   send_event=0
  → realloc + attach + commit at the         [+ ConfigureNotify(synth) send_event=1
    configured size — wrong size in a         in ROOT coords, under a WM]
    maximized state = fatal protocol       realloc → ← Expose (gate on count==0)
    error, connection killed (EPROTO)      → repaint at the authoritative size

Win32 — synchronous cascade [n-f02]      AppKit — synchronous chain [a-f02]
  → SetWindowPos —— re-entrant inside:     → setFrame:display:YES (or setContentSize:)
    WM_WINDOWPOSCHANGING (proposal,          —— synchronous inside the call:
      mutable) → WM_NCCALCSIZE →             view setFrameSize: (+0.4–0.7 ms)
    [WM_ERASEBKGND — grows only] →           → windowDidResize: delegate (+~60 µs)
    WM_WINDOWPOSCHANGED (fact) →           → drawRect: forced by display:YES (+~6 ms);
    WM_SIZE (client size) → realloc          without the flag, next run-loop pass
  → InvalidateRect + WM_PAINT — shrinks    every request honoured bit-exact; no
    self-invalidate NOTHING [n-f02]          negotiation, no live-resize bracket
```

Who picks the size: Wayland the compositor (the client _must_ obey constrained
states and carry its own floating-size memory); X11 the server — or the WM,
which may delay, batch, or modify (`XResizeWindow` degrades to a
`ConfigureRequest` suggestion); Win32 and AppKit the app, verbatim. X11's
`serial` field cannot attribute events, and the server never coalesces a burst
(three requests = three notifies) [x-f02]. Wayland's serial is an opaque
per-compositor token to echo, never to interpret [w-f02].

**Alignment notes.** The framework must present one "resized(w, h)" event per
settled size, which means: on Wayland, fuse configure+ack+commit and enforce
the serial discipline internally (a missed ack or wrong-sized maximized commit
is connection-fatal); on X11, coalesce `ConfigureNotify` batches, drop
synthetic-event coordinates (root vs parent space), and tolerate the
structural stale frame; on Win32, survive the re-entrant cascade (the handler
runs _inside_ the app's own `SetWindowPos`) and self-invalidate on shrink; on
AppKit, nothing — but note the event has already happened synchronously when
the request returns.

## 3. Scale / DPI change under a live window

```text
Wayland (sway, fractional) [w-f08]       Win32 (documented) [n-f08]  A[wine]
  ← wl_output.scale(2)      # ceil, lie!   ← WM_DPICHANGED(oldDpi, newDpi,
  ← wp_fractional_scale_v1                     suggested rect)
      .preferred_scale(180) # ÷120 = 1.5   → SetWindowPos(suggested rect)
  ← wl_surface.preferred_buffer_scale(2)   ← WM_WINDOWPOSCHANGING/CHANGED → WM_SIZE
  ← xdg_toplevel/xdg_surface.configure     → realloc at new physical size
      (NEW logical size — retiled)         …but under Wine 10.0 the message never
  → ack + realloc (buffer = logical ×        arrives: a live compositor scale change
    scale120/120, half-away-from-zero) +     lands as a plain WM_SIZE doubling the
    viewport.set_destination + commit        pixels at constant DPI 96 [n-f08]

AppKit [a-f08]                           X11 [x-f08]
  ← NSApplicationDidChangeScreenParams…    ← PropertyNotify(RESOURCE_MANAGER) on the
      (arrangement changed, app-level)         ROOT window — opt-in convention only
  ← NSWindowDidChangeBackingProperties…    → re-fetch Xft.dpi via XGetWindowProperty
      (old scale in userInfo)                  (XResourceManagerString is a stale
  ← viewDidChangeBackingProperties             connection-time snapshot)
  → reallocate at points × new scale       → (nothing else, ever — the entire
  [registration proven; firing is Tier C       "rescale" is application policy)
   — locked single-screen session]
```

Wayland's first commit is **always at scale 1** (the protocol default); the
authoritative scale arrives post-map, so one rescale/realloc right after
mapping is guaranteed on any scaled output. The legacy integer events
(`wl_output.scale`, `preferred_buffer_scale`) fire _alongside_ the fractional
one and round up — a fractional-aware client must ignore them. AppKit fires
`viewDidChangeBackingProperties` once at view installation (install ≠ scale
change) and never hands out a fractional scale; X11 has no scale concept
addressed to a window at all — the absence is the finding [x-f08].

**Alignment notes.** A unified "scale changed" event needs heavy per-platform
synthesis: on Wayland, suppress the rounded integer echoes and coalesce
`preferred_scale` with the configure that almost always follows (a scale change
is usually also a resize); on Win32, treat scale and size as independently
arriving facts (Wine proves the size can change without the DPI message); on
AppKit, distinguish the install-time view callback from a real window-level
backing flip; on X11, the framework must _invent_ the event from an opt-in
root-property watch — or document that it never fires.

## 4. Maximize / restore

```text
Wayland [w-f14]                          X11 + icewm [x-f14]
  → set_maximized                          → _NET_WM_STATE ClientMessage to ROOT
  ← configure size=1024x608                ← ConfigureNotify(real) + (synth)   # resize FIRST
      states=[maximized]                   ← PropertyNotify(_NET_WM_STATE)     # state LAST
  → ack + commit at EXACTLY that size      → re-fetch + diff the atom list:
  restore: configure 0x0 states=[] —          [MAXIMIZED_VERT, MAXIMIZED_HORZ]
    "you pick"; client restores its OWN    restore: symmetric (configure back, atoms drop)
    remembered floating size               no WM: the message is DISCARDED — silence

Win32 [n-f14]  A[wine]                   AppKit (zoom:) [a-f14]  A[ssh]
  → ShowWindow(SW_MAXIMIZE) — re-entrant:  → zoom: —— BLOCKS ~356 ms (animated):
    WM_GETMINMAXINFO ×2 (override point)     windowWillUseStandardFrame (proposal)
    → WM_WINDOWPOSCHANGING →                 → windowShouldZoom:toFrame: (veto point)
    WM_WINDOWPOSCHANGED →                    → windowWillStartLiveResize
    WM_SIZE wParam=SIZE_MAXIMIZED (echo)     → windowDidResize (ONE, at the end)
  normal rect remembered by the SYSTEM       → windowDidEndLiveResize
    (GetWindowPlacement)                   zoomed frame = visibleFrame (minus menubar)
  [winewayland only: a SECOND compositor-  restore: AppKit restores ITS saved user
    driven WM_WINDOWPOSCHANGED corrects      frame; inserts windowWillResize:toSize:
    the size ~2 ms later]                  isZoomed re-invokes willUseStandardFrame!
```

Obedience varies: sway acks `set_maximized` on a tiled window with an
_unchanged_ states array — the echoed array, never the request, is the truth
[w-f14]. Who remembers the pre-maximize geometry: the client (Wayland), the WM
(X11), the system (`GetWindowPlacement`, Win32), AppKit (zoom).

**Alignment notes.** Emit "maximized" only from the platform's echo (states
array / `_NET_WM_STATE` diff / `SIZE_MAXIMIZED` / `isZoomed`), never from the
request returning. The framework owns floating-size memory on Wayland only.
On Win32-on-Wayland, the first echo is provisional — debounce a possible
second configure. On AppKit, the request blocks for an animation and delegate
veto points fire mid-call; on X11 without a WM the request must time out.

## 5. Minimize — the asymmetry section

Who echoes, who goes dark:

```text
Wayland [w-f14]                          X11 + icewm [x-f14]
  → set_minimized                          → WM_CHANGE_STATE (XIconifyWindow)
  ← (nothing — EVER; no minimized state,   ← PropertyNotify _NET_WM_STATE → [HIDDEN]
    no unset request, by protocol design)  ← PropertyNotify WM_STATE → iconic
  frame callbacks STOP — the only          ← FocusOut
    machine-readable signal (suspended     ← UnmapNotify          # properties FIRST,
    needs xdg_wm_base v6; nobody ships it)     structure LAST — inverse of maximize
                                           NO ConfigureNotify: geometry is kept

Win32 [n-f14]  A[wine]                   AppKit (miniaturize:) [a-f14]  A[ssh]
  → ShowWindow(SW_MINIMIZE)                → miniaturize: — returns IMMEDIATELY
  ← WM_KILLFOCUS next=null                   (readback still says mini=0)
  ← WM_WINDOWPOSCHANGING/CHANGED to        ← windowWillMiniaturize + WillOrderOffScreen
      (-32000,-32000) 160×31  # parked,        (+4 ms)
      still has geometry                   …1.55 s animation gap…
  ← WM_SIZE wParam=SIZE_MINIMIZED size=0x0 ← windowDidMiniaturize + DidOrderOffScreen
  restore: SIZE_RESTORED then WM_SETFOCUS  focus question unanswerable at A[ssh]
    + WM_ACTIVATE — focus returns unasked    (locked session grants no key status)
```

Four different temporal shapes: Wayland fire-and-forget (silence is the echo),
X11 a five-event echo with the property/structure order _inverted_ relative to
maximize, Win32 a synchronous in-band echo with size 0×0, AppKit asynchronous
fire-and-settle-later. Only Wayland never confirms; only Win32 reports a
geometry (the parking lot); only X11 unmaps.

**Alignment notes.** "Minimized" must be synthesized on Wayland from
frame-callback silence (which also means the event loop cannot be
frame-callback-driven — it deadlocks at `set_minimized` [w-f14]). On X11,
infer it from `WM_STATE`/`_NET_WM_STATE_HIDDEN`, not from `UnmapNotify` alone
(that also means withdrawal). On Win32, suppress the 0×0 `WM_SIZE` from the
resize stream (keep the old buffer). On AppKit, the unified event arrives
seconds after the request — do not read state synchronously after the call.

## 6. Fullscreen — real state vs idiom vs Space transition

```text
Wayland [w-f14] — first-class state       X11 + icewm [x-f14] — real WM state
  → set_fullscreen(nil output)              → _NET_WM_STATE_FULLSCREEN to root
  ← configure size=1024x640 (FULL output;   ← ConfigureNotify pair (full screen, 0+0)
      maximize had left panel room)         ← PropertyNotify _NET_FRAME_EXTENTS
      states=[fullscreen]                       (frame REMOVED)
  → ack + commit at exactly that size       ← state_changed [FULLSCREEN] + layer raise

Win32 [n-f14] — a geometry IDIOM           AppKit [a-f14] — a Space transition
  → save style + rect; strip                → set collectionBehavior FullScreenPrimary
    WS_OVERLAPPEDWINDOW;                    → toggleFullScreen: (asynchronous)
    SetWindowPos(monitor rect,              ← NSWindowWillSnapshotForFullScreen…
    SWP_FRAMECHANGED)                       ← windowWillEnterFullScreen
  ← …POSCHANGING/CHANGED →                  ← live-resize bracket to full frame
    WM_SIZE wParam=SIZE_RESTORED (!)        ← [locked session: resized BACK, then
  GetWindowPlacement says SW_SHOWNORMAL —       windowDidFailToEnterFullScreen — a
    no state exists; AND the idiom              first-class failure callback; the one
    DESTROYS rcNormalPosition: restore          place the notification preceded the
    must use the app's own saved rect           delegate method]
```

**Alignment notes.** A unified `setFullscreen(bool)` has four contracts: a
state echo to await (Wayland, X11), a pure geometry trick whose echo claims
"restored" and which corrupts the system's normal-rect memory (Win32 — the
framework must own the saved rect), and an asynchronous transition that can
_fail_ and must surface that failure (AppKit). Only AppKit needs a
prerequisite (`collectionBehavior`) and only AppKit can deny the request after
starting it.

## 7. Close request + veto — the contract ladder

From first-class return-value veto to advisory-ignore:

```text
AppKit [a-f14]   performClose: → delegate windowShouldClose: returns NO = veto
                 (sticks: no windowWillClose, no notifications, window stays).
                 TRAPDOOR: close skips the ask entirely — route "request close"
                 through performClose: only.
Win32 [n-f14]    ✕ → WM_SYSCOMMAND SC_CLOSE → WM_CLOSE; returning 0 WITHOUT
                 DefWindowProc = veto (DefWindowProc is what calls DestroyWindow).
                 Accepted close tears down hide → WA_INACTIVE → WM_ACTIVATEAPP 0
                 → WM_KILLFOCUS → WM_DESTROY — focus loss is part of destruction.
X11 [x-f14]      WM_PROTOCOLS/WM_DELETE_WINDOW ClientMessage; no reply channel —
                 veto = do nothing (indistinguishable from a hang; WMs escalate to
                 XKillClient → XIOError, non-returnable). Skipping the handshake
                 entirely converts every user close into SIGKILL semantics.
Wayland [w-f14]  xdg_toplevel.close event; "the client may choose to ignore this
                 request" — veto = ignore, accept = tear down yourself. No
                 escalation ever; the only non-vetoable end is the socket dying
                 (EPIPE), which must be absorbed as a clean exit.
```

**Alignment notes.** A unified `onCloseRequested → bool` maps natively onto
AppKit/Win32 (synchronous return value) but on X11/Wayland the "veto" is the
_absence of action_ — the framework implements accept, not veto. It must also
suppress the Win32 destruction-time focus events from the activation stream,
and on X11 always install the `WM_DELETE_WINDOW` handshake plus an
`XIOError`/`EPIPE` handler for the non-vetoable paths.

## 8. Window crosses to another output

```text
Wayland (sway) [w-f09] — push, ordered     AppKit [a-f09] — push, derived by AppKit
  move to output B:                          ← NSWindowDidChangeScreenNotification
  ← configure (retiled to B's logical          (window.screen re-answers; majority-
      size) — the resize comes FIRST            area rule; valid from init)
  → ack + commit at new size                 ← viewDidChangeBackingProperties /
  ← leave(A) / enter(B) ~200 ms LATER —          window backing notification if the
      occupancy derives from committed           scale differs [a-f08]
      buffers and TRAILS the resize          [firing is Tier C — single locked screen;
  occupied output dies: leave →                 registration + self-test proven]
      global_remove → enter(survivor) →
      configure(new size); spurious        Win32 [n-f09] — pull + WM_DPICHANGED
      same-output leave/enter pairs occur    MonitorFromWindow on demand; topology
                                             changes via WM_DISPLAYCHANGE; the DPI
X11 [x-f09] — nothing; derive it             consequence is the §3 WM_DPICHANGED
  no event addresses the window. On every    sequence (unreachable under Wine).
  ConfigureNotify: translate to root
  coords, intersect with XRRGetMonitors
  rects yourself. Fully off-screen =
  still running, no event, no error.
```

**Alignment notes.** A unified "window changed output" event is native push on
Wayland and AppKit (but on Wayland it _trails_ the resize — never gate "which
output am I on" on `enter` having arrived, and handlers must be idempotent
against spurious leave/enter), a poll Win32 must run on move/`WM_DISPLAYCHANGE`,
and pure framework-side geometry intersection on X11. The scale consequence
rides along only on Wayland (`preferred_scale`) and Win32 (`WM_DPICHANGED`);
AppKit splits it into a separate backing notification; X11 has none (§3).

## Sharpest divergences

Ranked by how little a 4-way unified event can reuse: **(1) scale change** —
ordered multi-protocol negotiation vs a suggested-rect message vs a
notification pair vs structural silence; **(2) minimize** — four temporal
shapes, one of which is "no echo, ever"; **(3) close/veto** — return-value
contract vs advisory-ignore, with X11's kill escalation; **(4) resize** is the
deepest _mechanical_ split (negotiate / notify / re-entrant cascade /
synchronous chain) but at least every platform emits an authoritative size.

## Sources

Every sequence above is quoted or condensed from the per-platform findings docs
(which carry the verbatim instrument logs and primary-source citations):
Wayland — [F01][w-f01], [F02][w-f02], [F08][w-f08], [F09][w-f09], [F14][w-f14];
X11 — [F01][x-f01], [F02][x-f02], [F08][x-f08], [F09][x-f09], [F14][x-f14];
Win32 — [F01][n-f01], [F02][n-f02], [F08][n-f08], [F09][n-f09], [F14][n-f14];
AppKit — [F01][a-f01], [F02][a-f02], [F08][a-f08], [F09][a-f09], [F14][a-f14].
Feature specs live in [`features/`](./features/index.md); the per-cell evidence
grid is [the feature matrix](./feature-matrix.md).

<!-- References -->

[w-f01]: ./wayland/f01-first-pixel.md
[x-f01]: ./x11/f01-first-pixel.md
[n-f01]: ./win32/f01-first-pixel.md
[a-f01]: ./appkit/f01-first-pixel.md
[w-f02]: ./wayland/f02-resize.md
[x-f02]: ./x11/f02-resize.md
[n-f02]: ./win32/f02-resize.md
[a-f02]: ./appkit/f02-resize.md
[w-f08]: ./wayland/f08-dpi-scaling.md
[x-f08]: ./x11/f08-dpi-scaling.md
[n-f08]: ./win32/f08-dpi-scaling.md
[a-f08]: ./appkit/f08-dpi-scaling.md
[w-f14]: ./wayland/f14-window-state.md
[x-f14]: ./x11/f14-window-state.md
[n-f14]: ./win32/f14-window-state.md
[a-f14]: ./appkit/f14-window-state.md
[w-f09]: ./wayland/f09-outputs.md
[x-f09]: ./x11/f09-outputs.md
[n-f09]: ./win32/f09-outputs.md
[a-f09]: ./appkit/f09-outputs.md
