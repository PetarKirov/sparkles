# Win32 — F06: keyboard & keymap

Findings from [`./examples/f06-keyboard/app.d`][f06-app], the Win32 implementation of the
[F06 spec][f06-spec]: a `WndProc` that logs the full
[`WM_KEYDOWN`][wm-keydown] → [`TranslateMessage`][translatemessage] → [`WM_CHAR`][wm-char] /
[`WM_DEADCHAR`][wm-deadchar] → [`WM_KEYUP`][wm-keyup] chain (plus the
[`WM_SYSKEYDOWN`][wm-syskeydown] flavor) for input injected at **scancode level** with
[`SendInput`][sendinput] — a letter, a shifted digit, a same-key keydown pair, an Alt
chord, a surrogate-pair `WM_CHAR`, and (after [`LoadKeyboardLayoutW`][loadkeyboardlayout]
`"00000407"`) the German-layout scancodes for the Y/Z swap and the dead-acute + `E`
compose. A `WSI_NO_TRANSLATE=1` variant skips `TranslateMessage` in the pump to isolate its
exact role. The headline Wine finding: **the layout switch is a lie under the headless null
driver** — the `HKL` changes, the tables don't — so the de-specific captures are
behaviorally proven impossible here and queued for real Windows.

**Last reviewed:** June 11, 2026

> [!IMPORTANT]
> **Everything observed below is `A[wine]`** — measured under Wine 10.0 (`wine64`, null
> display driver, headless) with the exe cross-compiled by LDC 1.41.0
> (`-mtriple=x86_64-pc-windows-msvc`). Wine is a **reimplementation, not Windows** — and
> for this feature the gap is structural: Wine's keyboard layout tables come from the
> display driver, the null driver has only its built-in (US) table, and Wine ships no
> per-locale `kbd*.dll` files. Every de-layout claim below is therefore split into
> _observed fallback_ (`A[wine]`) and _documented Windows contract_ (cited, queued for the
> [manual-run queue][manual-queue]).

---

## The demo

Three bounded runs (`WSI_AUTO_EXIT=1`, ~1.1 s each, all exit `0`): default, the
`WSI_NO_TRANSLATE=1` variant, and an X-backed cross-check (see [Surprises](#surprises)).
The default run's `summary`:

```text
1122302 summary keydown=11 keyup=11 syskeydown=2 syskeyup=1 char=10 deadchar=0
        syschar=1 sysdeadchar=0 inputlangchange=2
```

The script (one [`SetTimer`][settimer] tick per step; each step is one `SendInput` batch,
injected with `wVk=0` + `KEYEVENTF_SCANCODE` so **the active layout, not the injector,
decides vk and text** — "[t]he `SendInput` function inserts the events in the `INPUT`
structures serially into the keyboard or mouse input stream" ([`SendInput`][sendinput]);
the legacy [`keybd_event`][keybd-event] wraps the same stream and is documented as
superseded by it):

| Step                | Scancodes (set 1)             | Exercises                                  |
| ------------------- | ----------------------------- | ------------------------------------------ |
| `letter`            | `0x1e` (A)                    | the plain three-level chain                |
| `shifted_digit`     | `0x2a` + `0x03` (Shift+2)     | vk ≠ text                                  |
| `repeat_bit`        | `0x30`, `0x30`, up (B)        | previous-state bit 30                      |
| `alt_chord`         | `0x38` + `0x2e` (Alt+C)       | `WM_SYSKEYDOWN`/`WM_SYSCHAR`               |
| `load_layout`       | —                             | `LoadKeyboardLayoutW("00000407")` + probes |
| `de_y_position`     | `0x15` (QWERTY Y)             | Y/Z swap (de types `z` here)               |
| `de_z_position`     | `0x2c` (QWERTY Z)             | Y/Z swap, mirror                           |
| `dead_acute`        | `0x0d` (`´` on de, `=` on us) | `WM_DEADCHAR`                              |
| `dead_then_e`       | `0x12` (E)                    | the composed `WM_CHAR` (`é` on de)         |
| `unicode_surrogate` | `KEYEVENTF_UNICODE` ×2 units  | surrogate-pair `WM_CHAR`s (U+1F600)        |

---

## The three-level chain — `A[wine]`

The plain letter, end to end (timestamps µs):

```text
123892 key code=0x1e ext=0 vk=0x41 sym=a text=- state=down repeat=0 count=1 sys=0
124395 char utf16=0x0061 cp=U+0061 text=a repeat=0 sys=0
124804 key code=0x1e ext=0 vk=0x41 sym=a text=- state=up repeat=1 count=1 sys=0
```

`code=` is bits 16–23 of `WM_KEYDOWN`'s `lParam` (+ the extended bit 24), `vk=` is its
`wParam`, `sym=` is [`GetKeyNameTextW`][getkeynametext] fed the same `lParam` bits,
`count=` is bits 0–15, `repeat=` is bit 30. The three levels split across **two messages**:
the key event carries scancode + vk; the text arrives as a separately posted `WM_CHAR` —
which is why the `key` line logs `text=-` and the demo logs `char` as its own event. (The
in-`WM_KEYDOWN` alternative, calling [`ToUnicodeEx`][tounicodeex] for the text, is a
documented trap: "[a]s `ToUnicodeEx` translates the virtual-key code, it also changes the
state of the kernel-mode keyboard buffer. This state-change affects dead keys, ligatures,
Alt+Numeric keypad key entry, and so on" — it would consume the pending accent the _next_
`TranslateMessage` needs.)

| Level    | Carried by                                                          | Provided by                                                                         |
| -------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| scancode | `lParam` bits 16–24 of `WM_(SYS)KEY*`                               | keyboard driver (or the `KEYBDINPUT.wScan` of an injector)                          |
| vk       | `wParam` of `WM_(SYS)KEY*`                                          | the active layout's scancode→vk table, applied by the system before posting         |
| text     | a **separate** `WM_CHAR`/`WM_DEADCHAR` posted by `TranslateMessage` | layout tables + kernel dead-key state, **only if the app pumps `TranslateMessage`** |

### `TranslateMessage`'s exact role — proven by omission

> Translates virtual-key messages into character messages. The character messages are
> posted to the calling thread's message queue, to be read the next time the thread calls
> the `GetMessage` or `PeekMessage` function.
>
> — [`TranslateMessage`][translatemessage], Microsoft Learn

The `WSI_NO_TRANSLATE=1` run injects the identical script and skips only the
`TranslateMessage` call in the pump:

```text
1121318 summary keydown=12 keyup=12 syskeydown=2 syskeyup=1 char=0 deadchar=0
        syschar=0 sysdeadchar=0 inputlangchange=2
```

**Zero text-level messages.** Text on Win32 is not an event the system sends — it is a
service the app must request, message by message, in its own pump. A framework that
forgets the call (or filters the wrong messages around it) gets scancodes and vks forever
and not one character. This also locates dead-key/compose ownership: the accent state
machine lives **system-side** (kernel keyboard buffer + layout tables), but it only
advances through the app's `TranslateMessage` calls.

### vk ≠ text: the shifted digit

```text
223481 key code=0x2a ext=0 vk=0x10 sym=Shift_L text=- state=down repeat=0 count=1 sys=0
223980 key code=0x03 ext=0 vk=0x32 sym=2 text=- state=down repeat=0 count=1 sys=0
224430 char utf16=0x0040 cp=U+0040 text=@ repeat=0 sys=0
```

`vk=0x32` is `'2'` at both transitions; only the `WM_CHAR` knows Shift turned it into `@`.
Hotkeys belong to the vk level, text input to the char level — conflating them breaks one
or the other (the [F06 spec][f06-spec]'s core point, identical in shape to the
sym-vs-text split on the other platforms).

### The `WM_SYS*` flavor

Alt-modified keys ride the same chain renamed (`A[wine]`, as documented in
[`WM_SYSKEYDOWN`][wm-syskeydown]):

```text
423110 key code=0x38 ext=0 vk=0x12 sym=Alt_L text=- state=down repeat=0 count=1 sys=1
423601 key code=0x2e ext=0 vk=0x43 sym=c text=- state=down repeat=0 count=1 sys=1
424057 char utf16=0x0063 cp=U+0063 text=c repeat=0 sys=1
424533 key code=0x2e ext=0 vk=0x43 sym=c text=- state=up repeat=1 count=1 sys=1
425009 key code=0x38 ext=0 vk=0x12 sym=Alt_L text=- state=up repeat=1 count=1 sys=0
```

`WM_SYSKEYDOWN` → `WM_SYSCHAR` → `WM_SYSKEYUP`; the final Alt release arrives as a plain
`WM_KEYUP` (no Alt held anymore). The `WM_SYS*` messages must reach `DefWindowProcW` or
Alt-menu/Alt-F4 handling dies — the demo forwards them after logging.

---

## The repeat contract — `A[wine]` + documented

**The system owns auto-repeat.** The app sees it only as extra `WM_KEYDOWN`s with `lParam`
bit 30 set:

> Because of the autorepeat feature, more than one `WM_KEYDOWN` message may be posted
> before a `WM_KEYUP` message is posted. The previous key state (bit 30) can be used to
> determine whether the `WM_KEYDOWN` message indicates the first down transition or a
> repeated down transition.
>
> — [`WM_KEYDOWN`][wm-keydown], Microsoft Learn

Injected hardware-level events do not trigger the autorepeat generator, so the demo proves
the bit with two keydowns and no intervening release:

```text
323778 key code=0x30 ext=0 vk=0x42 sym=b text=- state=down repeat=0 count=1 sys=0
324241 char utf16=0x0062 cp=U+0062 text=b repeat=0 sys=0
324607 key code=0x30 ext=0 vk=0x42 sym=b text=- state=down repeat=1 count=1 sys=0
325069 char utf16=0x0062 cp=U+0062 text=b repeat=1 sys=0
```

The second down (and its `WM_CHAR` — the bit propagates into the char message's `lParam`)
carries `repeat=1`; every `WM_KEYUP` carries it trivially (the key _was_ down). Bits 0–15
additionally batch coalesced repeats (`count=`, always 1 here). The knobs are global,
read-only-discoverable via [`SystemParametersInfoW`][systemparametersinfo]:

```text
21762 repeat_config speed=12 delay=1 owner=system
```

`SPI_GETKEYBOARDSPEED` is "a value in the range from 0 (approximately 2.5 repetitions per
second) through 31 (approximately 30 repetitions per second)"; `SPI_GETKEYBOARDDELAY` "from
0 (approximately 250 ms delay) through 3 (approximately 1 second delay)"
([`SystemParametersInfoW`][systemparametersinfo]). Under Wine the value tracked the host
environment (the headless run reported `speed=12`, an X-backed run `speed=31`) — the
numbers are Wine's, the contract (system repeats; app neither generates nor cancels
anything; rate/delay global, not per-app) is Windows'. Contrast Wayland in the
[F06 spec][f06-spec], where repeat is entirely the client's job.

---

## Layouts: the switch that lies under Wine — `A[wine]`, the headline finding

Step `load_layout` requests German and verifies **behaviorally** rather than trusting the
returned handle:

```text
522976 script step=load_layout klid=00000407
523795 msg name=WM_INPUTLANGCHANGE charset=0 hkl=0x4070409
524158 layout_active hkl=0x4070409 klid=04070409 tables=fallback_not_de
524553 layout_map scan=0x15 vk_start=0x59 vk_de=0x59
524864 layout_map scan=0x2c vk_start=0x5a vk_de=0x5a
525593 tounicodeex layout=de hkl=0x4070409 scan=0x15 vk=0x59 rc=1 text=y
527208 tounicodeex layout=de hkl=0x4070409 scan=0x0d vk=0xbb rc=1 text==
```

Everything that _signals_ success fires: [`LoadKeyboardLayoutW`][loadkeyboardlayout]
returns non-null, [`WM_INPUTLANGCHANGE`][wm-inputlangchange] is delivered,
`GetKeyboardLayoutNameW` reports `04070409`. But the `HKL` exposes the trick — the name
"is a string composed of the hexadecimal value of the Language Identifier (low word) and
a device identifier (high word)" ([`LoadKeyboardLayoutW`][loadkeyboardlayout]), and Wine
glued the German language id onto the **unchanged** mapping: [`MapVirtualKeyExW`][mapvirtualkeyex]
still maps scan `0x15` → vk `0x59` (`Y`) under the "de" `HKL`, and the injected scancodes
typed `y`/`z` US-style with **no Y/Z swap**. The dead-acute position produced an ordinary
`=` (`tounicodeex … rc=1 text==`, where `rc=-1` would mark a dead key per
[`ToUnicodeEx`][tounicodeex]: "[t]he specified virtual key is a dead key character (accent
or diacritic)"). Root cause: Wine builds layout tables in the display driver from the host
keymap; the null driver carries only the built-in default table, and no `kbd*.dll`
per-locale tables exist in the Wine 10 tree to load.

**Consequences recorded as findings:**

- A binding **cannot** verify a layout switch from the `HKL`/`WM_INPUTLANGCHANGE`
  paper trail; the only honest check is behavioral (map a known scancode through the new
  `HKL`, as the demo's `tables=` verdict does). This holds on Windows too — `HKL` values
  are explicitly "device identifiers", not table identities.
- The de-specific spec items — Y/Z swap on injection, and the dead-key capture — are
  **structurally impossible under headless Wine**, not merely flaky: queued for the
  [manual-run queue][manual-queue] (real-Windows CI), where the same binary and script
  need no changes.

### The dead-key sequence: fallback captured, contract cited

What the run captured (us tables, so `0x0d` is `=`, no dead key — the chain stays
two-level):

```text
822849 key code=0x0d ext=0 vk=0xbb sym== text=- state=down repeat=0 count=1 sys=0
823339 char utf16=0x003d cp=U+003D text== repeat=0 sys=0
923215 key code=0x12 ext=0 vk=0x45 sym=E text=- state=down repeat=0 count=1 sys=0
923665 char utf16=0x0065 cp=U+0065 text=e repeat=0 sys=0
```

What the same code logs where de tables exist (documented contract — the demo's
`deadchar` handler is exercised the moment it runs on real Windows):

> The window with the keyboard focus would receive the following sequence of messages:
> `WM_KEYDOWN`, `WM_DEADCHAR`, `WM_KEYUP`, `WM_KEYDOWN`, `WM_CHAR`, `WM_KEYUP` …
> `TranslateMessage` generates the `WM_DEADCHAR` message when it processes the
> `WM_KEYDOWN` message from a dead key.
>
> — [About Keyboard Input § dead keys][about-keyboard-input] (Microsoft Learn; the German
> circumflex + `o` example)

i.e. for the demo's acute + `E`: `key code=0x0d state=down` → `deadchar utf16=0x00b4` →
`key code=0x0d state=up` → `key code=0x12 state=down` → `char utf16=0x00e9 text=é` →
`key code=0x12 state=up`, with `WM_DEADCHAR` carrying the accent itself
("`WM_DEADCHAR` specifies a character code generated by a dead key" —
[`WM_DEADCHAR`][wm-deadchar]) and the composed `é` arriving only at the **text** level —
scancode and vk levels never see a composed character.

---

## Surrogate pairs: one code point, two `WM_CHAR`s — `A[wine]`

`KEYEVENTF_UNICODE` injection of U+1F600 (😀) arrives as `vk=0xe7` (`VK_PACKET`) key
events plus **one `WM_CHAR` per UTF-16 unit**, which the app must recombine:

```text
1023608 key code=0x3d ext=0 vk=0xe7 sym=F3 text=- state=down repeat=1 count=1 sys=0
1024073 char_unit utf16=0xd83d note=high_surrogate_pending
1024914 key code=0x00 ext=0 vk=0xe7 sym= text=- state=down repeat=1 count=1 sys=0
1025364 char utf16=0xde00 cp=U+1F600 text=😀 repeat=0 sys=0
```

A `WM_CHAR` handler that treats `wParam` as a character (rather than a UTF-16 code unit
with pending-high-surrogate state, as [`WM_CHAR`][wm-char] documents) corrupts every
supplementary-plane input. Wine quirk worth flagging: the `KEYBDINPUT.wScan` UTF-16 unit
leaks into the key message's scancode bits (`code=0x3d` = the low byte of `0xd83d`,
rendering a bogus `sym=F3`) — scancode fields are garbage for `VK_PACKET` events
(`A[wine]`; [`KEYBDINPUT`][keybdinput] documents `wScan` as repurposed for the unit, so
this is likely Windows-faithful, but it is queued for confirmation).

---

## Surprises

- **Every success signal of a layout switch can fire while the tables stay put**
  (`A[wine]`, the headline finding above). Behavioral verification or nothing.
- **An X-backed cross-check didn't help:** under `xvfb-run` (Wine's `winex11` driver —
  recognizable in the log by key names switching from `Shift_L` to `Shift`) with a `de`
  keymap uploaded via `xkbcomp`, the run still reported `tables=fallback_not_de` and
  `speed=31` instead of the headless `12` — Wine 10's layout tracking of a
  post-connection X keymap change is at best unreliable. Not pursued further; real
  Windows is the cheaper verifier ([manual queue][manual-queue]).
- **`text=-` is not a demo limitation but the platform's shape:** Win32 itself delivers
  text as a separate, later message, and the one API that could fill it in synchronously
  ([`ToUnicodeEx`][tounicodeex]) is documented to corrupt the dead-key state that
  `TranslateMessage` depends on.
- **`WM_INPUTLANGCHANGE` arrived once before any layout work** (`charset=254`,
  `hkl=0x4090409`, ~33 ms in) — an initial-activation notification under Wine. A binding
  keying "user switched layouts" UI off this message needs to tolerate a spurious one at
  startup (`A[wine]`).
- **The keyup messages always carry `repeat=1`** — bit 30 is "previous key state", not "is
  autorepeat"; only on `WM_KEYDOWN` does it mean repeat. Reading it uniformly across
  down/up (as the log field tempts) would misclassify every release.

---

## Build & run — `A[wine]`

The [scaffold's verified pipeline][scaffold], run in
`docs/research/window-system-integration/os-apis/win32/examples/f06-keyboard/`:

```bash
nix develop .#win32 -c win32-ldc2 app.d instrument.d -of=build/f06-keyboard.exe
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 \
    nix develop .#win32 -c wine64 ./build/f06-keyboard.exe                    # default
WINEPREFIX=$(mktemp -d) WINEDEBUG=-all WSI_AUTO_EXIT=1 WSI_NO_TRANSLATE=1 \
    nix develop .#win32 -c wine64 ./build/f06-keyboard.exe                    # no TranslateMessage
```

Both exit `0` in ~1.2 s. Without `WSI_AUTO_EXIT=1` the script still runs, then the window
stays open and logs real typing (interactive layout/AltGr exploration on real Windows).
The package's `dub.sdl` (`platforms "windows"`) exists for the Windows CI runner; locally
`dub` is not part of the pipeline, and the demo must not be run under
`wine explorer /desktop=…` (it swallows stdout and the exit code).

---

## Sources

- [`./examples/f06-keyboard/app.d`][f06-app] — the demo (all log excerpts above)
- [F06 spec][f06-spec] — requirements implemented here
- [Win32 scaffold findings][scaffold] — baseline pump and pipeline
- [`WM_KEYDOWN`][wm-keydown], [`WM_KEYUP`][wm-keyup], [`WM_CHAR`][wm-char],
  [`WM_DEADCHAR`][wm-deadchar], [`WM_SYSKEYDOWN`][wm-syskeydown],
  [`WM_INPUTLANGCHANGE`][wm-inputlangchange], [`TranslateMessage`][translatemessage],
  [`SendInput`][sendinput], [`KEYBDINPUT`][keybdinput], [`keybd_event`][keybd-event],
  [`LoadKeyboardLayoutW`][loadkeyboardlayout],
  [`ActivateKeyboardLayout`][activatekeyboardlayout], [`ToUnicodeEx`][tounicodeex],
  [`MapVirtualKeyExW`][mapvirtualkeyex], [`GetKeyNameTextW`][getkeynametext],
  [`SystemParametersInfoW`][systemparametersinfo],
  [About Keyboard Input][about-keyboard-input] — Microsoft Learn (Wayback-pinned)

<!-- References -->

[f06-app]: ./examples/f06-keyboard/app.d
[scaffold]: ./scaffold.md
[f06-spec]: ../features/f06-keyboard.md
[manual-queue]: ../manual-run-queue.md
[settimer]: https://web.archive.org/web/20260512015942/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer
[wm-keydown]: https://web.archive.org/web/20260515153559/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
[wm-keyup]: https://web.archive.org/web/20260515153559/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-keyup
[wm-char]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-char
[wm-deadchar]: https://web.archive.org/web/20260208183128/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-deadchar
[wm-syskeydown]: https://web.archive.org/web/20260214062731/https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-syskeydown
[wm-inputlangchange]: https://web.archive.org/web/20260116102032/https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-inputlangchange
[translatemessage]: https://web.archive.org/web/20260528202321/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-translatemessage
[sendinput]: https://web.archive.org/web/20260518160717/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
[keybdinput]: https://web.archive.org/web/20260502202212/https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput
[keybd-event]: https://web.archive.org/web/20260320234508/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-keybd_event
[loadkeyboardlayout]: https://web.archive.org/web/20251129001359/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-loadkeyboardlayoutw
[activatekeyboardlayout]: https://web.archive.org/web/20260416203913/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-activatekeyboardlayout
[tounicodeex]: https://web.archive.org/web/20260227141938/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-tounicodeex
[mapvirtualkeyex]: https://web.archive.org/web/20250819220719/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mapvirtualkeyexw
[getkeynametext]: https://web.archive.org/web/20250819231909/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getkeynametextw
[systemparametersinfo]: https://web.archive.org/web/20260327035133/https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow
[about-keyboard-input]: https://web.archive.org/web/20260526155704/https://learn.microsoft.com/en-us/windows/win32/inputdev/about-keyboard-input
