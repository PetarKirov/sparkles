# X11 F07 — IME / text input (XIM)

Composed text input on X11 through its native protocol, **XIM**, with every
pathology measured rather than recited. The demo,
[`./examples/f07-text-input/app.d`](./examples/f07-text-input/app.d), extends
the [scaffold](./scaffold.md) to the [F07 spec][f07]'s X11 requirements: an
editable line with a caret (block-cell rendering; the _real_ strings go to the
log), the full locale-coupling sequence (`setlocale` → `XSupportsLocale` →
`XSetLocaleModifiers`), `XOpenIM`/`XCreateIC` with a
`XIMPreeditPosition → XIMPreeditCallbacks → XIMPreeditNothing` preference
walk (negotiated style logged), the [`XFilterEvent` gate](#the-xfilterevent-contract)
on **every** event, `Xutf8LookupString` in the key path, `XNSpotLocation`
re-reported on every caret move, the on-the-spot pre-edit callbacks, and the
IM instantiate/destroy lifecycle callbacks. The co-located
`examples/f07-text-input/run.sh` driver runs six scenarios under one Xvfb —
including **a real CJK IME**: fcitx5 in XIM-server mode, headless. Tier A:
**a pinyin `nihao` + space round-trip commits `你好`**, the IM-server
kill/restart fires the destroy/instantiate callbacks live, and the
on-the-spot scenario captures nine `preedit_draw` deltas. Exit 0 everywhere.

**Last reviewed:** June 11, 2026

## The verdict lines

```text
[fcitx5]           20088841 f07_x11 summary im=1 style=PreeditPosition|StatusNothing commits=2 filtered=45 key_events=17 preedit_draws=0 line=你好你
[fcitx5-onthespot] 14098541 f07_x11 summary im=1 style=PreeditCallbacks|StatusNothing commits=1 filtered=50 key_events=13 preedit_draws=9 line=你好
[builtin-utf8]      9056487 f07_x11 summary im=1 style=PreeditNothing|StatusNothing commits=7 filtered=4 key_events=20 preedit_draws=0 line=
```

## Locale coupling, measured

XIM is the only input path in this tree whose availability depends on the C
runtime locale. Per the [Xlib manual][xlib-i18n]:

> The XOpenIM function opens an input method, matching the current locale and
> modifiers specification. Current locale and modifiers are bound to the input
> method at opening time. The locale associated with an input method cannot be
> changed dynamically.

and the prescribed order is `setlocale` → `XSetLocaleModifiers` ("Clients
should always call XSetLocaleModifiers with a non-NULL modifier_list after
setting the locale before they call any locale-dependent Xlib routine"). The
modifier string is where `XMODIFIERS` enters:

> The local host X locale modifiers announcer (on POSIX-compliant systems, the
> XMODIFIERS environment variable) is appended to the modifier_list to provide
> default values on the local host.

What the four locale scenarios actually measured:

| Scenario         | Environment                           | `setlocale` | `XSupportsLocale` | `XOpenIM`             | dead-key `´`+`e`          |
| ---------------- | ------------------------------------- | ----------- | ----------------- | --------------------- | ------------------------- |
| `builtin-utf8`   | `LC_ALL=en_US.UTF-8`, no `XMODIFIERS` | ok          | 1                 | ok (built-in, 4.0 ms) | **`é`** (UTF-8, 2 bytes)  |
| `locale-c`       | `LC_ALL=C`                            | `C`         | **1**             | ok (built-in, 0.3 ms) | **`é`** still composed    |
| `bogus-locale`   | `LC_ALL=xx_YY.nope`                   | **fails**   | 1 (still `C`)     | ok (built-in)         | (not exercised)           |
| `nonexistent-im` | `XMODIFIERS=@im=nosuchim`             | ok          | 1                 | **NULL in 12 µs**     | n/a — raw `XLookupString` |

Two corrections to folklore, first-hand:

- **The built-in IM is far more forgiving than its reputation.** `XOpenIM`
  succeeded under `LC_ALL=C` and even after a _failed_ `setlocale` (the
  process simply stays in the `C` locale, which `XSupportsLocale` accepts),
  and `Xutf8LookupString` still composed `´`+`e` → `é` — its output encoding
  is UTF-8 regardless of locale, and this libX11 (1.8.x) resolves a usable
  compose table even from `C`. The hard locale coupling is real for the
  _encoding-dependent_ `XmbLookupString` family and for IM servers that
  refuse the client's locale — not for the built-in UTF-8 path.
- **The coupling that does bite is `XMODIFIERS`.** With `@im=nosuchim`,
  `XOpenIM` returns **NULL in 12 µs** — no blocking, no timeout, and **no
  fallback to the built-in IM**. A host-leaked `XMODIFIERS=@im=ibus` with no
  ibus running reproduces this exactly (the bare CI run of this demo shows
  it). A toolkit that treats `XOpenIM == NULL` as "no text input" instead of
  falling back to `XLookupString` loses the keyboard entirely.

```text
[nonexistent-im] 345 f07_x11 step name=XSetLocaleModifiers result=@im=nosuchim XMODIFIERS=@im=nosuchim
[nonexistent-im] 15394 f07_x11 step name=XOpenIM ok=0 took_us=12
[nonexistent-im] 2002360 f07_x11 lookup via=XLookupString status=4 sym=0x68 len=1 text=h
```

## Style negotiation: what each IM actually offers

`XGetIMValues(im, XNQueryInputStyle, …)` returns the IM's menu; the client
must pick an entry it can implement. Measured menus:

| IM                           | Offered styles                                                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| built-in (libX11)            | `PreeditNone\|StatusNone`, `PreeditNothing\|StatusNothing`                                                                             |
| fcitx5 (default)             | `PreeditPosition\|Status{Area,Nothing,None}`, `PreeditNothing\|Status{Nothing,None}` — **no callbacks**                                |
| fcitx5 (`UseOnTheSpot=True`) | `PreeditPosition\|StatusNothing`, **`PreeditCallbacks\|StatusNothing`**, `PreeditNothing\|StatusNothing`, + `StatusCallbacks` variants |

The demo's preference walk (`Position → Callbacks → Nothing → None`,
reordered by `WSI_XIM_STYLE=callbacks|nothing`) negotiated
`PreeditNothing|StatusNothing` against the built-in IM,
`PreeditPosition|StatusNothing` (over-the-spot) against stock fcitx5, and
`PreeditCallbacks|StatusNothing` (on-the-spot) against the configured one.
Two creation-time gotchas: `XIMPreeditPosition` **requires** `XNSpotLocation`
and `XNFontSet` in the create-time `XNPreeditAttributes` (and a working
fontset requires the X server to have fonts at all — bare nixpkgs Xvfb has
**none**; the driver passes `-fp` pointing at `font-misc-misc`, after which
`XCreateFontSet` succeeds with 2 missing charsets); and fcitx5 only offers
the callbacks style when its XIM frontend is configured with
`UseOnTheSpot=True` ([`xim.cpp`][fcitx-xim] picks the `onthespot_styles`
table off that option).

## The `XFilterEvent` contract

The [Xlib manual][xlib-i18n] defines the gate:

> A filtering mechanism is provided to allow input methods to capture X
> events transparently to clients. It is expected that toolkits (or clients)
> … will call this filter at some point in the event processing mechanism to
> make sure that events needed by an input method can be filtered by that
> input method. … If XFilterEvent returns True, then some input method has
> filtered the event, and the client should discard the event.

and adds a second, easily-missed obligation:

> Clients are expected to get the XIC value XNFilterEvents and augment the
> event mask for the client window with that event mask.

The demo offers **every** event to `XFilterEvent` first and logs the
swallowed ones. What XIM actually eats (fcitx5, typing `nihao` + space):

```text
[fcitx5] 6573333 f07_x11 filtered type=KeyPress keycode=57     # n — into the pre-edit
[fcitx5] 6585640 f07_x11 filtered type=KeyPress keycode=31     # i
[fcitx5] 6597921 f07_x11 filtered type=KeyPress keycode=43     # h
[fcitx5] 6610223 f07_x11 filtered type=KeyPress keycode=38     # a
[fcitx5] 6622563 f07_x11 filtered type=KeyPress keycode=32     # o
[fcitx5] 7639459 f07_x11 filtered type=KeyPress keycode=65     # space — selects candidate 1
[fcitx5] 7645562 f07_x11 lookup via=Xutf8LookupString status=2 sym=0x0 len=6 text=你好
[fcitx5] 7645566 f07_x11 commit text=你好 line=你好 caret=2
```

Every composing `KeyPress` **and its `KeyRelease`** is filtered
(`filterEvents=0x3` = press+release, reported by the built-in IM too); the
commit arrives as a fresh, IM-synthesized `KeyPress` whose
`Xutf8LookupString` yields `status=XLookupChars`, `sym=0`, and the committed
UTF-8. Beyond keys, the run shows XIM filtering **`ClientMessage` (33)**
events constantly (the XIM wire protocol itself rides on client messages to
a client-side window), one **`PropertyNotify` (28)** (the instantiate
machinery watching `XIM_SERVERS` on the root), and one **`DestroyNotify`
(17)** (the IM server's window dying). A toolkit that gates only `KeyPress`
through `XFilterEvent` breaks all of that invisibly — the protocol traffic
happens to flow through windows the client never created.

## The built-in IM: compose-only, but filtering

With `XMODIFIERS` unset (or `@im=none`-equivalent) `XOpenIM` yields libX11's
built-in IM. Dead keys on the `de` layout, `´` then `e`:

```text
[builtin-utf8] 2030125 f07_x11 filtered type=KeyPress keycode=8   # dead_acute — swallowed
[builtin-utf8] 2044009 f07_x11 filtered type=KeyPress keycode=0   # IM-internal synthetic
[builtin-utf8] 2044013 f07_x11 lookup via=Xutf8LookupString status=4 sym=0xe9 len=2 text=é
[builtin-utf8] 2044015 f07_x11 commit text=é line=hié caret=3
[builtin-utf8] 2072774 f07_x11 lookup via=Xutf8LookupString status=4 sym=0xb4 len=2 text=´  # ´ ´ → spacing acute
```

Same contract as a real IM server, in miniature: the dead key press is
**filtered** (compose state, zero text), and the composed character arrives
on the next key with `status=XLookupBoth`. Contrast with [F06's][f06-x11]
`xkb_compose` path, where the dead key arrives as an ordinary `KeyPress` the
_application's_ state machine absorbs: same keystrokes, same `é`, but the
ownership flips from app-side (xkbcommon) to Xlib-side (XIM). A toolkit must
pick one — running both double-composes. (The `keycode=8`/`keycode=0` values
are an xdotool artifact: it binds `dead_acute` to a scratch keycode for
injection; the filtering behavior is unaffected.)

## A real CJK IME, headless: the fcitx5 round-trip

The driver starts fcitx5 (XIM frontend + pinyin from
`fcitx5-chinese-addons`) **after** the demo, under the same Xvfb — no D-Bus
session needed once the `dbus` addon is disabled. The full lifecycle, one
log:

```text
[fcitx5]    16103 f07_x11 step name=XOpenIM ok=0 took_us=14          # no server yet
[fcitx5]  2107023 f07_x11 im_instantiated                            # fcitx5 came up
[fcitx5]  2107027 f07_x11 filtered type=28                           #   (the XIM_SERVERS PropertyNotify, itself filtered)
[fcitx5]  2107033 f07_x11 step name=reopen_im (instantiate callback fired)
[fcitx5]  2107403 f07_x11 step name=XOpenIM ok=1 took_us=367
[fcitx5]  2107599 f07_x11 xim_style_negotiated style=0x0404 name=PreeditPosition|StatusNothing
[fcitx5]  2107756 f07_x11 spot x=12 y=62 (caret cell 0)
          … nihao filtered, committed:
[fcitx5]  7645566 f07_x11 commit text=你好 line=你好 caret=2
[fcitx5]  7645648 f07_x11 spot x=40 y=62 (caret cell 2)
[fcitx5]  8673705 f07_x11 im_destroyed (XIM and XICs now invalid; must NOT XCloseIM)
[fcitx5]  8673728 f07_x11 filtered type=17                           # the server window's DestroyNotify
[fcitx5] 10144237 f07_x11 im_instantiated                            # fcitx5 restarted
[fcitx5] 10144851 f07_x11 xim_style_negotiated style=0x0404 name=PreeditPosition|StatusNothing
[fcitx5] 14674711 f07_x11 commit text=你 line=你好你 caret=3          # works again
```

The three lifecycle pieces, each matching the [Xlib manual][xlib-i18n]
verbatim:

- **Instantiate** — "The XRegisterIMInstantiateCallback function registers a
  callback to be invoked whenever a new input method becomes available for
  the specified display that matches the current locale and modifiers."
  Registered _before_ the first `XOpenIM`; against an already-running IM it
  fires synchronously inside the register call (the built-in scenarios show
  `im_instantiated` logged before the register step returns).
- **Destroy** — "XNDestroyCallback is triggered when an input method stops
  its service for any reason. After the callback is invoked, the input
  method is closed and the associated input context(s) are destroyed by
  Xlib. Therefore, the client should not call" `XCloseIM` or `XDestroyIC`.
  The demo just forgets the pointers; touching them is use-after-free.
- **Reopen** — the instantiate callback stays registered, so the restart is
  symmetric: re-negotiate the style, re-create the IC, re-set the spot.
  Pre-edit state at the moment of death is simply **gone** — there is no
  recovery protocol; the user retypes.

Spot anchoring (over-the-spot): `XNSpotLocation` is re-sent via
`XSetICValues` on every caret move ("specifies to the input method the
coordinates of the spot to be used by an input method executing with
XNInputStyle set to XIMPreeditPosition" — [Xlib][xlib-i18n]), and the log
shows `spot x=…` tracking the caret cell. The units are **window-local
pixels** — physical, scale-less; an IM server has no idea what a "logical
pixel" is, which is exactly the [F08](./f08-dpi-scaling.md) story leaking
into F07.

Two deployment gotchas the driver had to learn (both are findings about the
ecosystem, not the demo): fcitx5's XIM frontend **names its server after the
`XMODIFIERS` it inherits** ([`guess_server_name()`][fcitx-xim] consumes
`@im=`), so a host-leaked `@im=ibus` makes it silently register as
`@server=ibus` while clients look for `fcitx`; and new fcitx5 input contexts
start on the _inactive_ keyboard engine — the pinyin engine engages on the
trigger key (`ctrl+space`), which the driver injects.

## On-the-spot: the pre-edit delta protocol

With `UseOnTheSpot=True` and `WSI_XIM_STYLE=callbacks` the demo owns the
pre-edit rendering — per the [Xlib manual][xlib-i18n], "only the client can
insert or delete preedit data in place … the echo of the keystrokes has to
be achieved by the client itself." The deltas for `nihao`, then space, then
a second composition cancelled with Esc:

```text
[fcitx5-onthespot] 6982655 f07_x11 preedit_start (returning -1: no length limit)
[fcitx5-onthespot] 6983492 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=0 text=n
[fcitx5-onthespot] 6985808 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=1 text=ni
[fcitx5-onthespot] 7096127 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=2 text=ni h
[fcitx5-onthespot] 7198337 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=4 text=ni ha
[fcitx5-onthespot] 7299676 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=5 text=ni hao
[fcitx5-onthespot] 7641453 f07_x11 commit text=你好 line=你好 caret=2
[fcitx5-onthespot] 7647021 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=6 text=(null)   # erase
[fcitx5-onthespot] 7647035 f07_x11 preedit_done
[fcitx5-onthespot] 9186862 f07_x11 filtered type=KeyPress keycode=9                            # Esc
[fcitx5-onthespot] 9187282 f07_x11 preedit_draw caret=0 chg_first=0 chg_length=2 text=(null)   # cancel = erase
[fcitx5-onthespot] 9187296 f07_x11 preedit_done
```

Worth recording: fcitx5 sends **whole-string replacements** (`chg_first=0`,
`chg_length` = previous length) rather than minimal edits — but the protocol
permits arbitrary range edits, so a client must implement the general
`remove(chg_first, chg_length)` + insert case anyway (`text=NULL` means pure
deletion). The pre-edit shows pinyin's own segmentation (`ni hao` with a
space). The **commit precedes the pre-edit erase** — an app that clears its
pre-edit on commit and then applies the erase blindly must not double-clear.
Esc-cancel is invisible as a key event (filtered) and arrives purely as
erase + `preedit_done` — [F07][f07]'s "cancel mid-composition" sequence.

## Findings

- **Negotiated styles:** built-in IM = `PreeditNothing|StatusNothing` (its
  menu has nothing better); fcitx5 = `PreeditPosition|StatusNothing`
  over-the-spot by default, `PreeditCallbacks|StatusNothing` only when the
  server is configured for it. A toolkit needs all three implementations to
  get good behavior everywhere — or settles for `PreeditNothing` and a
  root-window candidate box, which is what most of the
  [surveyed toolkits][gotchas-x11] do.
- **The `XFilterEvent` gate is total:** every event type, not just keys —
  the run shows filtered `ClientMessage`, `PropertyNotify`, `DestroyNotify`
  carrying the XIM protocol itself. Plus the `XNFilterEvents` mask must be
  OR-ed into the window's event mask (0x3 here: the IM needs `KeyRelease`
  the app didn't select).
- **Locale coupling is real but lands elsewhere than advertised:** the
  built-in UTF-8 path survives `C` and even a failed `setlocale`; what
  actually kills text input is `XMODIFIERS` naming an absent server —
  instant NULL, no built-in fallback, retry only via
  `XRegisterIMInstantiateCallback`.
- **The IM server lifecycle is observable and survivable** — instantiate
  callback (fires synchronously if the IM exists; later when it starts),
  destroy callback (Xlib frees everything; the client must only forget),
  re-instantiate on restart. Pre-edit in flight is lost, by design.
- **Commit payloads are real strings, not keysyms** (`status=XLookupChars`,
  `sym=0`, 6 bytes of UTF-8 for `你好`) — the text path and the
  [F06][f06-x11] key path genuinely diverge at this point; an app cannot
  reconstruct commits from keysyms.
- **Spot units are physical window pixels** — candidate-window anchoring
  inherits every [F08](./f08-dpi-scaling.md) scaling problem unsolved.
- **ImportC notes:** `XIMText.string` is a D keyword, so the payload union
  is unreachable from D — the shim adds two C accessor functions, which in
  turn means `c.c` must be **compiled** (dub `sourceFiles`), not merely
  imported, which in turn surfaces glibc's `_FORTIFY_SOURCE` wrappers that
  ImportC cannot digest (`#undef _FORTIFY_SOURCE` at the top of the shim).
  The `XN*` attribute names and `XIM*` style bits are macros — re-declared
  per the [scaffold discipline](./scaffold.md#surprises).

## Tier-C manual script (real desktop)

The headless run covers everything except a human-driven candidate window.
On a real X11 session with fcitx5 (or ibus) configured:

1. `dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f07-text-input`
2. `XMODIFIERS=@im=fcitx ./build/f07_text_input_x11` (no `WSI_AUTO_EXIT`).
3. Activate pinyin (`ctrl+space`), type `nihao` — expect: candidate window
   anchored at the caret bar (over-the-spot), every press logged
   `filtered`, no `commit` yet.
4. Press `2` to pick the second candidate — expect `commit text=…` with that
   candidate (proves selection, not just first-candidate space-commit).
5. Type at the line start vs after `Right`-ing to the end — the candidate
   window must follow the caret (the logged `spot x=…` values).
6. Mid-composition, click another window (focus loss) — log shows
   `focus state=out preedit_pending=N`; expected per-IM behavior: fcitx5
   hides the candidate window and keeps or clears the pre-edit (commit—
   on-focus-loss is IM policy, not protocol — record what it does).
7. `pkill fcitx5` mid-composition → `im_destroyed`; restart → typing works
   again after `im_instantiated` + renegotiation.

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f07-text-input
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    docs/research/window-system-integration/os-apis/x11/examples/f07-text-input/build/f07_text_input_x11
```

That CI-shaped run injects nothing: it negotiates with whatever the
environment provides (with a leaked `XMODIFIERS=@im=ibus` it demonstrates
the instant-NULL pathology and falls back to `XLookupString`) and times out
cleanly, exit 0. The six-scenario choreography — locale matrix, built-in
compose, nonexistent server, fcitx5 over-the-spot + lifecycle,
fcitx5 on-the-spot — is the co-located driver
`examples/f07-text-input/run.sh` (run from the dev shell; it pulls xdotool,
setxkbmap and fcitx5 via `nix shell`, resolves `fcitx5-chinese-addons` +
`font-misc-misc` store paths, and re-execs itself under `xvfb-run` with a
font path). No reachable display prints `SKIP: no X11 display` and exits 0.

## Sources

- **[F07 spec][f07]** — requirements 1–4 (editable line + caret, cursor
  rectangle to the IM, lifecycle, per-event payload logging) and the
  verification tiers.
- **[Xlib — C Language X Interface, ch. 13][xlib-i18n]** — all verbatim
  quotes above: `XOpenIM` locale binding, `XSetLocaleModifiers` /
  `XMODIFIERS`, event filtering and `XFilterEvent`, `XNFilterEvents`,
  `XNSpotLocation`, the on-the-spot client-echo contract, and
  `XNDestroyCallback` / `XRegisterIMInstantiateCallback` semantics (the
  latter two also in the [`XOpenIM` man page][xopenim-man]).
- **[fcitx5 `xim.cpp`][fcitx-xim]** — `guess_server_name()` reading
  `XMODIFIERS` for the server name; `UseOnTheSpot` selecting the
  callbacks-style table.
- **[Concepts: pre-edit / composition][pec]** — the cross-platform
  vocabulary this row instantiates.
- **[Per-platform gotchas § X11][gotchas-x11]** — how the surveyed toolkits
  split between XIM and D-Bus (ibus/fcitx) IME paths; this demo is the
  XIM-native data point.
- **[F06 — keyboard][f06-x11]** — the client-side `xkb_compose` path the
  built-in-IM compose section contrasts with.
- Demo sources: [`app.d`](./examples/f07-text-input/app.d),
  [`instrument.d`](./examples/f07-text-input/instrument.d), the `c.c`
  ImportC shim (with the `XIMText` accessors), and the `run.sh` driver
  alongside them.

<!-- References -->

[f07]: ../features/f07-text-input.md
[f06-x11]: ./f06-keyboard.md
[pec]: ../../concepts.md#pre-edit-composition
[gotchas-x11]: ../../platform-gotchas.md#x11
[xlib-i18n]: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
[xopenim-man]: https://xorg.freedesktop.org/archive/X11R7.7/doc/man/man3/XOpenIM.3.xhtml
[fcitx-xim]: https://github.com/fcitx/fcitx5/blob/master/src/frontend/xim/xim.cpp
