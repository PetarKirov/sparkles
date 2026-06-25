# Windowing demo feature specs

Specs for the per-platform demo programs that empirically map where **Wayland, X11, Win32,
and macOS (AppKit)** diverge. Each spec is platform-neutral: one demo per platform implements
it (in `<platform>/examples/fXX-<slug>/`), and the observed behavior lands in a findings doc
next to that platform's survey (`<platform>/fXX-<slug>.md`). The cross-platform grid lives in
the [feature matrix](../feature-matrix.md); items needing a human run are queued in the
[manual-run queue](../manual-run-queue.md).

**Last reviewed:** June 10, 2026

| ID                              | Feature                            | Why it discriminates                              |
| ------------------------------- | ---------------------------------- | ------------------------------------------------- |
| [F01](./f01-first-pixel.md)     | First pixel & init cost            | Concepts-to-pixel count; round-trips vs local     |
| [F02](./f02-resize.md)          | Resize correctness                 | Notification vs negotiation (ack-configure)       |
| [F03](./f03-modal-loop.md)      | Modal-loop survival                | Win32 `WM_ENTERSIZEMOVE`; macOS live-resize       |
| [F04](./f04-frame-pacing.md)    | Vsync / frame pacing               | Four different frame clocks                       |
| [F05](./f05-loop-wakeup.md)     | Loop wakeup & external fds         | fd-readiness vs handle waits vs run-loop sources  |
| [F06](./f06-keyboard.md)        | Keyboard & keymap                  | Who owns `xkb` state; client-side repeat          |
| [F07](./f07-text-input.md)      | IME / text input                   | Pre-edit/commit choreography; TSF vs IMM32 vs XIM |
| [F08](./f08-dpi-scaling.md)     | DPI / runtime rescale              | Logical vs physical; X11's missing mechanism      |
| [F09](./f09-outputs.md)         | Output enumeration & hotplug       | Surface↔output knowledge; hotplug order          |
| [F10](./f10-pointer-capture.md) | Pointer: relative + lock + confine | Async-failable lock; macOS's missing confine      |
| [F11](./f11-scroll.md)          | Scroll fidelity                    | `axis_v120` / sub-120 deltas / momentum phases    |
| [F12](./f12-cursors.md)         | Cursors                            | Client-composited cursors on Wayland              |
| [F13](./f13-decorations.md)     | CSD & decoration modes             | Wayland-only; the largest "app's problem" fork    |
| [F14](./f14-window-state.md)    | Window state & vetoable close      | State echo vs fire-and-forget; veto contracts     |
| [F15](./f15-popup.md)           | Popup with grab                    | Declarative positioner vs app-computed geometry   |
| [F16](./f16-clipboard-dnd.md)   | Clipboard + file DnD               | Format negotiation; INCR; delayed rendering       |
| [F17](./f17-threading.md)       | Threading probes                   | What actually breaks, and how it manifests        |

F01–F08 are the discriminating core (first wave); F09–F17 are the second wave. Every demo
follows the shared conventions: scaffold copied from `<platform>/examples/scaffold/`, the
`instrument.d` log format from [F01](./f01-first-pixel.md), and the verification-tier labels
defined in the [matrix](../feature-matrix.md) legend.

## Example Directories

Browse the source code folders for all demo implementations across platforms:

- **Wayland Examples**: [`wayland/examples/`](../wayland/examples/)
- **X11 Examples**: [`x11/examples/`](../x11/examples/)
- **Windows (Win32) Examples**: [`win32/examples/`](../win32/examples/)
- **macOS (AppKit) Examples**: [`appkit/examples/`](../appkit/examples/)

<!-- References -->
