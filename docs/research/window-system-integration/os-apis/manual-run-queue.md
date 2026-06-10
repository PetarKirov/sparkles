# Manual-run queue

The single ordered checklist of every **Tier C** item from the
[windowing demo matrix](./feature-matrix.md) — grouped by machine/session so each environment
is visited once. Each entry carries: demo path, build command, steps, the expected
observation, and where to paste results (the demo's findings doc). Agents append entries
here; Petar checks them off.

**Last reviewed:** June 11, 2026

> [!NOTE]
> On the Mac, build with `nix develop -c ldc2 …` (not `dub` — it fork-ENOMEMs there); the
> verified command pattern is in the AppKit scaffold notes. `[wine]`-flagged Win32 items are
> re-confirmations of behavior already observed under Wine.

## Windows box

- [ ] Win32 F03 on real Windows: run `win32/examples/f03-modal-loop` (build per
      `win32/scaffold.md`) without `WSI_AUTO_EXIT`, with and without `WSI_MODAL_FIX=1`;
      drag titlebar + corner ~2 s each; expect freeze vs ~15.6 ms `src=timer` ticks. Also
      Alt+Space → S → arrows to check whether Wine's keyboard-mode early-exit reproduces.
      Paste the `modal_summary` lines into `win32/f03-modal-loop.md`.
- [ ] Win32 F04 on real Windows: run `win32/examples/f04-frame-pacing` with
      `WSI_AUTO_EXIT=1` (expect `path=dwm`, true vblank stats) and again with
      `WSI_FORCE_TIMER=1`; note monitor Hz and whether minimize changes the `DwmFlush`
      cadence. Paste both stats blocks into `win32/f04-frame-pacing.md`.

- [ ] Win32 F05 on real Windows: re-measure the wakeup-latency table and the
      waitable-timer tick distribution at 142 ms period (Wine's ±1 ms is tighter than
      Windows' default 15.6 ms timer-resolution quantization). Paste into
      `win32/f05-loop-wakeup.md`.
- [ ] Win32 F06 on real Windows: `LoadKeyboardLayoutW("00000407")` with real KBDGR
      tables — capture the Y/Z swap on injected scan 0x15/0x2c and the dead-acute
      (scan 0x0d) + E sequence (`WM_DEADCHAR 0x00b4` then `WM_CHAR 0x00e9`; the demo logs
      it as-is). Also confirm the `VK_PACKET` scancode field shows the UTF-16 unit's low
      byte. Paste into `win32/f06-keyboard.md`.

- [ ] Win32 F07 with Microsoft Pinyin: run `win32/examples/f07-text-input` without
      `WSI_AUTO_EXIT` and execute the 6-step script in `win32/f07-text-input.md`. Record:
      composition keydowns swallowed as `VK_PROCESSKEY`?, the cancel shape (zero-flag
      `WM_IME_COMPOSITION` vs Wine's bare `ENDCOMPOSITION`), focus-loss pre-edit fate,
      candidate-window position vs the logged `candidate_anchor x=`. Paste into
      `win32/f07-text-input.md`.
- [ ] Win32 F08 on mixed-DPI monitors: run `win32/examples/f08-dpi-scaling` without
      `WSI_AUTO_EXIT`, drag between 100% and 150%/200% monitors. Record the live
      `dpi_changed` sequence + ordering vs `WM_GETDPISCALEDSIZE`/`WM_SIZE`, hairline
      sharpness after the suggested-rect move, and whether the late
      `SetProcessDpiAwarenessContext` fails `ERROR_ACCESS_DENIED` (succeeds-but-noops
      under Wine). Paste into `win32/f08-dpi-scaling.md`.

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
- [ ] AppKit F03 interactive live-resize/title-drag: build
      `…/appkit/examples/f03-modal-loop/` per the scaffold notes (binary also staged at
      `/tmp/wsi-m2/f03-modal-loop/demo` on the mac). Run `./demo` with no env vars; drag
      the border, then the title bar, ~3 s each. Expect: color cycle never freezes
      (common-modes timer), `modal_enter`/`modal_exit` bracket the drag, the
      `tick timer=default` lines vanish during it with a post-drag `gap_ms` ≈ drag length,
      `draw … live_resize=1`. Paste into `appkit/f03-modal-loop.md`.
- [ ] AppKit F04 display-link cadence on a real display: run
      `…/appkit/examples/f04-frame-pacing/` (`/tmp/wsi-m2/f04-frame-pacing/demo`) in an
      unlocked GUI session. Expect `path=displaylink` at ~8.33 ms (120 Hz), `fell_back=0`;
      record whether fires pause during the 3 s `orderOut:` window. Paste into
      `appkit/f04-frame-pacing.md`.
- [ ] AppKit F07 real Pinyin IME: add the **Pinyin – Simplified** input source, run
      `…/appkit/examples/f07-text-input/` (`/tmp/wsi-m4/f07-text-input/demo`) with **no**
      env vars, click the window, type `nihao` + Space, `x` + Esc, then `ni` + focus
      switch — full keystroke script in `appkit/f07-text-input.md` § Tier C. Expect
      per-keystroke `tic_set_marked_text` (attributed string class?), **system-driven**
      `tic_first_rect` re-queries anchoring the candidate window, `tic_insert_text
text=你好` on Space, and the Esc/focus-loss fate of the pre-edit under a real IME.
      Also re-do option-e + e from the physical keyboard on the US layout. Paste into
      `appkit/f07-text-input.md`.
- [ ] AppKit F08 monitor drag across scales: attach a 1× external display, run
      `…/appkit/examples/f08-dpi-scaling/` (`/tmp/wsi-m4/f08-dpi-scaling/demo`) with no
      env vars in an unlocked session. First read `ctm when=drawRect` on the Retina screen
      (expect `a=2.00 d=-2.00`, falsifying the headless identity-CTM artifact), then drag
      to the 1× display and back — expect `window_backing_changed old_scale=…`,
      `backing_changed n=2/3`, a CTM re-log, and `buffer_alloc` tracking the pixel size;
      note the crossing point and hairline crispness. Also flip the built-in "looks like"
      resolution and record which notification fires. Full script in
      `appkit/f08-dpi-scaling.md` § Tier C. Paste into `appkit/f08-dpi-scaling.md`.

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
- [ ] Wayland F06 on a real seat (any Wayland session): re-run
      `wayland/examples/f06-keyboard` with a physical keyboard — live layout switch via
      compositor config (virtual keyboards carry their own keymap, so the headless run
      could not observe it), AltGr/`ISO_Level3` symbols, and per-device keymap behavior.
      Paste into `wayland/f06-keyboard.md`.
- [ ] Wayland F07 candidate-window visuals (GNOME + kimpanel, or KDE): run
      `wayland/examples/f07-text-input` on the real session with fcitx5+pinyin active,
      type `nihao` + space at both ends of the line, Esc mid-composition, then switch
      focus away mid-composition. Expect the doc's logged choreography plus a candidate
      window anchored at the caret rect. Paste into `wayland/f07-text-input.md`.
- [ ] X11 F03 interactive border/title drag (any real X11/XWayland session): build with
      `nix develop -c dub build
--root=docs/research/window-system-integration/os-apis/x11/examples/f03-modal-loop`,
      run `…/examples/f03-modal-loop/build/f03_modal_loop_x11` with no env vars.
      Border-drag-resize ~5 s, then title-bar-drag ~5 s; any key exits. Expected: the color
      cycle never freezes; `tick … gap_us=…` stays ~16 ms (nothing above ~50 ms) through
      both drags. Paste the max observed gap into `x11/f03-modal-loop.md` (findings table,
      "Interactive border/title drag" row).
- [ ] X11 F05 under a real compositing X server + load: re-run
      `x11/examples/f05-loop-wakeup` and compare the latency distributions against the
      Xvfb numbers (no vsync/compositor contention there; the 808 µs `ClientMessage` max
      likely grows). Paste into `x11/f05-loop-wakeup.md`.
- [ ] X11 F06 on real `de` hardware: AltGr/`ISO_Level3` symbols, multi-layout group
      switching (`grp:` options, nonzero `group=` field), and whether real input drivers
      emit per-device `XkbNewKeyboardNotify` storms like Xvfb's 3x. Paste into
      `x11/f06-keyboard.md`.

## KDE session (kwin)

_(no entries yet)_

## sway session

_(no entries yet)_
