# Manual-run queue

The single ordered checklist of every **Tier C** item from the
[windowing demo matrix](./feature-matrix.md) — grouped by machine/session so each environment
is visited once. Each entry carries: demo path, build command, steps, the expected
observation, and where to paste results (the demo's findings doc). Agents append entries
here; Petar checks them off.

**Last reviewed:** June 10, 2026

> [!NOTE]
> On the Mac, build with `nix develop -c ldc2 …` (not `dub` — it fork-ENOMEMs there); the
> verified command pattern is in the AppKit scaffold notes. `[wine]`-flagged Win32 items are
> re-confirmations of behavior already observed under Wine.

## Windows box

_(no entries yet)_

## Mac (`mac-bsn`, unlocked GUI session)

- [ ] One-time: unlock the screen during a demo run so `CGWindowListCopyWindowInfo` reports
      `onscreen=true`, and grant Screen Recording TCC to `screencapture` for visual capture.
      Paste results into the AppKit scaffold findings.
- [ ] AppKit F02 interactive live-resize: build
      `docs/research/window-system-integration/os-apis/appkit/examples/f02-resize/` per the
      scaffold notes (`nix develop -c ldc2 …`, not dub), run `./demo` with **no** env vars in
      an unlocked GUI session, drag the window border for a few seconds, then close the
      window. Expected on stderr: `live_resize_start` → repeated `resize`/`frame_callback`
      pairs at drag cadence → `live_resize_end` (all three are absent under the programmatic
      storm). Paste the sequence into `appkit/f02-resize.md`.

## GNOME session (mutter)

- [ ] Wayland F03 — interactive drag continuity (also run in the KDE and sway sections
      below): `dub run
--root=docs/research/window-system-integration/os-apis/wayland/examples/f03-modal-loop`
      (no `WSI_AUTO_EXIT`). Drag the window by its title bar ≥5 s, then drag an edge to
      resize ≥5 s. Expect: uninterrupted ~2 Hz color cycling, the `tick … dt_us=…` stream
      bounded near the display's frame period throughout, `resizing=1` in the configure
      lines during the edge drag, `modal_enter=0 modal_exit=0` in the exit summary. Any
      tick gap far beyond one frame period during the drag falsifies the no-modal-loop
      finding. Paste into `wayland/f03-modal-loop.md`.

## KDE session (kwin)

_(no entries yet)_

## sway session

_(no entries yet)_
