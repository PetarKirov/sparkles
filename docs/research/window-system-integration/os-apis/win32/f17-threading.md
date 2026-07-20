# Win32 F17 — threading probes

What Win32's thread-affine message queues actually do, measured. The demo,
[`./examples/f17-threading/app.d`](./examples/f17-threading/app.d), extends the
[scaffold](./scaffold.md) per the [F17 spec][f17]: six `--probe=N` run modes, each ending
in a verdict line (`probe n=… result=ok|error|crash|deadlock|silent detail=…`) that
survives _any_ outcome — a [`SetUnhandledExceptionFilter`][seh] SEH hook turns crashes
into a flushed `result=crash` + `ExitProcess(0)`, and a watchdog thread turns hangs into
`result=deadlock` + `ExitProcess(0)`. The no-argument run (what CI executes) spawns
itself with `--probe=N` **twice** per probe via `CreateProcessW` (the spec's
nondeterminism rule, with process isolation so a deadlocked child can't poison the next
probe). All 12 child runs and the driver: exit 0 — including probe 4, whose job is to
deadlock.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 with the exe
> cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Two full passes:
> **winewayland** against a headless weston 15 socket and **winex11** under `xvfb-run`
> (`WAYLAND_DISPLAY` unset, private `XDG_RUNTIME_DIR`); every verdict, count, and
> failure mode was identical across both drivers and both runs each. The [spec][f17]
> explicitly flags that Wine's threading diverges from real user32 internals — the full
> suite is queued for a real-Windows re-run in the [manual-run queue][manual-queue].

## The contract being probed

Win32's rule is the opposite of X11's connection-affinity ([X11 F17][x11-f17]): the unit
of affinity is the **creating thread**. [`GetMessageW`][getmessage] "retrieves a message
from the calling thread's message queue", and a window's posted/sent messages land in
the queue of the thread that called `CreateWindowExW` — no API moves a window between
queues. Corollaries probed below: [`SendMessageW`][sendmessage] to another thread's
window "is blocked until the receiving thread processes the message" (but "the sending
thread will process incoming nonqueued messages while waiting"), and
[`DestroyWindow`][destroywindow] states "a thread cannot use `DestroyWindow` to destroy
a window created by a different thread". GDI, by contrast, has no such affinity — a DC
handle can be used from any thread, one thread at a time.

## Probe outcomes (the design-constraints table)

| #   | Probe                                                               | Legality         | Verdict ×2            | Detail                                                                                                    |
| --- | ------------------------------------------------------------------- | ---------------- | --------------------- | --------------------------------------------------------------------------------------------------------- |
| 1   | Window created on worker; main hunts for its messages               | legal            | `ok`                  | main saw **0** of 10 posted messages (even HWND-filtered); worker drained all 10                          |
| 2   | Worker creates **and pumps** its own window, main pumps another     | legal            | `ok`                  | 30 paints on each thread, two concurrent pumps                                                            |
| 3   | Cross-thread `SendMessage` vs `PostMessage`                         | legal            | `ok`                  | `SendMessage` blocked 400.6 ms against a 400 ms non-pumping gap; `PostMessage` returned in <1 ms          |
| 4a  | Two threads `SendMessage` each other simultaneously                 | legal            | `ok`                  | **no deadlock** — both returned in <1 ms (nonqueued-message processing during the wait)                   |
| 4b  | `SendMessage` to a thread parked in `WaitForSingleObject`           | legal, **hangs** | `deadlock` (expected) | `SendMessageTimeout` first: ret=0 `err=1460` (`ERROR_TIMEOUT`); plain send never returns — watchdog fired |
| 5   | `BitBlt` into a window DC from a non-owning thread, 100 frames      | legal            | `ok`                  | 100/100 blits succeeded while the owner pumped and repainted (20 paints)                                  |
| 6   | `GetFocus` across queues + [`AttachThreadInput`][attachthreadinput] | legal            | `ok`                  | worker's `GetFocus()`=`NULL` before attach, = the main thread's focus window after                        |

### Probe 1 — HWND messages go to the creating thread's queue, period

```text
10481 f17_win32 thread=worker action=window_created hwnd=0000000000020066 tid=416 ok=1
10950 f17_win32 thread=worker action=posted count=10 to_own_window=1
515490 f17_win32 main_hunt thread_wide=0 hwnd_filtered=0 tid=404
516123 f17_win32 thread=worker action=drained wm_ping=10
517305 f17_win32 probe n=1 result=ok detail=posted=10 main_saw=0 main_saw_hwnd_filtered=0 worker_drained=10
```

Window creation on a worker thread is **legal and silent** (contrast AppKit's
main-thread assertion), but the 10 messages posted to that window are invisible to the
main thread for the entire 500 ms hunt — both via thread-wide `PeekMessageW(null, …)`
and via a peek **filtered by that exact HWND**: [`PeekMessageW`][peekmessage] retrieves
only "messages associated with the window identified by the hWnd parameter **and
belonging to the calling thread**" (paraphrasing both message-retrieval docs — the hWnd
filter never reaches across queues). The worker then drained all 10 from its own queue.
This is THE Win32 rule a framework inherits: _whoever creates the window must pump it_.

One first-hand byproduct: the drain loop must filter to `WM_PING..WM_PING` — an
unfiltered `PeekMessage(PM_REMOVE)` on a shown-but-never-painted window **spins
forever**, because [`WM_PAINT`][wm-paint] is not removed from the queue by message
retrieval; it is only cleared by validating the update region (`BeginPaint`).

### Probe 2 — one pump per thread is the legal multi-window model

```text
172385 f17_win32 probe n=2 result=ok detail=main_paints=30 worker_paints=30 concurrent_pumps=2
```

Two windows, two threads, each thread pumping (and painting) its own — 30/30 frames
each, zero interference, both runs, both drivers. Win32 natively supports the
window-per-thread model X11 only reaches via display-per-thread (probe 5 in
[X11 F17][x11-f17]); the constraint is only that each window's pump lives on its
creating thread.

### Probe 3 — `SendMessage` is synchronous with the _receiver's pump_, not the call

```text
10245 f17_win32 thread=worker action=send_begin t=10245 owner_sleeping_ms=400
411350 f17_win32 thread=worker action=send_returned ret=42 blocked_us=400622
412320 f17_win32 post_latency_us=631 dispatched_on_thread=484
```

The main thread created the window and then deliberately slept 400 ms without pumping.
The worker's `SendMessageW` blocked **400.6 ms** — almost exactly the gap — and returned
the WndProc's return value (42) only after the owner reached its `GetMessage` loop.
The follow-up `PostMessageW` was dispatched 631 µs after posting (the owner was pumping
by then) and `PostMessage` itself returned immediately. Cross-thread `SendMessage`
latency is therefore unbounded by design: it is the receiver's scheduling, not IPC cost.

### Probe 4 — the deadlock recipe, and the one Windows defuses

```text
12337 f17_win32 main action=mutual_send_returned ret=7 blocked_us=602
12342 f17_win32 thread=worker action=mutual_send_returned ret=7 blocked_us=972
12992 f17_win32 probe n=4 stage=mutual_send result=ok detail=both_returned wm_mutual_recv=2 main_blocked_us=602
...
1614812 f17_win32 main action=SendMessageTimeout ret=0 err=1460 timeout_ms=1500
1615271 f17_win32 main action=plain_send_begin expect=deadlock watchdog_ms=3000
4618904 f17_win32 probe n=4 result=deadlock detail=watchdog_fired stage=p4b_send_to_blocked_thread
```

- **4a — mutual `SendMessage` does NOT deadlock.** Both threads sent to each other's
  window at a barrier; both calls returned in under 1 ms with the handler's value. This
  is the documented escape hatch working as written: "the sending thread will process
  incoming nonqueued messages while waiting for its message to be processed"
  ([`SendMessageW`][sendmessage]) — each blocked sender dispatches the other's _sent_
  message from inside its own wait. Wine reproduces the rule faithfully.
- **4b — the real deadlock is `SendMessage` → a thread that is neither pumping nor
  sending.** The worker parked in `WaitForSingleObject(INFINITE)` (a plain kernel wait
  processes no messages). [`SendMessageTimeoutW`][sendmessagetimeout] with
  `SMTO_NORMAL`/1500 ms is the mitigation an API binding should reach for: it returned
  0 with `GetLastError()==1460` (`ERROR_TIMEOUT`). The plain `SendMessageW` that
  followed never returned — the 3 s watchdog wrote the `result=deadlock` verdict and
  exited 0. The framework rule: **any thread that owns a window or may receive
  `SendMessage` must never block in a non-alertable, non-message wait** (this is
  exactly the X11 probe-3 shutdown hazard in different clothes — a blocked receiver can
  only be released by feeding it the thing it's blocked on).

### Probe 5 — GDI presentation has no thread affinity

```text
10771 f17_win32 thread=worker action=GetDC hdc=000000000A010053 err=0
... (100 BitBlts, Sleep(3) apart, owner pumping a 16 ms repaint timer)
320790 f17_win32 thread=worker action=blits done ok=100 fail=0 first_err=0
322274 f17_win32 probe n=5 result=ok detail=blits_ok=100/100 owner_dispatched=40 owner_paints=20
```

The worker acquired the window DC with `GetDC(hwnd)` **on its own thread**, selected a
DIB into its own memory DC, and `BitBlt`-presented 100 frame-varying fills while the
owning thread concurrently pumped and repainted (20 `WM_PAINT`s of its own). 100/100
succeeded in every run — no error, no corruption signal, no interaction with the owner's
queue. Rendering is where Win32 is _permissive_: the HWND→thread affinity binds the
message queue, not the surface. (The two writers do race for final pixel content — the
owner's `FillRect` and the worker's `BitBlt` interleave arbitrarily; correctness of
_what's shown_ still needs app-level ordering.)

### Probe 6 — input state is per-queue until `AttachThreadInput`

```text
10138 f17_win32 main action=SetFocus hwnd=00000000000A0076 get_focus=00000000000A0076
11120 f17_win32 thread=worker action=attach_probe before=0000000000000000 attach_ret=1 err=0 after=00000000000A0076
```

`GetFocus()` on the worker returned `NULL` while the main thread's own `GetFocus()`
returned its focused window — focus, like the queue, is **per-thread state**
([`GetFocus`][getfocus]: the calling thread's message queue). After
[`AttachThreadInput(worker, main, TRUE)`][attachthreadinput] the worker saw the main
thread's focus window; after detach the probe ended cleanly. Attach is the documented
(and notoriously global — it fuses the two queues' input state) way to share focus/
capture/active-window state across threads; a framework should treat it as a last
resort, not plumbing.

## Crash survival

Every child installs, before touching user32: the SEH filter (`result=crash` with the
exception code, then `ExitProcess(0)`) and a 15 s watchdog thread (`result=deadlock`,
`ExitProcess(0)`) — probe 4 re-arms a 3 s watchdog at the moment the deliberate
deadlock begins, so its verdict names the stage (`stage=p4b_send_to_blocked_thread`).
The driver waits each child with a 30 s cap and logs `child_exit probe=N run=R code=0`.
Nothing crashed in any run — but probe 4b _hangs by design_, and the machinery is what
makes "run the violation twice" a safe CI step.

## What a framework can promise on Win32 (vs X11/Wayland)

- **The narrowest contract across the three is Win32's**: _create and pump each window
  on one designated thread_ — not because creation off-main fails (it doesn't; probe 1
  creates fine), but because the creating thread is permanently the pumping thread.
  X11 has no per-thread affinity at all (any thread may pump, the `Display` is the
  unit); Wayland allows per-thread event queues on one connection. Win32 is the
  platform that forces the "one thread owns this window's events" shape — a
  cross-platform framework that promises exactly that runs unmodified on all three.
- **Render anywhere** holds on Win32 with no ceremony at all (probe 5) — easier than
  X11's flush-and-completion choreography.
- Cross-thread communication: prefer `PostMessage` (asynchronous, µs-scale);
  `SendMessage` only with `SendMessageTimeout` semantics in mind, and never from/to a
  thread that does hard kernel waits (probe 4b).

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f17-threading/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f17-threading.exe

# winewayland: needs a live Wayland socket; headless weston works
#   (in the default dev shell:  weston --backend=headless --socket=wsi-wl &)
XDG_RUNTIME_DIR=<runtime dir> WAYLAND_DISPLAY=wsi-wl \
    WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f17-threading.exe

# winex11 under Xvfb (WAYLAND_DISPLAY unset, private XDG_RUNTIME_DIR)
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) WINEPREFIX=$(mktemp -d) \
    WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop -c xvfb-run -a nix develop .#win32 -c wine64 ./build/f17-threading.exe
```

The no-argument run executes all six probes twice (~45 s, dominated by the deliberate
waits) and exits 0; `--probe=N` runs one probe once. The package's `dub.sdl`
(`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not part of
the pipeline.

## Sources

- [`./examples/f17-threading/app.d`](./examples/f17-threading/app.d) — the demo (all
  log excerpts above)
- [F17 spec][f17] — requirements implemented here; [X11 F17][x11-f17] — the
  structural sibling these results are contrasted against
- [Win32 scaffold findings][scaffold] — pump, build pipeline, instrument format
- [`GetMessageW`][getmessage], [`PeekMessageW`][peekmessage],
  [`SendMessageW`][sendmessage], [`PostMessageW`][postmessage],
  [`SendMessageTimeoutW`][sendmessagetimeout], [`DestroyWindow`][destroywindow],
  [`AttachThreadInput`][attachthreadinput], [`GetFocus`][getfocus],
  [`WM_PAINT`][wm-paint], [About Messages and Message Queues][aboutmsg] — Microsoft
  Learn (Wayback-pinned)

<!-- References -->

[f17]: ../features/f17-threading.md
[x11-f17]: ../x11/f17-threading.md
[scaffold]: ./scaffold.md
[manual-queue]: ../manual-run-queue.md
[getmessage]: https://web.archive.org/web/20260209042918/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessagew
[peekmessage]: https://web.archive.org/web/20260412100310/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-peekmessagew
[sendmessage]: https://web.archive.org/web/20260227013441/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessagew
[postmessage]: https://web.archive.org/web/20251115024504/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postmessagew
[sendmessagetimeout]: https://web.archive.org/web/20260226060028/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessagetimeoutw
[destroywindow]: https://web.archive.org/web/20260604001811/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-destroywindow
[attachthreadinput]: https://web.archive.org/web/20260219082947/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-attachthreadinput
[getfocus]: https://web.archive.org/web/20260416203913/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getfocus
[wm-paint]: https://web.archive.org/web/20260610093600/https://learn.microsoft.com/en-us/windows/win32/gdi/wm-paint
[aboutmsg]: https://web.archive.org/web/20260610104351/https://learn.microsoft.com/en-us/windows/win32/winmsg/about-messages-and-message-queues
[seh]: https://web.archive.org/web/20260330100815/https://learn.microsoft.com/en-us/windows/win32/api/errhandlingapi/nf-errhandlingapi-setunhandledexceptionfilter
