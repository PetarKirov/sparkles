# Win32 F16 — clipboard + drag-and-drop

Findings from [`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d),
the Win32 implementation of the [F16 spec][f16]: an immediate `CF_UNICODETEXT` copy of
`é漢🎈` plus the **delayed-rendering** protocol (`SetClipboardData(fmt, NULL)` →
[`WM_RENDERFORMAT`][wm-renderformat] on demand, [`WM_RENDERALLFORMATS`][wm-renderallformats]
at owner destruction), cross-process readers (`--reader` children in the same prefix),
ownership loss ([`WM_DESTROYCLIPBOARD`][wm-destroyclipboard]) and the modern listener
([`AddClipboardFormatListener`][addlistener] → `WM_CLIPBOARDUPDATE`), host-clipboard
bridging probes against `wl-paste`/`xclip`, and **OLE drag-and-drop with hand-declared
COM vtables** — an in-process [`DoDragDrop`][dodragdrop] of a `CF_HDROP` file list onto
the window's own [`RegisterDragDrop`][registerdragdrop]'d `IDropTarget`, full
negotiation logged. Headline answers: delayed rendering is **demand-driven and
per-promise** (one `WM_RENDERFORMAT` per `GetClipboardData`, in-thread or cross-process
alike), the whole OLE DnD negotiation **works headless under Wine** down to
`DRAGDROP_S_DROP`, and clipboard bridging to the host is **winex11-only** in this Wine —
two-way under X11, absent under winewayland.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — Wine 10.0, exe cross-compiled by LDC
> 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Two passes per driver: **winewayland**
> (headless weston 15, then sway 1.11 for the seat-dependent bridging probes) and
> **winex11** under `xvfb-run`. All clipboard/DnD protocol behavior was identical
> across drivers; only the host-bridging legs differ (by design — that _is_ the
> driver). Real-Windows confirmation of the delayed-rendering timings and the OLE
> negotiation rides the [manual-run queue][manual-queue].

---

## Copy: the `GMEM_MOVEABLE` contract and what Windows synthesizes

The immediate copy is the classic sequence — `OpenClipboard(hwnd)` /
`EmptyClipboard()` / `SetClipboardData(CF_UNICODETEXT, hMem)` / `CloseClipboard()` —
where `hMem` must be a [`GlobalAlloc(GMEM_MOVEABLE, …)`][globalalloc] handle and, per
[`SetClipboardData`][setclipboarddata], "if `SetClipboardData` succeeds, the system owns
the object identified by the `hMem` parameter" — the app must neither free nor reuse it.
The payload is `é漢🎈` (4 UTF-16 units incl. one surrogate pair, +NUL = 10 bytes):

```text
206328 f16_win32 clip_send fmt=CF_UNICODETEXT bytes=10 delayed=0 ok=1 owner=0000000000050050
207072 f16_win32 clip_offer who=owner_readback n=4 formats=[CF_UNICODETEXT,CF_LOCALE,CF_TEXT,CF_OEMTEXT] seq=4
207734 f16_win32 clip_read who=owner_readback fmt=CF_UNICODETEXT bytes=10 wchars=4 payload_match=1
208205 f16_win32 clip_update msg=WM_CLIPBOARDUPDATE seq=4 owner=0000000000050050
```

- **One format in, four out.** [`EnumClipboardFormats`][enumclipboardformats] after the
  copy lists `CF_UNICODETEXT,CF_LOCALE,CF_TEXT,CF_OEMTEXT` — the system's automatic
  conversions ([standard clipboard formats][stdformats]: setting one text format makes
  the others available as synthesized formats, with `CF_LOCALE` describing the
  conversion locale). A paste implementation must expect formats nobody explicitly set.
- **The sequence number moves in steps of 4 under Wine** (`seq=4,8,12,16` across the
  phases) — one bump per store including the synthesized entries; treat
  `GetClipboardSequenceNumber` as opaque-monotonic, not a counter of copies.
- **The clipboard-viewer chain, modern edition: Wine delivers it.**
  [`AddClipboardFormatListener`][addlistener] returned 1 and every ownership change —
  including the demo's own copies — produced a [`WM_CLIPBOARDUPDATE`][wm-clipboardupdate]
  in the pump (4 in a full run). No need for the legacy `SetClipboardViewer` chain.

**Cross-process, same prefix** ([spec][f16] Tier `A[wine]`): a spawned `--reader`
process enumerated the same 4 formats and read the payload back intact —
`clip_read who=reader fmt=CF_UNICODETEXT bytes=10 wchars=4 payload_match=1` — two Wine
processes share one wineserver clipboard exactly like two apps on one Windows session.

## Delayed rendering: demand-driven, measured

`SetClipboardData(CF_UNICODETEXT, NULL)` lodges the _promise_; the data is produced
only when the owner receives [`WM_RENDERFORMAT`][wm-renderformat] ("sent to the
clipboard owner if it has delayed rendering a specific clipboard format and if an
application has requested data in that format"). Two demand paths, both measured:

```text
 974229 f16_win32 clip_send fmt=CF_UNICODETEXT bytes=0 delayed=1 ok=0
1275530 f16_win32 thread=demand action=GetClipboardData t=1275529
1276098 f16_win32 clip_request msg=WM_RENDERFORMAT fmt=0x000d demand_n=1 us_since_delayed_set=301868
1276761 f16_win32 clip_send fmt=CF_UNICODETEXT bytes=10 delayed_render=1
1277118 f16_win32 clip_read who=demand_thread fmt=CF_UNICODETEXT bytes=10 wchars=4 payload_match=1
```

- **Rendering is demanded at `GetClipboardData` time, not at copy time.** The promise
  sat unrendered for 300 ms (the reader thread's deliberate delay); `WM_RENDERFORMAT`
  arrived ~0.6 ms after the demand — and the same held **cross-process**: a second
  delayed promise was demanded by a spawned `--reader`, producing `demand_n=2
us_since_delayed_set=169703` (the gap = reader process startup). The reader's
  `GetClipboardData` blocks while the owner's pump renders — a slow/hung owner stalls
  every paster in the session.
- **Once rendered, the data is cached** — the reader's subsequent reads (and the format
  enumeration before the demand) triggered no further `WM_RENDERFORMAT`; each fresh
  promise costs exactly one render per format.
- **Gotcha, observed:** for delayed rendering `SetClipboardData(fmt, NULL)` **returns
  `NULL` on success** (the demo logs `ok=0` + `err=0`) — `NULL`-is-failure checking
  must consult `GetLastError`, per the [function docs][setclipboarddata].
- **Who pays when the owner dies:** destroying the window with an unrendered promise
  outstanding delivered [`WM_RENDERALLFORMATS`][wm-renderallformats] ("sent to the
  clipboard owner before it is destroyed, if the clipboard owner has delayed rendering
  one or more clipboard formats") _before_ `WM_DESTROY`; the handler must do the full
  `OpenClipboard(hwnd)` + `GetClipboardOwner()==hwnd` check + `SetClipboardData` +
  `CloseClipboard` ceremony (unlike `WM_RENDERFORMAT`, where the clipboard is already
  open and **must not** be re-opened). After that, the data outlives the source process
  inside wineserver — the _source_ pays, eagerly, at exit:

```text
3054574 f16_win32 clip_request msg=WM_RENDERALLFORMATS
3054840 f16_win32 clip_send fmt=CF_UNICODETEXT bytes=10 render_all=1
3055149 f16_win32 msg name=WM_DESTROY render_demands=2 render_all=1
```

## Ownership loss

When another party (here a worker thread opening the clipboard with no owner window)
calls `EmptyClipboard`, the previous owner receives
[`WM_DESTROYCLIPBOARD`][wm-destroyclipboard] — and the demo shows it is delivered **even
when the owner empties the clipboard itself** (each delayed-copy phase's own
`EmptyClipboard` logged one first). The external grab:

```text
2094969 f16_win32 thread=grab action=EmptyClipboard t=2094969
2095404 f16_win32 ownership_lost msg=WM_DESTROYCLIPBOARD seq=12
2095789 f16_win32 clip_update msg=WM_CLIPBOARDUPDATE seq=16 owner=0000000000000000
```

`ownership_lost` is synchronous with the grab (≤0.5 ms), and the subsequent
`WM_CLIPBOARDUPDATE` shows the new owner (`NULL` — the grabber used
`OpenClipboard(NULL)`). A lazy-rendering source must treat `WM_DESTROYCLIPBOARD` as
"all outstanding promises are void".

## Host-clipboard bridging — the driver IS the feature

Whether a Wine clipboard reaches the host (and vice versa) is pure display-driver
plumbing, probed in both directions ([spec][f16] req. 1/2):

| Direction           | winex11 (Xvfb)                                                                                                           | winewayland (sway 1.11)                                       |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| host → Wine (paste) | **works** — `xclip`-preloaded text appeared at `paste_startup` (`bytes=46 wchars=22`)                                    | **nothing** — 0 formats, `CF_UNICODETEXT` absent              |
| Wine → host (copy)  | **works** — `xclip -o -t UTF8_STRING` returned `é漢🎈`; `TARGETS` = `UTF8_STRING COMPOUND_TEXT STRING text/plain TEXT …` | **nothing** — `wl-paste` kept returning the pre-run host data |

The winex11 export tracked the demo live (polled every 400 ms): the X selection
answered with the payload right after `copy_immediate`, switched to `grabbed` after the
ownership grab, and **died with the prefix** — once the demo (and with it wineserver)
exited, `TARGETS` stopped answering entirely. Wine's X11 bridge makes the _wine process
side_ the selection owner and runs no clipboard manager; a framework cannot assume a
Wine-hosted copy survives app exit. Under winewayland (Wine 10.0) no clipboard bridging
was observed in either direction even with a focused window under a seat-providing
compositor — wayland-host integration is the lagging side of this Wine, so treat any
winewayland clipboard interop as Tier C until re-measured on a newer Wine.

(Headless corner: `wl-clipboard` refused weston 15's headless backend outright — "the
compositor does not seem to implement seat" — hence sway for the bridging legs.)

## Drag-and-drop: OLE, hand-rolled, in-process — and it works headless

The DnD side is COM with **hand-declared vtables** (raw `extern(Windows)` function
pointer structs — no druntime `ole2` imports; the ABI itself is the contract under
test): an `IDropTarget` registered with [`RegisterDragDrop`][registerdragdrop], and a
minimal `IDataObject` (one `FORMATETC`: `CF_HDROP`/`TYMED_HGLOBAL` carrying a
[`DROPFILES`][dropfiles] block listing a real temp file) + `IDropSource` driven through
[`DoDragDrop`][dodragdrop] — the same in-process source→own-window trick as the
[X11 F16][x11-f16] XDND demo. Two pieces of ceremony made it work headless:

- **[`OleInitialize`][oleinitialize], not `CoInitialize`** — the docs are explicit that
  applications using the clipboard, drag-and-drop, OLE, or in-place activation "must
  call `OleInitialize`" (it layers the OLE services, including the drop-target window
  property machinery, on top of the STA that `CoInitialize` alone would create).
  `RegisterDragDrop` on a bare-`CoInitialize` thread is the classic
  `E_OUTOFMEMORY`-shaped failure.
- DoDragDrop's modal loop is driven by input: the demo parks the wineserver virtual
  cursor over its own client area (`SetCursorPos`, so the loop's hit-test finds the
  registered target) and a helper thread jiggles it ±1 px every 20 ms; the
  `IDropSource::`[`QueryContinueDrag`][querycontinuedrag] returns `DRAGDROP_S_DROP` on
  its 6th call (no real mouse button exists to release).

The full negotiation, verbatim:

```text
2415985 f16_win32 dnd_source query_continue n=1 esc=0 keys=0x0
2416594 f16_win32 dnd_enter keys=0x0 pt=240,160 effects_offered=0x7
2416955 f16_win32 dnd_dataobject ptr=0000000140086290 is_our_source_object=1
2417285 f16_win32 dnd_querygetdata CF_HDROP=0x00000000 CF_UNICODETEXT=0x80040064
2417635 f16_win32 dnd_enter formats=[CF_HDROP(tymed=1)] n=1
2417899 f16_win32 dnd_enter_reply effect=DROPEFFECT_COPY
2418204 f16_win32 dnd_source give_feedback n=1 effect=0x1
2418597 f16_win32 dnd_over n=1 pt=240,160 effect_in=0x7
2496517 f16_win32 dnd_drop pt=240,160 effects_in=0x7
2496743 f16_win32 dnd_request fmt=0x000f tymed=1 aspect=1
2496995 f16_win32 dnd_send fmt=CF_HDROP bytes=124
2497276 f16_win32 dnd_drop fmt=CF_HDROP bytes=124 files=1 fwide=1 file0=C:\users\petar\AppData\Local\Temp\wsi-f16-drop.txt
2497928 f16_win32 dnd_source DoDragDrop_returned hr=0x00040100 (DRAGDROP_S_DROP) effect=0x1 query_continue_calls=6
```

- **The sequence diagram is OLE's, intact under Wine:** `QueryContinueDrag` →
  `DragEnter` (with the offered-effects mask `0x7` = COPY|MOVE|LINK from the
  `DoDragDrop` call) → `GiveFeedback` (effect the target chose) → `DragOver` per cursor
  event → `Drop` → target pulls `GetData(CF_HDROP)` → `DoDragDrop` returns
  `DRAGDROP_S_DROP` with the negotiated `DROPEFFECT_COPY`. Position feedback,
  accept/reject (`*pdwEffect`), data transfer, and completion all observable — Tier
  `A[wine]`, no Tier-C downgrade needed.
- **No proxying in-process:** the `IDataObject*` handed to `DragEnter` is pointer-equal
  to the source's own object (`is_our_source_object=1`) — same apartment, no marshaling;
  `QueryGetData` answered `S_OK` for `CF_HDROP` and `DV_E_FORMATETC` for text, exactly
  what the source implements.
- **The drop payload is the `DROPFILES` HGLOBAL itself** (124 bytes: header + UTF-16
  path + double NUL); [`DragQueryFileW`][dragqueryfilew] parses it on the target side
  (`files=1`, the real path). File drop on Win32 is "clipboard format in a DnD
  envelope".
- **Clipboard and DnD share the data layer, not the transport.** The same
  `FORMATETC`/`STGMEDIUM`/`IDataObject` vocabulary (and literally `CF_HDROP`) serves
  both — OLE's clipboard API (`OleSetClipboard`) takes the very same `IDataObject` —
  but the _trigger_ machinery differs completely (window messages vs COM callbacks).
  For a framework data API this argues for one format-negotiation abstraction with two
  entry points, matching what Wayland/X11 do with one selection mechanism.

## Surprises

- **`SetClipboardData(fmt, NULL)` "fails" on success** — delayed rendering returns
  `NULL` + `GetLastError()==0`; naive error checking breaks the lazy path.
- **Your own `EmptyClipboard` sends you `WM_DESTROYCLIPBOARD`** — ownership-loss
  handlers must tolerate self-inflicted loss during re-copy.
- **An unfiltered `PeekMessage` reader thread is not needed and the obvious one is a
  trap** — see the [F17 doc](./f17-threading.md) `WM_PAINT` note; the clipboard demand
  thread here uses plain `GetClipboardData`, whose render round-trip Windows runs
  through the _owner's_ pump invisibly.
- **OLE DnD is fully scriptable headless under Wine** — expected to "fight headless",
  it instead completed the entire negotiation in every run on both drivers; the only
  accommodations were the parked cursor and the self-terminating `QueryContinueDrag`.
- **Wine ships working `WM_CLIPBOARDUPDATE`** but **no clipboard persistence** — data
  (even rendered) is gone when wineserver exits, and the X11 selection bridge dies with
  it.

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f16-clipboard-dnd/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f16-clipboard-dnd.exe

# winewayland (live socket needed; for the bridging probes use sway:
#   WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman sway -c /dev/null &)
XDG_RUNTIME_DIR=<runtime dir> WAYLAND_DISPLAY=<socket> \
    WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f16-clipboard-dnd.exe

# winex11 under Xvfb; host bridging probed with xclip on the same DISPLAY
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=$(mktemp -d) WINEPREFIX=$(mktemp -d) \
    WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop -c xvfb-run -a nix develop .#win32 -c wine64 ./build/f16-clipboard-dnd.exe
```

A `WSI_AUTO_EXIT=1` run walks all eight phases in ~3 s (plus ~10 s first-run prefix
init), spawns its two `--reader` children itself, and exits 0; without the env var the
window stays up and `c`/`v`/`d` trigger copy/paste/DnD interactively. The bridging
probes are host-side: preload with `wl-copy`/`xclip -i` before the run, poll
`wl-paste`/`xclip -o -t UTF8_STRING` during it. The package's `dub.sdl`
(`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not part of
the pipeline.

## Sources

- [`./examples/f16-clipboard-dnd/app.d`](./examples/f16-clipboard-dnd/app.d) — the demo
  (all log excerpts above)
- [F16 spec][f16] — requirements implemented here; [X11 F16][x11-f16] — the
  same-mechanism contrast (selections) and the in-process DnD trick
- [Win32 scaffold findings][scaffold]; [Win32 F17](./f17-threading.md) — thread/queue
  rules the clipboard demand path leans on
- [`SetClipboardData`][setclipboarddata], [`GlobalAlloc`][globalalloc],
  [`EnumClipboardFormats`][enumclipboardformats], [Standard clipboard formats][stdformats],
  [`WM_RENDERFORMAT`][wm-renderformat], [`WM_RENDERALLFORMATS`][wm-renderallformats],
  [`WM_DESTROYCLIPBOARD`][wm-destroyclipboard], [`AddClipboardFormatListener`][addlistener],
  [`WM_CLIPBOARDUPDATE`][wm-clipboardupdate], [`OleInitialize`][oleinitialize],
  [`RegisterDragDrop`][registerdragdrop], [`DoDragDrop`][dodragdrop],
  [`IDropTarget`][idroptarget], [`IDropSource::QueryContinueDrag`][querycontinuedrag],
  [`DROPFILES`][dropfiles], [`DragQueryFileW`][dragqueryfilew] — Microsoft Learn
  (Wayback-pinned)

<!-- References -->

[f16]: ../features/f16-clipboard-dnd.md
[x11-f16]: ../x11/f16-clipboard-dnd.md
[scaffold]: ./scaffold.md
[manual-queue]: ../manual-run-queue.md
[setclipboarddata]: https://web.archive.org/web/20260308061456/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setclipboarddata
[globalalloc]: https://web.archive.org/web/20260401202230/https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-globalalloc
[enumclipboardformats]: https://web.archive.org/web/20260308232548/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-enumclipboardformats
[stdformats]: https://web.archive.org/web/20260412191411/https://learn.microsoft.com/en-us/windows/win32/dataxchg/standard-clipboard-formats
[wm-renderformat]: https://web.archive.org/web/20260120230553/https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-renderformat
[wm-renderallformats]: https://web.archive.org/web/20260310234552/https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-renderallformats
[wm-destroyclipboard]: https://web.archive.org/web/20260202034222/https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-destroyclipboard
[addlistener]: https://web.archive.org/web/20260316064808/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-addclipboardformatlistener
[wm-clipboardupdate]: https://web.archive.org/web/20260216164227/https://learn.microsoft.com/en-us/windows/win32/dataxchg/wm-clipboardupdate
[oleinitialize]: https://web.archive.org/web/20260123181612/https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-oleinitialize
[registerdragdrop]: https://web.archive.org/web/20260423205002/https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-registerdragdrop
[dodragdrop]: https://web.archive.org/web/20260519185128/https://learn.microsoft.com/en-us/windows/win32/api/ole2/nf-ole2-dodragdrop
[idroptarget]: https://web.archive.org/web/20260423205019/https://learn.microsoft.com/en-us/windows/win32/api/oleidl/nn-oleidl-idroptarget
[querycontinuedrag]: https://web.archive.org/web/20260114102157/https://learn.microsoft.com/en-us/windows/win32/api/oleidl/nf-oleidl-idropsource-querycontinuedrag
[dropfiles]: https://web.archive.org/web/20260418091414/https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/ns-shlobj_core-dropfiles
[dragqueryfilew]: https://web.archive.org/web/20251129233844/https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-dragqueryfilew
