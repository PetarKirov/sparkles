# F16 — Clipboard + file drag-and-drop

Both are _format negotiation between processes_ — the same machinery on Wayland/X11, two
unrelated APIs elsewhere. The negotiation sequences, not the happy path, are the deliverable.

## Requirements

1. **Copy:** a key copies UTF-8 text (with a non-ASCII char — `é漢🎈`) to the clipboard;
   verify by pasting into another app (Tier C) and a companion CLI (Tier A:
   `wl-paste`/`xclip`; Win32: a second tiny D reader; macOS: `pbpaste`).
   - Wayland: `wl_data_source` offering `text/plain;charset=utf-8` (+`text/plain`), serve the
     `send` fd; log `cancelled` (clipboard ownership loss).
   - X11: own `CLIPBOARD`, answer `SelectionRequest` with `TARGETS` + `UTF8_STRING`;
     implement **INCR sending** for a >256 KiB payload too.
   - Win32: `OpenClipboard`/`SetClipboardData(CF_UNICODETEXT)` **plus delayed rendering**
     (`SetClipboardData(fmt, NULL)` + `WM_RENDERFORMAT`) — log when rendering is demanded.
   - macOS: `NSPasteboard` `setString:forType:` + `NSPasteboardItem` lazy provider variant.
2. **Paste:** a key reads the clipboard from another app, logging the offered
   formats/targets first, then the chosen one and byte count. X11: implement **INCR
   receive** (paste ≥1 MiB from another app; `xclip` can serve it).
3. **File drop:** accept a file dragged from the system file manager (Tier C) and from a
   scripted source where possible; log the full negotiation: enter (offered MIME
   types/formats), position feedback, accept/reject signaling, drop, data transfer, finish:
   - Wayland: `wl_data_device` events, `accept` + `set_actions`/`finish` (dnd actions).
   - X11: XDND protocol messages (`XdndEnter`…`XdndFinished`) — implement by hand.
   - Win32: `RegisterDragDrop` + `IDropTarget` (COM) with `CF_HDROP`.
   - macOS: `registerForDraggedTypes:` + `NSDraggingDestination` with file-URL type.
4. Clean ownership handling: copy, then another app copies — log the loss event per platform.

## Instrumentation

`clip_offer formats=[…]`, `clip_request fmt=…`, `clip_send bytes=… incr=0|1`,
`dnd_enter formats=[…]`, `dnd_drop fmt=… bytes=…`, `ownership_lost`.

## Findings to record

- The negotiation sequence diagrams (these feed `event-sequences.md`).
- Lazy/delayed rendering support per platform and who pays when the source exits first.
- INCR's design and its failure modes, observed first-hand.
- Whether clipboard and DnD share machinery (and what that means for a framework's data API).

## Verification

Wayland/X11: Tier A with companion CLI tools (`wl-clipboard`, `xclip` from nixpkgs) under
headless weston/Xvfb. Win32: `A[wine]` within one prefix (two Wine processes can exchange
clipboard); cross-app with real Windows apps is Tier C. macOS: `A[ssh]` via
`pbcopy`/`pbpaste`; Finder drag is Tier C.
