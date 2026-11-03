---
status: accepted
owner: sparkles:ui-app
reviewed: 2026-11-03
---

# Font preview and the text lab

## Abstract

The text lab previews exact font faces and their variation axes while its
interface remains usable in a stable font. Font discovery and file loading run
in the background, settings use shared generated controls, and prepared font
changes are measured against a sixty-frame-per-second interaction budget.

## Introduction

A font preview must distinguish its selected face from sibling and fallback
faces. It must also keep the controls used to select a font usable when a
proportional, unusually wide, or very large face is chosen. The native host
therefore owns independent interface and specimen contexts. The toolkit owns
numeric editing and section interaction, and the application owns catalog
sources, selection policy, and session history.

## Contract

- A selection names a file and collection member. The selected face survives
  scale and surface changes. A failed selection preserves the last complete
  specimen and reports its failure.
- The interface font is stable by default. An explicit option follows the
  specimen's typography and rendering settings; F12 restores stable interface
  typography. Drag geometry remains fixed until release.
- The picker searches catalog family, style, and PostScript names through
  `sparkles:fuzzy`, highlights its witnesses, and consumes typed input while
  open. Esc/Back closes the innermost editor before the settings sheet.
- Every declared non-hidden variable axis is editable within its own range;
  hidden axes are available through an option. Reset uses declared defaults.
  Session values are remembered per face. Automatic optical size follows the
  displayed point size within its declared bounds.
- Naturally shaped specimen layout is the default. Cell-grid comparison and
  explicit family sibling substitution are options. Fallback text is marked.
- Terminal and text-lab numeric editing share the toolkit's settings section
  controller. Input UDAs suggest sliders, counters, or numeric text fields;
  runtime metadata governs both presentation and edit validation.
- Discovery and cold file reads use Event Horizon workers with bounded queues
  and retained ownership. Only the latest requested selection may publish.
  Shutdown waits for workers before releasing their data.
- Prepared size/axis changes and prepared face switching target a fresh
  specimen each frame at 60 Hz on recorded desktop and Android reference
  devices, including interface-follow mode. Cold file loading is reported
  separately. Sustained sweeps must measure frame time, request-to-visible
  latency, cache pressure, and memory use.

Persistence and a named-instance picker are outside this contract.

## Run and verify

```bash
dub run :text-lab -- --settings
dub run :text-lab -- --picker
dub run :text-lab -- --font /path/to/variable.ttf --font-variation wght=700,opsz=24 --settings --shot /tmp/variable.png
dub run :text-lab -b checked -- --font /path/to/variable.ttf --sweep-frames 240 --debug trace-frames --debug frame-trace=/tmp/font-sweep.json
dub run --single libs/ui-app/examples/specimen-font-benchmark.d -b checked
```

The CPU benchmark covers preparation, binding, and first-use rasterization.
It excludes device upload and presentation. The native sweep covers the
application's real frames; presentation latency is available only when the
window system supplies feedback. The profiler's ordinary hitch threshold is
1.5 refresh intervals, so the preview separately counts 16.67 ms deadline
misses.

The shared contracts are documented in
[numeric property editors](../../libs/ui/reference/numeric-editors.md) and
[specimen font hosting](../../libs/ui-app/reference/specimen-fonts.md).

## Recorded desktop baseline

The 2026-11-03 checked build used LDC 1.43, a Ryzen 9 7940HX, Radeon RX Vega
(RADV, Mesa 25.2.6), and X11. A 240-update Noto Sans sweep changed size and
declared coordinates each frame, with the real multilingual specimen and
fallbacks. Other compiler jobs were active on the machine.

| Mode                       | CPU p50 | CPU p95 | CPU p99 | GPU p95 | Peak reported device memory |
| -------------------------- | ------: | ------: | ------: | ------: | --------------------------: |
| Stable interface           | 1.95 ms | 5.52 ms | 6.38 ms |  0.3 ms |                    41.9 MiB |
| Interface follows specimen | 2.17 ms | 6.38 ms | 9.14 ms |  0.3 ms |                    41.9 MiB |

Each run recorded 241 font submissions, including cold setup, with one
request-to-submit measurement over 16.67 ms. X11 supplied no observed-display
timestamps; these numbers do not establish input-to-display latency. The
Wayland compositor reported the test window suspended, so a paced Wayland run
could not be measured in that session. No Android reference device was
connected; the APK cross-build and device performance gate are separate checks.

The earlier size-only probe repeatedly resolved and loaded the same primary,
styled, and fallback files: warm steps took 150–167 ms before rendering. The
cached checked path, including cell-face binding, measured 0.129 ms at p95.
The isolated specimen benchmark measured 0.501 ms at p95 including primary
ASCII atlas misses; its exclusion of uploads and presentation is intentional.

## Recorded Android validation

The 2026-11-04 device check used a Xiaomi 11T Pro (`2107113SG`, Android 14),
with a 1080 × 2400 display in its 120 Hz mode. Tests used ADB touch and key
injection against the checked APK. The battery reported 15%, 50°C, and
Android thermal status 0 throughout the final samples.

The initial APK terminated during background catalog discovery: Android app
seccomp killed the `openat2` capability probe. The syscall boundary now
reports that resolver unavailable on Android, so the VFS uses its existing
component walk. The Android regression test and 22 desktop VFS tests passed.

Device checks passed for launch, background discovery, fuzzy filtering and
acceptance, static/variable axis visibility, live weight dragging, undo,
vertical sheet scrolling without slider changes, exact size entry, the soft
keyboard lifecycle, UI-follow mode, F12 recovery, and home-screen resume.
Corrections also separate touch capabilities from host gesture recognition,
defer touch activation until release, use toolkit hit testing for nested
controls, and hide the loupe while the picker is open. The affected suites
passed all 21 text-lab and 139 UI App tests.

Two 1.8-second Noto Sans weight drags used the stable interface and the open
settings sheet. SurfaceFlinger supplied actual presentation timestamps for
the app layer; its history was cleared before each drag. All positive
consecutive intervals were included, excluding zero/unavailable timestamps.

| Drag    | Intervals | Mean presented frames/s | Interval p50 | Interval p95 | Worst interval | Intervals >17 ms |
| ------- | --------: | ----------------------: | -----------: | -----------: | -------------: | ---------------: |
| Forward |       104 |                   58.39 |     16.50 ms |     24.61 ms |       41.18 ms |                7 |
| Reverse |       105 |                   58.15 |     16.50 ms |     24.74 ms |       24.77 ms |               11 |

These short presentation samples leave the sustained-60 performance gate
open. They neither isolate font preparation from rendering and scheduling
nor establish input-to-display latency; further on-device profiling is
required before attributing the missed deadlines.

The subsequent [120 fps profiling report and proposed implementation order](../../libs/ui-app/explanation/font-preview-performance.md)
separate repeated shaping, rasterization, settings work, GPU time, and
scheduler waits on the same device.
