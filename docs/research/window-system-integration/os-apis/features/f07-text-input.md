# F07 — IME / text input

The hardest row in the matrix. Composed text input (CJK, and increasingly emoji/voice input)
arrives through a second, stateful channel that must be interleaved with raw key events:
pre-edit strings, candidate windows anchored to the caret, commit/replace semantics. Every
platform has a different protocol; several have two.

## Requirements

1. Render an editable line of text with a visible caret. Display the **pre-edit string
   inline** at the caret with underline styling, distinct from committed text.
2. Report the **cursor rectangle** to the IME so the candidate window anchors to the caret
   (and re-report as the caret moves — prove it by typing at both ends of a long line):
   - Wayland: `zwp_text_input_v3` — `set_cursor_rectangle`, handle `preedit_string`,
     `commit_string`, `delete_surrounding_text`; `enable` on focus.
   - Win32: **TSF** (`ITfThreadMgr`/`ITextStoreACP`) — if the COM surface proves impractical
     from plain D within the budget, fall back to IMM32 (`WM_IME_COMPOSITION`,
     `ImmSetCandidateWindow`) and document precisely _why_ TSF was impractical.
   - macOS: implement `NSTextInputClient` on the view (`setMarkedText:…`,
     `firstRectForCharacterRange:…`, `insertText:replacementRange:`).
   - X11: XIM (`XOpenIM`, `XCreateIC` with `XIMPreeditPosition`) — document its pathologies
     (synchronization, server restarts, locale coupling) first-hand.
3. Handle the full lifecycle: focus in/out mid-composition (what happens to the pre-edit?),
   commit, cancel (Esc), and replacement of surrounding text.
4. Log every IME event with payloads (`preedit text=… cursor=…`, `commit text=…`,
   `delete_surrounding before=… after=…`).

## Findings to record

- The event choreography per platform for: typing "nihao" + space with a Pinyin IME; cancel
  mid-composition; focus loss mid-composition.
- How key events and text events interleave (which key events are swallowed).
- Candidate-window positioning units (logical vs physical — feeds F08).
- The TSF-vs-IMM32 decision record (or the COM bring-up notes if TSF worked).

## Verification

Tier C is the truth for this row — it needs a real CJK IME (fcitx5/ibus on Linux, the
built-in Pinyin IME on Windows/macOS). Each demo ships a precise manual script (input method
to enable, keystrokes, expected pre-edit/commit logs). Agent-side (Tier A) verification is
limited to: the protocol handshake under headless weston (`zwp_text_input_v3` advertised?),
XIM bring-up under Xvfb with `XMODIFIERS=@im=none` fallback behavior, and compile-level
correctness elsewhere. Budget note: this row gets the strongest agents.
