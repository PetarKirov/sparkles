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

## GNOME session (mutter)

_(no entries yet)_

## KDE session (kwin)

_(no entries yet)_

## sway session

_(no entries yet)_
