# Platform × Feature Findings Matrix

The cross-platform grid for the [windowing demo feature specs](./features/): one cell per
platform per feature, each holding a verification-tier label, a one-line finding, and a link
to the full findings doc. Empty cells are demos not yet landed.

**Last reviewed:** June 10, 2026

Legend: **A** = agent-verified (**A[wine]** = under Wine — Wine is a reimplementation, not
Windows; **A[ssh]** = on `mac-bsn` over SSH — WindowServer-registration verified, on-screen
compositing not), **B** = compiled-for-target only, **C** = manual run pending/done,
**—** = N/A. Tier B/C expectations are `[expected, unverified]`, never stated as fact.

| Feature                           | Wayland | X11 | Win32 | macOS |
| --------------------------------- | ------- | --- | ----- | ----- |
| Scaffold: concepts-to-pixel / LOC |         |     |       |       |
| [F01 first pixel][f01]            |         |     |       |       |
| [F02 resize][f02]                 |         |     |       |       |
| [F03 modal loop][f03]             |         |     |       |       |
| [F04 frame pacing][f04]           |         |     |       |       |
| [F05 loop wakeup][f05]            |         |     |       |       |
| [F06 keyboard][f06]               |         |     |       |       |
| [F07 text input][f07]             |         |     |       |       |
| [F08 dpi scaling][f08]            |         |     |       |       |
| [F09 outputs][f09]                |         |     |       |       |
| [F10 pointer capture][f10]        |         |     |       |       |
| [F11 scroll][f11]                 |         |     |       |       |
| [F12 cursors][f12]                |         |     |       |       |
| [F13 decorations][f13]            |         |     | —     | —     |
| [F14 window state][f14]           |         |     |       |       |
| [F15 popup][f15]                  |         |     |       |       |
| [F16 clipboard + DnD][f16]        |         |     |       |       |
| [F17 threading][f17]              |         |     |       |       |

The X11 and macOS F13 cells are "N/A — SSD" by design (see the
[F13 spec](./features/f13-decorations.md)); their one-line customization-hook notes land in
the Wayland F13 findings doc's comparison section.

<!-- References -->

[f01]: ./features/f01-first-pixel.md
[f02]: ./features/f02-resize.md
[f03]: ./features/f03-modal-loop.md
[f04]: ./features/f04-frame-pacing.md
[f05]: ./features/f05-loop-wakeup.md
[f06]: ./features/f06-keyboard.md
[f07]: ./features/f07-text-input.md
[f08]: ./features/f08-dpi-scaling.md
[f09]: ./features/f09-outputs.md
[f10]: ./features/f10-pointer-capture.md
[f11]: ./features/f11-scroll.md
[f12]: ./features/f12-cursors.md
[f13]: ./features/f13-decorations.md
[f14]: ./features/f14-window-state.md
[f15]: ./features/f15-popup.md
[f16]: ./features/f16-clipboard-dnd.md
[f17]: ./features/f17-threading.md
