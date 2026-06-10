# F03 — Modal-loop survival

On Win32, entering interactive resize/move (`WM_ENTERSIZEMOVE`) traps the thread in a system
modal loop and your message pump stops being yours; on macOS, live-resize runs the run loop in
a special mode. An animation that freezes during resize is the visible symptom. This demo
proves continuous animation through interactive resize **and** title-bar drag on every
platform, and documents the per-platform technique required.

## Requirements

1. Animate a full-window color cycle (~2 Hz) driven by the frame clock from F04's mechanism or
   a timer; log a `frame_callback`/`tick` event per frame with timestamps.
2. Prove animation continues during (a) interactive border resize and (b) title-bar drag: the
   inter-frame deltas in the log must stay bounded during the interaction.
3. **Win32 (the headline):** defeat the modal loop. Implement at least one technique and
   document the alternatives considered: `SetTimer` + `WM_TIMER` ticks inside the modal loop,
   rendering on `WM_ERASEBKGND`/`WM_NCPAINT`, a render thread that paints independently of the
   pumping thread, or `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` bracketing with a timer fallback.
4. **macOS:** handle live-resize (`viewWillStartLiveResize`/`viewDidEndLiveResize`,
   `NSRunLoop` common modes for timers) so animation continues while dragging.
5. **Wayland/X11:** confirm (and log) that no modal loop exists — interactive resize is just
   more events; that asymmetry is itself the finding.

## Instrumentation

`tick t=…` per animation frame; `modal_enter`/`modal_exit` (Win32, macOS live-resize
equivalents); the standard resize events from F02.

## Findings to record

- Max inter-frame gap during interaction, per platform (from the logs).
- The chosen Win32 technique, the alternatives, and their trade-offs (cite the relevant
  Microsoft Learn pages and known framework workarounds).
- Which thread the modal loop captures, and what that means for a frameworks' loop ownership.

## Verification

Interactive drag cannot be automated honestly: Wayland/X11 runs under headless compositors
prove the no-modal-loop half (Tier A); the Win32/macOS halves are Tier C with a precise
manual script. `A[wine]` runs of the Win32 demo are evidence Wine reproduces the modal loop,
not that Windows behaves identically — label accordingly.
