# `sparkles:wsi` — Open issues

_Only unresolved design or evidence questions live here. Accepted decisions belong in
[SPEC.md](./SPEC.md); delivery order belongs in [PLAN.md](./PLAN.md)._

**Last reviewed:** August 20, 2026

| ID     | Question                                                                                                                               | Why it remains open                                                                                                                                                    | Decision point                            |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| WSI-O1 | What is the smallest Event Horizon primitive that lets Win32 messages and AppKit's owned run loop share the scheduler without polling? | Linux foreign-fd integration already has a specified path. IOCP and kqueue exist, but the native-host attachment needs a real spike before its exact API is normative. | M2; update both specs before M3           |
| WSI-O2 | Should X11 use one Xlib-created display shared with XCB for XIM, or a pure XCB connection plus a separately integrated XIM strategy?   | XIM remains the practical desktop baseline, but accidentally owning two event queues would violate the one-loop contract.                                              | M2 X11 spike                              |
| WSI-O3 | Which bounded storage policy holds arbitrarily long IME pre-edit and clipboard MIME metadata while keeping `WindowEvent` Regular?      | Existing inline key text is intentionally small; composition can be much larger. A ref-counted/arena-backed value needs explicit lifetime and allocation behavior.     | M1 input changes                          |
| WSI-O4 | Which Wayland CSD renderer owns the bootstrap frame before Skia Graphite exists?                                                       | WSI must not draw, yet GNOME requires CSD before M7. A minimal protocol/hit-region harness can prove semantics without pretending to be the final renderer.            | M3 Wayland first-pixel slice              |
| WSI-O5 | Which native frame signals are sufficiently reliable to drive continuous animation on Win32 and AppKit?                                | DWM timing and display-link APIs report different lifecycle/occlusion semantics. The common event is decided; source selection needs measurement.                      | M2/M3 pacing spikes                       |
| WSI-O6 | How much of clipboard/DnD transfer belongs in WSI versus an Event Horizon stream helper?                                               | Platform negotiation is WSI-owned, but large transfer backpressure should reuse the loop without turning `WindowEvent` into an I/O handle grab bag.                    | M5 design review                          |
| WSI-O7 | Does `full` in `ui-app` link all GUI backends simultaneously or expose mutually exclusive child configurations?                        | Simultaneous native/SDL/raylib symbols and platform closures may be too large for production while useful in Gallery and parity tests.                                 | M8 configuration spike                    |
| WSI-O8 | What native Windows CI provider and IME automation can certify behavior Wine cannot?                                                   | Wine is intentionally the local compatibility lane and supports IMM32 well, but it is not native evidence for DWM, raw input, accessibility or all IMEs.               | before marking Win32 `F01`–`F17` verified |

## Closed decisions

| Decision                      | Resolution                                                             |
| ----------------------------- | ---------------------------------------------------------------------- |
| Package name                  | `sparkles:wsi`                                                         |
| Desktop backends              | native Wayland, X11, Win32 and AppKit                                  |
| Cross-platform WSI dependency | none in the native core                                                |
| Loop ownership                | one integrated Event Horizon loop                                      |
| Win32 first IME               | IMM32; TSF is deferred behind native Graphite and `ui-app` integration |
| Wayland decorations           | request SSD; renderer-drawn CSD fallback; no libdecor hard dependency  |
| Native renderer API           | typed closed native-handle sum                                         |
| SDL                           | explicit compatibility package/configuration only                      |
