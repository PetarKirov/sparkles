# F17 — Threading probes

Deliberately violate each platform's threading rules and record exactly what breaks and how
it manifests — error code, exception, deadlock, or silent corruption. Frameworks inherit
their threading model from the strictest platform; this row supplies the evidence.

## Requirements

Each probe is a separate run mode (`--probe=N`), each ending in a logged verdict
(`probe n=… result=ok|error|crash|deadlock|silent detail=…`):

1. **Create a window off the main thread** (events pumped on main):
   - macOS is the anchor: AppKit asserts/undefined behavior off the main thread — capture
     the exact console assert (`NSWindow should only be instantiated on the main thread!`?).
     Also probe with `NSApplicationLoad`-style legacy escape hatches absent.
   - Win32: legal — but the creating thread owns the message queue; prove `GetMessage` on the
     other thread receives its messages and the main thread does not.
   - X11: legal with `XInitThreads()` — probe with AND without it; record the corruption mode
     without (the classic async reply error).
   - Wayland: `wl_display` is thread-safe by design (per-thread event queues) — prove a
     second-thread `wl_event_queue` works; record the rules.
2. **Pump events on a non-creating thread** (where distinguishable from probe 1).
3. **Render from a second thread while events flow on the main one**: CPU-fill the buffer on
   a worker and present from it — Wayland (`wl_surface.commit` from worker with its own
   queue), X11 (`XShmPutImage` from worker, with `XInitThreads`), Win32 (`BitBlt` from a DC
   acquired on the worker), macOS (`lockFocusIfCanDraw`-free path: draw into a buffer +
   `setNeedsDisplay` marshaled vs direct `CGContext` access — record what the docs forbid vs
   what observably happens).
4. Run every probe twice; flaky/probabilistic outcomes (race-dependent) must be marked
   `result=nondeterministic` with both observed outcomes.

> [!WARNING]
> Crashes are expected outcomes here. Every probe must still exit through a handler that
> flushes the instrumentation log (install signal/SEH/uncaught-exception hooks), so the
> verdict line survives the crash.

## Instrumentation

`probe n=… thread=… action=…` around every cross-thread call; the final verdict line per
probe.

## Findings to record

- A platform × probe outcome table (this is the `design-constraints.md` threading section).
- The exact failure artifacts (assert text, `BadAccess`-style codes, HRESULTs) with log
  excerpts.
- The narrowest safe contract a framework can promise on all four platforms (expected:
  "create and pump on one designated thread; render anywhere with platform-specific
  ceremony" — verify or refute).

## Verification

Wayland/X11: Tier A. Win32: `A[wine]` — but Wine's threading implementation diverges from
real user32 internals; re-confirm any surprising Win32 outcome on real Windows (manual
queue). macOS: `A[ssh]` — the assert-on-spawn outcomes don't need a visible window.
