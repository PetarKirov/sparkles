# Win32 — F07: IME / text input

Findings from [`./examples/f07-text-input/app.d`][f07-app], the Win32 implementation of the
[F07 spec][f07-spec]: an editable line with a caret, an inline **underlined pre-edit** run,
caret-anchored [`ImmSetCandidateWindow`][immsetcandidatewindow] re-sent on every caret move,
and the full [`WM_IME_STARTCOMPOSITION`][wm-ime-startcomposition] →
[`WM_IME_COMPOSITION`][wm-ime-composition] → [`WM_IME_ENDCOMPOSITION`][wm-ime-endcomposition]
choreography — plus a minimal TSF COM bring-up whose outcome is the spec-mandated
**TSF-vs-IMM32 decision record**. The headline Wine finding: **headless Wine answers the
entire IMM32 protocol with no real input method installed** — an
[`ImmSetCompositionStringW`][immsetcompositionstring]`(SCS_SETSTR)` self-injection echoes
back as a genuine composition (start → pre-edit → commit-on-`CPS_COMPLETE` → end), so the
app-side choreography is fully verifiable under Tier `A[wine]`; only the candidate-list UX
and real-keystroke interleaving need the Tier-C CJK script below.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`, headless)
> with the exe cross-compiled by LDC 1.41.0 (`-mtriple=x86_64-pc-windows-msvc`). Two runs:
> the default **winewayland** driver (live `wayland-0` socket) and a **winex11** cross-check
> under `xvfb-run` — byte-identical `summary` lines, so the IME plumbing is
> driver-independent in Wine. No real IME is installed in either run; what answered is
> Wine's built-in `imm32`/default-IME-window machinery, which is a reimplementation —
> every claim about what a _real_ IME does is cited and queued for the
> [manual-run queue][manual-queue].

---

## The demo

One bounded run per driver (`WSI_AUTO_EXIT=1`, ~1.2 s, exit `0`). The script (one
[`SetTimer`][settimer] tick per step):

| Step                     | What it does                                                                                       | Proves                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `probe_imm`              | `ImmGetContext`, [`ImmGetDefaultIMEWnd`][immgetdefaultimewnd], open/conversion status, description | what headless Wine's `imm32` provides              |
| `type_ascii`             | `SendInput` scancodes for `a`, `b`                                                                 | caret movement re-anchors the candidate window     |
| `set_composition_string` | [`ImmSetCompositionStringW`][immsetcompositionstring]`(SCS_SETSTR, "nihao")`                       | does `imm32` echo `WM_IME_COMPOSITION` back? (yes) |
| `notify_complete`        | [`ImmNotifyIME`][immnotifyime]`(NI_COMPOSITIONSTR, CPS_COMPLETE)`                                  | the commit path (`GCS_RESULTSTR`)                  |
| `notify_cancel`          | `SCS_SETSTR "x"` + `ImmNotifyIME(…, CPS_CANCEL)`                                                   | the cancel path                                    |
| `associate_null`         | [`ImmAssociateContext`][immassociatecontext]`(hwnd, null)`, type `c`                               | IME-disable probe: plain `WM_CHAR` still arrives   |
| `associate_restore`      | `ImmAssociateContext(hwnd, saved)`                                                                 | the context survives detachment                    |

The default run's `summary`:

```text
1221232 summary text=abnihaoc caret=8 start=2 comp=3 end=2 setctx=5 notify=18
        imechar=0 char=3 commit=1
```

`abnihaoc` is exactly: typed `ab`, committed composition `nihao`, canceled `x` (absent),
IME-less `c`. `imechar=0` — see [below](#owning-the-rendering-what-the-demo-consumes).

---

## The TSF-vs-IMM32 decision record

The [F07 spec][f07-spec] mandates trying **TSF** first and documenting precisely why if
IMM32 is used instead. The demo's `tsfProbe` is that record, run before the editor starts.
druntime's `core.sys.windows` has **no projection of `msctf.h` at all**, so the demo
hand-declares the two vtbls ([`ITfThreadMgr`][itfthreadmgr], `ITfDocumentMgr`) and the
CLSID/IID it needs. The bring-up itself is shockingly painless — every step returned `S_OK`
under Wine:

```text
12476 tsf step=CoInitializeEx hr=0x00000000
13619 tsf step=CoCreateInstance clsid=TF_ThreadMgr hr=0x00000000 ptr=1
14015 tsf step=Activate hr=0x00000000 client_id=0x1
14316 tsf step=CreateDocumentMgr hr=0x00000000 ptr=1
14626 tsf step=CreateContext punk=null hr=0x00000000 cookie=0x3
14971 tsf step=Push hr=0x00000000
15205 tsf step=AssociateFocus hr=0x00000000 prev=0
15501 tsf_verdict reached=context_pushed_and_focused note=no_ITextStoreACP_so_no_editable_store
```

So **COM from plain D is not the wall** — interface declarations with the right vtbl order
and `extern (Windows)` calling convention are all it takes, and Wine implements enough of
`msctf` to activate a thread manager and push a context. The wall is what comes next:
[`ITfDocumentMgr::CreateContext`][createcontext] with `punk=null` is legal but produces a
context **without a text store** — an IME can neither read nor edit the document through
it. A functioning TSF integration requires the app to implement
[`ITextStoreACP`][itextstoreacp] (a ~30-method document-access interface with
lock/notification semantics) plus advise-sink plumbing, in a framework that — per
Microsoft's own positioning — "is designed for use by Component Object Model (COM)
programmers using the C/C++ programming languages"
([Text Services Framework][tsf-overview]).

**Decision:** the editor speaks **IMM32**, whose entire app-side surface is the handful of
`WM_IME_*` messages and `Imm*` calls exercised below. On modern Windows an IMM32-only
window is serviced through the system's IMM-over-TSF compatibility layer (the
[Input Method Manager][imm-overview] docs position IMM as the legacy surface TSF wraps), so
nothing is lost for a research demo; the cost is forgoing TSF-only features (in-place
candidate integration, reconversion-quality document access, modern handwriting/speech
sources). A production binding targeting first-class CJK should budget `ITextStoreACP` as
its own work item — the COM mechanics are cheap, the document-store semantics are the
project.

druntime footnote, a finding in its own right: `core.sys.windows.imm` declares
`alias DWORD HIMC` — but `HIMC` is a pointer-sized `DECLARE_HANDLE`, so on Win64 druntime's
own prototypes **truncate the handle** (and none are `nothrow`, which a `WndProc` needs).
The demo redeclares the dozen functions it uses with a correct `alias HIMC = HANDLE;` the
constants and structs (`WM_IME_*`, `GCS_*`, `CFS_*`, `CANDIDATEFORM`) are fine.

---

## The IMM32 choreography — `A[wine]`

### The composition echo: what `SCS_SETSTR` proves headless

The probe step asks the IME to _set_ the composition string; Wine's `imm32` answered with
the full message choreography a real IME keystroke would produce:

```text
471830 msg name=WM_IME_STARTCOMPOSITION
473069 msg name=WM_IME_COMPOSITION flags=0x1b8
473378 preedit text=nihao units=5 cursor=5 attr=00000
474581 imm set_composition_string scs=SCS_SETSTR ok=1 err=0
```

`flags=0x1b8` decodes to `GCS_COMPSTR | GCS_COMPATTR | GCS_COMPCLAUSE | GCS_CURSORPOS |
GCS_DELTASTART` — string, attributes, clause info, cursor, delta, all marked dirty in one
message, read back with [`ImmGetCompositionStringW`][immgetcompositionstring] (`attr=00000`
= five `ATTR_INPUT` bytes, one per `wchar`). Note the ordering: `WM_IME_STARTCOMPOSITION`
and `WM_IME_COMPOSITION` are delivered **synchronously inside the
`ImmSetCompositionStringW` call** (the `ok=1` log line trails them). Commit, via
`ImmNotifyIME(NI_COMPOSITIONSTR, CPS_COMPLETE)`:

```text
621951 msg name=WM_IME_COMPOSITION flags=0x1800
622240 commit text=nihao units=5
624246 msg name=WM_IME_ENDCOMPOSITION
624496 imm notify_ime action=CPS_COMPLETE ok=1
```

`flags=0x1800` = `GCS_RESULTSTR | GCS_RESULTCLAUSE`: the pre-edit is replaced by result
text in the same message type, distinguished only by the flag bits — exactly the
documented shape ("Sent to an application when the IME changes composition status as a
result of a keystroke" — [`WM_IME_COMPOSITION`][wm-ime-composition]). The demo inserts the
result at the caret and clears the pre-edit run.

### Cancel: no zero-flag message under Wine

```text
773587 msg name=WM_IME_COMPOSITION flags=0x1b8
773866 preedit text=x units=1 cursor=1 attr=0
774997 msg name=WM_IME_ENDCOMPOSITION
775245 imm notify_ime action=CPS_CANCEL ok=1
```

`CPS_CANCEL` produced **only** `WM_IME_ENDCOMPOSITION` — no `WM_IME_COMPOSITION` with
cleared flags (`lParam=0`) preceded it, which is the other commonly-described cancel shape.
An app that clears its pre-edit only in a `lParam==0` composition handler would render a
ghost pre-edit forever under Wine; the demo clears it in **both** places
(`WM_IME_ENDCOMPOSITION` is the authoritative end-of-life). Which shape real Windows IMEs
produce per cancel route (Esc vs focus loss) is a Tier-C question in the script below.

### Caret-anchored candidate positioning — and its feedback loop

Every caret move (typing, arrows, pre-edit cursor changes) re-sends a `CFS_EXCLUDE`
[`CANDIDATEFORM`][candidateform] (and a `CFS_POINT` `COMPOSITIONFORM` for IMEs that ignore
the former) at the freshly measured caret x:

```text
322688 char utf16=0x0061
323156 msg name=WM_IME_NOTIFY cmd=0x9
323551 msg name=WM_IME_NOTIFY cmd=0xb
323893 candidate_anchor x=19 y=25 style=CFS_EXCLUDE ok=1 comp_ok=1
…
474226 candidate_anchor x=55 y=25 style=CFS_EXCLUDE ok=1 comp_ok=1   (pre-edit grew)
623019 candidate_anchor x=85 y=25 style=CFS_EXCLUDE ok=1 comp_ok=1   (after commit)
```

The anchor x walks 12 → 19 → 25 with typed text, jumps to 55 while the 5-unit pre-edit is
live and to 85 after the commit — the re-report-on-caret-move contract working. The
`cmd=0x9`/`cmd=0xb` lines _preceding_ each `candidate_anchor` log are
`IMN_SETCANDIDATEPOS` / `IMN_SETCOMPOSITIONWINDOW` [`WM_IME_NOTIFY`][wm-ime-notify]
notifications — **synchronous echoes of the app's own `ImmSetCandidateWindow` /
`ImmSetCompositionWindow` calls**, delivered re-entrantly before the setter returns
(`A[wine]`). A binding that re-anchors _in response to_ `WM_IME_NOTIFY` position messages
recurses; route them to `DefWindowProcW` and anchor only on actual caret movement.

Units finding (feeds [F08][f08-doc]): `CANDIDATEFORM`/`COMPOSITIONFORM` coordinates are
**client-area pixels** — under Per-Monitor-v2 awareness those are physical pixels at the
window's current DPI, so a DPI change invalidates every cached anchor rectangle.

### Owning the rendering: what the demo consumes

The demo renders the pre-edit inline (underlined, distinct from committed text), so it:

- answers [`WM_IME_SETCONTEXT`][wm-ime-setcontext] with `lParam &
~ISC_SHOWUICOMPOSITIONWINDOW` (observed `show=0xc000000f` = composition window +
  guideline + all four candidate windows) — suppressing the IME's own composition UI while
  keeping the IME-drawn candidate list;
- returns `0` from `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION` instead of calling
  `DefWindowProcW` — which is why `imechar=0`: result characters reach
  [`WM_IME_CHAR`][wm-ime-char] only when the default window processing converts an
  unconsumed `GCS_RESULTSTR`, so a zero count proves the demo consumed the commit at the
  composition level (no double insertion).

### The IME-disable probe

```text
921638 msg name=WM_IME_SETCONTEXT active=0 show=0xc000000f
921966 msg name=WM_IME_SETCONTEXT active=1 show=0xc000000f
922314 imm associate_context new=0 old=0x20052 now=0x0
922950 char utf16=0x0063
923145 candidate_anchor skipped=no_himc
```

`ImmAssociateContext(hwnd, null)` ("Associates the specified input context with the
specified window" — [`ImmAssociateContext`][immassociatecontext]) detaches the context:
`ImmGetContext` then returns `0`, candidate anchoring becomes a no-op, and plain keys still
arrive as `WM_CHAR` (`c` landed) — the standard way to make a password/hotkey field
IME-proof. Re-associating the saved handle restored `now=0x20052`. Wine quirk: the
detach fired a `WM_IME_SETCONTEXT active=0` **and** an immediate `active=1` pair
(`A[wine]`).

### What headless Wine's `imm32` provides — probe summary

```text
171513 imm context himc=0x20052
171727 imm default_ime_wnd hwnd=0x2d0064
171975 imm open_status open=0
172181 imm conversion_status ok=1 conversion=0x0 sentence=0x0
172565 imm description len=0 note=not_an_ime_layout
```

A real input context and a live **default IME window** exist with no IME installed; status
queries answer (closed, native conversion); `ImmGetDescriptionW` returns empty because the
active `HKL` is a plain keyboard layout, not an IME — consistent with [F06][f06-doc]'s
finding that Wine's headless layout machinery is the US table wearing different `HKL`s.

### Key-event interleaving

With no IME in the loop, typed ASCII rides the ordinary [F06][f06-doc] chain
(`WM_KEYDOWN` → app-pumped `TranslateMessage` → `WM_CHAR`); nothing is swallowed. The
documented real-IME shape — keystrokes consumed by the IME surface as `VK_PROCESSKEY`
key-downs while text emerges from `WM_IME_*` — **cannot be observed under headless Wine**
and is the first thing the Tier-C script checks. Note that the `WM_IME_*` messages here
arrived _without_ `TranslateMessage`'s involvement (they are posted by `imm32`, not
synthesized in the pump), so the F06 rule "no `TranslateMessage`, no text" has an IME-side
exception path a binding must keep working.

---

## Surprises

- **Headless Wine speaks fluent IMM32.** `SCS_SETSTR`/`NI_COMPOSITIONSTR` round-trips
  produce the genuine `WM_IME_*` choreography with zero input methods installed — the
  whole app-side state machine is CI-testable under `A[wine]`, something none of the other
  platforms' IME stacks offer headless (`A[wine]`).
- **TSF's COM bring-up is the easy 10%.** Hand-declared vtbls from plain D reached
  `AssociateFocus` with all-`S_OK`; the missing 90% is `ITextStoreACP`'s document-store
  semantics, which is a design commitment, not a binding chore.
- **Cancel ≠ zero-flag message** under Wine: `CPS_CANCEL` yields a bare
  `WM_IME_ENDCOMPOSITION`. Clear the pre-edit there, not (only) in a `lParam==0` handler.
- **Your own `ImmSet*Window` calls come back as `WM_IME_NOTIFY`** re-entrantly — an
  anchor-on-notify feedback loop waiting to happen.
- **druntime's `imm` module is unusable as-is on Win64** (`HIMC` = `DWORD` truncation, no
  `nothrow`); the constants are fine, the prototypes are not.
- **`WM_IME_SETCONTEXT active=1` arrived before the first `WM_SETFOCUS`-driven activity**
  (17.4 ms, during window creation) and the associate-null probe produced an
  `active=0`/`active=1` pair — `WM_IME_SETCONTEXT` counts (5 here) track context plumbing,
  not focus changes, under Wine (`A[wine]`).

---

## Tier-C manual script — real Windows + Microsoft Pinyin

The same binary and `dub.sdl`, no code changes; run **without** `WSI_AUTO_EXIT` (the
scripted probe still runs, then the window stays open and logs live typing). Setup: Windows
11, add the Chinese (Simplified) language pack, select the built-in Microsoft Pinyin IME,
`Win+Space` to it with the demo window focused.

1. **Type `nihao`** — record: are the five `WM_KEYDOWN`s swallowed (no `char utf16=`
   lines)? Expect `WM_IME_STARTCOMPOSITION` after `n`, then one
   `preedit text=… cursor=… attr=…` line per keystroke with growing pinyin (`n`, `ni`,
   `nih`, …) and `attr` bytes flipping as the IME segments; the candidate list must open
   **beside the demo-drawn underlined pre-edit**, not at the window corner (that is
   `ImmSetCandidateWindow` working).
2. **Press Space then `1`** (or Enter) — expect `commit text=你好 units=2` (
   `GCS_RESULTSTR`), `WM_IME_ENDCOMPOSITION`, `imechar=0` still (no double insert), and
   the committed glyphs rendered un-underlined.
3. **Cancel:** type `nihao`, press Esc — record whether a `WM_IME_COMPOSITION` with
   `flags=0x0` (or `GCS_COMPSTR` with an empty string) precedes `WM_IME_ENDCOMPOSITION`,
   vs Wine's bare-end shape above.
4. **Focus loss mid-composition:** type `niha`, Alt+Tab away — record the
   `WM_IME_SETCONTEXT active=0` line and whether the pre-edit is committed, canceled, or
   restored on Alt+Tab back. This is the spec's focus-lifecycle question; Win32 gives the
   IME the choice.
5. **Caret-anchor proof at both ends:** commit a long line, press Home (caret index 0 via
   Left-arrow holds), type `nihao` — the candidate list must open at the line start; End,
   repeat — at the line end. The `candidate_anchor x=` log lines give the expected x.
6. **IME-proof field check:** wait for the script's `associate_null` step (or re-run),
   then try composing — the IME must not activate, and plain Latin keys must insert.

Expected-vs-observed deltas (especially items 3 and 4, and any `WM_IME_NOTIFY` commands
beyond `0x9`/`0xb`, e.g. `IMN_OPENCANDIDATE`/`IMN_CHANGECANDIDATE`) get recorded back into
this doc with `B`-tier labels.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f07-text-input/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f07-text-input.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f07-text-input.exe       # winewayland (wayland-0)
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 XDG_RUNTIME_DIR=$(mktemp -d) \
    env -u WAYLAND_DISPLAY xvfb-run -a \
    nix develop .#win32 -c wine64 ./build/f07-text-input.exe       # winex11 cross-check
```

Both exit `0` in ~1.2 s with identical summaries (`start=2 comp=3 end=2 … commit=1`).
Without `WSI_AUTO_EXIT=1` the window stays open for live (Tier-C) IME typing. The package's
`dub.sdl` (`platforms "windows"`) exists for the Windows CI runner; locally `dub` is not
part of the pipeline.

---

## Sources

- [`./examples/f07-text-input/app.d`][f07-app] — the demo (all log excerpts above)
- [F07 spec][f07-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold], [F06 keyboard findings][f06-doc] — baseline pump,
  text-input chain
- [`WM_IME_STARTCOMPOSITION`][wm-ime-startcomposition],
  [`WM_IME_COMPOSITION`][wm-ime-composition],
  [`WM_IME_ENDCOMPOSITION`][wm-ime-endcomposition],
  [`WM_IME_SETCONTEXT`][wm-ime-setcontext], [`WM_IME_NOTIFY`][wm-ime-notify],
  [`WM_IME_CHAR`][wm-ime-char], [`ImmGetContext`][immgetcontext],
  [`ImmGetCompositionStringW`][immgetcompositionstring],
  [`ImmSetCompositionStringW`][immsetcompositionstring],
  [`ImmSetCandidateWindow`][immsetcandidatewindow], [`CANDIDATEFORM`][candidateform],
  [`ImmNotifyIME`][immnotifyime], [`ImmAssociateContext`][immassociatecontext],
  [`ImmGetDefaultIMEWnd`][immgetdefaultimewnd], [Input Method Manager][imm-overview],
  [Text Services Framework][tsf-overview], [`ITfThreadMgr`][itfthreadmgr],
  [`ITfDocumentMgr::CreateContext`][createcontext], [`ITextStoreACP`][itextstoreacp] —
  Microsoft Learn (Wayback-pinned where the archive has a snapshot)

<!-- References -->

[f07-app]: ./examples/f07-text-input/app.d
[f07-spec]: ../features/f07-text-input.md
[scaffold]: ./scaffold.md
[f06-doc]: ./f06-keyboard.md
[f08-doc]: ./f08-dpi-scaling.md
[manual-queue]: ../manual-run-queue.md
[settimer]: https://web.archive.org/web/20260512015942/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
[wm-ime-startcomposition]: https://web.archive.org/web/20221220040257/https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-startcomposition
[wm-ime-composition]: https://web.archive.org/web/20260309125734/https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-composition
[wm-ime-endcomposition]: https://web.archive.org/web/20221220040324/https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-endcomposition
[wm-ime-setcontext]: https://web.archive.org/web/20250428201330/https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-setcontext
[wm-ime-notify]: https://web.archive.org/web/20230209130853/https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-notify
[wm-ime-char]: https://web.archive.org/web/20250406024329/https://learn.microsoft.com/en-us/windows/win32/intl/wm-ime-char
[immgetcontext]: https://web.archive.org/web/20251227022839/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immgetcontext
[immgetcompositionstring]: https://web.archive.org/web/20250819225608/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immgetcompositionstringw
[immsetcompositionstring]: https://web.archive.org/web/20260101043538/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immsetcompositionstringw
[immsetcandidatewindow]: https://web.archive.org/web/20260225001044/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immsetcandidatewindow
[candidateform]: https://web.archive.org/web/20251219033318/https://learn.microsoft.com/en-us/windows/win32/api/immdev/ns-immdev-candidateform
[immnotifyime]: https://web.archive.org/web/20260310141818/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immnotifyime
[immassociatecontext]: https://web.archive.org/web/20260312170108/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immassociatecontext
[immgetdefaultimewnd]: https://web.archive.org/web/20251218111728/https://learn.microsoft.com/en-us/windows/win32/api/immdev/nf-immdev-immgetdefaultimewnd
[imm-overview]: https://learn.microsoft.com/en-us/windows/win32/intl/input-method-manager
[tsf-overview]: https://web.archive.org/web/20260605080101/https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework
[itfthreadmgr]: https://web.archive.org/web/20260314104837/https://learn.microsoft.com/en-us/windows/win32/api/msctf/nn-msctf-itfthreadmgr
[createcontext]: https://web.archive.org/web/20250831093926/https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itfdocumentmgr-createcontext
[itextstoreacp]: https://web.archive.org/web/20250902012633/https://learn.microsoft.com/en-us/windows/win32/api/textstor/nn-textstor-itextstoreacp
