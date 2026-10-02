# Testing: oracles and the evidence ledger

_**Date:** 2026-10-02 · The one evidence ledger for this tree's `TCF`, `TSP`,
`TKM`, `TPR`, `TPG`, `TSE` and `TSS` rows (the Android page keeps its own
verification table for `NOD`)._

## Oracles

| Class            | Oracle (independent of the implementation)                                                                                                      | Covers                                   |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| Configuration    | hand-written fixtures per layer with the expected resolved value; a malformed file with its expected location                                   | `TCF`                                    |
| Key table        | `bindingsAt` vs `resolve` agreement (the toolkit's `KEY` test); a static scan for `KBD3` keys; a recording pty swept over the encoder's key set | `TKM`                                    |
| Protocol bytes   | input and reply bytes transcribed from each authority ([protocols](./protocols.md#authorities)), never produced by our own encoder              | `TPR`                                    |
| Hostile input    | injection fixtures: controls in titles, a closing bracket inside a paste, oversized OSC payloads, a `javascript:` OSC 8 URI                     | `TPR2`, `TPR6`, `TPR8`, `TPR18`, `TPR20` |
| Secrets stay put | a marker typed, pasted, autofilled (fake service) and copied; then searched for in the log ring, the log file, `keys.txt` and the clipboard     | `TPG6`, `TSE9`                           |
| Rendering        | `RecordingCanvas` / `--render` of each surface: slot declarations, the monochrome profile, a theme swap compared with a cold render             | every surface ([design](./design.md))    |
| Placement        | property tests over the menu placement: flip at the top, slide at the sides, never inside the keyboard inset                                    | `TSE6`                                   |
| Device           | the screen and key oracles ([NOD14](./android.md#requirements)), screenshots, `dumpsys notification`, on the Xiaomi 11T Pro (arm64)             | Android rows                             |
| Desktop          | `--debug-take-screenshot-and-exit` under xvfb; a real session for D-Bus notifications and the portal's scheme                                   | desktop rows                             |

Skipped or unavailable checks are not passes; a row stays `partial` naming
the missing configuration.

## Evidence ledger

| Date | Rows | Revision | Command / scenario | Configuration | Result | Remaining gap |
| ---- | ---- | -------- | ------------------ | ------------- | ------ | ------------- |

_No evidence yet: the tree was written on 2026-10-02 at `988a48257`._

→ [Overview](./index.md) · [Delivery plan](./PLAN.md)
